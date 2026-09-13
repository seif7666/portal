import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from './supabase';

export interface Membership {
  brand_id: string;
  brand_slug: string;
  brand_name: string;
  brand_timezone: string;
  role: 'owner' | 'analyst';
  email: string;
}

interface AuthState {
  session: Session | null;
  /** true until the stored session (or OAuth redirect) has been read */
  initialising: boolean;
  membership: Membership | null;
  membershipLoading: boolean;
  membershipError: unknown;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [initialising, setInitialising] = useState(true);
  const queryClient = useQueryClient();

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setInitialising(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
      // never show one user's cached data to the next user
      if (!next) queryClient.clear();
    });
    return () => sub.subscription.unsubscribe();
  }, [queryClient]);

  const userId = session?.user.id;
  const membershipQuery = useQuery({
    queryKey: ['membership', userId],
    enabled: !!userId,
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('my_membership');
      if (error) throw error;
      return ((data as Membership[]) ?? [])[0] ?? null;
    },
  });

  const value: AuthState = {
    session,
    initialising,
    membership: membershipQuery.data ?? null,
    membershipLoading: !!userId && membershipQuery.isPending,
    membershipError: membershipQuery.error,
    signOut: async () => {
      await supabase.auth.signOut();
      queryClient.clear();
    },
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth outside AuthProvider');
  return ctx;
}

/** Membership for pages rendered inside the brand layout (guaranteed present there). */
export function useBrand(): Membership & { isOwner: boolean } {
  const { membership } = useAuth();
  if (!membership) throw new Error('useBrand outside brand layout');
  return { ...membership, isOwner: membership.role === 'owner' };
}
