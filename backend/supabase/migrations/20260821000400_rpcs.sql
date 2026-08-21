-- v4 Phase A — RPCs.
--
-- Every function here is SECURITY DEFINER with a pinned search_path, is revoked
-- from public/anon, and starts by asserting there is a signed-in caller. They
-- exist because these operations need to be atomic (circle + code + membership)
-- or need to see rows RLS would hide.
--
-- SQLSTATEs the client switches on:
--   SB401 not signed in · SB404 no such circle · SB409 circle full · SB410 already in a circle
--   SB429 too many join attempts right now

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

-- How many join attempts the whole project may make in one clock hour.
-- Real load is a handful a day (a circle of 8 needs 7 joins, ever), so this is
-- ~100× headroom for humans and a hard ceiling for a guesser.
create or replace function public.join_attempt_budget() returns int
language sql immutable
as $$ select 500 $$;

-- Charges one attempt against the current hour and returns the running count.
--
-- The counter lives in a SEQUENCE, which looks odd until you notice that every
-- interesting outcome of join_circle() — unknown code, full, already a member —
-- RAISES, and a raise rolls the PostgREST transaction back. A table-backed
-- counter would therefore remember successes and forget every failed guess,
-- which is precisely backwards. nextval/setval are the only writes Postgres does
-- not roll back, so they are the only honest way to count a failure.
--
-- The value is (hour_slot * 1e6 + attempts_this_hour): one number carrying both
-- the window and the count, so the window rolls over on its own with no cron row
-- to maintain and nothing to reset if the retention job never runs.
--
-- Known trade-off: the budget is GLOBAL, so a determined attacker can spend it
-- and make joins fail for everyone until the hour turns. That is a loud,
-- self-healing, hour-long annoyance; the alternative it replaces is a silent
-- 2^30 keyspace walkable in an afternoon. Per-user accounting is not available
-- here for the rollback reason above — it needs a caller that can commit
-- between attempts (an Edge Function), which is a Phase D conversation.
create or replace function public.charge_join_attempt() returns int
language plpgsql volatile set search_path = public, pg_temp
as $$
declare
  v_slot bigint := floor(extract(epoch from clock_timestamp()) / 3600)::bigint;
  v_val  bigint := nextval('public.join_attempt_meter');
begin
  if (v_val / 1000000) <> v_slot then
    perform setval('public.join_attempt_meter', v_slot * 1000000 + 1, true);
    return 1;
  end if;
  return (v_val % 1000000)::int;
end $$;

create or replace function public.join_circle(p_code text)
returns public.circles
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_circle public.circles;
  v_code   text := upper(btrim(coalesce(p_code, '')));
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  if exists (select 1 from public.circle_members where user_id = v_uid) then
    raise exception 'already in a circle' using errcode = 'SB410', hint = 'already_member';
  end if;

  -- Shape first, and before the meter: a blank or malformed code is a UI slip,
  -- not a guess, and it must never reach the lookup. Before the code column got
  -- its CHECK an empty string was a legal code, which made `join('')` land the
  -- caller in whichever circle had claimed it.
  if v_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' then
    raise exception 'no circle with that code' using errcode = 'SB404', hint = 'unknown_code';
  end if;

  if public.charge_join_attempt() > public.join_attempt_budget() then
    raise exception 'too many join attempts — try again shortly'
      using errcode = 'SB429', hint = 'join_throttled';
  end if;

  select * into v_circle from public.circles where code = v_code;
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
--
-- The photos go too, which is the part that used to be a lie: deleting the posts
-- destroys the only record of their Storage paths, so the objects would survive
-- in `prayer-photos` forever, unreachable by the retention sweep and readable by
-- every remaining member of the circle. The AFTER DELETE trigger on posts
-- tombstones each path first (see the triggers migration); the tombstone hides
-- the object from the read policy immediately and the sweep removes the bytes.
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
  delete from public.posts             where user_id = v_uid;   -- tombstones the photos
  delete from public.circle_members    where user_id = v_uid;
  delete from public.circle_departures where user_id = v_uid;   -- nothing left to purge
  delete from public.profiles          where id = v_uid;
end $$;

-- Returns false (not an error) when this sender already nudged this recipient for
-- this prayer window — "already nudged" is a normal outcome, not a failure.
--
-- Two limits, because the primary key alone is not one. day_key is the client's
-- schedule day and therefore attacker-controlled: incrementing it walks ~18M
-- fresh primary keys (10,000 years × 5 prayers) against a single recipient, each
-- one a real push. So the key is bounded to ±1 day of the server's own date
-- (which covers every real timezone offset, §7's same-city assumption included),
-- and a sender's hourly total is capped. Both use now(), never the body.
create or replace function public.nudge_hourly_cap() returns int
language sql immutable
as $$ select 10 $$;

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

  if p_day_key is null
     or p_day_key not between to_char((now() - interval '1 day') at time zone 'utc', 'YYYY-MM-DD')
                          and to_char((now() + interval '1 day') at time zone 'utc', 'YYYY-MM-DD') then
    raise exception 'day_key is outside the current prayer window'
      using errcode = 'SB400', hint = 'stale_day_key';
  end if;

  -- Over the cap is "not sent", not an error: the caller renders the same
  -- "already nudged" state, and returning normally is also what lets this row
  -- count — a raise here would roll the attempt back with it.
  if (select count(*) from public.nudges
       where sender_id = v_uid and created_at > now() - interval '1 hour')
     >= public.nudge_hourly_cap() then
    return false;
  end if;

  insert into public.nudges (sender_id, recipient_id, day_key, prayer)
  values (v_uid, p_recipient, p_day_key, p_prayer)
  on conflict (sender_id, recipient_id, day_key, prayer) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted > 0;
end $$;

-- How long a departed member's week stays visible before it is purged. §2 says
-- "until the week ends"; seven days from the departure is that, without the
-- server ever having to derive a week boundary in the member's local timezone.
create or replace function public.departure_grace_days() returns int
language sql immutable
as $$ select 7 $$;

-- Retention (§4). One sweep, four jobs:
--   1. age photos off posts that are still live,
--   2. purge what a departed member left behind, once the grace window closes,
--   3. drop litter (stale nudge tokens, empty circles, ownerless rows),
--   4. hand back a bounded batch of Storage paths for the caller to delete.
--
-- The paths come from public.photo_tombstones, not from the UPDATE that cleared
-- them. That indirection is the whole point: returning a path in the same
-- committed statement that erases it means a Storage delete which fails, or an
-- Edge Function killed by the wall clock mid-loop, loses the path forever and
-- strands a private JPEG in the bucket with nothing left that can name it. A
-- tombstone survives the failure, so the next run simply picks it up again; the
-- caller confirms with confirm_photo_deletions() only once Storage said yes.
--
-- p_limit bounds a run so the first sweep after a long gap cannot return an
-- unbounded path set and guarantee the timeout it was meant to avoid.
-- Ages off created_at (the server's own clock, pinned by freeze_created_at) —
-- logged_at is client-supplied and never used for retention.
create or replace function public.purge_expired_photo_rows(p_days int default 30,
                                                           p_limit int default 500)
returns setof text
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_cutoff    timestamptz := now() - make_interval(days => greatest(coalesce(p_days, 30), 0));
  v_departed  timestamptz := now() - make_interval(days => public.departure_grace_days());
  v_orphaned  timestamptz := now() - interval '30 days';
begin
  -- Nudge rows are rate-limit tokens; once the window is long gone they are litter.
  delete from public.nudges where created_at < now() - interval '30 days';

  -- 2. A departed member's week (§2/§4). The posts trigger tombstones their
  -- photos on the way out, so this covers the bytes as well as the rows.
  delete from public.posts p
   using public.circle_departures d
   where p.user_id = d.user_id and p.circle_id = d.circle_id and d.left_at < v_departed;
  delete from public.excused_days e
   using public.circle_departures d
   where e.user_id = d.user_id and e.circle_id = d.circle_id and d.left_at < v_departed;
  delete from public.recovery_weeks r
   using public.circle_departures d
   where r.user_id = d.user_id and r.circle_id = d.circle_id and d.left_at < v_departed;
  delete from public.custom_challenges c
   using public.circle_departures d
   where c.created_by = d.user_id and c.circle_id = d.circle_id and d.left_at < v_departed;
  delete from public.circle_departures where left_at < v_orphaned;

  -- 3a. Rows whose owner is not in that circle and never recorded a departure
  -- (a pre-departure-table leaver, or a membership deleted out from under them).
  -- Scoped to the row's OWN circle: "is this user in *a* circle" would let a
  -- member who moved from A to B keep rendering resting days to circle A
  -- forever. Aged, because the same predicate fires the instant someone leaves,
  -- and a leaver whose excused days vanish while their posts remain turns a
  -- gentle "resting" into a wall of plain misses — the exact shaming outcome
  -- period privacy exists to prevent.
  delete from public.excused_days e
   where e.created_at < v_orphaned
     and not exists (select 1 from public.circle_members m
                      where m.user_id = e.user_id and m.circle_id = e.circle_id);
  delete from public.recovery_weeks r
   where r.updated_at < v_orphaned
     and not exists (select 1 from public.circle_members m
                      where m.user_id = r.user_id and m.circle_id = r.circle_id);

  -- 3b. A circle everybody left keeps its invite code alive against the code
  -- space forever, and cascades away cleanly (tombstoning its photos as it goes).
  delete from public.circles c
   where c.created_at < v_departed
     and not exists (select 1 from public.circle_members m where m.circle_id = c.id);

  -- 1. Age photos off live posts. The UPDATE fires the tombstone trigger, so the
  -- paths land in photo_tombstones with everything else awaiting deletion.
  update public.posts p
     set photo_path = null
   where p.photo_path is not null and p.created_at < v_cutoff;

  -- 4. Hand back a bounded batch. Oldest first so a backlog drains in order.
  return query
    select t.path from public.photo_tombstones t
     order by t.created_at
     limit greatest(coalesce(p_limit, 500), 1);
end $$;

-- Called once Storage has actually accepted the delete. Until this runs the path
-- stays on the list and the next sweep retries it — which is what makes a
-- half-finished sweep resumable instead of lossy.
create or replace function public.confirm_photo_deletions(p_paths text[])
returns int
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_removed int;
begin
  if p_paths is null or array_length(p_paths, 1) is null then
    return 0;
  end if;
  delete from public.photo_tombstones where path = any(p_paths);
  get diagnostics v_removed = row_count;
  return v_removed;
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
revoke execute on function public.charge_join_attempt()                         from public, anon, authenticated;
revoke execute on function public.join_attempt_budget()                         from public, anon;
revoke execute on function public.nudge_hourly_cap()                            from public, anon;
revoke execute on function public.departure_grace_days()                        from public, anon;
revoke execute on function public.create_circle(text, text)                     from public, anon;
revoke execute on function public.join_circle(text)                             from public, anon;
revoke execute on function public.leave_circle()                                from public, anon;
revoke execute on function public.rename_circle(text, text)                     from public, anon;
revoke execute on function public.delete_account()                              from public, anon;
revoke execute on function public.record_nudge(uuid, text, public.prayer_kind)  from public, anon;
revoke execute on function public.purge_expired_photo_rows(int, int)            from public, anon, authenticated;
revoke execute on function public.confirm_photo_deletions(text[])               from public, anon, authenticated;
revoke execute on function public.claim_retention_run(interval)                 from public, anon, authenticated;

grant execute on function public.create_circle(text, text)                    to authenticated;
grant execute on function public.join_circle(text)                            to authenticated;
grant execute on function public.leave_circle()                               to authenticated;
grant execute on function public.rename_circle(text, text)                    to authenticated;
grant execute on function public.delete_account()                             to authenticated;
grant execute on function public.record_nudge(uuid, text, public.prayer_kind) to authenticated, service_role;

-- Retention is service_role only — a user session must never be able to wipe photos.
grant execute on function public.purge_expired_photo_rows(int, int) to service_role;
grant execute on function public.confirm_photo_deletions(text[])    to service_role;
grant execute on function public.claim_retention_run(interval)      to service_role;
