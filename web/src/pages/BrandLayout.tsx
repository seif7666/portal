import { useState } from 'react';
import { Navigate, NavLink, Outlet, useParams, useLocation } from 'react-router';
import clsx from 'clsx';
import { useAuth } from '../lib/auth';
import { Badge, ErrorState, LoadingState } from '../components/ui';
import { NotFoundPage } from './StatusPages';

const NAV = [
  { to: 'dashboard', label: 'Dashboard', icon: 'M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6' },
  { to: 'contacts', label: 'Contacts', icon: 'M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z' },
  { to: 'campaigns', label: 'Campaigns', icon: 'M11 5.882V19.24a1.76 1.76 0 01-3.417.592l-2.147-6.15M18 13a3 3 0 100-6M5.436 13.683A4.001 4.001 0 017 6h1.832c4.1 0 7.625-1.234 9.168-3v14c-1.543-1.766-5.067-3-9.168-3H7a3.988 3.988 0 01-1.564-.317z' },
  { to: 'imports', label: 'Imports', icon: 'M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12' },
];

export function BrandLayout() {
  const { brandSlug } = useParams();
  const { session, initialising, membership, membershipLoading, membershipError, signOut } = useAuth();
  const [menuOpen, setMenuOpen] = useState(false);
  const location = useLocation();

  if (initialising || membershipLoading) return <LoadingState label="Loading your portal…" />;
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  if (membershipError) return <div className="p-6"><ErrorState error={membershipError} onRetry={() => location.pathname && window.location.reload()} /></div>;
  if (!membership) return <Navigate to="/no-access" replace />;
  // Another brand's URL looks exactly like a page that does not exist.
  // (The data would be empty anyway: RLS decides, not this check.)
  if (membership.brand_slug !== brandSlug) return <NotFoundPage />;

  const nav = (
    <nav className="space-y-1">
      {NAV.map((item) => (
        <NavLink
          key={item.to}
          to={item.to}
          onClick={() => setMenuOpen(false)}
          className={({ isActive }) =>
            clsx(
              'flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium',
              isActive ? 'bg-brand-50 text-brand-700' : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900',
            )
          }
        >
          <svg className="h-5 w-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.7} aria-hidden>
            <path strokeLinecap="round" strokeLinejoin="round" d={item.icon} />
          </svg>
          {item.label}
        </NavLink>
      ))}
    </nav>
  );

  const account = (
    <div className="border-t border-slate-200 pt-4">
      <p className="truncate text-sm font-medium text-slate-800" title={membership.email}>{membership.email}</p>
      <div className="mt-1 flex items-center justify-between">
        <Badge tone={membership.role === 'owner' ? 'brand' : 'slate'}>{membership.role === 'owner' ? 'Owner' : 'Analyst · view only'}</Badge>
        <button onClick={signOut} className="text-sm text-slate-500 hover:text-slate-900">Sign out</button>
      </div>
    </div>
  );

  return (
    <div className="min-h-full lg:flex">
      {/* desktop sidebar */}
      <aside className="hidden w-64 shrink-0 flex-col justify-between border-r border-slate-200 bg-white p-4 lg:flex lg:fixed lg:inset-y-0">
        <div>
          <BrandMark name={membership.brand_name} />
          <div className="mt-6">{nav}</div>
        </div>
        {account}
      </aside>

      {/* mobile top bar */}
      <header className="sticky top-0 z-20 flex items-center justify-between border-b border-slate-200 bg-white/95 px-4 py-3 backdrop-blur lg:hidden">
        <BrandMark name={membership.brand_name} />
        <button
          onClick={() => setMenuOpen((o) => !o)}
          className="rounded-lg p-2 text-slate-600 hover:bg-slate-100"
          aria-expanded={menuOpen}
          aria-label="Menu"
        >
          <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8} aria-hidden>
            <path strokeLinecap="round" d={menuOpen ? 'M6 18L18 6M6 6l12 12' : 'M4 6h16M4 12h16M4 18h16'} />
          </svg>
        </button>
      </header>
      {menuOpen && (
        <div className="sticky top-[57px] z-10 space-y-4 border-b border-slate-200 bg-white p-4 shadow-sm lg:hidden">
          {nav}
          {account}
        </div>
      )}

      <main className="min-w-0 flex-1 px-4 py-6 sm:px-6 lg:ml-64 lg:px-8 lg:py-8">
        <div className="mx-auto max-w-7xl">
          <Outlet />
        </div>
      </main>
    </div>
  );
}

function BrandMark({ name }: { name: string }) {
  return (
    <div className="flex items-center gap-3">
      <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-brand-600 text-sm font-bold text-white">
        {name.split(' ').map((w) => w[0]).slice(0, 2).join('')}
      </div>
      <div className="leading-tight">
        <p className="text-sm font-semibold text-slate-900">{name}</p>
        <p className="text-xs text-slate-500">Campaign Portal</p>
      </div>
    </div>
  );
}
