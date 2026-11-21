'use client';
import { getSupabase } from '@/lib/supabase/client';
import type {
  DrawGeometry,
  Frequency,
  GeomKind,
  MapData,
  MyProfile,
  NearbyReport,
  PublicConfig,
  ReportDetail
} from '@/lib/types';

const MESSAGES: Record<string, string> = {
  not_authenticated: 'Pro tuto akci je potřeba se přihlásit.',
  blocked: 'Váš účet byl zablokován správcem mapy.',
  forbidden: 'K této akci nemáte oprávnění.',
  topic_required: 'Napište prosím název kategorie, kterou navrhujete.',
  rate_limit: 'Odesíláte příliš mnoho příspěvků v krátké době. Zkuste to prosím za chvíli.',
  spam_detected: 'Příspěvek byl vyhodnocen jako nevyžádaný obsah. Pokud jde o omyl, upravte text (např. méně odkazů).',
  title_required: 'Vyplňte prosím název podnětu (alespoň 3 znaky).',
  name_required: 'Vyplňte prosím jméno nebo přezdívku.',
  category_required: 'Vyberte prosím kategorii.',
  invalid_subcategory: 'Vybraná podkategorie nepatří do zvolené kategorie.',
  invalid_geometry: 'Zakreslení není platné. Zkuste ho prosím nakreslit znovu.',
  geometry_kind_mismatch: 'Typ zakreslení neodpovídá zvolenému typu.',
  geometry_too_complex: 'Zakreslení má příliš mnoho bodů.',
  line_too_short: 'Linie je příliš krátká.',
  line_too_long: 'Linie je příliš dlouhá.',
  polygon_too_small: 'Plocha je příliš malá nebo neplatná.',
  polygon_too_large: 'Plocha je příliš velká.',
  outside_area: 'Zakreslení leží mimo území Ivančic a místních částí.',
  invalid_photo_path: 'Fotografii se nepodařilo připojit.',
  invalid_email: 'Zadaný e-mail nemá platný formát.',
  contributions_closed: 'Sběr podnětů je momentálně uzavřen.',
  login_required: 'Přidávat podněty a komentáře mohou jen přihlášení uživatelé. Přihlaste se prosím odkazem zaslaným na e-mail – je to bez hesla.',
  verification_required: 'Podpořit podnět mohou jen přihlášení uživatelé. Přihlaste se prosím odkazem zaslaným na e-mail – zajišťuje, že každý hlasuje jen jednou.',
  own_report: 'Vlastní podnět nelze podpořit – jako autor jste už započítáni.',
  not_found: 'Podnět nebyl nalezen nebo byl skryt.',
  comment_required: 'Napište prosím text komentáře.',
  invalid_flag: 'Nahlášení se nepodařilo uložit.',
  merge_into_self: 'Podnět nelze sloučit sám se sebou.',
  target_is_merged: 'Cílový podnět je sám sloučený do jiného.',
  last_admin: 'Nelze odebrat posledního administrátora.',
  unknown_setting: 'Neznámé nastavení.',
  unsupported_srid: 'Nepodporovaný souřadnicový systém.'
};

export class ApiError extends Error {
  code: string;
  constructor(code: string, message?: string) {
    super(message ?? MESSAGES[code] ?? code);
    this.code = code;
  }
}

export function errorMessage(e: unknown): string {
  if (e instanceof ApiError) return e.message;
  if (e instanceof Error) {
    const m = e.message;
    if (MESSAGES[m]) return MESSAGES[m];
    if (/fetch|network/i.test(m)) return 'Nepodařilo se spojit se serverem. Zkontrolujte připojení k internetu.';
    return m;
  }
  return 'Neočekávaná chyba.';
}

export async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await getSupabase().rpc(fn, args ?? {});
  if (error) {
    const code = (error.message || '').trim();
    if (MESSAGES[code]) throw new ApiError(code);
    if (error.code === '42501') throw new ApiError('forbidden');
    throw new ApiError(code || 'error', MESSAGES[code] ?? (error.message || 'Chyba serveru'));
  }
  return data as T;
}

// --- Veřejné API --------------------------------------------------------
export const api = {
  config: () => rpc<PublicConfig>('get_public_config'),
  mapData: () => rpc<MapData>('get_map_data'),
  report: (id: string) => rpc<ReportDetail | null>('get_report', { p_id: id }),
  nearby: (geometry: DrawGeometry, category: number) =>
    rpc<NearbyReport[]>('nearby_reports', { p_geometry: geometry, p_category: category }),
  around: (id: string, radius = 150) => rpc<NearbyReport[]>('reports_around', { p_id: id, p_radius_m: radius }),
  createReport: (p: {
    category_id: number;
    subcategory_id: number | null;
    custom_topic?: string;
    title: string;
    description?: string;
    solution?: string;
    frequency?: Frequency | '';
    author_name: string;
    email?: string;
    newsletter?: boolean;
    kind: GeomKind;
    geometry: DrawGeometry;
    variant_of?: string | null;
    photos?: { path: string; width: number; height: number }[];
    website?: string;
  }) => rpc<{ id: string; no: number; pending?: boolean }>('create_report', { p }),
  setSupport: (id: string, support: boolean) =>
    rpc<{ report_id: string; people: number; supporters: number; authors: number; my_support: boolean }>('set_support', {
      p_report: id,
      p_support: support
    }),
  addComment: (id: string, body: string, name: string, photos?: { path: string; width: number; height: number }[]) =>
    rpc<{ id: string }>('add_comment', { p_report: id, p_body: body, p_author_name: name, p_photos: photos ?? null }),
  flag: (p: { report?: string | null; comment?: string | null; photo?: string | null; reason: string; note?: string }) =>
    rpc<{ id: string }>('flag_content', {
      p_report: p.report ?? null,
      p_comment: p.comment ?? null,
      p_photo: p.photo ?? null,
      p_reason: p.reason,
      p_note: p.note ?? null
    }),
  myProfile: () => rpc<MyProfile | null>('get_my_profile'),
  updateProfile: (nickname: string | null, email: string | null, newsletter: boolean | null) =>
    rpc<MyProfile>('update_my_profile', { p_nickname: nickname, p_contact_email: email, p_newsletter: newsletter }),
  myReports: () =>
    rpc<{ id: string; no: number; title: string; kind: GeomKind; category_id: number; created_at: string; is_hidden: boolean; pending?: boolean; custom_topic?: string | null; people: number }[]>(
      'my_reports'
    ),
  updateMyReport: (id: string, title: string, description: string, solution: string) =>
    rpc('update_my_report', { p_id: id, p_title: title, p_description: description, p_solution: solution }),
  withdrawMyReport: (id: string) => rpc('withdraw_my_report', { p_id: id }),
  createClaimToken: () => rpc<string | null>('create_claim_token'),
  claim: (token: string) => rpc<{ moved: number }>('claim_contributions', { p_token: token }),
  deleteMyAccount: () => rpc('delete_my_account'),
  analysis: (layer: 'polygon_overlap' | 'line_overlap' | 'point_clusters' | 'hexgrid', categories: number[] | null) =>
    rpc<GeoJSON.FeatureCollection>('get_analysis', { p_layer: layer, p_categories: categories })
};
