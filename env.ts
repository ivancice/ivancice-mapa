export const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? '';
export const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '';
export const SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL ?? '').replace(/\/$/, '');
/** Podadresář, ve kterém web běží (např. "/ivancice-mapa" na GitHub Pages) */
export const BASE_PATH = (process.env.NEXT_PUBLIC_BASE_PATH ?? '').replace(/\/$/, '');
export const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? '';

export const BASEMAP_TILES = process.env.NEXT_PUBLIC_BASEMAP_TILES || 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
export const BASEMAP_ATTRIBUTION =
  process.env.NEXT_PUBLIC_BASEMAP_ATTRIBUTION ||
  '© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">přispěvatelé OpenStreetMap</a>';
export const ORTHO_TILES =
  process.env.NEXT_PUBLIC_ORTHO_TILES ||
  'https://ags.cuzk.gov.cz/arcgis1/rest/services/ORTOFOTO_WM/MapServer/tile/{z}/{y}/{x}';
export const ORTHO_ATTRIBUTION =
  process.env.NEXT_PUBLIC_ORTHO_ATTRIBUTION ||
  'Ortofoto © <a href="https://geoportal.cuzk.gov.cz" target="_blank" rel="noopener">ČÚZK</a> (CC BY 4.0)';

export const isConfigured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);

/** Veřejná adresa aplikace včetně podadresáře, bez koncového lomítka */
export function siteUrl(): string {
  if (SITE_URL) return SITE_URL;
  if (typeof window !== 'undefined') return window.location.origin + BASE_PATH;
  return BASE_PATH;
}

/** Odkaz na podnět ke sdílení */
export function reportUrl(id: string): string {
  return `${siteUrl()}/?p=${id}`;
}

export function photoUrl(path: string): string {
  return `${SUPABASE_URL}/storage/v1/object/public/photos/${path}`;
}
