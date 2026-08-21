-- 19. The columns a signed-in user must never write, proved from a user session
--     rather than from the grant statements.
--
-- posts.created_at is the retention clock (§4). Regression for a table-wide
-- INSERT/UPDATE grant, under which a client could
--   PATCH /rest/v1/posts?id=eq.<mine> {"created_at":"2126-01-01T00:00:00Z"}
-- and its photo would never age out — a picture the owner believed expires from
-- the circle in 30 days stays readable by every current and future member,
-- forever. Back-dating works the same way in reverse and force-purges early.
-- The comment in the retention RPC ("ages off the server's own clock") is only
-- true because of the grants asserted here.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000001901', 'writer@example.test'),
  ('00000000-0000-0000-0000-000000001902', 'mate@example.test');

set local role authenticated;

do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000001901';
  v_mate   uuid := '00000000-0000-0000-0000-000000001902';
  v_circle uuid;
  v_code   text;
  v_post   uuid := '00000000-0000-0000-0000-0000000019a1';
  v_before timestamptz;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  select id, code into v_circle, v_code from public.create_circle('Columns', '🤝');

  -- INSERT with a forged created_at
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, created_at)
    values (v_post, v_me, v_circle, '2026-08-21', 'fajr', 'onTime', now(), '2126-01-01T00:00:00Z');
    raise exception 'a client set posts.created_at on INSERT';
  exception when insufficient_privilege then null;
  end;

  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path)
  values (v_post, v_me, v_circle, '2026-08-21', 'fajr', 'onTime', now(), 'p/q/r.jpg');
  select created_at into v_before from public.posts where id = v_post;

  -- UPDATE, the shape the finding was reproduced with
  begin
    update public.posts set created_at = '2126-01-01T00:00:00Z' where id = v_post;
    raise exception 'a client re-dated posts.created_at';
  exception when insufficient_privilege then null;
  end;

  -- ...and the columns it legitimately owns still move, which proves the grant
  -- was narrowed rather than simply broken.
  update public.posts set tier = 'prayed', place_label = 'Masjid' where id = v_post;
  if (select tier from public.posts where id = v_post) <> 'prayed' then
    raise exception 'the narrowed grant broke a legitimate post edit';
  end if;
  if (select created_at from public.posts where id = v_post) <> v_before then
    raise exception 'created_at drifted during a legitimate update';
  end if;

  -- push leases are the server's
  begin
    update public.posts set notified_at = null where id = v_post;
    raise exception 'a client cleared posts.notified_at (the first-post push lease)';
  exception when insufficient_privilege then null;
  end;

  -- nudges.created_at is the column the nudge sweep prunes on
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_mate), true);
  perform public.join_circle(v_code);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  begin
    insert into public.nudges (sender_id, recipient_id, day_key, prayer, created_at)
    values (v_me, v_mate, '2026-08-21', 'fajr', '2126-01-01T00:00:00Z');
    raise exception 'a client set nudges.created_at';
  exception when insufficient_privilege then null;
  end;

  -- recovery_weeks.updated_at belongs to the touch trigger
  insert into public.recovery_weeks (user_id, circle_id, week_key, xp)
  values (v_me, v_circle, '2026-W34', 20);
  begin
    update public.recovery_weeks set updated_at = '2126-01-01T00:00:00Z'
     where user_id = v_me and circle_id = v_circle and week_key = '2026-W34';
    raise exception 'a client set recovery_weeks.updated_at';
  exception when insufficient_privilege then null;
  end;

  -- circle_members.announced_at is the join-push lease
  begin
    update public.circle_members set announced_at = null where user_id = v_me;
    raise exception 'a client cleared circle_members.announced_at';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- The service-role client in the edge functions bypasses RLS *and* the grants,
-- so created_at is pinned by a trigger too: even a privileged writer cannot
-- re-date a row out of the retention window.
do $$
declare
  v_post uuid := '00000000-0000-0000-0000-0000000019a1';
  v_was  timestamptz;
begin
  select created_at into v_was from public.posts where id = v_post;
  update public.posts set created_at = '2126-01-01T00:00:00Z' where id = v_post;
  if (select created_at from public.posts where id = v_post) <> v_was then
    raise exception 'freeze_created_at did not pin posts.created_at against a privileged writer';
  end if;
end $$;

rollback;
