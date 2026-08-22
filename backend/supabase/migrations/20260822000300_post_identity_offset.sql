-- Make a post's IDENTITY carry the zone it was prayed in.
--
-- day_key stays exactly what it has always been: the CLIENT's schedule day, and
-- the grouping key for a day. Nothing about scoring, the week grid or the streak
-- moves here. What changes is uniqueness.
--
-- The problem: day_key was doing two jobs at once. It is the label of a calendar
-- day AND, until now, half the answer to "is this the same prayer?". Those two
-- agree for everybody who stays put and stop agreeing the moment somebody
-- crosses a serious number of timezones. Fajr in Mumbai and Fajr in Seattle on
-- 2026-08-22 are two genuinely different prayers, prayed hours apart, that
-- happen to share one calendar date. The old key
--
--     unique (user_id, circle_id, day_key, prayer)
--
-- said they were the same row, so the second one — a real prayer, really prayed
-- — was refused with a 23505 and the traveller's grid simply lost it.
--
-- utc_offset (added in 20260822000200, captured on every log since) is the
-- missing coordinate, so it joins the key.
--
-- NULLS NOT DISTINCT IS LOAD-BEARING. Every post written before 20260822000200
-- has utc_offset = NULL, and under Postgres's DEFAULT null semantics two NULLs
-- are distinct — which would mean two legacy rows in the same slot both being
-- accepted, silently throwing away the one dedup guarantee this table has always
-- given. `nulls not distinct` (Postgres 15+; CI runs 16) makes NULL behave like
-- a value, so legacy rows keep colliding with each other exactly as they do
-- today.
--
-- What it does NOT cover is a NULL offset sitting beside a real one: NULLS NOT
-- DISTINCT makes NULL equal to NULL and to nothing else, so that pair is
-- accepted here and is two rows for one prayer. No unique index can express
-- "NULL matches every value", so the wildcard rule is enforced by a trigger
-- instead -- see 20260822000400, which is where that case is costed and
-- closed. This constraint is only half of the invariant.
--
-- THE SERVER RULE IS DELIBERATELY LOOSER THAN THE CLIENT RULE. DO NOT TIGHTEN
-- IT. The client (GameEngine.isSamePrayerInstance) treats two offsets within
-- three hours of each other as the SAME prayer, because a DST shift is exactly
-- one hour and a madhab change moves Asr's window by about one — neither may be
-- allowed to re-open a prayer somebody already prayed. Here, any two distinct
-- offsets are distinct rows, so this constraint would permit a pair one hour
-- apart that the client never creates. That asymmetry is correct on purpose: a
-- database constraint cannot express "within three hours" without an exclusion
-- constraint over a btree_gist range, and the client is the only party that
-- knows whether a shift was DST or a flight. Adding tolerance here would buy
-- nothing and would break DST twice a year for everybody.
--
-- The write path does not depend on these columns: the client upserts on the
-- PRIMARY KEY (`on_conflict=id`, see CircleOutbox.swift) and only falls back to
-- a slot-scoped UPDATE when this constraint fires. That fallback now filters on
-- utc_offset too, so it still lands on exactly the row that refused the insert.

alter table public.posts
  drop constraint if exists posts_user_id_circle_id_day_key_prayer_key;

alter table public.posts
  add constraint posts_user_id_circle_id_day_key_prayer_utc_offset_key
  unique nulls not distinct (user_id, circle_id, day_key, prayer, utc_offset);

comment on constraint posts_user_id_circle_id_day_key_prayer_utc_offset_key on public.posts is
  'One post per (user, circle, schedule day, prayer, zone). utc_offset is part '
  'of the key because a long-haul flight makes two different prayers share one '
  'day_key. NULLS NOT DISTINCT so pre-20260822000200 rows, which have no '
  'offset, keep deduping against each other; a NULL beside a real offset is '
  'refused by the posts_zone_wildcard trigger (20260822000400) instead, which '
  'no unique index could do. Deliberately looser than the client rule (which '
  'folds offsets within 3h together, so DST never splits a prayer) -- see the '
  'migration for why that must not be "fixed".';

-- The old index served (circle_id, day_key, prayer) reads and is untouched; the
-- constraint's own index is the (user_id, circle_id, day_key, prayer, utc_offset)
-- one Postgres builds for it.

-- 20260822000200 said "nothing scores off this yet". Something does now, so the
-- column's own documentation is brought up to date rather than left lying.
comment on column public.posts.utc_offset is
  'Device UTC offset in seconds when the prayer was logged. Part of the row''s '
  'IDENTITY: two prayers can share a day_key across a long-haul flight. '
  'Nullable, and it stays nullable -- rows predating 20260822000200 have no '
  'answer, and the unique key is NULLS NOT DISTINCT so they still dedupe.';
