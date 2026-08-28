-- v5 — the other end of the reports mailbox.
--
-- 20260821000700 built a table a reporter can write and NOBODY can read, and
-- 20260821000800 made sure what lands in it still names a member after the
-- accused taps undo. Both halves are about getting the complaint safely into the
-- box. Nothing in the schema has ever been about taking one back out: there is
-- no way to say "a human looked at this", so every report is open forever and
-- the second one filed about the same photo is indistinguishable from the first.
-- App Store guideline 1.2 wants a human who can READ and ACT before the app is
-- public; a reader with no way to close what it read is half a mailbox.
--
-- So: two columns, and the smallest vocabulary that can describe an outcome.
--
-- TOLERANT OF EXISTING ROWS, deliberately and in the plainest way there is —
-- both columns are nullable with no default, so every report already filed
-- reads as OPEN, which is exactly what it is. A `not null default now()` would
-- have marked the entire backlog handled on the day this migration ran, which
-- is the one thing a triage column must never do.
--
-- RLS STANCE UNCHANGED. There is no new policy and no new grant to
-- `authenticated`: 20260821000700's INSERT grant is column-scoped and names its
-- columns one by one, so a column added afterwards is outside it by
-- construction — a client can neither read a report's disposition nor write
-- one. `service_role` holds a TABLE-wide grant on `reports`, which does cover
-- new columns, and that is the whole access story. Test 12 pins both directions
-- so "the grant list happens to be short" cannot quietly become "the grant list
-- was widened and nobody noticed".

alter table public.reports
  add column if not exists handled_at timestamptz;

alter table public.reports
  add column if not exists handled_action text;

comment on column public.reports.handled_at is
  'When triage closed this report. NULL means open — including for every row filed before this migration.';
comment on column public.reports.handled_action is
  'What triage did: photo_removed or dismissed. NULL means open.';

-- One constraint doing two jobs, because they are the same job: a report is
-- either open or closed, and a closed one says what was done.
--
--   * The pair moves together. A `handled_at` with no action is a row that
--     says "somebody looked" and nothing else, which is not a disposition; an
--     action with no timestamp is a disposition nobody can put in order, and
--     the nightly count's "oldest open" is derived from exactly that ordering.
--   * The vocabulary is closed. Two words today, and both of them are things
--     the CLI can actually carry out — a resolution the tooling cannot perform
--     is a note, not an action.
--
-- A CHECK and not an enum type. The list will grow (an account-level action, a
-- "referred upstream"), and a check constraint can be replaced in a later
-- migration the ordinary way, whereas a value added to a pg enum can never be
-- taken back out. `prayer_kind` is an enum because the five prayers are not
-- going to change; a moderation vocabulary is the opposite kind of list.
alter table public.reports drop constraint if exists reports_handled_pair;
alter table public.reports
  add constraint reports_handled_pair check (
    (handled_at is null) = (handled_action is null)
    and (handled_action is null or handled_action in ('photo_removed', 'dismissed'))
  );

-- handled_at is the SERVER's, exactly like every other timestamp in this schema
-- (see touch_updated_at / freeze_created_at, which this copies). The writer is
-- an operator at a terminal, so the clock at risk is a laptop's, and "when was
-- this reported photo actually taken down" is the one number an App Review
-- question would be about. Deriving it from the action also means the CLI sends
-- ONE field and cannot get the pair out of step with the constraint above.
--
-- Re-handling keeps the original stamp unless the disposition itself changes:
-- re-running `dismiss` on a dismissed report is a no-op, while dismissed ->
-- photo_removed is a new decision and re-dates itself. Clearing the action
-- re-opens the report and takes the timestamp with it.
create or replace function public.stamp_report_handled() returns trigger
language plpgsql set search_path = public, pg_temp
as $$
begin
  if new.handled_action is null then
    new.handled_at := null;
  elsif tg_op = 'INSERT' then
    -- A moderation-side insert (the reason reports.id has a default at all).
    new.handled_at := now();
  elsif new.handled_action is distinct from old.handled_action then
    new.handled_at := now();
  else
    new.handled_at := old.handled_at;
  end if;
  return new;
end $$;

drop trigger if exists reports_stamp_handled on public.reports;
create trigger reports_stamp_handled before insert or update on public.reports
  for each row execute function public.stamp_report_handled();

-- The triage queue's own index, and the nightly count's. Partial on the open
-- set because that is the only set anything reads: a handled report is history,
-- and the whole point of the columns above is that history stops being scanned.
create index if not exists reports_open_idx
  on public.reports (created_at) where handled_at is null;

-- Nightly visibility, and the reason it is a FUNCTION rather than a query the
-- workflow spells out for itself.
--
-- `.github/workflows/maintenance.yml` runs on a PUBLIC repo: its logs are
-- readable by anyone on the internet, forever. A count is the ceiling of what
-- may appear there — not a reason, not a path, not who was reported, not even
-- how many distinct people are involved. Written inline, that ceiling is a
-- promise about a `jq` filter, and one schema change away from being false.
-- Written here, it is a promise about a RETURN TYPE: this function has no
-- column that could carry a row's content, so no edit to the workflow can make
-- it print one.
--
-- SECURITY INVOKER (the default) on purpose. It needs no elevation — the only
-- role that can execute it can already read the table — and a definer function
-- would be a readable window into `reports` that outlives whatever grant a
-- future migration revokes.
create or replace function public.open_report_stats()
returns table (open_count int, oldest_open_hours int)
language sql stable set search_path = public, pg_temp
as $$
  select count(*)::int,
         -- coalesce, not null: an empty queue is "0 hours old", and a nightly
         -- job comparing a null against a threshold silently does nothing.
         coalesce(floor(extract(epoch from (now() - min(created_at))) / 3600)::int, 0)
    from public.reports
   where handled_at is null
$$;

-- `from public` drops the grant every new function is born with; `from anon`
-- and `from authenticated` are separate and necessary, because a real project's
-- default privileges on `public` hand out EXPLICIT grants that a revoke aimed
-- at PUBLIC leaves standing. Same reasoning as the retention functions.
revoke execute on function public.open_report_stats() from public, anon, authenticated;
grant  execute on function public.open_report_stats() to service_role;
