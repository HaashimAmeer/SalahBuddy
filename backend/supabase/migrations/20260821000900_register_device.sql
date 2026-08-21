-- v4 Phase D fix — claiming an APNs token that changed hands.
--
-- `devices.apns_token` is the primary key and one install keeps the same token
-- for its whole life, so the row has to FOLLOW the token when a second person
-- signs in on the same phone. The client did that with
-- `upsert(onConflict: "apns_token")`, which cannot work under `devices_all`
-- (`using user_id = auth.uid()`): ON CONFLICT DO UPDATE evaluates the UPDATE
-- policy's USING clause against the EXISTING row, so a row belonging to the
-- previous account is refused with 42501 — and a plain delete of it is refused
-- for the same reason. Verified against this schema, not assumed.
--
-- The consequence was not "the second user has no push". It was that the FIRST
-- account's row stayed live on a phone somebody else is now holding, so their
-- circle kept pushing "📸 Yusuf posted first for Fajr" to a stranger, and the
-- new user could never register at all. The client's sign-out delete is the
-- happy path; this is the one that has to work when that delete never went out
-- (offline sign-out, a lost response, a restore onto a different account).
--
-- SECURITY DEFINER because reclaiming is precisely the operation RLS is right to
-- refuse a client and wrong to refuse a phone. Deleting by token alone is safe:
-- a device token is a 32-byte value APNs issues to one install, it is not
-- guessable, and whoever can present it is holding the phone it addresses.
create or replace function public.register_device(
  p_token          text,
  p_environment    text default null,
  p_friend_activity boolean default false
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
  insert into public.devices (user_id, apns_token, environment, notify_friend_activity)
  values (v_uid, p_token, coalesce(nullif(btrim(p_environment), ''), 'production'),
          coalesce(p_friend_activity, false));
end $$;

-- `from public` drops the implicit grant every function is born with; `from anon`
-- is separate and necessary, because the project's default privileges on `public`
-- hand out an EXPLICIT grant that survives a revoke aimed at PUBLIC.
revoke execute on function public.register_device(text, text, boolean) from public, anon;
grant  execute on function public.register_device(text, text, boolean) to authenticated;
