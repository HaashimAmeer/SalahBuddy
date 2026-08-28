-- 30. Live Activity push tokens (SPEC-V5 §6, P4).
--
--     `devices` is keyed on a STABLE apns_token — one install, one row, for the
--     life of the install. ActivityKit's tokens are the opposite: an update
--     token dies with its activity (~8h at the outside, five a day if every
--     prayer window gets one) and a push-to-start token rotates under the app.
--     They therefore live in their own table, and this file pins the four
--     things that makes true rather than merely stated:
--
--       (a) a push address is private to its owner — invisible AND undeletable
--           from another account, even though the token is the primary key;
--       (b) the RPC reclaims a token that changed hands, and retires the stale
--           address of an activity whose token ROTATED — without ever
--           unsubscribing a second phone that has its own activity for the same
--           window;
--       (c) the shape holds from BOTH doors — the RPC and the direct grant —
--           because a row that names no window is a row the fan-out cannot use;
--       (d) the cleanup story is real: expiry is server-owned, the sweep
--           collects it, and deleting an account takes its tokens with it.
--
--     (d) is the one worth being loudest about. delete_account() enumerates
--     tables by hand and does not delete the auth.users row, so `on delete
--     cascade` covers nothing here: without the replacement in 20260828000200 a
--     deleted account would leave live push addresses behind, and the circle it
--     left would keep paying to push to a phone whose owner asked to be gone.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000003001', 'holder@example.test'),
  ('00000000-0000-0000-0000-000000003002', 'nextowner@example.test');

set local role authenticated;

-- (a) One person's token is another person's nothing. -------------------------
do $$
declare
  v_one uuid := '00000000-0000-0000-0000-000000003001';
  v_two uuid := '00000000-0000-0000-0000-000000003002';
  v_n   int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_one), true);
  insert into public.live_activity_tokens (token, user_id, kind)
  values ('start-one', v_one, 'start');

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_two), true);

  select count(*) into v_n from public.live_activity_tokens where token = 'start-one';
  if v_n <> 0 then
    raise exception 'another account can read a push token that is not theirs';
  end if;

  delete from public.live_activity_tokens where token = 'start-one';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'another account deleted a push token that is not theirs';
  end if;

  -- ...and cannot write one in somebody else's name either.
  begin
    insert into public.live_activity_tokens (token, user_id, kind)
    values ('start-forged', v_one, 'start');
    raise exception 'a client registered a push token for another account';
  exception when insufficient_privilege then null;
  end;
end $$;

-- (b) The token changes hands; the row follows it. ----------------------------
do $$
declare
  v_one   uuid := '00000000-0000-0000-0000-000000003001';
  v_two   uuid := '00000000-0000-0000-0000-000000003002';
  v_owner uuid;
  v_n     int;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_two), true);
  perform public.register_live_activity_token('start-one', 'start', null, null, null,
                                              null, 'sandbox', -25200);

  reset role;
  select count(*) into v_n from public.live_activity_tokens where token = 'start-one';
  select user_id into v_owner from public.live_activity_tokens where token = 'start-one';
  set local role authenticated;
  if v_n <> 1 then
    raise exception 'one token, one row — found % for the same token', v_n;
  end if;
  if v_owner <> v_two then
    raise exception 'the reclaimed token still belongs to the previous account';
  end if;
end $$;

-- ...one ADDRESS per activity — and one activity per phone, not per account. ---
--
-- The distinction this block exists for: the row is retired by ACTIVITY, never
-- by (user, window). Scoping it to the window reads as tidier and silently
-- breaks the second phone on an account — its activity keeps running, stops
-- receiving every later fan-out, and freezes on whatever it last showed, with
-- ActivityKit reporting nothing to anybody.
do $$
declare
  v_two uuid := '00000000-0000-0000-0000-000000003002';
  v_n   int;
  v_tok text;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_two), true);
  -- ActivityKit rotates a RUNNING activity's push token: same `Activity.id`, new
  -- address. The old row is a dead address for a live activity and would take a
  -- push per post with it until it expired.
  perform public.register_live_activity_token('act-asr-a', 'update', 'A1',
                                              '2026-08-28', 'asr',
                                              now() + interval '2 hours',
                                              'sandbox', -25200);
  perform public.register_live_activity_token('act-asr-rotated', 'update', 'A1',
                                              '2026-08-28', 'asr',
                                              now() + interval '2 hours',
                                              'sandbox', -25200);

  select count(*) into v_n from public.live_activity_tokens
   where kind = 'update' and activity_id = 'A1';
  if v_n <> 1 then
    raise exception 'one activity kept % addresses after a token rotation', v_n;
  end if;
  select token into v_tok from public.live_activity_tokens
   where kind = 'update' and activity_id = 'A1';
  if v_tok <> 'act-asr-rotated' then
    raise exception 'the surviving activity token is the stale one (%)', v_tok;
  end if;

  -- THE SECOND PHONE. Same account, same window, its own activity — and it must
  -- still be there. `max_devices_per_user()` is ten and this table's cap is 24
  -- precisely to allow it, so a registration that unsubscribed a sibling device
  -- would be the schema contradicting itself.
  perform public.register_live_activity_token('act-asr-phone2', 'update', 'A2',
                                              '2026-08-28', 'asr',
                                              now() + interval '2 hours',
                                              'sandbox', -25200);
  select count(*) into v_n from public.live_activity_tokens
   where kind = 'update' and day_key = '2026-08-28' and prayer = 'asr';
  if v_n <> 2 then
    raise exception
      'a second device''s activity for the same window did not survive (found %)', v_n;
  end if;

  -- A DIFFERENT window is a different activity and must survive too.
  perform public.register_live_activity_token('act-isha', 'update', 'B1',
                                              '2026-08-28', 'isha',
                                              now() + interval '6 hours',
                                              'sandbox', -25200);
  select count(*) into v_n from public.live_activity_tokens
   where kind = 'update' and prayer = 'isha';
  if v_n <> 1 then
    raise exception 'registering one window''s activity took another window with it';
  end if;

  -- The activity's own end is kept (it is what a correct `stale-date` and an
  -- `end` push are built from) and a push-to-start token never gets one — the
  -- server holds one running activity's boundary, never a schedule.
  select count(*) into v_n from public.live_activity_tokens
   where token = 'act-asr-rotated' and ends_at is not null;
  if v_n <> 1 then
    raise exception 'an activity registered without keeping its window end';
  end if;
  select count(*) into v_n from public.live_activity_tokens
   where kind = 'start' and ends_at is not null;
  if v_n <> 0 then
    raise exception 'a push-to-start token was given a window end';
  end if;
end $$;

-- (c) The shape holds from both doors. ----------------------------------------
do $$
declare
  v_two uuid := '00000000-0000-0000-0000-000000003002';
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_two), true);

  -- An update token that names no window is a row the fan-out cannot use.
  begin
    perform public.register_live_activity_token('act-nowindow', 'update', null, null, null,
                                                null, 'sandbox', 0);
    raise exception 'an activity token was registered without a window';
  exception when sqlstate 'SB400' then null;
  end;

  -- A push-to-start token belongs to the APP, not to a window.
  begin
    perform public.register_live_activity_token('start-window', 'start', null,
                                                '2026-08-28', 'asr', null, 'sandbox', 0);
    raise exception 'a push-to-start token was allowed to name a window';
  exception when sqlstate 'SB400' then null;
  end;

  begin
    perform public.register_live_activity_token('act-bogus', 'sideways', null, null, null,
                                                null, 'sandbox', 0);
    raise exception 'an unknown token kind was accepted';
  exception when sqlstate 'SB400' then null;
  end;

  -- The direct INSERT grant is the second door, and the CHECK is what makes it
  -- as safe as the RPC.
  begin
    insert into public.live_activity_tokens (token, user_id, kind, day_key)
    values ('direct-halfwindow', v_two, 'update', '2026-08-28');
    raise exception 'a half-specified window got past the shape check';
  exception when check_violation then null;
  end;

  -- expires_at is the sweep's clock and is server-owned: a client that could
  -- push it out to 2126 would park a dead token on the fan-out's books forever.
  begin
    insert into public.live_activity_tokens (token, user_id, kind, expires_at)
    values ('direct-immortal', v_two, 'start', now() + interval '100 years');
    raise exception 'a client set its own token expiry';
  exception when insufficient_privilege then null;
  end;
end $$;

-- (d) The cleanup story. ------------------------------------------------------
reset role;

-- An expired row is swept; a live one is not. The sweep is service_role's, and
-- test 12 pins that a user session cannot reach it.
do $$
declare
  v_two     uuid := '00000000-0000-0000-0000-000000003002';
  v_removed int;
  v_n       int;
begin
  insert into public.live_activity_tokens (token, user_id, kind, expires_at)
  values ('act-dead', v_two, 'start', now() - interval '1 minute');

  v_removed := public.purge_expired_live_activity_tokens();
  if v_removed <> 1 then
    raise exception 'the sweep removed % rows, expected exactly the dead one', v_removed;
  end if;
  select count(*) into v_n from public.live_activity_tokens where token = 'act-dead';
  if v_n <> 0 then
    raise exception 'an expired token survived the sweep';
  end if;
  select count(*) into v_n from public.live_activity_tokens where token = 'act-isha';
  if v_n <> 1 then
    raise exception 'the sweep took a live activity with it';
  end if;
end $$;

-- The cap prunes the oldest instead of refusing a real phone.
do $$
declare
  v_one uuid := '00000000-0000-0000-0000-000000003001';
  v_cap int := public.max_live_activity_tokens_per_user();
  v_n   int;
  i     int;
begin
  for i in 1..(v_cap + 3) loop
    insert into public.live_activity_tokens (token, user_id, kind, updated_at)
    values (format('cap-%s', i), v_one, 'start', now() + make_interval(secs => i));
  end loop;
  select count(*) into v_n from public.live_activity_tokens where user_id = v_one;
  if v_n > v_cap then
    raise exception 'one account holds % token rows against a cap of %', v_n, v_cap;
  end if;
  -- The newest survived, which is the half that matters: a phone that has just
  -- registered must not be the one pruned.
  select count(*) into v_n from public.live_activity_tokens
   where user_id = v_one and token = format('cap-%s', v_cap + 3);
  if v_n <> 1 then
    raise exception 'the cap pruned the registration that had just arrived';
  end if;
end $$;

-- Deleting the account takes its push addresses with it. `on delete cascade`
-- does NOT cover this: delete_account() enumerates tables by hand and leaves
-- auth.users alone.
do $$
declare
  v_two uuid := '00000000-0000-0000-0000-000000003002';
  v_n   int;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_two), true);
  perform public.delete_account();
  reset role;

  select count(*) into v_n from public.live_activity_tokens where user_id = v_two;
  if v_n <> 0 then
    raise exception
      'a deleted account left % live push tokens behind', v_n;
  end if;
end $$;

rollback;
