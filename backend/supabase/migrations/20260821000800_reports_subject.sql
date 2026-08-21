-- v4 Phase D fix — a report has to keep saying WHO it is about.
--
-- 20260821000700 files a report as (reporter, post, circle, reason) with every
-- foreign key ON DELETE SET NULL, so that deleting the photo could not retract
-- the complaint. That half worked: the ROW survives, the SUBJECT does not. Undo
-- is an ordinary button available for the whole schedule day (`AppState.undoLog`)
-- and it deletes the `posts` row, which nulls `post_id`; the photo is tombstoned
-- and swept behind it. Triage was then left with (created_at, reason, circle_id,
-- reporter_id) — no reported member, no path, no image — so a member could
-- defeat every report against them by tapping undo, which is the exact evasion
-- SET NULL was chosen over CASCADE to prevent.
--
-- So the report keeps its own copy of the subject: who was reported, and where
-- the picture was. Both are PINNED by the insert policy against the `posts` row
-- itself rather than taken on trust from the body — the same rule the `notify`
-- function follows. A freely-chosen copy would be a way to name a friend in a
-- complaint they had nothing to do with.
--
-- A SEPARATE migration rather than an edit to 20260821000700: `supabase db push`
-- records applied versions and never re-runs one, so editing that file would not
-- reach a database that already has the table.

alter table public.reports
  add column if not exists reported_user_id uuid references auth.users (id) on delete set null;

-- The Storage path the photo was at when it was reported. Nullable because the
-- object outlives neither undo nor the ~30-day sweep, and a report whose photo
-- is already gone is still a report about a named member; it is here because
-- while the object DOES exist this is the only thing that leads a human to it.
alter table public.reports
  add column if not exists photo_path text;

comment on column public.reports.reported_user_id is
  'Who was reported. Pinned to posts.user_id by reports_insert, and kept so undo cannot anonymise the complaint.';
comment on column public.reports.photo_path is
  'The Storage path at report time. Pinned to posts.photo_path by reports_insert.';

-- The subject is re-derived from the database, exactly like the post and the
-- circle already were.
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated
with check (
  reporter_id = auth.uid()
  and circle_id = public.current_circle_id()
  -- The post must exist and be one this caller can actually see; without it a
  -- member could file reports naming any uuid at all, or attribute one to a
  -- circle they have left. Spelled out instead of leaning on posts' own SELECT
  -- policy so that loosening that policy later cannot quietly widen this one.
  and reports.post_id is not null
  -- A report that names no member is the anonymised row this migration exists
  -- to stop existing.
  and reports.reported_user_id is not null
  and exists (
    select 1 from public.posts p
     where p.id = reports.post_id
       and p.circle_id = public.current_circle_id()
       -- The two pins: the accused is the post's author, and the path is the
       -- post's path. Either one left to the client would be a free-text field
       -- pointing at whoever the client liked.
       and p.user_id = reports.reported_user_id
       and (reports.photo_path is null or reports.photo_path = p.photo_path)
  )
);

-- Column-scoped like every other INSERT in this schema, and still no SELECT:
-- the reporter writes the subject and reads nothing back.
grant insert (id, reporter_id, post_id, circle_id, reason, reported_user_id, photo_path)
      on public.reports to authenticated;

-- Same justification as `reports_post_idx`: this sits on the WRITE path too. An
-- ON DELETE SET NULL scans the referencing table on every parent delete, and the
-- account sweep deletes `auth.users` rows in bulk.
create index if not exists reports_reported_idx on public.reports (reported_user_id, created_at desc);
