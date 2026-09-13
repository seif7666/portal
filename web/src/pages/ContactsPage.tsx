import { useEffect, useState } from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { useBrand } from '../lib/auth';
import { fetchContacts, useDashboardSummary, type ContactRow } from '../lib/queries';
import { fmtDate, fmtInt } from '../lib/format';
import { Badge, Button, Card, EmptyState, ErrorState, LoadingState, PageHeader, TableWrap } from '../components/ui';

const FILTERS = [
  { key: 'all', label: 'All' },
  { key: 'contactable', label: 'Contactable' },
  { key: 'not_contactable', label: 'Not contactable' },
  { key: 'deleted', label: 'Deleted' },
] as const;

export function ContactsPage() {
  const brand = useBrand();
  const [input, setInput] = useState('');
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<(typeof FILTERS)[number]['key']>('all');
  const summary = useDashboardSummary(brand.brand_id);

  useEffect(() => {
    const t = setTimeout(() => setSearch(input.trim().slice(0, 100)), 300);
    return () => clearTimeout(t);
  }, [input]);

  const q = useInfiniteQuery({
    queryKey: ['contacts', brand.brand_id, search, filter],
    initialPageParam: null as string | null,
    queryFn: ({ pageParam }) => fetchContacts(brand.brand_id, search, filter, pageParam),
    getNextPageParam: (last) => (last.length === 50 ? last[last.length - 1].external_id : undefined),
  });
  const rows = q.data?.pages.flat() ?? [];

  const counts: Record<string, number | undefined> = summary.data
    ? { all: summary.data.contacts_in_database, contactable: summary.data.contactable_any, not_contactable: summary.data.total_customers - summary.data.contactable_any, deleted: summary.data.deleted }
    : {};

  return (
    <>
      <PageHeader title="Contacts" description="Every contact loaded for this brand, with whether they can be reached and, if not, the first reason why." />

      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <input
          type="search"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Search name, email or ID…"
          maxLength={100}
          className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 focus:outline-none sm:max-w-sm"
        />
        <div className="flex flex-wrap gap-1">
          {FILTERS.map((f) => (
            <Button key={f.key} size="sm" variant={filter === f.key ? 'primary' : 'secondary'} onClick={() => setFilter(f.key)}>
              {f.label}
              {counts[f.key] != null && !search && <span className={clsx('tabular text-xs', filter === f.key ? 'text-brand-100' : 'text-slate-400')}>{fmtInt(counts[f.key])}</span>}
            </Button>
          ))}
        </div>
      </div>

      <Card>
        {q.isPending ? (
          <LoadingState label="Loading contacts…" />
        ) : q.isError ? (
          <ErrorState error={q.error} onRetry={() => q.refetch()} />
        ) : rows.length === 0 ? (
          <EmptyState title={search ? `No contacts match “${search}”` : 'No contacts in this view'}>
            {search ? 'Try part of a name, an email or an ID like CT-000123.' : undefined}
          </EmptyState>
        ) : (
          <>
            {/* phones: cards */}
            <ul className="divide-y divide-slate-100 md:hidden">
              {rows.map((c) => (
                <li key={c.id} className="py-3">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="truncate font-medium text-slate-900">{c.full_name ?? '—'}</p>
                      <p className="truncate text-sm text-slate-500">{c.email ?? 'no valid email'}</p>
                      <p className="text-xs text-slate-400">{c.external_id} · {c.phone_e164 ?? 'no valid phone'}</p>
                    </div>
                    <Reach c={c} />
                  </div>
                </li>
              ))}
            </ul>
            {/* larger screens: table */}
            <div className="hidden md:block">
              <TableWrap>
                <table className="min-w-full text-sm">
                  <thead>
                    <tr className="border-b border-slate-200 text-left text-xs font-medium tracking-wide text-slate-500 uppercase">
                      <th className="px-4 py-2">Contact</th>
                      <th className="px-4 py-2">Email</th>
                      <th className="px-4 py-2">Phone</th>
                      <th className="px-4 py-2">Location</th>
                      <th className="px-4 py-2">Signed up</th>
                      <th className="px-4 py-2">Status</th>
                      <th className="px-4 py-2">Consent</th>
                      <th className="px-4 py-2">Reachable</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {rows.map((c) => (
                      <tr key={c.id} className="hover:bg-slate-50">
                        <td className="px-4 py-2">
                          <p className="font-medium text-slate-900">{c.full_name ?? '—'}</p>
                          <p className="text-xs text-slate-500">{c.external_id}</p>
                        </td>
                        <td className="max-w-[16rem] truncate px-4 py-2 text-slate-700" title={c.email ?? undefined}>{c.email ?? <span className="text-slate-400">none / invalid</span>}</td>
                        <td className="px-4 py-2 whitespace-nowrap text-slate-700" title={c.phone_raw ? `as exported: ${c.phone_raw}` : undefined}>
                          {c.phone_e164 ?? <span className="text-slate-400">{c.phone_raw ? 'unreadable' : 'none'}</span>}
                        </td>
                        <td className="px-4 py-2 whitespace-nowrap text-slate-600">{[c.city, c.country].filter(Boolean).join(', ') || '—'}</td>
                        <td className="px-4 py-2 whitespace-nowrap text-slate-600">{fmtDate(c.signup_at, brand.brand_timezone)}</td>
                        <td className="px-4 py-2"><Badge tone={c.status === 'active' ? 'green' : 'slate'}>{c.status}</Badge></td>
                        <td className="px-4 py-2 text-slate-600">{c.consent_marketing == null ? <span className="text-slate-400">not stated</span> : c.consent_marketing ? 'Yes' : 'No'}</td>
                        <td className="px-4 py-2"><Reach c={c} /></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </TableWrap>
            </div>
            <div className="mt-4 flex items-center justify-between text-sm text-slate-500">
              <span className="tabular">Showing {fmtInt(rows.length)}{!q.hasNextPage ? ' (all)' : ''}</span>
              {q.hasNextPage && (
                <Button variant="secondary" size="sm" onClick={() => q.fetchNextPage()} disabled={q.isFetchingNextPage}>
                  {q.isFetchingNextPage ? 'Loading…' : 'Load 50 more'}
                </Button>
              )}
            </div>
          </>
        )}
      </Card>
    </>
  );
}

function Reach({ c }: { c: ContactRow }) {
  if (c.contactable_email || c.contactable_sms) {
    return (
      <div className="flex flex-wrap gap-1">
        {c.contactable_email && <Badge tone="green">Email</Badge>}
        {c.contactable_sms && <Badge tone="green">SMS</Badge>}
      </div>
    );
  }
  return <Badge tone={c.deleted_at ? 'slate' : 'amber'}>{c.not_contactable_reason ?? 'Not contactable'}</Badge>;
}
