-- =====================================================================
-- Ivančice očima pěších a cyklistů – databázové schéma
-- Supabase / PostgreSQL 15+ / PostGIS 3.1+
-- =====================================================================
-- Princip zabezpečení:
--   * Všechny tabulky mají zapnuté RLS.
--   * Veřejnost (role anon/authenticated) nemá přímý přístup k tabulkám
--     s osobními údaji. Čtení i zápis probíhá výhradně přes funkce (RPC)
--     s pečlivou validací (SECURITY DEFINER, pevný search_path).
--   * Číselníky (kategorie, podkategorie, místní části) jsou veřejně čitelné.
-- =====================================================================

create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Výčtové typy
-- ---------------------------------------------------------------------
do $$ begin
  create type public.geom_kind as enum ('point', 'line', 'polygon');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.report_status as enum ('new', 'reviewing', 'forwarded', 'in_progress', 'resolved');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.visit_frequency as enum ('daily', 'weekly', 'sometimes', 'rarely');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Nastavení aplikace (klíč → JSON hodnota)
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key         text primary key,
  value       jsonb not null,
  is_public   boolean not null default false,
  description text,
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Kategorie a podkategorie (editovatelné administrátorem)
-- ---------------------------------------------------------------------
create table if not exists public.categories (
  id            serial primary key,
  code          text unique,
  name          text not null check (char_length(name) between 1 and 120),
  description   text,
  color         text not null default '#2563eb' check (color ~ '^#[0-9a-fA-F]{6}$'),
  icon          text not null default 'map-pin',
  default_geom  public.geom_kind not null default 'point',
  sort_order    integer not null default 0,
  is_active     boolean not null default true,
  allow_custom_topic boolean not null default false,  -- „Jiné / vlastní podnět“
  theme         text not null default 'mobilita',      -- tematická vrstva (budoucí rozšíření platformy)
  source        text not null default 'app',           -- 'app' | 'maphub' (původní kategorie)
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.categories add column if not exists requires_approval boolean not null default false;  -- návrhy nových kategorií: podněty čekají na schválení správcem

create table if not exists public.subcategories (
  id            serial primary key,
  category_id   integer not null references public.categories(id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 160),
  default_geom  public.geom_kind,   -- null = převezme se z kategorie
  sort_order    integer not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index if not exists subcategories_category_idx on public.subcategories(category_id);
do $$ begin
  alter table public.subcategories add constraint subcategories_name_uq unique (category_id, name);
exception when duplicate_object or duplicate_table then null; end $$;

-- ---------------------------------------------------------------------
-- Místní části (pro statistiky). Hranice lze nahrát v administraci
-- (GeoJSON z RÚIAN/OSM). Bez hranic se použije nejbližší střed.
-- ---------------------------------------------------------------------
create table if not exists public.districts (
  id          serial primary key,
  name        text not null unique,
  center      extensions.geometry(Point, 4326) not null,
  boundary    extensions.geometry(MultiPolygon, 4326),
  sort_order  integer not null default 0
);
create index if not exists districts_boundary_gix on public.districts using gist(boundary);

-- ---------------------------------------------------------------------
-- Profily uživatelů (neveřejné). E-mail z přihlášení je v auth.users.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  nickname       text check (nickname is null or char_length(nickname) between 1 and 60),
  contact_email  text check (contact_email is null or contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  newsletter     boolean not null default false,
  newsletter_at  timestamptz,
  privacy_ack_at timestamptz,
  is_admin       boolean not null default false,
  is_blocked     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- E-maily, které po přihlášení automaticky získají roli administrátora
create table if not exists public.admin_emails (
  email      text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Podněty (body, linie, plochy)
-- ---------------------------------------------------------------------
create table if not exists public.reports (
  id              uuid primary key default gen_random_uuid(),
  public_no       bigserial unique,
  user_id         uuid references auth.users(id) on delete set null,
  author_key      uuid not null,             -- pseudonymní identita autora (zůstává i po smazání účtu)
  author_name     text not null check (char_length(author_name) between 1 and 60),
  category_id     integer not null references public.categories(id),
  subcategory_id  integer references public.subcategories(id) on delete set null,
  custom_topic    text check (custom_topic is null or char_length(custom_topic) <= 120),
  title           text not null check (char_length(title) between 3 and 140),
  description     text check (description is null or char_length(description) <= 3000),
  solution        text check (solution is null or char_length(solution) <= 3000),
  frequency       public.visit_frequency,
  geom            extensions.geometry(Geometry, 4326) not null,
  geom_kind       public.geom_kind not null,
  length_m        double precision,
  area_m2         double precision,
  district_id     integer references public.districts(id) on delete set null,
  variant_of      uuid references public.reports(id) on delete set null,   -- vlastní prostorová varianta
  merged_into     uuid references public.reports(id) on delete set null,   -- sloučení duplicit (data zůstávají)
  status          public.report_status not null default 'new',
  status_public   boolean not null default false,
  status_note     text,
  is_hidden       boolean not null default false,
  hidden_reason   text,
  is_demo         boolean not null default false,
  source          text not null default 'app',
  admin_note      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint reports_geom_kind_chk check (
    (geom_kind = 'point'   and extensions.GeometryType(geom) in ('POINT')) or
    (geom_kind = 'line'    and extensions.GeometryType(geom) in ('LINESTRING', 'MULTILINESTRING')) or
    (geom_kind = 'polygon' and extensions.GeometryType(geom) in ('POLYGON', 'MULTIPOLYGON'))
  ),
  constraint reports_not_self_merged check (merged_into is null or merged_into <> id)
);
create index if not exists reports_geom_gix on public.reports using gist(geom);
create index if not exists reports_category_idx on public.reports(category_id);
create index if not exists reports_author_idx on public.reports(author_key);
create index if not exists reports_user_idx on public.reports(user_id);
create index if not exists reports_merged_idx on public.reports(merged_into);
create index if not exists reports_created_idx on public.reports(created_at);

-- Podpora („Také to vnímám jako problém“) – jeden člověk = jeden hlas
create table if not exists public.supports (
  report_id  uuid not null references public.reports(id) on delete cascade,
  user_id    uuid not null,     -- auth.users.id (u ukázkových dat náhodné UUID)
  created_at timestamptz not null default now(),
  primary key (report_id, user_id)
);
create index if not exists supports_user_idx on public.supports(user_id);

-- Komentáře
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.reports(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete set null,
  author_key  uuid not null,
  author_name text not null check (char_length(author_name) between 1 and 60),
  body        text not null check (char_length(body) between 1 and 2000),
  is_hidden   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists comments_report_idx on public.comments(report_id);

-- Fotografie (soubory v Supabase Storage, bucket „photos“)
create table if not exists public.photos (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.reports(id) on delete cascade,
  comment_id  uuid references public.comments(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete set null,
  path        text not null unique,
  width       integer,
  height      integer,
  is_hidden   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists photos_report_idx on public.photos(report_id);

-- Nahlášení nevhodného obsahu
create table if not exists public.flags (
  id           uuid primary key default gen_random_uuid(),
  report_id    uuid references public.reports(id) on delete cascade,
  comment_id   uuid references public.comments(id) on delete cascade,
  photo_id     uuid references public.photos(id) on delete cascade,
  user_id      uuid,
  reason       text not null check (reason in ('spam', 'offensive', 'personal_data', 'duplicate', 'wrong_location', 'other')),
  note         text check (note is null or char_length(note) <= 1000),
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  resolved_by  uuid,
  resolution   text,
  constraint flags_target_chk check (num_nonnulls(report_id, comment_id, photo_id) >= 1)
);
create index if not exists flags_open_idx on public.flags(resolved_at) where resolved_at is null;

-- Jednorázové tokeny pro převod příspěvků anonymní relace na ověřený účet
create table if not exists public.claim_tokens (
  token       text primary key,
  anon_uid    uuid not null,
  created_at  timestamptz not null default now()
);

-- Auditní záznam administrátorských zásahů (zachování původních dat)
create table if not exists public.audit_log (
  id          bigserial primary key,
  actor       uuid,
  action      text not null,
  target_type text,
  target_id   text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists audit_log_target_idx on public.audit_log(target_type, target_id);

-- ---------------------------------------------------------------------
-- RLS: zapnout všude. Veřejně čitelné jen číselníky.
-- ---------------------------------------------------------------------
alter table public.app_settings  enable row level security;
alter table public.categories    enable row level security;
alter table public.subcategories enable row level security;
alter table public.districts     enable row level security;
alter table public.profiles      enable row level security;
alter table public.admin_emails  enable row level security;
alter table public.reports       enable row level security;
alter table public.supports      enable row level security;
alter table public.comments      enable row level security;
alter table public.photos        enable row level security;
alter table public.flags         enable row level security;
alter table public.claim_tokens  enable row level security;
alter table public.audit_log     enable row level security;

drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories for select to anon, authenticated using (true);
drop policy if exists subcategories_read on public.subcategories;
create policy subcategories_read on public.subcategories for select to anon, authenticated using (true);
drop policy if exists districts_read on public.districts;
create policy districts_read on public.districts for select to anon, authenticated using (true);
drop policy if exists settings_read_public on public.app_settings;
create policy settings_read_public on public.app_settings for select to anon, authenticated using (is_public);

-- Přímé zápisy do tabulek zakázat (vše přes RPC)
revoke insert, update, delete on all tables in schema public from anon, authenticated;
revoke select on public.profiles, public.admin_emails, public.reports, public.supports,
  public.comments, public.photos, public.flags, public.claim_tokens, public.audit_log
  from anon, authenticated;
