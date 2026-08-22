-- A post with NO zone is a WILDCARD, not a third zone.
--
-- 20260822000300 put utc_offset into the posts unique key so a long-haul
-- flight's second fajr stops being refused. `nulls not distinct` kept the two
-- legacy cases deduping (NULL vs NULL, and a real offset vs the same real
-- offset), and that migration's prose claimed the only surviving pairs were
-- "two DIFFERENT real offsets". One pair was left uncosted, and it is the one
-- the v4 rollout produces by itself:
--
--     row A  utc_offset = NULL      -- written by a build older than v4, or
--                                   -- backfilled from a v3.9 log that has no
--                                   -- offset to give
--     row B  utc_offset = -25200    -- the same prayer, logged on a second
--                                   -- device that IS on the new build
--
-- NULLS NOT DISTINCT makes NULL equal to NULL and to nothing else, so B is
-- accepted and the slot holds two rows for ONE prayer, permanently: no later
-- upsert conflicts with either, so nothing ever heals it. Every circle-mate's
-- mirror keeps both, CircleSnapshot.prayerLogs feeds both into GameEngine, and
-- that member's weekly score reads a whole prayer (30 XP) high on everybody
-- else's device — enough to hand them the race-to-target crown. Under the old
-- four-column key B collided and was repaired in place into one row.
--
-- The client has never had this hole: GameEngine.isSamePrayerInstance reads a
-- nil offset as "matches anything", so a zoneless log can lose a duplicate it
-- should have been allowed but can never gain one it should not. This is the
-- server saying the same thing.
--
-- WHY A TRIGGER AND NOT A CONSTRAINT. "NULL matches every value" is not a
-- unique key — a unique index can only compare a row against a key, and this
-- compares a row against the OTHER rows' nullness. An exclusion constraint
-- over an int4range (unbounded for NULL) would express it declaratively, but
-- it needs btree_gist, it cannot be an ON CONFLICT target, and it raises 23P01
-- where every client and every caller here already handles 23505.
--
-- WHY IT ONLY FIRES ON THE CROSS CASE. `on conflict ... do nothing` can swallow
-- a constraint violation and CANNOT swallow an exception raised in a BEFORE
-- trigger. The unique key from 20260822000300 therefore keeps its two jobs
-- (NULL vs NULL, offset vs same offset), seed.sql stays idempotent, and this
-- adds only the pair no index can see.

create or replace function public.posts_reject_zone_wildcard_conflict()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  -- Exactly one side of the pair is zoneless: they cannot both be real
  -- prayers, because the one with no offset matches every zone there is.
  if exists (
    select 1
      from public.posts p
     where p.user_id   = new.user_id
       and p.circle_id = new.circle_id
       and p.day_key   = new.day_key
       and p.prayer    = new.prayer
       and p.id       <> new.id
       and (p.utc_offset is null) <> (new.utc_offset is null)
  ) then
    -- 23505 on purpose. SupabaseCircleTransport.upsertPost reads a unique
    -- violation as "this slot is already taken" and repairs the row in place
    -- (scopedToSlot matches `utc_offset = n OR utc_offset is null` precisely so
    -- it lands on the row that refused this insert). A bespoke SQLSTATE would
    -- make the client throw instead, and the queued post would retry forever.
    raise exception 'a post for this prayer already exists with an unknown zone'
      using errcode = 'unique_violation', hint = 'zone_wildcard';
  end if;
  return new;
end $$;

drop trigger if exists posts_zone_wildcard on public.posts;
create trigger posts_zone_wildcard
  before insert or update of user_id, circle_id, day_key, prayer, utc_offset
  on public.posts
  for each row execute function public.posts_reject_zone_wildcard_conflict();

comment on function public.posts_reject_zone_wildcard_conflict() is
  'A post with utc_offset NULL is a wildcard: it is the same prayer as any '
  'zoned post in its (user, circle, day_key, prayer) slot, so the two may not '
  'coexist. Raises 23505 so the client''s existing slot-repair path handles it. '
  'The unique key still covers NULL-vs-NULL and offset-vs-same-offset, which '
  'is what keeps ON CONFLICT DO NOTHING working.';
