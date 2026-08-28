-- 11. delete_account clears everything of the caller's server-side, and touches
--     nobody else's rows.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000901', 'quitter@example.test'),
  ('00000000-0000-0000-0000-000000000902', 'friend@example.test');

set local role authenticated;

do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000000901';
  v_friend uuid := '00000000-0000-0000-0000-000000000902';
  v_circle uuid;
  v_code   text;
  -- Derived, not written down: record_nudge() only accepts a day_key within
  -- ±1 day of the server's own date, so a literal here passes for two days and
  -- then fails forever (see test 09). posts.day_key below has no such bound and
  -- can stay a fixed date.
  v_today  text := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  select id, code into v_circle, v_code from public.create_circle('Bye', '🤝');
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-21', 'fajr', 'onTime', now());
  insert into public.excused_days   (user_id, circle_id, day_key)  values (v_me, v_circle, '2026-08-19');
  insert into public.recovery_weeks (user_id, circle_id, week_key, xp) values (v_me, v_circle, '2026-W34', 25);
  insert into public.custom_challenges (id, circle_id, created_by, prayer, days, week_key)
  values ('custom-' || gen_random_uuid()::text, v_circle, v_me, 'fajr', 3, '2026-W34');
  insert into public.devices (user_id, apns_token) values (v_me, 'token-quitter');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_friend), true);
  perform public.join_circle(v_code);
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_friend, v_circle, '2026-08-21', 'asr', 'prayed', now());
  insert into public.devices (user_id, apns_token) values (v_friend, 'token-friend');
  perform public.record_nudge(v_me, v_today, 'isha');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  perform public.delete_account();

  -- now look with the service role, which sees past RLS
  perform set_config('request.jwt.claims', '', true);
end $$;

reset role;

do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000000901';
  v_friend uuid := '00000000-0000-0000-0000-000000000902';
begin
  if exists (select 1 from public.profiles       where id      = v_me) then raise exception 'profile survived'; end if;
  if exists (select 1 from public.circle_members where user_id = v_me) then raise exception 'membership survived'; end if;
  if exists (select 1 from public.posts          where user_id = v_me) then raise exception 'posts survived'; end if;
  if exists (select 1 from public.excused_days   where user_id = v_me) then raise exception 'excused days survived'; end if;
  if exists (select 1 from public.recovery_weeks where user_id = v_me) then raise exception 'recovery weeks survived'; end if;
  if exists (select 1 from public.custom_challenges where created_by = v_me) then raise exception 'challenges survived'; end if;
  if exists (select 1 from public.devices        where user_id = v_me) then raise exception 'devices survived'; end if;
  if exists (select 1 from public.nudges where sender_id = v_me or recipient_id = v_me) then
    raise exception 'nudges survived';
  end if;

  -- the friend is untouched
  if not exists (select 1 from public.posts   where user_id = v_friend) then raise exception 'the friend''s post was collateral'; end if;
  if not exists (select 1 from public.devices where user_id = v_friend) then raise exception 'the friend''s device was collateral'; end if;
  if not exists (select 1 from public.circle_members where user_id = v_friend) then raise exception 'the friend was ejected'; end if;
end $$;

rollback;
