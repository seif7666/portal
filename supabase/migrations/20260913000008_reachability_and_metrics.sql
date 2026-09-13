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
