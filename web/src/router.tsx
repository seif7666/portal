import { createBrowserRouter, Navigate } from 'react-router';
import { useAuth } from './lib/auth';
import { LoadingState, ErrorState } from './components/ui';
import { LoginPage } from './pages/LoginPage';
import { NoAccessPage, NotFoundPage } from './pages/StatusPages';
import { BrandLayout } from './pages/BrandLayout';
import { DashboardPage } from './pages/DashboardPage';
import { ContactsPage } from './pages/ContactsPage';
import { CampaignsPage } from './pages/CampaignsPage';
import { CampaignDetailPage } from './pages/CampaignDetailPage';
import { PrepareSendPage } from './pages/sends/PrepareSendPage';
import { SendPage } from './pages/sends/SendPage';
import { SharedReportPage } from './pages/SharedReportPage';
import { ImportsPage } from './pages/imports/ImportsPage';
import { ImportRunPage } from './pages/imports/ImportRunPage';

/** "/" sends people where they belong: login, their brand, or a no-access page. */
function RootRedirect() {
  const { session, initialising, membership, membershipLoading, membershipError } = useAuth();
  if (initialising || membershipLoading) return <LoadingState label="Signing you in…" />;
  if (!session) return <Navigate to="/login" replace />;
  if (membershipError) return <div className="p-6"><ErrorState error={membershipError} onRetry={() => location.reload()} /></div>;
  if (!membership) return <Navigate to="/no-access" replace />;
  return <Navigate to={`/b/${membership.brand_slug}/dashboard`} replace />;
}

export const router = createBrowserRouter([
  { path: '/', element: <RootRedirect /> },
  { path: '/login', element: <LoginPage /> },
  { path: '/no-access', element: <NoAccessPage /> },
  { path: '/r/:token', element: <SharedReportPage /> },
  {
    path: '/b/:brandSlug',
    element: <BrandLayout />,
    children: [
      { index: true, element: <Navigate to="dashboard" replace /> },
      { path: 'dashboard', element: <DashboardPage /> },
      { path: 'contacts', element: <ContactsPage /> },
      { path: 'campaigns', element: <CampaignsPage /> },
      { path: 'campaigns/:campaignId', element: <CampaignDetailPage /> },
      { path: 'campaigns/:campaignId/send', element: <PrepareSendPage /> },
      { path: 'sends/:sendId', element: <SendPage /> },
      { path: 'imports', element: <ImportsPage /> },
      { path: 'imports/:runId', element: <ImportRunPage /> },
      { path: '*', element: <NotFoundPage embedded /> },
    ],
  },
  { path: '*', element: <NotFoundPage /> },
]);
