-- 4. RLS: a member of circle A sees nothing belonging to circle B.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000301', 'circlea@example.test'),
  ('00000000-0000-0000-0000-000000000302', 'circleb@example.test');

set local role authenticated;

do $$
declare
  v_a uuid := '00000000-0000-0000-0000-000000000301';
  v_b uuid := '00000000-0000-0000-0000-000000000302';
  v_circle_a uuid;
  v_circle_b uuid;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_a), true);
  select id into v_circle_a from public.create_circle('A', '🤝');
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_a, v_circle_a, '2026-08-21', 'fajr', 'onTime', now());
  insert into public.excused_days (user_id, circle_id, day_key) values (v_a, v_circle_a, '2026-08-20');

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_b), true);
  select id into v_circle_b from public.create_circle('B', '🤝');
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_b, v_circle_b, '2026-08-21', 'asr', 'prayed', now());

  -- B is looking: only B's own circle exists as far as the API is concerned.
  select count(*) into v_n from public.posts;
  if v_n <> 1 then raise exception 'B sees % posts, expected only its own 1', v_n; end if;

  select count(*) into v_n from public.posts where circle_id = v_circle_a;
  if v_n <> 0 then raise exception 'B can read circle A posts'; end if;

  select count(*) into v_n from public.excused_days;
  if v_n <> 0 then raise exception 'B can read circle A excused days'; end if;

  select count(*) into v_n from public.circles;
  if v_n <> 1 then raise exception 'B sees % circles, expected 1', v_n; end if;

  select count(*) into v_n from public.circle_members;
  if v_n <> 1 then raise exception 'B sees % memberships, expected 1', v_n; end if;

  -- profiles: your own row plus your circle-mates', never a stranger's.
  select count(*) into v_n from public.profiles;
  if v_n <> 1 then raise exception 'B sees % profiles, expected 1', v_n; end if;

  -- and the same from A's side
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_a), true);
  select count(*) into v_n from public.posts where circle_id = v_circle_b;
  if v_n <> 0 then raise exception 'A can read circle B posts'; end if;
end $$;

rollback;
