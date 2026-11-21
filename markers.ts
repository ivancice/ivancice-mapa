/**
 * Mapové značky kreslené na canvas (bez závislosti na fontech mapového stylu).
 * Název obrázku nese všechny parametry, mapa je generuje na vyžádání
 * (událost `styleimagemissing`).
 *   pin|#rrggbb|<počet lidí>|<stav>   – značka ve tvaru kapky s číslem uvnitř
 *   cl|#rrggbb|<podněty>|<lidé>        – shluk bodů stejné kategorie
 */
const PR = 2; // pixel ratio

export function pinImageName(color: string, people: number, state: 'n' | 's' | 'm' = 'n') {
  return `pin|${color}|${Math.max(1, people)}|${state}`;
}

export function clusterImageName(color: string, count: number, people: number) {
  return `cl|${color}|${count}|${people}`;
}

function pinScale(n: number) {
  if (n >= 50) return 1.42;
  if (n >= 20) return 1.3;
  if (n >= 10) return 1.2;
  if (n >= 5) return 1.1;
  return 1;
}

function label(n: number) {
  return n > 999 ? '999+' : String(n);
}

export function badgeImageName(color: string, people: number) {
  return `bd|${color}|${Math.max(1, people)}`;
}

export function drawImage(name: string): { width: number; height: number; data: Uint8ClampedArray } | null {
  const parts = name.split('|');
  if (parts[0] === 'bd' && parts.length === 3) return drawBadge(parts[1], Number(parts[2]) || 1);
  if (parts[0] === 'pin' && parts.length === 4) return drawPin(parts[1], Number(parts[2]) || 1, parts[3]);
  if (parts[0] === 'cl' && parts.length === 4) return drawCluster(parts[1], Number(parts[2]) || 0, Number(parts[3]) || 0);
  return null;
}

function canvas(w: number, h: number) {
  const c = document.createElement('canvas');
  c.width = Math.ceil(w * PR);
  c.height = Math.ceil(h * PR);
  const ctx = c.getContext('2d')!;
  ctx.scale(PR, PR);
  return { c, ctx };
}

function drawPin(color: string, n: number, state: string) {
  const s = pinScale(n);
  const r = 13 * s; // poloměr hlavy kapky
  const w = r * 2 + 8;
  const h = r * 2 + 16 * s + 6;
  const { c, ctx } = canvas(w, h);
  const cx = w / 2;
  const cy = r + 3;
  const tipY = h - 3;

  // stín
  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.25)';
  ctx.beginPath();
  ctx.ellipse(cx, tipY - 1, r * 0.45, 2.2, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // tvar kapky
  const ang = Math.asin(r / (tipY - cy));
  ctx.beginPath();
  ctx.moveTo(cx, tipY);
  ctx.arc(cx, cy, r, Math.PI / 2 + ang, Math.PI / 2 - ang, false);
  ctx.closePath();
  ctx.fillStyle = color;
  ctx.fill();
  ctx.lineWidth = state === 's' ? 3.5 : 2;
  ctx.strokeStyle = state === 's' ? '#111827' : '#ffffff';
  ctx.stroke();

  // vnitřní kruh
  ctx.beginPath();
  ctx.arc(cx, cy, r * 0.74, 0, Math.PI * 2);
  ctx.fillStyle = '#ffffff';
  ctx.fill();

  // číslo = počet unikátních lidí
  const txt = label(n);
  const fs = (txt.length >= 3 ? 10.5 : 13) * s;
  ctx.fillStyle = '#111827';
  ctx.font = `700 ${fs}px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(txt, cx, cy + 0.5);

  if (state === 'm') {
    // ukázková data – přerušovaný obrys
    ctx.setLineDash([3, 2]);
    ctx.strokeStyle = '#111827';
    ctx.lineWidth = 1.2;
    ctx.beginPath();
    ctx.arc(cx, cy, r * 0.74, 0, Math.PI * 2);
    ctx.stroke();
  }
  const img = ctx.getImageData(0, 0, c.width, c.height);
  return { width: c.width, height: c.height, data: img.data };
}

function drawCluster(color: string, count: number, people: number) {
  const base = count >= 50 ? 26 : count >= 20 ? 23 : count >= 8 ? 20 : 17;
  const badgeTxt = label(people);
  const bw = 12 + badgeTxt.length * 6.2;
  // symetrické plátno, aby střed kruhu = střed obrázku (kotvení na souřadnici)
  const w = 2 * Math.max(base + 5, base * 0.55 + bw + 3);
  const h = 2 * (base * 0.62 + 10);
  const { c, ctx } = canvas(w, Math.max(h, base * 2 + 10));
  const cx = w / 2;
  const cy = Math.max(h, base * 2 + 10) / 2;

  ctx.beginPath();
  ctx.arc(cx, cy, base + 4, 0, Math.PI * 2);
  ctx.fillStyle = hexA(color, 0.28);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(cx, cy, base, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.strokeStyle = '#ffffff';
  ctx.stroke();

  ctx.fillStyle = '#ffffff';
  ctx.font = `800 ${count >= 100 ? 13 : 15}px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(label(count), cx, cy + 0.5);

  // odznak s počtem unikátních lidí
  const bx = cx + base * 0.55;
  const by = cy + base * 0.62;
  const bh = 15;
  roundRect(ctx, bx, by - bh / 2, bw, bh, bh / 2);
  ctx.fillStyle = '#111827';
  ctx.fill();
  ctx.strokeStyle = '#ffffff';
  ctx.lineWidth = 1.5;
  ctx.stroke();
  // ikona osoby
  ctx.fillStyle = '#ffffff';
  ctx.beginPath();
  ctx.arc(bx + 6.5, by - 2.2, 2.2, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(bx + 6.5, by + 4.2, 3.6, Math.PI, 0);
  ctx.fill();
  ctx.font = `700 10px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`;
  ctx.textAlign = 'left';
  ctx.fillText(badgeTxt, bx + 11.5, by + 0.5);

  const img = ctx.getImageData(0, 0, c.width, c.height);
  return { width: c.width, height: c.height, data: img.data };
}

/** Odznak s počtem lidí pro linie a plochy */
function drawBadge(color: string, n: number) {
  const txt = label(n);
  const w = 14 + txt.length * 7;
  const h = 20;
  const { c, ctx } = canvas(w + 4, h + 4);
  roundRect(ctx, 2, 2, w, h, h / 2);
  ctx.fillStyle = '#ffffff';
  ctx.fill();
  ctx.lineWidth = 2.5;
  ctx.strokeStyle = color;
  ctx.stroke();
  ctx.fillStyle = '#111827';
  ctx.font = `700 11.5px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(txt, 2 + w / 2, 2 + h / 2 + 0.5);
  const img = ctx.getImageData(0, 0, c.width, c.height);
  return { width: c.width, height: c.height, data: img.data };
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

export function hexA(hex: string, a: number) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

export const PIXEL_RATIO = PR;
