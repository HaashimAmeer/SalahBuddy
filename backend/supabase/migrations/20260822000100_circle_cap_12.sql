-- Circle capacity: 8 -> 12 members total.
--
-- WHY THIS EXISTS. The original 8 was never a technical limit. It came from a
-- v2/v3 comment on BuddySimulator.maxFriends -- "sharing five photos a day is
-- an intimate thing; past ~8 it stops feeling like a circle" -- which was a
-- judgement about the SIMULATED circle. v4 inherited the number for real
-- circles without re-deriving it, and reinterpreted it as 8 seats rather than
-- 8 friends, which is where the demo/real off-by-one came from.
--
-- 12 was chosen deliberately: it seats a family or a masjid friend group, and
-- it stays inside the range the sync path was built for. The reconciling pull
-- (CircleSync.pull(since: nil)) reads the whole 35-day window for every member
-- and every device re-runs GameEngine over all of it, since there is no
-- server-side scoring. That is ~1,400 posts at 8 seats and ~2,100 at 12 --
-- growth the client already absorbs. It is the reason this is 12 and not 50.
--
-- Nothing but the function changes. enforce_circle_capacity() calls
-- circle_max_members() at trigger time rather than baking the number in, so
-- the trigger, the error message and the client's mirrored constant all move
-- together. That was the point of putting it in a function.
create or replace function public.circle_max_members() returns int
language sql immutable
as $$ select 12 $$;
