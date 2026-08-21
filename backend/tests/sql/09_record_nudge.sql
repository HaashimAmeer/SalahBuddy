-- 9. record_nudge is its own rate limit: true the first time, false after.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000701', 'nudger@example.test'),
  ('00000000-0000-0000-0000-000000000702', 'nudged@example.test'),
  ('00000000-0000-0000-0000-000000000703', 'outsider@example.test');

set local role authenticated;

do $$
declare
  v_from    uuid := '00000000-0000-0000-0000-000000000701';
  v_to      uuid := '00000000-0000-0000-0000-000000000702';
  v_out     uuid := '00000000-0000-0000-0000-000000000703';
  v_code    text;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_from), true);
  select code into v_code from public.create_circle('Nudges', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_to), true);
  perform public.join_circle(v_code);

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_out), true);
  perform public.create_circle('Elsewhere', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_from), true);

  if public.record_nudge(v_to, '2026-08-21', 'asr') is not true then
    raise exception 'the first nudge was not recorded';
  end if;
  if public.record_nudge(v_to, '2026-08-21', 'asr') is not false then
    raise exception 'the second nudge in the same window was not rate limited';
  end if;

  -- a different prayer window opens a fresh allowance
  if public.record_nudge(v_to, '2026-08-21', 'maghrib') is not true then
    raise exception 'the next prayer window should allow a nudge';
  end if;
  if public.record_nudge(v_to, '2026-08-22', 'asr') is not true then
    raise exception 'the next day should allow a nudge';
  end if;

  -- outside the circle, and yourself, are both refused
  begin
    perform public.record_nudge(v_out, '2026-08-21', 'asr');
    raise exception 'nudged someone outside the circle';
  exception when sqlstate 'SB403' then
    null;
  end;

  begin
    perform public.record_nudge(v_from, '2026-08-21', 'asr');
    raise exception 'nudged myself';
  exception when sqlstate 'SB400' then
    null;
  end;

  if (select count(*) from public.nudges) <> 3 then
    raise exception 'expected 3 nudge rows, saw %', (select count(*) from public.nudges);
  end if;
end $$;

rollback;
