-- 32. Captions, the 'forgot' tier and place_kind (20261002000100).
--
--   * A poster can write all three; the shape checks refuse a blank, padded,
--     multi-line or over-long caption.
--   * 'forgot' is bare: no photo, no caption — on insert AND on a later update.
--   * A report pins the caption to the post's own, like photo_path.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000003201', 'poster@example.test'),
  ('00000000-0000-0000-0000-000000003202', 'reader@example.test');

set local role authenticated;

do $$
declare
  v_poster  uuid := '00000000-0000-0000-0000-000000003201';
  v_reader  uuid := '00000000-0000-0000-0000-000000003202';
  v_post    uuid := '00000000-0000-0000-0000-0000000032a1';
  v_forgot  uuid := '00000000-0000-0000-0000-0000000032a2';
  v_circle  uuid;
  v_code    text;
  v_path    text;
begin
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_poster), true);
  select id, code into v_circle, v_code from public.create_circle('Captions', '🤝');
  v_path := format('%s/%s/beach.jpg', v_circle, v_poster);

  -- The honest post: caption, kind and label together. 140 code points is the
  -- ceiling, counted in code points (each 'é' below is one).
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at,
                            photo_path, place_label, place_kind, caption)
  values (v_post, v_poster, v_circle, '2026-10-01', 'dhuhr', 'onTime', now(),
          v_path, '📍 Golden Gardens', 'onTheGo', repeat('é', 140));

  if (select place_kind from public.posts where id = v_post) <> 'onTheGo' then
    raise exception 'place_kind did not round-trip';
  end if;

  update public.posts set caption = 'sand in everything, worth it' where id = v_post;

  -- Shape: each of these is a caption that would render as something else.
  begin
    update public.posts set caption = repeat('x', 141) where id = v_post;
    raise exception 'accepted a 141-character caption';
  exception when check_violation then null;
  end;
  begin
    update public.posts set caption = '' where id = v_post;
    raise exception 'accepted an empty caption (null is the only "none")';
  exception when check_violation then null;
  end;
  begin
    update public.posts set caption = '  padded  ' where id = v_post;
    raise exception 'accepted an untrimmed caption';
  exception when check_violation then null;
  end;
  begin
    update public.posts set caption = E'line one\nline two' where id = v_post;
    raise exception 'accepted a caption with a newline';
  exception when check_violation then null;
  end;
  begin
    update public.posts set place_kind = 'garden' where id = v_post;
    raise exception 'accepted a place_kind outside PlaceTag';
  exception when invalid_text_representation then null;
  end;

  -- 'forgot': counts as done, shows nothing.
  insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at)
  values (v_forgot, v_poster, v_circle, '2026-09-30', 'fajr', 'forgot', now());

  begin
    update public.posts set photo_path = v_path || '.2' where id = v_forgot;
    raise exception 'a forgotten log gained a photo';
  exception when check_violation then null;
  end;
  begin
    update public.posts set caption = 'I promise' where id = v_forgot;
    raise exception 'a forgotten log gained a caption';
  exception when check_violation then null;
  end;
  begin
    insert into public.posts (id, user_id, circle_id, day_key, prayer, tier, logged_at, photo_path)
    values (gen_random_uuid(), v_poster, v_circle, '2026-09-30', 'dhuhr', 'forgot', now(), v_path || '.3');
    raise exception 'inserted a forgotten log with a photo';
  exception when check_violation then null;
  end;

  -- Reports: the caption is evidence, so it must be the post's.
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_reader), true);
  perform public.join_circle(v_code);

  begin
    insert into public.reports (reporter_id, post_id, circle_id, reported_user_id, caption)
    values (v_reader, v_post, v_circle, v_poster, 'words they never wrote');
    raise exception 'a report attached a caption the post never had';
  exception when insufficient_privilege then null;
  end;

  insert into public.reports (reporter_id, post_id, circle_id, reported_user_id,
                              photo_path, caption)
  values (v_reader, v_post, v_circle, v_poster, v_path, 'sand in everything, worth it');
end $$;

reset role;

do $$
begin
  if (select caption from public.reports
       where post_id = '00000000-0000-0000-0000-0000000032a1') <> 'sand in everything, worth it' then
    raise exception 'the report did not keep its copy of the caption';
  end if;
end $$;

rollback;
