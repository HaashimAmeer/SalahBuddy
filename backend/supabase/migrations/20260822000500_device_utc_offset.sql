-- Where the RECIPIENT of a push is standing.
--
-- 20260822000200 recorded the POSTER's zone on every post. This is the other
-- half, and it exists for one concrete bug: `notify` fans "📸 Yusuf posted
-- first for Fajr" out to every member of the circle with no idea what time it
-- is where they are. Post Fajr at 5am in Mumbai and your friend in Seattle is
-- buzzed at 4:30pm, twelve hours after their own Fajr, about a prayer window
-- that closed before lunch. Every push we send is a small withdrawal from the
-- one permission the app has to ask for and can never get back, and this one
-- buys nothing.
--
-- The function cannot judge that without knowing where each device is, so the
-- device row has to say. Seconds, same unit and sign as posts.utc_offset and
-- as Swift's `TimeZone.secondsFromGMT()`, so the two sides are comparable
-- without a conversion anybody could get backwards.
--
-- NULLABLE, AND IT STAYS NULLABLE. Two reasons, and the second is the one that
-- matters:
--   * every devices row written before this migration genuinely has no answer,
--     and inventing one would be a lie the push filter then acts on;
--   * 0 IS A REAL PLACE. London in winter, Reykjavík all year, Accra, Dublin
--     in December. A `not null default 0` would quietly file every unknown
--     device in the UTC+0 bucket and then silence the ones whose real day has
--     not turned over yet. "Unknown" and "Greenwich" must never be the same
--     value.
-- The function reads NULL as "cannot judge, so send" — unknown never means
-- silence. That rule is asserted in tests/deno/zones_test.ts, not just written
-- down here.
alter table public.devices add column if not exists utc_offset int;

-- A live device is somewhere between UTC-12:00 and UTC+14:00. This is not
-- about trust — a signed-in caller holds `update (utc_offset)` on their OWN
-- row and can only ever mute or unmute themselves, which they can already do
-- by deleting the row. It is about a garbage value (milliseconds, minutes,
-- a sign flip) producing a local day years away and then silently filtering a
-- real person out of their circle's pushes forever. ±14h, rounded out to a
-- flat 14 on both sides rather than encoding the exact -12/+14 asymmetry,
-- which is a political fact and not a law.
alter table public.devices drop constraint if exists devices_utc_offset_range;
alter table public.devices add constraint devices_utc_offset_range
  check (utc_offset is null or utc_offset between -50400 and 50400);

comment on column public.devices.utc_offset is
  'The device''s UTC offset in seconds, as of its last registration. Read by '
  'the notify function to decide whether a post''s day_key is still the '
  'recipient''s current local day. Nullable, and it stays nullable: rows '
  'predating 20260822000500 have no answer, and 0 is a real offset (London in '
  'winter), so it can never stand in for "unknown". NULL means "cannot judge" '
  'and is always notified.';

-- Writable by the owner, exactly like the four columns already granted in
-- 20260821000200 — same shape as the `utc_offset` grant 20260822000200 added
-- to posts. `devices_all` (`user_id = auth.uid()`) still scopes it to your own
-- row; this only says which COLUMN of that row you may name.
grant insert (utc_offset), update (utc_offset) on public.devices to authenticated;

-- ---------------------------------------------------------------------------
-- register_device grows the parameter.
--
-- The old three-argument function is DROPPED rather than left beside the new
-- one. Two overloads that differ only by a defaulted trailing parameter make
-- `select register_device('t','production',false)` ambiguous ("function
-- reference is not unique") — the client would start failing on the call it
-- has been making since Phase D. One function, four parameters, the last one
-- defaulted.
--
-- A client that has not shipped the new field yet keeps working untouched:
-- PostgREST resolves an RPC by the argument names present in the body, so a
-- body of {p_token, p_environment, p_friend_activity} still binds here and
-- p_utc_offset defaults to NULL — which the filter reads as "cannot judge,
-- send anyway". An old build loses nothing.
--
-- Editing 20260821000900 in place was never an option: `supabase db push`
-- records applied versions and will not re-run one. This is that migration's
-- successor, and everything it says about reclaiming a token that changed
-- hands still holds — the body below is the same delete-then-insert.
drop function if exists public.register_device(text, text, boolean);

create or replace function public.register_device(
  p_token           text,
  p_environment     text default null,
  p_friend_activity boolean default false,
  p_utc_offset      int default null
) returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in required' using errcode = 'SB401';
  end if;
  if p_token is null or btrim(p_token) = '' then
    raise exception 'a device token is required' using errcode = 'SB400', hint = 'bad_token';
  end if;
  -- An APNs token is 64 hex characters; the bound is generous rather than exact
  -- so a future token format is not an outage, and it exists at all because this
  -- is a text column a signed-in caller writes at will.
  if char_length(p_token) > 200 then
    raise exception 'device token too long' using errcode = 'SB400', hint = 'bad_token';
  end if;

  -- Whoever holds the token owns the row. The old one goes first, so the insert
  -- below is a plain insert and never an upsert against a row RLS would hide.
  delete from public.devices where apns_token = p_token;

  -- `environment` keeps its column CHECK as the authority on the two legal
  -- values — validating it twice is two places to disagree.
  --
  -- An out-of-range offset is COERCED TO NULL here rather than raised. The
  -- check constraint above is the guard for the direct-grant path; on this
  -- path a nonsense offset must not cost the device its whole registration,
  -- because a phone with no `devices` row gets no nudges and no join alerts
  -- either. Degrading to "unknown zone, always notified" loses only the
  -- filtering.
  insert into public.devices (user_id, apns_token, environment,
                              notify_friend_activity, utc_offset)
  values (v_uid, p_token, coalesce(nullif(btrim(p_environment), ''), 'production'),
          coalesce(p_friend_activity, false),
          case when p_utc_offset between -50400 and 50400 then p_utc_offset end);
end $$;

comment on function public.register_device(text, text, boolean, int) is
  'Claims an APNs token for the calling user, whoever held it before, and '
  'records the zone that device is in. SECURITY DEFINER because reclaiming a '
  'row from a previous account is exactly what RLS is right to refuse a client '
  '(see 20260821000900). p_utc_offset is seconds and may be NULL; a value '
  'outside ±14h is stored as NULL rather than refused, so a bad clock costs '
  'push filtering and never push itself.';

-- `from public` drops the implicit grant every function is born with; `from anon`
-- is separate and necessary, because the project's default privileges on `public`
-- hand out an EXPLICIT grant that survives a revoke aimed at PUBLIC.
revoke execute on function public.register_device(text, text, boolean, int) from public, anon;
grant  execute on function public.register_device(text, text, boolean, int) to authenticated;
