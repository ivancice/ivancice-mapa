'use client';
import { getSupabase } from '@/lib/supabase/client';
import { api } from '@/lib/api';
import { siteUrl } from '@/lib/env';

/**
 * Zajistí přihlašovací relaci. Pokud uživatel není přihlášen, vytvoří se
 * anonymní relace (Supabase Anonymous Sign-in), aby šlo bez registrace
 * vložit podnět. Hlasování vyžaduje ověřený e-mail (nastavitelné).
 */
export async function ensureSession(captchaToken?: string): Promise<string> {
  const sb = getSupabase();
  const { data } = await sb.auth.getSession();
  if (data.session?.user) return data.session.user.id;
  const { data: d2, error } = await sb.auth.signInAnonymously(captchaToken ? { options: { captchaToken } } : undefined);
  if (error || !d2.user) {
    if (error && /captcha/i.test(error.message)) throw new Error('Ověření proti robotům se nezdařilo. Obnovte prosím stránku.');
    throw new Error('Nepodařilo se vytvořit relaci: ' + (error?.message ?? 'neznámá chyba'));
  }
  return d2.user.id;
}

export async function currentUser() {
  const { data } = await getSupabase().auth.getUser();
  return data.user ?? null;
}

/**
 * Přihlášení bez hesla – ověřovací odkaz na e-mail (magic link).
 * Anonymní relace se nejprve pokusí e-mail připojit ke svému účtu
 * (příspěvky zůstanou pod stejnou identitou). Pokud e-mail už patří
 * existujícímu účtu, odešle se běžný přihlašovací odkaz a příspěvky
 * anonymní relace se po přihlášení převedou pomocí jednorázového tokenu.
 */
export async function sendMagicLink(email: string, next = '/', captchaToken?: string): Promise<'linked' | 'login'> {
  const sb = getSupabase();
  const clean = email.trim().toLowerCase();
  const { data } = await sb.auth.getSession();
  const user = data.session?.user;
  const base = `${siteUrl()}/auth/callback/`;

  if (user && user.is_anonymous) {
    const { error } = await sb.auth.updateUser(
      { email: clean },
      { emailRedirectTo: `${base}?next=${encodeURIComponent(next)}` }
    );
    if (!error) return 'linked';
    // e-mail už existuje → přihlásit se k existujícímu účtu a převést příspěvky
    let claim: string | null = null;
    try {
      claim = await api.createClaimToken();
    } catch {
      claim = null;
    }
    const redirect = `${base}?next=${encodeURIComponent(next)}${claim ? `&claim=${claim}` : ''}`;
    const { error: e2 } = await sb.auth.signInWithOtp({
      email: clean,
      options: { emailRedirectTo: redirect, shouldCreateUser: true, captchaToken }
    });
    if (e2) throw new Error(translateAuthError(e2.message));
    return 'login';
  }

  const { error } = await sb.auth.signInWithOtp({
    email: clean,
    options: { emailRedirectTo: `${base}?next=${encodeURIComponent(next)}`, shouldCreateUser: true, captchaToken }
  });
  if (error) throw new Error(translateAuthError(error.message));
  return 'login';
}

export async function signOut() {
  await getSupabase().auth.signOut();
}

export function translateAuthError(m: string): string {
  if (/rate limit|security purposes|too many/i.test(m)) return 'Odkaz byl odeslán před chvílí. Počkejte prosím minutu a zkuste to znovu.';
  if (/invalid.*email|email.*invalid/i.test(m)) return 'Zadaný e-mail není platný.';
  if (/captcha/i.test(m)) return 'Ověření proti robotům se nezdařilo. Zkuste to prosím znovu.';
  if (/signups not allowed/i.test(m)) return 'Registrace nových uživatelů je vypnutá.';
  return m;
}
