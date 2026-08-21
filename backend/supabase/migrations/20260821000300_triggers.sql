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
