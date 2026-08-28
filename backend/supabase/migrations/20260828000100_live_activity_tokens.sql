-- v5 §6 (P4) — where a Live Activity's push tokens live.
--
-- ITS OWN TABLE, AND THAT IS THE WHOLE POINT. `devices` is keyed on
-- `apns_token`: one install, one row, for the life of the install (see
-- 20260821000900 — the row FOLLOWS the token when a phone changes hands).
-- ActivityKit's tokens are the opposite kind of thing:
--
--   * a per-activity UPDATE token is minted when an activity starts and is dead
--     the moment it ends — five a day per phone if every window gets one, and
--     ~8h is ActivityKit's own lifetime cap;
--   * a push-to-START token belongs to the app rather than to any activity, but
--     it still rotates, and it is useless to any push type but this one.
--
-- Hanging either off `devices` would mean a column that is NULL for most rows,
-- rewritten five times a day, and whose staleness silently breaks the ordinary
-- alert path when it is cleared wrong. Separate table, separate lifetime,
-- separate cleanup. §6 says exactly this and it is worth restating in the
-- schema: "Live Activity tokens are per-activity and ephemeral — `devices` is
-- keyed on a stable `apns_token`, so this needs its OWN table, not a column."
--
-- Both kinds live here rather than in two tables because they are the same
-- fact ("this phone will accept a liveactivity push at this address") and the
-- fan-out reads them in one query: for each recipient, update what is already
-- running, and start one only where nothing is.

-- How many token rows one account may hold. Ten devices (max_devices_per_user)
-- × one push-to-start token each, plus a window's worth of update tokens, with
-- room to spare — the cap exists so a client that never deletes cannot grow the
-- table without bound, not to ration honest phones.
create or replace function public.max_live_activity_tokens_per_user() returns int
language sql immutable
as $$ select 24 $$;

create table if not exists public.live_activity_tokens (
  -- The APNs address, and the identity of the row: whoever presents the token
  -- owns it, exactly as `devices.apns_token` does. Reclaiming by token is what
  -- makes `register_live_activity_token` safe to call from any account on the
  -- phone that holds it.
  token       text primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  -- 'start' — the app-wide push-to-start token (§6). No activity exists yet, so
  --           it names no window.
  -- 'update' — one running activity's own token.
  kind        text not null check (kind in ('start','update')),
  -- ActivityKit's `Activity.id`, so the app can delete precisely the row for an
  -- activity it just ended. Opaque to the server; never matched on.
  activity_id text,
  -- Which prayer window a running activity is ABOUT. This is what lets the
  -- fan-out skip a push-to-start for a device that already has one — the
  -- "client-assisted" half of the trigger decision recorded in backend/README.md.
  day_key     text check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  prayer      public.prayer_kind,
  -- When the window this activity is about CLOSES, as the device that created
  -- the activity computed it.
  --
  -- This is the one piece of schedule the server is willing to hold, and the
  -- boundary is deliberate: a prayer window's end is derived on-device from
  -- coordinates + calc method + madhab (Adhan), and the backend has no
  -- coordinates and is not getting any. What it accepts here is not a schedule
  -- — it is ONE already-running activity's own end, supplied by the process
  -- that started it, for the window it is already about. It cannot go stale
  -- (an activity is per-window and dies with it) and it buys two things the
  -- fan-out cannot otherwise do honestly: a correct `stale-date` on every
  -- update push, and an `end` push for an activity whose window has closed.
  --
  -- Nullable, and read as "unknown" rather than defaulted: a row written by a
  -- client that did not send it still takes updates, it just gets no stale
  -- date. Never a substitute for the client ending its own activity.
  ends_at     timestamptz,
  environment text not null default 'production'
              check (environment in ('production','sandbox')),
  -- Same unit, sign and range as devices.utc_offset (20260822000500), and read
  -- by the same relevance filter: a liveactivity push is about one prayer
  -- window on one schedule day, so a phone whose local day has moved past it
  -- has nothing to draw.
  utc_offset  int check (utc_offset is null or utc_offset between -50400 and 50400),
  -- SERVER-OWNED, and outside the grant below for the same reason
  -- `posts.created_at` is: it is the retention clock. A client that could push
  -- its own expiry out to 2126 would keep a dead token on the fan-out's books
  -- forever, and every push to it is a wasted round trip to Apple.
  --
  -- Twelve hours, against ActivityKit's ~8h activity cap: generous enough that
  -- a live activity is never swept out from under itself, short enough that a
  -- phone which goes quiet leaves nothing behind by tomorrow.
  expires_at  timestamptz not null default now() + interval '12 hours',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- A start token names no window; an update token must name one. Stated as a
  -- CHECK rather than left to the RPC, because the direct INSERT grant below is
  -- a second door into this table and both have to produce rows the fan-out can
  -- reason about.
  constraint live_activity_tokens_shape check (
    (kind = 'start'  and day_key is null and prayer is null)
    or
    (kind = 'update' and day_key is not null and prayer is not null)
  )
);

-- The three questions asked of this table, in order of how often.
-- (1) "which tokens does this set of recipients have" — the fan-out;
create index if not exists live_activity_tokens_user_idx
  on public.live_activity_tokens (user_id, kind, updated_at desc);
-- (2) "does this person already have an activity for this window" — the
--     push-to-start skip;
create index if not exists live_activity_tokens_window_idx
  on public.live_activity_tokens (user_id, day_key, prayer)
  where kind = 'update';
-- (3) "what is dead" — the sweep.
create index if not exists live_activity_tokens_expiry_idx
  on public.live_activity_tokens (expires_at);

-- updated_at belongs to the trigger, exactly as it does on devices/posts.
drop trigger if exists live_activity_tokens_touch on public.live_activity_tokens;
create trigger live_activity_tokens_touch before update on public.live_activity_tokens
  for each row execute function public.touch_updated_at();

-- Prune the oldest rather than raise, for the reason `enforce_device_cap`
-- documents: a real phone registering a real activity must never see an error,
-- and the cap is there so an account cannot grow the fan-out's read without
-- bound.
create or replace function public.enforce_live_activity_token_cap() returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  delete from public.live_activity_tokens t
   where t.user_id = new.user_id
     and t.token <> new.token
     and t.token in (
       select token from public.live_activity_tokens
        where user_id = new.user_id and token <> new.token
        order by updated_at desc
       offset greatest(public.max_live_activity_tokens_per_user() - 1, 0)
     );
  return new;
end $$;

drop trigger if exists live_activity_tokens_cap on public.live_activity_tokens;
create trigger live_activity_tokens_cap before insert on public.live_activity_tokens
  for each row execute function public.enforce_live_activity_token_cap();

-- RLS + grants ---------------------------------------------------------------
-- A push address is private to its owner. `notify` reads these with the
-- service-role key, never through a user session — same shape as `devices`.
alter table public.live_activity_tokens enable row level security;

drop policy if exists live_activity_tokens_all on public.live_activity_tokens;
create policy live_activity_tokens_all on public.live_activity_tokens
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- REVOKE FIRST. A real Supabase project's default privileges on `public` hand
-- every NEWLY CREATED table all four verbs to anon and authenticated — which is
-- to say this table was born readable by anyone holding the publishable key,
-- and a migration that only refrains from granting leaves it that way. The
-- 20260821000200 wipe ran before this table existed and cannot help it. Test 12
-- walks the whole schema for exactly this mistake; the revoke is what makes it
-- pass honestly rather than by luck.
revoke all on public.live_activity_tokens from public, anon, authenticated;

grant select, delete on public.live_activity_tokens to authenticated;
-- COLUMN-SCOPED, and the three columns left out are the load-bearing ones:
-- expires_at (the sweep's clock — see above), created_at and updated_at.
grant insert (token, user_id, kind, activity_id, day_key, prayer, ends_at,
              environment, utc_offset),
      update (token, user_id, kind, activity_id, day_key, prayer, ends_at,
              environment, utc_offset)
      on public.live_activity_tokens to authenticated;
grant select, insert, update, delete on public.live_activity_tokens to service_role;

revoke execute on function public.max_live_activity_tokens_per_user() from public, anon;
grant  execute on function public.max_live_activity_tokens_per_user()
  to authenticated, service_role;

-- register_live_activity_token ----------------------------------------------
-- The same shape as `register_device` (20260821000900 / 20260822000500), and
-- for the same reason: the token is the primary key, one phone keeps handing us
-- tokens, and the row has to FOLLOW the token when the account on that phone
-- changes. Delete-then-insert, SECURITY DEFINER, because reclaiming a row from
-- a previous account is precisely what RLS is right to refuse a client.
--
-- Whoever presents the token is holding the phone it addresses: an ActivityKit
-- push token is an opaque value Apple minted for one install, it is not
-- guessable, and it is worthless for anything but pushing to that install.
create or replace function public.register_live_activity_token(
  p_token       text,
  p_kind        text,
  p_activity_id text default null,
  p_day_key     text default null,
  p_prayer      public.prayer_kind default null,
  p_ends_at     timestamptz default null,
  p_environment text default null,
  p_utc_offset  int default null
) returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_kind, '')));
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  if p_token is null or btrim(p_token) = '' then
    raise exception 'a push token is required' using errcode = 'SB400', hint = 'bad_token';
  end if;
  -- An ActivityKit token is 64 hex characters today; generous rather than
  -- exact, so a future token format is not an outage — and bounded at all
  -- because this is a text column a signed-in caller writes at will.
  if char_length(p_token) > 400 then
    raise exception 'push token too long' using errcode = 'SB400', hint = 'bad_token';
  end if;
  if v_kind not in ('start', 'update') then
    raise exception 'kind must be start or update'
      using errcode = 'SB400', hint = 'bad_kind';
  end if;
  -- An update token that names no window is a row the fan-out cannot use and
  -- the shape CHECK would refuse anyway; say so in the app's own vocabulary
  -- rather than letting it surface as a constraint violation.
  if v_kind = 'update' and (p_day_key is null or p_prayer is null) then
    raise exception 'an activity token must name its window'
      using errcode = 'SB400', hint = 'bad_window';
  end if;
  if v_kind = 'start' and (p_day_key is not null or p_prayer is not null) then
    raise exception 'a push-to-start token names no window'
      using errcode = 'SB400', hint = 'bad_window';
  end if;

  -- Whoever holds the token owns the row.
  delete from public.live_activity_tokens where token = p_token;

  -- One running activity per (person, window): a phone that restarts an
  -- activity for the same prayer mints a NEW token, and the old row would
  -- otherwise sit here until it expired, taking a push per post with it.
  if v_kind = 'update' then
    delete from public.live_activity_tokens
     where user_id = v_uid and kind = 'update'
       and day_key = p_day_key and prayer = p_prayer;
  end if;

  insert into public.live_activity_tokens
    (token, user_id, kind, activity_id, day_key, prayer, ends_at,
     environment, utc_offset)
  values
    (p_token, v_uid, v_kind,
     nullif(btrim(coalesce(p_activity_id, '')), ''),
     case when v_kind = 'update' then p_day_key end,
     case when v_kind = 'update' then p_prayer end,
     -- Only an activity has an end; a push-to-start token is not about a window
     -- (see the column comment, and backend/README.md's trigger note).
     case when v_kind = 'update' then p_ends_at end,
     coalesce(nullif(btrim(p_environment), ''), 'production'),
     -- Out of range is stored as NULL rather than refused, exactly as
     -- register_device does it: a bad clock costs push FILTERING, never push.
     case when p_utc_offset between -50400 and 50400 then p_utc_offset end);
end $$;

comment on function public.register_live_activity_token(text, text, text, text,
                                                        public.prayer_kind, timestamptz,
                                                        text, int) is
  'Claims an ActivityKit push token for the calling user, whoever held it '
  'before. SECURITY DEFINER for the same reason register_device is: the token '
  'is the primary key and the row must follow it when the account on a phone '
  'changes. kind is start (push-to-start, names no window) or update (one '
  'running activity, names its window).';

revoke execute on function public.register_live_activity_token(text, text, text, text,
                                                               public.prayer_kind, timestamptz,
                                                               text, int)
  from public, anon;
grant  execute on function public.register_live_activity_token(text, text, text, text,
                                                               public.prayer_kind, timestamptz,
                                                               text, int)
  to authenticated;

-- The sweep ------------------------------------------------------------------
-- Two clocks close a token, and both matter:
--
--   * WINDOW CLOSE is the client's job and the fast path — the app ends the
--     activity when the window ends and DELETEs its own row (the policy above
--     scopes that to its own rows, so no RPC is needed).
--   * EXPIRY is the backstop, for every phone that never came back: uninstalled,
--     out of battery, signed out offline, or simply killed mid-window. Without
--     it the table is append-only and the fan-out slowly pays for phones that
--     stopped listening months ago.
--
-- service_role ONLY, like every other retention function. Called by the
-- `retention` edge function on the nightly cron (.github/workflows/maintenance.yml).
create or replace function public.purge_expired_live_activity_tokens()
returns int
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_removed int;
begin
  delete from public.live_activity_tokens where expires_at < now();
  get diagnostics v_removed = row_count;
  return v_removed;
end $$;

revoke execute on function public.purge_expired_live_activity_tokens()
  from public, anon, authenticated;
grant  execute on function public.purge_expired_live_activity_tokens() to service_role;

-- delete_account -------------------------------------------------------------
-- It enumerates tables by hand (20260821000400) and does NOT delete the
-- auth.users row, so `on delete cascade` above does not cover it: without this
-- replacement a deleted account leaves live push addresses on the books, and
-- the circle it left keeps paying to push to them until they expire. Same body
-- as 20260821000400's, plus one line — a new file rather than an edit, because
-- `supabase db push` records applied versions and will not re-run one.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;

  delete from public.live_activity_tokens where user_id = v_uid;
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

revoke execute on function public.delete_account() from public, anon;
grant  execute on function public.delete_account() to authenticated;
