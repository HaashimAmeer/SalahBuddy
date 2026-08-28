-- 9. record_nudge is its own rate limit: true the first time, false after.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000701', 'nudger@example.test'),
  ('00000000-0000-0000-0000-000000000702', 'nudged@example.test'),
  ('00000000-0000-0000-0000-000000000703', 'outsider@example.test');

set local role authenticated;

-- The day keys are DERIVED, never written down. record_nudge() bounds day_key
-- to ±1 day of the server's own UTC date (an unbounded one is ~18M fresh
-- primary keys against one circle-mate, each a real push), so a hard-coded date
-- in here is a time bomb: it passes on the day it is written and starts failing
-- 48 hours later, in CI, for a reason that has nothing to do with the change
-- that ran it. It went off once already.
do $$
declare
  v_from     uuid := '00000000-0000-0000-0000-000000000701';
  v_to       uuid := '00000000-0000-0000-0000-000000000702';
  v_out      uuid := '00000000-0000-0000-0000-000000000703';
  v_code     text;
  v_today    text := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
  v_tomorrow text := to_char((now() + interval '1 day') at time zone 'utc', 'YYYY-MM-DD');
  v_stale    text := to_char((now() - interval '9 days') at time zone 'utc', 'YYYY-MM-DD');
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_from), true);
  select code into v_code from public.create_circle('Nudges', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_to), true);
  perform public.join_circle(v_code);

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_out), true);
  perform public.create_circle('Elsewhere', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_from), true);

  if public.record_nudge(v_to, v_today, 'asr') is not true then
    raise exception 'the first nudge was not recorded';
  end if;
  if public.record_nudge(v_to, v_today, 'asr') is not false then
    raise exception 'the second nudge in the same window was not rate limited';
  end if;

  -- a different prayer window opens a fresh allowance
  if public.record_nudge(v_to, v_today, 'maghrib') is not true then
    raise exception 'the next prayer window should allow a nudge';
  end if;
  -- tomorrow is the far edge of the ±1 day window, and still legal: a
  -- circle-mate east of the poster is genuinely already on it.
  if public.record_nudge(v_to, v_tomorrow, 'asr') is not true then
    raise exception 'the next day should allow a nudge';
  end if;

  -- outside the circle, and yourself, are both refused
  begin
    perform public.record_nudge(v_out, v_today, 'asr');
    raise exception 'nudged someone outside the circle';
  exception when sqlstate 'SB403' then
    null;
  end;

  begin
    perform public.record_nudge(v_from, v_today, 'asr');
    raise exception 'nudged myself';
  exception when sqlstate 'SB400' then
    null;
  end;

  -- ...and so is a day_key from outside the window, which is the bound the
  -- derived dates above exist to respect. Pinned here so nobody "fixes" a
  -- future date failure by widening the RPC instead of the test.
  begin
    perform public.record_nudge(v_to, v_stale, 'asr');
    raise exception 'nudged with a stale day_key';
  exception when sqlstate 'SB400' then
    null;
  end;

  if (select count(*) from public.nudges) <> 3 then
    raise exception 'expected 3 nudge rows, saw %', (select count(*) from public.nudges);
  end if;
end $$;

rollback;
