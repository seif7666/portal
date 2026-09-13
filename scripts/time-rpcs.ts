// Times the read RPCs through the public API as a brand owner (PostgREST
// enforces an 8s statement timeout, so this is the number that matters).
//   npm run time-rpcs -- kilele
import { createClient } from '@supabase/supabase-js';
import { account, type BrandSlug } from './accounts.ts';

const brand = (process.argv[2] ?? 'kilele') as BrandSlug;
const owner = account(brand, 'owner');
const sb = createClient(process.env.VITE_SUPABASE_URL!, process.env.VITE_SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
await sb.auth.signInWithPassword({ email: owner.email, password: owner.password });
const { data: me } = await sb.rpc('my_membership');
const brandId = me[0].brand_id;

async function time(label: string, fn: () => PromiseLike<{ data: unknown; error: unknown }>) {
  const t = Date.now();
  const { data, error } = await fn();
  const ms = Date.now() - t;
  const preview = error ? `ERROR ${JSON.stringify(error)}` : JSON.stringify(data).slice(0, 400);
  console.log(`${label.padEnd(34)} ${String(ms).padStart(5)} ms  ${preview}`);
}

await time('dashboard_summary', () => sb.rpc('dashboard_summary', { p_brand_id: brandId }));
await time('signups_per_day', () => sb.rpc('signups_per_day', { p_brand_id: brandId }));
await time('campaign_performance', () => sb.rpc('campaign_performance', { p_brand_id: brandId }));
await time('list_contacts (first page)', () => sb.rpc('list_contacts', { p_brand_id: brandId }));
await time('list_contacts (search "wafula")', () => sb.rpc('list_contacts', { p_brand_id: brandId, p_search: 'wafula' }));
await time('list_contacts (not_contactable)', () => sb.rpc('list_contacts', { p_brand_id: brandId, p_filter: 'not_contactable' }));
await time('list_contacts (deep page)', () => sb.rpc('list_contacts', { p_brand_id: brandId, p_after: 'CT-070000' }));
