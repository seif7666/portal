// What happened after the button was pressed: approval record, dispatch
// progress per batch, and the delivery picture as reports arrive.
import { useState } from 'react';
import { Link, useParams } from 'react-router';
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, errorMessage } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { fmtDateTime, fmtInt, fmtPct, timeAgo } from '../../lib/format';
import { Badge, Button, Card, ErrorState, LoadingState, PageHeader, Stat, TableWrap } from '../../components/ui';
import { NotFoundPage } from '../StatusPages';

export interface SendSummary {
  send: {
    id: string; campaign_id: string; channel: 'email' | 'sms'; status: string; recipient_count: number; chunk_count: number;
    prepared_by_email: string; prepared_at: string; approved_by_email: string | null; approved_at: string | null;
    approved_count: number | null; dispatch_started_at: string | null; completed_at: string | null;
  };
  campaign_name: string;
  campaign_external_id: string;
  recipients: Record<'approved' | 'pending' | 'skipped' | 'dispatched' | 'rejected' | 'failed' | 'delivered' | 'bounced' | 'opened' | 'clicked' | 'complained' | 'unsubscribed' | 'awaiting_report', number>;
  skip_reasons: Record<string, number>;
  chunks: { total: number; pending: number; in_flight: number; dispatched: number; failed: number; retrying: number; last_error: string | null; events_synced_at: string | null; all_reports_complete: boolean };
  events: { applied: number; quarantined: number; quarantine_reasons: Record<string, number> };
}

export function sendStatusBadge(status: string) {
  switch (status) {
    case 'draft': return <Badge>Not confirmed</Badge>;
    case 'approved': return <Badge tone="blue">Approved, starting</Badge>;
    case 'dispatching': return <Badge tone="blue">Sending</Badge>;
    case 'completed': return <Badge tone="green">Sent</Badge>;
    case 'partially_failed': return <Badge tone="amber">Partly sent</Badge>;
    case 'failed': return <Badge tone="red">Failed</Badge>;
    case 'expired': return <Badge>Confirmation expired</Badge>;
    case 'cancelled': return <Badge>Cancelled</Badge>;
    default: return <Badge>{status}</Badge>;
  }
}

interface RecipientRow { seq: number; external_id: string; full_name: string | null; address: string; dispatch_status: string; skip_reason: string | null; delivered: boolean; bounced: boolean; opened: boolean; unsubscribed: boolean }

export function SendPage() {
  const { sendId } = useParams();
  const brand = useBrand();
  const queryClient = useQueryClient();
  const [page, setPage] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);

  const summary = useQuery({
    queryKey: ['send_summary', sendId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('send_summary', { p_send_id: sendId });
      if (error) throw error;
      return data as SendSummary | null;
    },
    refetchInterval: (q) => {
      const d = q.state.data;
      if (!d) return false;
      if (['approved', 'dispatching'].includes(d.send.status)) return 3000;
      return d.chunks.all_reports_complete ? false : 15000;
    },
  });

  const recipients = useQuery({
    queryKey: ['send_recipients', sendId, page, summary.data?.events.applied, summary.data?.recipients.dispatched],
    enabled: !!summary.data,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('send_recipients_page', { p_send_id: sendId, p_after_seq: page * 50, p_limit: 50 });
      if (error) throw error;
      return data as RecipientRow[];
    },
  });

  async function refreshReports() {
    setRefreshing(true);
    setRefreshError(null);
    const { error } = await supabase.functions.invoke('sync-provider-events', { body: {} });
    if (error) setRefreshError(errorMessage(error));
    await queryClient.invalidateQueries({ queryKey: ['send_summary', sendId] });
    setRefreshing(false);
  }

  if (summary.isPending) return <LoadingState />;
  if (summary.isError) return <ErrorState error={summary.error} onRetry={() => summary.refetch()} />;
  if (!summary.data) return <NotFoundPage embedded />;
  const { send, recipients: r, chunks, events } = summary.data;
  const sentTo = r.dispatched;

  return (
    <>
      <Link to={`/b/${brand.brand_slug}/campaigns/${send.campaign_id}`} className="text-sm text-brand-700 hover:underline">← {summary.data.campaign_name}</Link>
      <PageHeader
        title={`Send of “${summary.data.campaign_name}”`}
        description={<span className="flex flex-wrap items-center gap-2">{sendStatusBadge(send.status)} <span>{send.channel === 'email' ? 'Email' : 'SMS'} · {summary.data.campaign_external_id} · send {send.id.slice(0, 8)}</span></span>}
      />

      <Card title="Approval">
        {send.approved_at ? (
          <p className="text-sm text-slate-700">
            Approved by <span className="font-medium">{send.approved_by_email}</span> on {fmtDateTime(send.approved_at, brand.brand_timezone)} for{' '}
            <span className="tabular font-semibold">{fmtInt(send.approved_count)}</span> recipients. This record cannot be edited.
          </p>
        ) : (
          <p className="text-sm text-slate-600">Prepared by {send.prepared_by_email} on {fmtDateTime(send.prepared_at, brand.brand_timezone)} for {fmtInt(send.recipient_count)} recipients; never confirmed, so nothing was sent.</p>
        )}
      </Card>

      {send.approved_at && (
        <>
          <Card title="Dispatch" className="mt-6">
            <div className="flex items-center justify-between text-sm">
              <span className="text-slate-700">{fmtInt(chunks.dispatched)} of {fmtInt(chunks.total)} batches handed to the provider</span>
              <span className="tabular text-slate-500">{fmtPct(chunks.dispatched, chunks.total)}</span>
            </div>
            <div className="mt-2 flex h-2 overflow-hidden rounded-full bg-slate-100">
              <div className="h-full bg-brand-600" style={{ width: `${chunks.total ? (chunks.dispatched / chunks.total) * 100 : 0}%` }} />
              <div className="h-full bg-red-500" style={{ width: `${chunks.total ? (chunks.failed / chunks.total) * 100 : 0}%` }} />
            </div>
            {chunks.retrying > 0 && <p className="mt-2 text-sm text-amber-800">{fmtInt(chunks.retrying)} batches are being retried. Retries reuse the same request, so nobody receives a message twice.</p>}
            {chunks.failed > 0 && <p className="mt-2 text-sm text-red-700">{fmtInt(chunks.failed)} batches could not be sent after repeated attempts; their {fmtInt(r.failed)} recipients did not get this message.</p>}
            {chunks.last_error && send.status !== 'completed' && <p className="mt-2 text-xs text-slate-500">Last provider error: {chunks.last_error}</p>}

            <div className="mt-4 grid grid-cols-2 gap-3 md:grid-cols-5">
              <Stat label="Approved" value={fmtInt(r.approved)} />
              <Stat label="Sent to provider" value={fmtInt(r.dispatched)} />
              <Stat label="Skipped" value={fmtInt(r.skipped)} sub="became uncontactable after approval" />
              <Stat label="Rejected" value={fmtInt(r.rejected)} sub="by the provider" />
              <Stat label="Not sent" value={fmtInt(r.failed + r.pending)} sub={r.pending ? `${fmtInt(r.pending)} still queued` : 'batch failures'} />
            </div>
            {Object.keys(summary.data.skip_reasons).length > 0 && (
              <ul className="mt-3 text-sm text-slate-600">
                {Object.entries(summary.data.skip_reasons).map(([reason, n]) => <li key={reason}>{fmtInt(n)} skipped: {reason}</li>)}
              </ul>
            )}
          </Card>

          <Card
            title="Delivery and engagement"
            className="mt-6"
            actions={
              <div className="flex items-center gap-3 text-xs text-slate-500">
                <span>{chunks.events_synced_at ? `Reports checked ${timeAgo(chunks.events_synced_at)}` : 'No reports yet'}{chunks.all_reports_complete ? ' · provider says complete' : ''}</span>
                <Button size="sm" variant="secondary" onClick={refreshReports} disabled={refreshing}>{refreshing ? 'Checking…' : 'Check now'}</Button>
              </div>
            }
          >
            {refreshError && <p role="alert" className="mb-3 text-sm text-red-700">{refreshError}</p>}
            <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
              <Stat label="Delivered" value={fmtInt(r.delivered)} sub={`${fmtPct(r.delivered, sentTo)} of sent`} definition="People with a delivered or opened report and no bounce. An open proves delivery even if the delivered report never arrived." />
              <Stat label="Bounced" value={fmtInt(r.bounced)} sub={`${fmtPct(r.bounced, sentTo)} of sent`} definition="People with any bounce report. The bounced address is no longer contactable." />
              <Stat label="Opened" value={fmtInt(r.opened)} sub={`${fmtPct(r.opened, r.delivered)} of delivered`} definition="People with at least one open report, counted once however many opens arrive." />
              <Stat label="Clicked" value={fmtInt(r.clicked)} sub={`${fmtPct(r.clicked, r.delivered)} of delivered`} />
              <Stat label="Unsubscribed" value={fmtInt(r.unsubscribed)} sub="now excluded from future sends" />
              <Stat label="Awaiting report" value={fmtInt(r.awaiting_report)} sub="sent, nothing reported yet" />
            </div>
            <p className="mt-3 text-xs text-slate-500">
              {fmtInt(events.applied)} {events.applied === 1 ? 'report' : 'reports'} applied.{' '}
              {events.quarantined > 0 && (
                <>
                  {fmtInt(events.quarantined)} {events.quarantined === 1 ? 'report was' : 'reports were'} not applied because {events.quarantined === 1 ? 'it' : 'they'} could not be verified:{' '}
                  {Object.entries(events.quarantine_reasons).map(([k, n]) => `${fmtInt(n)} ${k}`).join('; ')}.
                </>
              )}{' '}
              Duplicate reports are counted once, and late or out-of-order reports are applied in the right order.
            </p>
          </Card>
        </>
      )}

      <Card title="Recipients" className="mt-6">
        {recipients.isPending ? (
          <LoadingState />
        ) : recipients.isError ? (
          <ErrorState error={recipients.error} onRetry={() => recipients.refetch()} />
        ) : (
          <>
            <TableWrap>
              <table className="min-w-full text-sm">
                <thead>
                  <tr className="border-b border-slate-200 text-left text-xs text-slate-500 uppercase">
                    <th className="px-4 py-2">#</th><th className="px-4 py-2">Contact</th><th className="px-4 py-2">Address</th><th className="px-4 py-2">Dispatch</th><th className="px-4 py-2">Reports</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {recipients.data.map((x) => (
                    <tr key={x.seq}>
                      <td className="tabular px-4 py-1.5 text-slate-400">{x.seq}</td>
                      <td className="px-4 py-1.5">{x.full_name ?? '—'} <span className="text-xs text-slate-400">{x.external_id}</span></td>
                      <td className="px-4 py-1.5 text-slate-700">{x.address}</td>
                      <td className="px-4 py-1.5">
                        <Badge tone={x.dispatch_status === 'dispatched' ? 'green' : x.dispatch_status === 'pending' ? 'blue' : 'amber'}>{x.dispatch_status}</Badge>
                        {x.skip_reason && <span className="ml-1 text-xs text-slate-500">{x.skip_reason}</span>}
                      </td>
                      <td className="px-4 py-1.5">
                        <div className="flex flex-wrap gap-1">
                          {x.bounced && <Badge tone="red">bounced</Badge>}
                          {x.delivered && !x.bounced && <Badge tone="green">delivered</Badge>}
                          {x.opened && <Badge tone="brand">opened</Badge>}
                          {x.unsubscribed && <Badge tone="amber">unsubscribed</Badge>}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </TableWrap>
            <div className="mt-3 flex items-center justify-between text-sm text-slate-500">
              <span className="tabular">{fmtInt(page * 50 + 1)}–{fmtInt(page * 50 + recipients.data.length)} of {fmtInt(send.recipient_count)}</span>
              <div className="flex gap-2">
                <Button size="sm" variant="secondary" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</Button>
                <Button size="sm" variant="secondary" disabled={(page + 1) * 50 >= send.recipient_count} onClick={() => setPage((p) => p + 1)}>Next</Button>
              </div>
            </div>
          </>
        )}
      </Card>
    </>
  );
}
