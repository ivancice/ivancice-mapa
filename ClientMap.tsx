'use client';
import dynamic from 'next/dynamic';
import { isConfigured } from '@/lib/env';

const MapApp = dynamic(() => import('@/components/MapApp'), {
  ssr: false,
  loading: () => (
    <div className="flex h-dvh items-center justify-center text-sm text-ink-soft">Načítám mapu…</div>
  )
});

export default function ClientMap({ embed = false }: { embed?: boolean }) {
  if (!isConfigured) {
    return (
      <div className="mx-auto max-w-xl p-8">
        <h1 className="text-xl font-bold">Aplikace není nakonfigurována</h1>
        <p className="mt-2 text-sm text-ink-soft">
          Nastavte proměnné prostředí <code>NEXT_PUBLIC_SUPABASE_URL</code> a <code>NEXT_PUBLIC_SUPABASE_ANON_KEY</code> (viz README a .env.example).
        </p>
      </div>
    );
  }
  return <MapApp embed={embed} />;
}
