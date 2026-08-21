-- v4 Phase A — triggers.

-- updated_at is maintained server-side so a client with a skewed clock (or the
-- app's own time-travel offset) can never make a row look newer than it is.
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- created_at is the retention clock (§4): the sweep ages photos off it, so a row
-- that can re-date itself never expires. The column-scoped UPDATE grants already
-- keep `authenticated` off it; this pins it against every other writer too —
-- including the service-role client the edge functions use, which bypasses both
-- RLS and the grants.
create or replace function public.freeze_created_at() returns trigger
language plpgsql set search_path = public, pg_temp
as $$
begin
  new.created_at := old.created_at;
  return new;
end $$;

drop trigger if exists profiles_touch       on public.profiles;
create trigger profiles_touch       before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists posts_touch          on public.posts;
create trigger posts_touch          before update on public.posts
  for each row execute function public.touch_updated_at();

drop trigger if exists recovery_weeks_touch on public.recovery_weeks;
create trigger recovery_weeks_touch before update on public.recovery_weeks
  for each row execute function public.touch_updated_at();

drop trigger if exists devices_touch        on public.devices;
create trigger devices_touch        before update on public.devices
  for each row execute function public.touch_updated_at();

drop trigger if exists posts_freeze_created on public.posts;
create trigger posts_freeze_created before update on public.posts
  for each row execute function public.freeze_created_at();

-- Photo tombstones ----------------------------------------------------------
-- The only reference to a Storage object is posts.photo_path. Undo deletes the
-- row, delete_account() deletes them all, retention nulls the column — and in
-- every one of those cases the path becomes unknowable the instant the row
-- changes, leaving a private JPEG in the bucket that nothing can ever find or
-- delete. Recording it here first is what makes the sweep the single deleter.
--
-- SECURITY DEFINER: the client's own DELETE (undo) has to be able to write this
-- table, and `authenticated` deliberately holds no grant on it.
create or replace function public.tombstone_photo_path() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if old.photo_path is null then
    return null;
  end if;
  if tg_op = 'UPDATE' and new.photo_path is not distinct from old.photo_path then
    return null;   -- the column was in the statement but did not actually change
  end if;
  insert into public.photo_tombstones (path) values (old.photo_path)
  on conflict (path) do nothing;
  return null;
end $$;

drop trigger if exists posts_tombstone_photo on public.posts;
create trigger posts_tombstone_photo after delete or update of photo_path on public.posts
  for each row execute function public.tombstone_photo_path();

-- Departures ----------------------------------------------------------------
-- On circle_members rather than inside leave_circle() because the
-- circle_members_delete policy lets a client DELETE its own row directly — a
-- leave that never touched the RPC still has to start the purge clock.
create or replace function public.record_circle_departure() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  -- A membership row also disappears when its circle or its user is deleted, and
  -- by the time this AFTER trigger runs the parent is already gone — inserting a
  -- departure that references it would fail the FK and abort the whole delete.
  -- Nothing is left to purge in that case anyway.
  if not exists (select 1 from public.circles where id = old.circle_id)
     or not exists (select 1 from auth.users where id = old.user_id) then
    return null;
  end if;

  insert into public.circle_departures (user_id, circle_id, left_at)
  values (old.user_id, old.circle_id, now())
  on conflict (user_id, circle_id) do update set left_at = excluded.left_at;
  return null;
end $$;

drop trigger if exists circle_members_departed on public.circle_members;
create trigger circle_members_departed after delete on public.circle_members
  for each row execute function public.record_circle_departure();

-- Re-joining the same circle cancels the purge clock; without this a member who
-- left and came back would have their week deleted out from under them.
create or replace function public.clear_circle_departure() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  delete from public.circle_departures
   where user_id = new.user_id and circle_id = new.circle_id;
  return null;
end $$;

drop trigger if exists circle_members_returned on public.circle_members;
create trigger circle_members_returned after insert on public.circle_members
  for each row execute function public.clear_circle_departure();

-- Device cap ----------------------------------------------------------------
-- devices_all lets a user insert their own rows, and apns_token is the primary
-- key — nothing else bounds how many a single account can register. The fan-out
-- reads every one of them, serially, inside one Edge Function invocation, so an
-- unbounded roster is a way to make a circle's pushes time out. Prune the oldest
-- instead of raising: a real phone re-registering must never see an error.
create or replace function public.enforce_device_cap() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  delete from public.devices d
   where d.user_id = new.user_id
     and d.apns_token <> new.apns_token
     and d.apns_token in (
       select apns_token from public.devices
        where user_id = new.user_id and apns_token <> new.apns_token
        order by updated_at desc
       offset greatest(public.max_devices_per_user() - 1, 0)
     );
  return new;
end $$;

drop trigger if exists devices_cap on public.devices;
create trigger devices_cap before insert on public.devices
  for each row execute function public.enforce_device_cap();

-- Cap 8 ---------------------------------------------------------------------
-- A count-then-insert is a classic race, so take a transaction-scoped advisory
-- lock keyed on the circle first: two people tapping "join" on the last free
-- slot at the same instant serialise here instead of both squeezing in.
create or replace function public.enforce_circle_capacity() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  perform pg_advisory_xact_lock(hashtext(new.circle_id::text));
  select count(*) into v_count from public.circle_members where circle_id = new.circle_id;
  if v_count >= public.circle_max_members() then
    raise exception 'circle is full (% members)', public.circle_max_members()
      using errcode = 'SB409', hint = 'circle_full';
  end if;
  return new;
end $$;

drop trigger if exists circle_members_capacity on public.circle_members;
create trigger circle_members_capacity before insert on public.circle_members
  for each row execute function public.enforce_circle_capacity();

-- profiles auto-create ------------------------------------------------------
-- Sign-in happens at the social boundary, so the very first thing a new auth
-- user needs is a profile row for their circle-mates to read.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, name)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
      ''
    )
  )
  on conflict (id) do nothing;
  return new;
end $$;

-- Guarded: only wire the trigger when auth.users actually looks like Supabase's.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users' and column_name = 'raw_user_meta_data'
  ) then
    execute 'drop trigger if exists on_auth_user_created on auth.users';
    execute 'create trigger on_auth_user_created after insert on auth.users
             for each row execute function public.handle_new_user()';
  else
    raise notice 'auth.users missing raw_user_meta_data — profile auto-create trigger skipped';
  end if;
end $$;
