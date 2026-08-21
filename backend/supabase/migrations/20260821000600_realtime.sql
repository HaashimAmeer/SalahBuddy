-- v4 Phase A — realtime.
--
-- The Today grid fills in live from these four tables (§6): posts is the main
-- event, and the other three change what the grid renders (roster, resting
-- state, the circle's custom challenge).
--
-- Guarded so a vanilla Postgres without the supabase_realtime publication just
-- skips this instead of failing the migration.
do $$
begin
  execute 'alter publication supabase_realtime add table
             public.posts, public.circle_members, public.excused_days, public.custom_challenges';
exception
  when undefined_object then
    raise notice 'supabase_realtime publication absent — skipping realtime registration';
  when duplicate_object then
    raise notice 'tables already in supabase_realtime — nothing to do';
end $$;

-- DELETE payloads only carry the replica identity, and an undo needs to tell
-- subscribers WHICH prayer vanished — the default (pk only) is not enough.
alter table public.posts replica identity full;
