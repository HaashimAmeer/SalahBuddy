-- 21. Every way a photo's post row can disappear must leave the PATH behind, or
--     the object is stranded in the bucket with nothing left that can name it.
--
-- Regression, three shapes of the same hole:
--   * undo (posts DELETE) removed the row and left the JPEG,
--   * delete_account() — the App Store "delete my data" RPC — deleted every one
--     of the user's posts, so the retention sweep (which discovers paths ONLY
--     through posts.photo_path) could never find any of them again. Meanwhile
--     the storage read policy checks circle membership and not whether a post
--     exists, so every remaining member could keep listing and downloading a
--     departed account's prayer photos indefinitely.
--   * retention itself returned the paths in the same committed statement that
--     erased them, so a Storage delete that failed lost them for good.
--
-- Fixed ids throughout because the tombstone list is deliberately unreadable
-- from a user session, so the assertions have to change role between stages.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002101', 'shooter@example.test'),
  ('00000000-0000-0000-0000-000000002102', 'mate@example.test');

insert into public.circles (id, code, name, created_by)
values ('00000000-0000-0000-0000-0000000021cc', 'TMBSAB', 'Tombs',
        '00000000-0000-0000-0000-000000002101');

insert into storage.objects (bucket_id, name, owner) values
  ('prayer-photos', '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/undo.jpg',
   '00000000-0000-0000-0000-000000002101'),
  ('prayer-photos', '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/keep.jpg',
   '00000000-0000-0000-0000-000000002101'),
  ('prayer-photos', '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/deleted.jpg',
   '00000000-0000-0000-0000-000000002101');

-- Memberships are seeded here rather than through join_circle() because
-- `authenticated` deliberately holds no INSERT on circle_members (joining goes
-- through the RPC, under the cap lock).
insert into public.circle_members (circle_id, user_id) values
  ('00000000-0000-0000-0000-0000000021cc', '00000000-0000-0000-0000-000000002101');

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000002101","role":"authenticated"}';

insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path) values
  ('00000000-0000-0000-0000-0000000021a1', '00000000-0000-0000-0000-000000002101',
   '00000000-0000-0000-0000-0000000021cc', '2026-08-21', 'fajr', 'onTime', now(),
   '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/undo.jpg'),
  ('00000000-0000-0000-0000-0000000021a2', '00000000-0000-0000-0000-000000002101',
   '00000000-0000-0000-0000-0000000021cc', '2026-08-21', 'dhuhr', 'onTime', now(),
   '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/keep.jpg'),
  ('00000000-0000-0000-0000-0000000021a3', '00000000-0000-0000-0000-000000002101',
   '00000000-0000-0000-0000-0000000021cc', '2026-08-21', 'asr', 'onTime', now(),
   '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/deleted.jpg');

-- 1. Undo: the post row goes, and the path must be remembered.
delete from public.posts where id = '00000000-0000-0000-0000-0000000021a1';
-- 2. Replacing a photo tombstones the old object...
update public.posts
   set photo_path = '00000000-0000-0000-0000-0000000021cc/00000000-0000-0000-0000-000000002101/keep2.jpg'
 where id = '00000000-0000-0000-0000-0000000021a2';
-- ...while a no-op write of the same value must not.
update public.posts set photo_path = photo_path where photo_path is not null;

reset role;

do $$
begin
  if not exists (select 1 from public.photo_tombstones
                  where path like '%/undo.jpg') then
    raise exception 'undo left the photo path unrecorded — the object is now unreachable';
  end if;
  if not exists (select 1 from public.photo_tombstones where path like '%/keep.jpg') then
    raise exception 'a replaced photo path was not recorded';
  end if;
  if exists (select 1 from public.photo_tombstones where path like '%/keep2.jpg') then
    raise exception 'an unchanged photo_path was tombstoned';
  end if;
end $$;

-- A circle-mate must lose the read the instant the fact is retracted — not "at
-- the next sweep", which is what the membership-only policy amounted to.
insert into public.circle_members (circle_id, user_id) values
  ('00000000-0000-0000-0000-0000000021cc', '00000000-0000-0000-0000-000000002102');

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000002102","role":"authenticated"}';

do $$
begin
  if exists (select 1 from storage.objects where name like '%/undo.jpg') then
    raise exception 'a circle-mate can still read a photo whose post was undone';
  end if;
  if not exists (select 1 from storage.objects where name like '%/deleted.jpg') then
    raise exception 'the tombstone gate hid a live photo';
  end if;
end $$;

-- 3. delete_account(): the App Store path. Every remaining post of theirs goes,
-- and every photo has to go with it.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000002101","role":"authenticated"}';
select public.delete_account();

set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000002102","role":"authenticated"}';

do $$
declare
  v_n int;
begin
  if exists (select 1 from public.posts where user_id = '00000000-0000-0000-0000-000000002101') then
    raise exception 'delete_account() left posts behind';
  end if;
  select count(*) into v_n from storage.objects;
  if v_n <> 0 then
    raise exception 'a deleted account''s photos are still readable by the circle (% objects)', v_n;
  end if;
end $$;

reset role;

do $$
begin
  if not exists (select 1 from public.photo_tombstones where path like '%/deleted.jpg') then
    raise exception 'delete_account() orphaned a photo: the path went with the post row';
  end if;
end $$;

-- The sweep is the single deleter, and only a CONFIRMED delete clears the list.
set local role service_role;

do $$
declare
  v_paths text[];
begin
  select array_agg(p order by p) into v_paths from public.purge_expired_photo_rows(30) p;
  if coalesce(array_length(v_paths, 1), 0) < 3 then
    raise exception 'the sweep did not hand back the tombstoned paths (got %)',
      coalesce(v_paths::text, 'null');
  end if;

  -- unconfirmed → still pending on the next run (a failed Storage batch resumes)
  if (select count(*) from public.purge_expired_photo_rows(30)) <> array_length(v_paths, 1) then
    raise exception 'an unconfirmed path was dropped from the pending list';
  end if;

  perform public.confirm_photo_deletions(v_paths);
  if exists (select 1 from public.purge_expired_photo_rows(30)) then
    raise exception 'confirmed paths came back';
  end if;
end $$;

rollback;
