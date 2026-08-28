-- 30. The other end of the mailbox: a report can be CLOSED, and only by the one
--     role that could ever read it (App Store guideline 1.2).
--
-- Test 25 proves a report goes in and stays in. This one proves the half added
-- by 20260828000100_reports_triage.sql, and every assertion here is a thing that
-- would be wrong in a way nobody would notice from the app:
--
--   * OPEN IS THE DEFAULT, for rows filed before the columns existed as much as
--     for rows filed after. A `not null default now()` would have closed the
--     entire backlog on deploy day — silently, and with a timestamp that looks
--     exactly like a human decision.
--   * THE REPORTER STILL SEES NOTHING, and now there is something new to see.
--     A readable `handled_action` tells the reported member their complaint was
--     dismissed; a writable one lets them dismiss it themselves.
--   * THE PAIR MOVES TOGETHER and the SERVER owns the clock. The writer is an
--     operator at a terminal, so a client-supplied `handled_at` is a laptop's
--     idea of the time on the one field an App Review question would be about.
--   * THE COUNT IS COUNTS-ONLY. `open_report_stats()` is what a PUBLIC
--     workflow log prints, so its return type — not a `jq` filter — is what
--     makes "a count is the ceiling" true.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000003001', 'reporter@example.test'),
  ('00000000-0000-0000-0000-000000003002', 'author@example.test'),
  ('00000000-0000-0000-0000-000000003003', 'bystander@example.test');

set local role authenticated;

-- The honest path, exactly as a phone walks it: a circle, a photo, a report.
do $$
declare
  v_reporter uuid := '00000000-0000-0000-0000-000000003001';
  v_author   uuid := '00000000-0000-0000-0000-000000003002';
  v_circle   uuid;
  v_code     text;
  v_post     uuid := '00000000-0000-0000-0000-0000000030a1';
  v_post2    uuid := '00000000-0000-0000-0000-0000000030a2';
  v_path     text;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_reporter), true);
  select id, code into v_circle, v_code from public.create_circle('Triage', '🤝');

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_author), true);
  perform public.join_circle(v_code);
  v_path := format('%s/%s/reported.jpg', v_circle, v_author);
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path)
  values (v_post,  v_author, v_circle, '2026-08-21', 'fajr',  'onTime', now(), v_path),
         -- A second photo, so the refusals below have a (reporter, post) pair of
         -- their own. Re-using the reported one would surface a policy hole as a
         -- unique violation and fail the test with the wrong reason.
         (v_post2, v_author, v_circle, '2026-08-21', 'dhuhr', 'onTime', now(),
          format('%s/%s/other.jpg', v_circle, v_author));

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_reporter), true);
  insert into public.reports (id, reporter_id, post_id, circle_id,
                              reported_user_id, photo_path, reason)
  values ('00000000-0000-0000-0000-0000000030b1', v_reporter, v_post, v_circle,
          v_author, v_path, 'Not a prayer photo');
end $$;

reset role;

-- 1. It lands OPEN, and nothing about the report itself was disturbed.
do $$
declare
  v_at     timestamptz;
  v_action text;
begin
  select handled_at, handled_action into v_at, v_action
    from public.reports where id = '00000000-0000-0000-0000-0000000030b1';
  if v_at is not null or v_action is not null then
    raise exception 'a freshly filed report arrived already handled (% / %)', v_at, v_action;
  end if;
end $$;

-- 2. The reporter's side of the wall has not moved.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000003001","role":"authenticated"}';

do $$
declare
  v_reporter uuid := '00000000-0000-0000-0000-000000003001';
  v_author   uuid := '00000000-0000-0000-0000-000000003002';
  v_post2    uuid := '00000000-0000-0000-0000-0000000030a2';
  v_circle   uuid;
  v_when     timestamptz;
begin
  select circle_id into v_circle from public.posts where id = v_post2;

  -- Reading the disposition would tell a member their complaint was closed —
  -- and, filed the other way, that somebody's complaint about THEM was not.
  begin
    select handled_at into v_when from public.reports;
    raise exception 'a reporter can read handled_at';
  exception when insufficient_privilege then null;
  end;

  -- Writing it is a withdrawal button on a filed complaint, which is the whole
  -- reason there is no UPDATE grant on this table at all.
  begin
    update public.reports set handled_action = 'dismissed';
    raise exception 'a reporter can close a report';
  exception when insufficient_privilege then null;
  end;

  -- ...and the subtler one: filing a report that arrives pre-closed. The INSERT
  -- grant is column-scoped and names its columns one by one, so these two are
  -- outside it — but an ALTER TABLE that added them looks exactly like an ALTER
  -- TABLE that added `reason`, and only this assertion tells the two apart.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, handled_action)
    values (v_reporter, v_post2, v_circle, v_author, 'dismissed');
    raise exception 'a reporter filed a report that was already handled';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, handled_at)
    values (v_reporter, v_post2, v_circle, v_author, now());
    raise exception 'a reporter stamped handled_at on the way in';
  exception when insufficient_privilege then null;
  end;

  -- The count is triage's business too. A member who can watch the number move
  -- can watch their own report being closed.
  begin
    perform public.open_report_stats();
    raise exception 'a signed-in member can read the open-report count';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- 3. Triage's own half, from the only role that holds it.
set local role service_role;

do $$
declare
  v_id     uuid := '00000000-0000-0000-0000-0000000030b1';
  v_at     timestamptz;
  v_action text;
  v_who    uuid;
  v_path   text;
  v_made   timestamptz;
begin
  -- The vocabulary is closed. A free-text disposition is a note, not an action,
  -- and the CLI can only carry out the two words the constraint allows.
  begin
    update public.reports set handled_action = 'nuked from orbit' where id = v_id;
    raise exception 'reports accepted a disposition nothing can carry out';
  exception when check_violation then null;
  end;

  -- A timestamp with no action is "somebody looked", which is not a decision.
  -- The trigger declines it rather than the constraint rejecting it: handled_at
  -- is DERIVED, so the only way to close a report is to say what was done.
  update public.reports set handled_at = now() where id = v_id;
  select handled_at into v_at from public.reports where id = v_id;
  if v_at is not null then
    raise exception 'handled_at was set without a disposition (%)', v_at;
  end if;

  -- Closing it. The forged timestamp rides along and must be ignored: the
  -- server's clock owns this column, exactly like created_at and updated_at.
  select reported_user_id, photo_path, created_at into v_who, v_path, v_made
    from public.reports where id = v_id;

  update public.reports
     set handled_action = 'photo_removed', handled_at = '2126-01-01T00:00:00Z'
   where id = v_id;

  select handled_at, handled_action into v_at, v_action
    from public.reports where id = v_id;
  if v_action <> 'photo_removed' then
    raise exception 'the disposition did not stick (%)', v_action;
  end if;
  if v_at is null or v_at <> now() then
    raise exception 'handled_at is not the server clock (%)', v_at;
  end if;

  -- Closing a report must not rewrite what it says. The subject copy
  -- 20260821000800 exists to protect is the evidence; triage annotates it.
  if (select reported_user_id from public.reports where id = v_id) is distinct from v_who
     or (select photo_path  from public.reports where id = v_id) is distinct from v_path
     or (select created_at  from public.reports where id = v_id) is distinct from v_made then
    raise exception 'handling a report altered what it was about';
  end if;

  -- Re-opening: clearing the action takes the timestamp with it, so "open" has
  -- exactly one representation and `where handled_at is null` is the whole query.
  update public.reports
     set handled_action = null, handled_at = '2126-01-01T00:00:00Z'
   where id = v_id;
  select handled_at into v_at from public.reports where id = v_id;
  if v_at is not null then
    raise exception 're-opening a report left its handled_at behind (%)', v_at;
  end if;
end $$;

reset role;

-- 4. Re-handling. `now()` is the TRANSACTION's clock, so a re-stamp inside this
--    test would be indistinguishable from a preserved one — hence the planted
--    back-date. The trigger is disabled for exactly one statement, as the table
--    owner, because there is no other way to put a past timestamp in a column
--    the server owns; that is the property under test, not a way around it.
alter table public.reports disable trigger reports_stamp_handled;
update public.reports
   set handled_action = 'dismissed', handled_at = now() - interval '3 days'
 where id = '00000000-0000-0000-0000-0000000030b1';
alter table public.reports enable trigger reports_stamp_handled;

set local role service_role;

do $$
declare
  v_id     uuid := '00000000-0000-0000-0000-0000000030b1';
  v_at     timestamptz;
  v_before timestamptz;
begin
  select handled_at into v_before from public.reports where id = v_id;

  -- Re-running the same decision is a no-op, not a fresh one. An operator who
  -- runs `dismiss` twice has not re-triaged anything, and re-dating would make
  -- a three-day-old decision look like it happened tonight.
  update public.reports set handled_action = 'dismissed' where id = v_id;
  select handled_at into v_at from public.reports where id = v_id;
  if v_at <> v_before then
    raise exception 'repeating a disposition re-dated it (% -> %)', v_before, v_at;
  end if;

  -- Changing it IS a fresh decision — dismissed, then looked at again and the
  -- photo taken down — so the stamp moves to when that happened.
  update public.reports set handled_action = 'photo_removed' where id = v_id;
  select handled_at into v_at from public.reports where id = v_id;
  if v_at <> now() then
    raise exception 'changing the disposition kept the old timestamp (%)', v_at;
  end if;
end $$;

reset role;

-- 5. Nothing about handling makes a report deletable-by-proxy. The undo button
--    is still not a retraction button, and now it cannot erase the decision
--    either — which is the shape an App Review answer takes: "reported on X,
--    photo removed on Y", still true after the post is gone.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000003002","role":"authenticated"}';
delete from public.posts where id = '00000000-0000-0000-0000-0000000030a1';
reset role;

do $$
declare
  v_action text;
  v_at     timestamptz;
begin
  select handled_action, handled_at into v_action, v_at
    from public.reports where id = '00000000-0000-0000-0000-0000000030b1';
  if v_action is null or v_at is null then
    raise exception 'deleting the reported post re-opened the report';
  end if;
end $$;

-- 6. The nightly count. Three rows, three states, and only one of them may be
--    visible to a public workflow log — as a number.
set local role service_role;

insert into public.reports (id, reporter_id, reported_user_id, created_at)
values ('00000000-0000-0000-0000-0000000030b2',
        '00000000-0000-0000-0000-000000003003',
        '00000000-0000-0000-0000-000000003002',
        now() - interval '50 hours');

-- An older report that is already CLOSED: it must not count, and it must not be
-- the one "oldest open" reports. Getting that wrong turns a cleared queue into
-- a permanent nightly warning nobody can act on, which is how a warning stops
-- being read.
insert into public.reports (id, reporter_id, reported_user_id, created_at, handled_action)
values ('00000000-0000-0000-0000-0000000030b3',
        '00000000-0000-0000-0000-000000003002',
        '00000000-0000-0000-0000-000000003003',
        now() - interval '200 hours', 'dismissed');

do $$
declare
  v_open  int;
  v_hours int;
begin
  select open_count, oldest_open_hours into v_open, v_hours from public.open_report_stats();
  -- b1 is handled (step 4), b2 is open and 50 hours old, b3 is handled.
  if v_open <> 1 then
    raise exception 'open_report_stats counted % open report(s), expected 1', v_open;
  end if;
  if v_hours <> 50 then
    raise exception 'oldest_open_hours was % — a handled report is setting the age', v_hours;
  end if;

  -- Re-open the one from step 5 and the older OPEN row becomes the age.
  update public.reports set handled_action = null
   where id = '00000000-0000-0000-0000-0000000030b1';
  select open_count, oldest_open_hours into v_open, v_hours from public.open_report_stats();
  if v_open <> 2 then
    raise exception 'a re-opened report did not come back to the queue (% open)', v_open;
  end if;
  if v_hours <> 50 then
    raise exception 'oldest_open_hours moved to the newer report (%)', v_hours;
  end if;

  -- An empty queue answers 0, not null. A nightly job comparing null against a
  -- threshold does nothing at all, and does it quietly.
  update public.reports set handled_action = 'dismissed' where handled_at is null;
  select open_count, oldest_open_hours into v_open, v_hours from public.open_report_stats();
  if v_open <> 0 or v_hours <> 0 then
    raise exception 'an empty queue answered (%, %)', v_open, v_hours;
  end if;
end $$;

reset role;

-- 7. The queue's index. `where handled_at is null` is every read this feature
--    makes — the CLI's list, the nightly count — and a full index would scan the
--    whole history of handled reports to answer it.
do $$
begin
  if not exists (
    select 1 from pg_index i
     join pg_class c on c.oid = i.indexrelid
    where c.relname = 'reports_open_idx' and i.indpred is not null
  ) then
    raise exception 'reports_open_idx is missing or is not partial';
  end if;
end $$;

-- 8. TOLERANT OF EXISTING ROWS, proved against rows that already exist rather
--    than against a comment in the migration.
--
-- Every assertion above ran on a table this test filled itself, in a database
-- where the migration had already been applied to an EMPTY `reports` — which is
-- the one situation the real project will never be in. The backlog is the
-- hazard: a `not null default now()`, or a tidying `update ... where handled_at
-- is null` in a later hand, closes every report ever filed, all at once, with a
-- timestamp indistinguishable from a human decision. Nothing downstream would
-- notice — the queue simply goes quiet and stays quiet.
--
-- So the real migration file gets run again over a table that already holds
-- reports (`:migrations_dir` comes from run_sql_tests.sh, the same trick test 17
-- uses) — TWICE, because the two runs prove different things and the first one
-- alone was mistaken for both.
update public.reports set handled_action = null
 where id = '00000000-0000-0000-0000-0000000030b1';

create temporary table triage_before on commit drop as
  select id, created_at, handled_at, handled_action from public.reports;

-- 8a. Idempotence. `supabase db push` will not re-run a recorded version, but a
--     hand-run `psql -f` during a recovery will, so running the file over a
--     database that already has it must be a no-op on the rows.
\i :migrations_dir/20260828000100_reports_triage.sql

do $$
declare
  v_bad  text;
  v_open int;
begin
  select string_agg(r.id::text, ', ' order by r.id::text) into v_bad
    from public.reports r
    join triage_before b on b.id = r.id
   where r.created_at     is distinct from b.created_at
      or r.handled_at     is distinct from b.handled_at
      or r.handled_action is distinct from b.handled_action;
  if v_bad is not null then
    raise exception 're-applying the migration rewrote existing reports: %', v_bad;
  end if;

  select count(*) into v_open from public.reports where handled_at is null;
  if v_open <> 1 then
    raise exception 're-applying the migration left % open report(s), expected 1', v_open;
  end if;
end $$;

-- 8b. The assertion 8a CANNOT make, and the reason this step is two steps.
--
-- Both column adds are `add column IF NOT EXISTS`, so on that second run they
-- were no-ops: 8a proves the FILE CONTAINS NO DATA-MODIFYING STATEMENT, which
-- is a real property and a much narrower one than "the backlog survives the
-- deploy". The ADD COLUMN path itself — the only line that will ever touch the
-- staging project's existing rows — never ran. Mutate the migration to
-- `add column if not exists handled_at timestamptz default now()` and 8a alone
-- stays green, while the real deploy back-fills every report ever filed and
-- then aborts on the pair constraint.
--
-- So put the table into the shape deploy day will actually find: the rows, and
-- no triage columns at all. Dropping the columns takes the constraint and the
-- partial index with them (both are defined over the columns), which is exactly
-- the pre-migration state. Then run the file for real.
alter table public.reports drop column handled_at;
alter table public.reports drop column handled_action;

\i :migrations_dir/20260828000100_reports_triage.sql

do $$
declare
  v_bad    text;
  v_rows   int;
  v_closed int;
begin
  -- ADD COLUMN must not disturb the evidence. created_at is the only column
  -- from the snapshot still comparable — handled_at/handled_action were just
  -- dropped, which is the point.
  select string_agg(r.id::text, ', ' order by r.id::text) into v_bad
    from public.reports r
    join triage_before b on b.id = r.id
   where r.created_at is distinct from b.created_at;
  if v_bad is not null then
    raise exception 'adding the triage columns disturbed existing reports: %', v_bad;
  end if;

  select count(*),
         count(*) filter (where handled_at is not null or handled_action is not null)
    into v_rows, v_closed
    from public.reports;
  if v_rows <> 3 then
    raise exception 'the backlog changed size across the migration (% rows)', v_rows;
  end if;
  -- THE assertion. A default on either column closes every report ever filed on
  -- the day this migration runs, with a timestamp indistinguishable from a
  -- human decision, and nothing downstream would ever say so.
  if v_closed <> 0 then
    raise exception
      '% pre-existing report(s) arrived CLOSED — a default on a triage column has shut the backlog', v_closed;
  end if;

  -- ...and the rest of the file came back over them, rather than the columns
  -- landing bare because a `drop constraint if exists` found nothing to replace.
  if not exists (select 1 from pg_constraint
                  where conname = 'reports_handled_pair'
                    and conrelid = 'public.reports'::regclass) then
    raise exception 'reports_handled_pair did not come back with the columns';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'reports_stamp_handled'
                    and tgrelid = 'public.reports'::regclass) then
    raise exception 'reports_stamp_handled did not come back with the columns';
  end if;
end $$;

rollback;
