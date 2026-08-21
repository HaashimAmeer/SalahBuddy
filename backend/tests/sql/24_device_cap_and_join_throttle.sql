-- 24. Two bounds that keep one ordinary signed-in user from spending the whole
--     project's budget.
--
-- (a) devices: devices_all lets a user insert their own rows and apns_token is
--     the primary key — nothing bounded how many. The push fan-out reads every
--     device of every circle-mate inside ONE Edge Function invocation, so a
--     member with thousands of rows turns their circle's notifications into a
--     guaranteed wall-clock timeout. Prune the oldest rather than raising: a
--     real phone re-registering must never see an error.
--
-- (b) join_circle: 32^6 ≈ 1.07e9 invite codes with no attempt counter, no
--     lockout and no backoff is a keyspace an online guesser walks in an
--     afternoon, and one hit reads a stranger's entire circle. The meter is a
--     SEQUENCE precisely because every failure path here RAISES — and a raise
--     rolls back any table a counter would have written, remembering successes
--     and forgetting exactly the attempts that matter.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002401', 'phones@example.test'),
  ('00000000-0000-0000-0000-000000002402', 'guesser@example.test');

set local role authenticated;

do $$
declare
  v_me uuid := '00000000-0000-0000-0000-000000002401';
  v_n  int;
  i    int;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  for i in 1..40 loop
    insert into public.devices (user_id, apns_token, environment)
    values (v_me, format('token-%s', i), 'production');
  end loop;

  select count(*) into v_n from public.devices where user_id = v_me;
  if v_n > public.max_devices_per_user() then
    raise exception 'one user holds % device rows, cap is %', v_n, public.max_devices_per_user();
  end if;
  -- the newest registration always survives — that is the phone in your hand
  if not exists (select 1 from public.devices where apns_token = 'token-40') then
    raise exception 'the most recent device registration was pruned';
  end if;
end $$;

do $$
declare
  v_guess uuid := '00000000-0000-0000-0000-000000002402';
  v_hit   boolean := false;
  i       int;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_guess), true);

  -- Burn the hour's budget on misses. Each one raises SB404 and rolls back, so
  -- if the meter were a table this loop would leave no trace at all.
  for i in 1..(public.join_attempt_budget() + 5) loop
    begin
      perform public.join_circle('ZZZZZZ');
    exception
      when sqlstate 'SB404' then null;
      when sqlstate 'SB429' then v_hit := true; exit;
    end;
  end loop;

  if not v_hit then
    raise exception 'join_circle never throttled after % failed guesses',
      public.join_attempt_budget() + 5;
  end if;

  -- A well-formed but unknown code and a malformed one are both SB404, so the
  -- error alone stays a poor oracle.
  begin
    perform public.join_circle('!!!!!!');
    raise exception 'a malformed code was not refused';
  exception when sqlstate 'SB404' then null;
  end;
end $$;

rollback;

-- The meter lives outside transactions (that is the entire point), so reset it
-- or every later test in this scratch database starts the hour already spent.
select setval('public.join_attempt_meter', 1, false);
