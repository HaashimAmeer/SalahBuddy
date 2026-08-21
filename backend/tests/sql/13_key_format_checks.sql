-- 13. day_key / week_key are client-computed strings, so the column checks are
--     the only thing standing between a formatting bug and an unreadable grid.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000001001', 'keys@example.test');
insert into public.circles (id, code, name, created_by)
values ('00000000-0000-0000-0000-0000000010cc', 'KEYSAB', 'Keys', '00000000-0000-0000-0000-000000001001');
insert into public.circle_members (circle_id, user_id)
values ('00000000-0000-0000-0000-0000000010cc', '00000000-0000-0000-0000-000000001001');

do $$
declare
  v_user   uuid := '00000000-0000-0000-0000-000000001001';
  v_circle uuid := '00000000-0000-0000-0000-0000000010cc';
  bad_day  text;
  bad_week text;
begin
  foreach bad_day in array array['2026-8-21', '20260821', '2026-08-21T00:00:00', '', 'today', '2026-08-211']
  loop
    begin
      insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
      values (gen_random_uuid(), v_user, v_circle, bad_day, 'fajr', 'onTime', now());
      raise exception 'posts accepted the malformed day_key %', quote_literal(bad_day);
    exception when check_violation then
      null;
    end;

    begin
      insert into public.excused_days (user_id, circle_id, day_key) values (v_user, v_circle, bad_day);
      raise exception 'excused_days accepted the malformed day_key %', quote_literal(bad_day);
    exception when check_violation then
      null;
    end;
  end loop;

  foreach bad_week in array array['2026-W1', '2026W34', '2026-w34', '', '2026-W345']
  loop
    begin
      insert into public.recovery_weeks (user_id, circle_id, week_key, xp)
      values (v_user, v_circle, bad_week, 10);
      raise exception 'recovery_weeks accepted the malformed week_key %', quote_literal(bad_week);
    exception when check_violation then
      null;
    end;
  end loop;

  -- negative recovery XP is not a thing
  begin
    insert into public.recovery_weeks (user_id, circle_id, week_key, xp)
    values (v_user, v_circle, '2026-W34', -1);
    raise exception 'recovery_weeks accepted negative xp';
  exception when check_violation then
    null;
  end;

  -- custom challenges span 2..7 days
  begin
    insert into public.custom_challenges (id, circle_id, created_by, prayer, days, week_key)
    values ('custom-too-long', v_circle, v_user, 'fajr', 8, '2026-W34');
    raise exception 'custom_challenges accepted an 8-day target';
  exception when check_violation then
    null;
  end;

  -- devices only know two APNs environments
  begin
    insert into public.devices (user_id, apns_token, environment) values (v_user, 'tok', 'staging');
    raise exception 'devices accepted an unknown APNs environment';
  exception when check_violation then
    null;
  end;

  -- and the well-formed versions all land
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_user, v_circle, '2026-08-21', 'fajr', 'onTime', now());
  insert into public.excused_days (user_id, circle_id, day_key) values (v_user, v_circle, '2026-08-21');
  insert into public.recovery_weeks (user_id, circle_id, week_key, xp) values (v_user, v_circle, '2026-W34', 40);
  insert into public.custom_challenges (id, circle_id, created_by, prayer, days, week_key)
  values ('custom-ok', v_circle, v_user, 'fajr', 3, '2026-W34');
  insert into public.devices (user_id, apns_token, environment) values (v_user, 'tok', 'sandbox');
end $$;

rollback;
