-- 20. §6: "one nudge per sender per recipient per prayer window". The nudges
--     primary key enforces that only against a client that tells the truth.
--
-- Regression: day_key is the CLIENT's schedule day, so it is attacker-supplied.
-- The only validation anywhere used to be "is this a real calendar date", which
-- accepts every day from year 0000 to 9999 — about 18 million distinct primary
-- keys (3.65M days × 5 prayers) for one sender against one recipient, each one
-- returning true from record_nudge and firing a real push. The collapse id also
-- embeds dayKey, so they do not even stack on the lock screen.
--
-- Both limits below read now(), never the body.
--
-- Every day_key here is anchored to `now() at time zone 'utc'`, because that is
-- what record_nudge's ±1-day staleness guard compares against. Anchoring on
-- plain now() (the session's local zone) used to make this file fail for a
-- reason that had nothing to do with rate limiting: run it in the evening in
-- PDT and local-yesterday is two days back in UTC, so a key the test intends as
-- "just inside the window" lands outside it and raises SB400. It passed in CI
-- and failed on a Mac after 5pm, which is the worst way for a test to be wrong.
-- Real clients are unaffected -- they send a local TODAY key, and ±1 day
-- absorbs any timezone offset. It is only this file's deliberate probing of the
-- boundary that needs to use the same clock the guard does.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002001', 'sender@example.test'),
  ('00000000-0000-0000-0000-000000002002', 'target@example.test');

set local role authenticated;

do $$
declare
  v_send uuid := '00000000-0000-0000-0000-000000002001';
  v_recv uuid := '00000000-0000-0000-0000-000000002002';
  v_code text;
  v_today text := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
  v_day  text;
  i int;
  v_sent int := 0;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_send), true);
  select code into v_code from public.create_circle('Nudges', '🤝');
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_recv), true);
  perform public.join_circle(v_code);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_send), true);

  -- today works, and repeating it is the honest "already nudged"
  if public.record_nudge(v_recv, v_today, 'fajr') is not true then
    raise exception 'the first nudge for today was refused';
  end if;
  if public.record_nudge(v_recv, v_today, 'fajr') is not false then
    raise exception 'the primary key stopped enforcing the repeat';
  end if;

  -- ±1 day is allowed: a circle-mate west or east of you can legitimately be on
  -- yesterday's or tomorrow's schedule day (§7's same-city assumption is soft).
  if public.record_nudge(v_recv, to_char((now() at time zone 'utc') - interval '1 day', 'YYYY-MM-DD'), 'fajr') is not true then
    raise exception 'yesterday''s day_key was refused';
  end if;

  -- ...anything further out is not a prayer window, it is a fresh rate-limit token
  foreach v_day in array array['1000-01-02', '2020-01-01', '2999-12-31',
                                to_char((now() at time zone 'utc') + interval '5 days', 'YYYY-MM-DD')]
  loop
    begin
      perform public.record_nudge(v_recv, v_day, 'dhuhr');
      raise exception 'record_nudge accepted an out-of-window day_key: %', v_day;
    exception when sqlstate 'SB400' then null;
    end;
  end loop;

  -- The hourly cap is the backstop: even inside the ±1 day window there are
  -- 3 days × 5 prayers of legal tokens, and one sender should not be able to
  -- spend all of them at a circle-mate in one sitting.
  for i in 1..20 loop
    if public.record_nudge(
         v_recv,
         to_char((now() at time zone 'utc') + make_interval(days => (i % 3) - 1), 'YYYY-MM-DD'),
         (array['fajr','dhuhr','asr','maghrib','isha'])[(i % 5) + 1]::public.prayer_kind
       ) then
      v_sent := v_sent + 1;
    end if;
  end loop;
  if v_sent > public.nudge_hourly_cap() then
    raise exception 'sent % nudges past the hourly cap of %', v_sent, public.nudge_hourly_cap();
  end if;
  if (select count(*) from public.nudges where sender_id = v_send) > public.nudge_hourly_cap() then
    raise exception 'more nudge rows were written than the hourly cap allows';
  end if;
end $$;

rollback;
