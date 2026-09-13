// Typed wrappers around the read RPCs. Every call passes the brand id, but the
// database decides what the caller can see: a foreign brand id returns nothing.
import { useQuery } from '@tanstack/react-query';
import { supabase } from './supabase';

export interface DashboardSummary {
  contacts_in_database: number;
  deleted: number;
  total_customers: number;
  excluded_status: number;
  excluded_no_consent: number;
  excluded_suppressed: number;
  excluded_opted_out: number;
  excluded_no_address: number;
  contactable_any: number;
  contactable_email: number;
  contactable_sms: number;
  computed_at: string;
}

export interface SignupsPerDay {
  timezone: string;
  from: string;
  to: string;
  days: { day: string; signups: number }[];
  total_in_window: number;
  latest_signup_at: string | null;
  contacts_without_signup_date: number;
}

export interface CampaignPerformance {
  campaign_id: string;
  external_id: string;
  name: string;
  channel: 'email' | 'sms';
  sent_at: string | null;
  spend: number | null;
  parent_campaign_ref: string | null;
  reported_sent: number | null;
  reported_delivered: number | null;
  reported_bounced: number | null;
  reported_opens: number | null;
  reported_clicks: number | null;
  measured_openers: number;
  measured_clickers: number;
  measured_bounced: number;
  measured_complained: number;
  measured_unsubscribed: number;
  events_total: number;
  events_before_send: number;
  events_other_channel: number;
  legacy_batches: number;
  legacy_recipients: number;
}

export interface ContactRow {
  id: string;
  external_id: string;
  full_name: string | null;
  email: string | null;
  phone_e164: string | null;
  phone_raw: string | null;
  country: string | null;
  city: string | null;
  signup_at: string | null;
  status: string;
  consent_marketing: boolean | null;
  deleted_at: string | null;
  suppressed_until: string | null;
  contactable_email: boolean;
  contactable_sms: boolean;
  not_contactable_reason: string | null;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export const useDashboardSummary = (brandId: string) =>
  useQuery({ queryKey: ['dashboard_summary', brandId], queryFn: () => rpc<DashboardSummary>('dashboard_summary', { p_brand_id: brandId }) });

export const useSignupsPerDay = (brandId: string) =>
  useQuery({ queryKey: ['signups_per_day', brandId], queryFn: () => rpc<SignupsPerDay>('signups_per_day', { p_brand_id: brandId, p_days: 30 }) });

export const useCampaignPerformance = (brandId: string, campaignId?: string) =>
  useQuery({
    queryKey: ['campaign_performance', brandId, campaignId ?? null],
    queryFn: () => rpc<CampaignPerformance[]>('campaign_performance', { p_brand_id: brandId, p_campaign_id: campaignId ?? null }),
  });

export function fetchContacts(brandId: string, search: string, filter: string, after: string | null) {
  return rpc<ContactRow[]>('list_contacts', { p_brand_id: brandId, p_search: search || null, p_filter: filter, p_after: after, p_limit: 50 });
}
