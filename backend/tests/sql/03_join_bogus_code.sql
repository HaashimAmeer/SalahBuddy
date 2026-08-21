-- 3. join_circle with a code nobody owns raises SB404.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000201', 'lost@example.test');

set local role authenticated;

do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000201","role":"authenticated"}', true);

  begin
    perform public.join_circle('ZZZZZZ');
    raise exception 'join_circle accepted an unknown code';
  exception when sqlstate 'SB404' then
    null;
  end;

  begin
    perform public.join_circle('');
    raise exception 'join_circle accepted an empty code';
  exception when sqlstate 'SB404' then
    null;
  end;

  if exists (select 1 from public.circle_members
              where user_id = '00000000-0000-0000-0000-000000000201') then
    raise exception 'a failed join still created a membership';
  end if;
end $$;

rollback;
