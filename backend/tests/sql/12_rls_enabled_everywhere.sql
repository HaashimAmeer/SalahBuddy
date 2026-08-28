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

  -- ...and `authenticated` must hold EXACTLY the verbs the RLS migration lists,
  -- no more. Worth pinning rather than trusting the grant statements, because a
  -- real project's default privileges hand every new table all four verbs to
  -- authenticated before a migration says a word: a table that quietly kept
  -- INSERT it was never meant to have is then one missing policy away from being
  -- writable. Only RLS stands between those two facts, so state the intent here.
  select string_agg(format('%s(%s)', table_name, verbs), ', ' order by table_name)
    into v_bad
  from (
    select g.table_name,
           string_agg(distinct g.privilege_type, ',' order by g.privilege_type) as verbs
    from information_schema.role_table_grants g
    where g.grantee = 'authenticated' and g.table_schema = 'public'
    group by g.table_name
  ) actual
  -- NOTE: INSERT/UPDATE are column-scoped now, so they do NOT appear here —
  -- information_schema.role_table_grants lists table-wide grants only. The
  -- columns those verbs actually cover are pinned in the next block, which is
  -- the assertion that matters: a table-wide INSERT would show up here as a
  -- surprise verb, and a widened column list fails there.
  where (table_name, verbs) not in (
    values ('profiles',          'SELECT'),
           ('circles',           'SELECT'),
           ('circle_members',    'DELETE,SELECT'),
           ('posts',             'DELETE,SELECT'),
           ('excused_days',      'DELETE'),
           ('recovery_weeks',    'DELETE'),
           ('custom_challenges', 'DELETE,SELECT'),
           ('devices',           'DELETE,SELECT'),
           -- v5 §6: an ActivityKit push address. Same shape as devices —
           -- select/delete your own rows, insert/update column-scoped below.
           ('live_activity_tokens', 'DELETE,SELECT'),
           ('nudges',            'SELECT')
  );
  if v_bad is not null then
    raise exception 'authenticated holds unexpected table privileges: %', v_bad;
  end if;

  -- The columns a signed-in user must never write. Each of these is load-bearing
  -- somewhere: created_at is the retention clock (a writable one makes the
  -- ~30-day photo expiry opt-out), updated_at is the touch trigger's,
  -- notified_at / announced_at are push leases, and circles.code is the invite
  -- (rewritable = every outstanding invite silently dead, and a blank code
  -- captures anyone whose join field was empty).
  select string_agg(format('%s.%s(%s)', t, c, v), ', ') into v_bad
  from (values
      ('posts','created_at','INSERT'),   ('posts','created_at','UPDATE'),
      ('posts','updated_at','INSERT'),   ('posts','updated_at','UPDATE'),
      ('posts','notified_at','INSERT'),  ('posts','notified_at','UPDATE'),
      ('posts','id','UPDATE'),
      ('posts','user_id','UPDATE'),      ('posts','circle_id','UPDATE'),
      ('nudges','created_at','INSERT'),  ('nudges','created_at','UPDATE'),
      ('circles','code','UPDATE'),       ('circles','created_by','UPDATE'),
      ('circles','id','UPDATE'),         ('circles','created_at','UPDATE'),
      ('circle_members','announced_at','UPDATE'),
      ('excused_days','created_at','INSERT'),
      ('excused_days','created_at','UPDATE'),
      -- ...and not even READABLE: §3's bare flag stops being bare the moment
      -- the circle can see what time of day the break started.
      ('excused_days','created_at','SELECT'),
      ('recovery_weeks','updated_at','INSERT'),
      ('recovery_weeks','updated_at','UPDATE'),
      ('recovery_weeks','updated_at','SELECT'),
      ('custom_challenges','created_at','INSERT'),
      ('custom_challenges','created_at','UPDATE'),
      ('custom_challenges','created_by','UPDATE'),
      ('custom_challenges','id','UPDATE'),
      ('devices','updated_at','INSERT'), ('devices','updated_at','UPDATE'),
      -- v5 §6: expires_at is the live-activity sweep's clock, and a writable
      -- one is an opt-out from it — a client could park a dead token on the
      -- fan-out's books until 2126. created_at/updated_at are the server's for
      -- the same reason they are everywhere else.
      ('live_activity_tokens','expires_at','INSERT'),
      ('live_activity_tokens','expires_at','UPDATE'),
      ('live_activity_tokens','created_at','INSERT'),
      ('live_activity_tokens','created_at','UPDATE'),
      ('live_activity_tokens','updated_at','INSERT'),
      ('live_activity_tokens','updated_at','UPDATE'),
      ('profiles','created_at','INSERT'),('profiles','created_at','UPDATE'),
      ('profiles','updated_at','INSERT'),('profiles','updated_at','UPDATE'),
      ('profiles','id','UPDATE'),
      -- reports is write-only for the reporter, so EVERY column is unreadable
      -- and unrewritable — spelled out column by column rather than left to
      -- "there is no grant statement", because the whole table's design is that
      -- asymmetry. A SELECT anywhere here is an enumeration of who reported
      -- whom; an UPDATE is a withdrawal button on a filed complaint.
      ('reports','id','SELECT'),               ('reports','id','UPDATE'),
      ('reports','reporter_id','SELECT'),      ('reports','reporter_id','UPDATE'),
      ('reports','post_id','SELECT'),          ('reports','post_id','UPDATE'),
      ('reports','circle_id','SELECT'),        ('reports','circle_id','UPDATE'),
      ('reports','reported_user_id','SELECT'), ('reports','reported_user_id','UPDATE'),
      ('reports','photo_path','SELECT'),       ('reports','photo_path','UPDATE'),
      ('reports','reason','SELECT'),           ('reports','reason','UPDATE'),
      ('reports','created_at','SELECT'),       ('reports','created_at','INSERT'),
      ('reports','created_at','UPDATE'),
      -- ...and the triage columns are the newest way to get this wrong. They
      -- were added by ALTER TABLE, which does NOT re-run the project's default
      -- privileges — but the INSERT grant beside them is column-scoped and
      -- names its columns one by one, so the day somebody re-issues it as a
      -- table-wide `grant insert on public.reports`, these three fail. Readable
      -- would tell the reported member their complaint was dismissed; writable
      -- would let them close it themselves.
      ('reports','handled_at','SELECT'),       ('reports','handled_at','INSERT'),
      ('reports','handled_at','UPDATE'),
      ('reports','handled_action','SELECT'),   ('reports','handled_action','INSERT'),
      ('reports','handled_action','UPDATE')
  ) as forbidden(t, c, v)
  where has_column_privilege('authenticated', 'public.' || t, c, v);
  if v_bad is not null then
    raise exception 'authenticated can write columns it must not: %', v_bad;
  end if;

  -- ...and the columns it genuinely needs, so a copy-paste that over-narrows a
  -- grant fails here instead of at runtime on a real device.
  select string_agg(format('%s.%s(%s)', t, c, v), ', ') into v_bad
  from (values
      ('posts','id','INSERT'),           ('posts','user_id','INSERT'),
      ('posts','circle_id','INSERT'),    ('posts','photo_path','UPDATE'),
      ('posts','tier','UPDATE'),         ('posts','logged_at','UPDATE'),
      ('excused_days','day_key','INSERT'),
      ('excused_days','day_key','SELECT'),
      ('recovery_weeks','xp','INSERT'),  ('recovery_weeks','xp','UPDATE'),
      ('recovery_weeks','xp','SELECT'),
      ('circles','name','UPDATE'),       ('circles','emoji','UPDATE'),
      ('devices','apns_token','INSERT'),
      ('devices','notify_friend_activity','INSERT'),
      ('devices','notify_friend_activity','UPDATE'),
      -- v5 §6. The app writes these through register_live_activity_token, but
      -- the direct grant is what lets it DELETE its own row at window close
      -- without an RPC, and the insert columns are pinned so a copy-paste
      -- cannot silently narrow the RPC's own reach either.
      ('live_activity_tokens','token','INSERT'),
      ('live_activity_tokens','kind','INSERT'),
      ('live_activity_tokens','day_key','INSERT'),
      ('live_activity_tokens','prayer','INSERT'),
      ('live_activity_tokens','ends_at','INSERT'),
      ('live_activity_tokens','activity_id','INSERT'),
      ('live_activity_tokens','environment','INSERT'),
      ('live_activity_tokens','utc_offset','INSERT'),
      ('profiles','name','UPDATE'),      ('profiles','id','INSERT'),
      ('nudges','day_key','INSERT'),
      -- The other half of the reports matrix. Write-only is not "no grant at
      -- all": the report still has to be FILEABLE, and an over-narrowed copy of
      -- 20260821000800's grant would fail here rather than on a real phone as a
      -- 42501 the reporter reads as "reporting is broken".
      ('reports','id','INSERT'),               ('reports','reporter_id','INSERT'),
      ('reports','post_id','INSERT'),          ('reports','circle_id','INSERT'),
      ('reports','reported_user_id','INSERT'), ('reports','photo_path','INSERT'),
      ('reports','reason','INSERT')
  ) as needed(t, c, v)
  where not has_column_privilege('authenticated', 'public.' || t, c, v);
  if v_bad is not null then
    raise exception 'authenticated lost a column grant it needs: %', v_bad;
  end if;

  -- every table we expect must actually exist
  select string_agg(t, ', ') into v_bad
  from unnest(array['profiles','circles','circle_members','circle_departures',
                    'photo_tombstones','posts','excused_days',
                    'recovery_weeks','custom_challenges','devices','nudges',
                    'live_activity_tokens','retention_runs','reports']) t
  where to_regclass('public.' || t) is null;
  if v_bad is not null then
    raise exception 'missing tables: %', v_bad;
  end if;

  -- The sweep's own bookkeeping is service_role-only. photo_tombstones in
  -- particular IS the list of paths we are burying — a SELECT grant on it would
  -- publish exactly what the storage policy is hiding.
  select string_agg(distinct table_name, ', ') into v_bad
  from information_schema.role_table_grants
  where grantee in ('authenticated', 'anon') and table_schema = 'public'
    and table_name in ('circle_departures', 'photo_tombstones');
  if v_bad is not null then
    raise exception 'a user session can reach the sweep bookkeeping: %', v_bad;
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
  -- open_report_stats() rides along: it answers only in counts, but "how many
  -- open reports are there" is still triage's own business, and a member who
  -- can watch the number move can watch their own complaint being closed.
  select string_agg(f, ', ') into v_bad
  from unnest(array['public.purge_expired_photo_rows(int,int)',
                    'public.confirm_photo_deletions(text[])',
                    'public.charge_join_attempt()',
                    'public.purge_expired_live_activity_tokens()',
                    'public.claim_retention_run(interval)',
                    'public.open_report_stats()']) f
  where has_function_privilege('authenticated', f, 'execute')
     or has_function_privilege('anon', f, 'execute');
  if v_bad is not null then
    raise exception 'retention functions reachable from a user session: %', v_bad;
  end if;

  -- ...and it must stay executable by the one role that triages. A revoke that
  -- overshot would leave the nightly count silently failing on a public repo,
  -- which reads as "nothing is open".
  if not has_function_privilege('service_role', 'public.open_report_stats()', 'execute') then
    raise exception 'service_role cannot execute open_report_stats()';
  end if;

  -- anon gets no RPCs at all; authenticated gets exactly the user-facing ones.
  select string_agg(f, ', ') into v_bad
  from unnest(array['public.create_circle(text,text)', 'public.join_circle(text)',
                    'public.leave_circle()', 'public.rename_circle(text,text)',
                    'public.delete_account()',
                    'public.record_nudge(uuid,text,public.prayer_kind)',
                    'public.register_live_activity_token(text,text,text,text,public.prayer_kind,timestamptz,text,int)',
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
                    'public.register_live_activity_token(text,text,text,text,public.prayer_kind,timestamptz,text,int)',
                    'public.current_circle_id()']) f
  where not has_function_privilege('authenticated', f, 'execute');
  if v_bad is not null then
    raise exception 'authenticated cannot execute: %', v_bad;
  end if;
end $$;

rollback;
