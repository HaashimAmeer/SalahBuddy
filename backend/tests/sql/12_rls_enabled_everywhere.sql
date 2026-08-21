-- 12. Automatic RLS is OFF on this project, so a forgotten
--     `enable row level security` would silently publish a table to every
--     signed-in user. Walk pg_class instead of trusting review.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_bad text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'public tables without RLS: %', v_bad;
  end if;

  -- anon must hold no table privileges anywhere in public
  select string_agg(distinct table_name, ', ') into v_bad
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public';
  if v_bad is not null then
    raise exception 'anon was granted access to: %', v_bad;
  end if;

  -- every table we expect must actually exist
  select string_agg(t, ', ') into v_bad
  from unnest(array['profiles','circles','circle_members','posts','excused_days',
                    'recovery_weeks','custom_challenges','devices','nudges','retention_runs']) t
  where to_regclass('public.' || t) is null;
  if v_bad is not null then
    raise exception 'missing tables: %', v_bad;
  end if;

  -- retention_runs is service_role-only: RLS on, zero policies, no user grants
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'retention_runs') then
    raise exception 'retention_runs should have no policies at all';
  end if;
  if exists (select 1 from information_schema.role_table_grants
              where grantee = 'authenticated' and table_schema = 'public' and table_name = 'retention_runs') then
    raise exception 'authenticated must not reach retention_runs';
  end if;

  -- Every SECURITY DEFINER function runs as the owner, so an unpinned search_path
  -- is a privilege-escalation hole.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and (p.proconfig is null or not exists (
      select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%'
    ));
  if v_bad is not null then
    raise exception 'security definer functions without a pinned search_path: %', v_bad;
  end if;

  -- Retention is service_role only; a user session must never wipe photos.
  select string_agg(f, ', ') into v_bad
  from unnest(array['public.purge_expired_photo_rows(int)',
                    'public.claim_retention_run(interval)']) f
  where has_function_privilege('authenticated', f, 'execute')
     or has_function_privilege('anon', f, 'execute');
  if v_bad is not null then
    raise exception 'retention functions reachable from a user session: %', v_bad;
  end if;

  -- anon gets no RPCs at all; authenticated gets exactly the user-facing ones.
  select string_agg(f, ', ') into v_bad
  from unnest(array['public.create_circle(text,text)', 'public.join_circle(text)',
                    'public.leave_circle()', 'public.rename_circle(text,text)',
                    'public.delete_account()',
                    'public.record_nudge(uuid,text,public.prayer_kind)',
                    'public.current_circle_id()']) f
  where has_function_privilege('anon', f, 'execute');
  if v_bad is not null then
    raise exception 'anon can execute: %', v_bad;
  end if;

  select string_agg(f, ', ') into v_bad
  from unnest(array['public.create_circle(text,text)', 'public.join_circle(text)',
                    'public.leave_circle()', 'public.rename_circle(text,text)',
                    'public.delete_account()',
                    'public.record_nudge(uuid,text,public.prayer_kind)',
                    'public.current_circle_id()']) f
  where not has_function_privilege('authenticated', f, 'execute');
  if v_bad is not null then
    raise exception 'authenticated cannot execute: %', v_bad;
  end if;
end $$;

rollback;
