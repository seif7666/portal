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
