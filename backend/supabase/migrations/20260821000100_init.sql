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

create table if not exists public.circles (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null default 'Your Circle',
  emoji      text not null default '🤝',
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

-- unique (user_id) IS the one-circle-per-user rule; the ≤8 cap is a trigger
-- (see 20260821000300_triggers.sql) because it needs a count under a lock.
create table if not exists public.circle_members (
  circle_id uuid not null references public.circles (id) on delete cascade,
  user_id   uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (circle_id, user_id),
  unique (user_id)
);

-- id is client-generated so the offline queue can retry uploads idempotently (§3).
-- day_key is the CLIENT's schedule day — the Isha-after-midnight rule travels with
-- the post and the server never re-derives it.
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
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, day_key, prayer)
);

-- A bare flag. Period privacy is absolute (§3): there is NO reason column here,
-- and test 08 fails the build if anyone ever adds one.
create table if not exists public.excused_days (
  user_id    uuid not null references auth.users (id) on delete cascade,
  circle_id  uuid not null references public.circles (id) on delete cascade,
  day_key    text not null check (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
  created_at timestamptz not null default now(),
  primary key (user_id, day_key)
);

-- Opaque weekly total: the scoreboard sees the number, never what earned it.
create table if not exists public.recovery_weeks (
  user_id    uuid not null references auth.users (id) on delete cascade,
  circle_id  uuid not null references public.circles (id) on delete cascade,
  week_key   text not null check (week_key ~ '^\d{4}-W\d{2}$'),
  xp         int not null default 0 check (xp >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, week_key)
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

create table if not exists public.devices (
  user_id     uuid not null references auth.users (id) on delete cascade,
  apns_token  text primary key,
  environment text not null default 'production' check (environment in ('production','sandbox')),
  updated_at  timestamptz not null default now()
);

-- The primary key IS the rate limit: one nudge per sender per recipient per
-- prayer window (§6). No extra bookkeeping, no cron to reset it.
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

create index if not exists posts_circle_day_idx      on public.posts (circle_id, day_key);
create index if not exists posts_circle_logged_idx   on public.posts (circle_id, logged_at desc);
create index if not exists posts_photo_retention_idx on public.posts (created_at) where photo_path is not null;
create index if not exists excused_days_circle_idx   on public.excused_days (circle_id, day_key);
create index if not exists recovery_weeks_circle_idx on public.recovery_weeks (circle_id, week_key);
create index if not exists custom_ch_circle_idx      on public.custom_challenges (circle_id, week_key);
create index if not exists devices_user_idx          on public.devices (user_id);
create index if not exists nudges_recipient_idx      on public.nudges (recipient_id, created_at desc);
