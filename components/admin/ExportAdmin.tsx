'use client';
import { useState } from 'react';
import clsx from 'clsx';
import { Download } from 'lucide-react';
import { Button, inputCls, toast } from '@/components/ui';
import { buildExport, download, type ExportFormat, type ExportLayer } from '@/lib/export/run';
import { errorMessage } from '@/lib/api';

const LAYERS = [
  { id: 'reports', label: 'Původní zakreslení (všechny podněty)', hint: 'Body, linie a plochy s atributy: ID, kategorie, název, popis, datum, počet autorů/podporovatelů, stav, míra shody…' },
  { id: 'polygon_overlap', label: 'Analýza: překryvy ploch', hint: 'Plochy rozdělené podle počtu unikátních lidí (people, share)' },
  { id: 'line_overlap', label: 'Analýza: překryvy linií', hint: 'Úseky tras s počtem lidí, kteří je zakreslili' },
  { id: 'point_clusters', label: 'Analýza: shluky bodů', hint: 'Středy shluků bodů stejné kategorie, počty podnětů, autorů a lidí' },
  { id: 'hexgrid', label: 'Analýza: mapa intenzity (šestiúhelníky)', hint: 'Počet zakreslení, autorů a unikátních lidí v buňce' }
];

export default function ExportAdmin() {
  const [layer, setLayer] = useState('reports');
  const [srid, setSrid] = useState('5514');
  const [hidden, setHidden] = useState(false);
  const [demo, setDemo] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  async function run(format: ExportFormat) {
    setBusy(format);
    try {
      const r = await buildExport({ layer: layer as ExportLayer, format, srid: Number(srid), hidden, demo });
      download(r);
      toast(`Staženo: ${r.filename} (${r.count} prvků)`);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="max-w-3xl space-y-4">
      <h1 className="text-xl font-extrabold">Export dat pro GIS</h1>
      <p className="text-sm text-ink-soft">Data jsou připravena pro QGIS a další GIS nástroje. Shapefile obsahuje pro každý typ geometrie samostatnou vrstvu, kódování UTF-8 (.cpg) a projekci (.prj). CSV obsahuje geometrii jako WKT (oddělovač středník).</p>
      <section className="rounded-2xl bg-white p-4 shadow-sm">
        <div className="mb-2 text-sm font-bold">1. Vrstva</div>
        <div className="space-y-1.5">
          {LAYERS.map((l) => (
            <label key={l.id} className={clsx('flex items-start gap-2 rounded-xl p-2', layer === l.id && 'bg-brand-50')}>
              <input type="radio" className="mt-1 accent-brand-600" checked={layer === l.id} onChange={() => setLayer(l.id)} />
              <span className="text-sm"><b>{l.label}</b><span className="block text-xs text-ink-soft">{l.hint}</span></span>
            </label>
          ))}
        </div>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <label className="text-sm font-bold">2. Souřadnicový systém
            <select className={`${inputCls} mt-1`} value={srid} onChange={(e) => setSrid(e.target.value)}>
              <option value="5514">S-JTSK / Krovak East North (EPSG:5514) – doporučeno pro ČR</option>
              <option value="4326">WGS 84 (EPSG:4326)</option>
              <option value="32633">WGS 84 / UTM 33N (EPSG:32633)</option>
            </select>
          </label>
          {layer === 'reports' && (
            <div className="space-y-1 pt-6 text-sm">
              <label className="flex items-center gap-2"><input type="checkbox" className="accent-brand-600" checked={hidden} onChange={(e) => setHidden(e.target.checked)} /> Včetně skrytých a sloučených</label>
              <label className="flex items-center gap-2"><input type="checkbox" className="accent-brand-600" checked={demo} onChange={(e) => setDemo(e.target.checked)} /> Včetně ukázkových dat</label>
            </div>
          )}
        </div>
        <div className="mt-4 text-sm font-bold">3. Formát</div>
        <div className="mt-2 flex flex-wrap gap-2">
          {([['shp', 'Shapefile (ZIP)'], ['geojson', 'GeoJSON'], ['csv', 'CSV (WKT)']] as [ExportFormat, string][]).map(([f, l]) => (
            <Button key={f} variant="primary" loading={busy === f} disabled={!!busy} onClick={() => run(f)}><Download className="h-4 w-4" /> {l}</Button>
          ))}
        </div>
      </section>
      <section className="rounded-2xl bg-white p-4 text-sm shadow-sm">
        <h2 className="font-bold">Popis atributů (vrstva podnětů)</h2>
        <table className="mt-2 w-full text-xs">
          <tbody className="[&_td]:border-t [&_td]:border-slate-100 [&_td]:py-1 [&_td:first-child]:pr-3 [&_td:first-child]:font-mono">
            {[
              ['id', 'Jedinečný identifikátor podnětu (UUID)'], ['cislo', 'Pořadové číslo podnětu'], ['typ_geom', 'point / line / polygon'],
              ['kat_id, kategorie', 'Kategorie'], ['podkat_id, podkat', 'Podkategorie'], ['vl_tema', 'Vlastní téma (kategorie Jiné)'],
              ['nazev, popis, reseni', 'Název, komentář, návrh řešení'], ['cetnost', 'Jak často se autor v místě pohybuje'], ['autor', 'Jméno/přezdívka (veřejné)'],
              ['vlozeno', 'Datum a čas vložení'], ['cast_obce', 'Místní část'], ['stav, stav_verej', 'Stav řešení a zda je veřejný'],
              ['n_autoru', 'Počet unikátních autorů (vč. sloučených duplicit)'], ['n_podpor', 'Počet lidí, kteří podnět podpořili (bez autorů)'],
              ['n_lidi', 'Unikátní lidé celkem (autoři + podporovatelé)'], ['shoda_lidi', 'Počet dalších lidí se shodným zakreslením'],
              ['shoda_pod', 'Podíl délky/plochy pokrytý zakresleními ostatních (0–1)'], ['delka_m, plocha_m2', 'Délka linie / výměra plochy'],
              ['varianta_k', 'ID podnětu, ke kterému je zakreslení variantou'], ['slouceno', 'ID podnětu, do kterého byl sloučen'],
              ['skryto, ukazka, zdroj', 'Skrytý, ukázková data, zdroj (app / maphub / demo)'], ['n_fotek, n_koment', 'Počet fotografií a komentářů']
            ].map(([a, b]) => <tr key={a}><td>{a}</td><td>{b}</td></tr>)}
          </tbody>
        </table>
        <p className="mt-2 text-xs text-ink-soft">E-mailové adresy se do exportu nikdy nezahrnují. Seznam odběratelů novinek (se souhlasem) lze stáhnout v Nastavení.</p>
      </section>
    </div>
  );
}
