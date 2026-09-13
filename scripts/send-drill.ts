// Send-safety drill against the live project and provider (this SENDS real
// messages for the chosen campaign). Demonstrates:
//   1. confirm pressed 4x concurrently from two separate sessions -> one approval, one send
//   2. a dispatcher that crashes after posting a batch but before recording it
//      -> the scheduler re-sends the same key + body, the provider returns the
//         same batch, nobody is messaged twice
//   3. every chunk ends with exactly one provider batch, and the recorded
//      recipients match what was approved
//
//   npm run send-drill -- marrakech MAR-0001
import { createClient } from '@supabase/supabase-js';
import { account, type BrandSlug } from './accounts.ts';

const [brandArg, campaignExternalId] = process.argv.slice(2);
if (!brandArg || !campaignExternalId) throw new Error('usage: npm run send-drill -- <brand> <campaign external id>');
const brand = brandArg as BrandSlug;
const URL_ = process.env.VITE_SUPABASE_URL!;
const ANON = process.env.VITE_SUPABASE_ANON_KEY!;
const owner = account(brand, 'owner');

async function session() {
  const c = createClient(URL_, ANON, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email: owner.email, password: owner.password });
  if (error) throw error;
  return c;
}
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const a = await session();
const b = await session();
const svc = createClient(URL_, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });

const { data: campaign } = await a.from('campaigns').select('id,name,channel').eq('external_id', campaignExternalId).single();
log(`campaign ${campaignExternalId} "${campaign!.name}" (${campaign!.channel})`);

// --- 1. prepare, then confirm 4x concurrently from two sessions --------------
const { data: prepared, error: prepErr } = await a.rpc('prepare_send', { p_campaign_id: campaign!.id });
if (prepErr || prepared?.error) throw new Error(prepErr?.message ?? prepared.message);
log(`prepared send ${prepared.send_id}: ${prepared.recipient_count} recipients in ${prepared.chunk_count} chunks`);

const args = { p_send_id: prepared.send_id, p_expected_count: prepared.recipient_count, p_audience_hash: prepared.audience_hash };
const results = await Promise.all([a.rpc('approve_send', args), b.rpc('approve_send', args), a.rpc('approve_send', args), b.rpc('approve_send', args)]);
results.forEach((r, i) => log(`confirm #${i + 1} (session ${i % 2 ? 'B' : 'A'}):`, r.error ? `error ${r.error.message}` : `already_approved=${r.data.already_approved}`));
const fresh = results.filter((r) => !r.error && r.data.already_approved === false).length;
const { count: liveSends } = await a.from('sends').select('id', { count: 'exact', head: true }).eq('campaign_id', campaign!.id).in('status', ['approved', 'dispatching', 'completed', 'partially_failed', 'failed']).gte('approved_at', new Date(Date.now() - 60_000).toISOString());
log(`=> approvals recorded: ${fresh} (expected 1); approved sends for this campaign in the last minute: ${liveSends}`);

// wrong count / hash must be refused
const tampered = await b.rpc('approve_send', { ...args, p_expected_count: prepared.recipient_count + 1 });
log('confirm with a different count:', tampered.error ? `refused (${tampered.error.message})` : 'ACCEPTED (bug)');

// --- 2. crash after posting, before recording -----------------------------
const { data: claim } = await svc.rpc('svc_claim_chunk', { p_send_id: prepared.send_id, p_lease_seconds: 10 });
const res = await fetch(`${process.env.DISPATCHER_BASE_URL}/v1/messages`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${process.env.DISPATCHER_API_KEY}`, 'Content-Type': 'application/json', 'Idempotency-Key': claim.idempotency_key },
  body: JSON.stringify(claim.body),
});
const firstBatch = (await res.json()).batch_id;
log(`chunk ${claim.chunk_no} posted by a dispatcher that then "crashed": provider batch ${firstBatch}; result NOT recorded`);

// --- 3. let the real dispatcher run (also twice at once) --------------------
log('waiting for the lease to expire, then triggering two dispatchers at once…');
await sleep(12_000);
const [d1, d2] = await Promise.all([
  a.functions.invoke('dispatch-send', { body: { send_id: prepared.send_id } }),
  b.functions.invoke('dispatch-send', { body: { send_id: prepared.send_id } }),
]);
log('dispatcher A:', JSON.stringify(d1.data ?? d1.error?.message), ' dispatcher B:', JSON.stringify(d2.data ?? d2.error?.message));

for (let i = 0; i < 20; i++) {
  const { data: s } = await a.rpc('send_summary', { p_send_id: prepared.send_id });
  if (!['approved', 'dispatching'].includes(s.send.status)) break;
  await sleep(5000);
}

const { data: chunks } = await svc.from('send_chunks').select('chunk_no,status,attempts,provider_batch_id,recipient_count,accepted_count,last_error').eq('send_id', prepared.send_id).order('chunk_no');
console.table(chunks);
const crashed = chunks!.find((c) => c.chunk_no === claim.chunk_no)!;
log(`crashed chunk: recorded batch ${crashed.provider_batch_id} after ${crashed.attempts} attempts -> ${crashed.provider_batch_id === firstBatch ? 'SAME batch as the crashed post (no double send)' : 'DIFFERENT batch (bug)'}`);
const batches = chunks!.map((c) => c.provider_batch_id).filter(Boolean);
log(`chunks: ${chunks!.length}, distinct provider batches: ${new Set(batches).size}`);

const { data: summary } = await a.rpc('send_summary', { p_send_id: prepared.send_id });
log('final:', summary.send.status, JSON.stringify(summary.recipients));
log(`send page: /b/${brand}/sends/${prepared.send_id}`);
