// Posts approved sends to the messaging provider, one frozen chunk at a time.
//
// Called by the portal right after an owner approves (for an immediate start)
// and by pg_cron every minute (to resume anything interrupted). Running twice
// at once is safe: chunks are claimed with a lease under a row lock, and every
// request carries Idempotency-Key = "<send id>:<chunk no>" with a byte-identical
// body, which the provider dedupes.
import { corsHeaders, env, identify, json, serviceClient, UUID_RE } from '../_shared/common.ts';

const TIME_BUDGET_MS = 45_000;
const REQUEST_TIMEOUT_MS = 20_000;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const caller = await identify(req);
  if (!caller) return json({ error: 'not permitted' }, 401);
  if (caller.kind === 'user' && caller.role !== 'owner') return json({ error: 'only owners can send' }, 403);

  const input = await req.json().catch(() => ({}));
  const svc = serviceClient();
  let sendIds: string[];

  if (caller.kind === 'user') {
    const sendId = String(input?.send_id ?? '');
    if (!UUID_RE.test(sendId)) return json({ error: 'send_id required' }, 400);
    // RLS: the user's own client only sees their brand's sends
    const { data: send } = await caller.client.from('sends').select('id,status').eq('id', sendId).maybeSingle();
    if (!send) return json({ error: 'not found' }, 404);
    sendIds = [send.id];
  } else {
    const { data, error } = await svc.rpc('svc_sends_to_dispatch');
    if (error) return json({ error: error.message }, 500);
    sendIds = (data as string[]) ?? [];
  }

  const started = Date.now();
  const report: Record<string, { dispatched: number; retrying: number; failed: number; empty: number }> = {};

  for (const sendId of sendIds) {
    const r = (report[sendId] = { dispatched: 0, retrying: 0, failed: 0, empty: 0 });
    while (Date.now() - started < TIME_BUDGET_MS) {
      const { data: claim, error: claimError } = await svc.rpc('svc_claim_chunk', { p_send_id: sendId, p_lease_seconds: 60 });
      if (claimError) {
        console.error('claim failed', sendId, claimError.message);
        break;
      }
      if (!claim) break; // nothing left to do for this send right now
      if (claim.empty) {
        r.empty++;
        continue;
      }

      let status = 0;
      let body: unknown = {};
      let errorText: string | null = null;
      try {
        const res = await fetch(`${env('DISPATCHER_BASE_URL')}/v1/messages`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${env('DISPATCHER_API_KEY')}`,
            'Content-Type': 'application/json',
            'Idempotency-Key': claim.idempotency_key,
          },
          body: JSON.stringify(claim.body),
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
        status = res.status;
        const text = await res.text();
        try {
          body = JSON.parse(text);
        } catch {
          body = {};
        }
        if (!res.ok) errorText = `HTTP ${res.status}: ${text.slice(0, 300)}`;
      } catch (e) {
        errorText = e instanceof Error ? e.message : String(e);
      }

      const { data: result, error: recordError } = await svc.rpc('svc_record_chunk_result', {
        p_send_id: sendId,
        p_chunk_no: claim.chunk_no,
        p_http_status: status,
        p_response: body && typeof body === 'object' ? body : {},
        p_error: errorText,
      });
      if (recordError) {
        // The lease expires and the chunk is retried with the same key: no double send.
        console.error('record failed', sendId, claim.chunk_no, recordError.message);
        break;
      }
      if (result?.dispatched) r.dispatched++;
      else if (result?.retry) r.retrying++;
      else if (result?.failed) r.failed++;
      if (result?.retry) break; // back off; the scheduler picks it up after next_attempt_at
    }
  }

  return json({ ok: true, sends: report, elapsed_ms: Date.now() - started });
});
