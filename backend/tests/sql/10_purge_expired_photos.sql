-- 10. Retention: photo_path is cleared on posts older than the window, the path
--     is handed back for object deletion, fresh posts are untouched — and the
--     hand-back is DURABLE (a tombstone), so a Storage delete that fails is
--     retried next run instead of stranding a private JPEG forever.
--
--     Also pins the grace period on ownerless rows. The old sweep deleted a
--     leaver's excused_days the instant their membership went, which turned a
--     gentle "resting" into a wall of plain misses for the circle that still saw
--     their posts — the exact shaming outcome period privacy exists to prevent.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000801', 'old@example.test'),
  ('00000000-0000-0000-0000-000000000802', 'gone@example.test'),
  ('00000000-0000-0000-0000-000000000803', 'justleft@example.test');

insert into public.circles (id, code, name, created_by)
values ('00000000-0000-0000-0000-0000000008cc', 'PURGEA', 'Purge', '00000000-0000-0000-0000-000000000801');
insert into public.circle_members (circle_id, user_id)
values ('00000000-0000-0000-0000-0000000008cc', '00000000-0000-0000-0000-000000000801');

insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path, created_at) values
  ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-000000000801',
   '00000000-0000-0000-0000-0000000008cc', '2026-06-01', 'fajr', 'onTime', now() - interval '81 days',
   '00000000-0000-0000-0000-0000000008cc/00000000-0000-0000-0000-000000000801/old-a.jpg',
   now() - interval '81 days'),
  ('00000000-0000-0000-0000-0000000008a2', '00000000-0000-0000-0000-000000000801',
   '00000000-0000-0000-0000-0000000008cc', '2026-06-02', 'asr', 'prayed', now() - interval '31 days',
   '00000000-0000-0000-0000-0000000008cc/00000000-0000-0000-0000-000000000801/old-b.jpg',
   now() - interval '31 days'),
  ('00000000-0000-0000-0000-0000000008a3', '00000000-0000-0000-0000-000000000801',
   '00000000-0000-0000-0000-0000000008cc', '2026-08-20', 'isha', 'onTime', now() - interval '1 day',
   '00000000-0000-0000-0000-0000000008cc/00000000-0000-0000-0000-000000000801/fresh.jpg',
   now() - interval '1 day');

-- litter left behind long ago by a user who is in no circle any more
insert into public.excused_days (user_id, circle_id, day_key, created_at)
values ('00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-0000000008cc',
        '2026-06-05', now() - interval '40 days');
insert into public.recovery_weeks (user_id, circle_id, week_key, xp, updated_at)
values ('00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-0000000008cc',
        '2026-W23', 30, now() - interval '40 days');

-- ...and the same shape from someone who left YESTERDAY: still inside the grace
-- window, must survive, because their posts are still on the circle's week grid.
insert into public.excused_days (user_id, circle_id, day_key, created_at)
values ('00000000-0000-0000-0000-000000000803', '00000000-0000-0000-0000-0000000008cc',
        '2026-08-20', now() - interval '1 day');
insert into public.recovery_weeks (user_id, circle_id, week_key, xp, updated_at)
values ('00000000-0000-0000-0000-000000000803', '00000000-0000-0000-0000-0000000008cc',
        '2026-W34', 20, now() - interval '1 day');

insert into public.nudges (sender_id, recipient_id, day_key, prayer, created_at)
values ('00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000802',
        '2026-06-01', 'fajr', now() - interval '45 days');

-- Retention runs with the service role, never a user session.
set local role service_role;

do $$
declare
  v_paths text[];
begin
  select array_agg(p order by p) into v_paths from public.purge_expired_photo_rows(30) p;

  if coalesce(array_length(v_paths, 1), 0) <> 2 then
    raise exception 'expected 2 expired photo paths, got %', coalesce(v_paths::text, 'null');
  end if;
  if not (v_paths[1] like '%old-a.jpg' and v_paths[2] like '%old-b.jpg') then
    raise exception 'unexpected expired paths: %', v_paths::text;
  end if;

  if (select photo_path from public.posts where id = '00000000-0000-0000-0000-0000000008a1') is not null
     or (select photo_path from public.posts where id = '00000000-0000-0000-0000-0000000008a2') is not null then
    raise exception 'an expired photo_path was not cleared';
  end if;
  if (select photo_path from public.posts where id = '00000000-0000-0000-0000-0000000008a3') is null then
    raise exception 'a fresh photo_path was cleared';
  end if;

  -- the post itself stays: only the photo expires
  if (select count(*) from public.posts) <> 3 then
    raise exception 'purge deleted posts, it should only detach photos';
  end if;

  -- long-dead ownerless rows and stale rate-limit tokens go...
  if exists (select 1 from public.excused_days   where user_id = '00000000-0000-0000-0000-000000000802')
     or exists (select 1 from public.recovery_weeks where user_id = '00000000-0000-0000-0000-000000000802') then
    raise exception 'rows belonging to a long-gone non-member survived the purge';
  end if;
  if exists (select 1 from public.nudges) then
    raise exception 'a 45-day-old nudge token survived the purge';
  end if;

  -- ...but yesterday's leaver keeps their resting flag while their week is still
  -- on the grid. Deleting it immediately is what makes a leaver look like a
  -- serial misser to the circle they just left.
  if not exists (select 1 from public.excused_days where user_id = '00000000-0000-0000-0000-000000000803')
     or not exists (select 1 from public.recovery_weeks where user_id = '00000000-0000-0000-0000-000000000803') then
    raise exception 'a fresh leaver had their resting/recovery rows deleted with no grace period';
  end if;

  -- The hand-back is a durable list, not a one-shot return value: an unconfirmed
  -- path comes back on the NEXT run, which is what makes a failed Storage delete
  -- recoverable instead of an orphan nobody can name.
  if (select count(*) from public.purge_expired_photo_rows(30)) <> 2 then
    raise exception 'unconfirmed paths were forgotten by the second sweep';
  end if;

  -- ...and once Storage confirms, they are gone for good.
  if public.confirm_photo_deletions(v_paths) <> 2 then
    raise exception 'confirm_photo_deletions did not drain both paths';
  end if;
  if exists (select 1 from public.purge_expired_photo_rows(30)) then
    raise exception 'purge is not idempotent after confirmation';
  end if;

  -- p_limit bounds a run so the first sweep after a long gap cannot return an
  -- unbounded path set and guarantee the timeout it exists to avoid.
  insert into public.photo_tombstones (path, created_at) values
    ('a/b/1.jpg', now() - interval '3 minutes'),
    ('a/b/2.jpg', now() - interval '2 minutes'),
    ('a/b/3.jpg', now() - interval '1 minute');
  if (select count(*) from public.purge_expired_photo_rows(30, 2)) <> 2 then
    raise exception 'p_limit did not bound the returned batch';
  end if;

  -- the run lease: first claim wins, the next one inside the interval does not
  if public.claim_retention_run('1 hour') is not true then
    raise exception 'the first retention claim should succeed';
  end if;
  if public.claim_retention_run('1 hour') is not false then
    raise exception 'a second claim inside the interval should be refused';
  end if;
  if public.claim_retention_run('0 seconds') is not true then
    raise exception 'a zero interval should always claim';
  end if;
end $$;

rollback;
