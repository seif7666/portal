// Manual check: sign in as one of the six (via the public API + anon key, like
// the browser app will) and print what that user can see.
//
//   npm run try-login -- kilele owner
//   npm run try-login -- someone@else.com somePassword     (any other credentials)
import { createClient } from '@supabase/supabase-js';
import { account, type BrandSlug, type Role } from './accounts.ts';

const [a1, a2] = process.argv.slice(2);
if (!a1 || !a2) {
  console.log('usage: npm run try-login -- <kilele|karoo|marrakech> <owner|analyst>\n       npm run try-login -- <email> <password>');
  process.exit(1);
}
const creds = a1.includes('@') ? { email: a1, password: a2 } : account(a1 as BrandSlug, a2 as Role);

const c = createClient(process.env.VITE_SUPABASE_URL!, process.env.VITE_SUPABASE_ANON_KEY!, {
  auth: { persistSession: false },
});

const { error: signInError } = await c.auth.signInWithPassword({ email: creds.email, password: creds.password });
if (signInError) {
  console.log(`✗ sign-in refused for ${creds.email}: ${signInError.message}`);
} else {
  await report();
}

async function report() {
console.log(`✓ signed in as ${creds.email}`);

const { data: me } = await c.rpc('my_membership');
console.log('membership   :', me?.length ? me : 'NONE (not on the allowlist — sees nothing)');

const { data: brands } = await c.from('brands').select('slug, name');
console.log('brands seen  :', brands);

for (const table of ['memberships', 'contacts', 'campaigns', 'engagement_events', 'import_runs']) {
  const { count, error } = await c.from(table).select('*', { count: 'exact', head: true });
  console.log(`${table.padEnd(13)}:`, error ? `error ${error.code} ${error.message}` : `${count} rows visible`);
}

const attempt = await c.from('contacts').insert({ brand_id: me?.[0]?.brand_id, external_id: 'X', status: 'active', source_exported_at: new Date().toISOString() });
console.log('direct insert:', attempt.error ? `refused (${attempt.error.code})` : 'ALLOWED — this would be a bug');
}
