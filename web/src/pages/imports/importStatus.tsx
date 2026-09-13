import { Badge } from '../../components/ui';

export interface ImportRun {
  id: string;
  kind: 'contacts' | 'campaigns' | 'events' | 'send_log';
  file_name: string;
  file_sha256: string;
  file_size_bytes: number;
  encoding: string;
  delimiter: string;
  header: string[];
  source_exported_at: string;
  status: 'running' | 'completed' | 'failed';
  expected_rows: number;
  rows_total: number;
  rows_inserted: number;
  rows_updated: number;
  rows_unchanged: number;
  rows_superseded: number;
  rows_rejected: number;
  rows_warned: number;
  blank_lines: number;
  failure_reason: string | null;
  started_at: string;
  finished_at: string | null;
  last_activity_at: string;
}

export const KIND_LABEL: Record<ImportRun['kind'], string> = {
  contacts: 'Contacts',
  campaigns: 'Campaigns',
  events: 'Engagement events',
  send_log: 'Send log',
};

/** A run with no activity for 10 minutes was abandoned (tab closed, network lost). */
export function effectiveStatus(run: ImportRun): 'running' | 'completed' | 'failed' | 'interrupted' {
  if (run.status === 'running' && Date.now() - new Date(run.last_activity_at).getTime() > 10 * 60_000) return 'interrupted';
  return run.status;
}

export function RunStatusBadge({ run }: { run: ImportRun }) {
  const s = effectiveStatus(run);
  if (s === 'completed') return run.rows_rejected > 0 ? <Badge tone="amber">Completed with rejections</Badge> : <Badge tone="green">Completed</Badge>;
  if (s === 'running') return <Badge tone="blue">Loading…</Badge>;
  if (s === 'interrupted') return <Badge tone="red">Interrupted</Badge>;
  return <Badge tone="red">Failed</Badge>;
}
