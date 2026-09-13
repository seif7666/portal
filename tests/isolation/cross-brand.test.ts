// Behavioural isolation test: signs in as the real accounts through the public
// API with the anon key (exactly what an evaluator can do) and tries to reach
// another brand's data. Fixture rows are inserted per brand and removed after.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import pg from 'pg';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { accounts, account, type BrandSlug } from '../../scripts/accounts.ts';

const URL_ = process.env.VITE_SUPABASE_URL!;
const ANON = process.env.VITE_SUPABASE_ANON_KEY!;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const BRANDS: BrandSlug[] = ['kilele', 'karoo', 'marrakech'];
const FIXTURE_PREFIX = 'ZZTEST-ISO-';
const OUTSIDER = { email: 'outsider.isolation-test@example.com', password: 'Outsider-Only-Test-123!' };

let db: pg.Client;
const brandId: Record<string, string> = {};
const contactId: Record<string, string> = {};
const campaignId: Record<string, string> = {};

function anonClient() {
  return createClient(URL_, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function signIn(email: string, password: string): Promise<SupabaseClient> {
  const c = anonClient();
  const { error } = await c.auth.signInWithPassword({ email, password });
  if (error) throw new Error(`sign-in failed for ${email}: ${error.message}`);
  return c;
}

beforeAll(async () => {
  db = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
  await db.connect();
  await cleanup();
  for (const slug of BRANDS) {
    const { rows: [b] } = await db.query('select id from public.brands where slug = $1', [slug]);
    brandId[slug] = b.id;
    const { rows: [c] } = await db.query(
      `insert into public.contacts (brand_id, external_id, full_name, email, status, consent_marketing, source_exported_at)
       values ($1, $2, $3, $4, 'active', true, now()) returning id`,
      [b.id, `${FIXTURE_PREFIX}${slug}`, `Fixture ${slug}`, `fixture.${slug}@example.com`],
    );
    contactId[slug] = c.id;
    const { rows: [k] } = await db.query(
      `insert into public.campaigns (brand_id, external_id, name, channel, source_exported_at)
       values ($1, $2, $3, 'email', now()) returning id`,
      [b.id, `${FIXTURE_PREFIX}${slug}`, `Fixture campaign ${slug}`],
    );
    campaignId[slug] = k.id;
  }
  // A confirmed user who is NOT on the allowlist.
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  await admin.auth.admin.createUser({ ...OUTSIDER, email_confirm: true });
});

async function cleanup() {
  await db.query('delete from public.campaigns where external_id like $1', [`${FIXTURE_PREFIX}%`]);
  await db.query('delete from public.contacts where external_id like $1', [`${FIXTURE_PREFIX}%`]);
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const { data } = await admin.auth.admin.listUsers({ perPage: 200 });
  const u = data?.users.find((x) => x.email === OUTSIDER.email);
  if (u) await admin.auth.admin.deleteUser(u.id);
}

afterAll(async () => {
  await cleanup();
  await db.end();
});

describe.each(accounts().map((a) => [`${a.brand} ${a.role}`, a] as const))('%s', (_label, me) => {
  let c: SupabaseClient;
  const others = BRANDS.filter((b) => b !== me.brand);

  beforeAll(async () => {
    c = await signIn(me.email, me.password);
  });

  it('lands in its own brand with its own role', async () => {
    const { data, error } = await c.rpc('my_membership');
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data[0]).toMatchObject({ brand_slug: me.brand, role: me.role });
  });

  it('sees only its own brand row', async () => {
    const { data } = await c.from('brands').select('slug');
    expect(data).toEqual([{ slug: me.brand }]);
  });

  it('sees only its own team in memberships', async () => {
    const { data } = await c.from('memberships').select('brand_id');
    expect(data!.length).toBe(2);
    expect(new Set(data!.map((r) => r.brand_id))).toEqual(new Set([brandId[me.brand]]));
  });

  it.each(['contacts', 'campaigns'])('lists only its own %s', async (table) => {
    const { data, error } = await c.from(table).select('brand_id, external_id').like('external_id', `${FIXTURE_PREFIX}%`);
    expect(error).toBeNull();
    expect(data).toEqual([{ brand_id: brandId[me.brand], external_id: `${FIXTURE_PREFIX}${me.brand}` }]);
  });

  it('cannot fetch another brand\'s contact or campaign by exact id', async () => {
    for (const other of others) {
      const byContact = await c.from('contacts').select('id').eq('id', contactId[other]);
      expect(byContact.data).toEqual([]);
      const byBrand = await c.from('contacts').select('id').eq('brand_id', brandId[other]);
      expect(byBrand.data).toEqual([]);
      const byCampaign = await c.from('campaigns').select('id').eq('id', campaignId[other]);
      expect(byCampaign.data).toEqual([]);
    }
  });

  it('cannot write to any brand directly (writes go through checked RPCs only)', async () => {
    for (const target of BRANDS) {
      const ins = await c.from('contacts').insert({
        brand_id: brandId[target], external_id: `${FIXTURE_PREFIX}write`, status: 'active', source_exported_at: new Date().toISOString(),
      });
      expect(ins.error?.code).toBe('42501'); // permission denied
      const upd = await c.from('contacts').update({ full_name: 'hijacked' }).eq('id', contactId[target]).select();
      expect(upd.error?.code).toBe('42501');
      const del = await c.from('contacts').delete().eq('id', contactId[target]).select();
      expect(del.error?.code).toBe('42501');
    }
    const { rows } = await db.query("select count(*)::int n from public.contacts where full_name = 'hijacked' or external_id = $1", [`${FIXTURE_PREFIX}write`]);
    expect(rows[0].n).toBe(0);
  });

  it('cannot reach the private helper schema', async () => {
    const { error } = await c.schema('private' as 'public').rpc('current_brand_ids');
    expect(error).not.toBeNull();
  });
});

describe('outside the six', () => {
  it('anonymous callers see nothing', async () => {
    const c = anonClient();
    for (const table of ['brands', 'memberships', 'contacts', 'campaigns']) {
      const { data, error } = await c.from(table).select('*').limit(1);
      // either an explicit permission error or an empty result, never data
      expect(error?.code === '42501' || (Array.isArray(data) && data.length === 0)).toBe(true);
    }
  });

  it('a signed-in user who is not on the allowlist sees nothing', async () => {
    const c = await signIn(OUTSIDER.email, OUTSIDER.password);
    const { data: m } = await c.rpc('my_membership');
    expect(m).toEqual([]);
    for (const table of ['brands', 'memberships', 'contacts', 'campaigns']) {
      const { data } = await c.from(table).select('*').limit(1);
      expect(data).toEqual([]);
    }
  });

  it('a stranger cannot create an account at all (sign-up refused by the allowlist hook)', async () => {
    const email = `stranger.${Date.now()}@example.com`;
    const { data, error } = await anonClient().auth.signUp({ email, password: 'Stranger-Password-123' });
    expect(error?.status).toBe(403);
    expect(data.user).toBeNull();
  });

  it('a wrong password is refused', async () => {
    const { owner } = { owner: account('kilele', 'owner') };
    const { error } = await anonClient().auth.signInWithPassword({ email: owner.email, password: 'wrong-password' });
    expect(error).not.toBeNull();
  });
});
