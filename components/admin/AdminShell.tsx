'use client';
import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import clsx from 'clsx';
import { ChartColumn, Download, Flag, FolderTree, List, Map as MapIcon, Settings, ArrowLeft } from 'lucide-react';
import type { MyProfile, PublicConfig } from '@/lib/types';
import { api } from '@/lib/api';
import { getSupabase } from '@/lib/supabase/client';
import { Spinner, Toaster } from '@/components/ui';
import { AccountDialog } from '@/components/AccountDialog';
import { BASE_PATH, isConfigured } from '@/lib/env';

interface Ctx {
  config: PublicConfig;
  profile: MyProfile;
  reloadConfig: () => Promise<void>;
}
const AdminCtx = createContext<Ctx | null>(null);
export const useAdmin = () => useContext(AdminCtx)!;

const NAV = [
  { href: '/admin', label: 'Přehled', icon: ChartColumn },
  { href: '/admin/podnety', label: 'Podněty', icon: List },
  { href: '/admin/mapa', label: 'Mapa a analýzy', icon: MapIcon },
  { href: '/admin/moderace', label: 'Moderace', icon: Flag },
  { href: '/admin/kategorie', label: 'Kategorie', icon: FolderTree },
  { href: '/admin/export', label: 'Export dat', icon: Download },
  { href: '/admin/nastaveni', label: 'Nastavení', icon: Settings }
];

export default function AdminShell({ children }: { children: ReactNode }) {
  const [config, setConfig] = useState<PublicConfig | null>(null);
  const [profile, setProfile] = useState<MyProfile | null | undefined>(undefined);
  const path = usePathname();

  const reloadConfig = useCallback(async () => setConfig(await api.config()), []);
  const loadProfile = useCallback(async () => setProfile(await api.myProfile().catch(() => null)), []);

  useEffect(() => {
    if (!isConfigured) return;
    reloadConfig();
    loadProfile();
    const { data } = getSupabase().auth.onAuthStateChange(() => loadProfile());
    return () => data.subscription.unsubscribe();
  }, [reloadConfig, loadProfile]);

  if (!isConfigured) return <div className="p-8">Aplikace není nakonfigurována (chybí proměnné prostředí Supabase).</div>;
  if (profile === undefined || !config) return <div className="flex h-dvh items-center justify-center"><Spinner className="h-8 w-8 text-brand-600" /></div>;

  if (!profile?.is_verified || !profile.is_admin) {
    return (
      <div className="mx-auto max-w-md p-8">
        <Toaster />
        <h1 className="text-xl font-bold">Administrace</h1>
        {profile?.is_verified && !profile.is_admin ? (
          <p className="mt-3 text-sm text-ink-soft">Účet <b>{profile.email}</b> nemá oprávnění administrátora. Požádejte správce o přidání.</p>
        ) : (
          <p className="mt-3 text-sm text-ink-soft">Přihlaste se e-mailem s oprávněním administrátora.</p>
        )}
        {!profile?.is_verified && <AccountDialog profile={profile ?? null} config={config} onClose={() => (window.location.href = `${BASE_PATH}/`)} onChanged={loadProfile} onOpenReport={() => {}} />}
        <Link href="/" className="mt-4 inline-block text-sm font-semibold text-brand-700">← Zpět na mapu</Link>
      </div>
    );
  }

  return (
    <AdminCtx.Provider value={{ config, profile, reloadConfig }}>
      <Toaster />
      <div className="flex min-h-dvh flex-col md:flex-row">
        <aside className="shrink-0 border-b border-slate-200 bg-white md:sticky md:top-0 md:h-dvh md:w-60 md:border-b-0 md:border-r">
          <div className="px-4 py-3 md:py-5">
            <Link href="/" className="flex items-center gap-1 text-xs font-semibold text-ink-soft hover:text-brand-700"><ArrowLeft className="h-3.5 w-3.5" /> Veřejná mapa</Link>
            <div className="mt-1 text-lg font-extrabold text-brand-800">Administrace</div>
            <div className="truncate text-xs text-ink-faint">{profile.email}</div>
          </div>
          <nav className="flex gap-1 overflow-x-auto px-2 pb-2 md:flex-col md:overflow-visible">
            {NAV.map((n) => {
              const active = n.href === '/admin' ? path === '/admin' : path?.startsWith(n.href);
              return (
                <Link key={n.href} href={n.href} className={clsx('flex shrink-0 items-center gap-2 rounded-xl px-3 py-2 text-sm font-semibold', active ? 'bg-brand-50 text-brand-800' : 'text-ink-soft hover:bg-slate-50')}>
                  <n.icon className="h-4 w-4" /> {n.label}
                </Link>
              );
            })}
          </nav>
        </aside>
        <main className="min-w-0 flex-1 bg-slate-50 p-4 md:p-6">{children}</main>
      </div>
    </AdminCtx.Provider>
  );
}
