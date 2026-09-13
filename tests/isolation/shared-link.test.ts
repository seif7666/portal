// The shared results link, approached the way a stranger would.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import pg from 'pg';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { account } from '../../scripts/accounts.ts';

const URL_ = process.env.VITE_SUPABASE_URL!;
const ANON = process.env.VITE_SUPABASE_ANON_KEY!;
const PASSWORD = 'correct horse battery';
const GENERIC = 'This link or password is not valid, or the link has expired.';

let db: pg.Client;
let owner: SupabaseClient;
let campaignId: string;
const created: string[] = [];

const stranger = () => createClient(URL_, ANON, { auth: { persistSession: false } });
async function signIn(brand: 'kilele' | 'karoo' | 'marrakech', role: 'owner' | 'analyst') {
  const a = account(brand, role);
  const c = createClient(URL_, ANON, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email: a.email, password: a.password });
  if (error) throw error;
  return c;
}
async function createLink(password = PASSWORD) {
  const { data, error } = await owner.rpc('create_share_link', { p_campaign_id: campaignId, p_password: password, p_expires_in_days: 1 });
  if (error) throw error;
  created.push(data.id);
  return data as { id: string; token: string };
}

beforeAll(async () => {
  db = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
  await db.connect();
  owner = await signIn('marrakech', 'owner');
  const { data } = await owner.from('campaigns').select('id').eq('external_id', 'MAR-0001').single();
  campaignId = data!.id;
});

afterAll(async () => {
  if (created.length) await db.query('delete from public.shared_reports where id = any($1::uuid[])', [created]);
  await db.end();
});

describe('shared results link', () => {
  it('opens with the right password and shows only that campaign’s aggregate numbers', async () => {
    const link = await createLink();
    const { data } = await stranger().rpc('shared_report_open', { p_token: link.token, p_password: PASSWORD });
    expect(data.ok).toBe(true);
    expect(data.campaign.reference).toBe('MAR-0001');
    expect(Object.keys(data).sort()).toEqual(['brand_name', 'campaign', 'generated_at', 'link_expires_at', 'measured', 'ok', 'portal_sends', 'reported', 'timezone']);
    const text = JSON.stringify(data);
    expect(text).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i); // no internal ids
    expect(text).not.toMatch(/@/);                                                          // no email addresses
    expect(text).not.toMatch(/\+\d{9,}/);                                                    // no phone numbers
  });

  it('gives one generic answer for a wrong password, a guessed token, and garbage', async () => {
    const link = await createLink();
    const s = stranger();
    const answers = await Promise.all([
      s.rpc('shared_report_open', { p_token: link.token, p_password: 'wrong password!' }),
      s.rpc('shared_report_open', { p_token: 'A'.repeat(43), p_password: PASSWORD }),
      s.rpc('shared_report_open', { p_token: link.token.slice(0, -1) + (link.token.endsWith('A') ? 'B' : 'A'), p_password: PASSWORD }),
      s.rpc('shared_report_open', { p_token: "' or 1=1 --", p_password: PASSWORD }),
      s.rpc('shared_report_open', { p_token: link.token, p_password: 'x'.repeat(5000) }),
    ]);
    for (const a of answers) expect(a.data).toEqual({ ok: false, error: GENERIC });
  });

  it('locks after 5 wrong passwords, even against the right one', async () => {
    const link = await createLink();
    const s = stranger();
    for (let i = 0; i < 5; i++) await s.rpc('shared_report_open', { p_token: link.token, p_password: `guess number ${i}` });
    const { data } = await s.rpc('shared_report_open', { p_token: link.token, p_password: PASSWORD });
    expect(data).toEqual({ ok: false, error: GENERIC });
  });

  it('stops working once revoked', async () => {
    const link = await createLink();
    await owner.rpc('revoke_share_link', { p_id: link.id });
    const { data } = await stranger().rpc('shared_report_open', { p_token: link.token, p_password: PASSWORD });
    expect(data).toEqual({ ok: false, error: GENERIC });
  });

  it('stores neither the token nor the password', async () => {
    const link = await createLink();
    const { rows } = await db.query('select token_hash, password_hash from public.shared_reports where id = $1', [link.id]);
    expect(rows[0].token_hash).not.toContain(link.token);
    expect(rows[0].password_hash).toMatch(/^\$2[aby]\$/);
    expect(rows[0].password_hash).not.toContain(PASSWORD);
  });

  it('cannot be listed or read by a stranger, and members cannot read the hashes', async () => {
    const link = await createLink();
    const anonRead = await stranger().from('shared_reports').select('*');
    expect(anonRead.error?.code === '42501' || anonRead.data?.length === 0).toBe(true);
    const hashRead = await owner.from('shared_reports').select('token_hash').eq('id', link.id);
    expect(hashRead.error?.code).toBe('42501');
    const ok = await owner.from('shared_reports').select('id, view_count').eq('id', link.id);
    expect(ok.data).toHaveLength(1);
  });

  it('can only be created by the owner of that campaign’s brand', async () => {
    const analyst = await signIn('marrakech', 'analyst');
    const byAnalyst = await analyst.rpc('create_share_link', { p_campaign_id: campaignId, p_password: PASSWORD, p_expires_in_days: 1 });
    expect(byAnalyst.error?.code).toBe('42501');
    const otherOwner = await signIn('kilele', 'owner');
    const byOtherBrand = await otherOwner.rpc('create_share_link', { p_campaign_id: campaignId, p_password: PASSWORD, p_expires_in_days: 1 });
    expect(byOtherBrand.error?.code).toBe('42501');
    const link = await createLink();
    const revokeByOtherBrand = await otherOwner.rpc('revoke_share_link', { p_id: link.id });
    expect(revokeByOtherBrand.error?.code).toBe('42501');
    const weak = await owner.rpc('create_share_link', { p_campaign_id: campaignId, p_password: 'short', p_expires_in_days: 1 });
    expect(weak.error?.code).toBe('22023');
  });
});
