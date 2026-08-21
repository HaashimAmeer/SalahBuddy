-- Supabase shim for vanilla Postgres 16.
--
-- The sandbox has no Docker, so `supabase start` is out (SPEC-V4 §9). Instead the
-- migrations are applied to a scratch database that has just enough of Supabase's
-- managed surface for them to mean something: the three API roles, an auth schema
-- with a real users table and the auth.* claim helpers, and a minimal storage
-- schema so the bucket policies are genuinely created and testable.
--
-- This file is TEST INFRASTRUCTURE ONLY — it is never applied to a real project.

create extension if not exists pgcrypto;

-- Roles ---------------------------------------------------------------------
-- Roles are cluster-global, so this has to survive being re-run against a
-- cluster that already has them.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    -- Mirrors the real project: service_role bypasses RLS entirely.
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    create role supabase_auth_admin nologin noinherit;
  end if;
end $$;

-- Schemas -------------------------------------------------------------------
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

grant usage on schema auth       to anon, authenticated, service_role;
grant usage on schema storage    to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

-- auth ----------------------------------------------------------------------
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

-- PostgREST sets request.jwt.claims per request; the tests set it with
-- `set local request.jwt.claims = '{"sub":"…","role":"authenticated"}'`.
create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(nullif(auth.jwt() ->> 'role', ''), current_setting('role', true))
$$;

grant select on auth.users to service_role;

-- storage -------------------------------------------------------------------
create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  owner              uuid,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default now()
);

create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets (id) on delete cascade,
  name       text not null,
  owner      uuid,
  metadata   jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;

grant select                         on storage.buckets to authenticated, service_role;
grant select, insert, update, delete on storage.objects to authenticated, service_role;

-- Same semantics as the real one: the FOLDER parts of an object name, i.e. every
-- path segment except the filename.
create or replace function storage.foldername(name text) returns text[]
language plpgsql immutable
as $$
declare
  v_parts text[];
begin
  v_parts := string_to_array(name, '/');
  return v_parts[1:array_length(v_parts, 1) - 1];
end $$;

-- realtime ------------------------------------------------------------------
-- Real projects ship this publication; creating it here means the realtime
-- migration takes its real path instead of silently no-opping.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;
