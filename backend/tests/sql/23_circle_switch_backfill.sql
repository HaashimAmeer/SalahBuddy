-- 23. §2: "joining mid-week shows your week-so-far posts to the circle (the
--     client uploads the current week's logs on join)".
--
-- Regression for keys that named the user but not the circle. A member's posts,
-- rest days and recovery total survive them leaving (§2), so with
-- `unique (user_id, day_key, prayer)` every row of that backfill collided with
-- the rows still sitting in the circle they just left — and the on-conflict
-- escape was closed too, because posts_update's predicate names the CURRENT
-- circle while the stored row holds the old one. The member joined their new
-- circle with a blank week and no way to fix it from the app.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002301', 'mover@example.test'),
  ('00000000-0000-0000-0000-000000002302', 'hosta@example.test'),
  ('00000000-0000-0000-0000-000000002303', 'hostb@example.test');

set local role authenticated;

do $$
declare
  v_move  uuid := '00000000-0000-0000-0000-000000002301';
  v_hosta uuid := '00000000-0000-0000-0000-000000002302';
  v_hostb uuid := '00000000-0000-0000-0000-000000002303';
  v_a     uuid;
  v_b     uuid;
  v_ca    text;
  v_cb    text;
  v_n     int;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_hosta), true);
  select id, code into v_a, v_ca from public.create_circle('A', '🤝');
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_hostb), true);
  select id, code into v_b, v_cb from public.create_circle('B', '🌙');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_move), true);
  perform public.join_circle(v_ca);
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_move, v_a, '2026-08-19', 'fajr', 'onTime', now());
  insert into public.excused_days   (user_id, circle_id, day_key)         values (v_move, v_a, '2026-08-18');
  insert into public.recovery_weeks (user_id, circle_id, week_key, xp)    values (v_move, v_a, '2026-W34', 25);

  perform public.leave_circle();
  perform public.join_circle(v_cb);

  -- The backfill: the same week, re-uploaded into the new circle.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_move, v_b, '2026-08-19', 'fajr', 'onTime', now());
  insert into public.excused_days   (user_id, circle_id, day_key)      values (v_move, v_b, '2026-08-18');
  insert into public.recovery_weeks (user_id, circle_id, week_key, xp) values (v_move, v_b, '2026-W34', 25);

  select count(*) into v_n from public.posts;
  if v_n <> 1 then
    raise exception 'circle B sees % of the backfilled posts, expected exactly 1', v_n;
  end if;
  select count(*) into v_n from public.excused_days;
  if v_n <> 1 then raise exception 'the backfilled rest day did not land'; end if;
  select count(*) into v_n from public.recovery_weeks;
  if v_n <> 1 then raise exception 'the backfilled recovery total did not land'; end if;

  -- ...and within ONE circle the fact is still unique: a second Fajr for the
  -- same day is still the duplicate the offline queue must not create.
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_move, v_b, '2026-08-19', 'fajr', 'prayed', now());
    raise exception 'a duplicate post inside one circle was accepted';
  exception when unique_violation then null;
  end;
end $$;

rollback;
