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

