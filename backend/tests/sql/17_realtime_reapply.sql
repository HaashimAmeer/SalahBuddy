-- 17. Regression: the realtime migration must publish all four tables even when
--     one of them is ALREADY published.
--
-- `alter publication ... add table a, b, c, d` is all-or-nothing. The moment a
-- single table is already in supabase_realtime — someone flipped its Realtime
-- toggle in the dashboard, or a half-finished push got retried — the statement
-- raises duplicate_object, the migration's handler swallows it, and the other
-- three are silently never added. Success is reported; the Today grid quietly
-- stops receiving roster / resting / challenge events.
--
-- The shim starts with an EMPTY publication, so nothing else in this suite can
-- see that. Here we recreate the partial state and re-run the real migration
-- file (`:migrations_dir` is passed in by run_sql_tests.sh) rather than a copy
-- of its SQL — a test that reimplements the migration proves nothing about it.
\set ON_ERROR_STOP on
begin;

-- Partial state: posts published, the other three not.
alter publication supabase_realtime drop table
  public.posts, public.circle_members, public.excused_days, public.custom_challenges;
alter publication supabase_realtime add table public.posts;

do $$
begin
  if (select count(*) from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public') <> 1 then
    raise exception 'test setup failed: expected exactly posts to be published';
  end if;
end $$;

\i :migrations_dir/20260821000600_realtime.sql

do $$
declare
  v_missing text;
begin
  select string_agg(t, ', ' order by t) into v_missing
  from unnest(array['posts','circle_members','excused_days','custom_challenges']) t
  where not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
  );
  if v_missing is not null then
    raise exception
      'one already-published table stranded the rest — not published: %', v_missing;
  end if;
end $$;

rollback;
