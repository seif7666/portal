-- Reject rows carrying control characters (NUL bytes and friends) before any
-- per-kind processing. The file reader turns NUL into U+FFFD because NUL
-- cannot be sent as JSON; both are rejected here. Tabs and line breaks are
-- allowed (quoted multi-line notes are legitimate).

create or replace function private.has_control_chars(p_cells jsonb)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select array_to_string(array(select jsonb_array_elements_text(p_cells)), '')
         ~ ('[' || chr(1) || '-' || chr(8) || chr(11) || chr(12) || chr(14) || '-' || chr(31) || chr(127) || chr(65533) || ']')
$$;

create or replace function public.import_chunk(p_run_id uuid, p_chunk_no int, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_run      public.import_runs;
  v_prior    jsonb;
  v_res      jsonb;
  v_clean    jsonb;
  v_bad      int := 0;
  e          jsonb;
begin
  select * into v_run from public.import_runs where id = p_run_id;
  perform private.assert_member(v_run.brand_id, true);   -- null brand (unknown run) raises too

  if v_run.status <> 'running' then
    raise exception 'this import is % and accepts no more rows', v_run.status using errcode = '55000';
  end if;
  if p_chunk_no is null or p_chunk_no < 0 then
    raise exception 'invalid chunk number' using errcode = '22023';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception 'rows must be an array of at most 5000 items' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_rows) x
    where jsonb_typeof(x) <> 'object' or jsonb_typeof(x->'n') <> 'number' or jsonb_typeof(x->'c') <> 'array'
       or exists (select 1 from jsonb_array_elements(x->'c') y where jsonb_typeof(y) <> 'string')
  ) then
    raise exception 'each row must be {"n": <line number>, "c": [<cell strings>]}' using errcode = '22023';
  end if;

  -- one writer per run at a time; a retried chunk returns its original result
  perform pg_advisory_xact_lock(hashtextextended(v_run.id::text, 0));
  select result into v_prior from public.import_run_chunks where run_id = p_run_id and chunk_no = p_chunk_no;
  if v_prior is not null then
    return v_prior || '{"replayed": true}';
  end if;

  for e in select x from jsonb_array_elements(p_rows) x where private.has_control_chars(x->'c') loop
    perform private.add_issue(v_run, (e->>'n')::int, 'error', 'control_characters', null,
      'Row contains invisible control characters (for example a NUL byte), which usually means a corrupted export. Not loaded.',
      private.row_json(v_run.header, array(select jsonb_array_elements_text(e->'c'))));
    v_bad := v_bad + 1;
  end loop;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_clean
  from jsonb_array_elements(p_rows) x where not private.has_control_chars(x->'c');

  v_res := case v_run.kind
    when 'contacts'  then private.import_contacts_rows(v_run, v_clean)
    when 'campaigns' then private.import_campaigns_rows(v_run, v_clean)
    when 'events'    then private.import_events_rows(v_run, v_clean)
    when 'send_log'  then private.import_send_log_rows(v_run, v_clean)
  end;
  v_res := jsonb_set(v_res, '{rejected}', to_jsonb((v_res->>'rejected')::int + v_bad));

  insert into public.import_run_chunks (brand_id, run_id, chunk_no, row_count, result)
  values (v_run.brand_id, v_run.id, p_chunk_no, jsonb_array_length(p_rows), v_res);

  update public.import_runs set
    rows_total      = rows_total + jsonb_array_length(p_rows) - (v_res->>'blank')::int,
    rows_inserted   = rows_inserted + (v_res->>'inserted')::int,
    rows_updated    = rows_updated + (v_res->>'updated')::int,
    rows_unchanged  = rows_unchanged + (v_res->>'unchanged')::int,
    rows_superseded = rows_superseded + (v_res->>'superseded')::int,
    rows_rejected   = rows_rejected + (v_res->>'rejected')::int,
    rows_warned     = rows_warned + (v_res->>'warned')::int,
    blank_lines     = blank_lines + (v_res->>'blank')::int,
    last_activity_at = now()
  where id = v_run.id;

  return v_res;
end
$$;

revoke execute on function private.has_control_chars(jsonb) from public, anon, authenticated;
revoke execute on function public.import_chunk(uuid, int, jsonb) from public, anon;
grant execute on function public.import_chunk(uuid, int, jsonb) to authenticated;
