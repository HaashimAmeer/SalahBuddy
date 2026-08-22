-- 29. The recipient's zone reaches the devices row, and "unknown" survives
--     the trip (SPEC-V4 §6, migration 20260822000500).
--
-- `notify` decides whether a post's day_key is still the recipient's current
-- local day, and it can only do that if the device row says where the device
-- is. Three things have to hold for that filter to be safe, and all three are
-- easy to break with a well-meaning schema edit:
--
--   * the column is NULLABLE and has no default. 0 is a real offset — London
--     in winter, Reykjavík all year — so a `not null default 0` would file
--     every unknown device in Greenwich and then mute the ones whose real day
--     has not turned over. "Unknown" and "UTC+0" must be different values, and
--     the Deno side reads NULL as "send anyway".
--   * register_device WRITES it, and rewrites it on the next registration.
--     A traveller who lands in Mumbai and keeps a Seattle offset is filtered
--     out of their own circle's pushes.
--   * a garbage offset costs the FILTER, never the REGISTRATION. A phone with
--     no devices row gets no nudges and no join alerts either, so the RPC
--     coerces nonsense to NULL rather than raising.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002901', 'traveller@example.test'),
  ('00000000-0000-0000-0000-000000002902', 'homebody@example.test');

-- (a) The column's shape, asserted from the catalog rather than from the
--     migration text — a later `alter table ... set not null` has to fail here.
do $$
declare
  v_nullable text;
  v_default  text;
  v_type     text;
begin
  select is_nullable, column_default, data_type
    into v_nullable, v_default, v_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'devices'
     and column_name = 'utc_offset';
  if v_nullable is null then
    raise exception 'devices.utc_offset does not exist';
  end if;
  if v_nullable <> 'YES' then
    raise exception 'devices.utc_offset became NOT NULL — unknown is now indistinguishable from UTC+0';
  end if;
  if v_default is not null then
    raise exception 'devices.utc_offset grew a default (%) — an invented zone is worse than none', v_default;
  end if;
  if v_type <> 'integer' then
    raise exception 'devices.utc_offset is %, not seconds-as-integer', v_type;
  end if;
end $$;

set local role authenticated;

-- (b) register_device carries the offset, and a re-registration MOVES it.
do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000002901';
  v_token  text := 'traveller-token';
  v_offset int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_me), true);

  -- Seattle, PDT.
  perform public.register_device(v_token, 'sandbox', true, -25200);
  select utc_offset into v_offset from public.devices where apns_token = v_token;
  if v_offset is distinct from -25200 then
    raise exception 'the device offset did not reach the row (got %)', v_offset;
  end if;

  -- ...and then they fly to Mumbai, foreground the app, and re-register. A
  -- stale offset here is a traveller quietly filtered out of their own circle.
  perform public.register_device(v_token, 'sandbox', true, 19800);
  select utc_offset into v_offset from public.devices where apns_token = v_token;
  if v_offset is distinct from 19800 then
    raise exception 'a re-registration kept the departure zone (got %)', v_offset;
  end if;

  -- A half-hour zone is stored exactly, not rounded to the hour: fifteen
  -- minutes of offset can decide which calendar day a device is on.
  perform public.register_device(v_token, 'sandbox', true, 20700);  -- Kathmandu
  select utc_offset into v_offset from public.devices where apns_token = v_token;
  if v_offset <> 20700 then
    raise exception 'a quarter-hour zone was not stored exactly (got %)', v_offset;
  end if;
end $$;

-- (c) An OLD CLIENT — one that has never heard of the parameter — still
--     registers, and lands with NULL rather than a fabricated zone.
--
--     This is the compatibility promise the drop-and-recreate in
--     20260822000500 has to keep: the three-argument call the app has been
--     making since Phase D must still bind.
do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000002902';
  v_token  text := 'old-build-token';
  v_offset int;
  v_owner  uuid;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_me), true);
  perform public.register_device(v_token, 'production', false);

  set local role postgres;
  select user_id, utc_offset into v_owner, v_offset
    from public.devices where apns_token = v_token;
  set local role authenticated;

  if v_owner is distinct from v_me then
    raise exception 'the three-argument register_device call stopped working';
  end if;
  if v_offset is not null then
    raise exception 'an old client was given a zone it never sent (%)', v_offset;
  end if;
  -- Named arguments, the shape PostgREST actually sends. Same answer.
  perform public.register_device(p_token => v_token, p_environment => 'production',
                                 p_friend_activity => false);
  select utc_offset into v_offset from public.devices where apns_token = v_token;
  if v_offset is not null then
    raise exception 'a named-argument old-client call invented a zone (%)', v_offset;
  end if;
end $$;

-- (d) A broken clock costs the filter, not the registration. And the column's
--     own CHECK still refuses the same value on the direct-grant path.
do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000002902';
  v_token  text := 'bad-clock-token';
  v_offset int;
  v_n      int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_me), true);

  -- Milliseconds instead of seconds, which is the mistake somebody will make.
  perform public.register_device(v_token, 'production', false, -25200000);
  select count(*) into v_n from public.devices where apns_token = v_token;
  if v_n <> 1 then
    raise exception 'a nonsense offset cost the device its whole registration';
  end if;
  select utc_offset into v_offset from public.devices where apns_token = v_token;
  if v_offset is not null then
    raise exception 'an out-of-range offset was stored as % instead of NULL', v_offset;
  end if;

  -- Directly, through the column grant: the CHECK is the guard there.
  begin
    update public.devices set utc_offset = 99999 where apns_token = v_token;
    raise exception 'devices.utc_offset accepted a value no place on earth has';
  exception when check_violation then null;
  end;

  -- ...and a real one lands.
  update public.devices set utc_offset = 0 where apns_token = v_token;
  select utc_offset into v_offset from public.devices where apns_token = v_token;
  if v_offset is distinct from 0 then
    raise exception 'UTC+0 (a real place) was not stored as 0';
  end if;
end $$;

-- (e) Somebody else's row is still somebody else's. The new column does not
--     widen `devices_all`.
do $$
declare
  v_me   uuid := '00000000-0000-0000-0000-000000002901';
  v_n    int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_me), true);
  update public.devices set utc_offset = 12345 where apns_token = 'old-build-token';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'a client rewrote another account''s device zone';
  end if;
end $$;

reset role;

-- (f) The grants and the signature. `anon` holds nothing — the publishable key
--     ships in a public repo — and the OLD three-argument overload is GONE, so
--     `register_device('t','production',false)` can never become ambiguous.
do $$
declare
  v_n int;
begin
  if has_function_privilege('anon',
       'public.register_device(text, text, boolean, int)', 'execute') then
    raise exception 'anon can execute register_device';
  end if;
  if not has_function_privilege('authenticated',
       'public.register_device(text, text, boolean, int)', 'execute') then
    raise exception 'authenticated cannot execute register_device';
  end if;

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'register_device';
  if v_n <> 1 then
    raise exception 'register_device has % overloads — a defaulted trailing '
                    'parameter makes the three-argument call ambiguous', v_n;
  end if;

  if not has_column_privilege('authenticated', 'public.devices', 'utc_offset', 'INSERT') then
    raise exception 'authenticated cannot insert devices.utc_offset';
  end if;
  if not has_column_privilege('authenticated', 'public.devices', 'utc_offset', 'UPDATE') then
    raise exception 'authenticated cannot update devices.utc_offset';
  end if;
  if has_column_privilege('anon', 'public.devices', 'utc_offset', 'INSERT') then
    raise exception 'anon can insert devices.utc_offset';
  end if;
end $$;

rollback;
