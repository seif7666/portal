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
