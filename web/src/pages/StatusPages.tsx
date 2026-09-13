import { Link, Navigate } from 'react-router';
import { useAuth } from '../lib/auth';
import { Button, LoadingState } from '../components/ui';

export function NoAccessPage() {
  const { session, initialising, membership, membershipLoading, signOut } = useAuth();
  if (initialising || membershipLoading) return <LoadingState />;
  if (!session) return <Navigate to="/login" replace />;
  if (membership) return <Navigate to="/" replace />;
  return (
    <main className="flex min-h-full items-center justify-center px-4">
      <div className="max-w-md text-center">
        <h1 className="text-lg font-semibold text-slate-900">No portal access</h1>
        <p className="mt-2 text-sm text-slate-500">
          You are signed in as <span className="font-medium text-slate-700">{session.user.email}</span>, but this account is not a member of
          any brand. Ask your Velocity Growth contact to invite you.
        </p>
        <Button variant="secondary" className="mt-6" onClick={signOut}>Sign out</Button>
      </div>
    </main>
  );
}

export function NotFoundPage({ embedded = false }: { embedded?: boolean }) {
  return (
    <main className={embedded ? 'py-16 text-center' : 'flex min-h-full items-center justify-center px-4 text-center'}>
      <div>
        <p className="text-sm font-semibold text-brand-600">404</p>
        <h1 className="mt-1 text-lg font-semibold text-slate-900">Page not found</h1>
        <p className="mt-2 text-sm text-slate-500">This page does not exist, or you do not have access to it.</p>
        <Link to="/" className="mt-6 inline-block text-sm font-medium text-brand-700 hover:underline">Go to your portal</Link>
      </div>
    </main>
  );
}
