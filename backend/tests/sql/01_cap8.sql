-- 1. The circle cap is 8 MEMBERS TOTAL: the 8th join succeeds, the 9th is refused.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email)
select ('00000000-0000-0000-0000-00000000000' || i)::uuid, 'cap' || i || '@example.test'
from generate_series(1, 9) i;

set local role authenticated;

do $$
declare
  v_code  text;
  v_count int;
  i       int;
begin
  if public.circle_max_members() <> 8 then
    raise exception 'circle_max_members() should be 8, got %', public.circle_max_members();
  end if;

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  select code into v_code from public.create_circle('Cap Test', '🤝');

  -- members 2..8 fill the circle exactly
  for i in 2..8 loop
    perform set_config('request.jwt.claims',
      format('{"sub":"00000000-0000-0000-0000-00000000000%s","role":"authenticated"}', i), true);
    perform public.join_circle(v_code);
  end loop;

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000008","role":"authenticated"}', true);
  select count(*) into v_count from public.circle_members;
  if v_count <> 8 then
    raise exception 'expected 8 members after the 8th join, saw %', v_count;
  end if;

  -- the 9th must bounce off the capacity trigger
  begin
    perform set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000009","role":"authenticated"}', true);
    perform public.join_circle(v_code);
    raise exception 'the 9th member was allowed in';
  exception when sqlstate 'SB409' then
    null;
  end;
end $$;

rollback;
