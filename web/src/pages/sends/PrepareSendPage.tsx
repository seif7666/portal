// Owner flow: prepare (freeze the audience) -> review exactly who -> confirm.
// The number on the confirm button is the number the server approves: the
// approval call carries the count and a hash of the frozen list, and is
// refused if either changed.
import { useEffect, useState } from 'react';
import { Link, Navigate, useNavigate, useParams } from 'react-router';
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, errorMessage } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { useCampaignPerformance } from '../../lib/queries';
import { fmtInt } from '../../lib/format';
import { Badge, Button, Card, EmptyState, ErrorState, LoadingState, PageHeader, TableWrap } from '../../components/ui';
import { NotFoundPage } from '../StatusPages';

interface Prepared {
  send_id: string;
  channel: 'email' | 'sms';
  recipient_count: number;
  audience_hash: string;
  expires_at: string;
  chunk_count: number;
}

interface RecipientRow { seq: number; external_id: string; full_name: string | null; address: string }

export function PrepareSendPage() {
  const { campaignId } = useParams();
  const brand = useBrand();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const perf = useCampaignPerformance(brand.brand_id, campaignId);
  const [prepared, setPrepared] = useState<Prepared | null>(null);
  const [busy, setBusy] = useState<'preparing' | 'approving' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [inProgress, setInProgress] = useState<string | null>(null);
  const [ack, setAck] = useState(false);
  const [progress, setProgress] = useState<{ scanned: number; total: number; found: number } | null>(null);
  const [page, setPage] = useState(0);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  const recipients = useQuery({
    queryKey: ['send_recipients_page', prepared?.send_id, page],
    enabled: !!prepared,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('send_recipients_page', { p_send_id: prepared!.send_id, p_after_seq: page * 50, p_limit: 50 });
      if (error) throw error;
      return data as RecipientRow[];
    },
  });

  if (!brand.isOwner) return <Navigate to={`/b/${brand.brand_slug}/campaigns/${campaignId}`} replace />;
  if (perf.isPending) return <LoadingState />;
  if (perf.isError) return <ErrorState error={perf.error} onRetry={() => perf.refetch()} />;
  const campaign = perf.data[0];
  if (!campaign) return <NotFoundPage embedded />;

  const secondsLeft = prepared ? Math.max(0, Math.floor((new Date(prepared.expires_at).getTime() - now) / 1000)) : 0;
  const expired = !!prepared && secondsLeft === 0;

  async function prepare() {
    setBusy('preparing');
    setError(null);
    setInProgress(null);
    setAck(false);
    setPage(0);
    setPrepared(null);
    const { data, error } = await supabase.rpc('prepare_send', { p_campaign_id: campaignId });
    if (error) {
      setBusy(null);
      return setError(errorMessage(error));
    }
    if (data?.error === 'send_in_progress') {
      setBusy(null);
      setInProgress(data.send_id);
      return setError(data.message);
    }
    // Build the frozen audience in steps, each well inside the API time limit.
    setProgress({ scanned: 0, total: data.contacts_total, found: 0 });
    for (;;) {
      const step = await supabase.rpc('prepare_send_step', { p_send_id: data.send_id });
      if (step.error || step.data?.error) {
        setBusy(null);
        setProgress(null);
        return setError(step.data?.message ?? errorMessage(step.error));
      }
      setProgress({ scanned: step.data.contacts_scanned, total: step.data.contacts_total, found: step.data.recipient_count });
      if (step.data.done) {
        setPrepared(step.data as Prepared);
        break;
      }
    }
    setProgress(null);
    setBusy(null);
  }

  async function approve() {
    if (!prepared) return;
    setBusy('approving');
    setError(null);
    const { data, error } = await supabase.rpc('approve_send', {
      p_send_id: prepared.send_id,
      p_expected_count: prepared.recipient_count,
      p_audience_hash: prepared.audience_hash,
    });
    if (error || data?.error) {
      setBusy(null);
      return setError(data?.message ?? errorMessage(error));
    }
    // Start dispatch now; if this request is lost, the scheduler starts it within a minute.
    supabase.functions.invoke('dispatch-send', { body: { send_id: prepared.send_id } }).catch(() => {});
    await queryClient.invalidateQueries();
    navigate(`/b/${brand.brand_slug}/sends/${prepared.send_id}`);
  }

  return (
    <>
      <Link to={`/b/${brand.brand_slug}/campaigns/${campaign.campaign_id}`} className="text-sm text-brand-700 hover:underline">← {campaign.name}</Link>
      <PageHeader
        title={`Send “${campaign.name}”`}
        description={<span className="flex items-center gap-2"><Badge>{campaign.channel === 'email' ? 'Email' : 'SMS'}</Badge> {campaign.external_id}</span>}
      />

      {!prepared ? (
        <Card title="Step 1 · Build the audience">
          <p className="text-sm text-slate-600">
            The audience is every contact of {brand.brand_name} who is contactable by {campaign.channel === 'email' ? 'email' : 'SMS'} right now, using the same rules as the dashboard. The list is frozen when you prepare it, and you will see exactly who is on it before anything is sent.
          </p>
          {error && (
            <p role="alert" className="mt-4 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
              {error} {inProgress && <Link to={`/b/${brand.brand_slug}/sends/${inProgress}`} className="font-medium underline">View that send</Link>}
            </p>
          )}
          <Button className="mt-4" onClick={prepare} disabled={busy !== null}>{busy === 'preparing' ? 'Building audience…' : 'Prepare audience'}</Button>
          {progress && (
            <div className="mt-4">
              <div className="flex justify-between text-xs text-slate-500">
                <span>Checked {fmtInt(progress.scanned)} of {fmtInt(progress.total)} contacts · {fmtInt(progress.found)} contactable so far</span>
                <span className="tabular">{progress.total ? Math.floor((progress.scanned / progress.total) * 100) : 0}%</span>
              </div>
              <div className="mt-1 h-2 overflow-hidden rounded-full bg-slate-100">
                <div className="h-full bg-brand-600 transition-all" style={{ width: `${progress.total ? (progress.scanned / progress.total) * 100 : 0}%` }} />
              </div>
            </div>
          )}
        </Card>
      ) : prepared.recipient_count === 0 ? (
        <EmptyState title="Nobody to send to">
          No contact is currently contactable by {prepared.channel === 'email' ? 'email' : 'SMS'}. See the dashboard for the reasons contacts are excluded.
        </EmptyState>
      ) : (
        <div className="space-y-6">
          <Card title="Step 2 · Check who this goes to">
            <p className="text-sm text-slate-600">
              <span className="tabular text-2xl font-semibold text-slate-900">{fmtInt(prepared.recipient_count)}</span>{' '}
              {prepared.channel === 'email' ? 'email addresses' : 'phone numbers'}, one message each, sent in {fmtInt(prepared.chunk_count)} batches.
            </p>
            {recipients.isPending ? (
              <LoadingState />
            ) : recipients.isError ? (
              <ErrorState error={recipients.error} onRetry={() => recipients.refetch()} />
            ) : (
              <>
                <TableWrap>
                  <table className="mt-4 min-w-full text-sm">
                    <thead>
                      <tr className="border-b border-slate-200 text-left text-xs text-slate-500 uppercase">
                        <th className="px-4 py-2">#</th><th className="px-4 py-2">Contact</th><th className="px-4 py-2">{prepared.channel === 'email' ? 'Email' : 'Phone'}</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {recipients.data.map((r) => (
                        <tr key={r.seq}>
                          <td className="tabular px-4 py-1.5 text-slate-400">{r.seq}</td>
                          <td className="px-4 py-1.5">{r.full_name ?? '—'} <span className="text-xs text-slate-400">{r.external_id}</span></td>
                          <td className="px-4 py-1.5 text-slate-700">{r.address}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </TableWrap>
                <div className="mt-3 flex items-center justify-between text-sm text-slate-500">
                  <span className="tabular">{fmtInt(page * 50 + 1)}–{fmtInt(Math.min((page + 1) * 50, prepared.recipient_count))} of {fmtInt(prepared.recipient_count)}</span>
                  <div className="flex gap-2">
                    <Button size="sm" variant="secondary" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</Button>
                    <Button size="sm" variant="secondary" disabled={(page + 1) * 50 >= prepared.recipient_count} onClick={() => setPage((p) => p + 1)}>Next</Button>
                  </div>
                </div>
              </>
            )}
          </Card>

          <Card title="Step 3 · Confirm">
            <ul className="list-disc space-y-1 pl-5 text-sm text-slate-600">
              <li>This sends real messages through the messaging provider and cannot be undone.</li>
              <li>Pressing confirm more than once, or from another window, does not send twice.</li>
              <li>If someone unsubscribes before their batch goes out, they are skipped and the skip is recorded.</li>
            </ul>
            <label className="mt-4 flex items-start gap-2 text-sm text-slate-700">
              <input type="checkbox" className="mt-0.5" checked={ack} onChange={(e) => setAck(e.target.checked)} disabled={expired} />
              I have checked the audience and want to send {fmtInt(prepared.recipient_count)} messages.
            </label>
            {error && <p role="alert" className="mt-4 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}
            <div className="mt-4 flex flex-wrap items-center gap-3">
              <Button onClick={approve} disabled={!ack || expired || busy !== null}>
                {busy === 'approving' ? 'Confirming…' : `Confirm and send to ${fmtInt(prepared.recipient_count)}`}
              </Button>
              <Button variant="secondary" onClick={prepare} disabled={busy !== null}>Rebuild audience</Button>
              <span className={`text-xs ${expired ? 'text-red-700' : 'text-slate-500'}`}>
                {expired ? 'This confirmation expired. Rebuild the audience to continue.' : `Confirmation valid for ${Math.floor(secondsLeft / 60)}:${String(secondsLeft % 60).padStart(2, '0')}`}
              </span>
            </div>
          </Card>
        </div>
      )}
    </>
  );
}
