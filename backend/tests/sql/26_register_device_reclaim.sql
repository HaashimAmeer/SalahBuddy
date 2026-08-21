-- 26. An APNs token that changes hands, and the row that must change with it
--     (SPEC-V4 §6).
--
-- `devices.apns_token` is the primary key and one install keeps the same token
-- for its whole life, so when a second person signs in on the same phone the row
-- has to follow the token. The obvious client shape —
-- `upsert(onConflict: "apns_token")` — CANNOT do that under `devices_all`
-- (`using user_id = auth.uid()`), and the first half of this test pins why: ON
-- CONFLICT DO UPDATE evaluates the UPDATE policy's USING clause against the
-- EXISTING row, so the previous account's row is a 42501, and a plain delete of
-- it is refused for the same reason.
--
-- What that left behind was not "the new user has no push". It was the FIRST
-- account's row still live on a phone somebody else is now holding — their
-- circle pushing a friend's name and prayer to a stranger — with no path for
-- either side to clean it up. `register_device()` is the reclaim, and the second
-- half asserts it does exactly one thing: the token addresses one row, owned by
-- whoever is holding the phone.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002601', 'first@example.test'),
  ('00000000-0000-0000-0000-000000002602', 'second@example.test');

set local role authenticated;

-- (a) The client-side upsert is refused, both ways round. This is the WHY.
do $$
declare
  v_first  uuid := '00000000-0000-0000-0000-000000002601';
  v_second uuid := '00000000-0000-0000-0000-000000002602';
  v_token  text := 'aaaa1111';
  v_n      int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_first), true);
  insert into public.devices (user_id, apns_token, environment, notify_friend_activity)
  values (v_first, v_token, 'sandbox', true);

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_second), true);
  begin
    insert into public.devices (user_id, apns_token, environment, notify_friend_activity)
    values (v_second, v_token, 'sandbox', false)
    on conflict (apns_token) do update
      set user_id = excluded.user_id,
          environment = excluded.environment,
          notify_friend_activity = excluded.notify_friend_activity;
    raise exception 'a client upsert took over another account''s device row';
  exception when insufficient_privilege then null;
  end;

  delete from public.devices where apns_token = v_token;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'a client deleted another account''s device row directly';
  end if;
end $$;

-- (b) The RPC reclaims it: one row, the new owner's, with the new owner's
--     environment and toggle.
do $$
declare
  v_first  uuid := '00000000-0000-0000-0000-000000002601';
  v_second uuid := '00000000-0000-0000-0000-000000002602';
  v_token  text := 'aaaa1111';
  v_owner  uuid;
  v_env    text;
  v_flag   boolean;
  v_n      int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_second), true);
  perform public.register_device(v_token, 'production', false);

  select count(*) into v_n from public.devices where apns_token = v_token;
  if v_n <> 1 then
    raise exception 'one phone, one row — found % for the same token', v_n;
  end if;

  set local role postgres;
  select user_id, environment, notify_friend_activity
    into v_owner, v_env, v_flag
    from public.devices where apns_token = v_token;
  set local role authenticated;

  if v_owner <> v_second then
    raise exception 'the reclaimed row still belongs to the previous account';
  end if;
  if v_env <> 'production' or v_flag then
    raise exception 'the reclaimed row kept the previous account''s settings';
  end if;
  if exists (select 1 from public.devices where user_id = v_first) then
    raise exception 'the previous account still has a device row on this phone';
  end if;
end $$;

-- (c) Re-registering the same phone is idempotent, and the toggle it carries is
--     the one the server fans out on — so flipping it has to land.
do $$
declare
  v_second uuid := '00000000-0000-0000-0000-000000002602';
  v_token  text := 'aaaa1111';
  v_flag   boolean;
  v_n      int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_second), true);
  perform public.register_device(v_token, 'production', true);

  select count(*) into v_n from public.devices where user_id = v_second;
  if v_n <> 1 then
    raise exception 're-registering the same token left % rows', v_n;
  end if;
  select notify_friend_activity into v_flag
    from public.devices where apns_token = v_token;
  if not v_flag then
    raise exception 'the friend-activity toggle did not reach the device row';
  end if;
end $$;

-- (d) The refusals: no session, no token, and the environment CHECK still rules.
do $$
declare
  v_second uuid := '00000000-0000-0000-0000-000000002602';
begin
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  begin
    perform public.register_device('bbbb2222', 'production', false);
    raise exception 'register_device accepted a caller with no session';
  exception when sqlstate 'SB401' then null;
  end;

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_second), true);
  begin
    perform public.register_device('   ', 'production', false);
    raise exception 'register_device accepted an empty token';
  exception when sqlstate 'SB400' then null;
  end;

  begin
    perform public.register_device('cccc3333', 'somewhere-else', false);
    raise exception 'register_device accepted an unknown APNs environment';
  exception when check_violation then null;
  end;
end $$;

reset role;

-- (e) anon holds nothing. The publishable key ships in a public repo, so every
--     RPC has to be closed to it explicitly — the project's default privileges
--     on `public` hand out an EXPLICIT grant that a revoke aimed at PUBLIC does
--     not remove.
do $$
begin
  if has_function_privilege('anon', 'public.register_device(text, text, boolean)', 'execute') then
    raise exception 'anon can execute register_device';
  end if;
  if not has_function_privilege('authenticated',
                                'public.register_device(text, text, boolean)', 'execute') then
    raise exception 'authenticated cannot execute register_device';
  end if;
end $$;

rollback;
