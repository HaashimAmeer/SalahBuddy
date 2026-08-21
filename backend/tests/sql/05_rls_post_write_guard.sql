-- 5. RLS: you cannot post as someone else, nor into a circle you are not in.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000401', 'writer@example.test'),
  ('00000000-0000-0000-0000-000000000402', 'mate@example.test'),
  ('00000000-0000-0000-0000-000000000403', 'stranger@example.test');

set local role authenticated;

do $$
declare
  v_me      uuid := '00000000-0000-0000-0000-000000000401';
  v_mate    uuid := '00000000-0000-0000-0000-000000000402';
  v_other   uuid := '00000000-0000-0000-0000-000000000403';
  v_mine    uuid;
  v_theirs  uuid;
  v_code    text;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  select id, code into v_mine, v_code from public.create_circle('Mine', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_mate), true);
  perform public.join_circle(v_code);

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_other), true);
  select id into v_theirs from public.create_circle('Theirs', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);

  -- someone else's user_id, my own circle
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_mate, v_mine, '2026-08-21', 'fajr', 'onTime', now());
    raise exception 'posted on behalf of a circle-mate';
  exception when insufficient_privilege then
    null;
  end;

  -- my own user_id, a circle I am not in
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_me, v_theirs, '2026-08-21', 'fajr', 'onTime', now());
    raise exception 'posted into a circle I am not a member of';
  exception when insufficient_privilege then
    null;
  end;

  -- excused_days and recovery_weeks carry the same guard
  begin
    insert into public.excused_days (user_id, circle_id, day_key)
    values (v_mate, v_mine, '2026-08-21');
    raise exception 'marked a circle-mate as excused';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.recovery_weeks (user_id, circle_id, week_key, xp)
    values (v_mate, v_mine, '2026-W34', 40);
    raise exception 'wrote a circle-mate''s recovery XP';
  exception when insufficient_privilege then
    null;
  end;

  -- and nobody can hand-insert a membership (join goes through the RPC)
  begin
    insert into public.circle_members (circle_id, user_id) values (v_theirs, v_me);
    raise exception 'inserted a membership directly';
  exception when insufficient_privilege then
    null;
  end;

  -- the honest write still works
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_mine, '2026-08-21', 'fajr', 'onTime', now());
end $$;

rollback;
