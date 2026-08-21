-- 14. The realtime publication is a privacy surface, not just a feature switch.
--
--   * posts + custom_challenges ARE published — that is what fills the Today
--     grid in live (§6).
--   * circle_members + excused_days are NOT, and must never be. Realtime cannot
--     apply RLS to DELETE events (there is no row left to test a policy on), so
--     a delete goes to every subscriber in the project carrying the row's
--     primary key — and for those two tables the primary key IS the secret:
--     "user X was resting on day Y", and the whole user→circle graph.
--   * posts must NOT carry `replica identity full`: walrus truncates a delete's
--     old_record to the primary key whenever RLS is on, so `full` delivers
--     nothing and costs a full old tuple in the WAL on every UPDATE.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_bad text;
  v_identity "char";
begin
  select string_agg(t, ', ') into v_bad
  from unnest(array['posts','custom_challenges']) t
  where not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
  );
  if v_bad is not null then
    raise exception 'not published to supabase_realtime: %', v_bad;
  end if;

  select string_agg(t, ', ') into v_bad
  from unnest(array['circle_members','excused_days']) t
  where exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
  );
  if v_bad is not null then
    raise exception
      'published to realtime, whose unfiltered DELETE payload is the private fact: %', v_bad;
  end if;

  select relreplident into v_identity from pg_class where oid = 'public.posts'::regclass;
  if v_identity <> 'd' then
    raise exception 'posts replica identity is %, expected d (default/pk)', v_identity;
  end if;
end $$;

rollback;
