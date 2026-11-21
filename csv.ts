import type { Feature } from 'geojson';

function wkt(g: GeoJSON.Geometry | null): string {
  if (!g) return '';
  const pt = (c: GeoJSON.Position) => `${c[0]} ${c[1]}`;
  const ring = (r: GeoJSON.Position[]) => `(${r.map(pt).join(', ')})`;
  switch (g.type) {
    case 'Point':
      return `POINT (${pt(g.coordinates)})`;
    case 'MultiPoint':
      return `MULTIPOINT (${g.coordinates.map((c) => `(${pt(c)})`).join(', ')})`;
    case 'LineString':
      return `LINESTRING ${ring(g.coordinates)}`;
    case 'MultiLineString':
      return `MULTILINESTRING (${g.coordinates.map(ring).join(', ')})`;
    case 'Polygon':
      return `POLYGON (${g.coordinates.map(ring).join(', ')})`;
    case 'MultiPolygon':
      return `MULTIPOLYGON (${g.coordinates.map((p) => `(${p.map(ring).join(', ')})`).join(', ')})`;
    default:
      return '';
  }
}

function cell(v: unknown): string {
  if (v === null || v === undefined) return '';
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  return /[";\n\r,]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

/** CSV (oddělovač středník – výchozí pro české Excel/LibreOffice), geometrie jako WKT. UTF-8 s BOM. */
export function toCsv(features: Feature[], sep = ';'): string {
  const keys: string[] = [];
  for (const f of features) for (const k of Object.keys(f.properties ?? {})) if (!keys.includes(k)) keys.push(k);
  const lines = [[...keys, 'geometrie_wkt'].join(sep)];
  for (const f of features) {
    const p = (f.properties ?? {}) as Record<string, unknown>;
    lines.push([...keys.map((k) => cell(p[k])), cell(wkt(f.geometry))].join(sep));
  }
  return '﻿' + lines.join('\r\n') + '\r\n';
}
