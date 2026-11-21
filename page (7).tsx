'use client';
import { useEffect, useState } from 'react';
import type { EmailOtpType } from '@supabase/supabase-js';
import { getSupabase } from '@/lib/supabase/client';
import { BASE_PATH, isConfigured } from '@/lib/env';

// Dokončení přihlášení z odkazu v e-mailu (magic link / potvrzení e-mailu).
// Běží v prohlížeči, takže web může být čistě statický.
export default function AuthCallback() {
  const [msg, setMsg] = useState('Dokončuji přihlášení…');

  useEffect(() => {
    if (!isConfigured) return;
    (async () => {
      const url = new URL(window.location.href);
      const hash = new URLSearchParams(url.hash.slice(1));
      const code = url.searchParams.get('code');
      const tokenHash = url.searchParams.get('token_hash');
      const type = url.searchParams.get('type') as EmailOtpType | null;
      const claim = url.searchParams.get('claim');
      let next = url.searchParams.get('next') || `${BASE_PATH}/`;
      if (!next.startsWith('/') || next.startsWith('//')) next = `${BASE_PATH}/`;

      const sb = getSupabase();
      let ok = false;
      if (url.searchParams.get('error') || hash.get('error')) {
        ok = false;
      } else {
        // klient Supabase může kód zpracovat sám při inicializaci
        const { data } = await sb.auth.getSession();
        const fresh = data.session && !data.session.user.is_anonymous;
        if (code && !fresh) {
          const { error } = await sb.auth.exchangeCodeForSession(code);
          ok = !error || !!(await sb.auth.getSession()).data.session;
        } else if (tokenHash && type) {
          const { error } = await sb.auth.verifyOtp({ token_hash: tokenHash, type });
          ok = !error;
        } else {
          ok = !!data.session;
        }
      }

      const target = new URL(next, window.location.origin);
      target.searchParams.set('login', ok ? 'ok' : 'error');
      if (ok && claim && /^[0-9a-f]{48}$/.test(claim)) {
        const { data } = await sb.rpc('claim_contributions', { p_token: claim });
        const moved = (data as { moved?: number } | null)?.moved ?? 0;
        if (moved > 0) target.searchParams.set('moved', String(moved));
      }
      if (!ok) setMsg('Odkaz je neplatný nebo vypršel.');
      window.location.replace(target.toString());
    })();
  }, []);

  return <div className="flex h-dvh items-center justify-center p-6 text-center text-sm text-ink-soft">{msg}</div>;
}
