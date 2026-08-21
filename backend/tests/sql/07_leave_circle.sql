-- 7. leave_circle drops the membership; afterwards you are solo and the circle's
--    rows are invisible — but your posts survive for the circle until retention.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000601', 'leaver@example.test'),
  ('00000000-0000-0000-0000-000000000602', 'stayer@example.test');

set local role authenticated;

do $$
declare
  v_leaver uuid := '00000000-0000-0000-0000-000000000601';
  v_stayer uuid := '00000000-0000-0000-0000-000000000602';
  v_circle uuid;
  v_code   text;
  v_n      int;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_stayer), true);
  select id, code into v_circle, v_code from public.create_circle('Stays', '🤝');
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_stayer, v_circle, '2026-08-21', 'fajr', 'onTime', now());

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_leaver), true);
  perform public.join_circle(v_code);
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_leaver, v_circle, '2026-08-21', 'dhuhr', 'prayed', now());

  if public.current_circle_id() is distinct from v_circle then
    raise exception 'current_circle_id() did not settle on the joined circle';
  end if;
  select count(*) into v_n from public.posts;
  if v_n <> 2 then raise exception 'expected to see 2 circle posts, saw %', v_n; end if;

  perform public.leave_circle();

  if public.current_circle_id() is not null then
    raise exception 'current_circle_id() is still set after leaving';
  end if;
  if exists (select 1 from public.circle_members where user_id = v_leaver) then
    raise exception 'membership survived leave_circle()';
  end if;

  select count(*) into v_n from public.posts;
  if v_n <> 0 then raise exception 'a solo user can still read % circle posts', v_n; end if;
  select count(*) into v_n from public.circles;
  if v_n <> 0 then raise exception 'a solo user can still read the circle row'; end if;

  -- writing is closed too
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_leaver, v_circle, '2026-08-22', 'asr', 'prayed', now());
    raise exception 'a departed member can still post to the circle';
  exception when insufficient_privilege then
    null;
  end;

  -- ...while the circle keeps seeing what they already posted
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_stayer), true);
  select count(*) into v_n from public.posts;
  if v_n <> 2 then raise exception 'the leaver''s posts vanished from the circle (saw %)', v_n; end if;
end $$;

rollback;
