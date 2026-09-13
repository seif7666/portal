// Structural isolation test: if anyone removes the thing that keeps brands
// apart (disables RLS, drops or loosens a policy, adds a table without
// brand_id, grants anon access, adds an unchecked SECURITY DEFINER RPC),
// this fails.
import { readFileSync } from 'node:fs';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import pg from 'pg';

const coverageSql = readFileSync(new URL('../../supabase/tests/rls_coverage.sql', import.meta.url), 'utf8');

let db: pg.Client;

beforeAll(async () => {
  if (!process.env.SUPABASE_DB_URL) throw new Error('SUPABASE_DB_URL is required for isolation tests');
  db = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
  await db.connect();
});

afterAll(async () => {
  await db?.end();
});

async function violations() {
  const { rows } = await db.query<{ object: string; problem: string }>(coverageSql);
  return rows;
}

describe('RLS coverage', () => {
  it('has no isolation violations in the live schema', async () => {
    expect(await violations()).toEqual([]);
  });

  // The next tests prove the check itself has teeth: each one breaks the
  // guarantee inside a transaction, asserts the check notices, then rolls back.
  async function inRolledBackTx(breakIt: string) {
    await db.query('begin');
    try {
      await db.query(breakIt);
      return await violations();
    } finally {
      await db.query('rollback');
    }
  }

  it('detects a dropped brand policy', async () => {
    const v = await inRolledBackTx('drop policy contacts_select_own_brand on public.contacts');
    expect(v).toContainEqual({ object: 'contacts', problem: 'missing_brand_scoped_select_policy' });
  });

  it('detects RLS being disabled', async () => {
    const v = await inRolledBackTx('alter table public.campaigns disable row level security');
    expect(v).toContainEqual({ object: 'campaigns', problem: 'rls_not_enabled' });
  });

  it('detects a policy loosened to "true"', async () => {
    const v = await inRolledBackTx(
      'create policy leak on public.contacts for select to authenticated using (true)',
    );
    expect(v).toContainEqual({ object: 'contacts', problem: 'policy_not_brand_scoped:leak' });
  });

  it('detects a new table added without brand scoping', async () => {
    const v = await inRolledBackTx('create table public.new_feature (id int primary key)');
    expect(v).toContainEqual({ object: 'new_feature', problem: 'missing_brand_id_column' });
    expect(v).toContainEqual({ object: 'new_feature', problem: 'missing_brand_scoped_select_policy' });
  });

  it('detects a SECURITY DEFINER RPC that skips the membership check', async () => {
    const v = await inRolledBackTx(`
      create function public.leaky_rpc() returns setof public.contacts
      language sql security definer set search_path = '' as $$ select * from public.contacts $$`);
    expect(v).toContainEqual({ object: 'leaky_rpc', problem: 'security_definer_rpc_without_membership_check' });
  });
});
