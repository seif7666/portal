// Idempotently provisions the six portal accounts:
//   1. memberships rows (the allowlist) — replaced so the table holds exactly six
//   2. Supabase Auth users with confirmed emails and the passwords from .env
// Safe to re-run after changing an email or password in .env.
//
//   npm run provision
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';
import { accounts } from './accounts.ts';

const url = process.env.VITE_SUPABASE_URL!;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const dbUrl = process.env.SUPABASE_DB_URL!;
if (!url || !serviceKey || !dbUrl) throw new Error('VITE_SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and SUPABASE_DB_URL are required');

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
const list = accounts();

// 1. allowlist
const db = new pg.Client({ connectionString: dbUrl, ssl: { rejectUnauthorized: false } });
await db.connect();
try {
  await db.query('begin');
  await db.query('delete from public.memberships');
  for (const a of list) {
    await db.query(
      `insert into public.memberships (brand_id, email, role)
       select id, $1, $2 from public.brands where slug = $3`,
      [a.email, a.role, a.brand],
    );
  }
  await db.query('commit');
} catch (e) {
  await db.query('rollback');
  throw e;
} finally {
  await db.end();
}
console.log(`memberships: ${list.length} rows`);

// 2. auth users
const existing = new Map<string, string>();
for (let page = 1; ; page++) {
  const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
  if (error) throw error;
  for (const u of data.users) if (u.email) existing.set(u.email.toLowerCase(), u.id);
  if (data.users.length < 200) break;
}

for (const a of list) {
  const id = existing.get(a.email);
  const { error } = id
    ? await admin.auth.admin.updateUserById(id, { password: a.password, email_confirm: true })
    : await admin.auth.admin.createUser({ email: a.email, password: a.password, email_confirm: true });
  if (error) throw new Error(`${a.email}: ${error.message}`);
  console.log(`${id ? 'updated' : 'created'}  ${a.brand.padEnd(10)} ${a.role.padEnd(8)} ${a.email}`);
}

const allowed = new Set(list.map((a) => a.email));
const strays = [...existing.keys()].filter((e) => !allowed.has(e));
if (strays.length) console.warn(`auth users NOT in the allowlist (they see nothing): ${strays.join(', ')}`);
