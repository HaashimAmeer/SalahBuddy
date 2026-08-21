-- v4 Phase A — realtime.
--
-- The Today grid fills in live from these four tables (§6): posts is the main
-- event, and the other three change what the grid renders (roster, resting
-- state, the circle's custom challenge).
--
-- Guarded so a vanilla Postgres without the supabase_realtime publication just
-- skips this instead of failing the migration.
--
-- ONE TABLE PER STATEMENT, deliberately. `alter publication ... add table a, b, c`
-- is all-or-nothing: if a single one of them is already published — which is what
-- happens the moment somebody flips a table's Realtime toggle in the dashboard, or
-- a half-applied push is retried — the whole statement raises duplicate_object and
-- the remaining tables are silently never added. The migration would still report
-- success while the Today grid quietly stopped receiving roster/resting/challenge
-- events. Adding them one at a time makes each already-published table a no-op
-- instead of a poison pill.
do $$
declare
  t text;
begin
  foreach t in array array['posts', 'circle_members', 'excused_days', 'custom_challenges']
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception
      when undefined_object then
        raise notice 'supabase_realtime publication absent — skipping realtime registration';
        exit;
      when duplicate_object then
        raise notice 'public.% is already in supabase_realtime', t;
    end;
  end loop;
end $$;

-- DELETE payloads only carry the replica identity, and an undo needs to tell
-- subscribers WHICH prayer vanished — the default (pk only) is not enough.
alter table public.posts replica identity full;
