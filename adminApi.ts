'use client';
import { rpc } from '@/lib/api';
import type { Category, GeomKind, ReportStatus } from '@/lib/types';

export interface AdminReport {
  id: string; no: number; title: string; author_name: string; category_id: number; subcategory_id: number | null;
  custom_topic: string | null; kind: GeomKind; status: ReportStatus; status_public: boolean; is_hidden: boolean;
  hidden_reason: string | null; is_demo: boolean; merged_into: string | null; variant_of: string | null; source: string;
  district_id: number | null; created_at: string; people: number; supporters: number; overlap_people: number;
  agreement: number | null; open_flags: number; photos: number; comments: number; contact_email: string | null;
  admin_note: string | null; description: string | null; solution: string | null; status_note: string | null; geometry?: GeoJSON.Geometry;
}

export const adminApi = {
  stats: (district: number | null, demo: boolean | null) => rpc<AdminStats>('admin_stats', { p_district: district, p_include_demo: demo }),
  reports: (p: Record<string, unknown>) => rpc<AdminReport[]>('admin_list_reports', { p }),
  updateReport: (id: string, p: Record<string, unknown>) => rpc('admin_update_report', { p_id: id, p }),
  merge: (target: string, sources: string[]) => rpc<{ merged: number }>('admin_merge_reports', { p_target: target, p_sources: sources }),
  unmerge: (id: string) => rpc('admin_unmerge_report', { p_id: id }),
  deleteReport: (id: string) => rpc<{ photo_paths: string[] }>('admin_delete_report', { p_id: id }),
  blockAuthor: (id: string, blocked: boolean) => rpc('admin_block_author', { p_report: id, p_blocked: blocked }),
  moderation: () => rpc<ModerationQueue>('admin_moderation_queue'),
  setCommentHidden: (id: string, h: boolean) => rpc('admin_set_comment_hidden', { p_id: id, p_hidden: h }),
  setPhotoHidden: (id: string, h: boolean) => rpc('admin_set_photo_hidden', { p_id: id, p_hidden: h }),
  deletePhoto: (id: string) => rpc<{ path: string }>('admin_delete_photo', { p_id: id }),
  resolveFlag: (id: string, res: string) => rpc('admin_resolve_flag', { p_id: id, p_resolution: res }),
  categories: () => rpc<Category[]>('admin_list_categories'),
  approveProposal: (id: string, categoryId: number | null, name: string | null) => rpc<{ category_id: number }>('admin_approve_proposal', { p_id: id, p_category_id: categoryId, p_name: name, p_color: null }),
  saveCategory: (p: Record<string, unknown>) => rpc<{ id: number }>('admin_save_category', { p }),
  deleteCategory: (id: number) => rpc<{ deleted?: boolean; deactivated?: boolean }>('admin_delete_category', { p_id: id }),
  reorderCategories: (ids: number[]) => rpc('admin_reorder_categories', { p_ids: ids }),
  saveSubcategory: (p: Record<string, unknown>) => rpc<{ id: number }>('admin_save_subcategory', { p }),
  deleteSubcategory: (id: number) => rpc<{ deleted?: boolean; deactivated?: boolean }>('admin_delete_subcategory', { p_id: id }),
  settings: () => rpc<{ key: string; value: unknown; is_public: boolean; description: string | null }[]>('admin_get_settings'),
  setSetting: (key: string, value: unknown) => rpc('admin_set_setting', { p_key: key, p_value: value }),
  admins: () => rpc<{ invited: string[]; active: { id: string; email: string; nickname: string | null }[] }>('admin_list_admins'),
  addAdmin: (email: string) => rpc('admin_add_admin', { p_email: email }),
  removeAdmin: (email: string) => rpc('admin_remove_admin', { p_email: email }),
  newsletter: () => rpc<{ email: string; nickname: string | null; consent_at: string }[]>('admin_newsletter_list'),
  audit: (limit = 300) => rpc<{ id: number; action: string; target_type: string; target_id: string; created_at: string; actor: string | null; new_data: unknown }[]>('admin_audit_log', { p_limit: limit }),
  seedDemo: (n: number) => rpc<{ created: number }>('admin_seed_demo', { p_count: n }),
  deleteDemo: () => rpc<{ deleted: number; photo_paths: string[] }>('admin_delete_demo'),
  importDistricts: (fc: unknown) => rpc<{ imported: number }>('admin_import_district_boundaries', { p_fc: fc }),
  importGeojson: (fc: unknown, options: Record<string, unknown>) =>
    rpc<{ imported: number; skipped: number; categories_created: number }>('admin_import_geojson', { p_fc: fc, p_options: options })
};

export interface ModerationQueue {
  flags: { id: string; reason: string; note: string | null; created_at: string; report_id: string | null; report_title: string | null;
    comment_id: string | null; comment_body: string | null; comment_hidden: boolean | null; photo_id: string | null; photo_path: string | null; photo_hidden: boolean | null }[];
  comments: { id: string; report_id: string; author_name: string; body: string; is_hidden: boolean; created_at: string; report_title: string }[];
  photos: { id: string; report_id: string; comment_id: string | null; path: string; is_hidden: boolean; created_at: string; report_title: string }[];
}

export interface AdminStats {
  totals: Record<string, number>;
  by_category: { category_id: number; name: string; color: string; reports: number; people: number; supporters: number; subcategories: { name: string; reports: number }[] }[];
  by_kind: Record<string, number> | null;
  by_status: Record<string, number> | null;
  by_frequency: Record<string, number> | null;
  by_district: { district_id: number; name: string; reports: number; people: number }[];
  top_supported: { id: string; no: number; title: string; category_id: number; kind: GeomKind; people: number; supporters: number }[];
  top_agreement: { id: string; no: number; title: string; category_id: number; kind: GeomKind; overlap_people: number; agreement: number | null }[];
  agreement_summary: { kind: GeomKind; reports: number; with_overlap: number; avg_agreement: number | null }[];
  timeline: { week: string; reports: number; supports: number }[];
  hotspots: GeoJSON.Feature<GeoJSON.Point, { category_id: number; reports: number; authors: number; people: number; report_ids: string[] }>[];
}
