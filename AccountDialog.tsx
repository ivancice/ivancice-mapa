'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
import { LogOut, Mail, Shield } from 'lucide-react';
import type { MyProfile, PublicConfig } from '@/lib/types';
import { api, errorMessage } from '@/lib/api';
import { sendMagicLink, signOut } from '@/lib/auth';
import { Button, Field, inputCls, Modal, toast } from '@/components/ui';
import { Turnstile, captchaEnabled } from '@/components/Turnstile';
import { formatDate } from '@/lib/geo';

export function AccountDialog({
  profile, config, reason, onClose, onChanged, onOpenReport
}: { profile: MyProfile | null; config: PublicConfig; reason?: string | null; onClose: () => void; onChanged: () => void; onOpenReport: (id: string) => void }) {
  const verified = !!profile?.is_verified;
  return (
    <Modal open onClose={onClose} title={verified ? 'Můj účet' : 'Přihlášení bez hesla'}>
      {verified && profile ? <Profile profile={profile} onChanged={onChanged} onClose={onClose} onOpenReport={onOpenReport} /> : <Login reason={reason} profile={profile} config={config} />}
    </Modal>
  );
}

function Login({ reason, profile }: { reason?: string | null; profile: MyProfile | null; config: PublicConfig }) {
  const [email, setEmail] = useState(profile?.contact_email ?? '');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState<null | 'linked' | 'login'>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function send(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())) return setErr('Zadejte prosím platný e-mail.');
    if (captchaEnabled && !captcha) return setErr('Potvrďte prosím, že nejste robot.');
    setBusy(true);
    try {
      const next = window.location.pathname + window.location.search;
      setSent(await sendMagicLink(email, next, captcha ?? undefined));
    } catch (e2) {
      setErr(errorMessage(e2));
    } finally {
      setBusy(false);
    }
  }

  if (sent) {
    return (
      <div className="space-y-3 text-sm">
        <div className="flex items-start gap-3 rounded-2xl bg-brand-50 p-4 text-brand-900">
          <Mail className="mt-0.5 h-6 w-6 shrink-0" />
          <div>
            Na adresu <b>{email}</b> jsme poslali ověřovací odkaz. Klikněte na něj a budete přihlášeni.
            {profile && ' Vaše dosavadní podněty zůstanou zachovány.'}
          </div>
        </div>
        <p className="text-ink-soft">E-mail nedorazil? Zkontrolujte složku nevyžádané pošty, případně to zkuste znovu za minutu.</p>
      </div>
    );
  }

  return (
    <form onSubmit={send} className="space-y-3">
      {reason && <div className="rounded-2xl bg-amber-50 p-3 text-sm text-amber-900">{reason}</div>}
      <p className="text-sm text-ink-soft">
        Žádné heslo. Zadejte e-mail a pošleme vám odkaz pro přihlášení. Přihlášení umožní podporovat podněty
        (každý jen jednou), spravovat vlastní příspěvky a přihlásit se k odběru výsledků mapování.
      </p>
      <Field label="E-mail" required>
        <input className={inputCls} type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" inputMode="email" autoFocus />
      </Field>
      {captchaEnabled && <Turnstile onToken={setCaptcha} />}
      {err && <div className="rounded-xl bg-red-50 p-3 text-sm text-red-700">{err}</div>}
      <Button type="submit" variant="primary" className="w-full" loading={busy}><Mail className="h-4 w-4" /> Poslat přihlašovací odkaz</Button>
      <p className="text-xs text-ink-soft">E-mail nikdy nezveřejníme. <Link href="/ochrana-osobnich-udaju" className="underline" target="_blank">Zásady ochrany osobních údajů</Link></p>
    </form>
  );
}

function Profile({ profile, onChanged, onClose, onOpenReport }: { profile: MyProfile; onChanged: () => void; onClose: () => void; onOpenReport: (id: string) => void }) {
  const [nick, setNick] = useState(profile.nickname ?? '');
  const [contact, setContact] = useState(profile.contact_email ?? '');
  const [newsletter, setNewsletter] = useState(profile.newsletter);
  const [busy, setBusy] = useState(false);
  const [mine, setMine] = useState<Awaited<ReturnType<typeof api.myReports>> | null>(null);

  useEffect(() => {
    api.myReports().then(setMine).catch(() => setMine([]));
  }, []);

  async function save() {
    setBusy(true);
    try {
      await api.updateProfile(nick || null, contact, newsletter);
      toast('Uloženo');
      onChanged();
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4 text-sm">
      <div className="rounded-2xl bg-slate-50 p-3">
        Přihlášeni jako <b>{profile.email}</b>
        <div className="text-xs text-ink-soft">{profile.reports} podnětů · {profile.supports} podpor</div>
      </div>
      {profile.is_admin && (
        <Link href="/admin" className="flex items-center gap-2 rounded-2xl border border-brand-200 bg-brand-50 p-3 font-semibold text-brand-800">
          <Shield className="h-4 w-4" /> Otevřít administraci
        </Link>
      )}
      <Field label="Přezdívka (veřejná)"><input className={inputCls} value={nick} onChange={(e) => setNick(e.target.value)} maxLength={60} /></Field>
      <Field label="Kontaktní e-mail" hint="Neveřejný. Pokud je prázdný, použije se e-mail přihlášení."><input className={inputCls} type="email" value={contact} onChange={(e) => setContact(e.target.value)} /></Field>
      <label className="flex items-start gap-2">
        <input type="checkbox" className="mt-0.5 h-4 w-4 accent-brand-600" checked={newsletter} onChange={(e) => setNewsletter(e.target.checked)} />
        <span>Chci dostávat informace o výsledcích mapování a novinkách (samostatný, kdykoli odvolatelný souhlas).</span>
      </label>
      <Button variant="primary" onClick={save} loading={busy}>Uložit</Button>

      <div>
        <h3 className="font-bold">Moje podněty</h3>
        {!mine ? <p className="text-ink-faint">Načítám…</p> : mine.length === 0 ? <p className="text-ink-soft">Zatím žádné.</p> : (
          <ul className="mt-1 divide-y divide-slate-100">
            {mine.map((m) => (
              <li key={m.id}>
                <button className="flex w-full gap-2 py-2 text-left" onClick={() => { onOpenReport(m.id); onClose(); }}>
                  <span className="min-w-0 flex-1 truncate">{m.title}{m.pending ? <span className="ml-1 text-xs font-semibold text-amber-700">(čeká na schválení správcem)</span> : m.is_hidden && <span className="ml-1 text-xs text-ink-faint">(skryto)</span>}</span>
                  <span className="shrink-0 text-xs text-ink-faint">{formatDate(m.created_at)} · {m.people}×</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="flex flex-wrap gap-2 border-t border-slate-100 pt-3">
        <Button variant="outline" onClick={async () => { await signOut(); onChanged(); onClose(); toast('Odhlášeno', 'info'); }}><LogOut className="h-4 w-4" /> Odhlásit</Button>
        <Button variant="ghost" className="text-red-600" onClick={async () => {
          if (!confirm('Opravdu smazat účet? Vaše podpory a kontaktní údaje budou smazány, podněty zůstanou v mapě anonymně.')) return;
          try { await api.deleteMyAccount(); await signOut(); toast('Účet byl smazán', 'info'); onChanged(); onClose(); } catch (e) { toast(errorMessage(e), 'error'); }
        }}>Smazat účet a údaje</Button>
      </div>
    </div>
  );
}
