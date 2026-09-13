import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!url || !anonKey) {
  throw new Error('VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set');
}

// The browser only ever holds the anon key. Every rule about who can see or
// change what is enforced in Postgres (RLS + checked RPCs), not here.
export const supabase = createClient(url, anonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' },
});

/** Human-readable message from a Supabase/PostgREST error or anything thrown. */
export function errorMessage(e: unknown): string {
  if (!e) return 'Something went wrong.';
  if (typeof e === 'string') return e;
  const err = e as { message?: string; code?: string };
  if (err.code === '42501') return 'You do not have permission to do that.';
  if (err.message?.includes('Failed to fetch')) return 'Could not reach the server. Check your connection and try again.';
  return err.message ?? 'Something went wrong.';
}
