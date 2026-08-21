-- v4 Phase A — row level security.
--
-- Automatic RLS is OFF on this project, so every table below gets an explicit
-- `enable row level security`. Test 12 walks pg_class and fails if one is missed.
--
-- The read predicate everywhere is "the row belongs to MY circle"; the write
-- predicate is "…and it is my own row". That is the whole model.

-- SECURITY DEFINER on purpose: called from circle_members' own policy it would
-- otherwise recurse through that policy forever.
create or replace function public.current_circle_id() returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$ select circle_id from public.circle_members where user_id = auth.uid() limit 1 $$;

alter table public.profiles          enable row level security;
alter table public.circles           enable row level security;
alter table public.circle_members    enable row level security;
alter table public.posts             enable row level security;
alter table public.excused_days      enable row level security;
alter table public.recovery_weeks    enable row level security;
alter table public.custom_challenges enable row level security;
alter table public.devices           enable row level security;
alter table public.nudges            enable row level security;
alter table public.retention_runs    enable row level security;

-- profiles ------------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
using (
  id = auth.uid()
  or id in (select user_id from public.circle_members where circle_id = public.current_circle_id())
);

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated
with check (id = auth.uid());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
using (id = auth.uid()) with check (id = auth.uid());

-- circles -------------------------------------------------------------------
-- No INSERT policy: circles are born in create_circle() so the code + membership
-- land in one transaction.
drop policy if exists circles_select on public.circles;
create policy circles_select on public.circles for select to authenticated
using (id = public.current_circle_id());

drop policy if exists circles_update on public.circles;
create policy circles_update on public.circles for update to authenticated
using (id = public.current_circle_id()) with check (id = public.current_circle_id());

-- circle_members ------------------------------------------------------------
-- No INSERT policy: joining goes through join_circle() so the cap and the
-- one-circle rule are enforced under a lock.
drop policy if exists circle_members_select on public.circle_members;
create policy circle_members_select on public.circle_members for select to authenticated
using (circle_id = public.current_circle_id());

-- Leave-only exits (§2): you can drop yourself, never anybody else.
drop policy if exists circle_members_delete on public.circle_members;
create policy circle_members_delete on public.circle_members for delete to authenticated
using (user_id = auth.uid());

-- posts ---------------------------------------------------------------------
drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select to authenticated
using (circle_id = public.current_circle_id());

drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts for insert to authenticated
with check (user_id = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists posts_update on public.posts;
create policy posts_update on public.posts for update to authenticated
using (user_id = auth.uid() and circle_id = public.current_circle_id())
with check (user_id = auth.uid() and circle_id = public.current_circle_id());

-- Undo deletes the post (§3).
drop policy if exists posts_delete on public.posts;
create policy posts_delete on public.posts for delete to authenticated
using (user_id = auth.uid() and circle_id = public.current_circle_id());

-- excused_days --------------------------------------------------------------
drop policy if exists excused_days_select on public.excused_days;
create policy excused_days_select on public.excused_days for select to authenticated
using (circle_id = public.current_circle_id());

drop policy if exists excused_days_insert on public.excused_days;
create policy excused_days_insert on public.excused_days for insert to authenticated
with check (user_id = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists excused_days_update on public.excused_days;
create policy excused_days_update on public.excused_days for update to authenticated
using (user_id = auth.uid() and circle_id = public.current_circle_id())
with check (user_id = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists excused_days_delete on public.excused_days;
create policy excused_days_delete on public.excused_days for delete to authenticated
using (user_id = auth.uid() and circle_id = public.current_circle_id());

-- recovery_weeks ------------------------------------------------------------
drop policy if exists recovery_weeks_select on public.recovery_weeks;
create policy recovery_weeks_select on public.recovery_weeks for select to authenticated
using (circle_id = public.current_circle_id());

drop policy if exists recovery_weeks_insert on public.recovery_weeks;
create policy recovery_weeks_insert on public.recovery_weeks for insert to authenticated
with check (user_id = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists recovery_weeks_update on public.recovery_weeks;
create policy recovery_weeks_update on public.recovery_weeks for update to authenticated
using (user_id = auth.uid() and circle_id = public.current_circle_id())
with check (user_id = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists recovery_weeks_delete on public.recovery_weeks;
create policy recovery_weeks_delete on public.recovery_weeks for delete to authenticated
using (user_id = auth.uid() and circle_id = public.current_circle_id());

-- custom_challenges ---------------------------------------------------------
drop policy if exists custom_challenges_select on public.custom_challenges;
create policy custom_challenges_select on public.custom_challenges for select to authenticated
using (circle_id = public.current_circle_id());

drop policy if exists custom_challenges_insert on public.custom_challenges;
create policy custom_challenges_insert on public.custom_challenges for insert to authenticated
with check (created_by = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists custom_challenges_update on public.custom_challenges;
create policy custom_challenges_update on public.custom_challenges for update to authenticated
using (created_by = auth.uid() and circle_id = public.current_circle_id())
with check (created_by = auth.uid() and circle_id = public.current_circle_id());

drop policy if exists custom_challenges_delete on public.custom_challenges;
create policy custom_challenges_delete on public.custom_challenges for delete to authenticated
using (created_by = auth.uid() and circle_id = public.current_circle_id());

-- devices -------------------------------------------------------------------
-- Push tokens are private to their owner; the notify function reads them with
-- the service-role key, never through a user session.
drop policy if exists devices_all on public.devices;
create policy devices_all on public.devices for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

-- nudges --------------------------------------------------------------------
drop policy if exists nudges_select on public.nudges;
create policy nudges_select on public.nudges for select to authenticated
using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists nudges_insert on public.nudges;
create policy nudges_insert on public.nudges for insert to authenticated
with check (
  sender_id = auth.uid()
  and recipient_id in (select user_id from public.circle_members where circle_id = public.current_circle_id())
);
-- No UPDATE/DELETE policy: a nudge row is the rate-limit token, so it must not be
-- editable or clearable by the sender. Retention prunes them after 30 days.

-- retention_runs: RLS on, zero policies — only service_role (which bypasses RLS)
-- ever touches it.

-- Grants --------------------------------------------------------------------
-- anon gets NOTHING: every table here is behind a signed-in user.
--
-- REVOKE, not merely "don't grant". A real Supabase project ships default
-- privileges on `public` that hand every newly created table to anon,
-- authenticated AND service_role — so a migration that only refrains from
-- granting still leaves anon holding select/insert/update/delete on all ten
-- tables. RLS saves us either way (every policy below is `to authenticated`,
-- so anon matches none and reads zero rows), but "the key is not the security
-- boundary" is only a comfortable claim if the privileges agree with it.
-- Explicitly stripping anon makes the deployed project match what test 12
-- asserts, on a plain Postgres and on Supabase alike.
--
-- Scoped to the tables that exist right now rather than to the schema's DEFAULT
-- privileges: changing those would silently reshape every table a future
-- migration (or a human in the dashboard) creates. A new table that forgets its
-- own revoke is caught by test 12 before it can ever reach a project.
--
-- `authenticated` is wiped for the same reason and then granted back, verb by
-- verb, in the block below. Without the wipe the per-table grants are decoration:
-- the default privileges have already handed authenticated all four verbs on all
-- ten tables, including retention_runs — the sweep's own lease, which is supposed
-- to be service_role-only and has no policy at all. Reset first, then grant, and
-- the deployed privilege matrix is exactly the one written here.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all tables    in schema public from authenticated;
revoke all on all sequences in schema public from authenticated;

grant usage on schema public to authenticated, service_role;

grant select, insert, update         on public.profiles          to authenticated;
grant select, update                 on public.circles           to authenticated;
grant select, delete                 on public.circle_members    to authenticated;
grant select, insert, update, delete on public.posts             to authenticated;
grant select, insert, update, delete on public.excused_days      to authenticated;
grant select, insert, update, delete on public.recovery_weeks    to authenticated;
grant select, insert, update, delete on public.custom_challenges to authenticated;
grant select, insert, update, delete on public.devices           to authenticated;
grant select, insert                 on public.nudges            to authenticated;

grant select, insert, update, delete on all tables in schema public to service_role;

-- `from public` drops the implicit grant every function is born with; `from anon`
-- is separate and necessary, because an EXPLICIT grant (which Supabase's default
-- privileges on `public` hand out) survives a revoke aimed at PUBLIC.
revoke execute on function public.current_circle_id()  from public, anon;
revoke execute on function public.circle_max_members() from public, anon;
grant  execute on function public.current_circle_id()  to authenticated, service_role;
grant  execute on function public.circle_max_members() to authenticated, service_role;
