-- 22. Leaving a circle starts a purge clock. §2: "posts stay visible to the
--     circle until the week ends, then purge with the retention job"; §4:
--     "leaving/deletion purges immediately after the current week".
--
-- Regression: leave_circle() deleted the membership row and nothing else, and
-- the sweep had no way to tell a departed member's rows from anyone else's — so
-- the posts survived FOREVER (readable by the circle) and only the photos aged
-- out at 30 days. The orphan predicate that did exist asked "is this user in ANY
-- circle", which meant moving from circle A to circle B left every rest day and
-- recovery total of yours on display to circle A indefinitely.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002201', 'stayer@example.test'),
  ('00000000-0000-0000-0000-000000002202', 'leaver@example.test'),
  ('00000000-0000-0000-0000-000000002203', 'mover@example.test'),
  ('00000000-0000-0000-0000-000000002204', 'hostb@example.test');

set local role authenticated;

do $$
declare
  v_stay  uuid := '00000000-0000-0000-0000-000000002201';
  v_leave uuid := '00000000-0000-0000-0000-000000002202';
  v_move  uuid := '00000000-0000-0000-0000-000000002203';
  v_hostb uuid := '00000000-0000-0000-0000-000000002204';
  v_a     uuid;
  v_code  text;
  v_codeb text;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_stay), true);
  select id, code into v_a, v_code from public.create_circle('A', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_hostb), true);
  select code into v_codeb from public.create_circle('B', '🌙');

  -- the leaver builds a week, then leaves
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_leave), true);
  perform public.join_circle(v_code);
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path)
  values (gen_random_uuid(), v_leave, v_a, '2026-08-21', 'fajr', 'onTime', now(),
          format('%s/%s/gone.jpg', v_a, v_leave));
  insert into public.excused_days (user_id, circle_id, day_key) values (v_leave, v_a, '2026-08-20');
  insert into public.recovery_weeks (user_id, circle_id, week_key, xp) values (v_leave, v_a, '2026-W34', 40);
  perform public.leave_circle();

  -- the mover leaves A and joins B, which is the case the old orphan predicate
  -- could not see at all: they are still in *a* circle, so nothing ever fired.
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_move), true);
  perform public.join_circle(v_code);
  insert into public.excused_days (user_id, circle_id, day_key) values (v_move, v_a, '2026-08-19');
  perform public.leave_circle();
  perform public.join_circle(v_codeb);
end $$;

reset role;

-- The departure record is the sweep's bookkeeping, deliberately unreadable from
-- a user session — so this assertion changes role rather than trusting the RPC.
do $$
begin
  if not exists (select 1 from public.circle_departures
                  where user_id = '00000000-0000-0000-0000-000000002202') then
    raise exception 'leave_circle() did not record a departure — nothing can ever purge the week';
  end if;
  if not exists (select 1 from public.circle_departures
                  where user_id = '00000000-0000-0000-0000-000000002203') then
    raise exception 'a member who left circle A for circle B recorded no departure';
  end if;
end $$;

set local role service_role;

-- Inside the grace window: everything the circle can see stays put, so the
-- week's grid does not develop holes mid-week.
do $$
begin
  perform public.purge_expired_photo_rows(30);
  if not exists (select 1 from public.posts where user_id = '00000000-0000-0000-0000-000000002202') then
    raise exception 'a leaver''s posts were purged inside the grace window';
  end if;
  if not exists (select 1 from public.excused_days where user_id = '00000000-0000-0000-0000-000000002202') then
    raise exception 'a leaver''s resting days were purged inside the grace window';
  end if;
end $$;

-- ...and once the week is over, the whole footprint goes — rows AND photo.
update public.circle_departures set left_at = now() - interval '8 days';

do $$
declare
  v_leave uuid := '00000000-0000-0000-0000-000000002202';
  v_move  uuid := '00000000-0000-0000-0000-000000002203';
begin
  perform public.purge_expired_photo_rows(30);

  if exists (select 1 from public.posts where user_id = v_leave) then
    raise exception 'a departed member''s posts outlived the grace window';
  end if;
  if exists (select 1 from public.excused_days where user_id = v_leave)
     or exists (select 1 from public.recovery_weeks where user_id = v_leave) then
    raise exception 'a departed member''s resting/recovery rows outlived the grace window';
  end if;
  if not exists (select 1 from public.photo_tombstones where path like '%gone.jpg') then
    raise exception 'purging a departed member''s post did not record its photo path';
  end if;

  -- the mover's circle-A rest day goes even though they are very much in a circle
  if exists (select 1 from public.excused_days
              where user_id = v_move
                and circle_id <> (select circle_id from public.circle_members where user_id = v_move)) then
    raise exception 'circle A can still see the rest days of a member who moved to circle B';
  end if;
end $$;

-- Re-joining cancels the clock: a member who came back must not have their week
-- deleted out from under them a few days later.
reset role;

-- Stash circle A's code while we can still read it: the leaver is solo now, so
-- circles_select hides the row from them (which is the point of test 07).
select set_config('test.code_a', (select code from public.circles where name = 'A'), false);

set local role authenticated;

do $$
declare
  v_leave uuid := '00000000-0000-0000-0000-000000002202';
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_leave), true);
  perform public.join_circle(current_setting('test.code_a'));
end $$;

reset role;

do $$
begin
  if exists (select 1 from public.circle_departures
              where user_id = '00000000-0000-0000-0000-000000002202') then
    raise exception 're-joining left the departure record (and the purge clock) in place';
  end if;
end $$;

-- A circle everybody left keeps its invite code alive against the code space
-- forever; the sweep collects it once the grace window closes.
insert into public.circles (id, code, name, created_at)
values ('00000000-0000-0000-0000-0000000022ee', 'EMPTYA', 'Abandoned', now() - interval '9 days');

set local role service_role;

do $$
begin
  perform public.purge_expired_photo_rows(30);
  if exists (select 1 from public.circles where id = '00000000-0000-0000-0000-0000000022ee') then
    raise exception 'an abandoned circle kept its invite code alive';
  end if;
end $$;

rollback;
