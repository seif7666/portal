import { useState, type FormEvent } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, errorMessage } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { fmtDateTime, fmtInt } from '../../lib/format';
import { Badge, Button, Card, EmptyState, ErrorState, LoadingState, TableWrap } from '../../components/ui';

interface LinkRow {
  id: string; created_by_email: string; created_at: string; expires_at: string; revoked_at: string | null;
  locked_until: string | null; view_count: number; last_viewed_at: string | null;
}

function generatePassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((b) => alphabet[b % alphabet.length]).join('').replace(/(.{4})(?!$)/g, '$1-');
}

function linkStatus(l: LinkRow) {
  if (l.revoked_at) return <Badge>Revoked</Badge>;
  if (new Date(l.expires_at) < new Date()) return <Badge>Expired</Badge>;
  if (l.locked_until && new Date(l.locked_until) > new Date()) return <Badge tone="red">Locked (too many wrong passwords)</Badge>;
  return <Badge tone="green">Active</Badge>;
}

export function ShareLinks({ campaignId }: { campaignId: string }) {
  const brand = useBrand();
  const queryClient = useQueryClient();
  const [password, setPassword] = useState('');
  const [days, setDays] = useState(30);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<{ url: string; password: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const links = useQuery({
    queryKey: ['share_links', campaignId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('shared_reports')
        .select('id,created_by_email,created_at,expires_at,revoked_at,locked_until,view_count,last_viewed_at')
        .eq('campaign_id', campaignId)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return data as LinkRow[];
    },
  });

  async function onCreate(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (password.length < 10) return setError('Use a password of at least 10 characters.');
    setBusy(true);
    const { data, error } = await supabase.rpc('create_share_link', { p_campaign_id: campaignId, p_password: password, p_expires_in_days: days });
    setBusy(false);
    if (error) return setError(errorMessage(error));
    setCreated({ url: `${window.location.origin}/r/${data.token}`, password });
    setPassword('');
    queryClient.invalidateQueries({ queryKey: ['share_links', campaignId] });
  }

  async function revoke(id: string) {
    const { error } = await supabase.rpc('revoke_share_link', { p_id: id });
    if (error) setError(errorMessage(error));
    queryClient.invalidateQueries({ queryKey: ['share_links', campaignId] });
  }

  return (
    <Card title="Share results with a client" className="mt-6">
      <p className="text-sm text-slate-600">
        Creates a password-protected page showing this campaign's results only: totals and rates, no contact details. Send the link and the password separately.
      </p>

      {brand.isOwner && (
        <form onSubmit={onCreate} className="mt-4 grid gap-3 sm:grid-cols-[1fr_auto_auto] sm:items-end">
          <label className="block">
            <span className="text-sm font-medium text-slate-700">Password for the link</span>
            <div className="mt-1 flex gap-2">
              <input
                type="text" value={password} onChange={(e) => setPassword(e.target.value)} maxLength={128} autoComplete="off"
                className="block w-full rounded-lg border border-slate-300 px-3 py-2 font-mono text-sm"
                placeholder="at least 10 characters"
              />
              <Button type="button" variant="secondary" onClick={() => setPassword(generatePassword())}>Generate</Button>
            </div>
          </label>
          <label className="block">
            <span className="text-sm font-medium text-slate-700">Valid for</span>
            <select value={days} onChange={(e) => setDays(Number(e.target.value))} className="mt-1 block rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
              {[7, 30, 90].map((d) => <option key={d} value={d}>{d} days</option>)}
            </select>
          </label>
          <Button type="submit" disabled={busy}>{busy ? 'Creating…' : 'Create link'}</Button>
        </form>
      )}
      {error && <p role="alert" className="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

      {created && (
        <div className="mt-4 rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-sm">
          <p className="font-medium text-emerald-900">Link created. Copy it now: the address cannot be shown again.</p>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <code className="min-w-0 flex-1 rounded bg-white px-2 py-1 text-xs break-all text-slate-800">{created.url}</code>
            <Button size="sm" variant="secondary" onClick={() => { navigator.clipboard.writeText(created.url); setCopied(true); }}>{copied ? 'Copied' : 'Copy link'}</Button>
          </div>
          <p className="mt-2 text-emerald-900">Password: <code className="rounded bg-white px-1.5 py-0.5 text-xs">{created.password}</code></p>
        </div>
      )}

      <div className="mt-6">
        {links.isPending ? (
          <LoadingState />
        ) : links.isError ? (
          <ErrorState error={links.error} onRetry={() => links.refetch()} />
        ) : links.data.length === 0 ? (
          <EmptyState title="No links shared for this campaign" />
        ) : (
          <TableWrap>
            <table className="min-w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 text-left text-xs text-slate-500 uppercase">
                  <th className="px-4 py-2">Status</th><th className="px-4 py-2">Created</th><th className="px-4 py-2">Expires</th><th className="px-4 py-2 text-right">Views</th><th className="px-4 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {links.data.map((l) => (
                  <tr key={l.id}>
                    <td className="px-4 py-2">{linkStatus(l)}</td>
                    <td className="px-4 py-2 text-slate-600">{fmtDateTime(l.created_at, brand.brand_timezone)} by {l.created_by_email}</td>
                    <td className="px-4 py-2 text-slate-600">{fmtDateTime(l.expires_at, brand.brand_timezone)}</td>
                    <td className="tabular px-4 py-2 text-right">{fmtInt(l.view_count)}</td>
                    <td className="px-4 py-2 text-right">
                      {brand.isOwner && !l.revoked_at && new Date(l.expires_at) > new Date() && (
                        <Button size="sm" variant="secondary" onClick={() => revoke(l.id)}>Revoke</Button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </TableWrap>
        )}
      </div>
    </Card>
  );
}
