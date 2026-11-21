'use client';
import { useCallback, useEffect, useState } from 'react';
import clsx from 'clsx';
import { Camera, ChevronDown, Flag, GitBranch, MapPin, Pencil, Share2, ThumbsUp, Trash2, Users, X } from 'lucide-react';
import type { MyProfile, NearbyReport, PublicConfig, ReportDetail as RD } from '@/lib/types';
import { FREQUENCY_LABEL, KIND_LABEL, STATUS_COLOR, STATUS_LABEL } from '@/lib/types';
import { api, errorMessage } from '@/lib/api';
import { Button, CategoryBadge, Field, inputCls, Modal, Sheet, Spinner, toast } from '@/components/ui';
import { formatArea, formatDate, formatLength, lastName, plural, rememberName } from '@/lib/geo';
import { photoUrl, reportUrl } from '@/lib/env';
import { ensureSession } from '@/lib/auth';
import { uploadPhoto } from '@/lib/photos';

const FLAG_REASONS: Record<string, string> = {
  spam: 'Spam nebo reklama',
  offensive: 'Urážlivý nebo nevhodný obsah',
  personal_data: 'Obsahuje osobní údaje (tváře, SPZ, jména…)',
  duplicate: 'Duplicitní podnět',
  wrong_location: 'Špatně umístěno',
  other: 'Jiný důvod'
};

export function ReportDetailPanel({
  id, config, profile, onClose, onChanged, onCreateVariant, onHighlight, onOpen, onLogin, onZoom
}: {
  id: string;
  config: PublicConfig;
  profile: MyProfile | null;
  onClose: () => void;
  onChanged: () => void;
  onCreateVariant: (r: RD) => void;
  onHighlight: (ids: string[]) => void;
  onOpen: (id: string) => void;
  onLogin: (reason: string) => void;
  onZoom: (r: RD) => void;
}) {
  const [r, setR] = useState<RD | null>(null);
  const [loading, setLoading] = useState(true);
  const [missing, setMissing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [around, setAround] = useState<NearbyReport[] | null>(null);
  const [comment, setComment] = useState('');
  const [cName, setCName] = useState(profile?.nickname || lastName());
  const [cFile, setCFile] = useState<File | null>(null);
  const [cBusy, setCBusy] = useState(false);
  const [flagOpen, setFlagOpen] = useState<{ comment?: string; photo?: string } | null>(null);
  const [editOpen, setEditOpen] = useState(false);
  const [photo, setPhoto] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const d = await api.report(id);
      if (!d) { setMissing(true); return; }
      if (d.merged_into) { onOpen(d.merged_into); return; }
      setR(d);
      setMissing(false);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setLoading(false);
    }
  }, [id, onOpen]);

  useEffect(() => {
    setLoading(true);
    setAround(null);
    setR(null);
    load();
  }, [load]);

  useEffect(() => {
    if (profile?.nickname && !cName) setCName(profile.nickname);
  }, [profile, cName]);

  const cat = config.categories.find((c) => c.id === r?.category_id);
  const sub = cat?.subcategories.find((s) => s.id === r?.subcategory_id);

  async function toggleSupport() {
    if (!r) return;
    if (config.settings.support_requires_verified !== false && !profile?.is_verified) {
      onLogin('Pro podporu podnětu se prosím přihlaste odkazem zaslaným na e-mail. Zajistíme tak, že každý hlasuje jen jednou.');
      return;
    }
    setBusy(true);
    try {
      await ensureSession();
      const res = await api.setSupport(r.id, !r.my_support);
      setR({ ...r, my_support: res.my_support, people: res.people, supporters: res.supporters });
      toast(res.my_support ? 'Děkujeme za podporu!' : 'Podpora odebrána', 'ok');
      onChanged();
    } catch (e) {
      const msg = errorMessage(e);
      if (/přihlásit|přihlaste/i.test(msg)) onLogin(msg);
      else toast(msg, 'error');
    } finally {
      setBusy(false);
    }
  }

  async function sendComment(e: React.FormEvent) {
    e.preventDefault();
    if (!r || !comment.trim()) return;
    if (config.settings.contribute_requires_login && !profile?.is_verified) {
      onLogin('Pro přidání komentáře se prosím přihlaste odkazem zaslaným na e-mail.');
      return;
    }
    if (!cName.trim()) return toast('Vyplňte prosím jméno nebo přezdívku.', 'error');
    setCBusy(true);
    try {
      rememberName(cName.trim());
      const uid = await ensureSession();
      const photos = cFile ? [await uploadPhoto(cFile, uid)] : undefined;
      await api.addComment(r.id, comment.trim(), cName.trim(), photos);
      setComment('');
      setCFile(null);
      toast('Komentář přidán');
      await load();
      onChanged();
    } catch (e2) {
      toast(errorMessage(e2), 'error');
    } finally {
      setCBusy(false);
    }
  }

  async function showAround() {
    if (!r) return;
    if (around) { setAround(null); onHighlight([]); return; }
    try {
      const a = await api.around(r.id, 150);
      setAround(a);
      onHighlight(a.map((x) => x.id));
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  }

  async function share() {
    if (!r) return;
    const url = reportUrl(r.id);
    try {
      if (navigator.share) await navigator.share({ title: r.title, text: 'Podnět v mapě Ivančice očima pěších a cyklistů', url });
      else { await navigator.clipboard.writeText(url); toast('Odkaz zkopírován do schránky'); }
    } catch { /* zrušeno */ }
  }

  if (loading) return <Sheet open onClose={onClose}><div className="flex justify-center py-10"><Spinner /></div></Sheet>;
  if (missing || !r) return <Sheet open onClose={onClose} title="Podnět nenalezen"><p className="text-sm text-ink-soft">Podnět neexistuje, byl skryt správcem nebo stažen autorem.</p></Sheet>;

  const photosOn = config.settings.photos_enabled !== false;
  return (
    <Sheet open onClose={onClose} wide z={35}
      title={
        <div className="flex flex-col items-center pl-7 text-center">
          {cat && <CategoryBadge color={cat.color} icon={cat.icon} size="lg" />}
          <div className="mt-2 text-xs font-semibold" style={{ color: cat?.color }}>{cat?.name}</div>
          <div className="mt-0.5 text-xl leading-snug">{r.title}</div>
          {(r.district || (sub && sub.name !== r.title)) && (
            <div className="mt-1 flex items-center gap-1 text-sm font-normal text-ink-soft">
              <MapPin className="h-3.5 w-3.5 shrink-0" />{[r.district, sub && sub.name !== r.title ? sub.name : null].filter(Boolean).join(' · ')}
            </div>
          )}
        </div>
      }
    >
      {r.is_demo && <div className="mb-3 rounded-xl bg-amber-100 px-3 py-2 text-xs font-semibold text-amber-900">UKÁZKOVÝ PODNĚT – testovací data, nejde o skutečný příspěvek obyvatel.</div>}
      {r.is_hidden && <div className="mb-3 rounded-xl bg-slate-200 px-3 py-2 text-xs font-semibold">Tento podnět je skrytý a veřejnost ho nevidí.</div>}

      <div className="mt-2 flex items-center gap-3 rounded-2xl p-3" style={{ backgroundColor: `${cat?.color ?? '#64748b'}1f` }}>
        <div className="min-w-[2rem] text-center text-2xl font-extrabold" style={{ color: cat?.color }}>{r.people}</div>
        <div className="min-w-0 flex-1 text-sm leading-snug">
          <b>{plural(r.people, 'člověk to vnímá', 'lidé to vnímají', 'lidí to vnímá')} jako problém</b>
          <div className="text-xs text-ink-soft">{r.supporters} {plural(r.supporters, 'podpora', 'podpory', 'podpor')}{r.merged_count > 0 && ` · sloučeno ${r.merged_count}×`}</div>
        </div>
        {r.is_mine ? (
          <span className="shrink-0 rounded-full bg-white px-3 py-2 text-xs font-semibold text-ink-soft">Váš podnět</span>
        ) : (
          <Button variant={r.my_support ? 'outline' : 'primary'} className="shrink-0 rounded-full px-4 py-2" onClick={toggleSupport} loading={busy} aria-pressed={r.my_support}>
            <ThumbsUp className={clsx('h-4 w-4', r.my_support && 'fill-current')} /> {r.my_support ? 'Podpořeno' : 'Podpořit'}
          </Button>
        )}
      </div>

      {r.status && (
        <div className="mt-3 flex flex-wrap items-center justify-center gap-2 text-sm">
          <span className="rounded-full px-2.5 py-1 text-xs font-bold text-white" style={{ backgroundColor: STATUS_COLOR[r.status] }}>{STATUS_LABEL[r.status]}</span>
          {r.status_note && <span className="text-ink-soft">{r.status_note}</span>}
        </div>
      )}

      {r.custom_topic && <p className="mt-3 text-sm"><b>Téma:</b> {r.custom_topic}</p>}
      {r.description && <p className="mt-3 whitespace-pre-line text-[15px] leading-relaxed">{r.description}</p>}
      {r.solution && (
        <div className="mt-3 rounded-2xl border-l-4 border-brand-500 bg-brand-50 p-3 text-sm">
          <div className="mb-0.5 font-semibold text-brand-800">Návrh řešení</div>
          <p className="whitespace-pre-line">{r.solution}</p>
        </div>
      )}

      {(r.photos.length > 0 || photosOn) && (
        <div className="mt-3 flex gap-2 overflow-x-auto pb-1">
          {r.photos.map((p) => (
            <button key={p.id} onClick={() => setPhoto(p.path)} className="relative h-24 w-32 shrink-0 overflow-hidden rounded-xl bg-slate-100">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={photoUrl(p.path)} alt="Fotografie místa" className="h-full w-full object-cover" loading="lazy" />
            </button>
          ))}
          {photosOn && (
            <button onClick={() => { document.getElementById('comment-photo')?.click(); }}
              className="flex h-24 w-32 shrink-0 flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-slate-300 text-xs text-ink-soft hover:border-brand-500 hover:text-brand-700">
              <Camera className="h-5 w-5" /> Přidat fotografii
            </button>
          )}
        </div>
      )}

      <div className="mt-3 grid grid-cols-2 gap-2">
        <Button variant="outline" onClick={() => onCreateVariant(r)} className="text-xs sm:text-sm" title="Vidíte-li rozsah nebo trasu jinak, zakreslete vlastní variantu. Původní zakreslení zůstane zachováno.">
          <GitBranch className="h-4 w-4" /> Zakreslit po svém
        </Button>
        <Button variant="outline" onClick={showAround} className="text-xs sm:text-sm" title="Ukáže další zakreslení do 150 m">
          <Users className="h-4 w-4" /> {around ? 'Skrýt okolí' : 'Další zakreslení zde'}
        </Button>
      </div>

      <details className="group mt-3 border-y border-slate-100">
        <summary className="flex cursor-pointer list-none items-center justify-between py-3 text-sm font-semibold [&::-webkit-details-marker]:hidden">
          Podrobnosti <ChevronDown className="h-4 w-4 transition group-open:rotate-180" />
        </summary>
        <dl className="divide-y divide-slate-100 pb-2 text-sm">
          <div className="flex justify-between gap-3 py-1.5"><dt className="text-ink-soft">Autor</dt><dd className="text-right font-medium">{r.author_name}</dd></div>
          <div className="flex justify-between gap-3 py-1.5"><dt className="text-ink-soft">Vloženo</dt><dd className="text-right font-medium">{formatDate(r.created_at)} · č. {r.no}</dd></div>
          <div className="flex justify-between gap-3 py-1.5"><dt className="text-ink-soft">Zakreslení</dt><dd className="text-right font-medium">{KIND_LABEL[r.kind]}{r.length_m ? ` · ${formatLength(r.length_m)}` : ''}{r.area_m2 ? ` · ${formatArea(r.area_m2)}` : ''}</dd></div>
          {r.frequency && <div className="flex justify-between gap-3 py-1.5"><dt className="text-ink-soft">Autor se zde pohybuje</dt><dd className="text-right font-medium">{FREQUENCY_LABEL[r.frequency]}</dd></div>}
          <div className="flex justify-between gap-3 py-1.5"><dt className="text-ink-soft">Autoři zakreslení</dt><dd className="text-right font-medium">{r.authors}</dd></div>
          <div className="flex justify-between gap-3 py-1.5">
            <dt className="text-ink-soft">Prostorová shoda</dt>
            <dd className="text-right font-medium">
              {r.overlap_people > 0
                ? `${r.overlap_people} ${plural(r.overlap_people, 'další člověk', 'další lidé', 'dalších lidí')} zakreslilo totéž${r.agreement != null ? ` (${Math.round(r.agreement * 100)} %)` : ''}`
                : 'zatím bez shody'}
            </dd>
          </div>
        </dl>
        <div className="flex justify-center gap-1 pb-3">
          <Button variant="ghost" onClick={() => onZoom(r)} className="text-xs"><MapPin className="h-4 w-4" /> Přiblížit</Button>
          <Button variant="ghost" onClick={share} className="text-xs"><Share2 className="h-4 w-4" /> Sdílet</Button>
          <Button variant="ghost" onClick={() => setFlagOpen({})} className="text-xs"><Flag className="h-4 w-4" /> Nahlásit</Button>
        </div>
      </details>

      {r.variant_of && (
        <p className="mt-3 text-sm">Varianta k podnětu: <button className="font-semibold text-brand-700 underline" onClick={() => onOpen(r.variant_of!.id)}>{r.variant_of.title}</button></p>
      )}
      {r.variants.length > 0 && (
        <div className="mt-3 text-sm">
          <div className="font-semibold">Vlastní varianty ostatních ({r.variants.length})</div>
          <ul className="mt-1 space-y-1">
            {r.variants.map((v) => (
              <li key={v.id}><button className="text-left text-brand-700 underline" onClick={() => onOpen(v.id)}>{v.title}</button> <span className="text-ink-faint">– {v.author_name}, {KIND_LABEL[v.kind].toLowerCase()}</span></li>
            ))}
          </ul>
        </div>
      )}

      {around && (
        <div className="mt-3 rounded-2xl border border-slate-200 p-3">
          <div className="text-sm font-semibold">Zakreslení do 150 m ({around.length})</div>
          {around.length === 0 && <p className="text-sm text-ink-soft">V okolí nejsou další podněty.</p>}
          <ul className="mt-1 divide-y divide-slate-100">
            {around.map((a) => {
              const c = config.categories.find((x) => x.id === a.category_id);
              return (
                <li key={a.id}>
                  <button onClick={() => onOpen(a.id)} className="flex w-full items-center gap-2 py-2 text-left text-sm">
                    <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ backgroundColor: c?.color }} />
                    <span className="min-w-0 flex-1 truncate">{a.title}</span>
                    <span className="shrink-0 text-xs text-ink-faint">{a.distance_m} m · {a.people}×</span>
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      )}

      {r.is_mine && (
        <div className="mt-4 flex gap-2 rounded-2xl bg-slate-50 p-3 text-sm">
          <span className="flex-1 text-ink-soft">Toto je váš podnět.</span>
          <Button variant="outline" className="px-3 py-1.5" onClick={() => setEditOpen(true)}><Pencil className="h-4 w-4" /> Upravit</Button>
          <Button variant="ghost" className="px-3 py-1.5 text-red-600" onClick={async () => {
            if (!confirm('Opravdu stáhnout podnět z mapy?')) return;
            try { await api.withdrawMyReport(r.id); toast('Podnět byl stažen'); onChanged(); onClose(); } catch (e) { toast(errorMessage(e), 'error'); }
          }}><Trash2 className="h-4 w-4" /></Button>
        </div>
      )}

      <section className="mt-5">
        <h3 className="text-sm font-bold">Komentáře ({r.comments.length})</h3>
        <ul className="mt-2 space-y-2">
          {r.comments.map((c) => (
            <li key={c.id} className={clsx('rounded-2xl bg-slate-50 p-3 text-sm', c.is_hidden && 'opacity-50')}>
              <div className="flex items-center gap-2 text-xs text-ink-soft">
                <b className="text-ink">{c.author_name}</b> · {formatDate(c.created_at)}
                <button className="ml-auto text-ink-faint hover:text-red-600" onClick={() => setFlagOpen({ comment: c.id })} aria-label="Nahlásit komentář"><Flag className="h-3.5 w-3.5" /></button>
              </div>
              <p className="mt-1 whitespace-pre-line">{c.body}</p>
              {c.photos.map((p) => (
                <button key={p.id} onClick={() => setPhoto(p.path)} className="mt-2 block h-24 w-32 overflow-hidden rounded-xl">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={photoUrl(p.path)} alt="Fotografie" className="h-full w-full object-cover" loading="lazy" />
                </button>
              ))}
            </li>
          ))}
        </ul>
        <form onSubmit={sendComment} className="mt-3 space-y-2">
          <textarea className={clsx(inputCls, 'min-h-[70px]')} placeholder={photosOn ? 'Přidat komentář, zkušenost nebo fotografii…' : 'Přidat komentář nebo vlastní zkušenost…'} value={comment} onChange={(e) => setComment(e.target.value)} maxLength={2000} />
          {cFile && <p className="text-xs text-ink-soft">Připojena fotografie: {cFile.name} – napište k ní krátký komentář a odešlete. <button type="button" className="underline" onClick={() => setCFile(null)}>Odebrat</button></p>}
          <div className="flex flex-wrap items-center gap-2">
            {(comment || cFile) && <input className={clsx(inputCls, 'w-auto flex-1')} placeholder="Jméno nebo přezdívka *" value={cName} onChange={(e) => setCName(e.target.value)} maxLength={60} />}
            {photosOn && <label className="inline-flex cursor-pointer items-center gap-1 rounded-xl border border-slate-300 px-3 py-2.5 text-sm">
              <Camera className="h-4 w-4" /> {cFile ? '1 foto' : 'Přidat foto'}
              <input id="comment-photo" type="file" accept="image/*" className="hidden" onChange={(e) => setCFile(e.target.files?.[0] ?? null)} />
            </label>}
            {(comment || cFile) && <Button type="submit" variant="primary" loading={cBusy}>Odeslat</Button>}
          </div>
        </form>
      </section>

      {flagOpen && <FlagModal reportId={r.id} commentId={flagOpen.comment} photoId={flagOpen.photo} onClose={() => setFlagOpen(null)} />}
      {editOpen && <EditOwnModal r={r} onClose={() => setEditOpen(false)} onSaved={() => { setEditOpen(false); load(); onChanged(); }} />}
      {photo && (
        <div className="fixed inset-0 z-[70] flex items-center justify-center bg-black/90 p-4" onClick={() => setPhoto(null)}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={photoUrl(photo)} alt="Fotografie" className="max-h-full max-w-full rounded-lg" />
          <button className="absolute right-4 top-4 rounded-full bg-white/20 p-2 text-white" aria-label="Zavřít"><X className="h-6 w-6" /></button>
          <button className="absolute bottom-4 right-4 rounded-full bg-white/20 px-3 py-1.5 text-xs text-white" onClick={(e) => {
            e.stopPropagation();
            const ph = [...r.photos, ...r.comments.flatMap((c) => c.photos)].find((p) => p.path === photo);
            setPhoto(null);
            setFlagOpen({ photo: ph?.id });
          }}>Nahlásit fotografii</button>
        </div>
      )}
    </Sheet>
  );
}

function FlagModal({ reportId, commentId, photoId, onClose }: { reportId: string; commentId?: string; photoId?: string; onClose: () => void }) {
  const [reason, setReason] = useState('spam');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <Modal open onClose={onClose} title={commentId ? 'Nahlásit komentář' : photoId ? 'Nahlásit fotografii' : 'Nahlásit podnět'}
      footer={<><Button variant="ghost" onClick={onClose}>Zrušit</Button><Button variant="danger" loading={busy} onClick={async () => {
        setBusy(true);
        try {
          await ensureSession();
          await api.flag({ report: commentId || photoId ? null : reportId, comment: commentId, photo: photoId, reason, note });
          toast('Děkujeme, správce obsah zkontroluje.');
          onClose();
        } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
      }}>Nahlásit</Button></>}>
      <div className="space-y-2">
        {Object.entries(FLAG_REASONS).map(([k, v]) => (
          <label key={k} className="flex items-center gap-2 text-sm"><input type="radio" name="reason" checked={reason === k} onChange={() => setReason(k)} className="accent-brand-600" /> {v}</label>
        ))}
        <Field label="Poznámka"><textarea className={inputCls} value={note} onChange={(e) => setNote(e.target.value)} maxLength={1000} /></Field>
      </div>
    </Modal>
  );
}

function EditOwnModal({ r, onClose, onSaved }: { r: RD; onClose: () => void; onSaved: () => void }) {
  const [title, setTitle] = useState(r.title);
  const [desc, setDesc] = useState(r.description ?? '');
  const [sol, setSol] = useState(r.solution ?? '');
  const [busy, setBusy] = useState(false);
  return (
    <Modal open onClose={onClose} title="Upravit můj podnět"
      footer={<><Button variant="ghost" onClick={onClose}>Zrušit</Button><Button variant="primary" loading={busy} onClick={async () => {
        setBusy(true);
        try { await api.updateMyReport(r.id, title, desc, sol); toast('Uloženo'); onSaved(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
      }}>Uložit</Button></>}>
      <div className="space-y-3">
        <Field label="Název" required><input className={inputCls} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={140} /></Field>
        <Field label="Komentář"><textarea className={clsx(inputCls, 'min-h-[90px]')} value={desc} onChange={(e) => setDesc(e.target.value)} maxLength={3000} /></Field>
        <Field label="Návrh řešení"><textarea className={clsx(inputCls, 'min-h-[70px]')} value={sol} onChange={(e) => setSol(e.target.value)} maxLength={3000} /></Field>
        <p className="text-xs text-ink-soft">Zakreslení nelze měnit – pokud chcete jiný rozsah, vytvořte novou variantu.</p>
      </div>
    </Modal>
  );
}
