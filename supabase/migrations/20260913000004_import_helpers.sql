-- Normalisation helpers for imports. Pure functions, no table access, living
-- in the private schema. Each returns the cleaned value plus, where useful, an
-- issue code the importer turns into a row-level warning or error.
--
-- These are the single source of truth for "what counts as a valid value":
-- the browser only splits bytes into cells; every judgement happens here.

-- ---------------------------------------------------------------------------
-- header aliases: canonical field <- the spellings exports actually use
-- ---------------------------------------------------------------------------
create table private.import_fields (
  kind      text not null,
  field     text not null,
  required  boolean not null,
  aliases   text[] not null,
  primary key (kind, field)
);

insert into private.import_fields (kind, field, required, aliases) values
  ('contacts', 'external_id',       true,  '{external_id,externalid,contact_id,customer_id,id}'),
  ('contacts', 'full_name',         false, '{full_name,fullname,name,customer_name}'),
  ('contacts', 'email',             true,  '{email,e_mail,email_address,mail}'),
  ('contacts', 'phone',             true,  '{phone,mobile,phone_number,msisdn,telephone}'),
  ('contacts', 'country',           false, '{country,pays,country_code}'),
  ('contacts', 'city',              false, '{city,ville,town}'),
  ('contacts', 'signup_at',         true,  '{signup_at,signed_up_at,signup_date,created_at}'),
  ('contacts', 'status',            true,  '{status,contact_status}'),
  ('contacts', 'consent_marketing', true,  '{consent_marketing,marketing_consent,consent,opt_in}'),
  ('contacts', 'deleted_at',        true,  '{deleted_at,deleted}'),
  ('contacts', 'suppressed_until',  true,  '{suppressed_until,suppression_until}'),
  ('contacts', 'brand_code',        true,  '{brand_code,brand}'),
  ('contacts', 'notes',             false, '{notes,note,comments}'),

  ('campaigns', 'external_id',        true,  '{external_id,campaign_id,id}'),
  ('campaigns', 'name',               true,  '{campaign_name,name,nom}'),
  ('campaigns', 'channel',            true,  '{channel,canal}'),
  ('campaigns', 'target_country',     false, '{target_country,country}'),
  ('campaigns', 'reported_sent',      false, '{reported_sent,sent}'),
  ('campaigns', 'reported_delivered', false, '{reported_delivered,delivered}'),
  ('campaigns', 'reported_bounced',   false, '{reported_bounced,bounced}'),
  ('campaigns', 'reported_opens',     false, '{reported_opens,opens}'),
  ('campaigns', 'reported_clicks',    false, '{reported_clicks,clicks}'),
  ('campaigns', 'spend',              false, '{spend,cost}'),
  ('campaigns', 'sent_at',            true,  '{sent_at_utc,sent_at}'),
  ('campaigns', 'send_local_time',    false, '{send_local_time}'),
  ('campaigns', 'parent_campaign_ref', false, '{parent_campaign_id,parent_campaign}'),

  ('events', 'event_id',            true, '{event_id,id}'),
  ('events', 'contact_external_id', true, '{external_contact_id,contact_external_id,contact_id}'),
  ('events', 'campaign_external_id', true, '{campaign_external_id,campaign_id}'),
  ('events', 'event_type',          true, '{event_type,type}'),
  ('events', 'channel',             true, '{channel}'),
  ('events', 'occurred_at',         true, '{occurred_at_utc,occurred_at,timestamp}'),

  ('send_log', 'batch_key',            true, '{batch_key,batch_id}'),
  ('send_log', 'campaign_external_id', true, '{campaign_external_id,campaign_id}'),
  ('send_log', 'queued_at',            true, '{queued_at_utc,queued_at}'),
  ('send_log', 'recipient_count',      true, '{recipient_count,recipients}'),
  ('send_log', 'status',               true, '{status}');

-- "External Id" / "e_mail" / "﻿external_id" -> external_id / e_mail / external_id
create or replace function private.norm_header(p text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select trim(both '_' from regexp_replace(lower(btrim(replace(coalesce(p, ''), chr(65279), ''))), '[^a-z0-9]+', '_', 'g'))
$$;

-- empty / whitespace-only -> null
create or replace function private.blank_to_null(p text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select nullif(btrim(p), '')
$$;

-- ---------------------------------------------------------------------------
-- value normalisers
-- ---------------------------------------------------------------------------

-- Returns (value, issue). value null + issue null means "not provided".
create or replace function private.norm_email(p text, out value text, out issue text)
language sql immutable parallel safe set search_path = '' as $$
  with v as (select lower(btrim(p)) as e)
  select
    case when e is null or e = '' then null
         when e ~ '^[a-z0-9._%+''-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' and e !~ '\.\.' then e
    end,
    case when e is null or e = '' then null
         when e ~ '^[a-z0-9._%+''-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' and e !~ '\.\.' then null
         else 'invalid_email'
    end
  from v
$$;

create or replace function private.calling_code(p_country text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select case upper(p_country)
    when 'KE' then '254' when 'ZA' then '27'  when 'MA' then '212'
    when 'UG' then '256' when 'TZ' then '255' when 'RW' then '250'
    when 'ET' then '251' when 'SS' then '211'
  end
$$;

-- Accepts +CC..., CC... (known codes, 9 national digits) and 0XXXXXXXXX
-- (national format, using the contact's country, else the brand's country).
-- Anything else is reported rather than guessed at.
create or replace function private.norm_phone(p text, p_country text, out value text, out issue text)
language plpgsql immutable parallel safe set search_path = '' as $$
declare
  raw text := btrim(coalesce(p, ''));
  digits text := regexp_replace(raw, '\D', '', 'g');
  cc text;
begin
  if raw = '' then
    return;
  end if;
  if raw ~* '^[0-9.]+e\+?[0-9]+$' then
    issue := 'phone_scientific_notation';   -- spreadsheet destroyed the digits
    return;
  end if;
  foreach cc in array array['254', '27', '212', '256', '255', '250', '251', '211'] loop
    if digits like cc || '%' and length(digits) = length(cc) + 9 then
      value := '+' || digits;
      return;
    end if;
  end loop;
  if digits ~ '^0[1-9][0-9]{8}$' and private.calling_code(p_country) is not null then
    value := '+' || private.calling_code(p_country) || substr(digits, 2);
    return;
  end if;
  issue := 'invalid_phone';
end
$$;

-- Returns true / false / null (not stated). issue set for unrecognised values.
create or replace function private.norm_bool(p text, out value boolean, out issue text)
language sql immutable parallel safe set search_path = '' as $$
  select
    case when v in ('true', 't', '1', 'yes', 'y') then true
         when v in ('false', 'f', '0', 'no', 'n') then false
    end,
    case when v is null or v = '' or v in ('true', 't', '1', 'yes', 'y', 'false', 'f', '0', 'no', 'n') then null
         else 'invalid_boolean'
    end
  from (select lower(btrim(p)) as v) s
$$;

create or replace function private.norm_status(p text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select case lower(btrim(p))
    when 'active' then 'active'
    when 'unsubscribed' then 'unsubscribed' when 'unsubscribe' then 'unsubscribed'
    when 'bounced' then 'bounced' when 'bounce' then 'bounced'
    when 'pending' then 'pending'
  end
$$;

create or replace function private.norm_country(p text, out value text, out issue text)
language sql immutable parallel safe set search_path = '' as $$
  select
    case when v in ('', 'NONE', 'NULL', 'N/A', 'NA', '-') then null
         when v in ('KE', 'KEN', 'KENYA', '254') then 'KE'
         when v in ('ZA', 'ZAF', 'SOUTH AFRICA', '27') then 'ZA'
         when v in ('MA', 'MAR', 'MOROCCO', 'MAROC', '212') then 'MA'
         when v = 'ZZ' then null
         when v ~ '^[A-Z]{2}$' then v
    end,
    case when v in ('', 'NONE', 'NULL', 'N/A', 'NA', '-') then null
         when v in ('KE', 'KEN', 'KENYA', '254', 'ZA', 'ZAF', 'SOUTH AFRICA', '27', 'MA', 'MAR', 'MOROCCO', 'MAROC', '212') then null
         when v = 'ZZ' then 'unknown_country'
         when v ~ '^[A-Z]{2}$' then null
         else 'unknown_country'
    end
  from (select upper(btrim(coalesce(p, ''))) as v) s
$$;

-- Timestamps. Explicit-zone ISO is taken as-is. Zone-less forms are read in
-- the brand's local timezone and reported via `format` so the importer can
-- warn. DD/MM/YYYY is assumed over MM/DD because the exports contain days > 12.
create or replace function private.parse_ts(p text, p_tz text, out value timestamptz, out format text)
language plpgsql stable parallel safe set search_path = '' as $$
declare
  s text := btrim(coalesce(p, ''));
  m text[];
begin
  if s = '' then
    return;
  end if;
  begin
    if s ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}(:?\d{2})?)$' then
      value := s::timestamptz;
      format := 'iso';
    elsif s ~ '^\d{4}-\d{2}-\d{2}$' then
      value := (s::date)::timestamp at time zone p_tz;
      format := 'date_only';
    elsif s ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?$' then
      value := s::timestamp at time zone p_tz;
      format := 'local_no_zone';
    else
      m := regexp_match(s, '^(\d{1,2})/(\d{1,2})/(\d{4})(?: (\d{1,2}):(\d{2}))?$');
      if m is not null then
        value := make_timestamp(m[3]::int, m[2]::int, m[1]::int, coalesce(m[4], '0')::int, coalesce(m[5], '0')::int, 0)
                 at time zone p_tz;
        format := 'dd/mm/yyyy';
      else
        format := 'invalid';
      end if;
    end if;
  exception when others then
    value := null;
    format := 'invalid';   -- e.g. 31/02/2026, 2026-13-01
  end;
end
$$;

-- "1,234.50" / "221,09" / "€ 61.81" -> numeric. Comma is a decimal separator
-- only when it is the last separator and followed by exactly 1-2 digits.
create or replace function private.parse_amount(p text)
returns numeric language plpgsql immutable parallel safe set search_path = '' as $$
declare
  s text := regexp_replace(btrim(coalesce(p, '')), '[^0-9.,-]', '', 'g');
begin
  if s = '' then return null; end if;
  if s ~ ',\d{1,2}$' and s !~ '\.\d+$' then
    s := replace(replace(s, '.', ''), ',', '.');
  else
    s := replace(s, ',', '');
  end if;
  if s !~ '^-?\d+(\.\d+)?$' then return null; end if;
  return s::numeric;
end
$$;

create or replace function private.parse_int(p text)
returns int language sql immutable parallel safe set search_path = '' as $$
  select case when btrim(p) ~ '^\d{1,9}$' then btrim(p)::int end
$$;

-- cell for a canonical field, using the run's column map (0-based indexes)
create or replace function private.cell(p_cells text[], p_map jsonb, p_field text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select case when p_map ? p_field then p_cells[(p_map->>p_field)::int + 1] end
$$;
