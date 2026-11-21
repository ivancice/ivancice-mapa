// Zápis ESRI Shapefile (SHP/SHX/DBF/PRJ/CPG) z GeoJSON prvků.
// Každý typ geometrie se ukládá do samostatné vrstvy (body, linie, plochy).
import type { Feature, Geometry, Position } from 'geojson';

type Kind = 'point' | 'line' | 'polygon';
const SHAPE_TYPE: Record<Kind, number> = { point: 1, line: 3, polygon: 5 };

interface DbfField {
  key: string;
  name: string;
  type: 'C' | 'N' | 'L';
  length: number;
  decimals: number;
}

export function kindOf(g: Geometry | null): Kind | null {
  if (!g) return null;
  if (g.type === 'Point' || g.type === 'MultiPoint') return 'point';
  if (g.type === 'LineString' || g.type === 'MultiLineString') return 'line';
  if (g.type === 'Polygon' || g.type === 'MultiPolygon') return 'polygon';
  return null;
}

/** Rozdělí prvky podle typu geometrie a vytvoří soubory vrstvy. */
export function buildShapefiles(baseName: string, features: Feature[], prj: string | null): { name: string; data: Uint8Array }[] {
  const groups: Record<Kind, Feature[]> = { point: [], line: [], polygon: [] };
  for (const f of features) {
    const k = kindOf(f.geometry);
    if (!k) continue;
    if (f.geometry.type === 'MultiPoint') {
      for (const c of f.geometry.coordinates) groups.point.push({ ...f, geometry: { type: 'Point', coordinates: c } });
    } else groups[k].push(f);
  }
  const suffix: Record<Kind, string> = { point: 'body', line: 'linie', polygon: 'plochy' };
  const out: { name: string; data: Uint8Array }[] = [];
  const enc = new TextEncoder();
  for (const k of ['point', 'line', 'polygon'] as Kind[]) {
    const fs = groups[k];
    if (!fs.length) continue;
    const name = `${baseName}_${suffix[k]}`;
    const { shp, shx } = writeShp(k, fs.map((f) => f.geometry));
    out.push({ name: `${name}.shp`, data: shp });
    out.push({ name: `${name}.shx`, data: shx });
    out.push({ name: `${name}.dbf`, data: writeDbf(fs.map((f) => (f.properties ?? {}) as Record<string, unknown>)) });
    out.push({ name: `${name}.cpg`, data: enc.encode('UTF-8') });
    if (prj) out.push({ name: `${name}.prj`, data: enc.encode(prj) });
  }
  return out;
}

// --- SHP / SHX --------------------------------------------------------------------
function signedArea(ring: Position[]): number {
  let a = 0;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) a += (ring[j][0] - ring[i][0]) * (ring[j][1] + ring[i][1]);
  return a / 2; // > 0 = po směru hodinových ručiček
}

function partsOf(g: Geometry): Position[][] {
  switch (g.type) {
    case 'LineString':
      return [g.coordinates];
    case 'MultiLineString':
      return g.coordinates;
    case 'Polygon':
      return orientPolygon(g.coordinates);
    case 'MultiPolygon':
      return g.coordinates.flatMap(orientPolygon);
    default:
      return [];
  }
}

// Shapefile: vnější prstenec po směru hodinových ručiček, otvory proti směru
function orientPolygon(rings: Position[][]): Position[][] {
  return rings.map((r, i) => {
    const cw = signedArea(r) > 0;
    const wantCw = i === 0;
    const ring = cw === wantCw ? r : [...r].reverse();
    const f = ring[0];
    const l = ring[ring.length - 1];
    return f[0] === l[0] && f[1] === l[1] ? ring : [...ring, f];
  });
}

function writeShp(kind: Kind, geoms: Geometry[]) {
  const records: Uint8Array[] = [];
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const g of geoms) {
    if (kind === 'point') {
      const [x, y] = (g as GeoJSON.Point).coordinates;
      const b = new DataView(new ArrayBuffer(20));
      b.setInt32(0, 1, true);
      b.setFloat64(4, x, true);
      b.setFloat64(12, y, true);
      records.push(new Uint8Array(b.buffer));
      minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    } else {
      const parts = partsOf(g);
      const pts = parts.flat();
      let bx0 = Infinity, by0 = Infinity, bx1 = -Infinity, by1 = -Infinity;
      for (const [x, y] of pts) {
        bx0 = Math.min(bx0, x); bx1 = Math.max(bx1, x); by0 = Math.min(by0, y); by1 = Math.max(by1, y);
      }
      minX = Math.min(minX, bx0); maxX = Math.max(maxX, bx1); minY = Math.min(minY, by0); maxY = Math.max(maxY, by1);
      const size = 44 + 4 * parts.length + 16 * pts.length;
      const b = new DataView(new ArrayBuffer(size));
      b.setInt32(0, SHAPE_TYPE[kind], true);
      b.setFloat64(4, bx0, true);
      b.setFloat64(12, by0, true);
      b.setFloat64(20, bx1, true);
      b.setFloat64(28, by1, true);
      b.setInt32(36, parts.length, true);
      b.setInt32(40, pts.length, true);
      let idx = 0;
      parts.forEach((p, i) => {
        b.setInt32(44 + 4 * i, idx, true);
        idx += p.length;
      });
      let o = 44 + 4 * parts.length;
      for (const [x, y] of pts) {
        b.setFloat64(o, x, true);
        b.setFloat64(o + 8, y, true);
        o += 16;
      }
      records.push(new Uint8Array(b.buffer));
    }
  }
  if (!isFinite(minX)) minX = minY = maxX = maxY = 0;
  const shpLen = 100 + records.reduce((a, r) => a + 8 + r.length, 0);
  const shxLen = 100 + 8 * records.length;
  const shp = new Uint8Array(shpLen);
  const shx = new Uint8Array(shxLen);
  const header = (buf: Uint8Array, len: number) => {
    const v = new DataView(buf.buffer);
    v.setInt32(0, 9994, false);
    v.setInt32(24, len / 2, false);
    v.setInt32(28, 1000, true);
    v.setInt32(32, SHAPE_TYPE[kind], true);
    v.setFloat64(36, minX, true);
    v.setFloat64(44, minY, true);
    v.setFloat64(52, maxX, true);
    v.setFloat64(60, maxY, true);
  };
  header(shp, shpLen);
  header(shx, shxLen);
  const sv = new DataView(shp.buffer);
  const xv = new DataView(shx.buffer);
  let off = 100;
  records.forEach((r, i) => {
    sv.setInt32(off, i + 1, false);
    sv.setInt32(off + 4, r.length / 2, false);
    shp.set(r, off + 8);
    xv.setInt32(100 + 8 * i, off / 2, false);
    xv.setInt32(100 + 8 * i + 4, r.length / 2, false);
    off += 8 + r.length;
  });
  return { shp, shx };
}

// --- DBF ----------------------------------------------------------------------------
const enc = new TextEncoder();

function truncateUtf8(s: string, maxBytes: number): Uint8Array {
  let b = enc.encode(s);
  if (b.length <= maxBytes) return b;
  // neusekávat uprostřed vícebajtového znaku
  let cut = maxBytes;
  while (cut > 0 && (b[cut] & 0xc0) === 0x80) cut--;
  b = b.slice(0, cut);
  return b;
}

function fieldName(key: string, used: Set<string>): string {
  const ascii = key.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9_]/g, '_');
  let n = ascii.slice(0, 10) || 'pole';
  let i = 1;
  while (used.has(n.toUpperCase())) {
    const sfx = String(i++);
    n = ascii.slice(0, 10 - sfx.length) + sfx;
  }
  used.add(n.toUpperCase());
  return n;
}

function inferFields(rows: Record<string, unknown>[]): DbfField[] {
  const keys: string[] = [];
  for (const r of rows) for (const k of Object.keys(r)) if (!keys.includes(k)) keys.push(k);
  const used = new Set<string>();
  return keys.map((key) => {
    const vals = rows.map((r) => r[key]).filter((v) => v !== null && v !== undefined && v !== '');
    let type: DbfField['type'] = 'C';
    let length = 1;
    let decimals = 0;
    if (vals.length && vals.every((v) => typeof v === 'boolean')) {
      type = 'L';
      length = 1;
    } else if (vals.length && vals.every((v) => typeof v === 'number' && isFinite(v))) {
      type = 'N';
      const isInt = vals.every((v) => Number.isInteger(v));
      decimals = isInt ? 0 : 6;
      length = Math.min(19, Math.max(...vals.map((v) => (decimals ? (v as number).toFixed(decimals) : String(v)).length), 1) + 1);
    } else {
      length = Math.min(254, Math.max(1, ...vals.map((v) => enc.encode(typeof v === 'object' ? JSON.stringify(v) : String(v)).length)));
    }
    return { key, name: fieldName(key, used), type, length, decimals };
  });
}

export function writeDbf(rows: Record<string, unknown>[]): Uint8Array {
  const fields = inferFields(rows);
  const headerLen = 32 + 32 * fields.length + 1;
  const recLen = 1 + fields.reduce((a, f) => a + f.length, 0);
  const buf = new Uint8Array(headerLen + recLen * rows.length + 1);
  const v = new DataView(buf.buffer);
  const now = new Date();
  buf[0] = 0x03;
  buf[1] = now.getFullYear() - 1900;
  buf[2] = now.getMonth() + 1;
  buf[3] = now.getDate();
  v.setUint32(4, rows.length, true);
  v.setUint16(8, headerLen, true);
  v.setUint16(10, recLen, true);
  fields.forEach((f, i) => {
    const o = 32 + 32 * i;
    buf.set(enc.encode(f.name), o);
    buf[o + 11] = f.type.charCodeAt(0);
    buf[o + 16] = f.length;
    buf[o + 17] = f.decimals;
  });
  buf[headerLen - 1] = 0x0d;
  let o = headerLen;
  for (const r of rows) {
    buf[o] = 0x20;
    let p = o + 1;
    for (const f of fields) {
      const raw = r[f.key];
      buf.fill(0x20, p, p + f.length);
      if (raw !== null && raw !== undefined && raw !== '') {
        if (f.type === 'L') buf[p] = raw ? 0x54 : 0x46;
        else if (f.type === 'N') {
          const s = (f.decimals ? Number(raw).toFixed(f.decimals) : String(raw)).slice(0, f.length);
          buf.set(enc.encode(s), p + f.length - s.length);
        } else {
          const s = typeof raw === 'object' ? JSON.stringify(raw) : String(raw);
          buf.set(truncateUtf8(s.replace(/[\r\n]+/g, ' '), f.length), p);
        }
      } else if (f.type === 'L') buf[p] = 0x3f;
      p += f.length;
    }
    o += recLen;
  }
  buf[o] = 0x1a;
  return buf;
}
