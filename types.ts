import type { Feature, FeatureCollection, Geometry, LineString, Point, Polygon } from 'geojson';

export type GeomKind = 'point' | 'line' | 'polygon';
export type ReportStatus = 'new' | 'reviewing' | 'forwarded' | 'in_progress' | 'resolved';
export type Frequency = 'daily' | 'weekly' | 'sometimes' | 'rarely';

export interface Subcategory {
  id: number;
  name: string;
  default_geom: GeomKind | null;
  sort_order: number;
  is_active?: boolean;
  reports?: number;
}

export interface Category {
  id: number;
  code: string | null;
  name: string;
  description: string | null;
  color: string;
  icon: string;
  default_geom: GeomKind;
  sort_order: number;
  allow_custom_topic: boolean;
  requires_approval?: boolean;
  theme: string;
  source: string;
  is_active?: boolean;
  reports?: number;
  subcategories: Subcategory[];
}

export interface District {
  id: number;
  name: string;
  center: [number, number];
  has_boundary: boolean;
}

export interface PublicSettings {
  contributions_open?: boolean;
  support_requires_verified?: boolean;
  contribute_requires_login?: boolean;
  show_demo?: boolean;
  duplicate_radius_m?: number;
  max_photos?: number;
  photos_enabled?: boolean;
  operator_name?: string;
  operator_url?: string;
  map_center?: [number, number];
  map_zoom?: number;
  map_bounds?: [[number, number], [number, number]];
  intro_title?: string;
  intro_subtitle?: string;
  intro_text?: string;
  privacy_controller?: string;
  privacy_contact?: string;
  privacy_dpo?: string;
  retention_text?: string;
  project_end?: string;
  line_tolerance_m?: number;
  point_tolerance_m?: number;
  polygon_tolerance_m?: number;
  hex_size_m?: number;
  [key: string]: unknown;
}

export interface PublicConfig {
  categories: Category[];
  districts: District[];
  settings: PublicSettings;
  demo_visible: boolean;
}

/** Vlastnosti prvku v mapových datech (zkrácené klíče kvůli velikosti odpovědi) */
export interface MapProps {
  id: string;
  no: number;
  c: number; // kategorie
  s: number | null; // podkategorie
  t: string; // název
  k: GeomKind;
  p: number; // unikátní lidé (autor + podporovatelé)
  a: number; // autoři
  sp: number; // podporovatelé (bez autorů)
  st: ReportStatus | null;
  d: string;
  v: string | null; // varianta k
  ph: number;
  cm: number;
  dm: boolean;
  ov: number; // počet dalších lidí se shodným zakreslením
  ag: number | null; // podíl shody 0–1
  ds: number | null;
  u: number[]; // pseudonymní čísla lidí (jen pro výpočet unikátních počtů v clusterech)
}

export type MapFeature = Feature<Geometry, MapProps>;
export type MapData = FeatureCollection<Geometry, MapProps>;

export interface Photo {
  id: string;
  path: string;
  width?: number | null;
  height?: number | null;
}

export interface Comment {
  id: string;
  author_name: string;
  body: string;
  created_at: string;
  is_mine: boolean;
  is_hidden: boolean;
  photos: Photo[];
}

export interface ReportDetail {
  id: string;
  no: number;
  title: string;
  description: string | null;
  solution: string | null;
  custom_topic: string | null;
  frequency: Frequency | null;
  author_name: string;
  category_id: number;
  subcategory_id: number | null;
  kind: GeomKind;
  geometry: Geometry;
  length_m: number | null;
  area_m2: number | null;
  district: string | null;
  created_at: string;
  is_demo: boolean;
  is_hidden: boolean;
  merged_into: string | null;
  status: ReportStatus | null;
  status_public: boolean;
  status_note: string | null;
  people: number;
  authors: number;
  supporters: number;
  overlap_people: number;
  agreement: number | null;
  is_mine: boolean;
  my_support: boolean;
  merged_count: number;
  variant_of: { id: string; no: number; title: string } | null;
  variants: { id: string; no: number; title: string; author_name: string; kind: GeomKind }[];
  photos: Photo[];
  comments: Comment[];
  merged_reports?: { id: string; no: number; title: string; author_name: string }[] | null;
}

export interface NearbyReport {
  id: string;
  no: number;
  title: string;
  kind: GeomKind;
  author_name: string;
  created_at: string;
  people: number;
  distance_m: number;
  is_mine: boolean;
  category_id?: number;
}

export interface MyProfile {
  id: string;
  nickname: string | null;
  contact_email: string | null;
  email: string | null;
  newsletter: boolean;
  is_verified: boolean;
  is_admin: boolean;
  reports: number;
  supports: number;
}

export type DrawGeometry = Point | LineString | Polygon;

export const KIND_LABEL: Record<GeomKind, string> = {
  point: 'Bod',
  line: 'Linie',
  polygon: 'Plocha'
};

export const KIND_HINT: Record<GeomKind, string> = {
  point: 'konkrétní místo',
  line: 'trasa nebo úsek',
  polygon: 'území nebo lokalita'
};

export const STATUS_LABEL: Record<ReportStatus, string> = {
  new: 'Nový',
  reviewing: 'Prověřuje se',
  forwarded: 'Předán městu',
  in_progress: 'V řešení',
  resolved: 'Vyřešeno'
};

export const STATUS_COLOR: Record<ReportStatus, string> = {
  new: '#64748b',
  reviewing: '#d97706',
  forwarded: '#2563eb',
  in_progress: '#7c3aed',
  resolved: '#16a34a'
};

export const FREQUENCY_LABEL: Record<Frequency, string> = {
  daily: 'Denně',
  weekly: 'Několikrát týdně',
  sometimes: 'Občas',
  rarely: 'Výjimečně'
};

/** Kategorie pro veřejnost (bez „Návrhu nové kategorie“, jehož podněty čekají na schválení). */
export function visibleCategories(config: PublicConfig): Category[] {
  return config.categories.filter((c) => !c.requires_approval);
}
export function proposalCategory(config: PublicConfig): Category | undefined {
  return config.categories.find((c) => c.requires_approval);
}
