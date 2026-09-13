import { useState } from 'react';
import { Link, useParams } from 'react-router';
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { fmtBytes, fmtDate, fmtDateTime, fmtInt } from '../../lib/format';
import { Badge, Button, Card, EmptyState, ErrorState, LoadingState, PageHeader, Stat, TableWrap } from '../../components/ui';
import { NotFoundPage } from '../StatusPages';
import { effectiveStatus, KIND_LABEL, RunStatusBadge, type ImportRun } from './importStatus';

const PAGE = 50;

interface IssueSummary { severity: 'error' | 'warning'; code: string; field: string | null; n: number; example_message: string; first_row: number | null }
interface Issue { id: number; row_number: number | null; severity: 'error' | 'warning'; code: string; field: string | null; message: string; raw: unknown }

export function ImportRunPage() {
  const { runId } = useParams();
  const brand = useBrand();
  const [filter, setFilter] = useState<{ severity?: string; code?: string }>({ severity: 'error' });
  const [page, setPage] = useState(0);

  const run = useQuery({
    queryKey: ['import_run', runId],
    queryFn: async () => {
      const { data, error } = await supabase.from('import_runs').select('*').eq('id', runId!).maybeSingle();
      if (error) throw error;
      return data as ImportRun | null;
    },
    refetchInterval: (q) => (q.state.data?.status === 'running' ? 3000 : false),
  });

  const summary = useQuery({
    queryKey: ['import_issue_summary', runId, run.data?.last_activity_at],
    enabled: !!run.data,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('import_issue_summary', { p_run_id: runId });
      if (error) throw error;
      return data as IssueSummary[];
    },
  });

  const issues = useQuery({
    queryKey: ['import_issues', runId, filter, page, run.data?.last_activity_at],
    enabled: !!run.data,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      let q = supabase
        .from('import_issues')
        .select('id,row_number,severity,code,field,message,raw', { count: 'exact' })
        .eq('run_id', runId!)
        .order('row_number', { ascending: true, nullsFirst: true })
        .order('id')
        .range(page * PAGE, page * PAGE + PAGE - 1);
      if (filter.severity) q = q.eq('severity', filter.severity);
      if (filter.code) q = q.eq('code', filter.code);
      const { data, error, count } = await q;
      if (error) throw error;
      return { rows: data as Issue[], count: count ?? 0 };
    },
  });

  if (run.isPending) return <LoadingState />;
  if (run.isError) return <ErrorState error={run.error} onRetry={() => run.refetch()} />;
  if (!run.data) return <NotFoundPage embedded />;

  const r = run.data;
  const status = effectiveStatus(r);
  const errors = summary.data?.filter((s) => s.severity === 'error').reduce((a, s) => a + Number(s.n), 0) ?? 0;
  const warnings = summary.data?.filter((s) => s.severity === 'warning').reduce((a, s) => a + Number(s.n), 0) ?? 0;

  return (
    <>
      <Link to=".." relative="path" className="text-sm text-brand-700 hover:underline">← All imports</Link>
      <PageHeader
        title={r.file_name}
        description={
          <span className="flex flex-wrap items-center gap-2">
            <RunStatusBadge run={r} />
            <span>{KIND_LABEL[r.kind]} · exported {fmtDate(r.source_exported_at)} · {fmtBytes(r.file_size_bytes)} · {r.encoding === 'utf-8' ? 'UTF-8' : 'Windows-1252'} · started {fmtDateTime(r.started_at, brand.brand_timezone)}</span>
          </span>
        }
      />

      {status === 'failed' && r.failure_reason && (
        <div role="alert" className="mb-6 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          <p className="font-medium">This import stopped before the end.</p>
          <p className="mt-1">{r.failure_reason}</p>
          <p className="mt-1">Rows counted below were loaded. Loading the same file again is safe and completes the rest without duplicates.</p>
        </div>
      )}
      {status === 'interrupted' && (
        <div role="alert" className="mb-6 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          This import was interrupted after {fmtInt(r.rows_total)} of {fmtInt(r.expected_rows)} rows. Load the same file again to finish: rows already loaded are recognised and not duplicated.
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <Stat label="Rows read" value={fmtInt(r.rows_total)} sub={r.blank_lines ? `+ ${fmtInt(r.blank_lines)} blank lines skipped` : `of ${fmtInt(r.expected_rows)} in file`} />
        <Stat label="New" value={fmtInt(r.rows_inserted)} />
        <Stat label="Updated" value={fmtInt(r.rows_updated)} />
        <Stat label="Unchanged" value={fmtInt(r.rows_unchanged)} sub="already loaded, identical" />
        <Stat label="Not applied" value={fmtInt(r.rows_superseded)} sub="a newer version was already loaded" />
        <Stat label="Not loaded" value={<span className={r.rows_rejected ? 'text-red-700' : ''}>{fmtInt(r.rows_rejected)}</span>} sub="rejected, see reasons below" />
      </div>

      <Card title="What didn't load cleanly, and why" className="mt-6">
        {summary.isPending ? (
          <LoadingState />
        ) : summary.isError ? (
          <ErrorState error={summary.error} onRetry={() => summary.refetch()} />
        ) : summary.data.length === 0 ? (
          <EmptyState title="Every row loaded cleanly" />
        ) : (
          <div className="space-y-2">
            <p className="text-sm text-slate-600">
              <span className="font-medium text-red-700">{fmtInt(errors)} rejected</span> (not stored) and{' '}
              <span className="font-medium text-amber-800">{fmtInt(warnings)} warnings</span> (stored, with the problem field cleaned or left empty). Click a reason to see the rows.
            </p>
            <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200">
              {summary.data.map((s) => {
                const active = filter.code === s.code && filter.severity === s.severity;
                return (
                  <li key={`${s.severity}-${s.code}-${s.field}`}>
                    <button
                      onClick={() => { setFilter(active ? { severity: s.severity } : { severity: s.severity, code: s.code }); setPage(0); }}
                      className={`flex w-full flex-wrap items-start gap-x-3 gap-y-1 px-3 py-2.5 text-left text-sm hover:bg-slate-50 ${active ? 'bg-brand-50/60' : ''}`}
                    >
                      <Badge tone={s.severity === 'error' ? 'red' : 'amber'}>{s.severity === 'error' ? 'Rejected' : 'Warning'}</Badge>
                      <span className="tabular w-16 font-semibold text-slate-800">{fmtInt(Number(s.n))}</span>
                      <span className="min-w-0 flex-1 text-slate-700">{s.example_message}</span>
                      <code className="text-xs text-slate-400">{s.code}</code>
                    </button>
                  </li>
                );
              })}
            </ul>
          </div>
        )}
      </Card>

      <Card
        title="Row details"
        className="mt-6"
        actions={
          <div className="flex gap-1">
            {[{ label: 'Rejected', severity: 'error' }, { label: 'Warnings', severity: 'warning' }, { label: 'All', severity: undefined }].map((f) => (
              <Button key={f.label} size="sm" variant={filter.severity === f.severity && !filter.code ? 'primary' : 'secondary'} onClick={() => { setFilter({ severity: f.severity }); setPage(0); }}>
                {f.label}
              </Button>
            ))}
          </div>
        }
      >
        {filter.code && <p className="mb-3 text-sm text-slate-600">Showing <code className="text-xs">{filter.code}</code> only.</p>}
        {issues.isPending ? (
          <LoadingState />
        ) : issues.isError ? (
          <ErrorState error={issues.error} onRetry={() => issues.refetch()} />
        ) : issues.data.rows.length === 0 ? (
          <EmptyState title="No rows match this filter" />
        ) : (
          <>
            <TableWrap>
              <table className="min-w-full text-sm">
                <thead>
                  <tr className="border-b border-slate-200 text-left text-xs font-medium tracking-wide text-slate-500 uppercase">
                    <th className="px-4 py-2">Line</th>
                    <th className="px-4 py-2">Problem</th>
                    <th className="px-4 py-2">Original row</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 align-top">
                  {issues.data.rows.map((i) => (
                    <tr key={i.id}>
                      <td className="tabular px-4 py-2 whitespace-nowrap text-slate-500">{i.row_number ?? '—'}</td>
                      <td className="min-w-[16rem] px-4 py-2">
                        <Badge tone={i.severity === 'error' ? 'red' : 'amber'}>{i.field ?? i.code}</Badge>
                        <p className="mt-1 text-slate-700">{i.message}</p>
                      </td>
                      <td className="px-4 py-2">
                        <code className="block max-w-xl text-xs break-all whitespace-pre-wrap text-slate-500">{formatRaw(i.raw)}</code>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </TableWrap>
            <div className="mt-4 flex items-center justify-between text-sm text-slate-500">
              <span className="tabular">{fmtInt(page * PAGE + 1)}–{fmtInt(page * PAGE + issues.data.rows.length)} of {fmtInt(issues.data.count)}</span>
              <div className="flex gap-2">
                <Button size="sm" variant="secondary" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</Button>
                <Button size="sm" variant="secondary" disabled={(page + 1) * PAGE >= issues.data.count} onClick={() => setPage((p) => p + 1)}>Next</Button>
              </div>
            </div>
          </>
        )}
      </Card>
    </>
  );
}

function formatRaw(raw: unknown) {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    return Object.entries(raw as Record<string, string>).map(([k, v]) => `${k}: ${v}`).join(' | ');
  }
  return JSON.stringify(raw);
}
