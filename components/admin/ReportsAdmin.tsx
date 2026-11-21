'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import { ExternalLink, Merge, Search } from 'lucide-react';
import { adminApi, type AdminReport } from '@/lib/adminApi';
import { useAdmin } from '@/components/admin/AdminShell';
import { errorMessage } from '@/lib/api';
import { Button, Field, Modal, Sheet, Spinner, inputCls, toast } from '@/components/ui';
import { KIND_LABEL, STATUS_COLOR, STATUS_LABEL, type ReportStatus } from '@/lib/types';
import { formatDate } from '@/lib/geo';
import { deleteStoragePhotos } from '@/lib/photos';

export default function ReportsAdmin() {
  const { config } = useAdmin();
  const [rows, setRows] = useState<AdminReport[] | null>(null);
  const [f, setF] = useState({ q: '', category_id: '', district_id: '', status: '', kind: '', visibility: 'all', demo: 'all' });
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [edit, setEdit] = useState<AdminReport | null>(null);
  const [mergeOpen, setMergeOpen] = useState(false);
  const [sort, setSort] = useState<'created' | 'people' | 'overlap'>('created');

  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get('q');
    if (q) setF((x) => ({ ...x, q }));
  }, []);

  const load = useCallback(async () => {
    try {
      const p: Record<string, unknown> = { with_contacts: true, visibility: f.visibility, demo: f.demo };
      if (f.category_id) p.category_id = Number(f.category_id);
      if (f.district_id) p.district_id = Number(f.district_id);
      if (f.status) p.status = f.status;
      if (f.kind) p.kind = f.kind;
      if (f.q) p.q = f.q;
      setRows(await adminApi.reports(p));
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  }, [f]);

  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [load]);

  const sorted = useMemo(() => {
    if (!rows) return [];
    const r = [...rows];
    if (sort === 'people') r.sort((a, b) => b.people - a.people);
    if (sort === 'overlap') r.sort((a, b) => b.overlap_people - a.overlap_people);
    return r;
  }, [rows, sort]);

  const cat = (id: number) => config.categories.find((c) => c.id === id);
  const dist = (id: number | null) => config.districts.find((d) => d.id === id)?.name ?? '';

  async function bulkStatus(status: ReportStatus) {
    for (const id of sel) await adminApi.updateReport(id, { status });
    toast(`Stav změněn u ${sel.size} podnětů`);
    setSel(new Set());
    load();
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="mr-auto text-xl font-extrabold">Podněty {rows && <span className="text-base font-semibold text-ink-faint">({rows.length})</span>}</h1>
      </div>
      <div className="grid grid-cols-2 gap-2 rounded-2xl bg-white p-3 shadow-sm md:grid-cols-4 xl:grid-cols-8">
        <label className="relative col-span-2">
          <Search className="absolute left-3 top-3 h-4 w-4 text-ink-faint" />
          <input className={`${inputCls} py-2 pl-9`} placeholder="Hledat název, popis, autora, číslo…" value={f.q} onChange={(e) => setF({ ...f, q: e.target.value })} />
        </label>
        <select className={`${inputCls} py-2`} value={f.category_id} onChange={(e) => setF({ ...f, category_id: e.target.value })}>
          <option value="">Všechny kategorie</option>
          {config.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <select className={`${inputCls} py-2`} value={f.district_id} onChange={(e) => setF({ ...f, district_id: e.target.value })}>
          <option value="">Všechny lokality</option>
          {config.districts.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
        </select>
        <select className={`${inputCls} py-2`} value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
          <option value="">Všechny stavy</option>
          {(Object.keys(STATUS_LABEL) as ReportStatus[]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
        </select>
        <select className={`${inputCls} py-2`} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}>
          <option value="">Body, linie, plochy</option>
          <option value="point">Body</option><option value="line">Linie</option><option value="polygon">Plochy</option>
        </select>
        <select className={`${inputCls} py-2`} value={f.visibility} onChange={(e) => setF({ ...f, visibility: e.target.value })}>
          <option value="all">Vše</option><option value="visible">Zveřejněné</option><option value="hidden">Skryté</option>
          <option value="merged">Sloučené</option><option value="flagged">Nahlášené</option>
        </select>
        <select className={`${inputCls} py-2`} value={f.demo} onChange={(e) => setF({ ...f, demo: e.target.value })}>
          <option value="all">Skutečné i ukázkové</option><option value="real">Jen skutečné</option><option value="demo">Jen ukázkové</option>
        </select>
      </div>

      {sel.size > 0 && (
        <div className="flex flex-wrap items-center gap-2 rounded-2xl bg-brand-50 p-3 text-sm">
          <b>Vybráno: {sel.size}</b>
          <Button variant="outline" className="py-1.5" disabled={sel.size < 2} onClick={() => setMergeOpen(true)}><Merge className="h-4 w-4" /> Sloučit duplicity</Button>
          <select className={`${inputCls} w-auto py-1.5`} defaultValue="" onChange={(e) => e.target.value && bulkStatus(e.target.value as ReportStatus)}>
            <option value="">Změnit stav na…</option>
            {(Object.keys(STATUS_LABEL) as ReportStatus[]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
          </select>
          <Button variant="ghost" className="py-1.5" onClick={() => setSel(new Set())}>Zrušit výběr</Button>
        </div>
      )}

      <div className="overflow-x-auto rounded-2xl bg-white shadow-sm">
        {!rows ? <div className="flex justify-center p-10"><Spinner /></div> : (
          <table className="w-full min-w-[900px] text-sm">
            <thead className="bg-slate-50 text-left text-xs text-ink-soft">
              <tr>
                <th className="p-2"><input type="checkbox" checked={sel.size > 0 && sel.size === sorted.length} onChange={(e) => setSel(e.target.checked ? new Set(sorted.map((r) => r.id)) : new Set())} /></th>
                <th className="p-2">č.</th><th className="p-2">Název</th><th className="p-2">Kategorie</th><th className="p-2">Typ</th>
                <th className="cursor-pointer p-2" onClick={() => setSort('people')}>Lidé {sort === 'people' && '↓'}</th>
                <th className="cursor-pointer p-2" onClick={() => setSort('overlap')}>Shoda {sort === 'overlap' && '↓'}</th>
                <th className="p-2">Lokalita</th><th className="p-2">Stav</th>
                <th className="cursor-pointer p-2" onClick={() => setSort('created')}>Vloženo {sort === 'created' && '↓'}</th><th className="p-2"></th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((r) => (
                <tr key={r.id} className={clsx('border-t border-slate-100 hover:bg-slate-50', (r.is_hidden || r.merged_into) && 'opacity-60')}>
                  <td className="p-2"><input type="checkbox" checked={sel.has(r.id)} onChange={(e) => { const s = new Set(sel); if (e.target.checked) s.add(r.id); else s.delete(r.id); setSel(s); }} /></td>
                  <td className="p-2 tabular-nums text-ink-faint">{r.no}</td>
                  <td className="max-w-[320px] p-2">
                    <button className="block max-w-full truncate text-left font-semibold hover:underline" onClick={() => setEdit(r)}>{r.title}</button>
                    <div className="flex flex-wrap gap-1 text-[11px] text-ink-soft">
                      {r.author_name}
                      {r.is_demo && <span className="rounded bg-amber-100 px-1 text-amber-900">ukázka</span>}
                      {r.is_hidden && <span className="rounded bg-slate-200 px-1">skryto</span>}
                      {r.merged_into && <span className="rounded bg-blue-100 px-1 text-blue-900">sloučeno</span>}
                      {r.variant_of && <span className="rounded bg-purple-100 px-1 text-purple-900">varianta</span>}
                      {r.open_flags > 0 && <span className="rounded bg-red-100 px-1 text-red-800">nahlášeno {r.open_flags}×</span>}
                      {r.source !== 'app' && <span className="rounded bg-slate-100 px-1">{r.source}</span>}
                    </div>
                  </td>
                  <td className="p-2"><span className="inline-flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: cat(r.category_id)?.color }} />{cat(r.category_id)?.name}</span></td>
                  <td className="p-2">{KIND_LABEL[r.kind]}</td>
                  <td className="p-2 tabular-nums">{r.people} <span className="text-[11px] text-ink-faint">({r.supporters} podpor)</span></td>
                  <td className="p-2 tabular-nums">{r.overlap_people > 0 ? `+${r.overlap_people}` : '–'}{r.agreement != null && r.overlap_people > 0 ? <span className="text-[11px] text-ink-faint"> {Math.round(r.agreement * 100)} %</span> : ''}</td>
                  <td className="p-2">{dist(r.district_id)}</td>
                  <td className="p-2"><span className="rounded-full px-2 py-0.5 text-[11px] font-bold text-white" style={{ backgroundColor: STATUS_COLOR[r.status] }}>{STATUS_LABEL[r.status]}</span>{r.status_public && <span className="ml-1 text-[10px] text-ink-faint">veřejný</span>}</td>
                  <td className="p-2 text-ink-soft">{formatDate(r.created_at)}</td>
                  <td className="p-2"><Link href={`/?p=${r.merged_into ?? r.id}`} target="_blank" aria-label="Otevřít v mapě"><ExternalLink className="h-4 w-4 text-ink-faint" /></Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {edit && <EditReport r={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); load(); }} />}
      {mergeOpen && rows && (
        <MergeDialog items={rows.filter((r) => sel.has(r.id))} onClose={() => setMergeOpen(false)} onDone={() => { setMergeOpen(false); setSel(new Set()); load(); }} />
      )}
    </div>
  );
}

function EditReport({ r, onClose, onSaved }: { r: AdminReport; onClose: () => void; onSaved: () => void }) {
  const { config } = useAdmin();
  const [v, setV] = useState({
    title: r.title, description: r.description ?? '', solution: r.solution ?? '', category_id: r.category_id, subcategory_id: r.subcategory_id ?? '', custom_topic: r.custom_topic ?? '',
    status: r.status, status_public: r.status_public, status_note: r.status_note ?? '', is_hidden: r.is_hidden, hidden_reason: r.hidden_reason ?? '',
    admin_note: r.admin_note ?? ''
  });
  const [busy, setBusy] = useState(false);
  const cat = config.categories.find((c) => c.id === Number(v.category_id));

  async function save() {
    setBusy(true);
    try {
      const p: Record<string, unknown> = { ...v, subcategory_id: v.subcategory_id === '' ? '' : String(v.subcategory_id) };
      await adminApi.updateReport(r.id, p);
      toast('Uloženo (původní stav je v auditním záznamu)');
      onSaved();
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Sheet open onClose={onClose} wide z={40} title={<>Podnět č. {r.no}<div className="text-sm font-normal text-ink-soft">{r.author_name}{r.contact_email ? ` · ${r.contact_email}` : ''} · {formatDate(r.created_at)}</div></>}
      footer={<div className="flex gap-2"><Button variant="primary" className="flex-1" onClick={save} loading={busy}>Uložit změny</Button><Link href={`/?p=${r.id}`} target="_blank" className="inline-flex items-center rounded-xl border border-slate-300 px-3 text-sm font-semibold">Detail <ExternalLink className="ml-1 h-4 w-4" /></Link></div>}>
      <div className="space-y-3">
        <Field label="Název" required><input className={inputCls} value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} /></Field>
        <Field label="Popis"><textarea className={`${inputCls} min-h-[80px]`} value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} /></Field>
        <Field label="Návrh řešení"><textarea className={inputCls} value={v.solution} onChange={(e) => setV({ ...v, solution: e.target.value })} /></Field>
        <div className="grid grid-cols-2 gap-2">
          <Field label="Kategorie" required>
            <select className={inputCls} value={v.category_id} onChange={(e) => setV({ ...v, category_id: Number(e.target.value), subcategory_id: '' })}>
              {config.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </Field>
          <Field label="Podkategorie">
            <select className={inputCls} value={v.subcategory_id} onChange={(e) => setV({ ...v, subcategory_id: e.target.value ? Number(e.target.value) : '' })}>
              <option value="">–</option>
              {cat?.subcategories.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </Field>
        </div>
        {cat?.allow_custom_topic && <Field label="Vlastní téma"><input className={inputCls} value={v.custom_topic} onChange={(e) => setV({ ...v, custom_topic: e.target.value })} /></Field>}
        <div className="rounded-2xl bg-slate-50 p-3">
          <div className="grid grid-cols-2 gap-2">
            <Field label="Stav" required>
              <select className={inputCls} value={v.status} onChange={(e) => setV({ ...v, status: e.target.value as ReportStatus })}>
                {(Object.keys(STATUS_LABEL) as ReportStatus[]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
              </select>
            </Field>
            <label className="mt-6 flex items-center gap-2 text-sm font-semibold"><input type="checkbox" className="h-4 w-4 accent-brand-600" checked={v.status_public} onChange={(e) => setV({ ...v, status_public: e.target.checked })} /> Zobrazit stav veřejně</label>
          </div>
          <div className="mt-2"><Field label="Veřejná poznámka ke stavu" hint="Zobrazí se u veřejného stavu"><input className={inputCls} value={v.status_note} onChange={(e) => setV({ ...v, status_note: e.target.value })} placeholder="Např. Předáno odboru dopravy 12. 3." /></Field></div>
        </div>
        <div className="rounded-2xl bg-slate-50 p-3">
          <label className="flex items-center gap-2 text-sm font-semibold"><input type="checkbox" className="h-4 w-4 accent-red-600" checked={v.is_hidden} onChange={(e) => setV({ ...v, is_hidden: e.target.checked })} /> Skrýt podnět (nevhodný obsah)</label>
          {v.is_hidden && <input className={`${inputCls} mt-2`} placeholder="Důvod skrytí (interní)" value={v.hidden_reason} onChange={(e) => setV({ ...v, hidden_reason: e.target.value })} />}
        </div>
        <Field label="Interní poznámka"><textarea className={inputCls} value={v.admin_note} onChange={(e) => setV({ ...v, admin_note: e.target.value })} /></Field>

        <div className="space-y-2 border-t border-slate-100 pt-3 text-sm">
          <div className="text-xs text-ink-soft">{r.people} lidí · {r.supporters} podpor · {r.comments} komentářů · {r.photos} fotografií · shoda +{r.overlap_people}</div>
          <div className="flex flex-wrap gap-2">
            {r.merged_into && <Button variant="outline" className="py-1.5" onClick={async () => { await adminApi.unmerge(r.id); toast('Sloučení zrušeno'); onSaved(); }}>Zrušit sloučení</Button>}
            <Button variant="outline" className="py-1.5" onClick={async () => { try { await adminApi.blockAuthor(r.id, true); toast('Autor zablokován'); } catch (e) { toast(errorMessage(e), 'error'); } }}>Zablokovat autora</Button>
            <Button variant="ghost" className="py-1.5 text-red-600" onClick={async () => {
              if (!confirm('Trvale smazat podnět včetně fotografií? Doporučujeme raději skrýt.')) return;
              try { const res = await adminApi.deleteReport(r.id); await deleteStoragePhotos(res.photo_paths ?? []); toast('Smazáno'); onSaved(); } catch (e) { toast(errorMessage(e), 'error'); }
            }}>Trvale smazat</Button>
          </div>
        </div>
      </div>
    </Sheet>
  );
}

function MergeDialog({ items, onClose, onDone }: { items: AdminReport[]; onClose: () => void; onDone: () => void }) {
  const [target, setTarget] = useState(items.sort((a, b) => b.people - a.people)[0]?.id);
  const [busy, setBusy] = useState(false);
  return (
    <Modal open onClose={onClose} title="Sloučit duplicitní podněty"
      footer={<><Button variant="ghost" onClick={onClose}>Zrušit</Button><Button variant="primary" loading={busy} onClick={async () => {
        setBusy(true);
        try { const r = await adminApi.merge(target, items.filter((i) => i.id !== target).map((i) => i.id)); toast(`Sloučeno ${r.merged} podnětů`); onDone(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
      }}>Sloučit</Button></>}>
      <p className="text-sm text-ink-soft">Vyberte hlavní podnět. Ostatní se do něj sloučí: zůstanou v databázi včetně zakreslení, autorů a komentářů, v mapě se zobrazí jen hlavní podnět a jejich podporovatelé se k němu započítají (každý člověk jednou).</p>
      <ul className="mt-3 space-y-1">
        {items.map((i) => (
          <li key={i.id}><label className="flex items-center gap-2 rounded-xl p-2 text-sm hover:bg-slate-50"><input type="radio" checked={target === i.id} onChange={() => setTarget(i.id)} className="accent-brand-600" /> <b>č. {i.no}</b> {i.title} <span className="ml-auto text-xs text-ink-faint">{i.people} lidí</span></label></li>
        ))}
      </ul>
    </Modal>
  );
}
