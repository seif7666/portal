import { Link } from 'react-router';
import { useBrand } from '../lib/auth';
import { useCampaignPerformance, type CampaignPerformance } from '../lib/queries';
import { fmtDateTime, fmtInt, fmtMoney } from '../lib/format';
import { Badge, Card, EmptyState, ErrorState, LoadingState, PageHeader, TableWrap } from '../components/ui';

export function CampaignsPage() {
  const brand = useBrand();
  const q = useCampaignPerformance(brand.brand_id);

  return (
    <>
      <PageHeader
        title="Campaigns"
        description="Reported numbers come from the campaign export as supplied. Measured numbers are recounted from the raw engagement log as unique people, so the two can disagree; where they do, it is flagged."
      />
      <Card>
        {q.isPending ? (
          <LoadingState />
        ) : q.isError ? (
          <ErrorState error={q.error} onRetry={() => q.refetch()} />
        ) : q.data.length === 0 ? (
          <EmptyState title="No campaigns yet">{brand.isOwner ? 'Load a campaigns export on the Imports page.' : 'The owner has not loaded any campaigns yet.'}</EmptyState>
        ) : (
          <CampaignTable rows={q.data} />
        )}
      </Card>
      <CountingNotes />
    </>
  );
}

export function campaignFlags(c: CampaignPerformance) {
  const flags: { tone: 'amber' | 'slate'; text: string }[] = [];
  if (c.reported_opens != null && c.reported_delivered != null && c.reported_opens > c.reported_delivered)
    flags.push({ tone: 'amber', text: 'Reported opens exceed deliveries' });
  if (c.reported_clicks != null && c.reported_opens != null && c.reported_clicks > c.reported_opens)
    flags.push({ tone: 'amber', text: 'Reported clicks exceed opens' });
  if (c.reported_sent != null && c.reported_delivered != null && c.reported_bounced != null && c.reported_sent !== c.reported_delivered + c.reported_bounced)
    flags.push({ tone: 'amber', text: 'Sent ≠ delivered + bounced' });
  if (c.events_before_send > 0) flags.push({ tone: 'amber', text: `${fmtInt(c.events_before_send)} events dated before send, not counted` });
  if (c.events_total === 0) flags.push({ tone: 'slate', text: 'No events in the log' });
  if (c.portal_sends > 0)
    flags.push({ tone: 'slate', text: `Portal: sent to ${fmtInt(c.portal_dispatched)}, ${fmtInt(c.portal_delivered)} delivered, ${fmtInt(c.portal_opened)} opened` });
  return flags;
}

export function CampaignTable({ rows, compact = false }: { rows: CampaignPerformance[]; compact?: boolean }) {
  const brand = useBrand();
  return (
    <TableWrap>
      <table className="min-w-full text-sm">
        <thead>
          <tr className="border-b border-slate-200 text-left text-xs font-medium tracking-wide text-slate-500 uppercase">
            <th className="px-4 py-2" rowSpan={2}>Campaign</th>
            <th className="px-4 py-2" rowSpan={2}>Sent</th>
            <th className="border-l border-slate-100 px-4 pt-2 pb-0 text-center normal-case" colSpan={compact ? 2 : 4}>Reported (export)</th>
            <th className="border-l border-slate-100 px-4 pt-2 pb-0 text-center normal-case" colSpan={compact ? 2 : 4}>Measured (unique people)</th>
            <th className="px-4 py-2" rowSpan={2}>Data notes</th>
          </tr>
          <tr className="border-b border-slate-200 text-right text-xs font-medium text-slate-500">
            {!compact && <th className="border-l border-slate-100 px-4 py-1.5">Sent</th>}
            <th className={`px-4 py-1.5 ${compact ? 'border-l border-slate-100' : ''}`}>Delivered</th>
            <th className="px-4 py-1.5">Opens</th>
            {!compact && <th className="px-4 py-1.5">Clicks</th>}
            <th className="border-l border-slate-100 px-4 py-1.5">Opened</th>
            <th className="px-4 py-1.5">Clicked</th>
            {!compact && <th className="px-4 py-1.5">Bounced</th>}
            {!compact && <th className="px-4 py-1.5">Unsub.</th>}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100 align-top">
          {rows.map((c) => {
            const flags = campaignFlags(c);
            return (
              <tr key={c.campaign_id} className="hover:bg-slate-50">
                <td className="px-4 py-2.5">
                  <Link to={`/b/${brand.brand_slug}/campaigns/${c.campaign_id}`} className="font-medium text-brand-700 hover:underline">{c.name}</Link>
                  <div className="mt-0.5 flex items-center gap-1.5 text-xs text-slate-500">
                    <span>{c.external_id}</span>
                    <Badge>{c.channel === 'email' ? 'Email' : 'SMS'}</Badge>
                    {!compact && c.spend != null && <span className="tabular">· spend {fmtMoney(c.spend)}</span>}
                  </div>
                </td>
                <td className="px-4 py-2.5 whitespace-nowrap text-slate-600">{fmtDateTime(c.sent_at, brand.brand_timezone)}</td>
                {!compact && <td className="tabular border-l border-slate-100 px-4 py-2.5 text-right">{fmtInt(c.reported_sent)}</td>}
                <td className={`tabular px-4 py-2.5 text-right ${compact ? 'border-l border-slate-100' : ''}`}>{fmtInt(c.reported_delivered)}</td>
                <td className="tabular px-4 py-2.5 text-right">{fmtInt(c.reported_opens)}</td>
                {!compact && <td className="tabular px-4 py-2.5 text-right">{fmtInt(c.reported_clicks)}</td>}
                <td className="tabular border-l border-slate-100 px-4 py-2.5 text-right">{fmtInt(c.measured_openers)}</td>
                <td className="tabular px-4 py-2.5 text-right">{fmtInt(c.measured_clickers)}</td>
                {!compact && <td className="tabular px-4 py-2.5 text-right">{fmtInt(c.measured_bounced)}</td>}
                {!compact && <td className="tabular px-4 py-2.5 text-right">{fmtInt(c.measured_unsubscribed)}</td>}
                <td className="px-4 py-2.5">
                  <div className="flex max-w-xs flex-wrap gap-1">
                    {flags.length === 0 ? <span className="text-xs text-slate-400">—</span> : flags.map((f) => <Badge key={f.text} tone={f.tone}>{f.text}</Badge>)}
                  </div>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </TableWrap>
  );
}

export function CountingNotes() {
  return (
    <details className="mt-4 rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm text-slate-600">
      <summary className="cursor-pointer font-medium text-slate-800">How these numbers are counted</summary>
      <ul className="mt-2 list-disc space-y-1 pl-5">
        <li><b>Reported</b> values are copied from the campaign export unchanged. Some exports count every open (one person opening three times = 3), which is why reported opens can exceed deliveries.</li>
        <li><b>Measured</b> values count <b>people</b>: a contact who opened three times is one opener. Duplicate event rows (same event id) are counted once.</li>
        <li>Events timestamped <b>before the campaign's send time</b> cannot be real responses to it, so they are not counted; the number excluded is shown per campaign.</li>
        <li>Events whose channel differs from the campaign's channel are still counted against the campaign they reference.</li>
        <li>Events for contacts or campaigns that were not loaded are not counted; they are listed on the Imports page.</li>
      </ul>
    </details>
  );
}
