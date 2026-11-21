'use client';
import { useCallback, useEffect, useState } from 'react';
import clsx from 'clsx';
import { ArrowDown, ArrowUp, Plus, Trash2 } from 'lucide-react';
import { adminApi } from '@/lib/adminApi';
import { useAdmin } from '@/components/admin/AdminShell';
import { errorMessage } from '@/lib/api';
import { Button, CategoryBadge, Field, ICON_NAMES, CategoryIcon, Spinner, inputCls, toast } from '@/components/ui';
import { KIND_LABEL, type Category, type GeomKind } from '@/lib/types';

const PALETTE = ['#dc2626', '#0891b2', '#ca8a04', '#7c3aed', '#16a34a', '#ea580c', '#64748b', '#db2777', '#0d9488', '#4f46e5', '#65a30d', '#92400e'];

export default function CategoriesAdmin() {
  const { reloadConfig } = useAdmin();
  const [cats, setCats] = useState<Category[] | null>(null);
  const [open, setOpen] = useState<number | 'new' | null>(null);

  const load = useCallback(async () => {
    try { setCats(await adminApi.categories()); } catch (e) { toast(errorMessage(e), 'error'); }
  }, []);
  useEffect(() => { load(); }, [load]);

  const after = async (msg: string) => { toast(msg); await load(); await reloadConfig(); };

  async function move(i: number, d: -1 | 1) {
    if (!cats) return;
    const arr = [...cats];
    const j = i + d;
    if (j < 0 || j >= arr.length) return;
    [arr[i], arr[j]] = [arr[j], arr[i]];
    setCats(arr);
    await adminApi.reorderCategories(arr.map((c) => c.id));
    await reloadConfig();
  }

  if (!cats) return <div className="flex justify-center p-10"><Spinner /></div>;
  return (
    <div className="space-y-3">
      <div className="flex items-center">
        <h1 className="mr-auto text-xl font-extrabold">Kategorie a podkategorie</h1>
        <Button variant="primary" onClick={() => setOpen('new')}><Plus className="h-4 w-4" /> Nová kategorie</Button>
      </div>
      <p className="text-sm text-ink-soft">
        Původní kategorie z mapy MapHub lze doplnit ručně nebo automaticky importem GeoJSON exportu z MapHub (Nastavení → Import dat). Kategorie, které už obsahují podněty, se při odebrání pouze deaktivují (nezobrazí se v nabídce, data zůstanou).
      </p>
      {open === 'new' && <CategoryForm onDone={async () => { setOpen(null); await after('Kategorie vytvořena'); }} onCancel={() => setOpen(null)} />}
      <ul className="space-y-2">
        {cats.map((c, i) => (
          <li key={c.id} className={clsx('rounded-2xl bg-white shadow-sm', !c.is_active && 'opacity-60')}>
            <div className="flex items-center gap-3 p-3">
              <div className="flex flex-col">
                <button onClick={() => move(i, -1)} className="text-ink-faint hover:text-ink" aria-label="Posunout výš"><ArrowUp className="h-4 w-4" /></button>
                <button onClick={() => move(i, 1)} className="text-ink-faint hover:text-ink" aria-label="Posunout níž"><ArrowDown className="h-4 w-4" /></button>
              </div>
              <CategoryBadge color={c.color} icon={c.icon} />
              <button className="min-w-0 flex-1 text-left" onClick={() => setOpen(open === c.id ? null : c.id)}>
                <div className="font-semibold">{c.name} {!c.is_active && <span className="text-xs font-normal">(neaktivní)</span>} {c.source === 'maphub' && <span className="rounded bg-slate-100 px-1 text-[10px]">MapHub</span>}</div>
                <div className="text-xs text-ink-soft">výchozí: {KIND_LABEL[c.default_geom]} · {c.subcategories.length} podkategorií · {c.reports} podnětů · vrstva „{c.theme}“</div>
              </button>
            </div>
            {open === c.id && (
              <div className="border-t border-slate-100 p-3">
                <CategoryForm cat={c} onDone={async () => { await after('Uloženo'); }} onCancel={() => setOpen(null)}
                  onDelete={async () => {
                    if (!confirm(`Odebrat kategorii „${c.name}“?`)) return;
                    const r = await adminApi.deleteCategory(c.id);
                    setOpen(null);
                    await after(r.deactivated ? 'Kategorie obsahuje podněty – byla deaktivována' : 'Kategorie odebrána');
                  }} />
                <Subcategories cat={c} onChanged={() => after('Uloženo')} />
              </div>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

function CategoryForm({ cat, onDone, onCancel, onDelete }: { cat?: Category; onDone: () => void; onCancel: () => void; onDelete?: () => void }) {
  const [v, setV] = useState({
    name: cat?.name ?? '', description: cat?.description ?? '', color: cat?.color ?? '#0d9488', icon: cat?.icon ?? 'map-pin',
    default_geom: cat?.default_geom ?? ('point' as GeomKind), is_active: cat?.is_active ?? true, allow_custom_topic: cat?.allow_custom_topic ?? false,
    theme: cat?.theme ?? 'mobilita', code: cat?.code ?? ''
  });
  const [busy, setBusy] = useState(false);
  return (
    <div className="space-y-3 rounded-2xl bg-slate-50 p-3">
      <div className="grid gap-3 md:grid-cols-2">
        <Field label="Název" required><input className={inputCls} value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} /></Field>
        <Field label="Popis"><input className={inputCls} value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} /></Field>
        <Field label="Výchozí typ zakreslení" required>
          <select className={inputCls} value={v.default_geom} onChange={(e) => setV({ ...v, default_geom: e.target.value as GeomKind })}>
            {(['point', 'line', 'polygon'] as GeomKind[]).map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
          </select>
        </Field>
        <Field label="Tematická vrstva" hint="Pro budoucí rozšíření (např. mobilita, zeleň, bezpečnost)"><input className={inputCls} value={v.theme} onChange={(e) => setV({ ...v, theme: e.target.value })} /></Field>
      </div>
      <div>
        <div className="mb-1 text-sm font-semibold">Barva</div>
        <div className="flex flex-wrap items-center gap-1.5">
          {PALETTE.map((p) => <button key={p} onClick={() => setV({ ...v, color: p })} className={clsx('h-8 w-8 rounded-full border-2', v.color === p ? 'border-ink' : 'border-white')} style={{ backgroundColor: p }} aria-label={p} />)}
          <input type="color" value={v.color} onChange={(e) => setV({ ...v, color: e.target.value })} className="h-8 w-12 cursor-pointer rounded" />
        </div>
      </div>
      <div>
        <div className="mb-1 text-sm font-semibold">Ikona</div>
        <div className="flex flex-wrap gap-1.5">
          {ICON_NAMES.map((n) => (
            <button key={n} onClick={() => setV({ ...v, icon: n })} className={clsx('flex h-9 w-9 items-center justify-center rounded-xl border', v.icon === n ? 'border-brand-600 bg-brand-50' : 'border-slate-200 bg-white')} title={n}>
              <CategoryIcon icon={n} className="h-4 w-4" />
            </button>
          ))}
        </div>
      </div>
      <div className="flex flex-wrap gap-4 text-sm">
        <label className="flex items-center gap-2"><input type="checkbox" className="accent-brand-600" checked={v.is_active} onChange={(e) => setV({ ...v, is_active: e.target.checked })} /> Aktivní</label>
        <label className="flex items-center gap-2"><input type="checkbox" className="accent-brand-600" checked={v.allow_custom_topic} onChange={(e) => setV({ ...v, allow_custom_topic: e.target.checked })} /> Umožnit vlastní téma</label>
      </div>
      <div className="flex gap-2">
        <Button variant="primary" loading={busy} onClick={async () => {
          if (!v.name.trim()) return toast('Vyplňte název', 'error');
          setBusy(true);
          try { await adminApi.saveCategory({ ...v, id: cat?.id }); onDone(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
        }}>Uložit kategorii</Button>
        <Button variant="ghost" onClick={onCancel}>Zavřít</Button>
        {onDelete && <Button variant="ghost" className="ml-auto text-red-600" onClick={onDelete}><Trash2 className="h-4 w-4" /> Odebrat</Button>}
      </div>
    </div>
  );
}

function Subcategories({ cat, onChanged }: { cat: Category; onChanged: () => void }) {
  const [name, setName] = useState('');
  const [geom, setGeom] = useState<GeomKind | ''>('');
  const save = async (p: Record<string, unknown>) => {
    try { await adminApi.saveSubcategory({ category_id: cat.id, ...p }); onChanged(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  return (
    <div className="mt-3">
      <div className="mb-1 text-sm font-bold">Podkategorie</div>
      <ul className="divide-y divide-slate-100 rounded-2xl border border-slate-200">
        {cat.subcategories.map((s, i) => (
          <li key={s.id} className={clsx('flex flex-wrap items-center gap-2 p-2 text-sm', s.is_active === false && 'opacity-50')}>
            <input className={`${inputCls} min-w-[160px] flex-1 py-1.5`} defaultValue={s.name} onBlur={(e) => e.target.value !== s.name && save({ id: s.id, name: e.target.value })} />
            <select className={`${inputCls} w-auto py-1.5`} value={s.default_geom ?? ''} onChange={(e) => save({ id: s.id, default_geom: e.target.value })}>
              <option value="">dle kategorie</option>
              {(['point', 'line', 'polygon'] as GeomKind[]).map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
            </select>
            <button className="text-ink-faint" disabled={i === 0} onClick={() => save({ id: s.id, sort_order: (cat.subcategories[i - 1].sort_order ?? 0) - 1 })} aria-label="Výš"><ArrowUp className="h-4 w-4" /></button>
            <label className="flex items-center gap-1 text-xs"><input type="checkbox" checked={s.is_active !== false} onChange={(e) => save({ id: s.id, is_active: e.target.checked })} /> aktivní</label>
            <span className="text-xs text-ink-faint">{s.reports ?? 0}×</span>
            <button className="text-red-500" onClick={async () => { if (!confirm(`Odebrat „${s.name}“?`)) return; const r = await adminApi.deleteSubcategory(s.id); toast(r.deactivated ? 'Podkategorie je použita – deaktivována' : 'Odebráno'); onChanged(); }} aria-label="Odebrat"><Trash2 className="h-4 w-4" /></button>
          </li>
        ))}
        <li className="flex flex-wrap gap-2 p-2">
          <input className={`${inputCls} min-w-[160px] flex-1 py-1.5`} placeholder="Nová podkategorie" value={name} onChange={(e) => setName(e.target.value)} />
          <select className={`${inputCls} w-auto py-1.5`} value={geom} onChange={(e) => setGeom(e.target.value as GeomKind | '')}>
            <option value="">dle kategorie</option>
            {(['point', 'line', 'polygon'] as GeomKind[]).map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
          </select>
          <Button variant="outline" className="py-1.5" onClick={async () => { if (!name.trim()) return; await save({ name: name.trim(), default_geom: geom }); setName(''); }}><Plus className="h-4 w-4" /> Přidat</Button>
        </li>
      </ul>
    </div>
  );
}
