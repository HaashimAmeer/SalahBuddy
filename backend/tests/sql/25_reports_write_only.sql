-- 25. A report is write-only for the person filing it, and it outlives
--     everything it points at (SPEC-V4 §4, App Store guideline 1.2).
--
-- Four halves, each of which has an obvious wrong answer:
--
--   * READ. The tempting grant is "let the reporter see their own reports" —
--     and in a circle of eight people who know each other, a readable reports
--     table is an enumeration of who reported whom. So the reporter inserts and
--     gets nothing back, not even through RETURNING on their own statement.
--   * DELETE. The tempting foreign key is ON DELETE CASCADE, which hands the
--     reported member an undo button that erases the complaint; the other
--     tempting one is the default NO ACTION, which makes a reported photo the
--     one photo nobody can ever delete. Both are asserted against below.
--   * SUBJECT. Surviving the delete is not enough if what survives is anonymous.
--     `reported_user_id` and `photo_path` (20260821000800) are the report's own
--     copy of who and what, and they are PINNED against the posts row — a copy
--     the client could choose freely would be a way to name a friend in a
--     complaint they had nothing to do with.
--   * IDEMPOTENCE. The tempting fix for a double-tap is
--     `on conflict (reporter_id, post_id) do nothing` — which needs SELECT on
--     the arbiter columns, i.e. on the exact pair the first bullet is hiding.
--     The refusal is asserted so nobody "fixes" it with a grant.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002501', 'reporter@example.test'),
  ('00000000-0000-0000-0000-000000002502', 'author@example.test'),
  ('00000000-0000-0000-0000-000000002503', 'stranger@example.test');

set local role authenticated;

do $$
declare
  v_reporter uuid := '00000000-0000-0000-0000-000000002501';
  v_author   uuid := '00000000-0000-0000-0000-000000002502';
  v_stranger uuid := '00000000-0000-0000-0000-000000002503';
  v_circle   uuid;
  v_code     text;
  v_other    uuid;
  v_post     uuid := '00000000-0000-0000-0000-0000000025a1';
  v_far      uuid := '00000000-0000-0000-0000-0000000025a2';
  v_report   uuid := '00000000-0000-0000-0000-0000000025b1';
  v_path     text;
  v_returned uuid;
  v_n        int;
begin
  -- Circle A: the reporter and the author of the photo.
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_reporter), true);
  select id, code into v_circle, v_code from public.create_circle('Reports', '🤝');

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_author), true);
  perform public.join_circle(v_code);
  v_path := format('%s/%s/reported.jpg', v_circle, v_author);
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path)
  values (v_post, v_author, v_circle, '2026-08-21', 'fajr', 'onTime', now(), v_path);

  -- Circle B: a stranger with a post the reporter must never be able to name.
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_stranger), true);
  select id into v_other from public.create_circle('Elsewhere', '🤝');
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (v_far, v_stranger, v_other, '2026-08-21', 'asr', 'prayed', now());

  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_reporter), true);

  -- RETURNING is checked before the honest insert, because RETURNING needs
  -- SELECT privilege and this is the shape a client reaches for by default.
  -- If it ever starts working, `Prefer: return=minimal` stops being load-bearing
  -- and the reporter is reading the reports table.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, reason)
    values (v_reporter, v_post, v_circle, v_author, 'Not a prayer photo')
    returning id into v_returned;
    raise exception 'a reporter read a row back out of reports via RETURNING';
  exception when insufficient_privilege then null;
  end;

  -- Every refusal below is asserted BEFORE the honest row exists, on purpose:
  -- once (reporter, post) is taken, a policy hole would surface as a unique
  -- violation and the test would fail with the wrong reason — a false negative
  -- that reads like a flaky constraint instead of an open door.

  -- created_at is the server's, like every other created_at in this schema.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, created_at)
    values (v_reporter, v_post, v_circle, v_author, '2126-01-01T00:00:00Z');
    raise exception 'a client set reports.created_at';
  exception when insufficient_privilege then null;
  end;

  -- Forging the reporter would turn the feature into a way to frame a friend.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_author, v_post, v_circle, v_author);
    raise exception 'filed a report in a circle-mate''s name';
  exception when insufficient_privilege then null;
  end;

  -- The circle on the row has to be the circle the caller is actually in...
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_reporter, v_post, v_other, v_author);
    raise exception 'filed a report into a circle I am not a member of';
  exception when insufficient_privilege then null;
  end;

  -- ...and the post has to be one the caller can see. This is the assertion
  -- that stops a member enumerating or annotating strangers' post ids.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_reporter, v_far, v_circle, v_stranger);
    raise exception 'reported a post from another circle';
  exception when insufficient_privilege then null;
  end;

  -- A report with no subject is not a report.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_reporter, null, v_circle, v_author);
    raise exception 'filed a report that named no post';
  exception when insufficient_privilege then null;
  end;

  -- Nor is one that names a post but nobody to answer for it — the anonymous
  -- row that made undo a retraction button before 20260821000800.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_reporter, v_post, v_circle, null);
    raise exception 'filed a report that named no member';
  exception when insufficient_privilege then null;
  end;

  -- The accused is the post's AUTHOR, from the database. Naming somebody else
  -- would be a complaint about a photo they did not post.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_reporter, v_post, v_circle, v_reporter);
    raise exception 'named a member who did not write the reported post';
  exception when insufficient_privilege then null;
  end;

  -- Same for the path: it is evidence, so it is the post's, not the client's.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, photo_path)
    values (v_reporter, v_post, v_circle, v_author, 'somebody/else/private.jpg');
    raise exception 'attached a storage path the reported post never had';
  exception when insufficient_privilege then null;
  end;

  -- Free text, but bounded.
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, reason)
    values (v_reporter, v_post, v_circle, v_author, repeat('x', 501));
    raise exception 'reports accepted an unbounded reason';
  exception when check_violation then null;
  end;

  -- The honest report lands.
  insert into public.reports (id, reporter_id, post_id, circle_id, reported_user_id,
                              photo_path, reason)
  values (v_report, v_reporter, v_post, v_circle, v_author, v_path, 'Not a prayer photo');

  -- ...and is invisible to the person who filed it.
  begin
    select count(*) into v_n from public.reports;
    raise exception 'a reporter can read the reports table (saw % rows)', v_n;
  exception when insufficient_privilege then null;
  end;

  -- No edits, no withdrawals: a report is a fact that was filed.
  begin
    update public.reports set reason = 'never mind';
    raise exception 'a reporter can rewrite a filed report';
  exception when insufficient_privilege then null;
  end;

  begin
    delete from public.reports;
    raise exception 'a reporter can withdraw a filed report';
  exception when insufficient_privilege then null;
  end;

  -- Reporting the same photo twice is the same report.
  begin
    insert into public.reports (id, reporter_id, post_id, circle_id, reported_user_id, reason)
    values (gen_random_uuid(), v_reporter, v_post, v_circle, v_author, 'again');
    raise exception 'a second report of the same photo was filed';
  exception when unique_violation then null;
  end;

  -- ...and the obvious way to swallow that — naming the conflict target — is
  -- REFUSED here, which is a real constraint on the client and not a curiosity:
  -- an ON CONFLICT *inference* clause needs SELECT privilege on the arbiter
  -- columns, and `(reporter_id, post_id)` is exactly the pair that would
  -- publish who reported whom. So the write-only grant and PostgREST's
  -- `on_conflict=` parameter are mutually exclusive by construction.
  begin
    insert into public.reports (id, reporter_id, post_id, circle_id, reported_user_id, reason)
    values (v_report, v_reporter, v_post, v_circle, v_author, 'Not a prayer photo')
    on conflict (reporter_id, post_id) do nothing;
    raise exception 'an ON CONFLICT target worked without SELECT on the arbiter columns';
  exception when insufficient_privilege then null;
  end;

  -- The targetless form does work on the insert grant alone (it infers nothing,
  -- so it reads nothing) — but no PostgREST call shape is guaranteed to emit it,
  -- so the client contract in backend/README.md is the plain insert plus
  -- "treat 23505 as already-reported". This is here to pin WHY that contract
  -- exists: it is the grant, not a missing feature.
  insert into public.reports (id, reporter_id, post_id, circle_id, reported_user_id, reason)
  values (v_report, v_reporter, v_post, v_circle, v_author, 'Not a prayer photo')
  on conflict do nothing;

  -- And a stranger cannot reach into circle A at all.
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_stranger), true);
  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id)
    values (v_stranger, v_post, v_circle, v_author);
    raise exception 'a member of another circle filed a report about circle A';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.reports;
  if v_n <> 1 then
    raise exception 'expected exactly one report row, found %', v_n;
  end if;
  if not exists (select 1 from public.reports
                  where post_id = '00000000-0000-0000-0000-0000000025a1'
                    and reporter_id = '00000000-0000-0000-0000-000000002501'
                    and reported_user_id = '00000000-0000-0000-0000-000000002502'
                    and photo_path is not null
                    and reason = 'Not a prayer photo') then
    raise exception 'the report did not record what was reported';
  end if;
end $$;

-- Triage reads them with the service-role key, which no client ever holds.
set local role service_role;

do $$
begin
  if (select count(*) from public.reports) <> 1 then
    raise exception 'service_role cannot read the reports it exists to triage';
  end if;
end $$;

reset role;

-- The undo button must not be a retraction button. The author deletes the
-- reported post exactly as the app does — and the delete has to succeed (a
-- RESTRICT-shaped foreign key would make a reported photo undeletable, which is
-- the same photo staying in the bucket forever) while the report survives it
-- WITH ITS SUBJECT INTACT. Surviving as an anonymous timestamp would still hand
-- the reported member a retraction button, just a slower one.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000002502","role":"authenticated"}';

delete from public.posts where id = '00000000-0000-0000-0000-0000000025a1';

reset role;

do $$
declare
  v_post_id uuid;
  v_who     uuid;
  v_path    text;
begin
  if (select count(*) from public.reports) <> 1 then
    raise exception 'deleting the reported post erased the report';
  end if;
  select post_id, reported_user_id, photo_path into v_post_id, v_who, v_path
    from public.reports;
  if v_post_id is not null then
    raise exception 'the report still points at a post that no longer exists';
  end if;
  if v_who <> '00000000-0000-0000-0000-000000002502' then
    raise exception 'undo anonymised the report — it no longer names who was reported';
  end if;
  if v_path is null then
    raise exception 'undo took the evidence path with it';
  end if;
  if exists (select 1 from public.posts where id = '00000000-0000-0000-0000-0000000025a1') then
    raise exception 'the reported post survived its own delete';
  end if;
end $$;

-- The same rule one level up: an emptied circle is swept by retention, and that
-- must not take the complaint with it either.
do $$
declare
  v_circle uuid;
begin
  select circle_id into v_circle from public.reports;
  delete from public.circles where id = v_circle;

  if (select count(*) from public.reports) <> 1 then
    raise exception 'deleting the circle erased the report';
  end if;
  if (select circle_id from public.reports) is not null then
    raise exception 'the report still points at a circle that no longer exists';
  end if;
  if (select reported_user_id from public.reports) is null then
    raise exception 'sweeping the circle anonymised the report';
  end if;
end $$;

rollback;
