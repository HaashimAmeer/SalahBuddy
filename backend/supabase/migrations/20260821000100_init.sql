-- v4 Phase A — schema.
--
-- The server stores FACTS, never scores: SPEC-V4 §0 keeps GameEngine as the one
-- source of scoring truth, so every client re-derives the leaderboard from the
-- same synced rows. That is why there is no xp column on posts and no server-side
-- tier math anywhere in this file.

create extension if not exists pgcrypto;

-- Enum labels are the Swift rawValues verbatim (Prayer / LogTier in Models.swift).
-- If these ever drift, decoding breaks silently on device — keep them quoted and exact.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'prayer_kind') then
    create type public.prayer_kind as enum ('fajr','dhuhr','asr','maghrib','isha');
  end if;
  if not exists (select 1 from pg_type where typname = 'log_tier') then
    create type public.log_tier as enum ('onTime','prayed','lastCall','closeCall','qada');
  end if;
end $$;

-- One shared circle per user, 8 MEMBERS TOTAL (not 8 friends + you — see README).
create or replace function public.circle_max_members() returns int
language sql immutable
as $$ select 8 $$;

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  name         text not null default '',
  avatar_emoji text,
  avatar_path  text,
  member_kind  text check (member_kind in ('brother','sister') or member_kind is null),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- The code CHECK is load-bearing, not decoration. `circles` is the one table a
-- member can UPDATE, and without a format constraint an empty string is a legal
-- code — which turns every mistyped/blank join into a silent capture. The grant
-- in 20260821000200_rls.sql is column-scoped to (name, emoji) so nothing but
-- create_circle() ever writes this column, and the CHECK is the second lock.
create table if not exists public.circles (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique
             check (code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'),
  name       text not null default 'Your Circle',
  emoji      text not null default '🤝',
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

-- unique (user_id) IS the one-circle-per-user rule; the ≤8 cap is a trigger
-- (see 20260821000300_triggers.sql) because it needs a count under a lock.
--
-- announced_at is the "member joined" push lease: notify claims it with a
-- conditional UPDATE so a client that POSTs {kind:"join"} in a loop fans out
-- exactly once. `authenticated` holds no UPDATE grant here, so only the
-- service-role client in the edge function can set it.
create table if not exists public.circle_members (
  circle_id    uuid not null references public.circles (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  joined_at    timestamptz not null default now(),
  announced_at timestamptz,
  primary key (circle_id, user_id),
  unique (user_id)
);

-- Who left which circle, and when. A departure is the clock SPEC §2/§4 purge on
-- ("posts stay visible until the week ends, then purge with the retention job"):
-- without a record of it the sweep has nothing to age off, because the rows
-- themselves still look like any other member's. Written by a trigger on
-- circle_members so it catches leave_circle() AND the direct DELETE the
-- circle_members_delete policy allows; cleared again on re-join.
create table if not exists public.circle_departures (
  user_id   uuid not null references auth.users (id) on delete cascade,
  circle_id uuid not null references public.circles (id) on delete cascade,
  left_at   timestamptz not null default now(),
  primary key (user_id, circle_id)
);

-- Storage paths whose owning row is gone (undo, account deletion, retention) or
-- whose photo was replaced. Nothing else in the database remembers them, so
-- without this table a deleted post's JPEG is unreachable and undeletable
-- forever — the retention sweep discovers paths only through posts. Rows are
-- removed by confirm_photo_deletions() once Storage has actually accepted the
-- delete, which is what makes a failed sweep resume instead of leaking.
create table if not exists public.photo_tombstones (
  path       text primary key,
  created_at timestamptz not null default now()
);

-- id is client-generated so the offline queue can retry uploads idempotently (§3).
-- day_key is the CLIENT's schedule day — the Isha-after-midnight rule travels with
-- the post and the server never re-derives it.
--
-- The uniqueness key carries circle_id even though §7 sketches it without one.
-- A user's posts survive them leaving a circle (§2), so "one post per user per
-- day per prayer" would make the join-backfill of the current week collide with
-- the rows still sitting in the circle they just left — and the on-conflict
-- escape is closed too, because posts_update's predicate names the CURRENT
-- circle. The fact is per circle; the key says so.
--
-- notified_at is the "first post" push lease, claimed by the notify function
-- with a conditional UPDATE. `authenticated` gets no grant on it (nor on
-- created_at/updated_at) — see the column-scoped grants in the RLS migration.
create table if not exists public.posts (
  id              uuid primary key,
  user_id         uuid not null references auth.users (id) on delete cascade,
  circle_id       uuid not null references public.circles (id) on delete cascade,
  day_key         text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  prayer          public.prayer_kind not null,
  tier            public.log_tier not null,
  logged_at       timestamptz not null,
  jamaat          boolean not null default false,
  place_label     text,
  photo_path      text,
  travel_combined boolean not null default false,
  notified_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, circle_id, day_key, prayer)
);

-- A bare flag. Period privacy is absolute (§3): there is NO reason column here,
-- and test 08 fails the build if anyone ever adds one.
-- circle_id is part of the key for the same reason it is on posts: the row
-- outlives the membership, so a circle switch must not collide with it.
create table if not exists public.excused_days (
  user_id    uuid not null references auth.users (id) on delete cascade,
  circle_id  uuid not null references public.circles (id) on delete cascade,
  day_key    text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  primary key (user_id, circle_id, day_key)
);

-- Opaque weekly total: the scoreboard sees the number, never what earned it.
create table if not exists public.recovery_weeks (
  user_id    uuid not null references auth.users (id) on delete cascade,
  circle_id  uuid not null references public.circles (id) on delete cascade,
  week_key   text not null check (week_key ~ '^\d{4}-W\d{2}$'),
  xp         int not null default 0 check (xp >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, circle_id, week_key)
);

-- id is the client's "custom-<uuid>" string so ChallengeEngine keeps its own identity.
create table if not exists public.custom_challenges (
  id         text primary key,
  circle_id  uuid not null references public.circles (id) on delete cascade,
  created_by uuid not null references auth.users (id) on delete cascade,
  prayer     public.prayer_kind not null,
  days       int not null check (days between 2 and 7),
  week_key   text check (week_key ~ '^\d{4}-W\d{2}$'),
  created_at timestamptz not null default now()
);

-- notify_friend_activity mirrors AppSettings.notifyFriendActivity, which is OFF
-- by default (Models.swift). §6's friend-activity push is opt-in, and iOS cannot
-- un-deliver an alert it already showed — so the toggle has to live where the
-- fan-out reads it, not only on the device that owns it.
create table if not exists public.devices (
  user_id                 uuid not null references auth.users (id) on delete cascade,
  apns_token              text primary key,
  environment             text not null default 'production'
                          check (environment in ('production','sandbox')),
  notify_friend_activity  boolean not null default false,
  updated_at              timestamptz not null default now()
);

-- One device row per phone; the cap trigger (triggers migration) prunes the
-- oldest beyond this so a member cannot register thousands of tokens and turn
-- one circle post into a fan-out that outlives the function's wall clock.
create or replace function public.max_devices_per_user() returns int
language sql immutable
as $$ select 10 $$;

-- The primary key is the rate-limit TOKEN — but it is only a rate limit once
-- day_key is pinned to the server's clock. day_key is client-supplied (it has
-- to be: it is the client's schedule day, §3), so on its own the key hands a
-- sender ~18M distinct tokens against one recipient: 10,000 years of calendar
-- × 5 prayers. record_nudge() bounds it to ±1 day of today and caps a sender's
-- hourly total; the key stops the honest repeat, those two stop the abuse.
create table if not exists public.nudges (
  sender_id    uuid not null references auth.users (id) on delete cascade,
  recipient_id uuid not null references auth.users (id) on delete cascade,
  day_key      text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  prayer       public.prayer_kind not null,
  created_at   timestamptz not null default now(),
  primary key (sender_id, recipient_id, day_key, prayer)
);

-- Single-row lease so any number of retention callers collapse into one real run.
create table if not exists public.retention_runs (
  id          int primary key default 1 check (id = 1),
  last_run_at timestamptz not null default '-infinity'
);
insert into public.retention_runs (id) values (1) on conflict (id) do nothing;

-- A cross-transaction meter for join_circle's brute-force budget.
--
-- It is a SEQUENCE and not a table on purpose: an unknown invite code raises
-- SB404, which rolls the whole PostgREST transaction back — including any row a
-- counter had just written. nextval/setval are the only writes in Postgres that
-- survive a rollback, which makes them the only way to remember an attempt that
-- failed. The value encodes (hour_slot * 1e6 + attempts_this_hour) so the window
-- resets itself with no cron and no extra table. See join_circle().
create sequence if not exists public.join_attempt_meter as bigint start 1;

create index if not exists posts_circle_day_idx      on public.posts (circle_id, day_key, prayer);
create index if not exists posts_circle_logged_idx   on public.posts (circle_id, logged_at desc);
create index if not exists posts_photo_retention_idx on public.posts (created_at) where photo_path is not null;
create index if not exists excused_days_circle_idx   on public.excused_days (circle_id, day_key);
create index if not exists recovery_weeks_circle_idx on public.recovery_weeks (circle_id, week_key);
create index if not exists custom_ch_circle_idx      on public.custom_challenges (circle_id, week_key);
create index if not exists devices_user_idx          on public.devices (user_id, updated_at desc);
create index if not exists nudges_recipient_idx      on public.nudges (recipient_id, created_at desc);
create index if not exists nudges_sender_idx         on public.nudges (sender_id, created_at desc);
create index if not exists departures_left_idx       on public.circle_departures (left_at);
create index if not exists tombstones_created_idx    on public.photo_tombstones (created_at);
