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
