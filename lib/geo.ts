import type { Geometry, Position } from 'geojson';

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;

export function distanceM(a: Position, b: Position): number {
  const dLat = rad(b[1] - a[1]);
  const dLon = rad(b[0] - a[0]);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[1])) * Math.cos(rad(b[1])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

export function lineLengthM(coords: Position[]): number {
  let l = 0;
  for (let i = 1; i < coords.length; i++) l += distanceM(coords[i - 1], coords[i]);
  return l;
}

/** Plocha prstence v m² (sférická aproximace) */
export function ringAreaM2(ring: Position[]): number {
  if (ring.length < 3) return 0;
  let area = 0;
  for (let i = 0; i < ring.length; i++) {
    const p1 = ring[i];
    const p2 = ring[(i + 1) % ring.length];
    area += rad(p2[0] - p1[0]) * (2 + Math.sin(rad(p1[1])) + Math.sin(rad(p2[1])));
  }
  return Math.abs((area * R * R) / 2);
}

export function allPositions(g: Geometry): Position[] {
  switch (g.type) {
    case 'Point':
      return [g.coordinates];
    case 'MultiPoint':
    case 'LineString':
      return g.coordinates;
    case 'MultiLineString':
    case 'Polygon':
      return g.coordinates.flat();
    case 'MultiPolygon':
      return g.coordinates.flat(2);
    case 'GeometryCollection':
      return g.geometries.flatMap(allPositions);
  }
}

export function bbox(g: Geometry): [number, number, number, number] {
  const pts = allPositions(g);
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [x, y] of pts) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }
  return [minX, minY, maxX, maxY];
}

function pointInRing(pt: Position, ring: Position[]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > pt[1] !== yj > pt[1] && pt[0] < ((xj - xi) * (pt[1] - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

export function pointInPolygon(pt: Position, poly: Position[][]): boolean {
  if (!pointInRing(pt, poly[0])) return false;
  for (let i = 1; i < poly.length; i++) if (pointInRing(pt, poly[i])) return false;
  return true;
}

/** Reprezentativní bod geometrie (střed linie podle délky, těžiště plochy uvnitř) */
export function representativePoint(g: Geometry): Position {
  if (g.type === 'Point') return g.coordinates;
  if (g.type === 'LineString' || g.type === 'MultiLineString') {
    const lines = g.type === 'LineString' ? [g.coordinates] : g.coordinates;
    const longest = lines.reduce((a, b) => (lineLengthM(b) > lineLengthM(a) ? b : a));
    return interpolate(longest, lineLengthM(longest) / 2);
  }
  if (g.type === 'Polygon' || g.type === 'MultiPolygon') {
    const polys = g.type === 'Polygon' ? [g.coordinates] : g.coordinates;
    const biggest = polys.reduce((a, b) => (ringAreaM2(b[0]) > ringAreaM2(a[0]) ? b : a));
    const c = centroid(biggest[0]);
    if (pointInPolygon(c, biggest)) return c;
    const samples = samplePolygon(biggest, 12);
    return samples[0] ?? biggest[0][0];
  }
  const b = bbox(g);
  return [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
}

function centroid(ring: Position[]): Position {
  let x = 0, y = 0, a = 0;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const f = ring[j][0] * ring[i][1] - ring[i][0] * ring[j][1];
    x += (ring[j][0] + ring[i][0]) * f;
    y += (ring[j][1] + ring[i][1]) * f;
    a += f;
  }
  if (a === 0) return ring[0];
  return [x / (3 * a), y / (3 * a)];
}

export function interpolate(coords: Position[], atM: number): Position {
  let acc = 0;
  for (let i = 1; i < coords.length; i++) {
    const d = distanceM(coords[i - 1], coords[i]);
    if (acc + d >= atM && d > 0) {
      const t = (atM - acc) / d;
      return [coords[i - 1][0] + t * (coords[i][0] - coords[i - 1][0]), coords[i - 1][1] + t * (coords[i][1] - coords[i - 1][1])];
    }
    acc += d;
  }
  return coords[coords.length - 1];
}

/** Body rozmístěné po linii v daném kroku (pro heatmapu) */
export function sampleLine(coords: Position[], stepM = 30): Position[] {
  const len = lineLengthM(coords);
  const n = Math.max(1, Math.min(200, Math.round(len / stepM)));
  const out: Position[] = [];
  for (let i = 0; i <= n; i++) out.push(interpolate(coords, (len * i) / n));
  return out;
}

/** Pravidelná síť bodů uvnitř plochy (pro heatmapu) */
export function samplePolygon(poly: Position[][], gridN = 6): Position[] {
  const b = bbox({ type: 'Polygon', coordinates: poly });
  const out: Position[] = [];
  for (let i = 0; i < gridN; i++)
    for (let j = 0; j < gridN; j++) {
      const p: Position = [b[0] + ((i + 0.5) / gridN) * (b[2] - b[0]), b[1] + ((j + 0.5) / gridN) * (b[3] - b[1])];
      if (pointInPolygon(p, poly)) out.push(p);
    }
  if (!out.length) out.push(centroid(poly[0]));
  return out;
}

/** Body pro heatmapu: bod = 1, linie = vzorky po délce, plocha = vzorky uvnitř. Váha se dělí počtem vzorků. */
export function heatSamples(g: Geometry): Position[] {
  switch (g.type) {
    case 'Point':
      return [g.coordinates];
    case 'LineString':
      return sampleLine(g.coordinates);
    case 'MultiLineString':
      return g.coordinates.flatMap((c) => sampleLine(c));
    case 'Polygon':
      return samplePolygon(g.coordinates);
    case 'MultiPolygon':
      return g.coordinates.flatMap((p) => samplePolygon(p));
    default:
      return [representativePoint(g)];
  }
}

export function formatLength(m: number | null | undefined): string {
  if (!m) return '';
  return m >= 1000 ? `${(m / 1000).toFixed(2).replace('.', ',')} km` : `${Math.round(m)} m`;
}

export function formatArea(m2: number | null | undefined): string {
  if (!m2) return '';
  if (m2 >= 10000) return `${(m2 / 10000).toFixed(2).replace('.', ',')} ha`;
  return `${Math.round(m2).toLocaleString('cs-CZ')} m²`;
}

export function formatDate(iso: string): string {
  try {
    return new Date(iso).toLocaleDateString('cs-CZ', { day: 'numeric', month: 'numeric', year: 'numeric' });
  } catch {
    return iso;
  }
}

/** Česká skloňování: 1 člověk, 2–4 lidé, 5+ lidí */
export function plural(n: number, one: string, few: string, many: string): string {
  if (n === 1) return one;
  if (n >= 2 && n <= 4) return few;
  return many;
}

/** Naposledy použité jméno/přezdívka (jen v prohlížeči uživatele) */
export function lastName(): string {
  try {
    return localStorage.getItem('last-name') ?? '';
  } catch {
    return '';
  }
}
export function rememberName(n: string) {
  try {
    localStorage.setItem('last-name', n);
  } catch {
    /* soukromý režim */
  }
}
