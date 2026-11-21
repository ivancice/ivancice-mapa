'use client';
// Export dat pro GIS – probíhá v prohlížeči administrátora (web je statický).
// Oprávnění ověřuje databáze: funkce admin_* odmítnou neadministrátora.
import type { Feature, FeatureCollection } from 'geojson';
import { rpc } from '@/lib/api';
import { buildShapefiles } from '@/lib/export/shapefile';
import { zip } from '@/lib/export/zip';
import { toCsv } from '@/lib/export/csv';

export type ExportLayer = 'reports' | 'polygon_overlap' | 'line_overlap' | 'point_clusters' | 'hexgrid';
export type ExportFormat = 'shp' | 'geojson' | 'csv';

const LAYER_FILE: Record<ExportLayer, string> = {
  reports: 'podnety',
  polygon_overlap: 'prekryv_ploch',
  line_overlap: 'prekryv_linii',
  point_clusters: 'shluky_bodu',
  hexgrid: 'intenzita_hex'
};

// Pevné pořadí atributů (PostgreSQL JSONB klíče neřadí)
const ORDER = ['id', 'cislo', 'typ_geom', 'kat_id', 'kategorie', 'podkat_id', 'podkat', 'vl_tema', 'nazev', 'popis', 'reseni',
  'cetnost', 'autor', 'vlozeno', 'cast_obce', 'stav', 'stav_verej', 'n_autoru', 'n_podpor', 'n_lidi', 'shoda_lidi', 'shoda_pod',
  'delka_m', 'plocha_m2', 'varianta_k', 'slouceno', 'skryto', 'ukazka', 'zdroj', 'n_fotek', 'n_koment'];

function ordered(p: Record<string, unknown>) {
  const out: Record<string, unknown> = {};
  for (const k of ORDER) if (k in p) out[k] = p[k];
  for (const k of Object.keys(p)) if (!(k in out)) out[k] = p[k];
  return out;
}

export interface ExportResult {
  filename: string;
  blob: Blob;
  count: number;
}

export async function buildExport(o: {
  layer: ExportLayer;
  format: ExportFormat;
  srid: number;
  hidden?: boolean;
  demo?: boolean;
  categories?: number[] | null;
}): Promise<ExportResult> {
  // zároveň ověří roli administrátora
  const prj = await rpc<string | null>('admin_srid_wkt', { p_srid: o.srid });

  let features: Feature[];
  if (o.layer === 'reports') {
    const data = await rpc<Feature[]>('admin_export_reports', {
      p_include_hidden: !!o.hidden,
      p_include_demo: !!o.demo,
      p_srid: o.srid
    });
    features = (data ?? []).map((f) => ({ ...f, properties: ordered((f.properties ?? {}) as Record<string, unknown>) }));
  } else {
    let fc = await rpc<FeatureCollection>('get_analysis', { p_layer: o.layer, p_categories: o.categories ?? null });
    if (o.srid !== 4326) fc = await rpc<FeatureCollection>('admin_transform_fc', { p_fc: fc, p_srid: o.srid });
    features = fc.features.map((f) => {
      const p = { ...(f.properties ?? {}) } as Record<string, unknown>;
      if (Array.isArray(p.report_ids)) p.report_ids = (p.report_ids as string[]).join(',');
      return { ...f, properties: p };
    });
  }

  const date = new Date().toISOString().slice(0, 10);
  const crs = o.srid === 5514 ? 'sjtsk' : o.srid === 32633 ? 'utm33' : 'wgs84';
  const base = `ivancice_${LAYER_FILE[o.layer]}_${crs}_${date}`;

  if (o.format === 'geojson') {
    const fc: Record<string, unknown> = { type: 'FeatureCollection', name: base, features };
    if (o.srid !== 4326) fc.crs = { type: 'name', properties: { name: `urn:ogc:def:crs:EPSG::${o.srid}` } };
    return { filename: `${base}.geojson`, blob: new Blob([JSON.stringify(fc)], { type: 'application/geo+json' }), count: features.length };
  }
  if (o.format === 'csv') {
    return { filename: `${base}.csv`, blob: new Blob([toCsv(features)], { type: 'text/csv;charset=utf-8' }), count: features.length };
  }
  const files = buildShapefiles(base, features, prj ?? null);
  files.push({
    name: 'README.txt',
    data: new TextEncoder().encode(
      `Export z aplikace Ivančice očima pěších a cyklistů (${date}).\r\nSouřadnicový systém: EPSG:${o.srid}. Kódování atributů: UTF-8 (soubor .cpg).\r\n` +
        `Každý typ geometrie je v samostatné vrstvě (_body, _linie, _plochy). Dlouhé texty jsou v DBF zkráceny na 254 bajtů – úplné texty obsahuje export CSV/GeoJSON.\r\n`
    )
  });
  const bytes = zip(files);
  return { filename: `${base}.zip`, blob: new Blob([bytes as BlobPart], { type: 'application/zip' }), count: features.length };
}

export function download(r: ExportResult) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(r.blob);
  a.download = r.filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}
