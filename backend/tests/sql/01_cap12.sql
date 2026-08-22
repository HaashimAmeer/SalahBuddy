-- 1. The circle cap is 12 MEMBERS TOTAL: the 12th join succeeds, the 13th is refused.
--
-- Everything below derives N from circle_max_members() rather than spelling the
-- number out, so the day the cap moves again this test follows it instead of
-- failing for the wrong reason. The one hard-coded 12 is deliberate: it is the
-- assertion that the cap is what we think it is, and it is the thing a silent
-- change has to trip over.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email)
select ('00000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'cap' || i || '@example.test'
from generate_series(1, public.circle_max_members() + 1) i;

set local role authenticated;

do $$
declare
  v_code  text;
  v_count int;
  v_max   int := public.circle_max_members();
  i       int;
begin
  if v_max <> 12 then
    raise exception 'circle_max_members() should be 12, got %', v_max;
  end if;

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  select code into v_code from public.create_circle('Cap Test', '🤝');

  -- members 2..N fill the circle exactly
  for i in 2..v_max loop
    perform set_config('request.jwt.claims',
      format('{"sub":"00000000-0000-0000-0000-%s","role":"authenticated"}',
             lpad(i::text, 12, '0')), true);
    perform public.join_circle(v_code);
  end loop;

  perform set_config('request.jwt.claims',
    format('{"sub":"00000000-0000-0000-0000-%s","role":"authenticated"}',
           lpad(v_max::text, 12, '0')), true);
  select count(*) into v_count from public.circle_members;
  if v_count <> v_max then
    raise exception 'expected % members after the last join, saw %', v_max, v_count;
  end if;

  -- one past the cap must bounce off the capacity trigger
  begin
    perform set_config('request.jwt.claims',
      format('{"sub":"00000000-0000-0000-0000-%s","role":"authenticated"}',
             lpad((v_max + 1)::text, 12, '0')), true);
    perform public.join_circle(v_code);
    raise exception 'member % was allowed in', v_max + 1;
  exception when sqlstate 'SB409' then
    null;
  end;
end $$;

rollback;
