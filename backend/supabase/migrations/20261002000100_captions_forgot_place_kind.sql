-- Three columns' worth of what the v5 prototype draws and the schema could not
-- carry: a caption under a photo, "I prayed it but forgot to log it", and a
-- machine-readable kind of place.
--
-- 1. log_tier gains 'forgot'.
--
--    "Forgot to log" is NOT a make-up. A qada says the prayer was prayed late;
--    'forgot' says it was prayed in its time and the app was never told. It
--    earns nothing (the incentive stays on logging as you pray), carries no
--    photo, and counts as done. The existing Journey make-up keeps 'qada'.
--
--    ADD VALUE is not reversible and cannot be used in the transaction that
--    adds it, which is why nothing below this line mentions 'forgot' except
--    as text inside a CHECK (resolved at row time, not at DDL time).
--
--    Older clients decoded `tier` strictly, so a 'forgot' row fails their whole
--    pull. Accepted deliberately (two internal testers); clients from this
--    change on read an unknown tier as 'forgot' instead of failing.
alter type public.log_tier add value if not exists 'forgot' after 'qada';

-- 2. place_kind: the tag behind posts.place_label.
--
--    place_label is the rendered pill ("📍 Green Lake") and stays the display
--    string. Counting "spots on the go" or keeping Home and Work off a shared
--    map by parsing an emoji out of free text is the bug this column prevents.
--    Labels are PlaceTag.rawValue verbatim, like every other enum here.
--    Nullable: an untagged post has no kind, and no row before this one does.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'place_kind') then
    create type public.place_kind as enum ('home','masjid','work','onTheGo');
  end if;
end $$;

alter table public.posts add column if not exists place_kind public.place_kind;

comment on column public.posts.place_kind is
  'PlaceTag.rawValue of the tag behind place_label. Nullable: untagged posts and every row before 20261002000100.';

-- 3. caption: one short line under the photo.
--
--    Bounded in CODE POINTS (char_length), so the client must count
--    unicodeScalars, not Characters: one family emoji is one Character and
--    seven code points. Trimmed and free of control characters, so a caption
--    cannot be blank padding or a stack of newlines pushing a friend's card
--    off the screen. Null when there is none; an empty string is refused, so
--    "no caption" has exactly one spelling.
alter table public.posts add column if not exists caption text;

alter table public.posts drop constraint if exists posts_caption_shape;
alter table public.posts add constraint posts_caption_shape check (
  caption is null
  or (char_length(caption) between 1 and 140
      and caption = btrim(caption)
      and caption !~ '[[:cntrl:]]')
);

comment on column public.posts.caption is
  'Optional caption, 1-140 code points, trimmed, no control characters.';

-- A forgotten log has nothing to show: no photo, no caption. Same shape as the
-- rule the client already follows for qada, enforced here because a 'forgot'
-- row claims an in-time prayer with no evidence, and a picture attached later
-- would make it look like one that had some.
alter table public.posts drop constraint if exists posts_forgot_is_bare;
alter table public.posts add constraint posts_forgot_is_bare check (
  tier::text <> 'forgot' or (photo_path is null and caption is null)
);

-- Writable by the poster like every other column they own; SELECT on posts is
-- already table-wide for circle members.
grant insert (place_kind, caption), update (place_kind, caption)
      on public.posts to authenticated;

-- 4. Reports cover the caption.
--
--    Words are a new thing a member can put in front of their circle, so a
--    report keeps its own copy of them, pinned to the post exactly as
--    photo_path is: undo deletes the post, and the complaint must survive it.
alter table public.reports add column if not exists caption text;

comment on column public.reports.caption is
  'The caption at report time. Pinned to posts.caption by reports_insert.';

drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated
with check (
  reporter_id = auth.uid()
  and circle_id = public.current_circle_id()
  and reports.post_id is not null
  and reports.reported_user_id is not null
  and exists (
    select 1 from public.posts p
     where p.id = reports.post_id
       and p.circle_id = public.current_circle_id()
       and p.user_id = reports.reported_user_id
       and (reports.photo_path is null or reports.photo_path = p.photo_path)
       and (reports.caption is null or reports.caption = p.caption)
  )
);

grant insert (caption) on public.reports to authenticated;
