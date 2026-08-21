-- 8. Period privacy is absolute (SPEC-V4 §3): excused_days is a bare flag and the
--    reason never leaves the device. This test exists to fail loudly the day
--    someone "just adds a note field".
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_cols text;
begin
  select string_agg(column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'excused_days'
    and (column_name ilike '%reason%' or column_name ilike '%note%'
         or column_name ilike '%comment%' or column_name ilike '%detail%');
  if v_cols is not null then
    raise exception 'excused_days must never explain itself; found: %', v_cols;
  end if;

  -- and while we are here: the columns it IS allowed to have
  select string_agg(column_name, ', ' order by column_name) into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'excused_days';
  if v_cols is distinct from 'circle_id, created_at, day_key, user_id' then
    raise exception 'excused_days shape drifted: %', v_cols;
  end if;
end $$;

rollback;
