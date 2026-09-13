-- Velocity Campaign Portal: complete database schema
-- Generated from supabase/migrations by `npm run schema`. Apply migrations, not this file,
-- to a live project (supabase db push); this file is for reading and review.

-- ============================================================================
-- 20260913000001_tenancy.sql
-- ============================================================================
-- Tenancy foundation: brands, the membership allowlist, and the helpers every
-- RLS policy in this project goes through.
--
-- THE DATA-ISOLATION GUARANTEE LIVES HERE: private.current_brand_ids() is the
-- only source of "which brands may this caller see". Every tenant table's
-- policy is written as  brand_id in (select private.current_brand_ids()).

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- brands
-- ---------------------------------------------------------------------------
create table public.brands (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z][a-z0-9-]{1,40}$'),
  code        text not null unique check (code ~ '^[A-Z]{2,20}$'),  -- brand_code in exports
  name        text not null check (length(name) between 1 and 100),
  country     char(2) not null,
  timezone    text not null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- memberships: the allowlist. Exactly who may sign in, and to what.
-- Keyed by email so the same person works whether they arrive via password
-- or Google (Supabase links identities that share a verified email).
-- ---------------------------------------------------------------------------
create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  brand_id    uuid not null references public.brands(id) on delete restrict,
  email       text not null unique              -- one brand per person
              check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role        text not null check (role in ('owner', 'analyst')),
  created_at  timestamptz not null default now()
);
create index on public.memberships (brand_id);

-- ---------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER, in a schema PostgREST does not expose)
-- ---------------------------------------------------------------------------

-- Email of the calling user, only if Supabase has verified it.
-- Read from auth.users (not the JWT claim) so a stale or forged claim can't
-- widen access.
create or replace function private.current_email()
returns text
language sql stable security definer
set search_path = ''
as $$
  select lower(u.email)
  from auth.users u
  where u.id = auth.uid()
    and u.email_confirmed_at is not null
    and u.deleted_at is null
    and coalesce(u.banned_until, '-infinity') < now()
$$;

create or replace function private.current_brand_ids()
returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select m.brand_id
  from public.memberships m
  where m.email = private.current_email()
$$;

create or replace function private.is_owner(p_brand_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.email = private.current_email()
      and m.brand_id = p_brand_id
      and m.role = 'owner'
  )
$$;

-- Raise unless the caller belongs to the brand (optionally as owner).
create or replace function private.assert_member(p_brand_id uuid, p_require_owner boolean default false)
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if p_brand_id is null or not exists (
    select 1 from public.memberships m
    where m.email = private.current_email()
      and m.brand_id = p_brand_id
      and (not p_require_owner or m.role = 'owner')
  ) then
    -- Same error whether the brand exists or not: no enumeration.
    raise exception 'not permitted' using errcode = '42501';
  end if;
end
$$;

grant usage on schema private to authenticated;
grant execute on function private.current_email(), private.current_brand_ids(),
  private.is_owner(uuid), private.assert_member(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.brands enable row level security;
alter table public.brands force row level security;
alter table public.memberships enable row level security;
alter table public.memberships force row level security;

create policy brands_select on public.brands
  for select to authenticated
  using (id in (select private.current_brand_ids()));

-- A user sees their own brand's team (owner + analyst), nothing else.
create policy memberships_select on public.memberships
  for select to authenticated
  using (brand_id in (select private.current_brand_ids()));

-- No insert/update/delete policies: memberships are managed by migrations /
-- service role only.

revoke all on public.brands, public.memberships from anon;
revoke insert, update, delete, truncate on public.brands, public.memberships from authenticated;
grant select on public.brands, public.memberships to authenticated;

-- ---------------------------------------------------------------------------
-- "Who am I" for the SPA: brand + role for the signed-in user.
-- ---------------------------------------------------------------------------
create or replace function public.my_membership()
returns table (brand_id uuid, brand_slug text, brand_name text, brand_timezone text, role text, email text)
language sql stable security invoker
set search_path = ''
as $$
  select b.id, b.slug, b.name, b.timezone, m.role, m.email
  from public.memberships m
  join public.brands b on b.id = m.brand_id
  where m.email = private.current_email()
$$;
revoke execute on function public.my_membership() from public, anon;
grant execute on function public.my_membership() to authenticated;

-- ---------------------------------------------------------------------------
-- Seed brands (memberships seeded separately once emails are final)
-- ---------------------------------------------------------------------------
insert into public.brands (slug, code, name, country, timezone) values
  ('kilele',    'KILELE',    'Kilele Rides',       'KE', 'Africa/Nairobi'),
  ('karoo',     'KAROO',     'Karoo Coaches',      'ZA', 'Africa/Johannesburg'),
  ('marrakech', 'MARRAKECH', 'Marrakech Express',  'MA', 'Africa/Casablanca');

-- ============================================================================
-- 20260913000002_default_deny.sql
-- ============================================================================
-- Default-deny for tables added later ("including the ones added after you've
-- moved on"). Any new table in public gets RLS enabled+forced the moment it is
-- created, so until someone writes a policy it returns nothing to anon or
-- authenticated. The isolation test suite (supabase/tests/rls_coverage.sql)
-- is the second line: it fails if a tenant table lacks a brand-scoped policy.

create or replace function private.enforce_rls_on_new_tables()
returns event_trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  obj record;
begin
  for obj in
    select * from pg_event_trigger_ddl_commands()
    where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      and schema_name = 'public'
      and object_type = 'table'
  loop
    execute format('alter table %s enable row level security', obj.object_identity);
    execute format('alter table %s force row level security', obj.object_identity);
    execute format('revoke all on %s from anon', obj.object_identity);
  end loop;
end
$$;

drop event trigger if exists enforce_rls_on_new_tables;
create event trigger enforce_rls_on_new_tables
  on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function private.enforce_rls_on_new_tables();

-- New tables in public should not be readable by anon by default either.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- ============================================================================
-- 20260913000003_core_data.sql
-- ============================================================================
-- Core tenant data: contacts, campaigns, historical engagement events,
-- legacy send log, and the import audit trail.
--
-- Isolation rules applied to every table below:
--   * brand_id uuid NOT NULL
--   * RLS enabled + forced, one SELECT policy scoped by private.current_brand_ids()
--   * no INSERT/UPDATE/DELETE grants to anon/authenticated: all writes go through
--     SECURITY DEFINER RPCs that call private.assert_member(brand, require_owner)
--   * child rows reference parents by (brand_id, id), so a row can never point
--     at another brand's parent even if an id is guessed.

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- import audit trail
-- ---------------------------------------------------------------------------
create table public.import_runs (
  id                  uuid primary key default gen_random_uuid(),
  brand_id            uuid not null references public.brands(id),
  kind                text not null check (kind in ('contacts', 'campaigns', 'events', 'send_log')),
  file_name           text not null check (length(file_name) between 1 and 255),
  file_sha256         text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  file_size_bytes     bigint not null check (file_size_bytes >= 0),
  encoding            text not null check (encoding in ('utf-8', 'windows-1252')),
  delimiter           text not null check (delimiter in (',', ';', E'\t', '|')),
  header              text[] not null,
  column_map          jsonb not null,          -- canonical field -> column index
  source_exported_at  timestamptz not null,    -- newer exports win over older ones
  status              text not null default 'running'
                      check (status in ('running', 'completed', 'failed')),
  rows_total          int not null default 0,
  rows_inserted       int not null default 0,
  rows_updated        int not null default 0,
  rows_unchanged      int not null default 0,
  rows_rejected       int not null default 0,
  rows_warned         int not null default 0,
  started_by          uuid not null default auth.uid(),
  started_at          timestamptz not null default now(),
  finished_at         timestamptz,
  unique (brand_id, id)
);
create index on public.import_runs (brand_id, started_at desc);
create index on public.import_runs (brand_id, kind, file_sha256);

create table public.import_issues (
  id          bigint generated always as identity primary key,
  brand_id    uuid not null,
  run_id      uuid not null,
  row_number  int,                               -- 1-based line in the file (header = 1)
  severity    text not null check (severity in ('error', 'warning')),
  code        text not null,
  field       text,
  message     text not null,
  raw         jsonb,
  created_at  timestamptz not null default now(),
  foreign key (brand_id, run_id) references public.import_runs (brand_id, id) on delete cascade
);
create index on public.import_issues (brand_id, run_id, severity, row_number);

-- ---------------------------------------------------------------------------
-- contacts
-- ---------------------------------------------------------------------------
create table public.contacts (
  id                  uuid primary key default gen_random_uuid(),
  brand_id            uuid not null references public.brands(id),
  external_id         text not null check (external_id ~ '^[A-Za-z0-9_.:-]{1,64}$'),
  full_name           text check (length(full_name) <= 200),
  email               text check (email is null or (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$')),
  phone_raw           text check (length(phone_raw) <= 50),
  phone_e164          text check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  country             char(2) check (country ~ '^[A-Z]{2}$'),
  city                text check (length(city) <= 100),
  signup_at           timestamptz,
  status              text not null check (status in ('active', 'unsubscribed', 'bounced', 'pending')),
  consent_marketing   boolean,                   -- null = not stated in the export
  deleted_at          timestamptz,
  suppressed_until    timestamptz,
  notes               text check (length(notes) <= 2000),
  source_exported_at  timestamptz not null,
  last_import_run_id  uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (brand_id, external_id),
  unique (brand_id, id)
);
create index on public.contacts (brand_id, signup_at);
create index on public.contacts (brand_id, email) where email is not null;
create index contacts_search_trgm on public.contacts
  using gin ((coalesce(full_name, '') || ' ' || coalesce(email, '') || ' ' || external_id) extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- campaigns
-- ---------------------------------------------------------------------------
create table public.campaigns (
  id                    uuid primary key default gen_random_uuid(),
  brand_id              uuid not null references public.brands(id),
  external_id           text not null check (external_id ~ '^[A-Za-z0-9_.:-]{1,64}$'),
  name                  text not null check (length(name) between 1 and 200),
  channel               text not null check (channel in ('email', 'sms')),
  target_country        char(2) check (target_country ~ '^[A-Z]{2}$'),
  reported_sent         int check (reported_sent >= 0),
  reported_delivered    int check (reported_delivered >= 0),
  reported_bounced      int check (reported_bounced >= 0),
  reported_opens        int check (reported_opens >= 0),
  reported_clicks       int check (reported_clicks >= 0),
  spend                 numeric(14, 2) check (spend >= 0),
  sent_at               timestamptz,
  send_local_time       text check (length(send_local_time) <= 40),
  -- Raw reference only. Deliberately NOT a foreign key: an export may name a
  -- campaign that lives in another brand, and we must never resolve it.
  parent_campaign_ref   text check (length(parent_campaign_ref) <= 64),
  source_exported_at    timestamptz not null,
  last_import_run_id    uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (brand_id, external_id),
  unique (brand_id, id)
);
create index on public.campaigns (brand_id, sent_at desc);

-- ---------------------------------------------------------------------------
-- historical engagement log (from the exports)
-- ---------------------------------------------------------------------------
create table public.engagement_events (
  brand_id        uuid not null references public.brands(id),
  event_id        text not null check (event_id ~ '^[A-Za-z0-9_.:-]{1,64}$'),
  contact_id      uuid not null,
  campaign_id     uuid not null,
  event_type      text not null check (event_type in ('open', 'click', 'bounce', 'complaint', 'unsubscribe')),
  channel         text not null check (channel in ('email', 'sms')),
  occurred_at     timestamptz not null,
  import_run_id   uuid,
  primary key (brand_id, event_id),
  foreign key (brand_id, contact_id)  references public.contacts  (brand_id, id),
  foreign key (brand_id, campaign_id) references public.campaigns (brand_id, id)
);
create index on public.engagement_events (brand_id, campaign_id, event_type, contact_id);
create index on public.engagement_events (brand_id, contact_id, event_type);

-- ---------------------------------------------------------------------------
-- legacy send log (approved sends made before this portal existed)
-- ---------------------------------------------------------------------------
create table public.legacy_sends (
  brand_id         uuid not null references public.brands(id),
  batch_key        text not null check (batch_key ~ '^[A-Za-z0-9_.:-]{1,64}$'),
  campaign_id      uuid not null,
  queued_at        timestamptz not null,
  recipient_count  int not null check (recipient_count >= 0),
  status           text not null check (length(status) <= 30),
  import_run_id    uuid,
  primary key (brand_id, batch_key),
  foreign key (brand_id, campaign_id) references public.campaigns (brand_id, id)
);

-- ---------------------------------------------------------------------------
-- RLS: identical shape on every tenant table
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['import_runs', 'import_issues', 'contacts', 'campaigns', 'engagement_events', 'legacy_sends']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (brand_id in (select private.current_brand_ids()))',
      t || '_select_own_brand', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end
$$;

-- ============================================================================
-- 20260913000004_import_helpers.sql
-- ============================================================================
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

-- ============================================================================
-- 20260913000005_import_rpcs.sql
-- ============================================================================
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

-- ============================================================================
-- 20260913000006_import_control_chars.sql
-- ============================================================================
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

-- ============================================================================
-- 20260913000007_import_read_rpcs.sql
-- ============================================================================
-- Read-side helpers for the Imports screens. SECURITY INVOKER: they run as the
-- caller, so RLS on import_runs / import_issues does the brand scoping.

-- "What didn't load and why", grouped: one line per (severity, code, field).
create or replace function public.import_issue_summary(p_run_id uuid)
returns table (severity text, code text, field text, n bigint, example_message text, first_row int)
language sql stable security invoker set search_path = '' as $$
  select i.severity, i.code, i.field, count(*), min(i.message), min(i.row_number)
  from public.import_issues i
  where i.run_id = p_run_id
  group by i.severity, i.code, i.field
  order by case i.severity when 'error' then 0 else 1 end, count(*) desc
$$;

revoke execute on function public.import_issue_summary(uuid) from public, anon;
grant execute on function public.import_issue_summary(uuid) to authenticated;

-- ============================================================================
-- 20260913000008_reachability_and_metrics.sql
-- ============================================================================
-- Who can be contacted, and the numbers on the dashboard.
--
-- ONE definition of "contactable" lives in public.contact_reachability. The
-- dashboard, the contacts list and (later) the send audience all read it, so
-- the count a marketer sees is the count a send would use.
--
-- A contact is contactable on a channel when ALL of these hold:
--   1. not deleted
--   2. status = active
--   3. consent_marketing = true            (blank = not given)
--   4. suppressed_until is empty or past
--   5. never unsubscribed or complained     (any channel, any source, any time: sticky)
--   6. has a valid address for the channel, and that address has not bounced

-- ---------------------------------------------------------------------------
-- suppressions: sticky facts derived from engagement events and, later, from
-- provider delivery reports. One row per (contact, reason, channel, address).
-- ---------------------------------------------------------------------------
create table public.suppressions (
  id           bigint generated always as identity primary key,
  brand_id     uuid not null,
  contact_id   uuid not null,
  reason       text not null check (reason in ('unsubscribe', 'complaint', 'bounce')),
  channel      text not null check (channel in ('email', 'sms')),
  -- for bounces: the address that bounced (a corrected address is reachable again)
  address      text,
  source       text not null check (source in ('history', 'provider')),
  source_ref   text not null,             -- event id that caused it
  occurred_at  timestamptz not null,
  created_at   timestamptz not null default now(),
  foreign key (brand_id, contact_id) references public.contacts (brand_id, id)
);
create unique index suppressions_one_per_fact
  on public.suppressions (brand_id, contact_id, reason, channel, coalesce(address, ''));
create index on public.suppressions (brand_id, contact_id);

alter table public.suppressions enable row level security;
alter table public.suppressions force row level security;
create policy suppressions_select_own_brand on public.suppressions
  for select to authenticated using (brand_id in (select private.current_brand_ids()));
revoke all on public.suppressions from anon;
revoke insert, update, delete, truncate on public.suppressions from authenticated;
grant select on public.suppressions to authenticated;

-- Derive suppressions from historical engagement events of one import run
-- (or all runs of a brand when p_run_id is null). Idempotent.
create or replace function private.suppressions_from_history(p_brand_id uuid, p_run_id uuid)
returns int language sql security definer set search_path = '' as $$
  with ins as (
    insert into public.suppressions (brand_id, contact_id, reason, channel, address, source, source_ref, occurred_at)
    select distinct on (e.contact_id, e.event_type, e.channel)
      e.brand_id, e.contact_id, e.event_type, e.channel,
      case when e.event_type = 'bounce' then case e.channel when 'email' then c.email else c.phone_e164 end end,
      'history', e.event_id, e.occurred_at
    from public.engagement_events e
    join public.contacts c on c.brand_id = e.brand_id and c.id = e.contact_id
    where e.brand_id = p_brand_id
      and (p_run_id is null or e.import_run_id = p_run_id)
      and e.event_type in ('unsubscribe', 'complaint', 'bounce')
    order by e.contact_id, e.event_type, e.channel, e.occurred_at
    on conflict do nothing
    returning 1
  )
  select count(*)::int from ins
$$;

select private.suppressions_from_history(id, null) from public.brands;

-- keep suppressions in step with future event imports
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

  if v_run.kind = 'events' then
    perform private.suppressions_from_history(v_run.brand_id, v_run.id);
  end if;

  update public.import_runs
    set status = 'completed', finished_at = now(), last_activity_at = now()
    where id = v_run.id
    returning * into v_run;
  return v_run;
end
$$;

-- ---------------------------------------------------------------------------
-- the definition
-- ---------------------------------------------------------------------------
create or replace view public.contact_reachability
with (security_invoker = true) as
select
  c.brand_id,
  c.id as contact_id,
  c.deleted_at is not null                                   as is_deleted,
  c.status = 'active'                                        as status_ok,
  coalesce(c.consent_marketing, false)                       as consent_ok,
  coalesce(c.suppressed_until > now(), false)                as suppressed_by_date,
  exists (select 1 from public.suppressions s
          where s.brand_id = c.brand_id and s.contact_id = c.id
            and s.reason in ('unsubscribe', 'complaint'))    as opted_out,
  c.email is not null and not exists (
    select 1 from public.suppressions s
    where s.brand_id = c.brand_id and s.contact_id = c.id and s.reason = 'bounce'
      and s.channel = 'email' and s.address = c.email)       as email_ok,
  c.phone_e164 is not null and not exists (
    select 1 from public.suppressions s
    where s.brand_id = c.brand_id and s.contact_id = c.id and s.reason = 'bounce'
      and s.channel = 'sms' and s.address = c.phone_e164)    as sms_ok
from public.contacts c;

-- ---------------------------------------------------------------------------
-- dashboard summary (SECURITY INVOKER: RLS scopes everything to the caller)
-- ---------------------------------------------------------------------------
create or replace function public.dashboard_summary(p_brand_id uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  with r as (
    select *,
      (not is_deleted and status_ok and consent_ok and not suppressed_by_date and not opted_out) as eligible
    from public.contact_reachability
    where brand_id = p_brand_id
  )
  select jsonb_build_object(
    'contacts_in_database',     count(*),
    'deleted',                  count(*) filter (where is_deleted),
    'total_customers',          count(*) filter (where not is_deleted),
    -- waterfall: each contact is counted once, at the first rule it fails
    'excluded_status',          count(*) filter (where not is_deleted and not status_ok),
    'excluded_no_consent',      count(*) filter (where not is_deleted and status_ok and not consent_ok),
    'excluded_suppressed',      count(*) filter (where not is_deleted and status_ok and consent_ok and suppressed_by_date),
    'excluded_opted_out',       count(*) filter (where not is_deleted and status_ok and consent_ok and not suppressed_by_date and opted_out),
    'excluded_no_address',      count(*) filter (where eligible and not email_ok and not sms_ok),
    'contactable_any',          count(*) filter (where eligible and (email_ok or sms_ok)),
    'contactable_email',        count(*) filter (where eligible and email_ok),
    'contactable_sms',          count(*) filter (where eligible and sms_ok),
    'computed_at',              now()
  )
  from r
$$;

-- Signups per calendar day in the brand's timezone, for the 30 days ending today.
create or replace function public.signups_per_day(p_brand_id uuid, p_days int default 30)
returns jsonb language sql stable security invoker set search_path = '' as $$
  with b as (
    select timezone, (now() at time zone timezone)::date as today
    from public.brands where id = p_brand_id
  ),
  days as (
    select d::date as day
    from b, generate_series(b.today - (least(greatest(p_days, 1), 366) - 1), b.today, interval '1 day') d
  ),
  counts as (
    select (c.signup_at at time zone b.timezone)::date as day, count(*) as n
    from public.contacts c, b
    where c.brand_id = p_brand_id
      and c.signup_at >= ((b.today - (least(greatest(p_days, 1), 366) - 1))::timestamp at time zone b.timezone)
    group by 1
  )
  select jsonb_build_object(
    'timezone', (select timezone from b),
    'from', (select min(day) from days),
    'to', (select max(day) from days),
    'days', (select jsonb_agg(jsonb_build_object('day', d.day, 'signups', coalesce(k.n, 0)) order by d.day)
             from days d left join counts k using (day)),
    'total_in_window', (select coalesce(sum(n), 0) from counts where day <= (select today from b)),
    'latest_signup_at', (select max(signup_at) from public.contacts where brand_id = p_brand_id),
    'contacts_without_signup_date', (select count(*) from public.contacts where brand_id = p_brand_id and signup_at is null)
  )
$$;

-- Per-campaign performance: the export's reported numbers next to what the
-- event log shows, counted as UNIQUE CONTACTS per event type. Events dated
-- before the campaign's send time are excluded and counted separately.
create or replace function public.campaign_performance(p_brand_id uuid, p_campaign_id uuid default null)
returns table (
  campaign_id uuid, external_id text, name text, channel text, sent_at timestamptz, spend numeric,
  parent_campaign_ref text,
  reported_sent int, reported_delivered int, reported_bounced int, reported_opens int, reported_clicks int,
  measured_openers bigint, measured_clickers bigint, measured_bounced bigint, measured_complained bigint,
  measured_unsubscribed bigint, events_total bigint, events_before_send bigint, events_other_channel bigint,
  legacy_batches bigint, legacy_recipients bigint
)
language sql stable security invoker set search_path = '' as $$
  select
    k.id, k.external_id, k.name, k.channel, k.sent_at, k.spend, k.parent_campaign_ref,
    k.reported_sent, k.reported_delivered, k.reported_bounced, k.reported_opens, k.reported_clicks,
    coalesce(e.openers, 0), coalesce(e.clickers, 0), coalesce(e.bounced, 0), coalesce(e.complained, 0),
    coalesce(e.unsubscribed, 0), coalesce(e.total, 0), coalesce(e.before_send, 0), coalesce(e.other_channel, 0),
    coalesce(l.batches, 0), coalesce(l.recipients, 0)
  from public.campaigns k
  left join lateral (
    select
      count(distinct ev.contact_id) filter (where ev.event_type = 'open' and counted)        as openers,
      count(distinct ev.contact_id) filter (where ev.event_type = 'click' and counted)       as clickers,
      count(distinct ev.contact_id) filter (where ev.event_type = 'bounce' and counted)      as bounced,
      count(distinct ev.contact_id) filter (where ev.event_type = 'complaint' and counted)   as complained,
      count(distinct ev.contact_id) filter (where ev.event_type = 'unsubscribe' and counted) as unsubscribed,
      count(*)                                                                               as total,
      count(*) filter (where not counted)                                                    as before_send,
      count(*) filter (where ev.channel <> k.channel)                                        as other_channel
    from (
      select x.*, (k.sent_at is null or x.occurred_at >= k.sent_at) as counted
      from public.engagement_events x
      where x.brand_id = k.brand_id and x.campaign_id = k.id
    ) ev
  ) e on true
  left join lateral (
    select count(*) as batches, sum(s.recipient_count) as recipients
    from public.legacy_sends s where s.brand_id = k.brand_id and s.campaign_id = k.id
  ) l on true
  where k.brand_id = p_brand_id
    and (p_campaign_id is null or k.id = p_campaign_id)
  order by k.sent_at desc nulls last, k.external_id
$$;

-- Contacts list: server-side search, reachability filter, keyset pagination.
create or replace function public.list_contacts(
  p_brand_id uuid,
  p_search   text default null,
  p_filter   text default 'all',        -- all | contactable | not_contactable | deleted
  p_after    text default null,         -- external_id cursor
  p_limit    int  default 50
)
returns table (
  id uuid, external_id text, full_name text, email text, phone_e164 text, phone_raw text, country text, city text,
  signup_at timestamptz, status text, consent_marketing boolean, deleted_at timestamptz, suppressed_until timestamptz,
  contactable_email boolean, contactable_sms boolean, not_contactable_reason text
)
language plpgsql stable security invoker set search_path = '' as $$
declare
  v_search text := nullif(btrim(p_search), '');
begin
  if p_filter not in ('all', 'contactable', 'not_contactable', 'deleted') then
    raise exception 'invalid filter' using errcode = '22023';
  end if;
  if length(v_search) > 100 then
    raise exception 'search too long' using errcode = '22023';
  end if;
  return query
  with base as (
    select c.*, r.is_deleted, r.status_ok, r.consent_ok, r.suppressed_by_date, r.opted_out, r.email_ok, r.sms_ok,
      (not r.is_deleted and r.status_ok and r.consent_ok and not r.suppressed_by_date and not r.opted_out) as eligible
    from public.contacts c
    join public.contact_reachability r on r.brand_id = c.brand_id and r.contact_id = c.id
    where c.brand_id = p_brand_id
      and (v_search is null
           or (coalesce(c.full_name, '') || ' ' || coalesce(c.email, '') || ' ' || c.external_id)
              ilike '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      and (p_after is null or c.external_id > p_after)
  )
  select b.id, b.external_id, b.full_name, b.email, b.phone_e164, b.phone_raw, b.country::text, b.city,
    b.signup_at, b.status, b.consent_marketing, b.deleted_at, b.suppressed_until,
    b.eligible and b.email_ok, b.eligible and b.sms_ok,
    case
      when b.is_deleted then 'Deleted'
      when not b.status_ok then 'Status: ' || b.status
      when not b.consent_ok then case when b.consent_marketing is null then 'No consent recorded' else 'Consent not given' end
      when b.suppressed_by_date then 'Suppressed until ' || to_char(b.suppressed_until, 'YYYY-MM-DD')
      when b.opted_out then 'Unsubscribed or complained'
      when not b.email_ok and not b.sms_ok then 'No valid email or phone'
    end
  from base b
  where case p_filter
          when 'contactable' then b.eligible and (b.email_ok or b.sms_ok)
          when 'not_contactable' then not (b.eligible and (b.email_ok or b.sms_ok)) and not b.is_deleted
          when 'deleted' then b.is_deleted
          else true
        end
  order by b.external_id
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
end
$$;

revoke execute on function public.dashboard_summary(uuid), public.signups_per_day(uuid, int),
  public.campaign_performance(uuid, uuid), public.list_contacts(uuid, text, text, text, int) from public, anon;
grant execute on function public.dashboard_summary(uuid), public.signups_per_day(uuid, int),
  public.campaign_performance(uuid, uuid), public.list_contacts(uuid, text, text, text, int) to authenticated;
grant select on public.contact_reachability to authenticated;
revoke all on public.contact_reachability from anon;
revoke execute on function private.suppressions_from_history(uuid, uuid) from public, anon, authenticated;

-- ============================================================================
-- 20260913000009_metrics_performance.sql
-- ============================================================================
-- Same definitions as 0008, restructured so the big brand (82k contacts,
-- 300k events) answers well inside PostgREST's 8s statement timeout:
--   * reachability joins suppressions aggregated once per contact instead of
--     three correlated EXISTS lookups per contact
--   * campaign performance is one grouped pass over the brand's events instead
--     of a per-campaign lateral scan
--   * RPCs are plpgsql so each call is planned with the actual brand id
--     (SQL functions called with parameters fell back to a slow generic plan)

create or replace view public.contact_reachability
with (security_invoker = true) as
select
  c.brand_id,
  c.id as contact_id,
  c.deleted_at is not null                                          as is_deleted,
  c.status = 'active'                                               as status_ok,
  coalesce(c.consent_marketing, false)                              as consent_ok,
  coalesce(c.suppressed_until > now(), false)                       as suppressed_by_date,
  coalesce(s.opted_out, false)                                      as opted_out,
  c.email is not null and not (c.email = any (coalesce(s.bounced_email, '{}')))        as email_ok,
  c.phone_e164 is not null and not (c.phone_e164 = any (coalesce(s.bounced_sms, '{}'))) as sms_ok
from public.contacts c
left join (
  select brand_id, contact_id,
    bool_or(reason in ('unsubscribe', 'complaint'))                         as opted_out,
    array_agg(address) filter (where reason = 'bounce' and channel = 'email') as bounced_email,
    array_agg(address) filter (where reason = 'bounce' and channel = 'sms')   as bounced_sms
  from public.suppressions
  group by brand_id, contact_id
) s on s.brand_id = c.brand_id and s.contact_id = c.id;

create or replace function public.dashboard_summary(p_brand_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v jsonb;
begin
  with r as (
    select *,
      (not is_deleted and status_ok and consent_ok and not suppressed_by_date and not opted_out) as eligible
    from public.contact_reachability
    where brand_id = p_brand_id
  )
  select jsonb_build_object(
    'contacts_in_database',     count(*),
    'deleted',                  count(*) filter (where is_deleted),
    'total_customers',          count(*) filter (where not is_deleted),
    'excluded_status',          count(*) filter (where not is_deleted and not status_ok),
    'excluded_no_consent',      count(*) filter (where not is_deleted and status_ok and not consent_ok),
    'excluded_suppressed',      count(*) filter (where not is_deleted and status_ok and consent_ok and suppressed_by_date),
    'excluded_opted_out',       count(*) filter (where not is_deleted and status_ok and consent_ok and not suppressed_by_date and opted_out),
    'excluded_no_address',      count(*) filter (where eligible and not email_ok and not sms_ok),
    'contactable_any',          count(*) filter (where eligible and (email_ok or sms_ok)),
    'contactable_email',        count(*) filter (where eligible and email_ok),
    'contactable_sms',          count(*) filter (where eligible and sms_ok),
    'computed_at',              now()
  ) into v
  from r;
  return v;
end
$$;

create or replace function public.signups_per_day(p_brand_id uuid, p_days int default 30)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v_tz    text;
  v_today date;
  v_days  int := least(greatest(coalesce(p_days, 30), 1), 366);
  v_from  date;
  v jsonb;
begin
  select timezone into v_tz from public.brands where id = p_brand_id;
  if v_tz is null then
    return null;   -- not a brand the caller belongs to
  end if;
  v_today := (now() at time zone v_tz)::date;
  v_from := v_today - (v_days - 1);

  with counts as (
    select (c.signup_at at time zone v_tz)::date as day, count(*) as n
    from public.contacts c
    where c.brand_id = p_brand_id
      and c.signup_at >= (v_from::timestamp at time zone v_tz)
      and c.signup_at <  ((v_today + 1)::timestamp at time zone v_tz)
    group by 1
  )
  select jsonb_build_object(
    'timezone', v_tz,
    'from', v_from,
    'to', v_today,
    'days', (select jsonb_agg(jsonb_build_object('day', d::date, 'signups', coalesce(k.n, 0)) order by d)
             from generate_series(v_from, v_today, interval '1 day') d
             left join counts k on k.day = d::date),
    'total_in_window', (select coalesce(sum(n), 0) from counts),
    'latest_signup_at', (select max(signup_at) from public.contacts where brand_id = p_brand_id),
    'contacts_without_signup_date', (select count(*) from public.contacts where brand_id = p_brand_id and signup_at is null)
  ) into v;
  return v;
end
$$;

drop function public.campaign_performance(uuid, uuid);
create or replace function public.campaign_performance(p_brand_id uuid, p_campaign_id uuid default null)
returns table (
  campaign_id uuid, external_id text, name text, channel text, sent_at timestamptz, spend numeric,
  parent_campaign_ref text,
  reported_sent int, reported_delivered int, reported_bounced int, reported_opens int, reported_clicks int,
  measured_openers bigint, measured_clickers bigint, measured_bounced bigint, measured_complained bigint,
  measured_unsubscribed bigint, events_total bigint, events_before_send bigint, events_other_channel bigint,
  legacy_batches bigint, legacy_recipients bigint
)
language plpgsql stable security invoker set search_path = '' as $$
begin
  return query
  with ev as (
    select e.campaign_id, e.event_type, e.contact_id, e.channel <> k.channel as other_channel,
           (k.sent_at is null or e.occurred_at >= k.sent_at) as counted
    from public.engagement_events e
    join public.campaigns k on k.brand_id = e.brand_id and k.id = e.campaign_id
    where e.brand_id = p_brand_id
      and (p_campaign_id is null or e.campaign_id = p_campaign_id)
  ),
  totals as (
    select ev.campaign_id, count(*) as total,
      count(*) filter (where not ev.counted) as before_send,
      count(*) filter (where ev.other_channel) as other_channel
    from ev group by ev.campaign_id
  ),
  uniq as (
    select distinct ev.campaign_id, ev.event_type, ev.contact_id from ev where ev.counted
  ),
  people as (
    select u.campaign_id,
      count(*) filter (where u.event_type = 'open')        as openers,
      count(*) filter (where u.event_type = 'click')       as clickers,
      count(*) filter (where u.event_type = 'bounce')      as bounced,
      count(*) filter (where u.event_type = 'complaint')   as complained,
      count(*) filter (where u.event_type = 'unsubscribe') as unsubscribed
    from uniq u group by u.campaign_id
  ),
  legacy as (
    select s.campaign_id, count(*) as batches, sum(s.recipient_count) as recipients
    from public.legacy_sends s where s.brand_id = p_brand_id group by s.campaign_id
  )
  select
    k.id, k.external_id, k.name, k.channel, k.sent_at, k.spend, k.parent_campaign_ref,
    k.reported_sent, k.reported_delivered, k.reported_bounced, k.reported_opens, k.reported_clicks,
    coalesce(p.openers, 0), coalesce(p.clickers, 0), coalesce(p.bounced, 0), coalesce(p.complained, 0),
    coalesce(p.unsubscribed, 0), coalesce(t.total, 0), coalesce(t.before_send, 0), coalesce(t.other_channel, 0),
    coalesce(l.batches, 0), coalesce(l.recipients, 0)::bigint
  from public.campaigns k
  left join totals t on t.campaign_id = k.id
  left join people p on p.campaign_id = k.id
  left join legacy l on l.campaign_id = k.id
  where k.brand_id = p_brand_id
    and (p_campaign_id is null or k.id = p_campaign_id)
  order by k.sent_at desc nulls last, k.external_id;
end
$$;

revoke execute on function public.campaign_performance(uuid, uuid) from public, anon;
grant execute on function public.campaign_performance(uuid, uuid) to authenticated;

-- ============================================================================
-- 20260913000010_precomputed_metrics.sql
-- ============================================================================
-- Precompute the two expensive parts of the metrics so a cold database still
-- answers inside the 8s API timeout for the big brand. Both are maintained on
-- WRITE (trigger / import finish), never on a timer, so they cannot drift:
--
--   contact_suppression_flags  one row per contact that has any suppression,
--                              kept current by a trigger on suppressions
--   campaign_event_stats       per-campaign unique-contact counts, rebuilt for
--                              a brand whenever its events or campaigns import

-- ---------------------------------------------------------------------------
-- contact_suppression_flags
-- ---------------------------------------------------------------------------
create table public.contact_suppression_flags (
  brand_id       uuid not null,
  contact_id     uuid not null,
  opted_out      boolean not null default false,
  bounced_email  text[] not null default '{}',
  bounced_sms    text[] not null default '{}',
  updated_at     timestamptz not null default now(),
  primary key (brand_id, contact_id),
  foreign key (brand_id, contact_id) references public.contacts (brand_id, id)
);
alter table public.contact_suppression_flags enable row level security;
alter table public.contact_suppression_flags force row level security;
create policy contact_suppression_flags_select_own_brand on public.contact_suppression_flags
  for select to authenticated using (brand_id in (select private.current_brand_ids()));
revoke all on public.contact_suppression_flags from anon;
revoke insert, update, delete, truncate on public.contact_suppression_flags from authenticated;
grant select on public.contact_suppression_flags to authenticated;

create or replace function private.on_suppression_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.contact_suppression_flags as f (brand_id, contact_id, opted_out, bounced_email, bounced_sms)
  values (
    new.brand_id, new.contact_id,
    new.reason in ('unsubscribe', 'complaint'),
    case when new.reason = 'bounce' and new.channel = 'email' and new.address is not null then array[new.address] else '{}' end,
    case when new.reason = 'bounce' and new.channel = 'sms' and new.address is not null then array[new.address] else '{}' end)
  on conflict (brand_id, contact_id) do update set
    opted_out = f.opted_out or excluded.opted_out,
    bounced_email = array(select distinct unnest(f.bounced_email || excluded.bounced_email)),
    bounced_sms = array(select distinct unnest(f.bounced_sms || excluded.bounced_sms)),
    updated_at = now();
  return null;
end
$$;

create trigger suppressions_maintain_flags
  after insert on public.suppressions
  for each row execute function private.on_suppression_insert();

insert into public.contact_suppression_flags (brand_id, contact_id, opted_out, bounced_email, bounced_sms)
select brand_id, contact_id,
  bool_or(reason in ('unsubscribe', 'complaint')),
  coalesce(array_agg(distinct address) filter (where reason = 'bounce' and channel = 'email' and address is not null), '{}'),
  coalesce(array_agg(distinct address) filter (where reason = 'bounce' and channel = 'sms' and address is not null), '{}')
from public.suppressions
group by brand_id, contact_id;

create or replace view public.contact_reachability
with (security_invoker = true) as
select
  c.brand_id,
  c.id as contact_id,
  c.deleted_at is not null                                   as is_deleted,
  c.status = 'active'                                        as status_ok,
  coalesce(c.consent_marketing, false)                       as consent_ok,
  coalesce(c.suppressed_until > now(), false)                as suppressed_by_date,
  coalesce(f.opted_out, false)                               as opted_out,
  c.email is not null and not (c.email = any (coalesce(f.bounced_email, '{}')))        as email_ok,
  c.phone_e164 is not null and not (c.phone_e164 = any (coalesce(f.bounced_sms, '{}'))) as sms_ok
from public.contacts c
left join public.contact_suppression_flags f on f.brand_id = c.brand_id and f.contact_id = c.id;

-- ---------------------------------------------------------------------------
-- campaign_event_stats
-- ---------------------------------------------------------------------------
create table public.campaign_event_stats (
  brand_id               uuid not null,
  campaign_id            uuid not null,
  measured_openers       bigint not null,
  measured_clickers      bigint not null,
  measured_bounced       bigint not null,
  measured_complained    bigint not null,
  measured_unsubscribed  bigint not null,
  events_total           bigint not null,
  events_before_send     bigint not null,
  events_other_channel   bigint not null,
  refreshed_at           timestamptz not null default now(),
  primary key (brand_id, campaign_id),
  foreign key (brand_id, campaign_id) references public.campaigns (brand_id, id) on delete cascade
);
alter table public.campaign_event_stats enable row level security;
alter table public.campaign_event_stats force row level security;
create policy campaign_event_stats_select_own_brand on public.campaign_event_stats
  for select to authenticated using (brand_id in (select private.current_brand_ids()));
revoke all on public.campaign_event_stats from anon;
revoke insert, update, delete, truncate on public.campaign_event_stats from authenticated;
grant select on public.campaign_event_stats to authenticated;

-- Counting rules (shown on screen next to the numbers):
--   * people, not events: a contact who opened 3 times is 1 opener
--   * events dated before the campaign's send time are not counted
create or replace function private.refresh_campaign_event_stats(p_brand_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.campaign_event_stats where brand_id = p_brand_id;
  insert into public.campaign_event_stats (brand_id, campaign_id, measured_openers, measured_clickers, measured_bounced,
    measured_complained, measured_unsubscribed, events_total, events_before_send, events_other_channel)
  with ev as (
    select e.campaign_id, e.event_type, e.contact_id, e.channel <> k.channel as other_channel,
           (k.sent_at is null or e.occurred_at >= k.sent_at) as counted
    from public.engagement_events e
    join public.campaigns k on k.brand_id = e.brand_id and k.id = e.campaign_id
    where e.brand_id = p_brand_id
  ),
  totals as (
    select campaign_id, count(*) as total,
      count(*) filter (where not counted) as before_send,
      count(*) filter (where other_channel) as other_channel
    from ev group by campaign_id
  ),
  people as (
    select campaign_id,
      count(*) filter (where event_type = 'open')        as openers,
      count(*) filter (where event_type = 'click')       as clickers,
      count(*) filter (where event_type = 'bounce')      as bounced,
      count(*) filter (where event_type = 'complaint')   as complained,
      count(*) filter (where event_type = 'unsubscribe') as unsubscribed
    from (select distinct campaign_id, event_type, contact_id from ev where counted) u
    group by campaign_id
  )
  select p_brand_id, t.campaign_id, coalesce(p.openers, 0), coalesce(p.clickers, 0), coalesce(p.bounced, 0),
    coalesce(p.complained, 0), coalesce(p.unsubscribed, 0), t.total, t.before_send, t.other_channel
  from totals t left join people p using (campaign_id);
end
$$;

select private.refresh_campaign_event_stats(id) from public.brands;

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

  if v_run.kind = 'events' then
    perform private.suppressions_from_history(v_run.brand_id, v_run.id);
  end if;
  if v_run.kind in ('events', 'campaigns') then
    perform private.refresh_campaign_event_stats(v_run.brand_id);   -- send times or events changed
  end if;

  update public.import_runs
    set status = 'completed', finished_at = now(), last_activity_at = now()
    where id = v_run.id
    returning * into v_run;
  return v_run;
end
$$;

create or replace function public.campaign_performance(p_brand_id uuid, p_campaign_id uuid default null)
returns table (
  campaign_id uuid, external_id text, name text, channel text, sent_at timestamptz, spend numeric,
  parent_campaign_ref text,
  reported_sent int, reported_delivered int, reported_bounced int, reported_opens int, reported_clicks int,
  measured_openers bigint, measured_clickers bigint, measured_bounced bigint, measured_complained bigint,
  measured_unsubscribed bigint, events_total bigint, events_before_send bigint, events_other_channel bigint,
  legacy_batches bigint, legacy_recipients bigint
)
language plpgsql stable security invoker set search_path = '' as $$
begin
  return query
  select
    k.id, k.external_id, k.name, k.channel, k.sent_at, k.spend, k.parent_campaign_ref,
    k.reported_sent, k.reported_delivered, k.reported_bounced, k.reported_opens, k.reported_clicks,
    coalesce(s.measured_openers, 0), coalesce(s.measured_clickers, 0), coalesce(s.measured_bounced, 0),
    coalesce(s.measured_complained, 0), coalesce(s.measured_unsubscribed, 0), coalesce(s.events_total, 0),
    coalesce(s.events_before_send, 0), coalesce(s.events_other_channel, 0),
    coalesce(l.batches, 0), coalesce(l.recipients, 0)::bigint
  from public.campaigns k
  left join public.campaign_event_stats s on s.brand_id = k.brand_id and s.campaign_id = k.id
  left join lateral (
    select count(*) as batches, sum(ls.recipient_count) as recipients
    from public.legacy_sends ls where ls.brand_id = k.brand_id and ls.campaign_id = k.id
  ) l on true
  where k.brand_id = p_brand_id
    and (p_campaign_id is null or k.id = p_campaign_id)
  order by k.sent_at desc nulls last, k.external_id;
end
$$;

revoke execute on function private.on_suppression_insert(), private.refresh_campaign_event_stats(uuid) from public, anon, authenticated;

-- ============================================================================
-- 20260913000011_sends.sql
-- ============================================================================
-- Sending a campaign.
--
--   prepare_send(campaign)                  owner: freezes the exact audience, returns count + hash
--   approve_send(send, count, hash)         owner: the count on screen is what gets approved;
--                                           double-clicks / two sessions get the same send back
--   [edge function dispatch-send]           posts frozen chunks with Idempotency-Key = send:chunk
--   [edge function sync-provider-events]    pulls delivery reports; ingest is idempotent,
--                                           order-independent, and never trusts ids it didn't issue
--
-- Everything that happened is recorded in: sends, send_chunks, send_recipients, provider_events.
--
-- Provider behaviour verified by probing (not what its docs claim):
--   * same Idempotency-Key + same body  -> same batch, not re-sent
--   * same key + DIFFERENT body          -> silently returns the ORIGINAL batch (new recipients dropped)
--     => a chunk's recipient list is frozen before its first attempt and never changes
--   * empty or malformed requests are "accepted" -> all validation happens here
--   * events arrive late, duplicated, out of order, and include forged recipients / brand codes

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- sends
-- ---------------------------------------------------------------------------
create table public.sends (
  id                   uuid primary key default gen_random_uuid(),
  brand_id             uuid not null references public.brands(id),
  campaign_id          uuid not null,
  channel              text not null check (channel in ('email', 'sms')),
  status               text not null default 'draft'
                       check (status in ('draft', 'approved', 'dispatching', 'completed', 'partially_failed', 'failed', 'cancelled', 'expired')),
  recipient_count      int not null check (recipient_count >= 0),
  audience_hash        text not null check (audience_hash ~ '^[0-9a-f]{64}$'),
  chunk_size           int not null check (chunk_size between 1 and 5000),
  chunk_count          int not null check (chunk_count >= 0),
  prepared_by          uuid not null,
  prepared_by_email    text not null,
  prepared_at          timestamptz not null default now(),
  expires_at           timestamptz not null,
  approved_by          uuid,
  approved_by_email    text,
  approved_at          timestamptz,
  approved_count       int,
  dispatch_started_at  timestamptz,
  completed_at         timestamptz,
  last_error           text check (length(last_error) <= 1000),
  unique (brand_id, id),
  foreign key (brand_id, campaign_id) references public.campaigns (brand_id, id),
  check ((status in ('draft', 'cancelled', 'expired')) or (approved_at is not null and approved_by is not null and approved_count is not null))
);
-- at most one approved-but-unfinished send per campaign
create unique index sends_one_live_per_campaign on public.sends (brand_id, campaign_id)
  where status in ('approved', 'dispatching');
create index on public.sends (brand_id, campaign_id, prepared_at desc);
create index on public.sends (status) where status in ('approved', 'dispatching');

-- An approval is history: once recorded, who approved what, when, and for how
-- many people can never be edited.
create or replace function private.protect_approval()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.approved_at is not null and (
       new.approved_at is distinct from old.approved_at or new.approved_by is distinct from old.approved_by
    or new.approved_by_email is distinct from old.approved_by_email or new.approved_count is distinct from old.approved_count
    or new.recipient_count is distinct from old.recipient_count or new.audience_hash is distinct from old.audience_hash
    or new.campaign_id is distinct from old.campaign_id or new.channel is distinct from old.channel) then
    raise exception 'an approved send cannot be altered' using errcode = '55000';
  end if;
  if old.status in ('completed', 'partially_failed', 'failed', 'cancelled', 'expired') and new.status <> old.status then
    raise exception 'a finished send cannot change status' using errcode = '55000';
  end if;
  return new;
end
$$;
create trigger sends_protect_approval before update on public.sends
  for each row execute function private.protect_approval();
create or replace function private.forbid_delete()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'send history cannot be deleted' using errcode = '55000';
end
$$;
create trigger sends_no_delete before delete on public.sends
  for each row execute function private.forbid_delete();

-- ---------------------------------------------------------------------------
-- send_chunks: the unit of dispatch
-- ---------------------------------------------------------------------------
create table public.send_chunks (
  brand_id             uuid not null,
  send_id              uuid not null,
  chunk_no             int not null check (chunk_no >= 0),
  idempotency_key      text not null unique,
  status               text not null default 'pending' check (status in ('pending', 'in_flight', 'dispatched', 'failed')),
  frozen_at            timestamptz,           -- recipient list fixed at first attempt
  recipient_count      int,                   -- recipients actually in the payload
  attempts             int not null default 0,
  lease_until          timestamptz,
  next_attempt_at      timestamptz not null default now(),
  provider_batch_id    text unique,
  accepted_count       int,
  rejected_count       int,
  dispatched_at        timestamptz,
  last_error           text check (length(last_error) <= 1000),
  events_cursor        text,
  events_complete      boolean not null default false,
  events_synced_at     timestamptz,
  full_resync_at       timestamptz,
  primary key (send_id, chunk_no),
  foreign key (brand_id, send_id) references public.sends (brand_id, id)
);
create index on public.send_chunks (status, next_attempt_at);
create index on public.send_chunks (events_synced_at) where provider_batch_id is not null;

-- ---------------------------------------------------------------------------
-- send_recipients: the frozen audience and each person's delivery state
-- ---------------------------------------------------------------------------
create table public.send_recipients (
  id                  uuid primary key default gen_random_uuid(),   -- the id given to the provider
  brand_id            uuid not null,
  send_id             uuid not null,
  contact_id          uuid not null,
  address             text not null,           -- email or E.164 phone at approval time
  seq                 int not null,
  chunk_no            int not null,
  dispatch_status     text not null default 'pending'
                      check (dispatch_status in ('pending', 'skipped', 'dispatched', 'rejected', 'failed')),
  skip_reason         text,
  -- delivery facts: set once from provider reports, never unset (order-independent)
  delivered_at        timestamptz,
  bounced_at          timestamptz,
  opened_at           timestamptz,
  clicked_at          timestamptz,
  complained_at       timestamptz,
  unsubscribed_at     timestamptz,
  last_event_at       timestamptz,
  unique (send_id, contact_id),
  unique (send_id, seq),
  unique (brand_id, id),
  foreign key (brand_id, send_id) references public.sends (brand_id, id),
  foreign key (brand_id, contact_id) references public.contacts (brand_id, id)
);
create index on public.send_recipients (send_id, chunk_no, seq);

-- ---------------------------------------------------------------------------
-- provider_events: every report as received, applied or quarantined
-- ---------------------------------------------------------------------------
create table public.provider_events (
  id                   bigint generated always as identity primary key,
  brand_id             uuid not null,           -- from OUR send, never from the report
  send_id              uuid not null,
  chunk_no             int not null,
  provider_batch_id    text not null,
  provider_event_id    text not null,
  recipient_ref        text,
  send_recipient_id    uuid,
  event_type           text,
  occurred_at          timestamptz,
  outcome              text not null check (outcome in ('applied', 'quarantined')),
  quarantine_reason    text,
  raw                  jsonb not null,
  received_at          timestamptz not null default now(),
  unique (provider_batch_id, provider_event_id),
  foreign key (brand_id, send_id) references public.sends (brand_id, id)
);
create index on public.provider_events (brand_id, send_id, outcome);

-- ---------------------------------------------------------------------------
-- RLS: read-only to the brand's members; all writes through RPCs / service role
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['sends', 'send_chunks', 'send_recipients', 'provider_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (brand_id in (select private.current_brand_ids()))',
      t || '_select_own_brand', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- prepare_send
-- ---------------------------------------------------------------------------
create or replace function public.prepare_send(p_campaign_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_campaign  public.campaigns;
  v_send      public.sends;
  v_live      public.sends;
  v_chunk     int := 500;
  v_count     int;
  v_hash      text;
begin
  select * into v_campaign from public.campaigns where id = p_campaign_id;
  perform private.assert_member(v_campaign.brand_id, true);   -- owners only; unknown campaign raises too

  -- serialise prepares/approvals for this campaign
  perform pg_advisory_xact_lock(hashtextextended('send:' || v_campaign.id::text, 0));

  select * into v_live from public.sends
    where brand_id = v_campaign.brand_id and campaign_id = v_campaign.id and status in ('approved', 'dispatching');
  if found then
    return jsonb_build_object('error', 'send_in_progress', 'send_id', v_live.id,
      'message', 'This campaign is already being sent. Wait for it to finish before preparing another send.');
  end if;

  -- older unconfirmed drafts for this campaign can no longer be approved
  update public.sends set status = 'cancelled'
    where brand_id = v_campaign.brand_id and campaign_id = v_campaign.id and status = 'draft';

  insert into public.sends (brand_id, campaign_id, channel, recipient_count, audience_hash, chunk_size, chunk_count,
    prepared_by, prepared_by_email, expires_at)
  values (v_campaign.brand_id, v_campaign.id, v_campaign.channel, 0, repeat('0', 64), v_chunk, 0,
    auth.uid(), private.current_email(), now() + interval '15 minutes')
  returning * into v_send;

  -- the audience: exactly the contacts the dashboard counts as reachable on this channel
  insert into public.send_recipients (brand_id, send_id, contact_id, address, seq, chunk_no)
  select v_send.brand_id, v_send.id, c.id,
    case v_campaign.channel when 'email' then c.email else c.phone_e164 end,
    row_number() over (order by c.external_id)::int,
    ((row_number() over (order by c.external_id) - 1) / v_chunk)::int
  from public.contacts c
  join public.contact_reachability r on r.brand_id = c.brand_id and r.contact_id = c.id
  where c.brand_id = v_campaign.brand_id
    and not r.is_deleted and r.status_ok and r.consent_ok and not r.suppressed_by_date and not r.opted_out
    and case v_campaign.channel when 'email' then r.email_ok else r.sms_ok end;

  select count(*), encode(extensions.digest(coalesce(string_agg(contact_id::text || '=' || address, ',' order by seq), ''), 'sha256'), 'hex')
    into v_count, v_hash
  from public.send_recipients where send_id = v_send.id;

  insert into public.send_chunks (brand_id, send_id, chunk_no, idempotency_key)
  select v_send.brand_id, v_send.id, g, v_send.id::text || ':' || g
  from generate_series(0, ceil(v_count::numeric / v_chunk)::int - 1) g;

  update public.sends
    set recipient_count = v_count, audience_hash = v_hash, chunk_count = ceil(v_count::numeric / v_chunk)::int
    where id = v_send.id
    returning * into v_send;

  return jsonb_build_object(
    'send_id', v_send.id, 'channel', v_send.channel, 'recipient_count', v_send.recipient_count,
    'audience_hash', v_send.audience_hash, 'expires_at', v_send.expires_at, 'chunk_count', v_send.chunk_count);
end
$$;

-- ---------------------------------------------------------------------------
-- approve_send
-- ---------------------------------------------------------------------------
create or replace function public.approve_send(p_send_id uuid, p_expected_count int, p_audience_hash text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_send public.sends;
begin
  select * into v_send from public.sends where id = p_send_id;
  perform private.assert_member(v_send.brand_id, true);
  perform pg_advisory_xact_lock(hashtextextended('send:' || v_send.campaign_id::text, 0));
  select * into v_send from public.sends where id = p_send_id for update;

  -- pressing confirm again (or from a second session) returns the same approval
  if v_send.status in ('approved', 'dispatching', 'completed', 'partially_failed', 'failed') then
    if v_send.approved_count = p_expected_count and v_send.audience_hash = p_audience_hash then
      return jsonb_build_object('send_id', v_send.id, 'status', v_send.status, 'already_approved', true,
        'approved_count', v_send.approved_count, 'approved_by_email', v_send.approved_by_email, 'approved_at', v_send.approved_at);
    end if;
    raise exception 'this send was already approved for a different audience' using errcode = '55000';
  end if;
  if v_send.status <> 'draft' then
    raise exception 'this confirmation is no longer valid (%); prepare the send again', v_send.status using errcode = '55000';
  end if;
  if v_send.expires_at < now() then
    update public.sends set status = 'expired' where id = v_send.id;
    return jsonb_build_object('error', 'expired', 'message', 'This confirmation expired. Prepare the send again to see the current audience.');
  end if;
  if p_expected_count is distinct from v_send.recipient_count or p_audience_hash is distinct from v_send.audience_hash then
    raise exception 'the audience changed since it was shown; prepare the send again' using errcode = '55000';
  end if;
  if v_send.recipient_count = 0 then
    raise exception 'there is nobody to send to' using errcode = '22023';
  end if;
  if exists (select 1 from public.sends s where s.brand_id = v_send.brand_id and s.campaign_id = v_send.campaign_id
             and s.status in ('approved', 'dispatching') and s.id <> v_send.id) then
    raise exception 'another send of this campaign is in progress' using errcode = '55000';
  end if;

  update public.sends set
    status = 'approved', approved_by = auth.uid(), approved_by_email = private.current_email(),
    approved_at = now(), approved_count = recipient_count
  where id = v_send.id
  returning * into v_send;

  return jsonb_build_object('send_id', v_send.id, 'status', v_send.status, 'already_approved', false,
    'approved_count', v_send.approved_count, 'approved_by_email', v_send.approved_by_email, 'approved_at', v_send.approved_at);
end
$$;

create or replace function public.cancel_send(p_send_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_send public.sends;
begin
  select * into v_send from public.sends where id = p_send_id for update;
  perform private.assert_member(v_send.brand_id, true);
  if v_send.status = 'draft' then
    update public.sends set status = 'cancelled' where id = v_send.id;
  end if;
end
$$;

-- Paginated view of a send's frozen recipients (for the confirmation screen).
create or replace function public.send_recipients_page(p_send_id uuid, p_after_seq int default 0, p_limit int default 50)
returns table (seq int, external_id text, full_name text, address text, dispatch_status text, skip_reason text,
  delivered boolean, bounced boolean, opened boolean, unsubscribed boolean)
language plpgsql stable security invoker set search_path = '' as $$
begin
  return query
  select r.seq, c.external_id, c.full_name, r.address, r.dispatch_status, r.skip_reason,
    r.delivered_at is not null, r.bounced_at is not null, r.opened_at is not null, r.unsubscribed_at is not null
  from public.send_recipients r
  join public.contacts c on c.brand_id = r.brand_id and c.id = r.contact_id
  where r.send_id = p_send_id and r.seq > coalesce(p_after_seq, 0)
  order by r.seq
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
end
$$;

-- Delivery picture for a send (counts people, not events).
create or replace function public.send_summary(p_send_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v jsonb;
begin
  select jsonb_build_object(
    'send', to_jsonb(s) - 'audience_hash',
    'campaign_name', k.name, 'campaign_external_id', k.external_id,
    'recipients', (select jsonb_build_object(
        'approved', count(*),
        'pending', count(*) filter (where dispatch_status = 'pending'),
        'skipped', count(*) filter (where dispatch_status = 'skipped'),
        'dispatched', count(*) filter (where dispatch_status = 'dispatched'),
        'rejected', count(*) filter (where dispatch_status = 'rejected'),
        'failed', count(*) filter (where dispatch_status = 'failed'),
        'delivered', count(*) filter (where (delivered_at is not null or opened_at is not null) and bounced_at is null),
        'bounced', count(*) filter (where bounced_at is not null),
        'opened', count(*) filter (where opened_at is not null),
        'clicked', count(*) filter (where clicked_at is not null),
        'complained', count(*) filter (where complained_at is not null),
        'unsubscribed', count(*) filter (where unsubscribed_at is not null),
        'awaiting_report', count(*) filter (where dispatch_status = 'dispatched' and delivered_at is null and bounced_at is null and opened_at is null)
      ) from public.send_recipients r where r.send_id = s.id),
    'skip_reasons', (select coalesce(jsonb_object_agg(skip_reason, n), '{}') from (
        select skip_reason, count(*) n from public.send_recipients r
        where r.send_id = s.id and dispatch_status = 'skipped' group by skip_reason) x),
    'chunks', (select jsonb_build_object(
        'total', count(*),
        'pending', count(*) filter (where status = 'pending'),
        'in_flight', count(*) filter (where status = 'in_flight'),
        'dispatched', count(*) filter (where status = 'dispatched'),
        'failed', count(*) filter (where status = 'failed'),
        'retrying', count(*) filter (where status = 'pending' and attempts > 0),
        'last_error', (select last_error from public.send_chunks c2 where c2.send_id = s.id and c2.last_error is not null order by c2.chunk_no limit 1),
        'events_synced_at', max(events_synced_at),
        'all_reports_complete', coalesce(bool_and(events_complete) filter (where provider_batch_id is not null), false)
      ) from public.send_chunks c where c.send_id = s.id),
    'events', (select jsonb_build_object(
        'applied', count(*) filter (where outcome = 'applied'),
        'quarantined', count(*) filter (where outcome = 'quarantined'),
        'quarantine_reasons', (select coalesce(jsonb_object_agg(quarantine_reason, n), '{}') from (
            select quarantine_reason, count(*) n from public.provider_events pe
            where pe.send_id = s.id and outcome = 'quarantined' group by quarantine_reason) q)
      ) from public.provider_events e where e.send_id = s.id)
  ) into v
  from public.sends s
  join public.campaigns k on k.brand_id = s.brand_id and k.id = s.campaign_id
  where s.id = p_send_id;
  return v;
end
$$;

-- ============================================================================
-- 20260913000012_dispatch_internals.sql
-- ============================================================================
-- Dispatcher and delivery-report internals, used only by the edge functions
-- (service role). Exposed in public so PostgREST can reach them, but every one
-- starts with private.assert_service_role() and EXECUTE is granted to
-- service_role only.

create or replace function private.assert_service_role()
returns void language plpgsql stable set search_path = '' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role', '') <> 'service_role' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
end
$$;

-- Mark a send finished once no chunk is waiting or in flight.
create or replace function private.finalize_send(p_send_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_open int; v_failed int; v_total int;
begin
  select count(*) filter (where status in ('pending', 'in_flight')),
         count(*) filter (where status = 'failed'),
         count(*)
    into v_open, v_failed, v_total
  from public.send_chunks where send_id = p_send_id;
  if v_open > 0 then
    return;
  end if;
  update public.sends set
    status = case when v_failed = 0 then 'completed' when v_failed = v_total then 'failed' else 'partially_failed' end,
    completed_at = now()
  where id = p_send_id and status in ('approved', 'dispatching');
end
$$;

-- ---------------------------------------------------------------------------
-- which sends need dispatching / which batches need report syncing
-- ---------------------------------------------------------------------------
create or replace function public.svc_sends_to_dispatch()
returns setof uuid language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_service_role();
  return query
  select distinct s.id from public.sends s
  join public.send_chunks c on c.send_id = s.id
  where s.status in ('approved', 'dispatching')
    and ((c.status = 'pending' and c.next_attempt_at <= now()) or (c.status = 'in_flight' and c.lease_until < now()));
end
$$;

-- Batches whose reports may still change: not yet complete, or dispatched in
-- the last 3 days (re-read in full periodically, since late reports can land
-- behind the cursor).
create or replace function public.svc_chunks_to_sync(p_limit int default 50)
returns table (send_id uuid, chunk_no int, provider_batch_id text, events_cursor text, full_resync boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_service_role();
  return query
  select c.send_id, c.chunk_no, c.provider_batch_id, c.events_cursor,
    (c.full_resync_at is null or c.full_resync_at < now() - interval '10 minutes')
  from public.send_chunks c
  where c.provider_batch_id is not null
    and (not c.events_complete or c.dispatched_at > now() - interval '3 days')
  order by c.events_synced_at nulls first
  limit least(greatest(coalesce(p_limit, 50), 1), 500);
end
$$;

-- ---------------------------------------------------------------------------
-- claim a chunk
-- ---------------------------------------------------------------------------
create or replace function public.svc_claim_chunk(p_send_id uuid, p_lease_seconds int default 60)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_send     public.sends;
  v_campaign public.campaigns;
  v_brand    public.brands;
  v_chunk    public.send_chunks;
  v_payload  jsonb;
  v_n        int;
begin
  perform private.assert_service_role();

  select * into v_send from public.sends where id = p_send_id for update;
  if not found or v_send.status not in ('approved', 'dispatching') then
    return null;
  end if;

  select * into v_chunk from public.send_chunks c
    where c.send_id = p_send_id
      and ((c.status = 'pending' and c.next_attempt_at <= now()) or (c.status = 'in_flight' and c.lease_until < now()))
    order by c.chunk_no
    for update skip locked
    limit 1;
  if not found then
    perform private.finalize_send(p_send_id);
    return null;
  end if;

  if v_send.status = 'approved' then
    update public.sends set status = 'dispatching', dispatch_started_at = now() where id = v_send.id;
  end if;

  if v_chunk.frozen_at is null then
    -- first attempt: drop anyone who stopped being reachable since approval, with the reason
    update public.send_recipients sr set dispatch_status = 'skipped', skip_reason = x.reason
    from (
      select r.id,
        case
          when rr.is_deleted then 'deleted since approval'
          when not rr.status_ok then 'status changed since approval'
          when not rr.consent_ok then 'consent withdrawn since approval'
          when rr.suppressed_by_date then 'suppressed since approval'
          when rr.opted_out then 'unsubscribed or complained since approval'
          when v_send.channel = 'email' and (not rr.email_ok or c.email is distinct from r.address) then 'email bounced or changed since approval'
          when v_send.channel = 'sms' and (not rr.sms_ok or c.phone_e164 is distinct from r.address) then 'phone bounced or changed since approval'
        end as reason
      from public.send_recipients r
      join public.contacts c on c.brand_id = r.brand_id and c.id = r.contact_id
      join public.contact_reachability rr on rr.brand_id = c.brand_id and rr.contact_id = c.id
      where r.send_id = p_send_id and r.chunk_no = v_chunk.chunk_no and r.dispatch_status = 'pending'
    ) x
    where sr.id = x.id and x.reason is not null;

    select count(*) into v_n from public.send_recipients r
      where r.send_id = p_send_id and r.chunk_no = v_chunk.chunk_no and r.dispatch_status = 'pending';
    update public.send_chunks set frozen_at = now(), recipient_count = v_n
      where send_id = p_send_id and chunk_no = v_chunk.chunk_no;

    if v_n = 0 then
      update public.send_chunks set status = 'dispatched', dispatched_at = now(), accepted_count = 0, rejected_count = 0,
        events_complete = true
        where send_id = p_send_id and chunk_no = v_chunk.chunk_no;
      return jsonb_build_object('send_id', p_send_id, 'chunk_no', v_chunk.chunk_no, 'empty', true);
    end if;
  end if;

  update public.send_chunks set status = 'in_flight', attempts = attempts + 1,
    lease_until = now() + make_interval(secs => least(greatest(coalesce(p_lease_seconds, 60), 10), 600))
    where send_id = p_send_id and chunk_no = v_chunk.chunk_no
    returning * into v_chunk;

  select * into v_campaign from public.campaigns where brand_id = v_send.brand_id and id = v_send.campaign_id;
  select * into v_brand from public.brands where id = v_send.brand_id;

  -- the frozen recipient list, in a stable order: identical on every retry
  select jsonb_agg(
           case v_send.channel
             when 'email' then jsonb_build_object('id', r.id, 'email', r.address)
             else jsonb_build_object('id', r.id, 'phone', r.address)
           end order by r.seq)
    into v_payload
  from public.send_recipients r
  where r.send_id = p_send_id and r.chunk_no = v_chunk.chunk_no
    and (r.dispatch_status = 'pending' or (v_chunk.attempts > 1 and r.dispatch_status in ('pending', 'dispatched', 'rejected')));

  return jsonb_build_object(
    'send_id', p_send_id,
    'chunk_no', v_chunk.chunk_no,
    'attempt', v_chunk.attempts,
    'idempotency_key', v_chunk.idempotency_key,
    'body', jsonb_build_object(
      'campaign', v_campaign.external_id || ' / send ' || v_send.id,
      'brand', v_brand.slug,
      'channel', v_send.channel,
      'recipients', v_payload));
end
$$;

-- ---------------------------------------------------------------------------
-- record the provider's answer
-- ---------------------------------------------------------------------------
create or replace function public.svc_record_chunk_result(
  p_send_id uuid, p_chunk_no int, p_http_status int, p_response jsonb, p_error text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_chunk    public.send_chunks;
  v_batch    text;
  v_accepted text[];
  v_rejected text[];
  v_retry    boolean;
begin
  perform private.assert_service_role();
  select * into v_chunk from public.send_chunks where send_id = p_send_id and chunk_no = p_chunk_no for update;
  if not found or v_chunk.status = 'dispatched' then
    return jsonb_build_object('ignored', true);
  end if;

  v_batch := p_response->>'batch_id';

  if p_http_status between 200 and 299 and v_batch ~ '^[A-Za-z0-9_-]{1,128}$' then
    select coalesce(array_agg(coalesce(x->>'id', x#>>'{}')), '{}') into v_accepted
      from jsonb_array_elements(case when jsonb_typeof(p_response->'accepted') = 'array' then p_response->'accepted' else '[]' end) x;
    select coalesce(array_agg(coalesce(x->>'id', x->>'recipient_id', x#>>'{}')), '{}') into v_rejected
      from jsonb_array_elements(case when jsonb_typeof(p_response->'rejected') = 'array' then p_response->'rejected' else '[]' end) x;

    update public.send_recipients set
      dispatch_status = case
        when id::text = any (v_accepted) then 'dispatched'
        when id::text = any (v_rejected) then 'rejected'
        else 'rejected' end,
      skip_reason = case
        when id::text = any (v_accepted) then null
        when id::text = any (v_rejected) then 'rejected by provider'
        else 'not acknowledged by provider' end
    where send_id = p_send_id and chunk_no = p_chunk_no and dispatch_status in ('pending', 'dispatched', 'rejected');

    update public.send_chunks set
      status = 'dispatched', dispatched_at = now(), lease_until = null,
      provider_batch_id = v_batch,
      accepted_count = (select count(*) from public.send_recipients where send_id = p_send_id and chunk_no = p_chunk_no and dispatch_status = 'dispatched'),
      rejected_count = (select count(*) from public.send_recipients where send_id = p_send_id and chunk_no = p_chunk_no and dispatch_status = 'rejected'),
      last_error = case when v_chunk.provider_batch_id is not null and v_chunk.provider_batch_id <> v_batch
                        then 'provider returned a different batch id on retry' else null end
    where send_id = p_send_id and chunk_no = p_chunk_no;
    perform private.finalize_send(p_send_id);
    return jsonb_build_object('dispatched', true, 'batch_id', v_batch);
  end if;

  -- failure: network errors, timeouts, 429 and 5xx are retried with the same key
  -- and body (safe: the provider dedupes on the key). Client errors are not.
  v_retry := p_http_status is null or p_http_status = 0 or p_http_status = 408 or p_http_status = 429 or p_http_status >= 500
             or (p_http_status between 200 and 299);   -- 2xx without a usable batch id: ask again
  if v_retry and v_chunk.attempts < 10 then
    update public.send_chunks set status = 'pending', lease_until = null,
      next_attempt_at = now() + make_interval(secs => least(5 * power(2, v_chunk.attempts), 600)),
      last_error = left(format('attempt %s: %s', v_chunk.attempts, coalesce(p_error, 'HTTP ' || p_http_status)), 1000)
    where send_id = p_send_id and chunk_no = p_chunk_no;
    return jsonb_build_object('retry', true);
  end if;

  update public.send_chunks set status = 'failed', lease_until = null,
    last_error = left(format('gave up after %s attempts: %s', v_chunk.attempts, coalesce(p_error, 'HTTP ' || p_http_status)), 1000)
  where send_id = p_send_id and chunk_no = p_chunk_no;
  update public.send_recipients set dispatch_status = 'failed', skip_reason = 'provider did not accept the batch'
    where send_id = p_send_id and chunk_no = p_chunk_no and dispatch_status = 'pending';
  perform private.finalize_send(p_send_id);
  return jsonb_build_object('failed', true);
end
$$;

-- ---------------------------------------------------------------------------
-- ingest delivery reports
-- ---------------------------------------------------------------------------
create or replace function public.svc_ingest_provider_events(
  p_send_id uuid, p_chunk_no int, p_events jsonb, p_next_cursor text, p_has_more boolean, p_full_resync boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_send     public.sends;
  v_chunk    public.send_chunks;
  e          jsonb;
  v_eid      text;
  v_type     text;
  v_at       timestamptz;
  v_rid      uuid;
  v_rec      public.send_recipients;
  v_reason   text;
  v_new      boolean;
  v_applied  int := 0;
  v_quar     int := 0;
  v_dupes    int := 0;
begin
  perform private.assert_service_role();
  select * into v_send from public.sends where id = p_send_id;
  select * into v_chunk from public.send_chunks where send_id = p_send_id and chunk_no = p_chunk_no for update;
  if v_chunk.provider_batch_id is null then
    raise exception 'chunk has no provider batch' using errcode = '22023';
  end if;
  if jsonb_typeof(p_events) <> 'array' then
    raise exception 'events must be an array' using errcode = '22023';
  end if;

  for e in select x from jsonb_array_elements(p_events) x loop
    v_reason := null; v_rid := null; v_at := null; v_rec := null;
    if jsonb_typeof(e) <> 'object' then
      v_eid := 'invalid:' || md5(e::text);
      v_reason := 'event is not an object';
    else
      v_eid := nullif(btrim(e->>'event_id'), '');
      if v_eid is null or length(v_eid) > 200 then
        v_eid := 'missing-id:' || md5(e::text);
        v_reason := 'missing or invalid event id';
      end if;
    end if;

    v_type := case lower(btrim(coalesce(e->>'type', e->>'event_type', '')))
      when 'delivered' then 'delivered'
      when 'bounced' then 'bounced' when 'bounce' then 'bounced'
      when 'opened' then 'opened' when 'open' then 'opened'
      when 'clicked' then 'clicked' when 'click' then 'clicked'
      when 'unsubscribed' then 'unsubscribed' when 'unsubscribe' then 'unsubscribed'
      when 'complained' then 'complained' when 'complaint' then 'complained' when 'spam' then 'complained'
    end;

    if v_reason is null and v_type is null then
      v_reason := 'unknown event type';
    end if;

    if v_reason is null then
      begin
        v_at := (e->>'occurred_at')::timestamptz;
      exception when others then
        v_at := null;
      end;
      if v_at is null then
        v_reason := 'missing or invalid timestamp';
      elsif v_at > now() + interval '1 day' then
        v_reason := 'timestamp in the future';
      elsif v_send.approved_at is not null and v_at < v_send.approved_at - interval '1 day' then
        v_reason := 'timestamp before the send was approved';
      end if;
    end if;

    if v_reason is null then
      -- Only ids WE issued, for THIS batch, count. Contact ids, emails and
      -- brand codes in the report are ignored: they are not proof of anything.
      if coalesce(e->>'recipient_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_rid := (e->>'recipient_id')::uuid;
        select * into v_rec from public.send_recipients r
          where r.id = v_rid and r.send_id = p_send_id and r.chunk_no = p_chunk_no;
      end if;
      if v_rec.id is null then
        v_reason := 'recipient is not part of this batch';
      elsif v_rec.dispatch_status <> 'dispatched' then
        v_reason := 'recipient was not dispatched in this batch';
      end if;
    end if;

    insert into public.provider_events (brand_id, send_id, chunk_no, provider_batch_id, provider_event_id, recipient_ref,
      send_recipient_id, event_type, occurred_at, outcome, quarantine_reason, raw)
    values (v_send.brand_id, p_send_id, p_chunk_no, v_chunk.provider_batch_id, v_eid, left(e->>'recipient_id', 200),
      v_rec.id, v_type, v_at, case when v_reason is null then 'applied' else 'quarantined' end, v_reason, e)
    on conflict (provider_batch_id, provider_event_id) do nothing
    returning true into v_new;

    if not coalesce(v_new, false) then
      v_dupes := v_dupes + 1;       -- same report again: already handled
      v_new := null;
      continue;
    end if;
    v_new := null;

    if v_reason is not null then
      v_quar := v_quar + 1;
      continue;
    end if;

    -- facts only ever get set (earliest time wins), so order of arrival doesn't matter
    update public.send_recipients set
      delivered_at    = case when v_type = 'delivered' then least(coalesce(delivered_at, v_at), v_at) else delivered_at end,
      bounced_at      = case when v_type = 'bounced' then least(coalesce(bounced_at, v_at), v_at) else bounced_at end,
      opened_at       = case when v_type = 'opened' then least(coalesce(opened_at, v_at), v_at) else opened_at end,
      clicked_at      = case when v_type = 'clicked' then least(coalesce(clicked_at, v_at), v_at) else clicked_at end,
      complained_at   = case when v_type = 'complained' then least(coalesce(complained_at, v_at), v_at) else complained_at end,
      unsubscribed_at = case when v_type = 'unsubscribed' then least(coalesce(unsubscribed_at, v_at), v_at) else unsubscribed_at end,
      last_event_at   = greatest(coalesce(last_event_at, v_at), v_at)
    where id = v_rec.id;

    if v_type in ('bounced', 'unsubscribed', 'complained') then
      insert into public.suppressions (brand_id, contact_id, reason, channel, address, source, source_ref, occurred_at)
      values (v_send.brand_id, v_rec.contact_id,
        case v_type when 'bounced' then 'bounce' when 'unsubscribed' then 'unsubscribe' else 'complaint' end,
        v_send.channel, case when v_type = 'bounced' then v_rec.address end,
        'provider', v_eid, v_at)
      on conflict do nothing;
    end if;
    v_applied := v_applied + 1;
  end loop;

  update public.send_chunks set
    events_cursor = case when p_full_resync then events_cursor else coalesce(p_next_cursor, events_cursor) end,
    events_complete = (not coalesce(p_has_more, true)) and p_next_cursor is null,
    events_synced_at = now(),
    full_resync_at = case when p_full_resync then now() else full_resync_at end
  where send_id = p_send_id and chunk_no = p_chunk_no;

  return jsonb_build_object('applied', v_applied, 'quarantined', v_quar, 'duplicates', v_dupes);
end
$$;

revoke execute on function public.svc_sends_to_dispatch(), public.svc_chunks_to_sync(int),
  public.svc_claim_chunk(uuid, int), public.svc_record_chunk_result(uuid, int, int, jsonb, text),
  public.svc_ingest_provider_events(uuid, int, jsonb, text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.svc_sends_to_dispatch(), public.svc_chunks_to_sync(int),
  public.svc_claim_chunk(uuid, int), public.svc_record_chunk_result(uuid, int, int, jsonb, text),
  public.svc_ingest_provider_events(uuid, int, jsonb, text, boolean, boolean) to service_role;

revoke execute on function public.prepare_send(uuid), public.approve_send(uuid, int, text), public.cancel_send(uuid),
  public.send_recipients_page(uuid, int, int), public.send_summary(uuid) from public, anon;
grant execute on function public.prepare_send(uuid), public.approve_send(uuid, int, text), public.cancel_send(uuid),
  public.send_recipients_page(uuid, int, int), public.send_summary(uuid) to authenticated;
revoke execute on function private.assert_service_role(), private.finalize_send(uuid),
  private.protect_approval(), private.forbid_delete() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- schedule: every minute, nudge the dispatcher (resumes interrupted sends) and
-- pull delivery reports, whether or not anyone has the app open.
-- The project URL and a shared secret live in Vault (set by scripts/setup-cron.ts),
-- never in this public repo.
-- ---------------------------------------------------------------------------
create or replace function private.invoke_edge_function(p_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cron_secret';
  if v_url is null or v_secret is null then
    return;   -- not configured yet
  end if;
  perform net.http_post(
    url := v_url || '/functions/v1/' || p_name,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body := '{"mode":"sweep"}'::jsonb,
    timeout_milliseconds := 5000);
end
$$;
revoke execute on function private.invoke_edge_function(text) from public, anon, authenticated;

select cron.schedule('dispatch-sweep', '* * * * *', $$select private.invoke_edge_function('dispatch-send')$$);
select cron.schedule('sync-provider-events', '* * * * *', $$select private.invoke_edge_function('sync-provider-events')$$);

-- ============================================================================
-- 20260913000013_campaign_performance_portal_sends.sql
-- ============================================================================
-- Campaign performance now also reflects sends made through the portal, built
-- from provider delivery reports (unique people per outcome).

drop function public.campaign_performance(uuid, uuid);
create or replace function public.campaign_performance(p_brand_id uuid, p_campaign_id uuid default null)
returns table (
  campaign_id uuid, external_id text, name text, channel text, sent_at timestamptz, spend numeric,
  parent_campaign_ref text,
  reported_sent int, reported_delivered int, reported_bounced int, reported_opens int, reported_clicks int,
  measured_openers bigint, measured_clickers bigint, measured_bounced bigint, measured_complained bigint,
  measured_unsubscribed bigint, events_total bigint, events_before_send bigint, events_other_channel bigint,
  legacy_batches bigint, legacy_recipients bigint,
  portal_sends bigint, portal_approved bigint, portal_dispatched bigint, portal_delivered bigint, portal_bounced bigint,
  portal_opened bigint, portal_unsubscribed bigint, portal_last_send_at timestamptz
)
language plpgsql stable security invoker set search_path = '' as $$
begin
  return query
  select
    k.id, k.external_id, k.name, k.channel, k.sent_at, k.spend, k.parent_campaign_ref,
    k.reported_sent, k.reported_delivered, k.reported_bounced, k.reported_opens, k.reported_clicks,
    coalesce(s.measured_openers, 0), coalesce(s.measured_clickers, 0), coalesce(s.measured_bounced, 0),
    coalesce(s.measured_complained, 0), coalesce(s.measured_unsubscribed, 0), coalesce(s.events_total, 0),
    coalesce(s.events_before_send, 0), coalesce(s.events_other_channel, 0),
    coalesce(l.batches, 0), coalesce(l.recipients, 0)::bigint,
    coalesce(p.sends, 0), coalesce(p.approved, 0), coalesce(p.dispatched, 0), coalesce(p.delivered, 0),
    coalesce(p.bounced, 0), coalesce(p.opened, 0), coalesce(p.unsubscribed, 0), p.last_send_at
  from public.campaigns k
  left join public.campaign_event_stats s on s.brand_id = k.brand_id and s.campaign_id = k.id
  left join lateral (
    select count(*) as batches, sum(ls.recipient_count) as recipients
    from public.legacy_sends ls where ls.brand_id = k.brand_id and ls.campaign_id = k.id
  ) l on true
  left join lateral (
    select
      count(distinct sd.id) as sends,
      count(r.id) as approved,
      count(r.id) filter (where r.dispatch_status = 'dispatched') as dispatched,
      count(r.id) filter (where (r.delivered_at is not null or r.opened_at is not null) and r.bounced_at is null) as delivered,
      count(r.id) filter (where r.bounced_at is not null) as bounced,
      count(r.id) filter (where r.opened_at is not null) as opened,
      count(r.id) filter (where r.unsubscribed_at is not null) as unsubscribed,
      max(sd.approved_at) as last_send_at
    from public.sends sd
    join public.send_recipients r on r.send_id = sd.id
    where sd.brand_id = k.brand_id and sd.campaign_id = k.id and sd.approved_at is not null
  ) p on true
  where k.brand_id = p_brand_id
    and (p_campaign_id is null or k.id = p_campaign_id)
  order by k.sent_at desc nulls last, k.external_id;
end
$$;

revoke execute on function public.campaign_performance(uuid, uuid) from public, anon;
grant execute on function public.campaign_performance(uuid, uuid) to authenticated;

-- ============================================================================
-- 20260913000014_shared_reports.sql
-- ============================================================================
-- Password-protected, shareable campaign results for people without a login.
--
--   create_share_link(campaign, password, days)   owner: returns the token ONCE
--   revoke_share_link(id)                         owner
--   shared_report_open(token, password)           anyone (anon): the only public entry point
--
-- Safe to send to a stranger:
--   * the token is 256 random bits; only its SHA-256 is stored, so the table
--     can't be used to rebuild links and addresses can't be guessed
--   * the password is stored as a bcrypt hash; unknown tokens still run a
--     bcrypt comparison so response time doesn't reveal whether a link exists
--   * every failure (unknown, wrong password, revoked, expired, locked) returns
--     the same message; 5 wrong passwords lock the link for 15 minutes
--   * the response is built from one campaign's aggregate numbers only:
--     no contact data, no internal ids, nothing else of the brand

create table public.shared_reports (
  id                uuid primary key default gen_random_uuid(),
  brand_id          uuid not null references public.brands(id),
  campaign_id       uuid not null,
  token_hash        text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  password_hash     text not null,
  created_by        uuid not null,
  created_by_email  text not null,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null,
  revoked_at        timestamptz,
  failed_attempts   int not null default 0,
  locked_until      timestamptz,
  view_count        int not null default 0,
  last_viewed_at    timestamptz,
  foreign key (brand_id, campaign_id) references public.campaigns (brand_id, id)
);
create index on public.shared_reports (brand_id, campaign_id, created_at desc);

alter table public.shared_reports enable row level security;
alter table public.shared_reports force row level security;
create policy shared_reports_select_own_brand on public.shared_reports
  for select to authenticated using (brand_id in (select private.current_brand_ids()));
revoke all on public.shared_reports from anon, authenticated;
-- members may see that links exist and how they're used, never the hashes
grant select (id, brand_id, campaign_id, created_by_email, created_at, expires_at, revoked_at, failed_attempts,
  locked_until, view_count, last_viewed_at) on public.shared_reports to authenticated;

create or replace function public.create_share_link(p_campaign_id uuid, p_password text, p_expires_in_days int default 30)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_campaign public.campaigns;
  v_token    text;
  v_row      public.shared_reports;
begin
  select * into v_campaign from public.campaigns where id = p_campaign_id;
  perform private.assert_member(v_campaign.brand_id, true);   -- owners only

  if p_password is null or length(p_password) < 10 or length(p_password) > 128 then
    raise exception 'password must be 10 to 128 characters' using errcode = '22023';
  end if;
  if p_expires_in_days is null or p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'links can last between 1 and 90 days' using errcode = '22023';
  end if;

  v_token := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');

  insert into public.shared_reports (brand_id, campaign_id, token_hash, password_hash, created_by, created_by_email, expires_at)
  values (v_campaign.brand_id, v_campaign.id, encode(extensions.digest(v_token, 'sha256'), 'hex'),
    extensions.crypt(p_password, extensions.gen_salt('bf', 10)), auth.uid(), private.current_email(),
    now() + make_interval(days => p_expires_in_days))
  returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'token', v_token, 'expires_at', v_row.expires_at);
end
$$;

create or replace function public.revoke_share_link(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_row public.shared_reports;
begin
  select * into v_row from public.shared_reports where id = p_id for update;
  perform private.assert_member(v_row.brand_id, true);
  update public.shared_reports set revoked_at = coalesce(revoked_at, now()) where id = p_id;
end
$$;

-- The single public entry point. Never raises for bad input (a raised error
-- would roll back the failed-attempt counter); returns {ok:false} instead.
create or replace function public.shared_report_open(p_token text, p_password text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_generic constant jsonb := '{"ok": false, "error": "This link or password is not valid, or the link has expired."}';
  v_row      public.shared_reports;
  v_campaign public.campaigns;
  v_brand    public.brands;
  v_ok       boolean;
  v_result   jsonb;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' or p_password is null or length(p_password) > 128 then
    perform extensions.crypt('dummy-password', '$2a$10$abcdefghijklmnopqrstuuYJ1iBO6s6r1NUvsXk5bWXKBF9QWEBn6');
    return c_generic;
  end if;

  select * into v_row from public.shared_reports
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    for update;

  if not found then
    perform extensions.crypt(p_password, '$2a$10$abcdefghijklmnopqrstuuYJ1iBO6s6r1NUvsXk5bWXKBF9QWEBn6');
    return c_generic;
  end if;

  if v_row.revoked_at is not null or v_row.expires_at < now() or coalesce(v_row.locked_until > now(), false) then
    perform extensions.crypt(p_password, v_row.password_hash);
    return c_generic;
  end if;

  v_ok := extensions.crypt(p_password, v_row.password_hash) = v_row.password_hash;
  if not v_ok then
    update public.shared_reports set
      failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
      locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else locked_until end
    where id = v_row.id;
    return c_generic;
  end if;

  update public.shared_reports set failed_attempts = 0, view_count = view_count + 1, last_viewed_at = now()
    where id = v_row.id;

  select * into v_campaign from public.campaigns where brand_id = v_row.brand_id and id = v_row.campaign_id;
  select * into v_brand from public.brands where id = v_row.brand_id;

  select jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'link_expires_at', v_row.expires_at,
    'brand_name', v_brand.name,
    'timezone', v_brand.timezone,
    'campaign', jsonb_build_object(
      'name', v_campaign.name, 'reference', v_campaign.external_id, 'channel', v_campaign.channel,
      'sent_at', v_campaign.sent_at),
    'reported', jsonb_build_object(
      'sent', v_campaign.reported_sent, 'delivered', v_campaign.reported_delivered, 'bounced', v_campaign.reported_bounced,
      'opens', v_campaign.reported_opens, 'clicks', v_campaign.reported_clicks),
    'measured', (select jsonb_build_object(
        'openers', s.measured_openers, 'clickers', s.measured_clickers, 'bounced', s.measured_bounced,
        'complained', s.measured_complained, 'unsubscribed', s.measured_unsubscribed, 'events_before_send_excluded', s.events_before_send)
      from public.campaign_event_stats s where s.brand_id = v_row.brand_id and s.campaign_id = v_row.campaign_id),
    'portal_sends', (select jsonb_build_object(
        'sends', count(distinct sd.id),
        'recipients', count(r.id),
        'sent', count(r.id) filter (where r.dispatch_status = 'dispatched'),
        'delivered', count(r.id) filter (where (r.delivered_at is not null or r.opened_at is not null) and r.bounced_at is null),
        'bounced', count(r.id) filter (where r.bounced_at is not null),
        'opened', count(r.id) filter (where r.opened_at is not null),
        'clicked', count(r.id) filter (where r.clicked_at is not null),
        'unsubscribed', count(r.id) filter (where r.unsubscribed_at is not null),
        'last_sent_at', max(sd.approved_at))
      from public.sends sd join public.send_recipients r on r.send_id = sd.id
      where sd.brand_id = v_row.brand_id and sd.campaign_id = v_row.campaign_id and sd.approved_at is not null)
  ) into v_result;

  return v_result;
end
$$;

revoke execute on function public.create_share_link(uuid, text, int), public.revoke_share_link(uuid) from public, anon;
grant execute on function public.create_share_link(uuid, text, int), public.revoke_share_link(uuid) to authenticated;
revoke execute on function public.shared_report_open(text, text) from public;
grant execute on function public.shared_report_open(text, text) to anon, authenticated;

-- ============================================================================
-- 20260913000015_auth_allowlist_hook.sql
-- ============================================================================
-- "Someone who isn't one of the six gets in nowhere."
--
-- Supabase Auth calls this before creating ANY user (email sign-up, Google,
-- admin API). Emails not on the memberships allowlist are refused, so a
-- stranger cannot even obtain a session. RLS remains the second line: a user
-- who somehow exists without a membership still sees nothing.
--
-- Enabled in Auth settings as: pg-functions://postgres/private/hook_before_user_created

create or replace function private.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(event->'user'->>'email', '')));
begin
  if v_email <> '' and exists (select 1 from public.memberships m where m.email = v_email) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This account is not invited to the Campaign Portal.'));
end
$$;

revoke execute on function private.hook_before_user_created(jsonb) from public, anon, authenticated;
grant usage on schema private to supabase_auth_admin;
grant execute on function private.hook_before_user_created(jsonb) to supabase_auth_admin;

-- ============================================================================
-- 20260913000016_incremental_prepare.sql
-- ============================================================================
-- Build a send's audience in steps.
--
-- Freezing ~35k Kilele recipients in one request took 5-9s on this instance,
-- past the API's 8s statement timeout, so the big brand could not send at all.
-- Now prepare_send creates the send in status 'preparing', and the portal
-- calls prepare_send_step until it reports done. Each step scans the next
-- 5,000 contacts in external-id order (an index range, ~0.2-0.5s) and freezes
-- the eligible ones. The last step computes count + hash, creates the batches
-- and opens the 15-minute confirmation window. Nothing about approval changed:
-- the approved count and hash are still exactly the frozen list.

do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.sends'::regclass and contype = 'c'
      and (pg_get_constraintdef(oid) like '%status%')
  loop
    execute format('alter table public.sends drop constraint %I', c.conname);
  end loop;
end
$$;

alter table public.sends
  add constraint sends_status_valid check (status in
    ('preparing', 'draft', 'approved', 'dispatching', 'completed', 'partially_failed', 'failed', 'cancelled', 'expired')),
  add constraint sends_approval_recorded check (
    status in ('preparing', 'draft', 'cancelled', 'expired')
    or (approved_at is not null and approved_by is not null and approved_count is not null)),
  add column audience_cursor text,
  add column contacts_scanned int not null default 0,
  add column contacts_total int;

create or replace function public.prepare_send(p_campaign_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_campaign  public.campaigns;
  v_send      public.sends;
  v_live      public.sends;
begin
  select * into v_campaign from public.campaigns where id = p_campaign_id;
  perform private.assert_member(v_campaign.brand_id, true);   -- owners only; unknown campaign raises too
  perform pg_advisory_xact_lock(hashtextextended('send:' || v_campaign.id::text, 0));

  select * into v_live from public.sends
    where brand_id = v_campaign.brand_id and campaign_id = v_campaign.id and status in ('approved', 'dispatching');
  if found then
    return jsonb_build_object('error', 'send_in_progress', 'send_id', v_live.id,
      'message', 'This campaign is already being sent. Wait for it to finish before preparing another send.');
  end if;

  -- older unconfirmed drafts for this campaign can no longer be approved
  update public.sends set status = 'cancelled'
    where brand_id = v_campaign.brand_id and campaign_id = v_campaign.id and status in ('preparing', 'draft');

  insert into public.sends (brand_id, campaign_id, channel, status, recipient_count, audience_hash, chunk_size, chunk_count,
    prepared_by, prepared_by_email, expires_at, audience_cursor, contacts_scanned, contacts_total)
  values (v_campaign.brand_id, v_campaign.id, v_campaign.channel, 'preparing', 0, repeat('0', 64), 500, 0,
    auth.uid(), private.current_email(), now() + interval '15 minutes', '', 0,
    (select count(*) from public.contacts where brand_id = v_campaign.brand_id))
  returning * into v_send;

  return jsonb_build_object('send_id', v_send.id, 'status', v_send.status, 'channel', v_send.channel,
    'contacts_total', v_send.contacts_total);
end
$$;

create or replace function public.prepare_send_step(p_send_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_batch    constant int := 5000;
  v_send     public.sends;
  v_scanned  int;
  v_last     text;
  v_count    int;
  v_hash     text;
begin
  select * into v_send from public.sends where id = p_send_id;
  perform private.assert_member(v_send.brand_id, true);
  select * into v_send from public.sends where id = p_send_id for update;   -- one step at a time per send

  if v_send.status <> 'preparing' then
    return jsonb_build_object('send_id', v_send.id, 'status', v_send.status, 'done', v_send.status = 'draft',
      'recipient_count', v_send.recipient_count, 'audience_hash', v_send.audience_hash, 'expires_at', v_send.expires_at,
      'chunk_count', v_send.chunk_count, 'contacts_scanned', v_send.contacts_scanned, 'contacts_total', v_send.contacts_total);
  end if;
  if v_send.expires_at < now() then
    update public.sends set status = 'expired' where id = v_send.id;
    return jsonb_build_object('error', 'expired', 'message', 'Building the audience took too long. Start again.');
  end if;

  select count(*), max(external_id) into v_scanned, v_last
  from (
    select external_id from public.contacts
    where brand_id = v_send.brand_id and external_id > v_send.audience_cursor
    order by external_id limit c_batch
  ) s;

  with scan as (
    select c.id, c.external_id, c.email, c.phone_e164
    from public.contacts c
    where c.brand_id = v_send.brand_id and c.external_id > v_send.audience_cursor
    order by c.external_id
    limit c_batch
  ),
  eligible as (
    select s.id, s.external_id, case v_send.channel when 'email' then s.email else s.phone_e164 end as address
    from scan s
    join public.contact_reachability r on r.brand_id = v_send.brand_id and r.contact_id = s.id
    -- the same rules the dashboard counts as contactable, for this campaign's channel
    where not r.is_deleted and r.status_ok and r.consent_ok and not r.suppressed_by_date and not r.opted_out
      and case v_send.channel when 'email' then r.email_ok else r.sms_ok end
  ),
  numbered as (
    select e.*, v_send.recipient_count + row_number() over (order by e.external_id) as seq from eligible e
  )
  insert into public.send_recipients (brand_id, send_id, contact_id, address, seq, chunk_no)
  select v_send.brand_id, v_send.id, n.id, n.address, n.seq, ((n.seq - 1) / v_send.chunk_size)::int
  from numbered n;

  get diagnostics v_count = row_count;

  update public.sends set
    recipient_count = recipient_count + v_count,
    contacts_scanned = contacts_scanned + v_scanned,
    audience_cursor = coalesce(v_last, audience_cursor)
  where id = v_send.id
  returning * into v_send;

  if v_scanned < c_batch then
    -- every contact has been considered: freeze the list and open the confirmation
    select encode(extensions.digest(coalesce(string_agg(contact_id::text || '=' || address, ',' order by seq), ''), 'sha256'), 'hex')
      into v_hash
    from public.send_recipients where send_id = v_send.id;

    insert into public.send_chunks (brand_id, send_id, chunk_no, idempotency_key)
    select v_send.brand_id, v_send.id, g, v_send.id::text || ':' || g
    from generate_series(0, ceil(v_send.recipient_count::numeric / v_send.chunk_size)::int - 1) g;

    update public.sends set
      status = 'draft', audience_hash = v_hash,
      chunk_count = ceil(recipient_count::numeric / chunk_size)::int,
      expires_at = now() + interval '15 minutes'
    where id = v_send.id
    returning * into v_send;
  end if;

  return jsonb_build_object('send_id', v_send.id, 'status', v_send.status, 'done', v_send.status = 'draft',
    'recipient_count', v_send.recipient_count, 'audience_hash', v_send.audience_hash, 'expires_at', v_send.expires_at,
    'chunk_count', v_send.chunk_count, 'contacts_scanned', v_send.contacts_scanned, 'contacts_total', v_send.contacts_total);
end
$$;

create or replace function public.cancel_send(p_send_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_send public.sends;
begin
  select * into v_send from public.sends where id = p_send_id for update;
  perform private.assert_member(v_send.brand_id, true);
  if v_send.status in ('preparing', 'draft') then
    update public.sends set status = 'cancelled' where id = v_send.id;
  end if;
end
$$;

revoke execute on function public.prepare_send_step(uuid) from public, anon;
grant execute on function public.prepare_send_step(uuid) to authenticated;

-- ============================================================================
-- 20260913000017_sync_scheduling.sql
-- ============================================================================
-- Report syncing that scales to large sends (a Kilele send is ~70 batches).
-- Incremental reads continue until the provider says a batch is complete.
-- Full re-reads (to catch reports that land behind the cursor) back off as
-- the batch ages: every 10 min in the first hour, hourly for a day, then
-- every 6 hours until 3 days after dispatch.

create or replace function public.svc_chunks_to_sync(p_limit int default 50)
returns table (send_id uuid, chunk_no int, provider_batch_id text, events_cursor text, full_resync boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_service_role();
  return query
  with candidates as (
    select c.*,
      (c.full_resync_at is null or c.full_resync_at < now() - case
         when c.dispatched_at > now() - interval '1 hour' then interval '10 minutes'
         when c.dispatched_at > now() - interval '1 day' then interval '1 hour'
         else interval '6 hours' end) as full_due
    from public.send_chunks c
    where c.provider_batch_id is not null
      and c.dispatched_at > now() - interval '3 days'
  )
  select c.send_id, c.chunk_no, c.provider_batch_id, c.events_cursor, c.full_due
  from candidates c
  where not c.events_complete or c.full_due
  order by c.events_synced_at nulls first
  limit least(greatest(coalesce(p_limit, 50), 1), 500);
end
$$;
