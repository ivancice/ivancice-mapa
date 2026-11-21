import AdminShell from '@/components/admin/AdminShell';

export const metadata = { title: 'Administrace – Ivančice očima pěších a cyklistů', robots: { index: false, follow: false } };

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  return <AdminShell>{children}</AdminShell>;
}
