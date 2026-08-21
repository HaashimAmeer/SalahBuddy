-- 15. The private prayer-photos bucket, and its <circle_id>/<user_id>/<uuid>.jpg
--     path contract: circle-mates read, only the owner writes.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000001101', 'shooter@example.test'),
  ('00000000-0000-0000-0000-000000001102', 'viewer@example.test'),
  ('00000000-0000-0000-0000-000000001103', 'nosy@example.test');

do $$
declare
  v_bucket storage.buckets;
begin
  select * into v_bucket from storage.buckets where id = 'prayer-photos';
  if not found then raise exception 'prayer-photos bucket was not created'; end if;
  if v_bucket.public then raise exception 'prayer-photos must be private'; end if;
  if v_bucket.file_size_limit <> 5242880 then
    raise exception 'unexpected file size limit %', v_bucket.file_size_limit;
  end if;
  if v_bucket.allowed_mime_types is distinct from array['image/jpeg'] then
    raise exception 'unexpected mime allowlist %', v_bucket.allowed_mime_types::text;
  end if;

  if (select count(*) from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname like 'prayer_photos_%') <> 4 then
    raise exception 'expected 4 prayer_photos policies on storage.objects';
  end if;
end $$;

set local role authenticated;

do $$
declare
  v_owner  uuid := '00000000-0000-0000-0000-000000001101';
  v_mate   uuid := '00000000-0000-0000-0000-000000001102';
  v_nosy   uuid := '00000000-0000-0000-0000-000000001103';
  v_circle uuid;
  v_code   text;
  v_n      int;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_owner), true);
  select id, code into v_circle, v_code from public.create_circle('Photos', '🤝');

  insert into storage.objects (bucket_id, name, owner)
  values ('prayer-photos', format('%s/%s/%s.jpg', v_circle, v_owner, gen_random_uuid()), v_owner);

  -- writing under someone else's folder is refused
  begin
    insert into storage.objects (bucket_id, name, owner)
    values ('prayer-photos', format('%s/%s/%s.jpg', v_circle, v_mate, gen_random_uuid()), v_owner);
    raise exception 'wrote into a circle-mate''s photo folder';
  exception when insufficient_privilege then
    null;
  end;

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_mate), true);
  perform public.join_circle(v_code);
  select count(*) into v_n from storage.objects;
  if v_n <> 1 then raise exception 'a circle-mate sees % photos, expected 1', v_n; end if;

  -- ...but cannot delete what is not theirs
  delete from storage.objects where bucket_id = 'prayer-photos';
  if (select count(*) from storage.objects) <> 1 then
    raise exception 'a circle-mate deleted the owner''s photo';
  end if;

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_nosy), true);
  perform public.create_circle('Nowhere', '🤝');
  select count(*) into v_n from storage.objects;
  if v_n <> 0 then raise exception 'an outsider sees % photos, expected 0', v_n; end if;
end $$;

rollback;
