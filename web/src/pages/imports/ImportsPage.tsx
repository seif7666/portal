import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router';
import { supabase } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { fmtDateTime, fmtInt } from '../../lib/format';
import { Card, EmptyState, ErrorState, LoadingState, PageHeader, TableWrap } from '../../components/ui';
import { KIND_LABEL, RunStatusBadge, type ImportRun } from './importStatus';
import { NewImport } from './NewImport';

export function ImportsPage() {
  const brand = useBrand();
  const runs = useQuery({
    queryKey: ['import_runs', brand.brand_id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('import_runs')
        .select('*')
        .eq('brand_id', brand.brand_id)
        .order('started_at', { ascending: false })
        .limit(100);
      if (error) throw error;
      return data as ImportRun[];
    },
  });

  return (
    <>
      <PageHeader
        title="Imports"
        description="Every file loaded into this portal, what was accepted, and exactly which rows were not loaded and why. Loading the same export twice is safe: nothing is duplicated."
      />

      {brand.isOwner ? (
        <NewImport />
      ) : (
        <p className="mb-6 rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm text-slate-600">
          You have view-only access. Only the brand owner can load new files.
        </p>
      )}

      <Card title="Import history" className="mt-6">
        {runs.isPending ? (
          <LoadingState />
        ) : runs.isError ? (
          <ErrorState error={runs.error} onRetry={() => runs.refetch()} />
        ) : runs.data.length === 0 ? (
          <EmptyState title="No files imported yet">{brand.isOwner ? 'Choose a file above to load your first export.' : 'The owner has not loaded any data yet.'}</EmptyState>
        ) : (
          <TableWrap>
            <table className="min-w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 text-left text-xs font-medium tracking-wide text-slate-500 uppercase">
                  <th className="px-4 py-2">File</th>
                  <th className="px-4 py-2">Type</th>
                  <th className="px-4 py-2">Status</th>
                  <th className="px-4 py-2 text-right">Rows</th>
                  <th className="px-4 py-2 text-right">New</th>
                  <th className="px-4 py-2 text-right">Updated</th>
                  <th className="px-4 py-2 text-right">Unchanged</th>
                  <th className="px-4 py-2 text-right">Not loaded</th>
                  <th className="px-4 py-2">Started</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {runs.data.map((run) => (
                  <tr key={run.id} className="hover:bg-slate-50">
                    <td className="max-w-[16rem] truncate px-4 py-2.5 font-medium">
                      <Link to={run.id} className="text-brand-700 hover:underline">{run.file_name}</Link>
                    </td>
                    <td className="px-4 py-2.5 whitespace-nowrap text-slate-600">{KIND_LABEL[run.kind]}</td>
                    <td className="px-4 py-2.5"><RunStatusBadge run={run} /></td>
                    <td className="tabular px-4 py-2.5 text-right">{fmtInt(run.rows_total)}</td>
                    <td className="tabular px-4 py-2.5 text-right">{fmtInt(run.rows_inserted)}</td>
                    <td className="tabular px-4 py-2.5 text-right">{fmtInt(run.rows_updated)}</td>
                    <td className="tabular px-4 py-2.5 text-right">{fmtInt(run.rows_unchanged)}</td>
                    <td className={`tabular px-4 py-2.5 text-right ${run.rows_rejected ? 'font-medium text-red-700' : ''}`}>{fmtInt(run.rows_rejected)}</td>
                    <td className="px-4 py-2.5 whitespace-nowrap text-slate-500">{fmtDateTime(run.started_at, brand.brand_timezone)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </TableWrap>
        )}
      </Card>
    </>
  );
}
