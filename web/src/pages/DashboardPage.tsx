import { Link } from 'react-router';
import { useBrand } from '../lib/auth';
import { useCampaignPerformance, useDashboardSummary, useSignupsPerDay, type DashboardSummary } from '../lib/queries';
import { fmtDate, fmtDateTime, fmtInt, fmtPct } from '../lib/format';
import { Card, EmptyState, ErrorState, LoadingState, PageHeader, Stat } from '../components/ui';
import { SignupsChart } from '../components/SignupsChart';
import { CampaignTable } from './CampaignsPage';

export function DashboardPage() {
  const brand = useBrand();
  const summary = useDashboardSummary(brand.brand_id);
  const signups = useSignupsPerDay(brand.brand_id);
  const campaigns = useCampaignPerformance(brand.brand_id);

  return (
    <>
      <PageHeader
        title="Dashboard"
        description={
          summary.data
            ? `Figures as of ${fmtDateTime(summary.data.computed_at, brand.brand_timezone)} (${brand.brand_timezone}).`
            : undefined
        }
      />

      {summary.isPending ? (
        <LoadingState label="Counting contacts…" />
      ) : summary.isError ? (
        <ErrorState error={summary.error} onRetry={() => summary.refetch()} />
      ) : summary.data.contacts_in_database === 0 ? (
        <EmptyState title="No contacts yet">
          {brand.isOwner ? <>Load a contacts export on the <Link className="text-brand-700 underline" to="../imports">Imports</Link> page.</> : 'The owner has not loaded any data yet.'}
        </EmptyState>
      ) : (
        <SummaryTiles s={summary.data} />
      )}

      <div className="mt-6 grid gap-6 xl:grid-cols-5">
        <Card title="Why some customers can't be contacted" className="xl:col-span-2">
          {summary.data ? <Waterfall s={summary.data} /> : summary.isError ? <ErrorState error={summary.error} /> : <LoadingState />}
        </Card>

        <Card title="Signups per day, last 30 days" className="xl:col-span-3">
          {signups.isPending ? (
            <LoadingState />
          ) : signups.isError ? (
            <ErrorState error={signups.error} onRetry={() => signups.refetch()} />
          ) : (
            <>
              <p className="mb-2 text-xs text-slate-500">
                {fmtDate(signups.data.from + 'T12:00:00Z', 'UTC')} – {fmtDate(signups.data.to + 'T12:00:00Z', 'UTC')}, days in {signups.data.timezone} time, today included.{' '}
                <span className="font-medium text-slate-700">{fmtInt(signups.data.total_in_window)} signups</span> in this window.
              </p>
              {signups.data.total_in_window === 0 ? (
                <EmptyState title="No signups in the last 30 days">
                  The most recent signup date in this brand's data is {fmtDate(signups.data.latest_signup_at, brand.brand_timezone)}. Newer signups appear here after a newer contacts export is loaded.
                </EmptyState>
              ) : (
                <SignupsChart data={signups.data} />
              )}
              <p className="mt-3 text-xs text-slate-500">
                Counted by each contact's signup date, including contacts later deleted or unsubscribed.
                {signups.data.contacts_without_signup_date > 0 && ` ${fmtInt(signups.data.contacts_without_signup_date)} contacts have no readable signup date and are not shown.`}
              </p>
            </>
          )}
        </Card>
      </div>

      <Card title="Campaign performance" className="mt-6" actions={<Link to="../campaigns" className="text-sm text-brand-700 hover:underline">All campaigns →</Link>}>
        {campaigns.isPending ? (
          <LoadingState />
        ) : campaigns.isError ? (
          <ErrorState error={campaigns.error} onRetry={() => campaigns.refetch()} />
        ) : campaigns.data.length === 0 ? (
          <EmptyState title="No campaigns yet" />
        ) : (
          <>
            <CampaignTable rows={campaigns.data.slice(0, 8)} compact />
            {campaigns.data.length > 8 && (
              <p className="mt-3 text-sm text-slate-500">
                Showing the 8 most recent of {fmtInt(campaigns.data.length)} campaigns. <Link to="../campaigns" className="text-brand-700 hover:underline">See all</Link>
              </p>
            )}
          </>
        )}
      </Card>
    </>
  );
}

function SummaryTiles({ s }: { s: DashboardSummary }) {
  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <Stat
        label="Total customers"
        value={fmtInt(s.total_customers)}
        sub={s.deleted ? `${fmtInt(s.deleted)} deleted contacts not included` : 'no deleted contacts'}
        definition="Distinct contacts (one per external id) that are not marked deleted. Duplicate rows in exports are counted once; rows rejected at import are not counted."
      />
      <Stat
        label="Contactable"
        value={fmtInt(s.contactable_any)}
        sub={`${fmtPct(s.contactable_any, s.total_customers)} of customers, on at least one channel`}
        definition="Not deleted, status active, marketing consent explicitly given (blank counts as no), not suppressed by date, never unsubscribed or complained (from any campaign, any channel), and a valid email or phone that has not bounced."
      />
      <Stat
        label="Reachable by email"
        value={fmtInt(s.contactable_email)}
        sub={fmtPct(s.contactable_email, s.total_customers) + ' of customers'}
        definition="Contactable, with a valid email address that has not bounced."
      />
      <Stat
        label="Reachable by SMS"
        value={fmtInt(s.contactable_sms)}
        sub={fmtPct(s.contactable_sms, s.total_customers) + ' of customers'}
        definition="Contactable, with a phone number we could read as a full international number, and that number has not bounced. Numbers in unrecognised formats are not guessed."
      />
    </div>
  );
}

function Waterfall({ s }: { s: DashboardSummary }) {
  const steps = [
    { label: 'Status is not active', hint: 'unsubscribed, bounced or pending in the export', n: s.excluded_status },
    { label: 'No marketing consent', hint: 'consent is "no" or was left blank', n: s.excluded_no_consent },
    { label: 'Suppressed until a future date', hint: 'suppressed_until has not passed', n: s.excluded_suppressed },
    { label: 'Unsubscribed or complained', hint: 'an unsubscribe or complaint event on any campaign', n: s.excluded_opted_out },
    { label: 'No usable email or phone', hint: 'missing, invalid, or bounced', n: s.excluded_no_address },
  ];
  const max = s.total_customers || 1;
  return (
    <div>
      <p className="mb-4 text-xs text-slate-500">
        Each customer is counted once, at the first rule they fail, in this order, so the rows add up:{' '}
        <span className="tabular font-medium text-slate-700">
          {fmtInt(s.total_customers)} − {fmtInt(steps.reduce((a, x) => a + x.n, 0))} = {fmtInt(s.contactable_any)} contactable
        </span>
        .
      </p>
      <ul className="space-y-3">
        {steps.map((x) => (
          <li key={x.label}>
            <div className="flex items-baseline justify-between gap-3 text-sm">
              <span className="text-slate-700">{x.label}</span>
              <span className="tabular font-medium text-slate-900">{fmtInt(x.n)}</span>
            </div>
            <div className="mt-1 h-2 rounded-full bg-slate-100" title={`${fmtInt(x.n)} of ${fmtInt(s.total_customers)} customers`}>
              <div className="h-2 rounded-full bg-slate-400" style={{ width: `${(x.n / max) * 100}%` }} />
            </div>
            <p className="mt-0.5 text-xs text-slate-500">{x.hint}</p>
          </li>
        ))}
        <li className="border-t border-slate-100 pt-3">
          <div className="flex items-baseline justify-between gap-3 text-sm">
            <span className="font-medium text-slate-900">Contactable</span>
            <span className="tabular font-semibold text-slate-900">{fmtInt(s.contactable_any)}</span>
          </div>
          <div className="mt-1 h-2 rounded-full bg-slate-100">
            <div className="h-2 rounded-full bg-brand-600" style={{ width: `${(s.contactable_any / max) * 100}%` }} />
          </div>
        </li>
      </ul>
    </div>
  );
}
