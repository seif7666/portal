// Shared helpers for the edge functions.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
}

export function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

/** Service-role client: only used to call the svc_* RPCs, which assert the service role themselves. */
export function serviceClient(): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
}

export type Caller =
  | { kind: 'cron' }
  | { kind: 'user'; client: SupabaseClient; brandId: string; role: 'owner' | 'analyst' };

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Who is calling: the scheduler (shared secret from Vault) or a signed-in
 * member of a brand (their own JWT, checked by Supabase Auth, membership read
 * through RLS). Anything else is refused.
 */
export async function identify(req: Request): Promise<Caller | null> {
  const cronSecret = req.headers.get('x-cron-secret');
  if (cronSecret) {
    return timingSafeEqual(cronSecret, env('CRON_SECRET')) ? { kind: 'cron' } : null;
  }
  const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const client = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: user, error } = await client.auth.getUser(token);
  if (error || !user?.user) return null;
  const { data: me } = await client.rpc('my_membership');
  const m = (me as { brand_id: string; role: 'owner' | 'analyst' }[] | null)?.[0];
  if (!m) return null;
  return { kind: 'user', client, brandId: m.brand_id, role: m.role };
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
