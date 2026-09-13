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
