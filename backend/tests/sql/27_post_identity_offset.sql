-- 27. utc_offset is part of a post's identity (20260822000300).
--
-- Two things have to hold at once, and they pull in opposite directions:
--   * a traveller who prays fajr in Mumbai and fajr again in Seattle on the
--     same calendar date must get BOTH rows — they are two real prayers;
--   * two rows with NO offset at all (every post written before
--     20260822000200) must still collide, or the dedup guarantee the offline
--     queue leans on quietly evaporates for all of history. That is what
--     NULLS NOT DISTINCT buys, and Postgres's default null semantics would
--     give the opposite answer.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000701', 'traveller@example.test');

set local role authenticated;

do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000000701';
  v_circle uuid;
  v_mumbai int := 5 * 3600 + 1800;   -- +05:30
  v_pdt    int := -7 * 3600;         -- -07:00
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  select id into v_circle from public.create_circle('Travel', '✈️');

  -- Mumbai's fajr.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'fajr', 'onTime', now(), v_mumbai);

  -- Seattle's fajr, same calendar date, twelve and a half hours of zone apart.
  -- Differs from the row above ONLY in utc_offset, and must be accepted.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'fajr', 'onTime', now(), v_pdt);

  if (select count(*) from public.posts where prayer = 'fajr') <> 2 then
    raise exception 'two fajrs differing only in utc_offset should both exist, saw %',
      (select count(*) from public.posts where prayer = 'fajr');
  end if;

  -- Same zone, same slot: still exactly one post. The traveller's exemption is
  -- not a licence to double-log at home.
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
    values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'fajr', 'prayed', now(), v_pdt);
    raise exception 'a duplicate (user, day_key, prayer, utc_offset) post was accepted';
  exception when unique_violation then
    null;
  end;

  -- LEGACY ROWS. Both have utc_offset NULL. Under the default (NULLS DISTINCT)
  -- both would insert; under NULLS NOT DISTINCT the second is refused, which is
  -- the behaviour every build shipped so far already relies on.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'maghrib', 'onTime', now());

  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'maghrib', 'prayed', now());
    raise exception 'two NULL-offset posts in one slot were accepted — is the '
                    'constraint missing NULLS NOT DISTINCT?';
  exception when unique_violation then
    null;
  end;

  -- A NULL offset beside a real one is NOT two prayers. NULLS NOT DISTINCT
  -- alone would accept it (it only makes NULL equal to NULL), which is the
  -- hole 20260822000400 closes with a trigger -- a zoneless row matches every
  -- zone, exactly as GameEngine.isSamePrayerInstance reads a nil offset.
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
    values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'maghrib', 'prayed', now(), v_pdt);
    raise exception 'a zoned post was accepted beside a zoneless one for the same prayer';
  exception when unique_violation then
    null;
  end;

  if (select count(*) from public.posts) <> 3 then
    raise exception 'expected 3 posts, saw %', (select count(*) from public.posts);
  end if;
end $$;

-- The constraint really is the nulls-not-distinct one, named as the migration
-- names it. Asserted structurally as well as behaviourally so that a future
-- migration that recreates it with default null semantics fails here loudly
-- rather than in a traveller's grid.
do $$
declare
  v_nulls_distinct boolean;
  v_cols text;
begin
  select not i.indnullsnotdistinct,
         string_agg(a.attname, ',' order by k.ord)
    into v_nulls_distinct, v_cols
    from pg_constraint c
    join pg_index i on i.indexrelid = c.conindid
    join lateral unnest(c.conkey) with ordinality as k(attnum, ord) on true
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
   where c.conrelid = 'public.posts'::regclass
     and c.contype = 'u'
   group by i.indnullsnotdistinct;

  if v_cols is distinct from 'user_id,circle_id,day_key,prayer,utc_offset' then
    raise exception 'posts unique key is (%), expected (user_id,circle_id,day_key,prayer,utc_offset)', v_cols;
  end if;
  if v_nulls_distinct then
    raise exception 'posts unique key is NULLS DISTINCT — legacy NULL-offset rows would stop deduping';
  end if;
end $$;

rollback;
