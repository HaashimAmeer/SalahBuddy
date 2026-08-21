-- 2. One circle per user: a second join_circle raises SB410.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000101', 'a@example.test'),
  ('00000000-0000-0000-0000-000000000102', 'b@example.test');

set local role authenticated;

do $$
declare
  v_code_a text;
  v_code_b text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000101","role":"authenticated"}', true);
  select code into v_code_a from public.create_circle('A', '🤝');

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000102","role":"authenticated"}', true);
  select code into v_code_b from public.create_circle('B', '🤝');

  -- joining a second circle
  begin
    perform public.join_circle(v_code_a);
    raise exception 'join_circle let a user into a second circle';
  exception when sqlstate 'SB410' then
    null;
  end;

  -- and creating one while already a member
  begin
    perform public.create_circle('C', '🤝');
    raise exception 'create_circle let a user start a second circle';
  exception when sqlstate 'SB410' then
    null;
  end;

  if (select circle_id from public.circle_members
       where user_id = '00000000-0000-0000-0000-000000000102') is null then
    raise exception 'the original membership was disturbed';
  end if;
  if v_code_a = v_code_b then
    raise exception 'two circles got the same invite code';
  end if;
end $$;

rollback;
