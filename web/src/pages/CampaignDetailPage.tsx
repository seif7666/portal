import { Link, useParams } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { useBrand } from '../lib/auth';
import { useCampaignPerformance } from '../lib/queries';
import { fmtDateTime, fmtInt, fmtMoney, fmtPct } from '../lib/format';
import { Badge, Card, EmptyState, ErrorState, LoadingState, PageHeader, Stat, TableWrap } from '../components/ui';
import { NotFoundPage } from './StatusPages';
import { campaignFlags, CountingNotes } from './CampaignsPage';
import { CampaignSends } from './sends/CampaignSends';
import { ShareLinks } from './sends/ShareLinks';

interface LegacySend { batch_key: string; queued_at: string; recipient_count: number; status: string }

export function CampaignDetailPage() {
  const { campaignId } = useParams();
  const brand = useBrand();
  const perf = useCampaignPerformance(brand.brand_id, campaignId);
  const legacy = useQuery({
    queryKey: ['legacy_sends', campaignId],
    queryFn: async () => {
      const { data, error } = await supabase.from('legacy_sends').select('batch_key,queued_at,recipient_count,status').eq('campaign_id', campaignId!).order('queued_at');
      if (error) throw error;
      return data as LegacySend[];
    },
  });

  if (perf.isPending) return <LoadingState />;
  if (perf.isError) return <ErrorState error={perf.error} onRetry={() => perf.refetch()} />;
  const c = perf.data[0];
  if (!c) return <NotFoundPage embedded />;
  const flags = campaignFlags(c);

  return (
    <>
      <Link to={`/b/${brand.brand_slug}/campaigns`} className="text-sm text-brand-700 hover:underline">← All campaigns</Link>
      <PageHeader
        title={c.name}
        description={
          <span className="flex flex-wrap items-center gap-2">
            <Badge>{c.channel === 'email' ? 'Email' : 'SMS'}</Badge>
            <span>{c.external_id} · sent {fmtDateTime(c.sent_at, brand.brand_timezone)} · spend {fmtMoney(c.spend)}</span>
          </span>
        }
      />

      {flags.length > 0 && (
        <div className="mb-6 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <p className="font-medium">Data notes for this campaign</p>
          <ul className="mt-1 list-disc pl-5">{flags.map((f) => <li key={f.text}>{f.text}</li>)}</ul>
        </div>
      )}
      {c.parent_campaign_ref && (
        <p className="mb-6 rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm text-slate-600">
          The export names <code className="text-xs">{c.parent_campaign_ref}</code> as this campaign's parent. It is shown as text only and is never looked up across brands.
        </p>
      )}

      <CampaignSends campaignId={c.campaign_id} campaignName={c.name} />
      <ShareLinks campaignId={c.campaign_id} />

      <h2 className="mt-8 mb-2 text-sm font-semibold text-slate-800">Reported by the campaign export</h2>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Stat label="Sent" value={fmtInt(c.reported_sent)} />
        <Stat label="Delivered" value={fmtInt(c.reported_delivered)} sub={`${fmtPct(c.reported_delivered, c.reported_sent)} of sent`} />
        <Stat label="Bounced" value={fmtInt(c.reported_bounced)} sub={`${fmtPct(c.reported_bounced, c.reported_sent)} of sent`} />
        <Stat label="Opens" value={fmtInt(c.reported_opens)} sub={`÷ delivered = ${fmtPct(c.reported_opens, c.reported_delivered)}`} />
        <Stat label="Clicks" value={fmtInt(c.reported_clicks)} sub={`÷ delivered = ${fmtPct(c.reported_clicks, c.reported_delivered)}`} />
      </div>

      <h2 className="mt-6 mb-2 text-sm font-semibold text-slate-800">Measured from the engagement log (unique people)</h2>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Stat label="Opened" value={fmtInt(c.measured_openers)} sub="people with at least one open" />
        <Stat label="Clicked" value={fmtInt(c.measured_clickers)} sub="people with at least one click" />
        <Stat label="Bounced" value={fmtInt(c.measured_bounced)} />
        <Stat label="Complained" value={fmtInt(c.measured_complained)} />
        <Stat label="Unsubscribed" value={fmtInt(c.measured_unsubscribed)} />
      </div>
      <p className="mt-2 text-xs text-slate-500">
        From {fmtInt(c.events_total)} logged events{c.events_before_send ? `, of which ${fmtInt(c.events_before_send)} were dated before the send time and not counted` : ''}
        {c.events_other_channel ? `; ${fmtInt(c.events_other_channel)} were logged on a different channel than the campaign's` : ''}.
      </p>

      <Card title="Previous sends (from the send log)" className="mt-6">
        {legacy.isPending ? (
          <LoadingState />
        ) : legacy.isError ? (
          <ErrorState error={legacy.error} onRetry={() => legacy.refetch()} />
        ) : legacy.data.length === 0 ? (
          <EmptyState title="No sends recorded in the send log for this campaign" />
        ) : (
          <TableWrap>
            <table className="min-w-full text-sm">
              <thead><tr className="border-b border-slate-200 text-left text-xs text-slate-500 uppercase"><th className="px-4 py-2">Batch</th><th className="px-4 py-2">Queued</th><th className="px-4 py-2 text-right">Recipients</th><th className="px-4 py-2">Status</th></tr></thead>
              <tbody className="divide-y divide-slate-100">
                {legacy.data.map((s) => (
                  <tr key={s.batch_key}>
                    <td className="px-4 py-2 font-mono text-xs">{s.batch_key}</td>
                    <td className="px-4 py-2">{fmtDateTime(s.queued_at, brand.brand_timezone)}</td>
                    <td className="tabular px-4 py-2 text-right">{fmtInt(s.recipient_count)}</td>
                    <td className="px-4 py-2"><Badge tone="green">{s.status}</Badge></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </TableWrap>
        )}
        <p className="mt-3 text-xs text-slate-500">Batches listed more than once in the send log are shown once: a repeated line is the same send, not another one.</p>
      </Card>

      <CountingNotes />
    </>
  );
}
