-- v4 Phase D — UGC reports.
--
-- App Store guideline 1.2 wants a way to flag user-generated content before the
-- app goes public, and SPEC-V4 §4 parks exactly that: a "report this photo"
-- action on any buddy photo, with leaving the circle as the block mechanism.
-- This table is the report half. It is deliberately the smallest thing that can
-- be honest — one row per (reporter, post), written once by the reporter and
-- read only by whoever triages it with the service-role key.
--
-- NOTE ON ORDERING: this table is created AFTER the blanket revoke/grant block
-- in 20260821000200_rls.sql has already run, so it inherits the project's
-- default privileges on `public` — which hand anon AND authenticated all four
-- verbs on every newly created table. A migration that merely declines to grant
-- is therefore not enough here; the revokes below are the whole point, and
-- test 12's sweep is what catches the day someone forgets them.

create table if not exists public.reports (
  -- Client-generated, like posts.id: a replayed op collides on this key instead
  -- of filing a second report. The default is there for a hand-written or
  -- moderation-side insert that has no uuid to offer.
  id          uuid primary key default gen_random_uuid(),

  -- Every foreign key here is ON DELETE SET NULL. Neither alternative works:
  --
  --   * CASCADE from posts would let the reported member delete the complaint
  --     by deleting the photo — undo is a button in the app, so "report me and
  --     I'll tap undo" erases the report before a human ever reads it. Same for
  --     the reporter's own account: deleting it must not retract a complaint
  --     they made about somebody else's content.
  --   * NO ACTION / RESTRICT (the default) fails the other way: a post could no
  --     longer be deleted at all while a report pointed at it, so undo,
  --     delete_account() and the retention sweep would all start erroring on
  --     precisely the rows a moderator cares about. A reported photo would
  --     become the one photo nobody can remove — kept alive in the bucket by
  --     the complaint against it. The report would be resurrecting the post.
  --
  -- SET NULL keeps both promises at once: the delete proceeds untouched, and the
  -- report survives it.
  --
  -- NOT ENOUGH ON ITS OWN, though — surviving as an anonymous dated fact still
  -- let the reported member erase who they were by tapping undo. The report
  -- keeps its own copy of the subject (`reported_user_id`, `photo_path`), which
  -- 20260821000800_reports_subject.sql adds and pins against the posts row.
  reporter_id uuid references auth.users (id)     on delete set null,
  post_id     uuid references public.posts (id)   on delete set null,
  circle_id   uuid references public.circles (id) on delete set null,

  -- Free text from the reporter. Bounded because it is free text a signed-in
  -- user can write at will, and 500 characters is more than "why" ever needs;
  -- null is allowed because a report with no words is still actionable (a human
  -- looks at the photo).
  reason      text check (reason is null or char_length(reason) <= 500),

  -- Server-owned, and outside the INSERT grant below like every other
  -- created_at in this schema.
  created_at  timestamptz not null default now(),

  -- One report per reporter per post. Reporting the same photo twice is the
  -- same report, so this is the semantics AND the only cap the table needs: a
  -- member's ceiling becomes "the posts they can actually see", which cap-8 and
  -- the retention sweep already bound.
  --
  -- The client CANNOT swallow the collision by naming this pair as an
  -- ON CONFLICT target — an inference clause needs SELECT privilege on the
  -- arbiter columns, and these two are precisely the pair that would publish
  -- who reported whom. So a double-tap or a replayed op surfaces as 23505 and
  -- the client reads that as "already reported" (CircleSync already has
  -- isUniqueViolation). Test 25 pins that, because the alternative reading —
  -- "grant SELECT on the arbiter columns" — undoes the whole table.
  unique (reporter_id, post_id)
);

alter table public.reports enable row level security;

-- The reporter may INSERT their own report and read NOTHING back.
--
-- That asymmetry is the design, not an oversight. A circle is eight people who
-- know each other, so a readable reports table is an enumeration of who
-- reported whom: one `select *` and a member learns that three of their friends
-- flagged the same photo, or that somebody flagged theirs. There is no UPDATE
-- or DELETE either — a report is a fact that was filed, not a message that can
-- be edited or withdrawn, and "I can see my own row" is one widened policy away
-- from "I can see yours".
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated
with check (
  reporter_id = auth.uid()
  and circle_id = public.current_circle_id()
  -- Re-derive the subject from the database rather than trusting the body (the
  -- same rule the notify function follows): the post must exist and be one this
  -- caller can actually see. Without it a member could file reports naming any
  -- uuid at all, or attribute one to a circle they have left. The predicate is
  -- spelled out instead of leaning on posts' own SELECT policy so that
  -- loosening that policy later cannot quietly widen this one.
  and reports.post_id is not null
  and exists (
    select 1 from public.posts p
     where p.id = reports.post_id
       and p.circle_id = public.current_circle_id()
  )
);

-- Grants --------------------------------------------------------------------
-- anon gets nothing, and `authenticated` is reset before anything is handed
-- back — see the ordering note at the top of this file.
revoke all on public.reports from anon;
revoke all on public.reports from authenticated;

-- COLUMN-SCOPED, like every other INSERT in this schema: the policy answers
-- "which rows", only the grant answers "which columns", and created_at is the
-- server's.
--
-- There is no SELECT grant, and that has a consequence the client must respect:
-- RETURNING needs SELECT privilege, so the insert has to ask for
-- `returning: .minimal` (PostgREST `Prefer: return=minimal`) or Postgres
-- refuses the statement outright. backend/README.md spells out the call shape.
grant insert (id, reporter_id, post_id, circle_id, reason)
      on public.reports to authenticated;

-- Triage runs with the service-role key, which bypasses RLS entirely and is
-- only ever held by an edge function or an operator — never by a client.
grant select, insert, update, delete on public.reports to service_role;

-- Both indexes sit on the WRITE path, not just a moderator's read path: an
-- ON DELETE SET NULL scans the referencing table on every parent delete, and
-- deleting a post is ordinary user traffic here (undo), not a rare admin event.
-- The reporter FK needs no index of its own — the unique constraint above
-- already leads with reporter_id.
create index if not exists reports_post_idx   on public.reports (post_id);
create index if not exists reports_circle_idx on public.reports (circle_id, created_at desc);
