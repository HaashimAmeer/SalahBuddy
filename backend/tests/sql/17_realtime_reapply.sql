-- 17. Regression: the realtime migration must converge on the intended list from
--     ANY starting state — including one where a table it wants is already
--     published, and one where a table it must NOT publish already is.
--
-- `alter publication ... add table a, b` is all-or-nothing. The moment a single
-- table is already in supabase_realtime — someone flipped its Realtime toggle in
-- the dashboard, or a half-finished push got retried — the statement raises
-- duplicate_object, the migration's handler swallows it, and the rest are
-- silently never added. Success is reported; the Today grid quietly stops
-- receiving events.
--
-- The reverse matters more: a project that once published excused_days (an
-- earlier cut of this migration did) must have it REMOVED on re-apply, or every
-- un-marked rest day keeps broadcasting to the whole project.
--
-- The shim starts with an EMPTY publication, so nothing else in this suite can
-- see either case. Here we recreate the awkward state and re-run the real
-- migration file (`:migrations_dir` is passed in by run_sql_tests.sh) rather
-- than a copy of its SQL — a test that reimplements the migration proves nothing
-- about it.
\set ON_ERROR_STOP on
begin;

-- Awkward state: posts published already, custom_challenges not, and the two
-- privacy-sensitive tables published as an old migration would have left them.
alter publication supabase_realtime drop table
  public.posts, public.custom_challenges;
alter publication supabase_realtime add table public.posts;
alter publication supabase_realtime add table public.circle_members;
alter publication supabase_realtime add table public.excused_days;
alter table public.posts replica identity full;

do $$
begin
  if (select count(*) from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public') <> 3 then
    raise exception 'test setup failed: expected exactly three published tables';
  end if;
end $$;

\i :migrations_dir/20260821000600_realtime.sql

do $$
declare
  v_bad text;
  v_identity "char";
begin
  select string_agg(t, ', ' order by t) into v_bad
  from unnest(array['posts','custom_challenges']) t
  where not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
  );
  if v_bad is not null then
    raise exception
      'one already-published table stranded the rest — not published: %', v_bad;
  end if;

  select string_agg(t, ', ' order by t) into v_bad
  from unnest(array['circle_members','excused_days']) t
  where exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
  );
  if v_bad is not null then
    raise exception 're-apply left a privacy-leaking table published: %', v_bad;
  end if;

  select relreplident into v_identity from pg_class where oid = 'public.posts'::regclass;
  if v_identity <> 'd' then
    raise exception 're-apply left posts replica identity at %, expected d', v_identity;
  end if;
end $$;

rollback;
