-- 14. The four tables the Today grid listens to are published, and posts carries
--     a full replica identity so an undo's DELETE payload says WHICH prayer went.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_missing text;
  v_identity "char";
begin
  select string_agg(t, ', ') into v_missing
  from unnest(array['posts','circle_members','excused_days','custom_challenges']) t
  where not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
  );
  if v_missing is not null then
    raise exception 'not published to supabase_realtime: %', v_missing;
  end if;

  select relreplident into v_identity from pg_class where oid = 'public.posts'::regclass;
  if v_identity <> 'f' then
    raise exception 'posts replica identity is %, expected f (full)', v_identity;
  end if;
end $$;

rollback;
