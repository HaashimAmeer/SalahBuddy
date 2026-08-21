-- v4 Phase A — photo storage.
--
-- Path layout is `<circle_id>/<user_id>/<uuid>.jpg`, which is what makes the
-- policies below one-liners: folder 1 is the read scope, folder 2 is the owner.
-- 5 MB / image/jpeg only, matching PhotoStore's downscaled quality-0.7 JPEGs.
--
-- Wrapped in a guard so the migration is a no-op on a plain Postgres without
-- Supabase's storage schema (the test shim provides a minimal one, so the
-- policies below really are exercised).
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    raise notice 'storage schema absent — skipping prayer-photos bucket and policies';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('prayer-photos', 'prayer-photos', false, 5242880, array['image/jpeg'])
  on conflict (id) do nothing;

  -- The tombstone clause is what makes "deletion purges immediately" (§4) true
  -- of the READ as well as the bytes. Membership alone would keep serving a
  -- departed account's photos to the circle right up until the next sweep runs
  -- — and the sweep is not even scheduled yet. The instant the owning row is
  -- retracted (undo, delete_account, expiry) the object stops being readable;
  -- the sweep then removes it for real.
  execute 'drop policy if exists prayer_photos_select on storage.objects';
  execute $p$
    create policy prayer_photos_select on storage.objects for select to authenticated
    using (
      bucket_id = 'prayer-photos'
      and (storage.foldername(name))[1] = public.current_circle_id()::text
      and not public.photo_is_pending_deletion(name)
    )
  $p$;

  execute 'drop policy if exists prayer_photos_insert on storage.objects';
  execute $p$
    create policy prayer_photos_insert on storage.objects for insert to authenticated
    with check (
      bucket_id = 'prayer-photos'
      and (storage.foldername(name))[1] = public.current_circle_id()::text
      and (storage.foldername(name))[2] = auth.uid()::text
    )
  $p$;

  execute 'drop policy if exists prayer_photos_update on storage.objects';
  execute $p$
    create policy prayer_photos_update on storage.objects for update to authenticated
    using (
      bucket_id = 'prayer-photos'
      and (storage.foldername(name))[1] = public.current_circle_id()::text
      and (storage.foldername(name))[2] = auth.uid()::text
    )
    with check (
      bucket_id = 'prayer-photos'
      and (storage.foldername(name))[1] = public.current_circle_id()::text
      and (storage.foldername(name))[2] = auth.uid()::text
    )
  $p$;

  execute 'drop policy if exists prayer_photos_delete on storage.objects';
  execute $p$
    create policy prayer_photos_delete on storage.objects for delete to authenticated
    using (
      bucket_id = 'prayer-photos'
      and (storage.foldername(name))[1] = public.current_circle_id()::text
      and (storage.foldername(name))[2] = auth.uid()::text
    )
  $p$;
end $$;
