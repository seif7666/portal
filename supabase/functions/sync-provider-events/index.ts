// Pulls delivery reports from the provider for every batch whose reports may
// still change, and hands them to svc_ingest_provider_events, which is
// idempotent (event ids), order-independent (facts only get set) and trusts
// only recipient ids we issued for that exact batch.
//
// The provider's cursor is used for incremental reads, but because reports
// can land late behind it, each open batch is also re-read in full every ten
// minutes. Runs every minute from pg_cron, and on demand from the portal.
import { corsHeaders, env, identify, json, serviceClient } from '../_shared/common.ts';

const TIME_BUDGET_MS = 45_000;
const MAX_PAGES_PER_BATCH = 50;
const CONCURRENCY = 6;

interface ChunkToSync {
  send_id: string;
  chunk_no: number;
  provider_batch_id: string;
  events_cursor: string | null;
  full_resync: boolean;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  const caller = await identify(req);
  if (!caller) return json({ error: 'not permitted' }, 401);

  const svc = serviceClient();
  const { data, error } = await svc.rpc('svc_chunks_to_sync', { p_limit: 100 });
  if (error) return json({ error: error.message }, 500);

  let chunks = (data as ChunkToSync[]) ?? [];
  if (caller.kind === 'user') {
    // a member's "refresh" only touches their own brand's sends
    const { data: mine } = await caller.client.from('sends').select('id').in('id', [...new Set(chunks.map((c) => c.send_id))]);
    const allowed = new Set((mine ?? []).map((s: { id: string }) => s.id));
    chunks = chunks.filter((c) => allowed.has(c.send_id));
  }

  const started = Date.now();
  const totals = { batches: 0, pages: 0, applied: 0, quarantined: 0, duplicates: 0, errors: 0 };

  // a few batches in parallel: well inside the provider's 600 requests/minute
  const queue = [...chunks];
  const worker = async () => {
    for (let chunk = queue.shift(); chunk && Date.now() - started < TIME_BUDGET_MS; chunk = queue.shift()) {
      totals.batches++;
      await syncChunk(chunk);
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));

  async function syncChunk(chunk: ChunkToSync) {
    const full = chunk.full_resync;
    let since: string | null = full ? null : chunk.events_cursor;

    for (let page = 0; page < MAX_PAGES_PER_BATCH; page++) {
      const url = new URL(`${env('DISPATCHER_BASE_URL')}/v1/messages/${encodeURIComponent(chunk.provider_batch_id)}/events`);
      if (since) url.searchParams.set('since', since);
      let payload: { events?: unknown; next_cursor?: unknown; has_more?: unknown };
      try {
        const res = await fetch(url, {
          headers: { Authorization: `Bearer ${env('DISPATCHER_API_KEY')}` },
          signal: AbortSignal.timeout(20_000),
        });
        if (!res.ok) {
          console.error('events fetch', chunk.provider_batch_id, res.status, (await res.text()).slice(0, 200));
          totals.errors++;
          return;
        }
        payload = await res.json();
      } catch (e) {
        console.error('events fetch failed', chunk.provider_batch_id, e);
        totals.errors++;
        return;
      }

      const events = Array.isArray(payload.events) ? payload.events : [];
      const nextCursor = typeof payload.next_cursor === 'string' && payload.next_cursor ? payload.next_cursor : null;
      const hasMore = payload.has_more === true;

      const { data: result, error: ingestError } = await svc.rpc('svc_ingest_provider_events', {
        p_send_id: chunk.send_id,
        p_chunk_no: chunk.chunk_no,
        p_events: events,
        p_next_cursor: nextCursor,
        p_has_more: hasMore,
        p_full_resync: full,
      });
      if (ingestError) {
        console.error('ingest failed', chunk.provider_batch_id, ingestError.message);
        totals.errors++;
        return;
      }
      totals.pages++;
      totals.applied += result?.applied ?? 0;
      totals.quarantined += result?.quarantined ?? 0;
      totals.duplicates += result?.duplicates ?? 0;

      if (!hasMore || !nextCursor || nextCursor === since) return;
      since = nextCursor;
    }
  }

  return json({ ok: true, ...totals, elapsed_ms: Date.now() - started });
});
