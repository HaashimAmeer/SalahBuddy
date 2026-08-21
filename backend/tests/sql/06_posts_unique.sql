-- 6. One post per (user, day_key, prayer) — the offline queue relies on it.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000501', 'dup@example.test');

set local role authenticated;

do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000000501';
  v_circle uuid;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  select id into v_circle from public.create_circle('Dup', '🤝');

  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-21', 'maghrib', 'onTime', now());

  -- different client uuid, same prayer slot
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_me, v_circle, '2026-08-21', 'maghrib', 'prayed', now());
    raise exception 'a duplicate (user, day_key, prayer) post was accepted';
  exception when unique_violation then
    null;
  end;

  -- a different day and a different prayer are both fine
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'maghrib', 'onTime', now()),
         (gen_random_uuid(), v_me, v_circle, '2026-08-21', 'isha',    'lastCall', now());

  if (select count(*) from public.posts) <> 3 then
    raise exception 'expected 3 posts, saw %', (select count(*) from public.posts);
  end if;
end $$;

rollback;
