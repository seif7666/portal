-- Import pipeline RPCs.
--
--   import_start(...)            -> validates the header, creates an import run
--   import_chunk(run, n, rows)   -> validates + loads up to 5,000 rows; idempotent per chunk number
--   import_finish(run)           -> cross-row checks, marks the run completed
--   import_abort(run, reason)    -> marks the run failed
--
-- The browser (or scripts/seed.ts) only decodes the file and splits it into
-- cells. Every rule about what is valid lives below. Rejected rows are never
-- written to data tables; they are recorded in import_issues with a reason.
--
-- Re-importing the same export is safe: rows are keyed on (brand_id,
-- external_id)/(brand_id, event_id), unchanged rows are counted as unchanged,
-- and a row from an OLDER export never overwrites one from a newer export.

alter table public.import_runs
  add column expected_rows     int not null default 0 check (expected_rows between 0 and 2000000),
  add column rows_superseded   int not null default 0,
  add column blank_lines       int not null default 0,
  add column failure_reason    text check (length(failure_reason) <= 500),
  add column last_activity_at  timestamptz not null default now();

create table public.import_run_chunks (
  brand_id      uuid not null,
  run_id        uuid not null,
  chunk_no      int not null check (chunk_no >= 0),
  row_count     int not null,
  result        jsonb not null,
  processed_at  timestamptz not null default now(),
  primary key (run_id, chunk_no),
  foreign key (brand_id, run_id) references public.import_runs (brand_id, id) on delete cascade
);
alter table public.import_run_chunks enable row level security;
alter table public.import_run_chunks force row level security;
create policy import_run_chunks_select_own_brand on public.import_run_chunks
  for select to authenticated using (brand_id in (select private.current_brand_ids()));
revoke all on public.import_run_chunks from anon;
revoke insert, update, delete, truncate on public.import_run_chunks from authenticated;
grant select on public.import_run_chunks to authenticated;

-- ---------------------------------------------------------------------------
-- issue helper
-- ---------------------------------------------------------------------------
create or replace function private.add_issue(
  p_run public.import_runs, p_row int, p_severity text, p_code text, p_field text, p_message text, p_raw jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.import_issues (brand_id, run_id, row_number, severity, code, field, message, raw)
  values (p_run.brand_id, p_run.id, p_row, p_severity, p_code, p_field, left(p_message, 1000), p_raw)
$$;

-- row as {"column header": "value"} for the issue log, so the marketer sees
-- the original row, not an array of cells
create or replace function private.row_json(p_header text[], p_cells text[])
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(coalesce(h, '#' || ord), c), '{}'::jsonb)
  from unnest(p_cells) with ordinality as t(c, ord)
  left join lateral (select p_header[ord] as h) hh on true
$$;

-- ---------------------------------------------------------------------------
-- import_start
-- ---------------------------------------------------------------------------
create or replace function public.import_start(
  p_brand_id            uuid,
  p_kind                text,
  p_file_name           text,
  p_file_sha256         text,
  p_file_size_bytes     bigint,
  p_encoding            text,
  p_delimiter           text,
  p_header              text[],
  p_expected_rows       int,
  p_source_exported_at  timestamptz
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_norm      text[];
  v_map       jsonb := '{}';
  v_missing   text[] := '{}';
  v_ignored   text[] := '{}';
  v_idx       int;
  f           record;
  v_run       public.import_runs;
  v_prev      timestamptz;
begin
  perform private.assert_member(p_brand_id, true);   -- owners only

  if p_kind is null or p_kind not in ('contacts', 'campaigns', 'events', 'send_log') then
    raise exception 'unknown import kind' using errcode = '22023';
  end if;
  if p_header is null or cardinality(p_header) = 0 or cardinality(p_header) > 200 then
    raise exception 'the file has no usable header row' using errcode = '22023';
  end if;
  if p_source_exported_at is null or p_source_exported_at > now() + interval '1 day'
     or p_source_exported_at < timestamptz '2000-01-01' then
    raise exception 'export date must be a real date, not in the future' using errcode = '22023';
  end if;
  if p_expected_rows is null or p_expected_rows < 0 or p_expected_rows > 2000000 then
    raise exception 'file too large (max 2,000,000 rows)' using errcode = '22023';
  end if;

  v_norm := array(select private.norm_header(h) from unnest(p_header) h);

  for f in select * from private.import_fields where kind = p_kind order by field loop
    select min(ord) - 1 into v_idx
    from unnest(v_norm) with ordinality as t(h, ord)
    where h = any (f.aliases);
    if v_idx is null then
      if f.required then v_missing := v_missing || f.field; end if;
    else
      v_map := v_map || jsonb_build_object(f.field, v_idx);
    end if;
  end loop;

  select array_agg(p_header[ord]) into v_ignored
  from generate_series(1, cardinality(p_header)) ord
  where not exists (select 1 from jsonb_each_text(v_map) m where m.value::int = ord - 1);

  insert into public.import_runs (
    brand_id, kind, file_name, file_sha256, file_size_bytes, encoding, delimiter,
    header, column_map, source_exported_at, expected_rows, status)
  values (
    p_brand_id, p_kind, left(btrim(p_file_name), 255), lower(p_file_sha256), p_file_size_bytes, p_encoding,
    p_delimiter, p_header, v_map, p_source_exported_at, p_expected_rows,
    case when cardinality(v_missing) > 0 then 'failed' else 'running' end)
  returning * into v_run;

  if cardinality(v_missing) > 0 then
    update public.import_runs
      set failure_reason = 'missing required columns: ' || array_to_string(v_missing, ', '),
          finished_at = now()
      where id = v_run.id
      returning * into v_run;
    perform private.add_issue(v_run, 1, 'error', 'missing_required_columns', null,
      format('This does not look like a %s export: missing %s. Nothing was loaded.', p_kind, array_to_string(v_missing, ', ')),
      to_jsonb(p_header));
  end if;

  if cardinality(v_ignored) > 0 then
    perform private.add_issue(v_run, 1, 'warning', 'ignored_columns', null,
      'Columns not recognised and not loaded: ' || array_to_string(v_ignored, ', '), to_jsonb(v_ignored));
  end if;

  select max(finished_at) into v_prev
  from public.import_runs
  where brand_id = p_brand_id and kind = p_kind and file_sha256 = lower(p_file_sha256)
    and status = 'completed' and id <> v_run.id;

  return jsonb_build_object(
    'run_id', v_run.id,
    'status', v_run.status,
    'column_map', v_map,
    'missing_columns', to_jsonb(v_missing),
    'ignored_columns', to_jsonb(coalesce(v_ignored, '{}')),
    'previously_imported_at', v_prev);
end
$$;

-- ---------------------------------------------------------------------------
-- per-kind row processors (called only from import_chunk)
-- Each returns counts: inserted, updated, unchanged, superseded, rejected, warned, blank
-- ---------------------------------------------------------------------------

create or replace function private.import_contacts_rows(v_run public.import_runs, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_brand     public.brands;
  v_hdr_norm  text[] := array(select private.norm_header(h) from unnest(v_run.header) h);
  v_ncols     int := cardinality(v_run.header);
  m           jsonb := v_run.column_map;
  r           jsonb;
  n           int;
  cells       text[];
  raw         jsonb;
  ok          boolean;
  warned      boolean;
  c           jsonb := '{"inserted":0,"updated":0,"unchanged":0,"superseded":0,"rejected":0,"warned":0,"blank":0}';

  v_ext text; v_bc text; v_status text; v_name text; v_city text; v_notes text;
  v_deleted record; v_supp record; v_signup record; v_email record; v_phone record;
  v_country record; v_consent record;
  ex record;
begin
  select * into v_brand from public.brands where id = v_run.brand_id;

  for r in select value from jsonb_array_elements(p_rows) loop
    n := (r->>'n')::int;
    cells := array(select jsonb_array_elements_text(r->'c'));

    -- structural checks -----------------------------------------------------
    if coalesce(cardinality(cells), 0) = 0 or array_to_string(cells, '') ~ '^\s*$' then
      c := jsonb_set(c, '{blank}', to_jsonb((c->>'blank')::int + 1));
      continue;
    end if;
    raw := private.row_json(v_run.header, cells);
    if cardinality(cells) <> v_ncols then
      perform private.add_issue(v_run, n, 'error', 'wrong_column_count', null,
        format('Expected %s columns, found %s. The row looks truncated or shifted, so none of it was trusted.', v_ncols, cardinality(cells)), raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;
    if array(select private.norm_header(x) from unnest(cells) x) = v_hdr_norm then
      perform private.add_issue(v_run, n, 'error', 'repeated_header', null, 'A header row repeated inside the file.', raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    -- row-level errors (row not loaded) -------------------------------------
    v_ext := private.blank_to_null(private.cell(cells, m, 'external_id'));
    v_bc := upper(private.blank_to_null(private.cell(cells, m, 'brand_code')));
    v_status := private.norm_status(private.cell(cells, m, 'status'));
    v_deleted := private.parse_ts(private.cell(cells, m, 'deleted_at'), v_brand.timezone);
    v_supp := private.parse_ts(private.cell(cells, m, 'suppressed_until'), v_brand.timezone);
    v_name := private.blank_to_null(private.cell(cells, m, 'full_name'));

    ok := false;
    if v_ext is null or v_ext !~ '^[A-Za-z0-9_.:-]{1,64}$' then
      perform private.add_issue(v_run, n, 'error', 'invalid_external_id', 'external_id', 'Missing or malformed external id.', raw);
    elsif v_bc is null then
      perform private.add_issue(v_run, n, 'error', 'brand_code_missing', 'brand_code',
        'No brand code, so the row cannot be proven to belong to ' || v_brand.name || '.', raw);
    elsif v_bc <> v_brand.code then
      perform private.add_issue(v_run, n, 'error', 'wrong_brand', 'brand_code',
        format('Row belongs to brand %s, not %s. Not loaded into either brand.', v_bc, v_brand.code), raw);
    elsif v_status is null then
      perform private.add_issue(v_run, n, 'error', 'invalid_status', 'status',
        format('Unrecognised status "%s".', private.cell(cells, m, 'status')), raw);
    elsif v_deleted.format = 'invalid' then
      perform private.add_issue(v_run, n, 'error', 'invalid_deleted_at', 'deleted_at',
        'Unreadable deleted_at. Loading it as "not deleted" could be wrong, so the row was skipped.', raw);
    elsif v_supp.format = 'invalid' then
      perform private.add_issue(v_run, n, 'error', 'invalid_suppressed_until', 'suppressed_until',
        'Unreadable suppressed_until. Loading it as "not suppressed" could be wrong, so the row was skipped.', raw);
    elsif length(v_name) > 200 then
      perform private.add_issue(v_run, n, 'error', 'name_too_long', 'full_name', 'Name longer than 200 characters.', raw);
    else
      ok := true;
    end if;
    if not ok then
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    -- field-level warnings (row loaded, field cleaned or nulled) ------------
    warned := false;
    v_email := private.norm_email(private.cell(cells, m, 'email'));
    if v_email.issue is not null then
      perform private.add_issue(v_run, n, 'warning', v_email.issue, 'email',
        format('Email "%s" is not a valid address; stored as empty, so this contact cannot be emailed.', private.cell(cells, m, 'email')), raw);
      warned := true;
    end if;

    v_country := private.norm_country(private.cell(cells, m, 'country'));
    if v_country.issue is not null then
      perform private.add_issue(v_run, n, 'warning', v_country.issue, 'country',
        format('Country "%s" not recognised; stored as empty.', private.cell(cells, m, 'country')), raw);
      warned := true;
    end if;

    v_phone := private.norm_phone(private.cell(cells, m, 'phone'), coalesce(v_country.value, v_brand.country));
    if v_phone.issue is not null then
      perform private.add_issue(v_run, n, 'warning', v_phone.issue, 'phone',
        case v_phone.issue
          when 'phone_scientific_notation' then format('Phone "%s" was mangled by a spreadsheet (scientific notation); digits are lost, so this contact cannot be texted.', private.cell(cells, m, 'phone'))
          else format('Phone "%s" is not a recognisable number; this contact cannot be texted.', private.cell(cells, m, 'phone'))
        end, raw);
      warned := true;
    end if;

    v_signup := private.parse_ts(private.cell(cells, m, 'signup_at'), v_brand.timezone);
    if v_signup.format = 'invalid' then
      perform private.add_issue(v_run, n, 'warning', 'invalid_signup_at', 'signup_at',
        format('Unreadable signup date "%s"; stored as empty and excluded from signup charts.', private.cell(cells, m, 'signup_at')), raw);
      warned := true;
    elsif v_signup.format in ('date_only', 'dd/mm/yyyy', 'local_no_zone') then
      perform private.add_issue(v_run, n, 'warning', 'signup_at_' || replace(v_signup.format, '/', ''), 'signup_at',
        format('Signup date "%s" has no timezone; read as %s in %s.', private.cell(cells, m, 'signup_at'),
          case v_signup.format when 'dd/mm/yyyy' then 'DD/MM/YYYY local time' when 'date_only' then 'midnight local time' else 'local time' end,
          v_brand.timezone), raw);
      warned := true;
    end if;
    if v_signup.value > now() + interval '1 day' then
      perform private.add_issue(v_run, n, 'warning', 'signup_in_future', 'signup_at', 'Signup date is in the future.', raw);
      warned := true;
    end if;

    v_consent := private.norm_bool(private.cell(cells, m, 'consent_marketing'));
    if v_consent.issue is not null then
      perform private.add_issue(v_run, n, 'warning', 'invalid_consent', 'consent_marketing',
        format('Consent value "%s" not recognised; treated as not given.', private.cell(cells, m, 'consent_marketing')), raw);
      warned := true;
    end if;

    v_city := left(private.blank_to_null(private.cell(cells, m, 'city')), 100);
    v_notes := private.blank_to_null(private.cell(cells, m, 'notes'));
    if length(v_notes) > 2000 then
      v_notes := left(v_notes, 2000);
      perform private.add_issue(v_run, n, 'warning', 'notes_truncated', 'notes', 'Notes longer than 2,000 characters were truncated.', raw);
      warned := true;
    end if;

    -- upsert ---------------------------------------------------------------
    select ct.id, ct.source_exported_at, ct.last_import_run_id,
           (ct.full_name, ct.email, ct.phone_raw, ct.phone_e164, ct.country, ct.city, ct.signup_at, ct.status,
            ct.consent_marketing, ct.deleted_at, ct.suppressed_until, ct.notes)::text as data
      into ex
      from public.contacts ct
      where ct.brand_id = v_run.brand_id and ct.external_id = v_ext
      for update;

    if not found then
      insert into public.contacts (brand_id, external_id, full_name, email, phone_raw, phone_e164, country, city,
        signup_at, status, consent_marketing, deleted_at, suppressed_until, notes, source_exported_at, last_import_run_id)
      values (v_run.brand_id, v_ext, v_name, v_email.value, left(private.blank_to_null(private.cell(cells, m, 'phone')), 50),
        v_phone.value, v_country.value, v_city, v_signup.value, v_status, v_consent.value, v_deleted.value, v_supp.value,
        v_notes, v_run.source_exported_at, v_run.id);
      c := jsonb_set(c, '{inserted}', to_jsonb((c->>'inserted')::int + 1));
    else
      if ex.last_import_run_id = v_run.id then
        perform private.add_issue(v_run, n, 'warning', 'duplicate_in_file', 'external_id',
          format('External id %s appears more than once in this file; the later row was kept.', v_ext), raw);
        warned := true;
      end if;

      if ex.source_exported_at > v_run.source_exported_at then
        update public.contacts set last_import_run_id = v_run.id where id = ex.id;
        perform private.add_issue(v_run, n, 'warning', 'superseded_by_newer_export', null,
          format('Not applied: this contact was already updated from a newer export (%s).', to_char(ex.source_exported_at, 'YYYY-MM-DD')), raw);
        warned := true;
        c := jsonb_set(c, '{superseded}', to_jsonb((c->>'superseded')::int + 1));
      elsif ex.data is distinct from
            (v_name, v_email.value, left(private.blank_to_null(private.cell(cells, m, 'phone')), 50), v_phone.value,
             v_country.value, v_city, v_signup.value, v_status, v_consent.value, v_deleted.value, v_supp.value, v_notes)::text then
        update public.contacts set
          full_name = v_name, email = v_email.value, phone_raw = left(private.blank_to_null(private.cell(cells, m, 'phone')), 50),
          phone_e164 = v_phone.value, country = v_country.value, city = v_city, signup_at = v_signup.value,
          status = v_status, consent_marketing = v_consent.value, deleted_at = v_deleted.value,
          suppressed_until = v_supp.value, notes = v_notes, source_exported_at = v_run.source_exported_at,
          last_import_run_id = v_run.id, updated_at = now()
        where id = ex.id;
        c := jsonb_set(c, '{updated}', to_jsonb((c->>'updated')::int + 1));
      else
        update public.contacts set last_import_run_id = v_run.id,
          source_exported_at = greatest(source_exported_at, v_run.source_exported_at)
        where id = ex.id;
        c := jsonb_set(c, '{unchanged}', to_jsonb((c->>'unchanged')::int + 1));
      end if;
    end if;

    if warned then
      c := jsonb_set(c, '{warned}', to_jsonb((c->>'warned')::int + 1));
    end if;
  end loop;
  return c;
end
$$;

create or replace function private.import_campaigns_rows(v_run public.import_runs, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_brand     public.brands;
  v_hdr_norm  text[] := array(select private.norm_header(h) from unnest(v_run.header) h);
  v_ncols     int := cardinality(v_run.header);
  m           jsonb := v_run.column_map;
  r           jsonb;
  n           int;
  cells       text[];
  raw         jsonb;
  ok          boolean;
  warned      boolean;
  c           jsonb := '{"inserted":0,"updated":0,"unchanged":0,"superseded":0,"rejected":0,"warned":0,"blank":0}';
  v_ext text; v_name text; v_channel text; v_parent text; v_local text;
  v_target record; v_sent_at record;
  v_sent int; v_deliv int; v_bounce int; v_opens int; v_clicks int; v_spend numeric;
  f text;
  ex record;
begin
  select * into v_brand from public.brands where id = v_run.brand_id;

  for r in select value from jsonb_array_elements(p_rows) loop
    n := (r->>'n')::int;
    cells := array(select jsonb_array_elements_text(r->'c'));
    if coalesce(cardinality(cells), 0) = 0 or array_to_string(cells, '') ~ '^\s*$' then
      c := jsonb_set(c, '{blank}', to_jsonb((c->>'blank')::int + 1));
      continue;
    end if;
    raw := private.row_json(v_run.header, cells);
    if cardinality(cells) <> v_ncols then
      perform private.add_issue(v_run, n, 'error', 'wrong_column_count', null,
        format('Expected %s columns, found %s.', v_ncols, cardinality(cells)), raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;
    if array(select private.norm_header(x) from unnest(cells) x) = v_hdr_norm then
      perform private.add_issue(v_run, n, 'error', 'repeated_header', null, 'A header row repeated inside the file.', raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    v_ext := private.blank_to_null(private.cell(cells, m, 'external_id'));
    v_name := private.blank_to_null(private.cell(cells, m, 'name'));
    v_channel := lower(btrim(private.cell(cells, m, 'channel')));
    v_sent_at := private.parse_ts(private.cell(cells, m, 'sent_at'), v_brand.timezone);

    ok := false;
    if v_ext is null or v_ext !~ '^[A-Za-z0-9_.:-]{1,64}$' then
      perform private.add_issue(v_run, n, 'error', 'invalid_external_id', 'external_id', 'Missing or malformed campaign id.', raw);
    elsif v_name is null or length(v_name) > 200 then
      perform private.add_issue(v_run, n, 'error', 'invalid_name', 'name', 'Campaign name is missing or longer than 200 characters.', raw);
    elsif v_channel is null or v_channel not in ('email', 'sms') then
      perform private.add_issue(v_run, n, 'error', 'invalid_channel', 'channel',
        format('Channel "%s" is not email or sms.', private.cell(cells, m, 'channel')), raw);
    elsif v_sent_at.format = 'invalid' then
      perform private.add_issue(v_run, n, 'error', 'invalid_sent_at', 'sent_at', 'Unreadable send time.', raw);
    else
      ok := true;
    end if;
    if not ok then
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    warned := false;
    v_target := private.norm_country(private.cell(cells, m, 'target_country'));
    if v_target.issue is not null then
      perform private.add_issue(v_run, n, 'warning', v_target.issue, 'target_country', 'Target country not recognised; stored as empty.', raw);
      warned := true;
    end if;

    v_sent := private.parse_int(private.cell(cells, m, 'reported_sent'));
    v_deliv := private.parse_int(private.cell(cells, m, 'reported_delivered'));
    v_bounce := private.parse_int(private.cell(cells, m, 'reported_bounced'));
    v_opens := private.parse_int(private.cell(cells, m, 'reported_opens'));
    v_clicks := private.parse_int(private.cell(cells, m, 'reported_clicks'));
    v_spend := private.parse_amount(private.cell(cells, m, 'spend'));

    foreach f in array array['reported_sent', 'reported_delivered', 'reported_bounced', 'reported_opens', 'reported_clicks', 'spend'] loop
      if private.blank_to_null(private.cell(cells, m, f)) is not null
         and (case f when 'spend' then v_spend is null or v_spend < 0 else private.parse_int(private.cell(cells, m, f)) is null end) then
        perform private.add_issue(v_run, n, 'warning', 'invalid_number', f,
          format('%s value "%s" is not a valid non-negative number; stored as empty.', f, private.cell(cells, m, f)), raw);
        warned := true;
      end if;
    end loop;
    if v_spend < 0 then v_spend := null; end if;

    -- the export's own numbers disagree with each other: keep, but say so
    if v_opens > v_deliv then
      perform private.add_issue(v_run, n, 'warning', 'reported_opens_exceed_delivered', 'reported_opens',
        format('Reported opens (%s) exceed reported deliveries (%s); the source likely counts total opens, not unique people.', v_opens, v_deliv), raw);
      warned := true;
    end if;
    if v_clicks > v_opens then
      perform private.add_issue(v_run, n, 'warning', 'reported_clicks_exceed_opens', 'reported_clicks',
        format('Reported clicks (%s) exceed reported opens (%s).', v_clicks, v_opens), raw);
      warned := true;
    end if;
    if v_sent is not null and v_deliv is not null and v_bounce is not null and v_sent <> v_deliv + v_bounce then
      perform private.add_issue(v_run, n, 'warning', 'reported_sent_mismatch', 'reported_sent',
        format('Reported sent (%s) is not delivered + bounced (%s).', v_sent, v_deliv + v_bounce), raw);
      warned := true;
    end if;

    v_parent := private.blank_to_null(private.cell(cells, m, 'parent_campaign_ref'));
    v_local := left(private.blank_to_null(private.cell(cells, m, 'send_local_time')), 40);

    select k.id, k.source_exported_at, k.last_import_run_id,
           (k.name, k.channel, k.target_country, k.reported_sent, k.reported_delivered, k.reported_bounced,
            k.reported_opens, k.reported_clicks, k.spend, k.sent_at, k.send_local_time, k.parent_campaign_ref)::text as data
      into ex
      from public.campaigns k
      where k.brand_id = v_run.brand_id and k.external_id = v_ext
      for update;

    if not found then
      insert into public.campaigns (brand_id, external_id, name, channel, target_country, reported_sent, reported_delivered,
        reported_bounced, reported_opens, reported_clicks, spend, sent_at, send_local_time, parent_campaign_ref,
        source_exported_at, last_import_run_id)
      values (v_run.brand_id, v_ext, v_name, v_channel, v_target.value, v_sent, v_deliv, v_bounce, v_opens, v_clicks,
        v_spend, v_sent_at.value, v_local, left(v_parent, 64), v_run.source_exported_at, v_run.id);
      c := jsonb_set(c, '{inserted}', to_jsonb((c->>'inserted')::int + 1));
    else
      if ex.last_import_run_id = v_run.id then
        perform private.add_issue(v_run, n, 'warning', 'duplicate_in_file', 'external_id',
          format('Campaign %s appears more than once in this file; the later row was kept.', v_ext), raw);
        warned := true;
      end if;
      if ex.source_exported_at > v_run.source_exported_at then
        update public.campaigns set last_import_run_id = v_run.id where id = ex.id;
        perform private.add_issue(v_run, n, 'warning', 'superseded_by_newer_export', null,
          'Not applied: this campaign was already updated from a newer export.', raw);
        warned := true;
        c := jsonb_set(c, '{superseded}', to_jsonb((c->>'superseded')::int + 1));
      elsif ex.data is distinct from (v_name, v_channel, v_target.value, v_sent, v_deliv, v_bounce, v_opens, v_clicks,
             v_spend, v_sent_at.value, v_local, left(v_parent, 64))::text then
        update public.campaigns set name = v_name, channel = v_channel, target_country = v_target.value,
          reported_sent = v_sent, reported_delivered = v_deliv, reported_bounced = v_bounce, reported_opens = v_opens,
          reported_clicks = v_clicks, spend = v_spend, sent_at = v_sent_at.value, send_local_time = v_local,
          parent_campaign_ref = left(v_parent, 64), source_exported_at = v_run.source_exported_at,
          last_import_run_id = v_run.id, updated_at = now()
        where id = ex.id;
        c := jsonb_set(c, '{updated}', to_jsonb((c->>'updated')::int + 1));
      else
        update public.campaigns set last_import_run_id = v_run.id where id = ex.id;
        c := jsonb_set(c, '{unchanged}', to_jsonb((c->>'unchanged')::int + 1));
      end if;
    end if;

    if warned then
      c := jsonb_set(c, '{warned}', to_jsonb((c->>'warned')::int + 1));
    end if;
  end loop;
  return c;
end
$$;

create or replace function private.import_events_rows(v_run public.import_runs, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_brand     public.brands;
  v_hdr_norm  text[] := array(select private.norm_header(h) from unnest(v_run.header) h);
  v_ncols     int := cardinality(v_run.header);
  m           jsonb := v_run.column_map;
  r           jsonb;
  n           int;
  cells       text[];
  raw         jsonb;
  ok          boolean;
  c           jsonb := '{"inserted":0,"updated":0,"unchanged":0,"superseded":0,"rejected":0,"warned":0,"blank":0}';
  v_eid text; v_contact uuid; v_campaign uuid; v_type text; v_channel text; v_at record;
  v_inserted boolean;
  ex public.engagement_events;
begin
  select * into v_brand from public.brands where id = v_run.brand_id;

  for r in select value from jsonb_array_elements(p_rows) loop
    n := (r->>'n')::int;
    cells := array(select jsonb_array_elements_text(r->'c'));
    if coalesce(cardinality(cells), 0) = 0 or array_to_string(cells, '') ~ '^\s*$' then
      c := jsonb_set(c, '{blank}', to_jsonb((c->>'blank')::int + 1));
      continue;
    end if;
    raw := private.row_json(v_run.header, cells);
    if cardinality(cells) <> v_ncols then
      perform private.add_issue(v_run, n, 'error', 'wrong_column_count', null,
        format('Expected %s columns, found %s.', v_ncols, cardinality(cells)), raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;
    if array(select private.norm_header(x) from unnest(cells) x) = v_hdr_norm then
      perform private.add_issue(v_run, n, 'error', 'repeated_header', null, 'A header row repeated inside the file.', raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    v_eid := private.blank_to_null(private.cell(cells, m, 'event_id'));
    v_type := lower(btrim(private.cell(cells, m, 'event_type')));
    v_channel := lower(btrim(private.cell(cells, m, 'channel')));
    v_at := private.parse_ts(private.cell(cells, m, 'occurred_at'), v_brand.timezone);
    -- lookups are scoped to this brand: an id from another brand simply isn't found
    select ct.id into v_contact from public.contacts ct
      where ct.brand_id = v_run.brand_id and ct.external_id = btrim(private.cell(cells, m, 'contact_external_id'));
    select k.id into v_campaign from public.campaigns k
      where k.brand_id = v_run.brand_id and k.external_id = btrim(private.cell(cells, m, 'campaign_external_id'));

    ok := false;
    if v_eid is null or v_eid !~ '^[A-Za-z0-9_.:-]{1,64}$' then
      perform private.add_issue(v_run, n, 'error', 'invalid_event_id', 'event_id', 'Missing or malformed event id.', raw);
    elsif v_type is null or v_type not in ('open', 'click', 'bounce', 'complaint', 'unsubscribe') then
      perform private.add_issue(v_run, n, 'error', 'invalid_event_type', 'event_type',
        format('Event type "%s" is not one of open, click, bounce, complaint, unsubscribe.', private.cell(cells, m, 'event_type')), raw);
    elsif v_channel is null or v_channel not in ('email', 'sms') then
      perform private.add_issue(v_run, n, 'error', 'invalid_channel', 'channel', 'Channel is not email or sms.', raw);
    elsif v_at.value is null then
      perform private.add_issue(v_run, n, 'error', 'invalid_occurred_at', 'occurred_at', 'Missing or unreadable event time.', raw);
    elsif v_contact is null then
      perform private.add_issue(v_run, n, 'error', 'unknown_contact', 'contact_external_id',
        format('Contact %s is not in %s''s contact list (import contacts first, or the contact was rejected).',
          private.cell(cells, m, 'contact_external_id'), v_brand.name), raw);
    elsif v_campaign is null then
      perform private.add_issue(v_run, n, 'error', 'unknown_campaign', 'campaign_external_id',
        format('Campaign %s is not in %s''s campaign list, so this event cannot be attributed.',
          private.cell(cells, m, 'campaign_external_id'), v_brand.name), raw);
    else
      ok := true;
    end if;
    if not ok then
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    insert into public.engagement_events (brand_id, event_id, contact_id, campaign_id, event_type, channel, occurred_at, import_run_id)
    values (v_run.brand_id, v_eid, v_contact, v_campaign, v_type, v_channel, v_at.value, v_run.id)
    on conflict (brand_id, event_id) do nothing
    returning true into v_inserted;

    if v_inserted then
      c := jsonb_set(c, '{inserted}', to_jsonb((c->>'inserted')::int + 1));
    else
      select * into ex from public.engagement_events e where e.brand_id = v_run.brand_id and e.event_id = v_eid;
      if (ex.contact_id, ex.campaign_id, ex.event_type, ex.channel, ex.occurred_at)
         is not distinct from (v_contact, v_campaign, v_type, v_channel, v_at.value) then
        c := jsonb_set(c, '{unchanged}', to_jsonb((c->>'unchanged')::int + 1));
        if ex.import_run_id = v_run.id then
          perform private.add_issue(v_run, n, 'warning', 'duplicate_in_file', 'event_id',
            format('Event %s appears more than once in this file; counted once.', v_eid), raw);
          c := jsonb_set(c, '{warned}', to_jsonb((c->>'warned')::int + 1));
        end if;
      else
        perform private.add_issue(v_run, n, 'warning', 'event_id_conflict', 'event_id',
          format('Event %s was already loaded with different details; the first version was kept.', v_eid), raw);
        c := jsonb_set(c, '{superseded}', to_jsonb((c->>'superseded')::int + 1));
        c := jsonb_set(c, '{warned}', to_jsonb((c->>'warned')::int + 1));
      end if;
    end if;
    v_inserted := null;
  end loop;
  return c;
end
$$;

create or replace function private.import_send_log_rows(v_run public.import_runs, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_brand     public.brands;
  v_hdr_norm  text[] := array(select private.norm_header(h) from unnest(v_run.header) h);
  v_ncols     int := cardinality(v_run.header);
  m           jsonb := v_run.column_map;
  r           jsonb;
  n           int;
  cells       text[];
  raw         jsonb;
  ok          boolean;
  c           jsonb := '{"inserted":0,"updated":0,"unchanged":0,"superseded":0,"rejected":0,"warned":0,"blank":0}';
  v_key text; v_campaign uuid; v_at record; v_count int; v_status text;
  v_inserted boolean;
  ex public.legacy_sends;
begin
  select * into v_brand from public.brands where id = v_run.brand_id;

  for r in select value from jsonb_array_elements(p_rows) loop
    n := (r->>'n')::int;
    cells := array(select jsonb_array_elements_text(r->'c'));
    if coalesce(cardinality(cells), 0) = 0 or array_to_string(cells, '') ~ '^\s*$' then
      c := jsonb_set(c, '{blank}', to_jsonb((c->>'blank')::int + 1));
      continue;
    end if;
    raw := private.row_json(v_run.header, cells);
    if cardinality(cells) <> v_ncols then
      perform private.add_issue(v_run, n, 'error', 'wrong_column_count', null,
        format('Expected %s columns, found %s.', v_ncols, cardinality(cells)), raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;
    if array(select private.norm_header(x) from unnest(cells) x) = v_hdr_norm then
      perform private.add_issue(v_run, n, 'error', 'repeated_header', null, 'A header row repeated inside the file.', raw);
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    v_key := private.blank_to_null(private.cell(cells, m, 'batch_key'));
    v_at := private.parse_ts(private.cell(cells, m, 'queued_at'), v_brand.timezone);
    v_count := private.parse_int(private.cell(cells, m, 'recipient_count'));
    v_status := lower(private.blank_to_null(private.cell(cells, m, 'status')));
    select k.id into v_campaign from public.campaigns k
      where k.brand_id = v_run.brand_id and k.external_id = btrim(private.cell(cells, m, 'campaign_external_id'));

    ok := false;
    if v_key is null or v_key !~ '^[A-Za-z0-9_.:-]{1,64}$' then
      perform private.add_issue(v_run, n, 'error', 'invalid_batch_key', 'batch_key', 'Missing or malformed batch key.', raw);
    elsif v_campaign is null then
      perform private.add_issue(v_run, n, 'error', 'unknown_campaign', 'campaign_external_id',
        format('Campaign %s is not in %s''s campaign list.', private.cell(cells, m, 'campaign_external_id'), v_brand.name), raw);
    elsif v_at.value is null then
      perform private.add_issue(v_run, n, 'error', 'invalid_queued_at', 'queued_at', 'Missing or unreadable queue time.', raw);
    elsif v_count is null then
      perform private.add_issue(v_run, n, 'error', 'invalid_recipient_count', 'recipient_count', 'Recipient count is not a non-negative whole number.', raw);
    elsif v_status is null or length(v_status) > 30 then
      perform private.add_issue(v_run, n, 'error', 'invalid_status', 'status', 'Missing or overlong status.', raw);
    else
      ok := true;
    end if;
    if not ok then
      c := jsonb_set(c, '{rejected}', to_jsonb((c->>'rejected')::int + 1));
      continue;
    end if;

    insert into public.legacy_sends (brand_id, batch_key, campaign_id, queued_at, recipient_count, status, import_run_id)
    values (v_run.brand_id, v_key, v_campaign, v_at.value, v_count, v_status, v_run.id)
    on conflict (brand_id, batch_key) do nothing
    returning true into v_inserted;

    if v_inserted then
      c := jsonb_set(c, '{inserted}', to_jsonb((c->>'inserted')::int + 1));
    else
      select * into ex from public.legacy_sends s where s.brand_id = v_run.brand_id and s.batch_key = v_key;
      if (ex.campaign_id, ex.queued_at, ex.recipient_count, ex.status) is not distinct from (v_campaign, v_at.value, v_count, v_status) then
        c := jsonb_set(c, '{unchanged}', to_jsonb((c->>'unchanged')::int + 1));
        if ex.import_run_id = v_run.id then
          perform private.add_issue(v_run, n, 'warning', 'duplicate_in_file', 'batch_key',
            format('Batch %s is listed more than once; it is one send and is counted once.', v_key), raw);
          c := jsonb_set(c, '{warned}', to_jsonb((c->>'warned')::int + 1));
        end if;
      else
        -- an approved send is history: never rewrite it
        perform private.add_issue(v_run, n, 'warning', 'batch_key_conflict', 'batch_key',
          format('Batch %s was already recorded with different details; the original record was kept.', v_key), raw);
        c := jsonb_set(c, '{superseded}', to_jsonb((c->>'superseded')::int + 1));
        c := jsonb_set(c, '{warned}', to_jsonb((c->>'warned')::int + 1));
      end if;
    end if;
    v_inserted := null;
  end loop;
  return c;
end
$$;

-- ---------------------------------------------------------------------------
-- import_chunk
-- ---------------------------------------------------------------------------
create or replace function public.import_chunk(p_run_id uuid, p_chunk_no int, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_run    public.import_runs;
  v_prior  jsonb;
  v_res    jsonb;
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
    select 1 from jsonb_array_elements(p_rows) e
    where jsonb_typeof(e) <> 'object' or jsonb_typeof(e->'n') <> 'number' or jsonb_typeof(e->'c') <> 'array'
       or exists (select 1 from jsonb_array_elements(e->'c') x where jsonb_typeof(x) <> 'string')
  ) then
    raise exception 'each row must be {"n": <line number>, "c": [<cell strings>]}' using errcode = '22023';
  end if;

  -- one writer per run at a time; a retried chunk returns its original result
  perform pg_advisory_xact_lock(hashtextextended(v_run.id::text, 0));
  select result into v_prior from public.import_run_chunks where run_id = p_run_id and chunk_no = p_chunk_no;
  if v_prior is not null then
    return v_prior || '{"replayed": true}';
  end if;

  v_res := case v_run.kind
    when 'contacts'  then private.import_contacts_rows(v_run, p_rows)
    when 'campaigns' then private.import_campaigns_rows(v_run, p_rows)
    when 'events'    then private.import_events_rows(v_run, p_rows)
    when 'send_log'  then private.import_send_log_rows(v_run, p_rows)
  end;

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

-- ---------------------------------------------------------------------------
-- import_finish / import_abort
-- ---------------------------------------------------------------------------
create or replace function public.import_finish(p_run_id uuid)
returns public.import_runs
language plpgsql security definer set search_path = '' as $$
declare
  v_run public.import_runs;
  k record;
begin
  select * into v_run from public.import_runs where id = p_run_id for update;
  perform private.assert_member(v_run.brand_id, true);
  if v_run.status <> 'running' then
    return v_run;   -- finishing twice is a no-op
  end if;

  if v_run.kind = 'campaigns' then
    -- parent references are resolved only inside the same brand; anything else is named, never followed
    for k in
      select c.external_id, c.parent_campaign_ref from public.campaigns c
      where c.brand_id = v_run.brand_id and c.last_import_run_id = v_run.id and c.parent_campaign_ref is not null
        and not exists (select 1 from public.campaigns p where p.brand_id = c.brand_id and p.external_id = c.parent_campaign_ref)
    loop
      perform private.add_issue(v_run, null, 'warning', 'parent_campaign_not_in_brand', 'parent_campaign_ref',
        format('Campaign %s names parent %s, which is not one of this brand''s campaigns. Kept as text only; not linked.',
          k.external_id, k.parent_campaign_ref));
    end loop;
  end if;

  update public.import_runs
    set status = 'completed', finished_at = now(), last_activity_at = now()
    where id = v_run.id
    returning * into v_run;
  return v_run;
end
$$;

create or replace function public.import_abort(p_run_id uuid, p_reason text)
returns public.import_runs
language plpgsql security definer set search_path = '' as $$
declare
  v_run public.import_runs;
begin
  select * into v_run from public.import_runs where id = p_run_id for update;
  perform private.assert_member(v_run.brand_id, true);
  if v_run.status = 'running' then
    update public.import_runs
      set status = 'failed', finished_at = now(), failure_reason = left(coalesce(p_reason, 'aborted'), 500)
      where id = v_run.id
      returning * into v_run;
  end if;
  return v_run;
end
$$;

-- ---------------------------------------------------------------------------
-- grants: only the four entry points are callable, and only when signed in
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.current_email(), private.current_brand_ids(),
  private.is_owner(uuid), private.assert_member(uuid, boolean) to authenticated;

revoke execute on function public.import_start(uuid, text, text, text, bigint, text, text, text[], int, timestamptz) from public, anon;
revoke execute on function public.import_chunk(uuid, int, jsonb) from public, anon;
revoke execute on function public.import_finish(uuid) from public, anon;
revoke execute on function public.import_abort(uuid, text) from public, anon;
grant execute on function public.import_start(uuid, text, text, text, bigint, text, text, text[], int, timestamptz) to authenticated;
grant execute on function public.import_chunk(uuid, int, jsonb) to authenticated;
grant execute on function public.import_finish(uuid) to authenticated;
grant execute on function public.import_abort(uuid, text) to authenticated;
