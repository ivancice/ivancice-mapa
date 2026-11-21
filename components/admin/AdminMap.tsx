'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import MapView, { type AnalysisData, type AnalysisLayer, type MapViewHandle } from '@/components/map/MapView';
import { useAdmin } from '@/components/admin/AdminShell';
import { api, errorMessage } from '@/lib/api';
import { ANALYSIS_LAYERS } from '@/components/FiltersPanel';
import type { MapData } from '@/lib/types';
import { KIND_LABEL } from '@/lib/types';
import { toast } from '@/components/ui';

export default function AdminMap() {
  const { config } = useAdmin();
  const ref = useRef<MapViewHandle>(null);
  const [data, setData] = useState<MapData>({ type: 'FeatureCollection', features: [] });
  const [mode, setMode] = useState<'reports' | 'analysis'>('analysis');
  const [layers, setLayers] = useState<Set<AnalysisLayer>>(new Set(['intensity']));
  const [an, setAn] = useState<AnalysisData>({});
  const [cats, setCats] = useState<Set<number>>(new Set(config.categories.map((c) => c.id)));
  const [sel, setSel] = useState<string | null>(null);

  useEffect(() => {
    api.mapData().then(setData).catch((e) => toast(errorMessage(e), 'error'));
  }, []);

  useEffect(() => {
    const q = new URLSearchParams(window.location.search);
    const lon = Number(q.get('lon')), lat = Number(q.get('lat'));
    if (lon && lat) setTimeout(() => ref.current?.flyTo([lon, lat], 17), 800);
  }, []);

  const filtered = useMemo<MapData>(() => ({ type: 'FeatureCollection', features: data.features.filter((f) => cats.has(f.properties.c)) }), [data, cats]);
  const catArr = cats.size === config.categories.length ? null : [...cats];

  useEffect(() => {
    if (mode !== 'analysis') return;
    const next: AnalysisData = {};
    const jobs: Promise<unknown>[] = [];
    const c = catArr && catArr.length === 0 ? [-1] : catArr;
    if (layers.has('poly_overlap')) jobs.push(api.analysis('polygon_overlap', c).then((d) => (next.polygon_overlap = d)));
    if (layers.has('line_overlap')) jobs.push(api.analysis('line_overlap', c).then((d) => (next.line_overlap = d)));
    if (layers.has('intensity') || layers.has('drawings')) jobs.push(api.analysis('hexgrid', c).then((d) => (next.hexgrid = d)));
    Promise.all(jobs).then(() => setAn(next)).catch((e) => toast(errorMessage(e), 'error'));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, layers, cats]);

  const selF = data.features.find((f) => f.properties.id === sel);

  return (
    <div className="space-y-3">
      <h1 className="text-xl font-extrabold">Mapa a analytické výstupy</h1>
      <div className="grid gap-3 lg:grid-cols-[1fr_300px]">
        <div className="relative h-[70dvh] overflow-hidden rounded-2xl bg-white shadow-sm">
          <MapView ref={ref} categories={config.categories} data={filtered} mode={mode} analysisLayers={layers} analysisData={an}
            basemap="osm" selectedId={sel} highlightIds={[]} draw={null} initialBounds={config.settings.map_bounds}
            onDrawClick={() => {}} onSelect={(ids) => setSel(ids[0] ?? null)} />
        </div>
        <div className="space-y-3">
          <div className="rounded-2xl bg-white p-3 shadow-sm">
            <div className="grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1">
              {(['reports', 'analysis'] as const).map((m) => (
                <button key={m} onClick={() => setMode(m)} className={clsx('rounded-lg py-1.5 text-sm font-semibold', mode === m ? 'bg-white shadow-sm' : 'text-ink-soft')}>{m === 'reports' ? 'Podněty' : 'Analýza'}</button>
              ))}
            </div>
            {mode === 'analysis' && (
              <div className="mt-2 space-y-1">
                {ANALYSIS_LAYERS.map((l) => (
                  <label key={l.id} className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className="accent-brand-600" checked={layers.has(l.id)} onChange={() => { const s = new Set(layers); if (s.has(l.id)) s.delete(l.id); else { s.add(l.id); if (l.id === 'intensity') s.delete('drawings'); if (l.id === 'drawings') s.delete('intensity'); } setLayers(s); }} />
                    {l.label}
                  </label>
                ))}
              </div>
            )}
          </div>
          <div className="rounded-2xl bg-white p-3 shadow-sm">
            <div className="mb-1 text-sm font-bold">Kategorie</div>
            {config.categories.map((c) => (
              <label key={c.id} className="flex items-center gap-2 py-0.5 text-sm">
                <input type="checkbox" className="accent-brand-600" checked={cats.has(c.id)} onChange={() => { const s = new Set(cats); if (s.has(c.id)) s.delete(c.id); else s.add(c.id); setCats(s); }} />
                <span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: c.color }} /> {c.name}
              </label>
            ))}
          </div>
          {selF && (
            <div className="rounded-2xl bg-white p-3 text-sm shadow-sm">
              <div className="font-bold">{selF.properties.t}</div>
              <div className="text-xs text-ink-soft">č. {selF.properties.no} · {KIND_LABEL[selF.properties.k]} · {selF.properties.p} lidí · shoda +{selF.properties.ov}</div>
              <div className="mt-2 flex gap-3">
                <Link className="font-semibold text-brand-700" href={`/?p=${selF.properties.id}`} target="_blank">Veřejný detail</Link>
                <Link className="font-semibold text-brand-700" href={`/admin/podnety?q=${selF.properties.no}`}>Upravit</Link>
              </div>
            </div>
          )}
          <p className="text-xs text-ink-soft">Analytické vrstvy lze stáhnout pro QGIS v sekci <Link href="/admin/export" className="underline">Export dat</Link>.</p>
        </div>
      </div>
    </div>
  );
}
