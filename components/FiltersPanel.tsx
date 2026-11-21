'use client';
import clsx from 'clsx';
import type { GeomKind, MapData, PublicConfig, ReportStatus } from '@/lib/types';
import { KIND_LABEL, STATUS_LABEL } from '@/lib/types';
import { CategoryBadge, inputCls, Sheet } from '@/components/ui';
import type { AnalysisLayer } from '@/components/map/MapView';
import { KIND_ICON } from '@/components/AddFlow';

export interface Filters {
  categories: Set<number>;
  kinds: Set<GeomKind>;
  minPeople: number;
  minOverlap: number;
  district: number | null;
  status: ReportStatus | 'any';
}

export function defaultFilters(config: PublicConfig): Filters {
  return {
    categories: new Set(config.categories.map((c) => c.id)),
    kinds: new Set<GeomKind>(['point', 'line', 'polygon']),
    minPeople: 1,
    minOverlap: 0,
    district: null,
    status: 'any'
  };
}

export function applyFilters(data: MapData, f: Filters): MapData {
  return {
    type: 'FeatureCollection',
    features: data.features.filter((x) => {
      const p = x.properties;
      return (
        f.categories.has(p.c) &&
        f.kinds.has(p.k) &&
        p.p >= f.minPeople &&
        (p.ov ?? 0) >= f.minOverlap &&
        (f.district == null || p.ds === f.district) &&
        (f.status === 'any' || p.st === f.status)
      );
    })
  };
}

export const ANALYSIS_LAYERS: { id: AnalysisLayer; label: string; hint: string }[] = [
  { id: 'intensity', label: 'Celková mapa intenzity problémů', hint: 'Počet unikátních lidí (autoři + podporovatelé) v buňkách 150 m' },
  { id: 'drawings', label: 'Počet jednotlivých zakreslení', hint: 'Kolik bodů, linií a ploch zasahuje do buňky' },
  { id: 'supporters', label: 'Počet podporovatelů', hint: 'Velikost kruhu = počet lidí, kteří místo vnímají jako problém' },
  { id: 'poly_overlap', label: 'Prostorové překryvy ploch', hint: 'Čím více lidí označilo stejné území, tím sytější barva' },
  { id: 'line_overlap', label: 'Prostorové překryvy linií', hint: 'Úseky tras, které zakreslilo více lidí (tolerance ~15 m)' },
  { id: 'point_density', label: 'Hustota bodových podnětů', hint: 'Heatmapa bodů' },
  { id: 'category_heat', label: 'Heatmapa podle kategorií', hint: 'Heatmapa vybraných kategorií (všechny typy zakreslení, vážená počtem lidí)' }
];

export function FiltersPanel({
  config, data, filters, setFilters, mode, setMode, layers, setLayers, onClose, loadingAnalysis
}: {
  config: PublicConfig; data: MapData; filters: Filters; setFilters: (f: Filters) => void;
  mode: 'reports' | 'analysis'; setMode: (m: 'reports' | 'analysis') => void;
  layers: Set<AnalysisLayer>; setLayers: (l: Set<AnalysisLayer>) => void; onClose: () => void; loadingAnalysis: boolean;
}) {
  const counts = new Map<number, number>();
  for (const f of data.features) counts.set(f.properties.c, (counts.get(f.properties.c) ?? 0) + 1);
  const maxPeople = Math.max(1, ...data.features.map((f) => f.properties.p));
  const maxOverlap = Math.max(0, ...data.features.map((f) => f.properties.ov ?? 0));
  const allOn = filters.categories.size === config.categories.length;

  const toggleCat = (id: number) => {
    const s = new Set(filters.categories);
    if (s.has(id)) s.delete(id);
    else s.add(id);
    setFilters({ ...filters, categories: s });
  };
  const toggleKind = (k: GeomKind) => {
    const s = new Set(filters.kinds);
    if (s.has(k)) { if (s.size > 1) s.delete(k); } else s.add(k);
    setFilters({ ...filters, kinds: s });
  };
  const toggleLayer = (l: AnalysisLayer) => {
    const s = new Set(layers);
    if (s.has(l)) s.delete(l);
    else {
      s.add(l);
      // vzájemně se vylučující vrstvy (stejný podklad)
      if (l === 'intensity') s.delete('drawings');
      if (l === 'drawings') s.delete('intensity');
    }
    setLayers(s);
    if (s.size && mode !== 'analysis') setMode('analysis');
  };

  return (
    <Sheet open onClose={onClose} title="Vrstvy a filtry">
      <div className="grid grid-cols-2 gap-1 rounded-2xl bg-slate-100 p-1">
        {(['reports', 'analysis'] as const).map((m) => (
          <button key={m} onClick={() => setMode(m)} className={clsx('rounded-xl py-2 text-sm font-semibold', mode === m ? 'bg-white text-brand-700 shadow-sm' : 'text-ink-soft')}>
            {m === 'reports' ? 'Jednotlivé podněty' : 'Analytické zobrazení'}
          </button>
        ))}
      </div>

      {mode === 'analysis' && (
        <section className="mt-4">
          <h3 className="mb-2 flex items-center gap-2 text-sm font-bold">Analytické vrstvy {loadingAnalysis && <span className="text-xs font-normal text-ink-faint">načítám…</span>}</h3>
          <div className="space-y-1.5">
            {ANALYSIS_LAYERS.map((l) => (
              <label key={l.id} className="flex items-start gap-2 rounded-xl p-1.5 hover:bg-slate-50">
                <input type="checkbox" className="mt-1 h-4 w-4 accent-brand-600" checked={layers.has(l.id)} onChange={() => toggleLayer(l.id)} />
                <span className="text-sm"><span className="font-semibold">{l.label}</span><span className="block text-xs text-ink-soft">{l.hint}</span></span>
              </label>
            ))}
          </div>
          <div className="mt-3 rounded-xl bg-slate-50 p-3">
            <div className="text-xs font-semibold">Míra shody (počet unikátních lidí)</div>
            <div className="mt-1.5 h-3 rounded-full" style={{ background: 'linear-gradient(90deg,#fde68a,#fbbf24,#f97316,#dc2626,#991b1b,#4c0519)' }} />
            <div className="mt-1 flex justify-between text-[11px] text-ink-soft"><span>1</span><span>2</span><span>3</span><span>5</span><span>8</span><span>15+</span></div>
            <p className="mt-2 text-[11px] text-ink-soft">Každý člověk se v analýze počítá jen jednou, i když zakreslil více objektů. Klepněte do vrstvy pro podrobnosti.</p>
          </div>
        </section>
      )}

      <section className="mt-5">
        <div className="mb-2 flex items-center justify-between">
          <h3 className="text-sm font-bold">Kategorie (legenda)</h3>
          <button className="text-xs font-semibold text-brand-700" onClick={() => setFilters({ ...filters, categories: allOn ? new Set() : new Set(config.categories.map((c) => c.id)) })}>
            {allOn ? 'Skrýt vše' : 'Zobrazit vše'}
          </button>
        </div>
        <div className="space-y-1">
          {config.categories.map((c) => (
            <label key={c.id} className={clsx('flex cursor-pointer items-center gap-3 rounded-xl p-1.5 hover:bg-slate-50', !filters.categories.has(c.id) && 'opacity-50')}>
              <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={filters.categories.has(c.id)} onChange={() => toggleCat(c.id)} />
              <CategoryBadge color={c.color} icon={c.icon} size="sm" />
              <span className="flex-1 text-sm">{c.name}</span>
              <span className="text-xs text-ink-faint">{counts.get(c.id) ?? 0}</span>
            </label>
          ))}
        </div>
      </section>

      <section className="mt-5">
        <h3 className="mb-2 text-sm font-bold">Typ zakreslení</h3>
        <div className="grid grid-cols-3 gap-1.5">
          {(['point', 'line', 'polygon'] as GeomKind[]).map((k) => {
            const K = KIND_ICON[k];
            return (
              <button key={k} onClick={() => toggleKind(k)} aria-pressed={filters.kinds.has(k)}
                className={clsx('flex items-center justify-center gap-1.5 rounded-xl border py-2 text-sm', filters.kinds.has(k) ? 'border-brand-600 bg-brand-50 font-semibold text-brand-800' : 'border-slate-300 text-ink-soft')}>
                <K className="h-4 w-4" /> {KIND_LABEL[k]}
              </button>
            );
          })}
        </div>
      </section>

      <section className="mt-5 space-y-4">
        <label className="block">
          <span className="flex justify-between text-sm font-bold">Min. počet lidí (podporovatelů) <span className="font-semibold text-brand-700">{filters.minPeople}+</span></span>
          <input type="range" min={1} max={Math.max(2, maxPeople)} value={filters.minPeople} onChange={(e) => setFilters({ ...filters, minPeople: Number(e.target.value) })} className="mt-1 w-full accent-brand-600" />
        </label>
        <label className="block">
          <span className="flex justify-between text-sm font-bold">Min. prostorová shoda <span className="font-semibold text-brand-700">{filters.minOverlap === 0 ? 'vše' : `${filters.minOverlap}+ dalších lidí`}</span></span>
          <input type="range" min={0} max={Math.max(1, maxOverlap)} value={filters.minOverlap} onChange={(e) => setFilters({ ...filters, minOverlap: Number(e.target.value) })} className="mt-1 w-full accent-brand-600" />
          <span className="text-xs text-ink-soft">Kolik dalších lidí zakreslilo shodné nebo překrývající se místo stejné kategorie.</span>
        </label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block text-sm font-bold">Místní část
            <select className={clsx(inputCls, 'mt-1 py-2 text-sm font-normal')} value={filters.district ?? ''} onChange={(e) => setFilters({ ...filters, district: e.target.value ? Number(e.target.value) : null })}>
              <option value="">Celé Ivančice</option>
              {config.districts.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
            </select>
          </label>
          <label className="block text-sm font-bold">Stav řešení
            <select className={clsx(inputCls, 'mt-1 py-2 text-sm font-normal')} value={filters.status} onChange={(e) => setFilters({ ...filters, status: e.target.value as Filters['status'] })}>
              <option value="any">Všechny</option>
              {(Object.keys(STATUS_LABEL) as ReportStatus[]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
            </select>
          </label>
        </div>
        <button className="text-sm font-semibold text-brand-700" onClick={() => setFilters(defaultFilters(config))}>Obnovit výchozí filtry</button>
      </section>
    </Sheet>
  );
}
