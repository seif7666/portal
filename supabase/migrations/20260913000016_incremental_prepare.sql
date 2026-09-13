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
