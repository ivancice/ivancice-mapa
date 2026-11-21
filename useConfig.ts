'use client';
import { useEffect, useState } from 'react';
import { api } from '@/lib/api';
import { isConfigured } from '@/lib/env';
import type { PublicConfig } from '@/lib/types';

/** Veřejná konfigurace (kategorie, texty, nastavení) pro statické stránky */
export function usePublicConfig(): PublicConfig | null {
  const [cfg, setCfg] = useState<PublicConfig | null>(null);
  useEffect(() => {
    if (!isConfigured) return;
    api.config().then(setCfg).catch(() => setCfg(null));
  }, []);
  return cfg;
}
