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
