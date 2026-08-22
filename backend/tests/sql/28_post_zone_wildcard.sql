-- 28. A zoneless post is a WILDCARD, not a third zone (20260822000400).
--
-- 20260822000300 made utc_offset part of a post's identity so a long-haul
-- flight's second fajr stops being refused. Its unique key is NULLS NOT
-- DISTINCT, which folds NULL into NULL and leaves one pair uncovered: a
-- zoneless legacy row beside a zoned one. That pair is ONE prayer written
-- twice, it double-counts on every circle-mate's scoreboard, and no upsert
-- ever conflicts with it again, so nothing heals it. The client has always
-- read a nil offset as "matches anything" (GameEngine.isSamePrayerInstance);
-- this is the server saying the same thing.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000801', 'wildcard@example.test'),
  ('00000000-0000-0000-0000-000000000802', 'neighbour@example.test');

set local role authenticated;

do $$
declare
  v_me      uuid := '00000000-0000-0000-0000-000000000801';
  v_circle  uuid;
  v_pdt     int  := -7 * 3600;         -- -07:00
  v_edt     int  := -4 * 3600;         -- -04:00, three hours away: a real flight
  v_legacy  uuid := gen_random_uuid();
  v_zoned   uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_me), true);
  select id into v_circle from public.create_circle('Wildcard', '🧭');

  -- THE ROLLOUT CASE, forwards. A build older than v4 (or a backfilled v3.9
  -- log, which has no offset to give) writes the zoneless row first; the same
  -- account's second device, on the new build, posts the same prayer with a
  -- real offset.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (v_legacy, v_me, v_circle, '2026-08-22', 'fajr', 'onTime', now());

  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
    values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'fajr', 'prayed', now(), v_pdt);
    raise exception 'a zoned post was accepted beside a zoneless one — '
                    'that slot now scores one whole prayer high for everybody';
  exception when unique_violation then
    null;   -- 23505: exactly what upsertPost catches to repair the row in place
  end;

  -- ...and backwards. Whichever lands first, the pair is still one prayer.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
  values (v_zoned, v_me, v_circle, '2026-08-22', 'dhuhr', 'onTime', now(), v_pdt);

  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
    values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'dhuhr', 'prayed', now());
    raise exception 'a zoneless post was accepted beside a zoned one';
  exception when unique_violation then
    null;
  end;

  -- WHAT MUST STILL BE ALLOWED. Two DIFFERENT real zones are two genuinely
  -- different prayers — the entire point of 20260822000300 — and the guard
  -- must not have quietly taken that back.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'dhuhr', 'onTime', now(), v_edt);

  if (select count(*) from public.posts where prayer = 'dhuhr') <> 2 then
    raise exception 'two real zones must still be two rows, saw %',
      (select count(*) from public.posts where prayer = 'dhuhr');
  end if;

  -- The guard is scoped to the slot, not to the table: another prayer, another
  -- day and another circle-mate are all untouched by it.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'asr', 'onTime', now());
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, utc_offset)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-23', 'fajr', 'onTime', now(), v_pdt);

  -- THE REPAIR PATH. The client answers the 23505 above with an UPDATE scoped
  -- to `utc_offset = n OR utc_offset is null` (SupabaseCircleTransport
  -- .scopedToSlot), which has to land on the legacy row that refused it —
  -- otherwise the JPEG it just uploaded has no row pointing at it and the
  -- retention sweep can never collect it.
  update public.posts
     set tier = 'prayed'
   where user_id = v_me and circle_id = v_circle
     and day_key = '2026-08-22' and prayer = 'fajr'
     and (utc_offset = v_pdt or utc_offset is null);

  if (select tier from public.posts where id = v_legacy) <> 'prayed' then
    raise exception 'the slot repair missed the zoneless row it was aimed at';
  end if;

  -- ...and that repair must not have fired the guard on itself: it does not
  -- touch the identity columns, so the row is still exactly one row.
  if (select count(*) from public.posts where prayer = 'fajr' and day_key = '2026-08-22') <> 1 then
    raise exception 'the repair changed the row count';
  end if;
end $$;

-- ON CONFLICT DO NOTHING MUST STILL WORK. A BEFORE trigger's exception cannot
-- be swallowed by ON CONFLICT, so the guard deliberately stays silent on the
-- pairs the unique key already refuses (NULL vs NULL, offset vs same offset).
-- seed.sql runs twice on every deploy and leans on exactly this.
do $$
declare
  v_me     uuid := '00000000-0000-0000-0000-000000000801';
  v_circle uuid;
begin
  select circle_id into v_circle from public.circle_members where user_id = v_me;

  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'isha', 'onTime', now())
  on conflict (user_id, circle_id, day_key, prayer, utc_offset) do nothing;

  -- Second pass: same zoneless slot. The unique key refuses it, ON CONFLICT
  -- swallows it, and nothing raises.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (gen_random_uuid(), v_me, v_circle, '2026-08-22', 'isha', 'prayed', now())
  on conflict (user_id, circle_id, day_key, prayer, utc_offset) do nothing;

  if (select count(*) from public.posts where prayer = 'isha') <> 1 then
    raise exception 'seed idempotency broke: saw % isha posts',
      (select count(*) from public.posts where prayer = 'isha');
  end if;
end $$;

-- Structural: the trigger exists, is BEFORE, and is per-row. A future
-- migration that drops it should fail here rather than in a leaderboard.
do $$
declare
  v_row record;
begin
  select t.tgtype, t.tgenabled into v_row
    from pg_trigger t
   where t.tgrelid = 'public.posts'::regclass
     and t.tgname = 'posts_zone_wildcard';

  if not found then
    raise exception 'posts_zone_wildcard trigger is missing — the wildcard rule is unenforced';
  end if;
  -- tgtype bit 0 = BEFORE (1 means BEFORE/row-level ordering), bit 1 = ROW.
  if (v_row.tgtype & 1) = 0 then
    raise exception 'posts_zone_wildcard must be a BEFORE trigger';
  end if;
  if (v_row.tgtype & 2) = 0 then
    raise exception 'posts_zone_wildcard must be FOR EACH ROW';
  end if;
  if v_row.tgenabled = 'D' then
    raise exception 'posts_zone_wildcard is disabled';
  end if;
end $$;

rollback;
