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
