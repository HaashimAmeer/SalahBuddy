-- Record WHERE IN THE WORLD a prayer was logged, in the only unit that matters
-- for a day boundary: the device's UTC offset in seconds at the moment of
-- logging.
--
-- WHY NOW, WHEN NOTHING READS IT YET. day_key is a client-local string, so the
-- same "2026-08-22" means one thing in Seattle and another in Mumbai, and the
-- app has no way to tell them apart after the fact. That is a real gap (see
-- SPEC-V4 §7's "accepted soft spot"), and fixing it properly means redefining
-- what a day IS -- which cascades into isDayComplete, isPerfectDay, the streak
-- walk, weeklyXP and the unique constraint below. That is a project, and it is
-- better designed against real data than guessed at.
--
-- But the data cannot be recovered later. A log written today without an
-- offset can never be told which zone it belonged to, so every month spent
-- deciding is a month of history permanently missing the one field the
-- eventual fix needs. Capture is cheap and irreversible-if-skipped; the day
-- model is expensive and reversible. So capture now, decide later.
--
-- Nullable on purpose, and it stays nullable: every row written before this
-- migration genuinely has no answer, and a default would be a fabricated one.
alter table public.posts add column if not exists utc_offset int;

comment on column public.posts.utc_offset is
  'Device UTC offset in seconds when the prayer was logged. Nullable: rows '
  'predating 20260822000200 have no answer, and inventing one would be worse '
  'than admitting it. Nothing scores off this yet -- it exists so a future '
  'cross-timezone day model has history to work with.';

-- Writable by the poster, like every other column they own. SELECT on posts is
-- already full-table for circle members, so no read grant changes.
--
-- On privacy: this does tell circle-mates roughly which longitude somebody is
-- at. That is not a new disclosure -- prayer windows are DERIVED from location,
-- so a member's logged_at against their own prayer times already implies it,
-- and place_label is far more specific when tagged. It is also unavoidable for
-- the purpose: rendering a shared grid across timezones requires knowing which
-- timezone each person is in.
grant insert (utc_offset), update (utc_offset) on public.posts to authenticated;
