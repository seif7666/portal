import { PageHeader, EmptyState } from '../components/ui';

export function DashboardPage() {
  return (
    <>
      <PageHeader title="Dashboard" />
      <EmptyState title="Dashboard view is being built">The data is loaded; this screen is next.</EmptyState>
    </>
  );
}
