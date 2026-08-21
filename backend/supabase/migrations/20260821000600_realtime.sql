-- v4 Phase A — realtime.
--
-- The Today grid fills in live from `posts` (§6: "subscribe to the circle's
-- posts channel while the app is open"), and `custom_challenges` so a challenge
-- the circle creates appears without a refetch.
--
-- circle_members and excused_days are DELIBERATELY NOT PUBLISHED, and this is a
-- privacy decision, not an omission. Realtime's Postgres-Changes cannot apply
-- RLS to DELETE events — there is no row left to test a policy against — so a
-- delete is broadcast to every subscriber in the project, reduced to the row's
-- primary key. For these two tables the primary key IS the private fact:
--
--   excused_days   (user_id, circle_id, day_key)  → "user X was resting on day Y"
--   circle_members (circle_id, user_id)           → the whole user→circle graph
--
-- Un-marking a rest day would therefore announce it product-wide, to strangers,
-- from the one table whose header says period privacy is absolute (§3). Posting
-- is the event the grid actually needs; the client re-fetches the roster and the
-- resting flags when a posts event arrives, or on foreground.
--
-- ONE TABLE PER STATEMENT, deliberately. `alter publication ... add table a, b, c`
-- is all-or-nothing: if a single one of them is already published — which is what
-- happens the moment somebody flips a table's Realtime toggle in the dashboard, or
-- a half-applied push is retried — the whole statement raises duplicate_object and
-- the remaining tables are silently never added. The migration would still report
-- success while the Today grid quietly stopped receiving events. Adding them one
-- at a time makes each already-published table a no-op instead of a poison pill.
do $$
declare
  t text;
begin
  foreach t in array array['posts', 'custom_challenges']
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception
      when undefined_object then
        raise notice 'supabase_realtime publication absent — skipping realtime registration';
        exit;
      when duplicate_object then
        raise notice 'public.% is already in supabase_realtime', t;
    end;
  end loop;

  -- Idempotent removal: a project (or an earlier version of this migration) that
  -- published these has to converge on the list above, not keep leaking.
  foreach t in array array['circle_members', 'excused_days']
  loop
    begin
      execute format('alter publication supabase_realtime drop table public.%I', t);
    exception
      when undefined_object then null;   -- publication or membership absent: fine
      when undefined_table  then null;
    end;
  end loop;
end $$;

-- Default (primary-key) replica identity, stated explicitly because the obvious
-- thing to reach for here is `full` — and `full` is a trap. It would only change
-- the DELETE payload if walrus trusted it, and walrus deliberately truncates a
-- delete's old_record to the primary key whenever RLS is enabled on the table,
-- precisely because deletes cannot be policy-filtered. So `full` buys the WAL
-- cost of writing the whole old tuple on every UPDATE and delivers nothing.
--
-- What the client gets on an undo is therefore `{id}` — an opaque client-minted
-- uuid that says nothing about who, when or which prayer, and that CircleSnapshot
-- already resolves against its own mirror by id.
alter table public.posts replica identity default;
