-- 16. Enum labels are the Swift rawValues verbatim, and invite codes stay inside
--     the read-aloud alphabet (no I/O/0/1).
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_labels text;
  v_code   text;
  i        int;
begin
  select string_agg(enumlabel, ',' order by enumsortorder) into v_labels
  from pg_enum where enumtypid = 'public.prayer_kind'::regtype;
  if v_labels <> 'fajr,dhuhr,asr,maghrib,isha' then
    raise exception 'prayer_kind labels drifted from Prayer.rawValue: %', v_labels;
  end if;

  select string_agg(enumlabel, ',' order by enumsortorder) into v_labels
  from pg_enum where enumtypid = 'public.log_tier'::regtype;
  if v_labels <> 'onTime,prayed,lastCall,closeCall,qada' then
    raise exception 'log_tier labels drifted from LogTier.rawValue: %', v_labels;
  end if;

  for i in 1..200 loop
    v_code := public.generate_invite_code();
    if v_code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' then
      raise exception 'invite code % is outside the unambiguous alphabet', v_code;
    end if;
  end loop;
end $$;

rollback;
