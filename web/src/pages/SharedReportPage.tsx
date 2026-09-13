// Public page for a shared link. Knows nothing until the server has checked
// the token and password; then shows one campaign's aggregate results.
import { useEffect, useState, type FormEvent } from 'react';
import { useParams } from 'react-router';
import { supabase } from '../lib/supabase';
import { fmtDateTime, fmtInt, fmtPct } from '../lib/format';
import { Button, Stat } from '../components/ui';

interface Report {
  ok: true;
  generated_at: string;
  link_expires_at: string;
  brand_name: string;
  timezone: string;
  campaign: { name: string; reference: string; channel: 'email' | 'sms'; sent_at: string | null };
  reported: { sent: number | null; delivered: number | null; bounced: number | null; opens: number | null; clicks: number | null };
  measured: { openers: number; clickers: number; bounced: number; complained: number; unsubscribed: number; events_before_send_excluded: number } | null;
  portal_sends: { sends: number; recipients: number; sent: number; delivered: number; bounced: number; opened: number; clicked: number; unsubscribed: number; last_sent_at: string | null };
}

export function SharedReportPage() {
  const { token } = useParams();
  const [password, setPassword] = useState('');
  const [report, setReport] = useState<Report | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    // keep the tokenised URL out of referrers and search engines
    const metas = [
      Object.assign(document.createElement('meta'), { name: 'robots', content: 'noindex, nofollow' }),
      Object.assign(document.createElement('meta'), { name: 'referrer', content: 'no-referrer' }),
    ];
    metas.forEach((m) => document.head.appendChild(m));
    document.title = 'Campaign results';
    return () => metas.forEach((m) => m.remove());
  }, []);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { data, error } = await supabase.rpc('shared_report_open', { p_token: token ?? '', p_password: password });
    setBusy(false);
    if (error) return setError('Could not reach the server. Please try again.');
    if (!data?.ok) return setError(data?.error ?? 'This link or password is not valid.');
    setReport(data as Report);
    setPassword('');
  }

  if (!report) {
    return (
      <main className="flex min-h-full items-center justify-center px-4 py-12">
        <form onSubmit={onSubmit} className="w-full max-w-sm rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h1 className="text-lg font-semibold text-slate-900">Campaign results</h1>
          <p className="mt-1 text-sm text-slate-500">Enter the password you were given with this link.</p>
          <input
            type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoFocus maxLength={128} autoComplete="off"
            className="mt-4 block w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 focus:outline-none"
            aria-label="Password"
          />
          {error && <p role="alert" className="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}
          <Button type="submit" className="mt-4 w-full" disabled={busy || !password}>{busy ? 'Checking…' : 'View results'}</Button>
        </form>
      </main>
    );
  }

  const { campaign: c, reported: rep, measured: m, portal_sends: p } = report;
  return (
    <main className="mx-auto max-w-5xl px-4 py-8 sm:px-6">
      <p className="text-sm font-medium text-brand-700">{report.brand_name}</p>
      <h1 className="mt-1 text-2xl font-semibold text-slate-900">{c.name}</h1>
      <p className="mt-1 text-sm text-slate-500">
        {c.channel === 'email' ? 'Email' : 'SMS'} campaign {c.reference}
        {c.sent_at && ` · originally sent ${fmtDateTime(c.sent_at, report.timezone)}`} · figures as of {fmtDateTime(report.generated_at, report.timezone)} ({report.timezone})
      </p>

      {p.sends > 0 && (
        <section className="mt-8">
          <h2 className="text-sm font-semibold text-slate-800">Latest send{p.sends > 1 ? 's' : ''} ({fmtInt(p.sends)}, last on {fmtDateTime(p.last_sent_at, report.timezone)})</h2>
          <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
            <Stat label="Sent" value={fmtInt(p.sent)} />
            <Stat label="Delivered" value={fmtInt(p.delivered)} sub={`${fmtPct(p.delivered, p.sent)} of sent`} />
            <Stat label="Bounced" value={fmtInt(p.bounced)} sub={`${fmtPct(p.bounced, p.sent)} of sent`} />
            <Stat label="Opened" value={fmtInt(p.opened)} sub={`${fmtPct(p.opened, p.delivered)} of delivered`} />
            <Stat label="Clicked" value={fmtInt(p.clicked)} sub={`${fmtPct(p.clicked, p.delivered)} of delivered`} />
            <Stat label="Unsubscribed" value={fmtInt(p.unsubscribed)} />
          </div>
          <p className="mt-2 text-xs text-slate-500">Counts are people, from the messaging provider's delivery reports. Reports can keep arriving for a few days after a send.</p>
        </section>
      )}

      <section className="mt-8">
        <h2 className="text-sm font-semibold text-slate-800">Original campaign, as reported</h2>
        <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-5">
          <Stat label="Sent" value={fmtInt(rep.sent)} />
          <Stat label="Delivered" value={fmtInt(rep.delivered)} sub={`${fmtPct(rep.delivered, rep.sent)} of sent`} />
          <Stat label="Bounced" value={fmtInt(rep.bounced)} />
          <Stat label="Opens" value={fmtInt(rep.opens)} sub="total opens, may count a person more than once" />
          <Stat label="Clicks" value={fmtInt(rep.clicks)} />
        </div>
      </section>

      {m && (
        <section className="mt-8">
          <h2 className="text-sm font-semibold text-slate-800">Original campaign, recounted from engagement records (people)</h2>
          <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-5">
            <Stat label="Opened" value={fmtInt(m.openers)} />
            <Stat label="Clicked" value={fmtInt(m.clickers)} />
            <Stat label="Bounced" value={fmtInt(m.bounced)} />
            <Stat label="Complained" value={fmtInt(m.complained)} />
            <Stat label="Unsubscribed" value={fmtInt(m.unsubscribed)} />
          </div>
          {m.events_before_send_excluded > 0 && (
            <p className="mt-2 text-xs text-slate-500">{fmtInt(m.events_before_send_excluded)} records dated before the campaign was sent were excluded.</p>
          )}
        </section>
      )}

      <p className="mt-10 border-t border-slate-200 pt-4 text-xs text-slate-400">
        Shared privately by {report.brand_name} via Velocity Growth. This link expires {fmtDateTime(report.link_expires_at, report.timezone)}.
      </p>
    </main>
  );
}
