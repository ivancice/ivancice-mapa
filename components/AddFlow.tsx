'use client';
import { useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import { Camera, Check, CircleDot, ImagePlus, Pentagon, Spline, ThumbsUp, Trash2, Undo2, X } from 'lucide-react';
import type { Category, DrawGeometry, Frequency, GeomKind, MyProfile, NearbyReport, PublicConfig } from '@/lib/types';
import { FREQUENCY_LABEL, KIND_HINT, KIND_LABEL } from '@/lib/types';
import { Button, CategoryBadge, Field, inputCls, Modal, Sheet, toast } from '@/components/ui';
import { api, errorMessage } from '@/lib/api';
import { ensureSession } from '@/lib/auth';
import { uploadPhoto } from '@/lib/photos';
import { formatArea, formatLength, lastName, lineLengthM, plural, rememberName, ringAreaM2 } from '@/lib/geo';
import { getSupabase } from '@/lib/supabase/client';
import { reportUrl } from '@/lib/env';
import { Turnstile, captchaEnabled } from '@/components/Turnstile';
import type { Position } from 'geojson';

export interface Draft {
  category_id: number | null;
  subcategory_id: number | null;
  kind: GeomKind;
  coords: Position[];
  variant_of: string | null;
  variant_title?: string | null;
  title?: string;
}

export const KIND_ICON = { point: CircleDot, line: Spline, polygon: Pentagon } as const;

export function defaultKind(cat: Category | undefined, subId: number | null): GeomKind {
  const sub = cat?.subcategories.find((s) => s.id === subId);
  return sub?.default_geom ?? cat?.default_geom ?? 'point';
}

// --- 1. výběr kategorie -------------------------------------------------------
export function CategoryStep({
  config, onPick, onClose
}: { config: PublicConfig; onPick: (catId: number, subId: number | null) => void; onClose: () => void }) {
  const [open, setOpen] = useState<number | null>(null);
  return (
    <Sheet open onClose={onClose} title={<>Co chcete označit?<div className="mt-1 text-sm font-normal text-ink-soft">Vyberte téma. Typ zakreslení (bod, linie, plocha) půjde změnit.</div></>}>
      <div className="grid gap-2">
        {config.categories.map((c) => (
          <div key={c.id} className={clsx('rounded-2xl border transition', open === c.id ? 'border-slate-300 bg-slate-50' : 'border-slate-200')}>
            <button className="flex w-full items-center gap-3 px-3 py-3 text-left" onClick={() => (c.subcategories.length ? setOpen(open === c.id ? null : c.id) : onPick(c.id, null))}>
              <CategoryBadge color={c.color} icon={c.icon} size="lg" />
              <span className="min-w-0 flex-1">
                <span className="block font-semibold leading-tight">{c.name}</span>
                {c.description && <span className="mt-0.5 block text-xs text-ink-soft">{c.description}</span>}
              </span>
            </button>
            {open === c.id && (
              <div className="flex flex-wrap gap-1.5 px-3 pb-3">
                {c.subcategories.map((s) => {
                  const K = KIND_ICON[s.default_geom ?? c.default_geom];
                  return (
                    <button key={s.id} onClick={() => onPick(c.id, s.id)} className="inline-flex items-center gap-1.5 rounded-full border border-slate-300 bg-white px-3 py-1.5 text-sm hover:border-brand-500 hover:bg-brand-50">
                      <K className="h-3.5 w-3.5 text-ink-soft" /> {s.name}
                    </button>
                  );
                })}
                <button onClick={() => onPick(c.id, null)} className="rounded-full px-3 py-1.5 text-sm text-ink-soft underline">Jiné v této kategorii</button>
              </div>
            )}
          </div>
        ))}
      </div>
    </Sheet>
  );
}

// --- 2. kreslení ----------------------------------------------------------------
export function DrawToolbar({
  draft, category, onKind, onUndo, onClear, onFinish, onCancel
}: {
  draft: Draft; category?: Category; onKind: (k: GeomKind) => void; onUndo: () => void; onClear: () => void; onFinish: () => void; onCancel: () => void;
}) {
  const n = draft.coords.length;
  const can = draft.kind === 'point' ? n === 1 : draft.kind === 'line' ? n >= 2 : n >= 3;
  const measure =
    draft.kind === 'line' && n >= 2 ? formatLength(lineLengthM(draft.coords))
      : draft.kind === 'polygon' && n >= 3 ? formatArea(ringAreaM2([...draft.coords, draft.coords[0]])) : '';
  const hint =
    draft.kind === 'point'
      ? n ? 'Bod je umístěn. Klepnutím do mapy ho můžete přesunout.' : 'Klepněte do mapy na místo, kterého se podnět týká.'
      : draft.kind === 'line'
        ? n === 0 ? 'Klepněte do mapy na začátek trasy a pak postupně na další body.' : `Pokračujte klepáním po trase. ${n} ${plural(n, 'bod', 'body', 'bodů')}.`
        : n === 0 ? 'Klepáním do mapy vyznačte rohy území.' : n < 3 ? `Přidejte ještě ${3 - n} ${plural(3 - n, 'bod', 'body', 'bodů')}.` : 'Plochu uzavřete tlačítkem Hotovo (nebo klepnutím na první bod).';
  return (
    <div className="fixed inset-x-2 top-2 z-30 mx-auto max-w-xl rounded-3xl bg-white p-3 shadow-panel md:top-4">
      <div className="flex items-center gap-2">
        {category && <CategoryBadge color={category.color} icon={category.icon} size="sm" />}
        <div className="min-w-0 flex-1 truncate text-sm font-semibold">
          {draft.variant_of ? 'Vlastní varianta: ' : ''}{category?.name ?? 'Nový podnět'}
        </div>
        <button onClick={onCancel} className="rounded-full p-1.5 text-ink-soft hover:bg-slate-100" aria-label="Zrušit kreslení"><X className="h-5 w-5" /></button>
      </div>
      <div className="mt-2 grid grid-cols-3 gap-1 rounded-2xl bg-slate-100 p-1" role="radiogroup" aria-label="Typ zakreslení">
        {(['point', 'line', 'polygon'] as GeomKind[]).map((k) => {
          const K = KIND_ICON[k];
          return (
            <button key={k} role="radio" aria-checked={draft.kind === k} onClick={() => onKind(k)}
              className={clsx('flex items-center justify-center gap-1.5 rounded-xl px-2 py-2 text-sm font-semibold', draft.kind === k ? 'bg-white text-brand-700 shadow-sm' : 'text-ink-soft')}>
              <K className="h-4 w-4" /> {KIND_LABEL[k]}
            </button>
          );
        })}
      </div>
      <p className="mt-2 text-sm text-ink-soft">{hint} {measure && <b className="text-ink">({measure})</b>}</p>
      <div className="mt-2 flex gap-2">
        {draft.kind !== 'point' && (
          <Button variant="outline" onClick={onUndo} disabled={!n} className="px-3"><Undo2 className="h-4 w-4" /> Zpět</Button>
        )}
        <Button variant="ghost" onClick={onClear} disabled={!n} className="px-3"><Trash2 className="h-4 w-4" /></Button>
        <Button variant="primary" onClick={onFinish} disabled={!can} className="flex-1"><Check className="h-4 w-4" /> Hotovo</Button>
      </div>
    </div>
  );
}

// --- 3. upozornění na podobné podněty v okolí ------------------------------------
export function NearbyDialog({
  items, category, onSupport, onDetail, onContinue, onClose
}: { items: NearbyReport[]; category?: Category; onSupport: (id: string) => Promise<void>; onDetail: (id: string) => void; onContinue: () => void; onClose: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  return (
    <Modal open onClose={onClose} title="V okolí už jsou podobné podněty"
      footer={<Button variant="primary" onClick={onContinue}>Přesto vytvořit vlastní podnět</Button>}>
      <p className="text-sm text-ink-soft">
        V kategorii <b>{category?.name}</b> už ostatní označili toto místo. Můžete jejich podnět podpořit – posílí to jeho váhu.
        Pokud vidíte rozsah nebo řešení jinak, vytvořte vlastní zakreslení; původní podněty zůstanou zachovány.
      </p>
      <ul className="mt-3 space-y-2">
        {items.map((r) => (
          <li key={r.id} className="rounded-2xl border border-slate-200 p-3">
            <div className="font-semibold leading-tight">{r.title}</div>
            <div className="mt-0.5 text-xs text-ink-soft">
              {KIND_LABEL[r.kind]} · {r.distance_m} m odsud · {r.people} {plural(r.people, 'člověk', 'lidé', 'lidí')} to vnímá jako problém
            </div>
            <div className="mt-2 flex flex-wrap gap-2">
              {!r.is_mine && (
                <Button variant="primary" className="px-3 py-1.5" loading={busy === r.id}
                  onClick={async () => { setBusy(r.id); try { await onSupport(r.id); } finally { setBusy(null); } }}>
                  <ThumbsUp className="h-4 w-4" /> Také to vnímám jako problém
                </Button>
              )}
              <Button variant="outline" className="px-3 py-1.5" onClick={() => onDetail(r.id)}>Zobrazit detail</Button>
            </div>
          </li>
        ))}
      </ul>
    </Modal>
  );
}

// --- 4. formulář -------------------------------------------------------------------
export function ReportForm({
  config, draft, geometry, profile, onDone, onBack, onCancel, onCategory
}: {
  config: PublicConfig; draft: Draft; geometry: DrawGeometry; profile: MyProfile | null;
  onDone: (r: { id: string; no: number }) => void; onBack: () => void; onCancel: () => void; onCategory: (c: number, s: number | null) => void;
}) {
  const cat = config.categories.find((c) => c.id === draft.category_id);
  const [title, setTitle] = useState(draft.title ?? (draft.subcategory_id ? cat?.subcategories.find((s) => s.id === draft.subcategory_id)?.name ?? '' : ''));
  const [topic, setTopic] = useState('');
  const [desc, setDesc] = useState('');
  const [solution, setSolution] = useState('');
  const [freq, setFreq] = useState<Frequency | ''>('');
  const [name, setName] = useState(profile?.nickname || lastName());
  const [email, setEmail] = useState(profile?.contact_email ?? profile?.email ?? '');
  const [newsletter, setNewsletter] = useState(profile?.newsletter ?? false);
  const [files, setFiles] = useState<File[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const honeypot = useRef<HTMLInputElement>(null);
  const started = useRef(Date.now());
  const maxPhotos = Number(config.settings.max_photos ?? 5);
  const photosOn = config.settings.photos_enabled !== false;
  const previews = useMemo(() => files.map((f) => URL.createObjectURL(f)), [files]);
  const needCaptcha = captchaEnabled && !profile;

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (!draft.category_id) return setErr('Vyberte prosím kategorii.');
    if (title.trim().length < 3) return setErr('Vyplňte prosím název podnětu (alespoň 3 znaky).');
    if (!name.trim()) return setErr('Vyplňte prosím jméno nebo přezdívku.');
    if (Date.now() - started.current < 2500) return setErr('Formulář byl odeslán příliš rychle. Zkuste to prosím znovu.');
    if (needCaptcha && !captcha) return setErr('Potvrďte prosím ověření, že nejste robot.');
    setBusy(true);
    try {
      rememberName(name.trim());
      const uid = await ensureSession(captcha ?? undefined);
      const photos = [];
      if (photosOn) for (const f of files.slice(0, maxPhotos)) photos.push(await uploadPhoto(f, uid));
      const res = await api.createReport({
        category_id: draft.category_id,
        subcategory_id: draft.subcategory_id,
        custom_topic: topic || undefined,
        title: title.trim(),
        description: desc.trim() || undefined,
        solution: solution.trim() || undefined,
        frequency: freq,
        author_name: name.trim(),
        email: email.trim() || undefined,
        newsletter: newsletter && !!email.trim(),
        kind: draft.kind,
        geometry,
        variant_of: draft.variant_of,
        photos,
        website: honeypot.current?.value || undefined
      });
      onDone(res);
    } catch (e2) {
      setErr(errorMessage(e2));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Sheet open onClose={onCancel} wide title={<>Popište podnět<div className="mt-1 text-sm font-normal text-ink-soft">{KIND_LABEL[draft.kind]} ({KIND_HINT[draft.kind]}) je zakreslen. <button type="button" className="underline" onClick={onBack}>Upravit zakreslení</button></div></>}>
      <form onSubmit={submit} className="space-y-4" noValidate>
        {draft.variant_of && (
          <div className="rounded-2xl bg-amber-50 p-3 text-sm text-amber-900">
            Vytváříte vlastní prostorovou variantu k podnětu <b>{draft.variant_title}</b>. Původní zakreslení zůstává beze změny.
          </div>
        )}
        <Field label="Kategorie" required>
          <select className={inputCls} value={draft.category_id ?? ''} onChange={(e) => onCategory(Number(e.target.value), null)}>
            {config.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </Field>
        {cat && cat.subcategories.length > 0 && (
          <Field label="Podkategorie">
            <select className={inputCls} value={draft.subcategory_id ?? ''} onChange={(e) => {
              const v = e.target.value ? Number(e.target.value) : null;
              onCategory(cat.id, v);
              const s = cat.subcategories.find((x) => x.id === v);
              if (s && (!title || cat.subcategories.some((x) => x.name === title))) setTitle(s.name);
            }}>
              <option value="">– nevybráno –</option>
              {cat.subcategories.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </Field>
        )}
        {cat?.allow_custom_topic && (
          <Field label="Vlastní téma" hint="Např. hluk, odpadky, osvětlení hřiště…">
            <input className={inputCls} value={topic} onChange={(e) => setTopic(e.target.value)} maxLength={120} />
          </Field>
        )}
        <Field label="Konkrétní problém nebo název podnětu" required>
          <input className={inputCls} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={140} placeholder="Např. Chybí přechod u zastávky" />
        </Field>
        <Field label="Podrobnější komentář">
          <textarea className={clsx(inputCls, 'min-h-[84px]')} value={desc} onChange={(e) => setDesc(e.target.value)} maxLength={3000} placeholder="Co přesně je problém? Kdy nastává?" />
        </Field>
        <Field label="Návrh řešení">
          <textarea className={clsx(inputCls, 'min-h-[64px]')} value={solution} onChange={(e) => setSolution(e.target.value)} maxLength={3000} placeholder="Jak by se to dalo zlepšit?" />
        </Field>
        <fieldset>
          <legend className="mb-1 text-sm font-semibold">Jak často se na tomto místě pohybujete? <span className="font-normal text-ink-faint">(nepovinné)</span></legend>
          <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-4">
            {(Object.keys(FREQUENCY_LABEL) as Frequency[]).map((f) => (
              <button type="button" key={f} onClick={() => setFreq(freq === f ? '' : f)}
                className={clsx('rounded-xl border px-2 py-2 text-sm', freq === f ? 'border-brand-600 bg-brand-50 font-semibold text-brand-800' : 'border-slate-300')}>
                {FREQUENCY_LABEL[f]}
              </button>
            ))}
          </div>
        </fieldset>
        {photosOn && <div>
          <span className="mb-1 block text-sm font-semibold">Fotografie místa <span className="font-normal text-ink-faint">(nepovinné, max. {maxPhotos})</span></span>
          <div className="flex flex-wrap gap-2">
            {previews.map((src, i) => (
              <div key={src} className="relative h-20 w-20 overflow-hidden rounded-xl bg-slate-100">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={src} alt="" className="h-full w-full object-cover" />
                <button type="button" onClick={() => setFiles(files.filter((_, j) => j !== i))} className="absolute right-1 top-1 rounded-full bg-black/60 p-0.5 text-white" aria-label="Odebrat fotografii"><X className="h-3.5 w-3.5" /></button>
              </div>
            ))}
            {files.length < maxPhotos && (
              <>
                <label className="flex h-20 w-20 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-slate-300 text-xs text-ink-soft hover:border-brand-500">
                  <Camera className="h-5 w-5" /> Vyfotit
                  <input type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => e.target.files && setFiles([...files, ...Array.from(e.target.files)].slice(0, maxPhotos))} />
                </label>
                <label className="flex h-20 w-20 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-slate-300 text-xs text-ink-soft hover:border-brand-500">
                  <ImagePlus className="h-5 w-5" /> Z galerie
                  <input type="file" accept="image/*" multiple className="hidden" onChange={(e) => e.target.files && setFiles([...files, ...Array.from(e.target.files)].slice(0, maxPhotos))} />
                </label>
              </>
            )}
          </div>
          <p className="mt-1 text-xs text-ink-soft">Na fotografiích prosím nezachycujte rozpoznatelné osoby ani SPZ. Údaje o poloze z fotografie se odstraní.</p>
        </div>}

        <div className="rounded-2xl bg-slate-50 p-3">
          <Field label="Jméno nebo přezdívka" required hint="Zobrazí se u podnětu veřejně.">
            <input className={inputCls} value={name} onChange={(e) => setName(e.target.value)} maxLength={60} autoComplete="nickname" />
          </Field>
          <div className="mt-3">
            <Field label="E-mail" hint="Nebude zveřejněn. Slouží jen pro případný doplňující dotaz nebo zasílání výsledků.">
              <input className={inputCls} type="email" value={email} onChange={(e) => setEmail(e.target.value)} maxLength={200} autoComplete="email" inputMode="email" />
            </Field>
          </div>
          <label className={clsx('mt-3 flex items-start gap-2 text-sm', !email.trim() && 'opacity-50')}>
            <input type="checkbox" className="mt-0.5 h-4 w-4 accent-brand-600" checked={newsletter && !!email.trim()} disabled={!email.trim()} onChange={(e) => setNewsletter(e.target.checked)} />
            <span>Souhlasím se zasíláním informací o výsledcích mapování a novinkách na uvedený e-mail. Souhlas mohu kdykoli odvolat.</span>
          </label>
        </div>
        <input ref={honeypot} name="website" tabIndex={-1} autoComplete="off" className="absolute -left-[9999px] h-0 w-0 opacity-0" aria-hidden />
        {needCaptcha && <Turnstile onToken={setCaptcha} />}
        <p className="text-xs text-ink-soft">
          Odesláním berete na vědomí <Link href="/ochrana-osobnich-udaju" target="_blank" className="underline">zásady zpracování osobních údajů</Link>.
          Podnět se zobrazí v mapě veřejně, včetně jména či přezdívky.
        </p>
        {err && <div className="rounded-xl bg-red-50 p-3 text-sm font-medium text-red-700" role="alert">{err}</div>}
        <div className="flex gap-2 pb-2">
          <Button type="button" variant="outline" onClick={onBack}>Zpět</Button>
          <Button type="submit" variant="primary" className="flex-1" loading={busy}>Odeslat podnět</Button>
        </div>
      </form>
    </Sheet>
  );
}

// --- 5. potvrzení ------------------------------------------------------------------
export function SuccessModal({ no, id, verified, onClose, onLogin, onShow }: { no: number; id: string; verified: boolean; onClose: () => void; onLogin: () => void; onShow: () => void }) {
  const url = typeof window !== 'undefined' ? reportUrl(id) : '';
  return (
    <Modal open onClose={onClose} title="Děkujeme, podnět byl přidán!"
      footer={<><Button variant="outline" onClick={onShow}>Zobrazit v mapě</Button><Button variant="primary" onClick={onClose}>Pokračovat</Button></>}>
      <div className="flex items-center gap-3 rounded-2xl bg-brand-50 p-4 text-brand-900">
        <Check className="h-8 w-8 shrink-0 rounded-full bg-brand-600 p-1.5 text-white" />
        <div>Váš podnět <b>č. {no}</b> je uložen a zobrazuje se v mapě. Ostatní ho teď mohou podpořit.</div>
      </div>
      <div className="mt-3 flex gap-2">
        <input readOnly value={url} className={clsx(inputCls, 'text-xs')} onFocus={(e) => e.target.select()} />
        <Button variant="outline" onClick={async () => {
          try {
            if (navigator.share) await navigator.share({ title: 'Podnět v mapě Ivančic', url });
            else { await navigator.clipboard.writeText(url); toast('Odkaz zkopírován'); }
          } catch { /* zrušeno */ }
        }}>Sdílet</Button>
      </div>
      {!verified && (
        <p className="mt-3 text-sm text-ink-soft">
          Chcete podporovat podněty ostatních nebo mít přehled o svých podnětech na více zařízeních?{' '}
          <button className="font-semibold text-brand-700 underline" onClick={onLogin}>Přihlaste se e-mailem</button> – bez hesla, stačí kliknout na odkaz.
        </p>
      )}
    </Modal>
  );
}

export async function currentUserId(): Promise<string | null> {
  const { data } = await getSupabase().auth.getSession();
  return data.session?.user.id ?? null;
}
