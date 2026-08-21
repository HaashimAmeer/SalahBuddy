-- Demo seed — STAGING ONLY. Never apply this to production.
--
-- Gives a fresh staging project one populated circle so the iOS client has
-- something real to render before two humans are on TestFlight together. The
-- ids below are hand-written 0000-…-000n uuids that no signup can ever mint,
-- so this seed can never collide with (or impersonate) a real account, and
-- there are no tokens, keys or personal data in it.
--
-- Idempotent: safe to re-apply. Day-scoped rows key off `current_date`, so
-- running it again tomorrow tops the circle up with today's activity instead
-- of leaving a stale week behind.

begin;

-- The demo circle. Code uses the unambiguous invite alphabet (no I/O/0/1).
insert into public.circles (id, code, name, emoji, created_by)
values (
  '00000000-0000-4000-a000-0000000000c1',
  'SALAM7',
  'Demo Circle',
  '🤝',
  null
)
on conflict (id) do update
  set name = excluded.name,
      emoji = excluded.emoji;

-- Demo accounts. `auth.users` first: the profiles trigger picks the name out of
-- raw_user_meta_data, and the upsert below fills in the rest.
insert into auth.users (id, email, raw_user_meta_data)
values
  ('00000000-0000-4000-a000-000000000001', 'amina@demo.salahbuddy.invalid',  '{"full_name":"Amina"}'::jsonb),
  ('00000000-0000-4000-a000-000000000002', 'yusuf@demo.salahbuddy.invalid',  '{"full_name":"Yusuf"}'::jsonb),
  ('00000000-0000-4000-a000-000000000003', 'bilal@demo.salahbuddy.invalid',  '{"full_name":"Bilal"}'::jsonb),
  ('00000000-0000-4000-a000-000000000004', 'layla@demo.salahbuddy.invalid',  '{"full_name":"Layla"}'::jsonb)
on conflict (id) do nothing;

insert into public.profiles (id, name, avatar_emoji, member_kind)
values
  ('00000000-0000-4000-a000-000000000001', 'Amina', '🌙', 'sister'),
  ('00000000-0000-4000-a000-000000000002', 'Yusuf', '⭐️', 'brother'),
  ('00000000-0000-4000-a000-000000000003', 'Bilal', '🕌', 'brother'),
  ('00000000-0000-4000-a000-000000000004', 'Layla', '🌸', 'sister')
on conflict (id) do update
  set name = excluded.name,
      avatar_emoji = excluded.avatar_emoji,
      member_kind = excluded.member_kind;

-- Four of the eight seats (cap is 8 MEMBERS total), leaving room to join from
-- a real device and test the roster live.
insert into public.circle_members (circle_id, user_id)
select '00000000-0000-4000-a000-0000000000c1', id
from (values
  ('00000000-0000-4000-a000-000000000001'::uuid),
  ('00000000-0000-4000-a000-000000000002'::uuid),
  ('00000000-0000-4000-a000-000000000003'::uuid),
  ('00000000-0000-4000-a000-000000000004'::uuid)
) as demo(id)
on conflict do nothing;

-- Today's posts. `day_key` is the client-computed local schedule day, so the
-- seed writes it the same way the app would; `id` is a fresh client-style uuid
-- and the (user, day, prayer) unique key is what makes the re-run a no-op.
insert into public.posts (
  id, user_id, circle_id, day_key, prayer, tier, logged_at, jamaat, place_label
)
select
  gen_random_uuid(),
  post.user_id,
  '00000000-0000-4000-a000-0000000000c1',
  to_char(current_date, 'YYYY-MM-DD'),
  post.prayer,
  post.tier,
  now() - post.ago,
  post.jamaat,
  post.place
from (values
  ('00000000-0000-4000-a000-000000000001'::uuid, 'fajr'::public.prayer_kind,    'onTime'::public.log_tier,   interval '9 hours', false, null),
  ('00000000-0000-4000-a000-000000000002'::uuid, 'fajr'::public.prayer_kind,    'prayed'::public.log_tier,   interval '8 hours', true,  'Masjid'),
  ('00000000-0000-4000-a000-000000000003'::uuid, 'fajr'::public.prayer_kind,    'lastCall'::public.log_tier, interval '7 hours', false, 'Home'),
  ('00000000-0000-4000-a000-000000000001'::uuid, 'dhuhr'::public.prayer_kind,   'onTime'::public.log_tier,   interval '4 hours', false, 'Work'),
  ('00000000-0000-4000-a000-000000000004'::uuid, 'dhuhr'::public.prayer_kind,   'prayed'::public.log_tier,   interval '3 hours', false, null),
  ('00000000-0000-4000-a000-000000000002'::uuid, 'asr'::public.prayer_kind,     'onTime'::public.log_tier,   interval '1 hour',  true,  'Masjid')
) as post(user_id, prayer, tier, ago, jamaat, place)
on conflict (user_id, day_key, prayer) do nothing;

-- A resting day, synced as a bare flag. There is no reason column and there
-- never will be — period/illness privacy is absolute (SPEC-V4 §3).
insert into public.excused_days (user_id, circle_id, day_key)
values (
  '00000000-0000-4000-a000-000000000003',
  '00000000-0000-4000-a000-0000000000c1',
  to_char(current_date - 1, 'YYYY-MM-DD')
)
on conflict (user_id, day_key) do nothing;

-- Recovery XP rides the scoreboard as an opaque weekly total: how it was
-- earned (dhikr vs. good deeds) never leaves the device.
insert into public.recovery_weeks (user_id, circle_id, week_key, xp)
values (
  '00000000-0000-4000-a000-000000000004',
  '00000000-0000-4000-a000-0000000000c1',
  to_char(current_date, 'IYYY-"W"IW'),
  24
)
on conflict (user_id, week_key) do update set xp = excluded.xp;

-- One group challenge, in the client's id format ("custom-<uuid>").
insert into public.custom_challenges (id, circle_id, created_by, prayer, days, week_key)
values (
  'custom-00000000-0000-4000-a000-0000000000d1',
  '00000000-0000-4000-a000-0000000000c1',
  '00000000-0000-4000-a000-000000000001',
  'fajr',
  5,
  to_char(current_date, 'IYYY-"W"IW')
)
on conflict (id) do update set week_key = excluded.week_key;

-- No `devices` or `nudges` rows on purpose: an APNs token is a live credential
-- and this repo is public. Devices register themselves from a real handset.

commit;
