-- v4 Phase A — RPCs.
--
-- Every function here is SECURITY DEFINER with a pinned search_path, is revoked
-- from public/anon, and starts by asserting there is a signed-in caller. They
-- exist because these operations need to be atomic (circle + code + membership)
-- or need to see rows RLS would hide.
--
-- SQLSTATEs the client switches on:
--   SB401 not signed in · SB404 no such circle · SB409 circle full · SB410 already in a circle

-- Invite codes are read aloud and typed by hand, so the alphabet drops I/O/0/1.
-- gen_random_uuid() draws from the platform CSPRNG, which keeps this core-only —
-- no dependency on which schema pgcrypto happens to live in.
create or replace function public.generate_invite_code() returns text
language plpgsql volatile set search_path = public, pg_temp
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  v_code  text := '';
  i int;
begin
  for i in 0..5 loop
    v_code := v_code || substr(alphabet, (get_byte(v_bytes, i) % length(alphabet)) + 1, 1);
  end loop;
  return v_code;
end $$;

create or replace function public.create_circle(p_name text default null, p_emoji text default null)
returns public.circles
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_circle public.circles;
  v_tries  int := 0;
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  if exists (select 1 from public.circle_members where user_id = v_uid) then
    raise exception 'already in a circle' using errcode = 'SB410', hint = 'already_member';
  end if;

  -- Retry on the (astronomically unlikely) code collision rather than pre-checking:
  -- the unique index is the only thing that can actually settle a race.
  loop
    v_tries := v_tries + 1;
    begin
      insert into public.circles (code, name, emoji, created_by)
      values (
        public.generate_invite_code(),
        coalesce(nullif(btrim(p_name), ''), 'Your Circle'),
        coalesce(nullif(btrim(p_emoji), ''), '🤝'),
        v_uid
      )
      returning * into v_circle;
      exit;
    exception when unique_violation then
      if v_tries >= 20 then raise; end if;
    end;
  end loop;

  -- Creator is just member #1 — there is no admin role (§2).
  insert into public.circle_members (circle_id, user_id) values (v_circle.id, v_uid);
  return v_circle;
end $$;

create or replace function public.join_circle(p_code text)
returns public.circles
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_circle public.circles;
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  if exists (select 1 from public.circle_members where user_id = v_uid) then
    raise exception 'already in a circle' using errcode = 'SB410', hint = 'already_member';
  end if;

  select * into v_circle from public.circles where code = upper(btrim(coalesce(p_code, '')));
  if not found then
    raise exception 'no circle with that code' using errcode = 'SB404', hint = 'unknown_code';
  end if;

  begin
    insert into public.circle_members (circle_id, user_id) values (v_circle.id, v_uid);
  exception when unique_violation then
    -- Lost a race against another device signed in as the same user.
    raise exception 'already in a circle' using errcode = 'SB410', hint = 'already_member';
  end;

  return v_circle;
end $$;

-- Leaving returns you to solo mode. Posts stay put: the circle keeps seeing your
-- week until retention purges them (§2).
create or replace function public.leave_circle() returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  delete from public.circle_members where user_id = v_uid;
end $$;

-- Any member can rename — the group stays flat.
create or replace function public.rename_circle(p_name text, p_emoji text)
returns public.circles
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_circle public.circles;
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;

  update public.circles c
     set name  = coalesce(nullif(btrim(p_name),  ''), c.name),
         emoji = coalesce(nullif(btrim(p_emoji), ''), c.emoji)
   where c.id = (select circle_id from public.circle_members where user_id = v_uid)
  returning * into v_circle;

  if not found then
    raise exception 'not in a circle' using errcode = 'SB404', hint = 'no_circle';
  end if;
  return v_circle;
end $$;

-- App Store requirement (§1). Server-side data goes; local history survives, so
-- the app simply degrades back to solo mode.
-- NOTE: the auth.users row itself needs the service-role admin API — the app calls
-- signOut right after this, and a scheduled admin sweep removes the orphan.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;

  delete from public.nudges            where sender_id = v_uid or recipient_id = v_uid;
  delete from public.devices           where user_id = v_uid;
  delete from public.custom_challenges where created_by = v_uid;
  delete from public.recovery_weeks    where user_id = v_uid;
  delete from public.excused_days      where user_id = v_uid;
  delete from public.posts             where user_id = v_uid;
  delete from public.circle_members    where user_id = v_uid;
  delete from public.profiles          where id = v_uid;
end $$;

-- Returns false (not an error) when this sender already nudged this recipient for
-- this prayer window — "already nudged" is a normal outcome, not a failure.
create or replace function public.record_nudge(p_recipient uuid, p_day_key text, p_prayer public.prayer_kind)
returns boolean
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid       uuid := auth.uid();
  v_circle    uuid;
  v_inserted  int;
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  if p_recipient = v_uid then
    raise exception 'cannot nudge yourself' using errcode = 'SB400';
  end if;

  select circle_id into v_circle from public.circle_members where user_id = v_uid;
  if v_circle is null then
    raise exception 'not in a circle' using errcode = 'SB404', hint = 'no_circle';
  end if;
  if not exists (
    select 1 from public.circle_members where user_id = p_recipient and circle_id = v_circle
  ) then
    raise exception 'recipient is not in your circle' using errcode = 'SB403';
  end if;

  insert into public.nudges (sender_id, recipient_id, day_key, prayer)
  values (v_uid, p_recipient, p_day_key, p_prayer)
  on conflict (sender_id, recipient_id, day_key, prayer) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted > 0;
end $$;

-- Retention (§4). Returns the storage paths it just detached so the caller can
-- delete the objects; clearing the column first means a crashed edge function
-- leaves orphaned bytes, never a post pointing at a deleted photo.
-- Ages off created_at (the server's own clock) — logged_at is client-supplied.
create or replace function public.purge_expired_photo_rows(p_days int default 30)
returns setof text
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_cutoff timestamptz := now() - make_interval(days => greatest(coalesce(p_days, 30), 0));
begin
  -- Nudge rows are rate-limit tokens; once the window is long gone they are litter.
  delete from public.nudges where created_at < now() - interval '30 days';

  -- Someone who left (or deleted their account) leaves these behind with nobody
  -- allowed to read them.
  delete from public.excused_days e
   where not exists (select 1 from public.circle_members m where m.user_id = e.user_id);
  delete from public.recovery_weeks r
   where not exists (select 1 from public.circle_members m where m.user_id = r.user_id);

  return query
    with expired as (
      select id, photo_path from public.posts
       where photo_path is not null and created_at < v_cutoff
    ),
    cleared as (
      update public.posts p
         set photo_path = null
        from expired e
       where p.id = e.id
      returning e.photo_path as path
    )
    select path from cleared;
end $$;

-- The retention function is triggerable by anyone signed in, so the real work is
-- behind a lease: first caller in the interval wins, everybody else gets false.
create or replace function public.claim_retention_run(p_min_interval interval default '1 hour')
returns boolean
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_claimed boolean;
begin
  insert into public.retention_runs (id) values (1) on conflict (id) do nothing;

  update public.retention_runs
     set last_run_at = now()
   where id = 1
     and last_run_at <= now() - coalesce(p_min_interval, interval '1 hour')
  returning true into v_claimed;

  return coalesce(v_claimed, false);
end $$;

-- Grants --------------------------------------------------------------------
-- `from public, anon`: revoking from PUBLIC removes the implicit grant a new
-- function carries, but NOT an explicit one — and a real Supabase project's
-- default privileges on `public` grant execute to anon outright. Both have to go
-- or an unauthenticated caller could reach create_circle with the shipped
-- publishable key (the RPC would refuse it — every one asserts auth.uid() is not
-- null — but a locked door is better than a polite one).
revoke execute on function public.generate_invite_code()                        from public, anon;
revoke execute on function public.create_circle(text, text)                     from public, anon;
revoke execute on function public.join_circle(text)                             from public, anon;
revoke execute on function public.leave_circle()                                from public, anon;
revoke execute on function public.rename_circle(text, text)                     from public, anon;
revoke execute on function public.delete_account()                              from public, anon;
revoke execute on function public.record_nudge(uuid, text, public.prayer_kind)  from public, anon;
revoke execute on function public.purge_expired_photo_rows(int)                 from public, anon, authenticated;
revoke execute on function public.claim_retention_run(interval)                 from public, anon, authenticated;

grant execute on function public.create_circle(text, text)                    to authenticated;
grant execute on function public.join_circle(text)                            to authenticated;
grant execute on function public.leave_circle()                               to authenticated;
grant execute on function public.rename_circle(text, text)                    to authenticated;
grant execute on function public.delete_account()                             to authenticated;
grant execute on function public.record_nudge(uuid, text, public.prayer_kind) to authenticated, service_role;

-- Retention is service_role only — a user session must never be able to wipe photos.
grant execute on function public.purge_expired_photo_rows(int) to service_role;
grant execute on function public.claim_retention_run(interval) to service_role;
