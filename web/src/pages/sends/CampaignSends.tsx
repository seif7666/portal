import { Link } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useBrand } from '../../lib/auth';
import { fmtDateTime, fmtInt } from '../../lib/format';
import { Card, EmptyState, ErrorState, LoadingState, TableWrap } from '../../components/ui';
import { sendStatusBadge } from './SendPage';

interface SendRow {
  id: string; status: string; recipient_count: number; approved_count: number | null; approved_by_email: string | null;
  approved_at: string | null; prepared_at: string; prepared_by_email: string; completed_at: string | null;
}

/** Sends of one campaign made through this portal, newest first. */
export function CampaignSends({ campaignId, campaignName }: { campaignId: string; campaignName: string }) {
  const brand = useBrand();
  const q = useQuery({
    queryKey: ['campaign_sends', campaignId],
    refetchInterval: 10_000,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('sends')
        .select('id,status,recipient_count,approved_count,approved_by_email,approved_at,prepared_at,prepared_by_email,completed_at')
        .eq('campaign_id', campaignId)
        .neq('status', 'cancelled')
        .order('prepared_at', { ascending: false })
        .limit(50);
      if (error) throw error;
      return data as SendRow[];
    },
  });

  return (
    <Card
      title="Sends from this portal"
      className="mt-6"
      actions={brand.isOwner ? (
        <Link to="send" className="inline-flex items-center rounded-lg bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">
          Send “{campaignName}”…
        </Link>
      ) : (
        <span className="text-xs text-slate-500">Only the owner can send</span>
      )}
    >
      {q.isPending ? (
        <LoadingState />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => q.refetch()} />
      ) : q.data.length === 0 ? (
        <EmptyState title="This campaign has not been sent from the portal yet" />
      ) : (
        <TableWrap>
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left text-xs text-slate-500 uppercase">
                <th className="px-4 py-2">Status</th><th className="px-4 py-2 text-right">Recipients</th><th className="px-4 py-2">Approved</th><th className="px-4 py-2" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {q.data.map((s) => (
                <tr key={s.id}>
                  <td className="px-4 py-2">{sendStatusBadge(s.status)}</td>
                  <td className="tabular px-4 py-2 text-right">{fmtInt(s.approved_count ?? s.recipient_count)}</td>
                  <td className="px-4 py-2 text-slate-600">
                    {s.approved_at ? `${s.approved_by_email}, ${fmtDateTime(s.approved_at, brand.brand_timezone)}` : `prepared ${fmtDateTime(s.prepared_at, brand.brand_timezone)}, not confirmed`}
                  </td>
                  <td className="px-4 py-2 text-right"><Link to={`/b/${brand.brand_slug}/sends/${s.id}`} className="text-brand-700 hover:underline">Details</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </TableWrap>
      )}
    </Card>
  );
}
