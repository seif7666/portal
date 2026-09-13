// Drives one import: start -> chunks -> finish. Used by the Imports page and
// by scripts/seed.ts, so the initial load goes through exactly the same path
// (and leaves the same audit trail) as a marketer's upload.
import type { SupabaseClient } from '@supabase/supabase-js';
import type { ImportKind, ParsedFile } from './readFile';

export interface ImportProgress {
  phase: 'starting' | 'loading' | 'finishing' | 'done' | 'failed';
  rowsSent: number;
  rowsTotal: number;
  runId?: string;
  message?: string;
}

export interface ImportOptions {
  brandId: string;
  kind: ImportKind;
  fileName: string;
  file: ParsedFile;
  /** ISO date/time the export was produced. Newer exports win over older ones. */
  exportedAt: string;
  onProgress?: (p: ImportProgress) => void;
  signal?: AbortSignal;
}

// Sized to keep each RPC well inside PostgREST's statement timeout.
const CHUNK_SIZE: Record<ImportKind, number> = { contacts: 1000, campaigns: 500, events: 2000, send_log: 500 };
const MAX_ATTEMPTS = 4;

export class ImportError extends Error {
  readonly runId?: string;
  constructor(message: string, runId?: string) {
    super(message);
    this.runId = runId;
  }
}

export async function runImport(supabase: SupabaseClient, opts: ImportOptions) {
  const { file, kind } = opts;
  const report = (p: Omit<ImportProgress, 'rowsTotal'>) => opts.onProgress?.({ ...p, rowsTotal: file.rows.length });

  report({ phase: 'starting', rowsSent: 0 });
  const { data: start, error: startError } = await supabase.rpc('import_start', {
    p_brand_id: opts.brandId,
    p_kind: kind,
    p_file_name: opts.fileName,
    p_file_sha256: file.sha256,
    p_file_size_bytes: file.sizeBytes,
    p_encoding: file.encoding,
    p_delimiter: file.delimiter,
    p_header: file.header,
    p_expected_rows: file.rows.length,
    // a bare date means that calendar day, not midnight in whatever zone the server or browser is in
    p_source_exported_at: /^\d{4}-\d{2}-\d{2}$/.test(opts.exportedAt) ? `${opts.exportedAt}T00:00:00Z` : opts.exportedAt,
  });
  if (startError) throw new ImportError(startError.message);
  const runId: string = start.run_id;
  if (start.status === 'failed') {
    report({ phase: 'failed', rowsSent: 0, runId, message: `Missing columns: ${start.missing_columns.join(', ')}` });
    return { runId, start };
  }

  const size = CHUNK_SIZE[kind];
  try {
    for (let chunkNo = 0, offset = 0; offset < file.rows.length; chunkNo++, offset += size) {
      if (opts.signal?.aborted) throw new ImportError('Import cancelled', runId);
      const rows = file.rows.slice(offset, offset + size);
      await withRetry(async () => {
        // Retrying the same chunk number is safe: the server returns the stored result.
        const { error } = await supabase.rpc('import_chunk', { p_run_id: runId, p_chunk_no: chunkNo, p_rows: rows });
        if (error) throw error;
      });
      report({ phase: 'loading', rowsSent: offset + rows.length, runId });
    }

    report({ phase: 'finishing', rowsSent: file.rows.length, runId });
    const { data: run, error: finishError } = await supabase.rpc('import_finish', { p_run_id: runId });
    if (finishError) throw finishError;
    report({ phase: 'done', rowsSent: file.rows.length, runId });
    return { runId, start, run };
  } catch (e) {
    const message = e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e);
    await supabase.rpc('import_abort', { p_run_id: runId, p_reason: message });
    report({ phase: 'failed', rowsSent: 0, runId, message });
    throw new ImportError(message, runId);
  }
}

async function withRetry(fn: () => Promise<void>) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      const code = (e as { code?: string })?.code ?? '';
      // Validation / permission errors won't fix themselves; network and timeouts might.
      const permanent = /^(22|23|42|55)/.test(code);
      if (permanent || attempt >= MAX_ATTEMPTS) throw e;
      await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
    }
  }
}
