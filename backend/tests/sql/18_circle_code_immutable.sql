-- 18. §2 gives members an editable NAME AND EMOJI. Nothing else on `circles` is
--     theirs — and the invite `code` least of all.
--
-- Regression for a table-wide `grant update on public.circles to authenticated`,
-- which the row-level policy cannot narrow. With it, any member could:
--   * rewrite the code, silently killing every invite already shared (and there
--     is no admin role to undo it — exits are leave-only),
--   * set it to '' — legal, because there was no format CHECK — after which
--     anyone whose join field was blank or whitespace landed in their circle
--     and had their whole week read,
--   * forge created_by,
--   * and use the unique index as a free existence oracle for OTHER circles'
--     codes: 23505 means taken, success means free, restore yours afterwards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000001801', 'owner@example.test'),
  ('00000000-0000-0000-0000-000000001802', 'mate@example.test'),
  ('00000000-0000-0000-0000-000000001803', 'stranger@example.test');

set local role authenticated;

do $$
declare
  v_owner  uuid := '00000000-0000-0000-0000-000000001801';
  v_mate   uuid := '00000000-0000-0000-0000-000000001802';
  v_out    uuid := '00000000-0000-0000-0000-000000001803';
  v_circle uuid;
  v_code   text;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_owner), true);
  select id, code into v_circle, v_code from public.create_circle('Real', '🤝');

  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_mate), true);
  perform public.join_circle(v_code);

  -- name + emoji: allowed, that is the whole point of the policy
  update public.circles set name = 'Renamed', emoji = '🌙' where id = v_circle;
  if (select name from public.circles where id = v_circle) <> 'Renamed' then
    raise exception 'a member cannot rename their own circle';
  end if;

  -- code: refused at the GRANT, not the policy
  begin
    update public.circles set code = 'ZZZZZZ' where id = v_circle;
    raise exception 'a member rewrote the invite code';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.circles set created_by = v_mate where id = v_circle;
    raise exception 'a member forged created_by';
  exception when insufficient_privilege then null;
  end;

  if (select code from public.circles where id = v_circle) <> v_code then
    raise exception 'the invite code changed under a member';
  end if;

  -- rename_circle() is still the supported path and touches exactly two columns
  perform public.rename_circle('Via RPC', '✨');
  if (select code from public.circles where id = v_circle) <> v_code then
    raise exception 'rename_circle() disturbed the invite code';
  end if;
end $$;

reset role;

-- The CHECK is the second lock: even a writer that CAN reach the column cannot
-- store a code that is not six characters of the unambiguous alphabet.
do $$
begin
  begin
    insert into public.circles (code) values ('');
    raise exception 'an empty invite code was accepted';
  exception when check_violation then null;
  end;

  begin
    insert into public.circles (code) values ('ABC0I1');   -- 0, I, 1 are excluded
    raise exception 'an ambiguous-alphabet code was accepted';
  exception when check_violation then null;
  end;

  begin
    insert into public.circles (code) values ('ABCDEFG');  -- seven
    raise exception 'a seven-character code was accepted';
  exception when check_violation then null;
  end;
end $$;

set local role authenticated;

-- ...and join_circle refuses a malformed code BEFORE it ever looks anything up,
-- so a blank join field can never resolve to somebody's circle.
do $$
declare
  v_out uuid := '00000000-0000-0000-0000-000000001803';
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_out), true);
  begin
    perform public.join_circle('   ');
    raise exception 'join_circle accepted a blank code';
  exception when sqlstate 'SB404' then null;
  end;
  begin
    perform public.join_circle(null);
    raise exception 'join_circle accepted a null code';
  exception when sqlstate 'SB404' then null;
  end;
  begin
    perform public.join_circle('abc');
    raise exception 'join_circle accepted a short code';
  exception when sqlstate 'SB404' then null;
  end;
  if exists (select 1 from public.circle_members where user_id = v_out) then
    raise exception 'a malformed code still joined a circle';
  end if;
end $$;

rollback;
