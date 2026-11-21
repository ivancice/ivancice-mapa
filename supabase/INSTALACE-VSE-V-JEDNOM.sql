-- ============================================================================
-- Ivančice očima pěších a cyklistů – kompletní instalace databáze v jednom souboru
-- Vložte celý obsah do Supabase → SQL Editor → New query a klikněte na Run.
-- Obsahuje všechny soubory ze supabase/migrations v pořadí, včetně 81 zakreslení
-- z původní mapy MapHub. Opakované spuštění data nepoškodí.
-- ============================================================================

-- >>> 20261120000100_schema.sql
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

-- >>> 20261120000200_helpers.sql
-- =====================================================================
-- Pomocné funkce, triggery, pohledy
-- =====================================================================

-- Nastavení -----------------------------------------------------------
create or replace function public.setting(p_key text)
returns jsonb language sql stable security definer set search_path = public as $$
  select value from public.app_settings where key = p_key
$$;

create or replace function public.setting_num(p_key text, p_default double precision)
returns double precision language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::double precision from public.app_settings where key = p_key
                   and jsonb_typeof(value) = 'number'), p_default)
$$;

create or replace function public.setting_bool(p_key text, p_default boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = p_key
                   and jsonb_typeof(value) = 'boolean'), p_default)
$$;

-- Identita volajícího --------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin and not p.is_blocked from public.profiles p where p.id = auth.uid()), false)
$$;

-- Ověřený uživatel = přihlášený přes e-mail (ne anonymní relace)
create or replace function public.is_verified_user()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
     and coalesce((select u.email is not null and u.email <> '' from auth.users u where u.id = auth.uid()), false)
$$;

create or replace function public._require_user()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles where id = v and is_blocked) then
    raise exception 'blocked' using errcode = 'P0001';
  end if;
  return v;
end $$;

create or replace function public._require_admin()
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return auth.uid();
end $$;

-- Ochrana proti spamu: počet záznamů uživatele za časové okno
create or replace function public._rate_ok(p_table text, p_limit integer, p_window interval)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare n integer;
begin
  if public.is_admin() then return true; end if;
  if p_table not in ('reports', 'comments', 'supports', 'flags', 'photos') then
    raise exception 'bad_table';
  end if;
  execute format('select count(*) from public.%I where user_id = $1 and created_at > now() - $2', p_table)
    into n using auth.uid(), p_window;
  return n < p_limit;
end $$;

-- Jednoduchá heuristika spamu v textu (počet odkazů)
create or replace function public._looks_like_spam(p_text text)
returns boolean language sql immutable as $$
  select coalesce(
    (select count(*) from regexp_matches(coalesce(p_text, ''), '(https?://|www\.)', 'gi')) > 3
    or coalesce(p_text, '') ~* '(viagra|casino|crypto ?airdrop|porn)', false)
$$;

create or replace function public._clean(p_text text, p_max integer)
returns text language sql immutable as $$
  select nullif(left(btrim(regexp_replace(coalesce(p_text, ''), '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', '', 'g')), p_max), '')
$$;

-- Metrická projekce pro výpočty (UTM 33N – Ivančice leží v pásmu 33)
create or replace function public._m(g extensions.geometry)
returns extensions.geometry language sql immutable parallel safe set search_path = public, extensions as $$
  select ST_Transform(g, 32633)
$$;

-- Místní část dle polohy -------------------------------------------------
create or replace function public._district_for(g extensions.geometry)
returns integer language sql stable security definer set search_path = public, extensions as $$
  with pt as (select ST_PointOnSurface(g) p)
  select coalesce(
    (select d.id from public.districts d, pt where d.boundary is not null and ST_Intersects(d.boundary, pt.p)
      order by d.sort_order limit 1),
    (select d.id from public.districts d, pt
      where not exists (select 1 from public.districts x where x.boundary is not null)
      order by ST_Distance(d.center::geography, pt.p::geography) limit 1),
    -- hranice jsou nahrány, ale bod leží mimo ně → nejbližší hranice do 1 km
    (select d.id from public.districts d, pt where d.boundary is not null
       and ST_DWithin(d.boundary::geography, pt.p::geography, 1000)
      order by ST_Distance(d.boundary::geography, pt.p::geography) limit 1)
  )
$$;

-- Triggery ---------------------------------------------------------------
create or replace function public._touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists trg_reports_touch on public.reports;
create trigger trg_reports_touch before update on public.reports
  for each row execute function public._touch_updated_at();
drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public._touch_updated_at();
drop trigger if exists trg_categories_touch on public.categories;
create trigger trg_categories_touch before update on public.categories
  for each row execute function public._touch_updated_at();

create or replace function public._reports_geom_derive()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'INSERT' or new.geom is distinct from old.geom then
    new.length_m := case when new.geom_kind = 'line' then ST_Length(new.geom::geography) end;
    new.area_m2  := case when new.geom_kind = 'polygon' then ST_Area(new.geom::geography) end;
    new.district_id := public._district_for(new.geom);
  end if;
  return new;
end $$;

drop trigger if exists trg_reports_geom on public.reports;
create trigger trg_reports_geom before insert or update of geom on public.reports
  for each row execute function public._reports_geom_derive();

-- Profil se zakládá automaticky s novým uživatelem (i anonymním)
create or replace function public._handle_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, is_admin)
  values (new.id, coalesce(new.email is not null and exists (select 1 from public.admin_emails a where a.email = lower(new.email)), false))
  on conflict (id) do update
    set is_admin = public.profiles.is_admin
                   or coalesce(new.email is not null and exists (select 1 from public.admin_emails a where a.email = lower(new.email)), false);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public._handle_auth_user();
drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email after update of email on auth.users
  for each row when (new.email is distinct from old.email) execute function public._handle_auth_user();

-- Po smazání uživatele odstranit jeho hlasy (podpory nemají FK kvůli ukázkovým datům)
create or replace function public._handle_auth_user_deleted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.supports where user_id = old.id;
  return old;
end $$;
drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted after delete on auth.users
  for each row execute function public._handle_auth_user_deleted();

-- Veřejně viditelné podněty ----------------------------------------------
-- (nejsou skryté, nejsou sloučené do jiného, ukázková data jen pokud je zapnuto)
create or replace function public._visible_reports()
returns setof public.reports language sql stable security definer set search_path = public as $$
  select r.* from public.reports r
  where not r.is_hidden and r.merged_into is null
    and (not r.is_demo or public.setting_bool('show_demo', false))
$$;

-- Členové skupiny podnětu = autor + podporovatelé, včetně sloučených duplicit.
-- gid = id cílového (viditelného) podnětu.
create or replace view public.v_report_members as
  select coalesce(r.merged_into, r.id) as gid, r.author_key as person, true as is_author
    from public.reports r where not r.is_hidden
  union all
  select coalesce(r.merged_into, r.id) as gid, s.user_id as person, false as is_author
    from public.supports s join public.reports r on r.id = s.report_id where not r.is_hidden;

create or replace view public.v_report_people as
  select gid as report_id,
         count(distinct person)::int as people,                                   -- unikátní lidé celkem
         count(distinct person) filter (where is_author)::int as authors,         -- autoři zakreslení
         (count(distinct person) - count(distinct person) filter (where is_author))::int as supporters -- jen podpořili
  from public.v_report_members group by gid;

revoke all on public.v_report_members, public.v_report_people from anon, authenticated;

-- Funkce _require_* a interní pomocníky nevystavovat veřejnosti
revoke execute on function public._require_user(), public._require_admin(),
  public._rate_ok(text, integer, interval), public._visible_reports(),
  public._district_for(extensions.geometry) from public, anon, authenticated;

-- Nastavení čte veřejnost jen přes get_public_config (pouze veřejné klíče)
revoke execute on function public.setting(text), public.setting_num(text, double precision),
  public.setting_bool(text, boolean) from public, anon, authenticated;

-- Funkce používané v pravidlech RLS (např. úložiště fotografií) musí být spustitelné
-- i v projektech, kde se oprávnění k API nepřidělují automaticky.
grant usage on schema public to anon, authenticated;
grant execute on function public.is_admin(), public.is_verified_user() to anon, authenticated;

-- >>> 20261120000300_analysis.sql
-- =====================================================================
-- Prostorové analýzy (PostGIS)
-- Všechny výpočty probíhají v metrické projekci UTM 33N (EPSG:32633).
-- Tolerance jsou nastavitelné v app_settings:
--   line_tolerance_m    – max. vzdálenost dvou linií považovaných za shodnou trasu (výchozí 15 m)
--   line_angle_deg      – max. rozdíl směru linií (výchozí 35°), aby se kolmé křížení nepočítalo jako shoda
--   line_segment_m      – délka úseku pro výpočet překryvu linií (výchozí 25 m)
--   polygon_tolerance_m – tolerance hranic ploch (výchozí 5 m)
--   point_tolerance_m   – vzdálenost bodů považovaných za stejné místo (výchozí 40 m)
--   hex_size_m          – velikost buňky šestiúhelníkové sítě (výchozí 150 m)
-- Jeden člověk se v každé analýze počítá vždy jen jednou (count distinct author_key/person).
-- =====================================================================

-- Úhlová shoda úseku `seg` s linií `other` v místě nejbližším středu úseku
create or replace function public._angle_close(seg extensions.geometry, other extensions.geometry, max_deg double precision)
returns boolean language plpgsql immutable parallel safe set search_path = public, extensions as $$
declare
  len double precision := ST_Length(other);
  pos double precision;
  d double precision;
  loc extensions.geometry;
  a1 double precision;
  a2 double precision;
  diff double precision;
begin
  if len = 0 or ST_Length(seg) = 0 then return true; end if;
  pos := ST_LineLocatePoint(other, ST_LineInterpolatePoint(seg, 0.5));
  d := least(10.0 / len, 0.5);
  loc := ST_LineSubstring(other, greatest(pos - d, 0), least(pos + d, 1));
  a1 := ST_Azimuth(ST_StartPoint(seg), ST_EndPoint(seg));
  a2 := ST_Azimuth(ST_StartPoint(loc), ST_EndPoint(loc));
  if a1 is null or a2 is null then return true; end if;
  diff := mod(abs(degrees(a1 - a2))::numeric, 180)::double precision;
  return least(diff, 180 - diff) <= max_deg;
end $$;

-- ---------------------------------------------------------------------
-- Míra shody jednotlivých podnětů (pro filtrování a detail)
--   overlap_people – počet DALŠÍCH lidí (autorů), kteří zakreslili shodné/překrývající
--                    se místo stejné kategorie a stejného typu geometrie
--   agreement      – podíl délky (linie) / plochy (plocha) podnětu, který je
--                    pokryt zakresleními jiných lidí (0–1); u bodů null
-- ---------------------------------------------------------------------
create or replace function public._compute_report_metrics()
returns table (report_id uuid, overlap_people integer, agreement double precision)
language sql stable security definer set search_path = public, extensions as $$
  with t as (
    select public.setting_num('line_tolerance_m', 15) lt,
           public.setting_num('point_tolerance_m', 40) pt,
           public.setting_num('polygon_tolerance_m', 5) plt
  ),
  b as (
    select r.id, r.author_key, r.category_id, r.geom_kind, r.is_demo, public._m(r.geom) g
    from public.reports r where not r.is_hidden and r.merged_into is null
  ),
  pairs as (
    select x.id, o.author_key, o.g
    from b x cross join t
    join b o on o.id <> x.id and o.author_key <> x.author_key and o.is_demo = x.is_demo
             and o.category_id = x.category_id and o.geom_kind = x.geom_kind
             and ST_DWithin(o.g, x.g, greatest(t.lt, t.pt, t.plt))
    where case x.geom_kind
            when 'point' then ST_DWithin(o.g, x.g, t.pt)
            when 'polygon' then ST_Area(ST_Intersection(ST_Buffer(o.g, t.plt), x.g))
                                  >= 0.05 * least(ST_Area(o.g), ST_Area(x.g))
            else ST_Length(ST_Intersection(x.g, ST_Buffer(o.g, t.lt)))
                   >= greatest(2.5 * t.lt, 0.2 * least(ST_Length(x.g), ST_Length(o.g)))
          end
  )
  select b.id,
         coalesce((select count(distinct p.author_key) from pairs p where p.id = b.id), 0)::int,
         case b.geom_kind
           when 'point' then null
           when 'polygon' then (
             select least(1.0, ST_Area(ST_Intersection(b.g, ST_UnaryUnion(ST_Collect(ST_Buffer(p.g, t.plt))))) / nullif(ST_Area(b.g), 0))
             from pairs p, t where p.id = b.id)
           else (
             select least(1.0, ST_Length(ST_Intersection(b.g, ST_UnaryUnion(ST_Collect(ST_Buffer(p.g, t.lt))))) / nullif(ST_Length(b.g), 0))
             from pairs p, t where p.id = b.id)
         end
  from b
$$;

drop materialized view if exists public.report_metrics;
create materialized view public.report_metrics as
  select * from public._compute_report_metrics();
create unique index report_metrics_pk on public.report_metrics(report_id);
revoke all on public.report_metrics from anon, authenticated;

create or replace function public._refresh_metrics()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- hromadné operace (import, ukázková data) přepočítají metriky jednou na konci
  if coalesce(current_setting('app.skip_metrics', true), '') = 'on' then return null; end if;
  refresh materialized view public.report_metrics;
  return null;
end $$;

drop trigger if exists trg_reports_metrics on public.reports;
create trigger trg_reports_metrics after insert or update or delete on public.reports
  for each statement execute function public._refresh_metrics();

-- ---------------------------------------------------------------------
-- A. Překryvy ploch: rozdělení území na dílčí plochy podle počtu
--    unikátních lidí, jejichž zakreslení danou část pokrývá.
-- ---------------------------------------------------------------------
create or replace function public.analysis_polygon_overlap(p_categories integer[] default null)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with t as (select public.setting_num('polygon_tolerance_m', 5) tol),
  polys as (
    select r.author_key,
           ST_UnaryUnion(ST_Collect(ST_SnapToGrid(public._m(r.geom), 0.01))) g
    from public._visible_reports() r
    where r.geom_kind = 'polygon' and (p_categories is null or r.category_id = any(p_categories))
    group by r.author_key
  ),
  total as (select count(*)::int n from polys),
  edges as (select ST_UnaryUnion(ST_Collect(ST_Boundary(g))) e from polys),
  faces as (select (ST_Dump(ST_Polygonize(e))).geom f from edges),
  counted as (
    select f,
      (select count(*) from polys p, t where ST_DWithin(p.g, ST_PointOnSurface(f), t.tol))::int n,
      exists (select 1 from polys p where ST_Intersects(p.g, ST_PointOnSurface(f))) inside
    from faces where ST_Area(f) > 1
  ),
  dissolved as (
    select n, ST_UnaryUnion(ST_Collect(f)) g from counted where inside and n >= 1 group by n
  )
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'total_people', (select n from total),
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(ST_Transform(d.g, 4326), 6)::jsonb,
      'properties', jsonb_build_object(
        'people', d.n,
        'share', round(d.n::numeric / nullif((select n from total), 0), 3),
        'area_m2', round(ST_Area(d.g)::numeric)
      )) order by d.n), '[]'::jsonb))
  from dissolved d
$$;

-- ---------------------------------------------------------------------
-- B. Překryvy linií: každá linie se rozdělí na úseky; u každého úseku se
--    spočítá, kolik různých lidí zakreslilo trasu v toleranci a podobném směru.
-- ---------------------------------------------------------------------
create or replace function public.analysis_line_overlap(p_categories integer[] default null)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with p as (
    select public.setting_num('line_segment_m', 25) seg,
           public.setting_num('line_tolerance_m', 15) tol,
           public.setting_num('line_angle_deg', 35) ang
  ),
  lines as (
    select r.id, r.author_key, r.category_id, d.geom g
    from public._visible_reports() r
    cross join lateral ST_Dump(ST_LineMerge(public._m(r.geom))) d
    where r.geom_kind = 'line' and (p_categories is null or r.category_id = any(p_categories))
      and ST_Length(d.geom) > 0
  ),
  total as (select count(distinct author_key)::int n from lines),
  segs as (
    select l.id, l.category_id,
           ST_LineSubstring(l.g, least((i * p.seg) / x.len, 1), least(((i + 1) * p.seg) / x.len, 1)) sg
    from lines l cross join p
    cross join lateral (select ST_Length(l.g) len) x
    cross join lateral generate_series(0, greatest(ceil(x.len / p.seg)::int - 1, 0)) i
  ),
  counted as (
    select s.id, s.category_id, s.sg,
      (select count(distinct o.author_key) from lines o
        where ST_DWithin(o.g, ST_LineInterpolatePoint(s.sg, 0.5), p.tol)
          and public._angle_close(s.sg, o.g, p.ang))::int n
    from segs s cross join p
    where ST_Length(s.sg) > 0
  ),
  grouped as (
    select id, category_id, n, ST_LineMerge(ST_Collect(sg)) g from counted group by id, category_id, n
  )
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'total_people', (select n from total),
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(ST_Transform(g.g, 4326), 6)::jsonb,
      'properties', jsonb_build_object(
        'report_id', g.id, 'category_id', g.category_id, 'people', g.n,
        'share', round(g.n::numeric / nullif((select n from total), 0), 3),
        'length_m', round(ST_Length(g.g)::numeric)
      )) order by g.n), '[]'::jsonb))
  from grouped g
$$;

-- ---------------------------------------------------------------------
-- C. Shluky bodů stejné kategorie (DBSCAN)
-- ---------------------------------------------------------------------
create or replace function public.analysis_point_clusters(p_categories integer[] default null)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with t as (select public.setting_num('point_tolerance_m', 40) eps),
  pts as (
    select r.id, r.category_id, r.author_key, public._m(r.geom) g
    from public._visible_reports() r
    where r.geom_kind = 'point' and (p_categories is null or r.category_id = any(p_categories))
  ),
  cl as (
    select pts.*, ST_ClusterDBSCAN(g, eps := t.eps, minpoints := 1) over (partition by category_id) cid
    from pts cross join t
  ),
  agg as (
    select category_id, cid, count(*)::int n_reports, count(distinct author_key)::int n_authors,
           ST_Centroid(ST_Collect(g)) c, array_agg(id) ids
    from cl group by category_id, cid
  )
  select jsonb_build_object('type', 'FeatureCollection', 'features', coalesce(jsonb_agg(jsonb_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(a.c, 4326), 6)::jsonb,
    'properties', jsonb_build_object(
      'category_id', a.category_id,
      'reports', a.n_reports,
      'authors', a.n_authors,
      'people', (select count(distinct m.person) from public.v_report_members m where m.gid = any(a.ids)),
      'report_ids', to_jsonb(a.ids)
    )) order by a.n_reports desc), '[]'::jsonb))
  from agg a
$$;

-- ---------------------------------------------------------------------
-- Šestiúhelníková síť: počet zakreslení, autorů a unikátních lidí v buňce
-- (celková mapa intenzity problémů)
-- ---------------------------------------------------------------------
create or replace function public.analysis_hexgrid(p_categories integer[] default null, p_size double precision default null)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with p as (select greatest(50, least(2000, coalesce(p_size, public.setting_num('hex_size_m', 150)))) s),
  vis as (
    select r.id, r.author_key, public._m(r.geom) g
    from public._visible_reports() r
    where (p_categories is null or r.category_id = any(p_categories))
  ),
  ext as (select ST_SetSRID(ST_Extent(g)::extensions.geometry, 32633) e from vis),
  hex as (
    select h.geom hg, h.i, h.j from ext cross join p
    cross join lateral ST_HexagonGrid(p.s, ST_Expand(ext.e, p.s)) h
    where ext.e is not null
  ),
  hit as (
    select h.i, h.j, h.hg, v.id, v.author_key from hex h join vis v on ST_Intersects(h.hg, v.g)
  ),
  agg as (
    select i, j, hg, count(distinct id)::int n_objects, count(distinct author_key)::int n_authors, array_agg(distinct id) ids
    from hit group by i, j, hg
  )
  select jsonb_build_object('type', 'FeatureCollection', 'features', coalesce(jsonb_agg(jsonb_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(a.hg, 4326), 6)::jsonb,
    'properties', jsonb_build_object(
      'objects', a.n_objects,
      'authors', a.n_authors,
      'people', (select count(distinct m.person) from public.v_report_members m where m.gid = any(a.ids))
    ))), '[]'::jsonb))
  from agg a
$$;

grant execute on function public.analysis_polygon_overlap(integer[]) to anon, authenticated;
grant execute on function public.analysis_line_overlap(integer[]) to anon, authenticated;
grant execute on function public.analysis_point_clusters(integer[]) to anon, authenticated;
grant execute on function public.analysis_hexgrid(integer[], double precision) to anon, authenticated;
revoke execute on function public._compute_report_metrics() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Mezipaměť analytických vrstev. Výsledek se přepočítá jen tehdy, když se
-- změnila data (podněty, podpory) nebo nastavení tolerancí.
-- ---------------------------------------------------------------------
create table if not exists public.analysis_cache (
  key        text primary key,
  version    text not null,
  result     jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.analysis_cache enable row level security;
revoke all on public.analysis_cache from anon, authenticated;

create or replace function public._data_version()
returns text language sql stable security definer set search_path = public as $$
  select concat_ws('|',
    (select count(*) || ':' || coalesce(max(updated_at)::text, '') from public.reports),
    (select count(*) || ':' || coalesce(max(created_at)::text, '') from public.supports),
    (select coalesce(max(updated_at)::text, '') from public.app_settings))
$$;

create or replace function public.get_analysis(p_layer text, p_categories integer[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_key text;
  v_ver text := public._data_version();
  v_res jsonb;
  cats integer[] := (select array_agg(distinct c order by c) from unnest(p_categories) c);
begin
  if p_layer not in ('polygon_overlap', 'line_overlap', 'point_clusters', 'hexgrid') then
    raise exception 'unknown_layer' using errcode = 'P0001';
  end if;
  v_key := p_layer || ':' || coalesce(array_to_string(cats, ','), 'all');
  select result into v_res from public.analysis_cache where key = v_key and version = v_ver;
  if v_res is not null then return v_res; end if;
  v_res := case p_layer
    when 'polygon_overlap' then public.analysis_polygon_overlap(cats)
    when 'line_overlap' then public.analysis_line_overlap(cats)
    when 'point_clusters' then public.analysis_point_clusters(cats)
    else public.analysis_hexgrid(cats, null) end;
  insert into public.analysis_cache (key, version, result) values (v_key, v_ver, v_res)
    on conflict (key) do update set version = excluded.version, result = excluded.result, created_at = now();
  -- udržovat mezipaměť malou
  delete from public.analysis_cache where created_at < now() - interval '7 days';
  return v_res;
end $$;
grant execute on function public.get_analysis(text, integer[]) to anon, authenticated;
revoke execute on function public._data_version() from public, anon, authenticated;

-- >>> 20261120000400_public_api.sql
-- =====================================================================
-- Veřejné API (RPC) – volané z webové aplikace přes supabase-js
-- Chybové kódy (exception message) překládá frontend do češtiny.
-- =====================================================================

-- Konfigurace pro frontend: kategorie, podkategorie, místní části, veřejná nastavení
create or replace function public.get_public_config()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'code', c.code, 'name', c.name, 'description', c.description, 'color', c.color,
        'icon', c.icon, 'default_geom', c.default_geom, 'sort_order', c.sort_order,
        'allow_custom_topic', c.allow_custom_topic, 'theme', c.theme, 'source', c.source,
        'subcategories', coalesce((select jsonb_agg(jsonb_build_object(
            'id', s.id, 'name', s.name, 'default_geom', s.default_geom, 'sort_order', s.sort_order)
            order by s.sort_order, s.id)
          from public.subcategories s where s.category_id = c.id and s.is_active), '[]'::jsonb)
      ) order by c.sort_order, c.id) from public.categories c where c.is_active), '[]'::jsonb),
    'districts', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'name', d.name, 'center', jsonb_build_array(round(ST_X(d.center)::numeric, 6), round(ST_Y(d.center)::numeric, 6)),
        'has_boundary', d.boundary is not null) order by d.sort_order, d.id) from public.districts d), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(s.key, s.value) from public.app_settings s where s.is_public), '{}'::jsonb),
    'demo_visible', public.setting_bool('show_demo', false) and exists (select 1 from public.reports where is_demo)
  )
$$;

-- Data pro mapu: všechny viditelné podněty jako GeoJSON FeatureCollection.
-- Vlastnost `u` obsahuje pseudonymní čísla lidí (platná jen v rámci jedné odpovědi,
-- náhodně zamíchaná), aby mapa mohla v clusterech počítat UNIKÁTNÍ lidi
-- bez zveřejnění jakékoli identity.
create or replace function public.get_map_data()
returns jsonb language sql volatile security definer set search_path = public, extensions as $$
  with vis as (select * from public._visible_reports()),
  mem as (select m.gid, m.person from public.v_report_members m join vis on vis.id = m.gid),
  salt as (select gen_random_uuid()::text s),
  idx as (
    select person, dense_rank() over (order by md5(person::text || salt.s)) i
    from (select distinct person from mem) x cross join salt
  ),
  ppl as (
    select mem.gid, array_agg(distinct idx.i order by idx.i) u from mem join idx using (person) group by mem.gid
  ),
  ph as (select report_id, count(*)::int n from public.photos where not is_hidden group by report_id),
  cm as (select report_id, count(*)::int n from public.comments where not is_hidden group by report_id)
  select jsonb_build_object('type', 'FeatureCollection', 'generated_at', now(), 'features',
    coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'id', r.public_no,
      'geometry', ST_AsGeoJSON(r.geom, 6)::jsonb,
      'properties', jsonb_build_object(
        'id', r.id, 'no', r.public_no, 'c', r.category_id, 's', r.subcategory_id,
        't', r.title, 'k', r.geom_kind,
        'p', coalesce(pp.people, 1), 'a', coalesce(pp.authors, 1), 'sp', coalesce(pp.supporters, 0),
        'st', case when r.status_public then r.status end,
        'd', to_char(r.created_at at time zone 'Europe/Prague', 'YYYY-MM-DD'),
        'v', r.variant_of, 'ph', coalesce(ph.n, 0), 'cm', coalesce(cm.n, 0), 'dm', r.is_demo,
        'ov', coalesce(m.overlap_people, 0), 'ag', round(m.agreement::numeric, 2),
        'ds', r.district_id, 'u', coalesce(to_jsonb(ppl.u), '[]'::jsonb)
      )) order by r.created_at), '[]'::jsonb))
  from vis r
  left join public.v_report_people pp on pp.report_id = r.id
  left join public.report_metrics m on m.report_id = r.id
  left join ppl on ppl.gid = r.id
  left join ph on ph.report_id = r.id
  left join cm on cm.report_id = r.id
$$;

-- Detail podnětu
create or replace function public.get_report(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  r public.reports;
  uid uuid := auth.uid();
  admin boolean := public.is_admin();
  res jsonb;
begin
  select * into r from public.reports where id = p_id;
  if not found then return null; end if;
  if (r.is_hidden or (r.is_demo and not public.setting_bool('show_demo', false)))
     and not admin and r.author_key is distinct from uid then
    return null;
  end if;

  select jsonb_build_object(
    'id', r.id, 'no', r.public_no, 'title', r.title, 'description', r.description,
    'solution', r.solution, 'custom_topic', r.custom_topic, 'frequency', r.frequency,
    'author_name', r.author_name, 'category_id', r.category_id, 'subcategory_id', r.subcategory_id,
    'kind', r.geom_kind, 'geometry', ST_AsGeoJSON(r.geom, 6)::jsonb,
    'length_m', round(r.length_m::numeric), 'area_m2', round(r.area_m2::numeric),
    'district', (select name from public.districts where id = r.district_id),
    'created_at', r.created_at, 'is_demo', r.is_demo, 'is_hidden', r.is_hidden,
    'merged_into', r.merged_into,
    'status', case when r.status_public or admin then r.status end,
    'status_public', r.status_public,
    'status_note', case when r.status_public or admin then r.status_note end,
    'people', coalesce(pp.people, 1), 'authors', coalesce(pp.authors, 1), 'supporters', coalesce(pp.supporters, 0),
    'overlap_people', coalesce(m.overlap_people, 0), 'agreement', round(m.agreement::numeric, 2),
    'is_mine', uid is not null and r.author_key = uid,
    'my_support', uid is not null and exists (
        select 1 from public.supports s join public.reports x on x.id = s.report_id
        where s.user_id = uid and coalesce(x.merged_into, x.id) = r.id),
    'merged_count', (select count(*) from public.reports x where x.merged_into = r.id),
    'variant_of', case when r.variant_of is not null then (
        select jsonb_build_object('id', v.id, 'no', v.public_no, 'title', v.title)
        from public.reports v where v.id = r.variant_of and not v.is_hidden) end,
    'variants', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'no', v.public_no, 'title', v.title,
        'author_name', v.author_name, 'kind', v.geom_kind) order by v.created_at)
        from public._visible_reports() v where v.variant_of = r.id), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id', ph.id, 'path', ph.path, 'width', ph.width, 'height', ph.height)
        order by ph.created_at) from public.photos ph
        where ph.report_id in (select x.id from public.reports x where x.id = r.id or x.merged_into = r.id)
          and ph.comment_id is null and (not ph.is_hidden or admin)), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'author_name', c.author_name, 'body', c.body, 'created_at', c.created_at,
        'is_mine', uid is not null and c.author_key = uid, 'is_hidden', c.is_hidden,
        'photos', coalesce((select jsonb_agg(jsonb_build_object('id', ph.id, 'path', ph.path))
                  from public.photos ph where ph.comment_id = c.id and (not ph.is_hidden or admin)), '[]'::jsonb))
        order by c.created_at) from public.comments c
        where c.report_id in (select x.id from public.reports x where x.id = r.id or x.merged_into = r.id)
          and (not c.is_hidden or admin)), '[]'::jsonb),
    'merged_reports', case when admin then coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'no', x.public_no,
        'title', x.title, 'author_name', x.author_name)) from public.reports x where x.merged_into = r.id), '[]'::jsonb) end
  ) into res
  from (select 1) _
  left join public.v_report_people pp on pp.report_id = r.id
  left join public.report_metrics m on m.report_id = r.id;

  return res;
end $$;

-- Blízké existující podněty stejné kategorie (upozornění před vytvořením nového)
create or replace function public.nearby_reports(p_geometry jsonb, p_category integer, p_radius_m double precision default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g extensions.geometry;
  rad double precision := least(coalesce(p_radius_m, public.setting_num('duplicate_radius_m', 60)), 500);
begin
  begin
    g := ST_SetSRID(ST_GeomFromGeoJSON(p_geometry::text), 4326);
  exception when others then
    raise exception 'invalid_geometry' using errcode = 'P0001';
  end;
  return coalesce((
    select jsonb_agg(x order by (x->>'distance_m')::numeric) from (
      select jsonb_build_object(
        'id', r.id, 'no', r.public_no, 'title', r.title, 'kind', r.geom_kind,
        'author_name', r.author_name, 'created_at', r.created_at,
        'people', coalesce(pp.people, 1),
        'distance_m', round(ST_Distance(r.geom::geography, g::geography)::numeric),
        'is_mine', r.author_key = auth.uid()
      ) x
      from public._visible_reports() r
      left join public.v_report_people pp on pp.report_id = r.id
      where r.category_id = p_category
        and ST_DWithin(r.geom::geography, g::geography, rad)
      order by ST_Distance(r.geom::geography, g::geography)
      limit 8
    ) q), '[]'::jsonb);
end $$;

-- Podněty v okolí libovolného podnětu (pro „zobrazit další zakreslení v lokalitě“)
create or replace function public.reports_around(p_id uuid, p_radius_m double precision default 150)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with me as (select geom from public.reports where id = p_id)
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'no', r.public_no, 'title', r.title, 'kind', r.geom_kind, 'category_id', r.category_id,
      'author_name', r.author_name, 'people', coalesce(pp.people, 1),
      'distance_m', round(ST_Distance(r.geom::geography, me.geom::geography)::numeric))
      order by ST_Distance(r.geom::geography, me.geom::geography)), '[]'::jsonb)
  from me, public._visible_reports() r
  left join public.v_report_people pp on pp.report_id = r.id
  where r.id <> p_id and ST_DWithin(r.geom::geography, me.geom::geography, least(greatest(p_radius_m, 10), 1000))
$$;

-- Validace a normalizace geometrie z GeoJSON
create or replace function public._parse_geometry(p_geometry jsonb, p_kind public.geom_kind)
returns extensions.geometry language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g extensions.geometry;
  center extensions.geometry;
  radius_km double precision;
  area jsonb := public.setting('service_area');
begin
  begin
    g := ST_SetSRID(ST_GeomFromGeoJSON(p_geometry::text), 4326);
  exception when others then
    raise exception 'invalid_geometry' using errcode = 'P0001';
  end;
  if g is null or ST_IsEmpty(g) then raise exception 'invalid_geometry' using errcode = 'P0001'; end if;
  if ST_NPoints(g) > 2000 then raise exception 'geometry_too_complex' using errcode = 'P0001'; end if;

  g := ST_Force2D(g);
  if p_kind = 'point' then
    if GeometryType(g) <> 'POINT' then raise exception 'geometry_kind_mismatch' using errcode = 'P0001'; end if;
  elsif p_kind = 'line' then
    if GeometryType(g) not in ('LINESTRING', 'MULTILINESTRING') then raise exception 'geometry_kind_mismatch' using errcode = 'P0001'; end if;
    g := ST_RemoveRepeatedPoints(g);
    if ST_Length(g::geography) < 5 then raise exception 'line_too_short' using errcode = 'P0001'; end if;
    if ST_Length(g::geography) > 40000 then raise exception 'line_too_long' using errcode = 'P0001'; end if;
  else
    if GeometryType(g) not in ('POLYGON', 'MULTIPOLYGON') then raise exception 'geometry_kind_mismatch' using errcode = 'P0001'; end if;
    g := ST_CollectionExtract(ST_MakeValid(ST_RemoveRepeatedPoints(g)), 3);
    if ST_IsEmpty(g) or ST_Area(g::geography) < 10 then raise exception 'polygon_too_small' using errcode = 'P0001'; end if;
    if ST_Area(g::geography) > 30000000 then raise exception 'polygon_too_large' using errcode = 'P0001'; end if;
    if ST_NumGeometries(g) = 1 then g := ST_GeometryN(g, 1); end if;
  end if;

  -- Územní rozsah (střed + poloměr) – zabraňuje zakreslení mimo Ivančice
  if area is not null then
    center := ST_SetSRID(ST_MakePoint((area->>'lon')::double precision, (area->>'lat')::double precision), 4326);
    radius_km := coalesce((area->>'radius_km')::double precision, 10);
    if not ST_DWithin(ST_PointOnSurface(g)::geography, center::geography, radius_km * 1000) then
      raise exception 'outside_area' using errcode = 'P0001';
    end if;
  end if;
  return g;
end $$;

-- Uložení fotografií (soubor už je nahrán do Storage do složky uživatele)
create or replace function public._attach_photos(p_report uuid, p_comment uuid, p_photos jsonb, p_uid uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  ph jsonb;
  n integer := 0;
  max_photos integer := public.setting_num('max_photos', 5)::int;
begin
  if p_photos is null or jsonb_typeof(p_photos) <> 'array' then return 0; end if;
  if not public.setting_bool('photos_enabled', true) then return 0; end if;
  for ph in select * from jsonb_array_elements(p_photos) loop
    exit when n >= max_photos;
    if (ph->>'path') is null or (ph->>'path') !~ ('^' || p_uid::text || '/[A-Za-z0-9._-]{1,120}$') then
      raise exception 'invalid_photo_path' using errcode = 'P0001';
    end if;
    insert into public.photos (report_id, comment_id, user_id, path, width, height)
    values (p_report, p_comment, p_uid, ph->>'path',
            nullif(ph->>'width', '')::int, nullif(ph->>'height', '')::int)
    on conflict (path) do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Aktualizace profilu z formuláře
create or replace function public._upsert_profile(p_uid uuid, p_nickname text, p_email text, p_newsletter boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text := lower(public._clean(p_email, 200));
begin
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email' using errcode = 'P0001';
  end if;
  insert into public.profiles (id, nickname, contact_email, newsletter, newsletter_at, privacy_ack_at)
  values (p_uid, public._clean(p_nickname, 60), v_email, coalesce(p_newsletter, false) and v_email is not null,
          case when coalesce(p_newsletter, false) and v_email is not null then now() end, now())
  on conflict (id) do update set
    nickname = coalesce(public._clean(p_nickname, 60), public.profiles.nickname),
    contact_email = coalesce(v_email, public.profiles.contact_email),
    newsletter = case when p_newsletter is null then public.profiles.newsletter
                      else p_newsletter and coalesce(v_email, public.profiles.contact_email) is not null end,
    newsletter_at = case when p_newsletter and not public.profiles.newsletter then now()
                         when p_newsletter = false then null
                         else public.profiles.newsletter_at end,
    privacy_ack_at = coalesce(public.profiles.privacy_ack_at, now());
end $$;

-- Vytvoření podnětu
create or replace function public.create_report(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := public._require_user();
  v_kind public.geom_kind;
  v_cat public.categories;
  v_sub integer;
  v_geom extensions.geometry;
  v_title text := public._clean(p->>'title', 140);
  v_name text := public._clean(p->>'author_name', 60);
  v_desc text := public._clean(p->>'description', 3000);
  v_sol text := public._clean(p->>'solution', 3000);
  v_topic text := public._clean(p->>'custom_topic', 120);
  v_freq public.visit_frequency;
  v_variant uuid;
  v_id uuid;
  v_no bigint;
  verified boolean := public.is_verified_user();
begin
  if not public.setting_bool('contributions_open', true) and not public.is_admin() then
    raise exception 'contributions_closed' using errcode = 'P0001';
  end if;
  if public.setting_bool('contribute_requires_login', false) and not verified then
    raise exception 'login_required' using errcode = 'P0001';
  end if;
  -- honeypot (skryté pole formuláře vyplní jen robot)
  if coalesce(p->>'website', '') <> '' then raise exception 'spam_detected' using errcode = 'P0001'; end if;
  if not public._rate_ok('reports', case when verified then public.setting_num('rate_reports_verified', 30)::int
                                         else public.setting_num('rate_reports_anon', 8)::int end, interval '1 hour') then
    raise exception 'rate_limit' using errcode = 'P0001';
  end if;
  if v_title is null or char_length(v_title) < 3 then raise exception 'title_required' using errcode = 'P0001'; end if;
  if v_name is null then raise exception 'name_required' using errcode = 'P0001'; end if;
  if public._looks_like_spam(concat_ws(' ', v_title, v_desc, v_sol, v_name)) then
    raise exception 'spam_detected' using errcode = 'P0001';
  end if;

  select * into v_cat from public.categories where id = (p->>'category_id')::int and is_active;
  if not found then raise exception 'category_required' using errcode = 'P0001'; end if;
  if (p->>'subcategory_id') is not null and (p->>'subcategory_id') <> '' then
    select id into v_sub from public.subcategories
      where id = (p->>'subcategory_id')::int and category_id = v_cat.id and is_active;
    if v_sub is null then raise exception 'invalid_subcategory' using errcode = 'P0001'; end if;
  end if;
  if not v_cat.allow_custom_topic then v_topic := null; end if;

  begin
    v_kind := (p->>'kind')::public.geom_kind;
  exception when others then raise exception 'invalid_geometry' using errcode = 'P0001'; end;
  v_geom := public._parse_geometry(p->'geometry', v_kind);

  if (p->>'frequency') is not null and (p->>'frequency') <> '' then
    begin v_freq := (p->>'frequency')::public.visit_frequency;
    exception when others then v_freq := null; end;
  end if;

  if (p->>'variant_of') is not null and (p->>'variant_of') <> '' then
    select id into v_variant from public._visible_reports() where id = (p->>'variant_of')::uuid;
  end if;

  perform public._upsert_profile(uid, v_name, p->>'email', (p->>'newsletter')::boolean);

  insert into public.reports (user_id, author_key, author_name, category_id, subcategory_id, custom_topic,
                              title, description, solution, frequency, geom, geom_kind, variant_of, is_demo)
  values (uid, uid, v_name, v_cat.id, v_sub, v_topic, v_title, v_desc, v_sol, v_freq, v_geom, v_kind, v_variant, false)
  returning id, public_no into v_id, v_no;

  perform public._attach_photos(v_id, null, p->'photos', uid);

  return jsonb_build_object('id', v_id, 'no', v_no);
end $$;

-- Podpora podnětu („Také to vnímám jako problém“) / odebrání podpory
create or replace function public.set_support(p_report uuid, p_support boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public._require_user();
  target public.reports;
  pp record;
begin
  if public.setting_bool('support_requires_verified', true) and not public.is_verified_user() then
    raise exception 'verification_required' using errcode = 'P0001';
  end if;
  select * into target from public.reports where id = p_report;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if target.merged_into is not null then
    select * into target from public.reports where id = target.merged_into;
  end if;
  if target.is_hidden then raise exception 'not_found' using errcode = 'P0001'; end if;

  if p_support then
    if exists (select 1 from public.v_report_members m where m.gid = target.id and m.person = uid and m.is_author) then
      raise exception 'own_report' using errcode = 'P0001';
    end if;
    if not public._rate_ok('supports', public.setting_num('rate_supports', 120)::int, interval '1 hour') then
      raise exception 'rate_limit' using errcode = 'P0001';
    end if;
    insert into public.supports (report_id, user_id) values (target.id, uid) on conflict do nothing;
  else
    delete from public.supports s using public.reports x
      where s.report_id = x.id and coalesce(x.merged_into, x.id) = target.id and s.user_id = uid;
  end if;

  select * into pp from public.v_report_people where report_id = target.id;
  return jsonb_build_object('report_id', target.id, 'people', coalesce(pp.people, 1),
    'supporters', coalesce(pp.supporters, 0), 'authors', coalesce(pp.authors, 1), 'my_support', p_support);
end $$;

-- Komentář (volitelně s fotografií)
create or replace function public.add_comment(p_report uuid, p_body text, p_author_name text, p_photos jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public._require_user();
  v_body text := public._clean(p_body, 2000);
  v_name text := public._clean(p_author_name, 60);
  target uuid;
  v_id uuid;
begin
  if public.setting_bool('contribute_requires_login', false) and not public.is_verified_user() then
    raise exception 'login_required' using errcode = 'P0001';
  end if;
  if v_body is null then raise exception 'comment_required' using errcode = 'P0001'; end if;
  if v_name is null then raise exception 'name_required' using errcode = 'P0001'; end if;
  if public._looks_like_spam(v_body || ' ' || v_name) then raise exception 'spam_detected' using errcode = 'P0001'; end if;
  if not public._rate_ok('comments', public.setting_num('rate_comments', 20)::int, interval '1 hour') then
    raise exception 'rate_limit' using errcode = 'P0001';
  end if;
  select coalesce(merged_into, id) into target from public.reports where id = p_report and not is_hidden;
  if target is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform public._upsert_profile(uid, v_name, null, null);
  insert into public.comments (report_id, user_id, author_key, author_name, body)
  values (target, uid, uid, v_name, v_body) returning id into v_id;
  perform public._attach_photos(target, v_id, p_photos, uid);
  return jsonb_build_object('id', v_id);
end $$;

-- Nahlášení nevhodného obsahu
create or replace function public.flag_content(p_report uuid, p_comment uuid, p_photo uuid, p_reason text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._require_user(); v_id uuid;
begin
  if not public._rate_ok('flags', 30, interval '1 hour') then raise exception 'rate_limit' using errcode = 'P0001'; end if;
  insert into public.flags (report_id, comment_id, photo_id, user_id, reason, note)
  values (p_report, p_comment, p_photo, uid, p_reason, public._clean(p_note, 1000)) returning id into v_id;
  return jsonb_build_object('id', v_id);
exception when check_violation then
  raise exception 'invalid_flag' using errcode = 'P0001';
end $$;

-- Profil přihlášeného uživatele (včetně e-mailu – vidí jen sám uživatel)
create or replace function public.get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'id', auth.uid(),
    'nickname', p.nickname, 'contact_email', p.contact_email,
    'email', (select email from auth.users where id = auth.uid()),
    'newsletter', coalesce(p.newsletter, false),
    'is_verified', public.is_verified_user(),
    'is_admin', public.is_admin(),
    'reports', (select count(*) from public.reports where author_key = auth.uid()),
    'supports', (select count(*) from public.supports where user_id = auth.uid())
  ) end
  from (select 1) _ left join public.profiles p on p.id = auth.uid()
$$;

create or replace function public.update_my_profile(p_nickname text, p_contact_email text, p_newsletter boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._require_user();
begin
  perform public._upsert_profile(uid, p_nickname, p_contact_email, p_newsletter);
  if p_contact_email is not null and btrim(p_contact_email) = '' then
    update public.profiles set contact_email = null, newsletter = false, newsletter_at = null where id = uid;
  end if;
  return public.get_my_profile();
end $$;

create or replace function public.my_reports()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'no', r.public_no, 'title', r.title, 'kind', r.geom_kind, 'category_id', r.category_id,
    'created_at', r.created_at, 'is_hidden', r.is_hidden, 'people', coalesce(pp.people, 1),
    'status', case when r.status_public then r.status end) order by r.created_at desc), '[]'::jsonb)
  from public.reports r left join public.v_report_people pp on pp.report_id = r.id
  where r.author_key = auth.uid()
$$;

-- Autor může upravit text svého podnětu (geometrii ne – místo toho lze vytvořit variantu)
create or replace function public.update_my_report(p_id uuid, p_title text, p_description text, p_solution text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._require_user(); old public.reports;
begin
  select * into old from public.reports where id = p_id and author_key = uid;
  if not found then raise exception 'forbidden' using errcode = 'P0001'; end if;
  if public._clean(p_title, 140) is null or char_length(public._clean(p_title, 140)) < 3 then
    raise exception 'title_required' using errcode = 'P0001';
  end if;
  if public._looks_like_spam(concat_ws(' ', p_title, p_description, p_solution)) then
    raise exception 'spam_detected' using errcode = 'P0001';
  end if;
  update public.reports set title = public._clean(p_title, 140), description = public._clean(p_description, 3000),
    solution = public._clean(p_solution, 3000) where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id, old_data)
  values (uid, 'author_edit', 'report', p_id::text, to_jsonb(old) - 'geom');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.withdraw_my_report(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._require_user();
begin
  update public.reports set is_hidden = true, hidden_reason = 'withdrawn_by_author'
   where id = p_id and author_key = uid;
  if not found then raise exception 'forbidden' using errcode = 'P0001'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Převod příspěvků z anonymní relace na ověřený účet (při přihlášení e-mailem
-- na účet, který už existuje). Token vytvoří anonymní relace, uplatní ověřená.
create or replace function public.create_claim_token()
returns text language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public._require_user(); t text;
begin
  if public.is_verified_user() then return null; end if;
  delete from public.claim_tokens where anon_uid = uid or created_at < now() - interval '2 days';
  t := encode(gen_random_bytes(24), 'hex');
  insert into public.claim_tokens (token, anon_uid) values (t, uid);
  return t;
end $$;

create or replace function public.claim_contributions(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._require_user(); anon uuid; n integer;
begin
  if not public.is_verified_user() then raise exception 'verification_required' using errcode = 'P0001'; end if;
  delete from public.claim_tokens where token = p_token and created_at > now() - interval '2 days'
    returning anon_uid into anon;
  if anon is null or anon = uid then return jsonb_build_object('moved', 0); end if;
  -- anonymní účet nesmí být ověřený (ochrana proti převzetí cizích dat)
  if exists (select 1 from auth.users where id = anon and email is not null and email <> '') then
    return jsonb_build_object('moved', 0);
  end if;
  update public.reports set user_id = uid, author_key = uid where author_key = anon;
  get diagnostics n = row_count;
  update public.comments set user_id = uid, author_key = uid where author_key = anon;
  update public.photos set user_id = uid where user_id = anon;
  -- podpory: přenést, pokud nejde o vlastní podnět a nejsou duplicitní
  insert into public.supports (report_id, user_id, created_at)
    select s.report_id, uid, s.created_at from public.supports s
    join public.reports r on r.id = s.report_id
    where s.user_id = anon and r.author_key <> uid
  on conflict do nothing;
  delete from public.supports where user_id = anon;
  return jsonb_build_object('moved', n);
end $$;

-- Výmaz účtu (GDPR). Podněty zůstávají anonymizovány, hlasy a kontaktní údaje se smažou.
create or replace function public.delete_my_account()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := public._require_user();
begin
  update public.reports set author_name = 'Anonym', user_id = null where author_key = uid;
  update public.comments set author_name = 'Anonym', user_id = null where author_key = uid;
  delete from public.supports where user_id = uid;
  delete from public.flags where user_id = uid;
  delete from public.profiles where id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Oprávnění ke spouštění
-- ---------------------------------------------------------------------
revoke execute on function public._parse_geometry(jsonb, public.geom_kind),
  public._attach_photos(uuid, uuid, jsonb, uuid),
  public._upsert_profile(uuid, text, text, boolean) from public, anon, authenticated;

revoke execute on function public.create_report(jsonb), public.set_support(uuid, boolean),
  public.add_comment(uuid, text, text, jsonb), public.flag_content(uuid, uuid, uuid, text, text),
  public.update_my_profile(text, text, boolean), public.my_reports(), public.update_my_report(uuid, text, text, text),
  public.withdraw_my_report(uuid), public.create_claim_token(), public.claim_contributions(text),
  public.delete_my_account() from public, anon;

grant execute on function public.get_public_config() to anon, authenticated;
grant execute on function public.get_map_data() to anon, authenticated;
grant execute on function public.get_report(uuid) to anon, authenticated;
grant execute on function public.nearby_reports(jsonb, integer, double precision) to anon, authenticated;
grant execute on function public.reports_around(uuid, double precision) to anon, authenticated;
grant execute on function public.create_report(jsonb) to authenticated;
grant execute on function public.set_support(uuid, boolean) to authenticated;
grant execute on function public.add_comment(uuid, text, text, jsonb) to authenticated;
grant execute on function public.flag_content(uuid, uuid, uuid, text, text) to authenticated;
grant execute on function public.get_my_profile() to anon, authenticated;
grant execute on function public.update_my_profile(text, text, boolean) to authenticated;
grant execute on function public.my_reports() to authenticated;
grant execute on function public.update_my_report(uuid, text, text, text) to authenticated;
grant execute on function public.withdraw_my_report(uuid) to authenticated;
grant execute on function public.create_claim_token() to authenticated;
grant execute on function public.claim_contributions(text) to authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- >>> 20261120000500_admin_api.sql
-- =====================================================================
-- Administrátorské API – každá funkce ověřuje roli administrátora
-- =====================================================================

-- Seznam podnětů s filtry (včetně skrytých, sloučených a ukázkových)
create or replace function public.admin_list_reports(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  res jsonb;
  q text := nullif(btrim(coalesce(p->>'q', '')), '');
begin
  perform public._require_admin();
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into res from (
    select jsonb_build_object(
      'id', r.id, 'no', r.public_no, 'title', r.title, 'author_name', r.author_name,
      'description', r.description, 'solution', r.solution, 'status_note', r.status_note,
      'category_id', r.category_id, 'subcategory_id', r.subcategory_id, 'custom_topic', r.custom_topic,
      'kind', r.geom_kind, 'status', r.status, 'status_public', r.status_public,
      'is_hidden', r.is_hidden, 'hidden_reason', r.hidden_reason, 'is_demo', r.is_demo,
      'merged_into', r.merged_into, 'variant_of', r.variant_of, 'source', r.source,
      'district_id', r.district_id, 'created_at', r.created_at,
      'people', coalesce(pp.people, 1), 'supporters', coalesce(pp.supporters, 0),
      'overlap_people', coalesce(m.overlap_people, 0), 'agreement', round(m.agreement::numeric, 2),
      'open_flags', (select count(*) from public.flags f where f.report_id = r.id and f.resolved_at is null),
      'photos', (select count(*) from public.photos ph where ph.report_id = r.id),
      'comments', (select count(*) from public.comments c where c.report_id = r.id),
      'contact_email', case when coalesce((p->>'with_contacts')::boolean, false)
                            then coalesce(pr.contact_email, (select email from auth.users u where u.id = r.user_id)) end,
      'admin_note', r.admin_note,
      'geometry', case when coalesce((p->>'with_geometry')::boolean, false) then ST_AsGeoJSON(r.geom, 6)::jsonb end
    ) x
    from public.reports r
    left join public.v_report_people pp on pp.report_id = coalesce(r.merged_into, r.id)
    left join public.report_metrics m on m.report_id = r.id
    left join public.profiles pr on pr.id = r.user_id
    where (p->>'category_id' is null or r.category_id = (p->>'category_id')::int)
      and (p->>'district_id' is null or r.district_id = (p->>'district_id')::int)
      and (p->>'status' is null or r.status = (p->>'status')::public.report_status)
      and (p->>'kind' is null or r.geom_kind = (p->>'kind')::public.geom_kind)
      and (coalesce(p->>'visibility', 'all') = 'all'
           or (p->>'visibility' = 'visible' and not r.is_hidden and r.merged_into is null)
           or (p->>'visibility' = 'hidden' and r.is_hidden)
           or (p->>'visibility' = 'merged' and r.merged_into is not null)
           or (p->>'visibility' = 'flagged' and exists (select 1 from public.flags f where f.report_id = r.id and f.resolved_at is null)))
      and (coalesce(p->>'demo', 'all') = 'all' or (p->>'demo' = 'real' and not r.is_demo) or (p->>'demo' = 'demo' and r.is_demo))
      and (q is null or r.title ilike '%' || q || '%' or r.description ilike '%' || q || '%'
           or r.author_name ilike '%' || q || '%' or r.public_no::text = q)
    limit least(coalesce((p->>'limit')::int, 2000), 10000)
  ) s;
  return res;
end $$;

-- Úprava podnětu administrátorem (původní stav se ukládá do audit_log)
create or replace function public.admin_update_report(p_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  admin uuid := public._require_admin();
  old public.reports;
  new_row public.reports;
begin
  select * into old from public.reports where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;

  update public.reports set
    title          = case when p ? 'title' then coalesce(public._clean(p->>'title', 140), title) else title end,
    description    = case when p ? 'description' then public._clean(p->>'description', 3000) else description end,
    solution       = case when p ? 'solution' then public._clean(p->>'solution', 3000) else solution end,
    category_id    = case when p ? 'category_id' then (p->>'category_id')::int else category_id end,
    subcategory_id = case when p ? 'subcategory_id' then nullif(p->>'subcategory_id', '')::int else subcategory_id end,
    custom_topic   = case when p ? 'custom_topic' then public._clean(p->>'custom_topic', 120) else custom_topic end,
    status         = case when p ? 'status' then (p->>'status')::public.report_status else status end,
    status_public  = case when p ? 'status_public' then (p->>'status_public')::boolean else status_public end,
    status_note    = case when p ? 'status_note' then public._clean(p->>'status_note', 1000) else status_note end,
    is_hidden      = case when p ? 'is_hidden' then (p->>'is_hidden')::boolean else is_hidden end,
    hidden_reason  = case when p ? 'hidden_reason' then public._clean(p->>'hidden_reason', 300) else hidden_reason end,
    admin_note     = case when p ? 'admin_note' then public._clean(p->>'admin_note', 3000) else admin_note end
  where id = p_id returning * into new_row;

  insert into public.audit_log (actor, action, target_type, target_id, old_data, new_data)
  values (admin, 'update', 'report', p_id::text, to_jsonb(old) - 'geom', p);
  return jsonb_build_object('ok', true, 'id', new_row.id);
end $$;

-- Sloučení duplicit: zdrojové podněty zůstávají v databázi (merged_into),
-- jejich autoři a podporovatelé se započítávají k cílovému podnětu (unikátně).
create or replace function public.admin_merge_reports(p_target uuid, p_sources uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); n integer;
begin
  if p_target = any(p_sources) then raise exception 'merge_into_self' using errcode = 'P0001'; end if;
  if exists (select 1 from public.reports where id = p_target and merged_into is not null) then
    raise exception 'target_is_merged' using errcode = 'P0001';
  end if;
  -- podněty, které byly sloučené do zdrojů, převést rovnou do cíle (jen jedna úroveň)
  update public.reports set merged_into = p_target where merged_into = any(p_sources);
  update public.reports set merged_into = p_target where id = any(p_sources);
  get diagnostics n = row_count;
  insert into public.audit_log (actor, action, target_type, target_id, new_data)
  values (admin, 'merge', 'report', p_target::text, jsonb_build_object('sources', p_sources));
  return jsonb_build_object('merged', n);
end $$;

create or replace function public.admin_unmerge_report(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  update public.reports set merged_into = null where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id) values (admin, 'unmerge', 'report', p_id::text);
  return jsonb_build_object('ok', true);
end $$;

-- Trvalé smazání (jen pro zjevný spam / testovací data)
create or replace function public.admin_delete_report(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); old public.reports; paths text[];
begin
  select * into old from public.reports where id = p_id;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  select array_agg(path) into paths from public.photos where report_id = p_id;
  update public.reports set merged_into = null where merged_into = p_id;
  update public.reports set variant_of = null where variant_of = p_id;
  delete from public.reports where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id, old_data)
  values (admin, 'delete', 'report', p_id::text, to_jsonb(old) - 'geom' || jsonb_build_object('wkt', extensions.ST_AsText(old.geom)));
  return jsonb_build_object('ok', true, 'photo_paths', coalesce(to_jsonb(paths), '[]'::jsonb));
end $$;

-- Moderace komentářů a fotografií
create or replace function public.admin_set_comment_hidden(p_id uuid, p_hidden boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  update public.comments set is_hidden = p_hidden where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id, new_data)
  values (admin, 'comment_hidden', 'comment', p_id::text, jsonb_build_object('hidden', p_hidden));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_photo_hidden(p_id uuid, p_hidden boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  update public.photos set is_hidden = p_hidden where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id, new_data)
  values (admin, 'photo_hidden', 'photo', p_id::text, jsonb_build_object('hidden', p_hidden));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_delete_photo(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); v_path text;
begin
  delete from public.photos where id = p_id returning path into v_path;
  insert into public.audit_log (actor, action, target_type, target_id, old_data)
  values (admin, 'photo_delete', 'photo', p_id::text, jsonb_build_object('path', v_path));
  return jsonb_build_object('ok', true, 'path', v_path);
end $$;

-- Fronta moderace: otevřená nahlášení + nejnovější komentáře a fotografie
create or replace function public.admin_moderation_queue()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return jsonb_build_object(
    'flags', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'reason', f.reason, 'note', f.note, 'created_at', f.created_at,
        'report_id', coalesce(f.report_id, c.report_id, ph.report_id),
        'report_title', (select title from public.reports where id = coalesce(f.report_id, c.report_id, ph.report_id)),
        'comment_id', f.comment_id, 'comment_body', c.body, 'comment_hidden', c.is_hidden,
        'photo_id', f.photo_id, 'photo_path', ph.path, 'photo_hidden', ph.is_hidden)
        order by f.created_at desc)
      from public.flags f left join public.comments c on c.id = f.comment_id left join public.photos ph on ph.id = f.photo_id
      where f.resolved_at is null), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
        select jsonb_build_object('id', c.id, 'report_id', c.report_id, 'author_name', c.author_name, 'body', c.body,
          'is_hidden', c.is_hidden, 'created_at', c.created_at,
          'report_title', (select title from public.reports where id = c.report_id)) x
        from public.comments c order by c.created_at desc limit 200) q), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
        select jsonb_build_object('id', ph.id, 'report_id', ph.report_id, 'comment_id', ph.comment_id, 'path', ph.path,
          'is_hidden', ph.is_hidden, 'created_at', ph.created_at,
          'report_title', (select title from public.reports where id = ph.report_id)) x
        from public.photos ph order by ph.created_at desc limit 300) q), '[]'::jsonb)
  );
end $$;

create or replace function public.admin_resolve_flag(p_id uuid, p_resolution text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  update public.flags set resolved_at = now(), resolved_by = admin, resolution = public._clean(p_resolution, 300) where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Blokace uživatele (spam) podle podnětu
create or replace function public.admin_block_author(p_report uuid, p_blocked boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); v_user uuid;
begin
  select user_id into v_user from public.reports where id = p_report;
  if v_user is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  update public.profiles set is_blocked = p_blocked where id = v_user and not is_admin;
  insert into public.audit_log (actor, action, target_type, target_id, new_data)
  values (admin, 'block_user', 'user', v_user::text, jsonb_build_object('blocked', p_blocked));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Kategorie a podkategorie
-- ---------------------------------------------------------------------
create or replace function public.admin_save_category(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); v_id integer := nullif(p->>'id', '')::int;
begin
  if v_id is null then
    insert into public.categories (code, name, description, color, icon, default_geom, sort_order, is_active, allow_custom_topic, theme, source)
    values (nullif(p->>'code', ''), p->>'name', p->>'description', coalesce(p->>'color', '#2563eb'), coalesce(p->>'icon', 'map-pin'),
            coalesce((p->>'default_geom')::public.geom_kind, 'point'),
            coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 10 from public.categories)),
            coalesce((p->>'is_active')::boolean, true), coalesce((p->>'allow_custom_topic')::boolean, false),
            coalesce(p->>'theme', 'mobilita'), coalesce(p->>'source', 'app'))
    returning id into v_id;
  else
    update public.categories set
      code = case when p ? 'code' then nullif(p->>'code', '') else code end,
      name = coalesce(p->>'name', name),
      description = case when p ? 'description' then p->>'description' else description end,
      color = coalesce(p->>'color', color),
      icon = coalesce(p->>'icon', icon),
      default_geom = coalesce((p->>'default_geom')::public.geom_kind, default_geom),
      sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active),
      allow_custom_topic = coalesce((p->>'allow_custom_topic')::boolean, allow_custom_topic),
      theme = coalesce(p->>'theme', theme)
    where id = v_id;
  end if;
  insert into public.audit_log (actor, action, target_type, target_id, new_data) values (admin, 'save', 'category', v_id::text, p);
  return jsonb_build_object('id', v_id);
end $$;

-- Odebrání kategorie: pokud ji používají podněty, pouze se deaktivuje
create or replace function public.admin_delete_category(p_id integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  if exists (select 1 from public.reports where category_id = p_id) then
    update public.categories set is_active = false where id = p_id;
    return jsonb_build_object('deactivated', true);
  end if;
  delete from public.categories where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id) values (admin, 'delete', 'category', p_id::text);
  return jsonb_build_object('deleted', true);
end $$;

create or replace function public.admin_reorder_categories(p_ids integer[])
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  update public.categories c set sort_order = x.ord * 10
  from unnest(p_ids) with ordinality as x(id, ord) where c.id = x.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_save_subcategory(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); v_id integer := nullif(p->>'id', '')::int;
begin
  if v_id is null then
    insert into public.subcategories (category_id, name, default_geom, sort_order, is_active)
    values ((p->>'category_id')::int, p->>'name', nullif(p->>'default_geom', '')::public.geom_kind,
            coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 10 from public.subcategories where category_id = (p->>'category_id')::int)),
            coalesce((p->>'is_active')::boolean, true))
    returning id into v_id;
  else
    update public.subcategories set
      category_id = coalesce((p->>'category_id')::int, category_id),
      name = coalesce(p->>'name', name),
      default_geom = case when p ? 'default_geom' then nullif(p->>'default_geom', '')::public.geom_kind else default_geom end,
      sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active)
    where id = v_id;
  end if;
  insert into public.audit_log (actor, action, target_type, target_id, new_data) values (admin, 'save', 'subcategory', v_id::text, p);
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.admin_delete_subcategory(p_id integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  if exists (select 1 from public.reports where subcategory_id = p_id) then
    update public.subcategories set is_active = false where id = p_id;
    return jsonb_build_object('deactivated', true);
  end if;
  delete from public.subcategories where id = p_id;
  return jsonb_build_object('deleted', true);
end $$;

create or replace function public.admin_list_categories()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name, 'description', c.description, 'color', c.color, 'icon', c.icon,
      'default_geom', c.default_geom, 'sort_order', c.sort_order, 'is_active', c.is_active,
      'allow_custom_topic', c.allow_custom_topic, 'theme', c.theme, 'source', c.source,
      'reports', (select count(*) from public.reports r where r.category_id = c.id),
      'subcategories', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'default_geom', s.default_geom,
          'sort_order', s.sort_order, 'is_active', s.is_active,
          'reports', (select count(*) from public.reports r where r.subcategory_id = s.id)) order by s.sort_order, s.id)
        from public.subcategories s where s.category_id = c.id), '[]'::jsonb))
    order by c.sort_order, c.id) from public.categories c), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- Nastavení
-- ---------------------------------------------------------------------
create or replace function public.admin_get_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('key', key, 'value', value, 'is_public', is_public, 'description', description) order by key)
    from public.app_settings), '[]'::jsonb);
end $$;

create or replace function public.admin_set_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin();
begin
  update public.app_settings set value = p_value, updated_at = now() where key = p_key;
  if not found then raise exception 'unknown_setting' using errcode = 'P0001'; end if;
  insert into public.audit_log (actor, action, target_type, target_id, new_data) values (admin, 'setting', 'setting', p_key, p_value);
  -- změna tolerancí → přepočítat metriky shody
  if p_key in ('line_tolerance_m', 'point_tolerance_m', 'polygon_tolerance_m', 'show_demo') then
    refresh materialized view public.report_metrics;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Správa administrátorů
create or replace function public.admin_list_admins()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return jsonb_build_object(
    'invited', coalesce((select jsonb_agg(email order by email) from public.admin_emails), '[]'::jsonb),
    'active', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'email', u.email, 'nickname', p.nickname))
       from public.profiles p join auth.users u on u.id = p.id where p.is_admin), '[]'::jsonb));
end $$;

create or replace function public.admin_add_admin(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); e text := lower(btrim(p_email));
begin
  insert into public.admin_emails(email) values (e) on conflict do nothing;
  update public.profiles p set is_admin = true from auth.users u where u.id = p.id and lower(u.email) = e;
  insert into public.audit_log (actor, action, target_type, target_id) values (admin, 'add_admin', 'user', e);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_remove_admin(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); e text := lower(btrim(p_email));
begin
  if (select count(*) from public.profiles where is_admin) <= 1
     and exists (select 1 from public.profiles p join auth.users u on u.id = p.id where p.is_admin and lower(u.email) = e) then
    raise exception 'last_admin' using errcode = 'P0001';
  end if;
  delete from public.admin_emails where email = e;
  update public.profiles p set is_admin = false from auth.users u where u.id = p.id and lower(u.email) = e;
  insert into public.audit_log (actor, action, target_type, target_id) values (admin, 'remove_admin', 'user', e);
  return jsonb_build_object('ok', true);
end $$;

-- Seznam odběratelů novinek (pouze s výslovným souhlasem)
create or replace function public.admin_newsletter_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'email', coalesce(p.contact_email, u.email), 'nickname', p.nickname, 'consent_at', p.newsletter_at) order by p.newsletter_at)
    from public.profiles p left join auth.users u on u.id = p.id
    where p.newsletter and coalesce(p.contact_email, u.email) is not null), '[]'::jsonb);
end $$;

create or replace function public.admin_audit_log(p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select jsonb_agg(x) from (select jsonb_build_object('id', a.id, 'action', a.action, 'target_type', a.target_type,
      'target_id', a.target_id, 'created_at', a.created_at, 'new_data', a.new_data,
      'actor', (select email from auth.users where id = a.actor)) x
    from public.audit_log a order by a.id desc limit least(p_limit, 2000)) q), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- Statistiky (celé Ivančice nebo jedna místní část)
-- ---------------------------------------------------------------------
create or replace function public.admin_stats(p_district integer default null, p_include_demo boolean default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  demo boolean := coalesce(p_include_demo, public.setting_bool('show_demo', false));
  res jsonb;
begin
  perform public._require_admin();
  with r as (
    select x.* from public.reports x
    where not x.is_hidden and x.merged_into is null and (demo or not x.is_demo)
      and (p_district is null or x.district_id = p_district)
  ),
  mem as (select m.* from public.v_report_members m join r on r.id = m.gid),
  pp as (select v.* from public.v_report_people v join r on r.id = v.report_id),
  comm as (select c.* from public.comments c join r on r.id = c.report_id where not c.is_hidden)
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'reports', (select count(*) from r),
      'points', (select count(*) from r where geom_kind = 'point'),
      'lines', (select count(*) from r where geom_kind = 'line'),
      'polygons', (select count(*) from r where geom_kind = 'polygon'),
      'people', (select count(distinct person) from (select person from mem union select author_key from comm) z),
      'authors', (select count(distinct author_key) from r),
      'supporters', (select count(distinct person) from mem where not is_author),
      'supports', (select count(*) from mem where not is_author),
      'comments', (select count(*) from comm),
      'photos', (select count(*) from public.photos ph join r on r.id = ph.report_id where not ph.is_hidden),
      'variants', (select count(*) from r where variant_of is not null),
      'merged', (select count(*) from public.reports x where x.merged_into is not null and (demo or not x.is_demo)),
      'hidden', (select count(*) from public.reports x where x.is_hidden and (demo or not x.is_demo)),
      'open_flags', (select count(*) from public.flags where resolved_at is null),
      'line_km', round(coalesce((select sum(length_m) from r), 0)::numeric / 1000, 2),
      'polygon_ha', round(coalesce((select sum(area_m2) from r), 0)::numeric / 10000, 2),
      'newsletter', (select count(*) from public.profiles where newsletter),
      'with_overlap', (select count(*) from r join public.report_metrics m on m.report_id = r.id where m.overlap_people > 0)
    ),
    'by_category', coalesce((select jsonb_agg(jsonb_build_object(
        'category_id', c.id, 'name', c.name, 'color', c.color,
        'reports', (select count(*) from r where r.category_id = c.id),
        'people', (select count(distinct m.person) from mem m join r on r.id = m.gid where r.category_id = c.id),
        'supporters', (select count(distinct m.person) from mem m join r on r.id = m.gid where r.category_id = c.id and not m.is_author),
        'subcategories', coalesce((select jsonb_agg(jsonb_build_object('name', s.name, 'reports', n) order by n desc) from (
            select s.name, count(*) n from r join public.subcategories s on s.id = r.subcategory_id
            where r.category_id = c.id group by s.name) s), '[]'::jsonb)
      ) order by c.sort_order) from public.categories c), '[]'::jsonb),
    'by_kind', (select jsonb_object_agg(k, n) from (select geom_kind::text k, count(*) n from r group by geom_kind) z),
    'by_status', (select jsonb_object_agg(k, n) from (select status::text k, count(*) n from r group by status) z),
    'by_frequency', (select jsonb_object_agg(coalesce(k, 'unknown'), n) from (select frequency::text k, count(*) n from r group by frequency) z),
    'by_district', coalesce((select jsonb_agg(jsonb_build_object('district_id', d.id, 'name', d.name,
        'reports', (select count(*) from public.reports x where x.district_id = d.id and not x.is_hidden and x.merged_into is null and (demo or not x.is_demo)),
        'people', (select count(distinct m.person) from public.v_report_members m join public.reports x on x.id = m.gid
                   where x.district_id = d.id and not x.is_hidden and x.merged_into is null and (demo or not x.is_demo))
      ) order by d.sort_order) from public.districts d), '[]'::jsonb),
    'top_supported', coalesce((select jsonb_agg(z) from (
        select jsonb_build_object('id', r.id, 'no', r.public_no, 'title', r.title, 'category_id', r.category_id,
          'kind', r.geom_kind, 'people', pp.people, 'supporters', pp.supporters) z
        from r join pp on pp.report_id = r.id order by pp.people desc, r.created_at limit 15) q), '[]'::jsonb),
    'top_agreement', coalesce((select jsonb_agg(z) from (
        select jsonb_build_object('id', r.id, 'no', r.public_no, 'title', r.title, 'category_id', r.category_id,
          'kind', r.geom_kind, 'overlap_people', m.overlap_people, 'agreement', round(m.agreement::numeric, 2)) z
        from r join public.report_metrics m on m.report_id = r.id where m.overlap_people > 0
        order by m.overlap_people desc, m.agreement desc nulls last limit 15) q), '[]'::jsonb),
    'agreement_summary', coalesce((select jsonb_agg(jsonb_build_object('kind', k, 'reports', n, 'with_overlap', o, 'avg_agreement', a)) from (
        select r.geom_kind::text k, count(*) n, count(*) filter (where m.overlap_people > 0) o,
               round(avg(m.agreement)::numeric, 2) a
        from r left join public.report_metrics m on m.report_id = r.id group by r.geom_kind) z), '[]'::jsonb),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('week', w, 'reports', n, 'supports', s) order by w) from (
        select to_char(date_trunc('week', d), 'YYYY-MM-DD') w, sum(nr)::int n, sum(ns)::int s from (
          select created_at d, 1 nr, 0 ns from r
          union all
          select s.created_at, 0, 1 from public.supports s join public.reports x on x.id = s.report_id
            join r on r.id = coalesce(x.merged_into, x.id)
        ) t group by 1) z), '[]'::jsonb)
  ) into res;

  -- Nejčastěji označovaná místa: shluky bodů a nejsilnější překryvy ploch
  res := res || jsonb_build_object(
    'hotspots', coalesce((select jsonb_agg(f order by (f->'properties'->>'people')::int desc) from (
        select f from jsonb_array_elements(public.analysis_point_clusters(null)->'features') f
        where (f->'properties'->>'reports')::int >= 2
        limit 15) q), '[]'::jsonb)
  );
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------
create or replace function public.admin_export_reports(p_include_hidden boolean default false,
  p_include_demo boolean default false, p_srid integer default 4326)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._require_admin();
  if p_srid not in (4326, 5514, 32633, 3857) then raise exception 'unsupported_srid' using errcode = 'P0001'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'type', 'Feature',
    'geometry', ST_AsGeoJSON(case when p_srid = 4326 then r.geom else ST_Transform(r.geom, p_srid) end,
                             case when p_srid = 4326 then 7 else 2 end)::jsonb,
    'properties', jsonb_build_object(
      'id', r.id::text, 'cislo', r.public_no, 'typ_geom', r.geom_kind,
      'kat_id', r.category_id, 'kategorie', c.name, 'podkat_id', r.subcategory_id, 'podkat', s.name,
      'vl_tema', r.custom_topic, 'nazev', r.title, 'popis', r.description, 'reseni', r.solution,
      'cetnost', r.frequency, 'autor', r.author_name,
      'vlozeno', to_char(r.created_at at time zone 'Europe/Prague', 'YYYY-MM-DD"T"HH24:MI:SS'),
      'cast_obce', d.name, 'stav', r.status, 'stav_verej', r.status_public,
      'n_autoru', coalesce(pp.authors, 1),
      'n_podpor', coalesce(pp.supporters, 0),
      'n_lidi', coalesce(pp.people, 1),
      'shoda_lidi', coalesce(m.overlap_people, 0),
      'shoda_pod', round(m.agreement::numeric, 3),
      'delka_m', round(r.length_m::numeric, 1), 'plocha_m2', round(r.area_m2::numeric, 1),
      'varianta_k', r.variant_of::text, 'slouceno', r.merged_into::text,
      'skryto', r.is_hidden, 'ukazka', r.is_demo, 'zdroj', r.source,
      'n_fotek', (select count(*) from public.photos ph where ph.report_id = r.id and not ph.is_hidden),
      'n_koment', (select count(*) from public.comments cm where cm.report_id = r.id and not cm.is_hidden)
    )) order by r.public_no)
    from public.reports r
    join public.categories c on c.id = r.category_id
    left join public.subcategories s on s.id = r.subcategory_id
    left join public.districts d on d.id = r.district_id
    left join public.v_report_people pp on pp.report_id = coalesce(r.merged_into, r.id)
    left join public.report_metrics m on m.report_id = r.id
    where (p_include_hidden or not r.is_hidden) and (p_include_demo or not r.is_demo)), '[]'::jsonb);
end $$;

-- Převod GeoJSON FeatureCollection (analytické vrstvy) do jiného S-JTSK apod.
create or replace function public.admin_transform_fc(p_fc jsonb, p_srid integer)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._require_admin();
  if p_srid = 4326 then return p_fc; end if;
  if p_srid not in (5514, 32633, 3857) then raise exception 'unsupported_srid' using errcode = 'P0001'; end if;
  return jsonb_set(p_fc, '{features}', coalesce((select jsonb_agg(
      jsonb_set(f, '{geometry}', ST_AsGeoJSON(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON((f->'geometry')::text), 4326), p_srid), 2)::jsonb))
    from jsonb_array_elements(p_fc->'features') f), '[]'::jsonb));
end $$;

create or replace function public.admin_srid_wkt(p_srid integer)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._require_admin();
  return (select srtext from extensions.spatial_ref_sys where srid = p_srid);
end $$;

-- ---------------------------------------------------------------------
-- Místní části: import hranic (GeoJSON FeatureCollection s vlastností name)
-- ---------------------------------------------------------------------
create or replace function public.admin_import_district_boundaries(p_fc jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare admin uuid := public._require_admin(); f jsonb; n integer := 0; v_name text; g extensions.geometry;
begin
  for f in select * from jsonb_array_elements(p_fc->'features') loop
    v_name := coalesce(f->'properties'->>'name', f->'properties'->>'nazev', f->'properties'->>'NAZEV');
    continue when v_name is null;
    g := ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON((f->'geometry')::text), 4326)), 3));
    insert into public.districts (name, center, boundary, sort_order)
    values (v_name, ST_PointOnSurface(g), g, (select coalesce(max(sort_order), 0) + 1 from public.districts))
    on conflict (name) do update set boundary = excluded.boundary;
    n := n + 1;
  end loop;
  update public.reports set district_id = public._district_for(geom);
  insert into public.audit_log (actor, action, target_type, new_data) values (admin, 'import_districts', 'district', jsonb_build_object('count', n));
  return jsonb_build_object('imported', n);
end $$;

-- ---------------------------------------------------------------------
-- Import podnětů a kategorií z GeoJSON (např. export původní mapy MapHub)
-- ---------------------------------------------------------------------
create or replace function public.admin_import_geojson(p_fc jsonb, p_options jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  admin uuid := public._require_admin();
  f jsonb; props jsonb;
  v_cat_name text; v_cat_id integer; v_kind public.geom_kind; g extensions.geometry;
  v_title text; n integer := 0; skipped integer := 0; cats integer := 0;
  v_author uuid := coalesce(nullif(p_options->>'author_key', '')::uuid, gen_random_uuid());
  v_author_name text := coalesce(nullif(p_options->>'author_name', ''), 'Původní mapa (MapHub)');
  v_source text := coalesce(nullif(p_options->>'source', ''), 'maphub');
  v_default_cat integer := nullif(p_options->>'default_category_id', '')::int;
  v_only_categories boolean := coalesce((p_options->>'only_categories')::boolean, false);
  v_color text;
  -- MapHub export obsahuje seznam skupin (id → název, barva) na nejvyšší úrovni
  group_map jsonb := coalesce(p_options->'group_names',
    (select jsonb_object_agg(grp->>'id', coalesce(grp->>'title', grp->>'name')) from jsonb_array_elements(
       case when jsonb_typeof(p_fc->'groups') = 'array' then p_fc->'groups' else '[]'::jsonb end) grp
     where grp ? 'id'), '{}'::jsonb);
  group_colors jsonb := coalesce(
    (select jsonb_object_agg(coalesce(grp->>'title', grp->>'name'), grp->>'color') from jsonb_array_elements(
       case when jsonb_typeof(p_fc->'groups') = 'array' then p_fc->'groups' else '[]'::jsonb end) grp
     where (grp->>'color') ~ '^#[0-9a-fA-F]{6}$'), '{}'::jsonb);
begin
  perform set_config('app.skip_metrics', 'on', true);
  for f in select * from jsonb_array_elements(p_fc->'features') loop
    props := coalesce(f->'properties', '{}'::jsonb);
    v_cat_name := coalesce(props->>'category', props->>'kategorie', props->>'group_title', props->>'layer',
                           group_map->>(props->>'group'), props->>'group');
    v_cat_id := null;
    if v_cat_name is not null and btrim(v_cat_name) <> '' then
      select id into v_cat_id from public.categories where lower(name) = lower(btrim(v_cat_name)) limit 1;
      if v_cat_id is null then
        v_color := coalesce(case when (group_colors->>btrim(v_cat_name)) ~ '^#[0-9a-fA-F]{6}$' then group_colors->>btrim(v_cat_name) end,
                            case when (props->>'marker-color') ~ '^#[0-9a-fA-F]{6}$' then props->>'marker-color' end,
                            case when (props->>'stroke') ~ '^#[0-9a-fA-F]{6}$' then props->>'stroke' end, '#475569');
        insert into public.categories (name, color, icon, default_geom, sort_order, source)
        values (left(btrim(v_cat_name), 120), v_color, 'map-pin', 'point',
                (select coalesce(max(sort_order), 0) + 10 from public.categories), v_source)
        returning id into v_cat_id;
        cats := cats + 1;
      end if;
    end if;
    continue when v_only_categories;
    v_cat_id := coalesce(v_cat_id, v_default_cat);
    if v_cat_id is null or f->'geometry' is null or jsonb_typeof(f->'geometry') = 'null' then
      skipped := skipped + 1; continue;
    end if;
    begin
      g := ST_Force2D(ST_SetSRID(ST_GeomFromGeoJSON((f->'geometry')::text), 4326));
      v_kind := case when GeometryType(g) like '%POLYGON' then 'polygon'
                     when GeometryType(g) like '%LINESTRING' then 'line' else 'point' end;
      if v_kind = 'polygon' then g := ST_CollectionExtract(ST_MakeValid(g), 3); end if;
      if v_kind = 'point' and GeometryType(g) = 'MULTIPOINT' then g := ST_GeometryN(g, 1); end if;
      v_title := coalesce(public._clean(props->>'title', 140), public._clean(props->>'name', 140), public._clean(props->>'nazev', 140), 'Podnět z původní mapy');
      if char_length(v_title) < 3 then v_title := 'Podnět: ' || v_title; end if;
      insert into public.reports (user_id, author_key, author_name, category_id, title, description, geom, geom_kind, source, created_at)
      values (null, v_author, v_author_name, v_cat_id, v_title,
              public._clean(concat_ws(E'\n\n', coalesce(props->>'description', props->>'popis'),
                case when coalesce(props->>'image_url', props->>'image', props->>'photo') ~ '^https?://'
                     then 'Fotografie z původní mapy: ' || coalesce(props->>'image_url', props->>'image', props->>'photo') end), 3000),
              g, v_kind, v_source,
              coalesce(nullif(props->>'created_at', '')::timestamptz, now()));
      n := n + 1;
    exception when others then
      skipped := skipped + 1;
    end;
  end loop;
  perform set_config('app.skip_metrics', 'off', true);
  refresh materialized view public.report_metrics;
  insert into public.audit_log (actor, action, target_type, new_data)
  values (admin, 'import_geojson', 'report', jsonb_build_object('imported', n, 'skipped', skipped, 'categories', cats));
  return jsonb_build_object('imported', n, 'skipped', skipped, 'categories_created', cats);
end $$;

-- ---------------------------------------------------------------------
-- Testovací prostředí: ukázková data (is_demo = true) a jejich výmaz
-- ---------------------------------------------------------------------
create or replace function public.admin_seed_demo(p_count integer default 60)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  admin uuid := public._require_admin();
  people uuid[] := array(select gen_random_uuid() from generate_series(1, 40));
  names text[] := array['Jana (ukázka)', 'Petr (ukázka)', 'Lucie (ukázka)', 'Tomáš (ukázka)', 'Eva (ukázka)',
                        'Martin (ukázka)', 'Klára (ukázka)', 'Ondřej (ukázka)', 'Hana (ukázka)', 'Jakub (ukázka)'];
  -- ohniska v zastavěném území (lon, lat)
  spots double precision[][] := array[
    [16.3775, 49.1014], [16.3810, 49.1028], [16.3735, 49.0995], [16.3842, 49.0987], [16.3700, 49.1040],
    [16.3689, 49.0928], [16.3567, 49.0958], [16.3600, 49.0895], [16.3485, 49.0722], [16.3206, 49.0847],
    [16.3045, 49.0905], [16.3900, 49.1050]];
  i integer; k integer; spot integer; cat record; sub integer; kind public.geom_kind;
  lon double precision; lat double precision; g extensions.geometry; v_id uuid; author integer;
  n_sup integer; titles text[];
begin
  perform set_config('app.skip_metrics', 'on', true);
  for i in 1..p_count loop
    select c.* into cat from public.categories c where c.is_active order by random() limit 1;
    select s.id into sub from public.subcategories s where s.category_id = cat.id and s.is_active order by random() limit 1;
    kind := case when random() < 0.55 then cat.default_geom
                 else (array['point', 'line', 'polygon']::public.geom_kind[])[1 + floor(random() * 3)::int] end;
    spot := 1 + floor(random() * array_length(spots, 1))::int;
    lon := spots[spot][1] + (random() - 0.5) * 0.004;
    lat := spots[spot][2] + (random() - 0.5) * 0.0025;
    if kind = 'point' then
      g := ST_SetSRID(ST_MakePoint(lon, lat), 4326);
    elsif kind = 'line' then
      g := ST_SetSRID(ST_MakeLine(array[
        ST_MakePoint(lon, lat),
        ST_MakePoint(lon + (random() - 0.3) * 0.003, lat + (random() - 0.5) * 0.002),
        ST_MakePoint(lon + (random() - 0.2) * 0.006, lat + (random() - 0.5) * 0.003)]), 4326);
    else
      g := ST_SetSRID(ST_Buffer(ST_MakePoint(lon, lat), 0.0006 + random() * 0.0012, 'quad_segs=2'), 4326);
    end if;
    author := 1 + floor(random() * 40)::int;
    insert into public.reports (user_id, author_key, author_name, category_id, subcategory_id, title, description,
                                solution, frequency, geom, geom_kind, is_demo, source, created_at)
    values (null, people[author], names[1 + (author % 10)], cat.id, sub,
            coalesce((select name from public.subcategories where id = sub), cat.name) || ' – ukázkový podnět',
            'UKÁZKOVÁ DATA pro otestování aplikace. Nejde o skutečný příspěvek obyvatel.',
            case when random() < 0.5 then 'Ukázkový návrh řešení.' end,
            (array['daily', 'weekly', 'sometimes', 'rarely']::public.visit_frequency[])[1 + floor(random() * 4)::int],
            g, kind, true, 'demo', now() - (random() * interval '40 days'))
    returning id into v_id;
    n_sup := floor(power(random(), 2) * 25)::int;
    insert into public.supports (report_id, user_id, created_at)
      select v_id, people[1 + floor(random() * 40)::int], now() - (random() * interval '30 days')
      from generate_series(1, n_sup)
    on conflict do nothing;
    delete from public.supports where report_id = v_id and user_id = people[author];
  end loop;

  -- Několik záměrně překrývajících se ploch a linií (ověření analýz překryvu)
  select c.* into cat from public.categories c where c.is_active order by c.sort_order limit 1;
  for k in 1..5 loop
    insert into public.reports (user_id, author_key, author_name, category_id, title, description, geom, geom_kind, is_demo, source)
    values (null, people[k], names[k], cat.id, 'Problematické území u náměstí – ukázka ' || k,
            'UKÁZKOVÁ DATA: překrývající se plochy různých lidí.',
            ST_SetSRID(ST_Buffer(ST_MakePoint(16.3775 + k * 0.00025, 49.1014 + (k % 2) * 0.0002), 0.0012, 'quad_segs=3'), 4326),
            'polygon', true, 'demo');
    insert into public.reports (user_id, author_key, author_name, category_id, title, description, geom, geom_kind, is_demo, source)
    values (null, people[10 + k], names[1 + ((10 + k) % 10)], cat.id, 'Nebezpečná trasa do školy – ukázka ' || k,
            'UKÁZKOVÁ DATA: podobné trasy různých lidí.',
            ST_SetSRID(ST_MakeLine(array[
              ST_MakePoint(16.3720, 49.0990 + k * 0.00004), ST_MakePoint(16.3765, 49.1003 + k * 0.00003),
              ST_MakePoint(16.3810 + k * 0.0002, 49.1020 + k * 0.0001)]), 4326),
            'line', true, 'demo');
  end loop;

  update public.app_settings set value = 'true'::jsonb where key = 'show_demo';
  perform set_config('app.skip_metrics', 'off', true);
  refresh materialized view public.report_metrics;
  insert into public.audit_log (actor, action, target_type, new_data) values (admin, 'seed_demo', 'report', jsonb_build_object('count', p_count));
  return jsonb_build_object('created', (select count(*) from public.reports where is_demo));
end $$;

create or replace function public.admin_delete_demo()
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); n integer; paths text[];
begin
  select array_agg(ph.path) into paths from public.photos ph join public.reports r on r.id = ph.report_id where r.is_demo;
  update public.reports set variant_of = null where variant_of in (select id from public.reports where is_demo);
  update public.reports set merged_into = null where merged_into in (select id from public.reports where is_demo);
  delete from public.reports where is_demo;
  get diagnostics n = row_count;
  update public.app_settings set value = 'false'::jsonb where key = 'show_demo';
  insert into public.audit_log (actor, action, target_type, new_data) values (admin, 'delete_demo', 'report', jsonb_build_object('deleted', n));
  return jsonb_build_object('deleted', n, 'photo_paths', coalesce(to_jsonb(paths), '[]'::jsonb));
end $$;

-- Všechny administrátorské funkce: spustitelné přihlášenými (ověření role probíhá uvnitř)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'admin\_%' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- >>> 20261120000600_seed_config.sql
-- =====================================================================
-- Výchozí konfigurace: nastavení, kategorie, podkategorie, místní části
-- (bez smyšlených podnětů – ukázková data se vkládají jen na vyžádání
--  v administraci a jsou označena is_demo = true)
-- =====================================================================

insert into public.app_settings (key, value, is_public, description) values
  ('contributions_open',        'true',  true,  'Přijímají se nové podněty'),
  ('support_requires_verified', 'true',  true,  'Podpora podnětu vyžaduje přihlášení e-mailem (ověřená identita)'),
  ('contribute_requires_login', 'false', true,  'Přidávat podněty a komentáře mohou jen uživatelé přihlášení e-mailem (pak lze v Supabase vypnout anonymní přihlášení)'),
  ('show_demo',                 'false', true,  'Zobrazovat ukázková (testovací) data'),
  ('duplicate_radius_m',        '60',    true,  'Okruh hledání podobných podnětů před vložením (m)'),
  ('point_tolerance_m',         '40',    true,  'Tolerance shody bodů (m)'),
  ('line_tolerance_m',          '15',    true,  'Tolerance shody linií (m)'),
  ('line_angle_deg',            '35',    true,  'Max. rozdíl směru shodných linií (°)'),
  ('line_segment_m',            '25',    true,  'Délka úseku pro analýzu překryvu linií (m)'),
  ('polygon_tolerance_m',       '5',     true,  'Tolerance hranic ploch (m)'),
  ('hex_size_m',                '150',   true,  'Velikost buňky mapy intenzity (m)'),
  ('max_photos',                '5',     true,  'Max. počet fotografií u podnětu'),
  ('photos_enabled',            'true',  true,  'Umožnit přidávání fotografií (vypnutím se nové fotografie nepřijímají)'),
  ('operator_name',             '"(doplňte název spolku)"', true, 'Provozovatel mapy (zobrazí se v patičce a v informacích o projektu)'),
  ('operator_url',              '""',    true,  'Web provozovatele (nepovinné)'),
  ('rate_reports_anon',         '8',     false, 'Max. podnětů za hodinu – neověřený uživatel'),
  ('rate_reports_verified',     '30',    false, 'Max. podnětů za hodinu – ověřený uživatel'),
  ('rate_comments',             '20',    false, 'Max. komentářů za hodinu'),
  ('rate_supports',             '120',   false, 'Max. podpor za hodinu'),
  ('service_area',              '{"lon": 16.350, "lat": 49.090, "radius_km": 9}', true, 'Územní rozsah pro zakreslení'),
  ('map_center',                '[16.3705, 49.0985]', true, 'Výchozí střed mapy na mobilu [lon, lat]'),
  ('map_zoom',                  '13.2',  true,  'Výchozí přiblížení mapy na mobilu'),
  ('map_bounds',                '[[16.285, 49.060], [16.405, 49.115]]', true, 'Výchozí výřez mapy (Ivančice a místní části)'),
  ('intro_title',               '"Ivančice očima pěších a cyklistů"', true, 'Název aplikace'),
  ('intro_subtitle',            '"Společně mapujeme, jak se nám v Ivančicích chodí, jezdí na kole a žije."', true, 'Podtitulek'),
  ('intro_text',                '"Označte v mapě místa, kde se vám špatně chodí nebo jezdí na kole, navrhněte zlepšení a podpořte podněty ostatních. Výsledky poslouží při plánování dopravy a veřejných prostranství města."', true, 'Úvodní text'),
  ('privacy_controller',        '"(doplňte název spolku, sídlo a IČO)"', true, 'Správce osobních údajů (doplňte dle skutečnosti)'),
  ('privacy_contact',           '"(doplňte kontaktní e-mail)"', true, 'Kontakt pro dotazy k osobním údajům (doplňte)'),
  ('privacy_dpo',               '""',    true,  'Pověřenec pro ochranu osobních údajů (kontakt)'),
  ('retention_text',            '"Údaje uchováváme po dobu trvání projektu participativního mapování a následného vyhodnocení, nejdéle 5 let. Poté jsou osobní údaje smazány nebo anonymizovány."', true, 'Doba uchování údajů'),
  ('project_end',               '""',    true,  'Datum ukončení sběru podnětů (informativně)')
on conflict (key) do nothing;

-- Kategorie (dle zadání; původní kategorie z mapy MapHub lze doplnit
-- v administraci ručně nebo importem GeoJSON exportu z MapHub)
insert into public.categories (id, code, name, description, color, icon, default_geom, sort_order, allow_custom_topic) values
  (1, 'bezpecnost-pesich',   'Bezpečnost pěších',                   'Přechody, chodníky, nebezpečná místa pro chodce a děti', '#dc2626', 'footprints',   'point',   10, false),
  (2, 'cyklisticka-doprava', 'Cyklistická doprava',                 'Cyklopropojení, nebezpečné úseky, stojany na kola',      '#0891b2', 'bike',         'line',    20, false),
  (3, 'parkovani-auta',      'Parkování a automobilová doprava',    'Parkování, průjezd, rychlost, křižovatky',               '#ca8a04', 'car',          'point',   30, false),
  (4, 'bezbarierovost',      'Bezbariérovost',                      'Bariéry, obrubníky, povrchy, přístupnost zastávek',      '#7c3aed', 'accessibility','point',   40, false),
  (5, 'verejny-prostor',     'Veřejný prostor a zeleň',             'Stromy, stín, mobiliář, místa k odpočinku a revitalizaci','#16a34a', 'trees',        'polygon', 50, false),
  (6, 'prostupnost',         'Prostupnost a propojení města',       'Chybějící propojení, průchody, nové trasy',              '#ea580c', 'route',        'line',    60, false),
  (7, 'jine',                'Jiné / vlastní podnět',               'Téma, které není obsaženo v předchozích kategoriích',    '#64748b', 'message-circle','point',  70, true)
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.categories', 'id'), greatest((select max(id) from public.categories), 1));

insert into public.subcategories (category_id, name, default_geom, sort_order) values
  (1, 'Chybějící přechod', 'point', 10),
  (1, 'Nebezpečný přechod', 'point', 20),
  (1, 'Nebezpečné místo pro chodce', 'point', 30),
  (1, 'Chybějící chodník', 'line', 40),
  (1, 'Špatně osvětlené místo', 'point', 50),
  (1, 'Nebezpečné místo pro děti', 'point', 60),
  (2, 'Chybějící cyklopropojení', 'line', 10),
  (2, 'Nebezpečný úsek pro cyklisty', 'line', 20),
  (2, 'Chybějící cyklistická infrastruktura', 'line', 30),
  (2, 'Problematické napojení na cyklotrasu', 'point', 40),
  (2, 'Chybějící stojany na kola', 'point', 50),
  (2, 'Konflikt pěších a cyklistů', 'point', 60),
  (3, 'Nedostatek parkovacích míst', 'polygon', 10),
  (3, 'Nevhodně organizované parkování', 'polygon', 20),
  (3, 'Nelegální nebo nebezpečné parkování', 'point', 30),
  (3, 'Problematický průjezd', 'line', 40),
  (3, 'Nadměrná rychlost', 'line', 50),
  (3, 'Konfliktní křižovatka', 'point', 60),
  (4, 'Chybějící bezbariérový přístup', 'point', 10),
  (4, 'Vysoký obrubník', 'point', 20),
  (4, 'Nevhodný povrch', 'line', 30),
  (4, 'Nepřístupná zastávka', 'point', 40),
  (4, 'Bariéra v pěší trase', 'point', 50),
  (5, 'Chybějící stromy a stín', 'polygon', 10),
  (5, 'Nevhodné povrchy', 'polygon', 20),
  (5, 'Chybějící mobiliář', 'point', 30),
  (5, 'Nevhodné nebo nevyužité veřejné prostranství', 'polygon', 40),
  (5, 'Místo vhodné k revitalizaci', 'polygon', 50),
  (5, 'Nedostatek míst k odpočinku', 'point', 60),
  (6, 'Chybějící pěší propojení', 'line', 10),
  (6, 'Chybějící cyklistické propojení', 'line', 20),
  (6, 'Chybějící průchod', 'point', 30),
  (6, 'Přerušená pěší trasa', 'line', 40),
  (6, 'Chybějící propojení s krajinou', 'line', 50),
  (6, 'Potenciál pro novou trasu', 'line', 60)
on conflict (category_id, name) do nothing;

-- Místní části (orientační středy; přesné hranice katastrálních území lze
-- nahrát v administraci → Nastavení → Místní části, viz README)
insert into public.districts (name, center, sort_order) values
  ('Ivančice',  extensions.ST_SetSRID(extensions.ST_MakePoint(16.3775, 49.1014), 4326), 1),
  ('Letkovice', extensions.ST_SetSRID(extensions.ST_MakePoint(16.3567, 49.0958), 4326), 2),
  ('Alexovice', extensions.ST_SetSRID(extensions.ST_MakePoint(16.3600, 49.0890), 4326), 3),
  ('Němčice',   extensions.ST_SetSRID(extensions.ST_MakePoint(16.3689, 49.0928), 4326), 4),
  ('Budkovice', extensions.ST_SetSRID(extensions.ST_MakePoint(16.3485, 49.0722), 4326), 5),
  ('Řeznovice', extensions.ST_SetSRID(extensions.ST_MakePoint(16.3206, 49.0847), 4326), 6),
  ('Hrubšice',  extensions.ST_SetSRID(extensions.ST_MakePoint(16.3045, 49.0905), 4326), 7)
on conflict (name) do nothing;

-- >>> 20261120000700_storage.sql
-- =====================================================================
-- Úložiště fotografií (Supabase Storage)
-- Bucket „photos“: veřejné čtení (náhodné UUID cesty), zápis jen do vlastní
-- složky přihlášeného uživatele, max. 6 MB, pouze obrázky.
-- Skrytí fotografie moderátorem ji odstraní z aplikace; trvalé smazání
-- souboru provádí administrace (Storage API s právy administrátora).
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 6291456, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "photos_insert_own_folder" on storage.objects;
create policy "photos_insert_own_folder" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = auth.uid()::text
    and not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_blocked)
  );

drop policy if exists "photos_read" on storage.objects;
create policy "photos_read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'photos');

drop policy if exists "photos_delete_own_or_admin" on storage.objects;
create policy "photos_delete_own_or_admin" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- >>> 20261120000800_maphub_data.sql
-- =====================================================================
-- Původní mapa MapHub „Ivančice očima pěších a cyklistů“ (kristri)
-- 5 původních kategorií (skupin) a 81 původních zakreslení.
-- Zakreslení jsou označena zdrojem 'maphub' a autorem „Původní mapa (MapHub)“.
-- Opakované spuštění nic nezdvojí.
-- =====================================================================

insert into public.categories (code, name, description, color, icon, default_geom, sort_order, source, theme) values
  ('maphub-4012865806', 'Nebezpečná místa pro pěší a cyklisty', 'Kategorie z původní mapy MapHub', '#cc1b15', 'shield', 'line', 100, 'maphub', 'mobilita'),
  ('maphub-1164403015', 'Nepříjemná nebo odpuzující místa', 'Kategorie z původní mapy MapHub', '#e0a800', 'construction', 'line', 110, 'maphub', 'mobilita'),
  ('maphub-3919024396', 'Nedostatečná obytnost, chybějící vybavení', 'Kategorie z původní mapy MapHub', '#a2911c', 'bench', 'polygon', 120, 'maphub', 'mobilita'),
  ('maphub-3687981227', 'Bariéra prostupnosti / přerušení', 'Kategorie z původní mapy MapHub', '#9333ea', 'route', 'line', 130, 'maphub', 'mobilita'),
  ('maphub-78187723', 'Příjemná trasa nebo místo', 'Kategorie z původní mapy MapHub', '#3cc954', 'trees', 'line', 140, 'maphub', 'mobilita')
on conflict (code) do nothing;

insert into public.reports (id, user_id, author_key, author_name, category_id, title, description, geom, geom_kind, source, created_at)
select v.id::uuid, null, '00000000-0000-4000-8000-00000000a0b1'::uuid, 'Původní mapa (MapHub)', c.id, v.title, v.descr,
       extensions.ST_SetSRID(extensions.ST_GeomFromGeoJSON(v.g), 4326), v.kind::public.geom_kind, 'maphub', timestamptz '2025-01-01 12:00:00+01'
from (values
  ('710dc258-3f33-e7dd-efc8-5a9f75b8fb01', 'maphub-4012865806', 'Na Brněnce', null, 'line', '{"type":"LineString","coordinates":[[16.37449,49.109272],[16.373788,49.108942],[16.373283,49.108625],[16.372866,49.108137],[16.37258,49.107303],[16.372317,49.106843],[16.372075,49.105478],[16.371944,49.104198],[16.3719,49.103623]]}'),
  ('9157075a-e2d9-05cf-850f-09fcd81e752a', 'maphub-4012865806', 'Oslavanská', null, 'line', '{"type":"LineString","coordinates":[[16.368899,49.103686],[16.371863,49.10347]]}'),
  ('ead4f5e1-a614-aa4d-fcc5-e39d06bd223d', 'maphub-4012865806', 'křižovatka Tesařovo náměstí', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.374966,49.10171],[16.374954,49.101537],[16.375115,49.10144],[16.375322,49.10144],[16.375448,49.101597],[16.375356,49.101748],[16.375161,49.101763],[16.374966,49.10171]]]}'),
  ('b2610f91-b1ce-5845-890d-06d15bd1fc64', 'maphub-4012865806', 'přechod u Penny', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.375625,49.099924],[16.375539,49.099871],[16.375545,49.099796],[16.375637,49.09974],[16.375769,49.099759],[16.375797,49.099834],[16.375774,49.099905],[16.375625,49.099924]]]}'),
  ('978eddda-40d6-ad81-ed91-9c8d25689a15', 'maphub-4012865806', 'Oslavanská - Dolní Hlinky', null, 'line', '{"type":"LineString","coordinates":[[16.375814,49.10308],[16.376135,49.103147],[16.376433,49.103286]]}'),
  ('6513b8f3-6672-6d90-ccf7-2e1ab3f0b8f7', 'maphub-4012865806', 'Krumlovská - cyklo', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.369143,49.096687],[16.369085,49.096574],[16.3692,49.096474],[16.36934,49.096474],[16.369449,49.096532],[16.369455,49.096636],[16.369366,49.096724],[16.369251,49.096728],[16.369143,49.096687]]]}'),
  ('1b4fe7ec-a3ac-3e4e-5f45-418c6497f92f', 'maphub-4012865806', 'roh Hybešova', null, 'line', '{"type":"LineString","coordinates":[[16.369769,49.099031],[16.369769,49.098875],[16.369956,49.098834],[16.370215,49.098841]]}'),
  ('a8c2517d-e13d-34a1-5c2b-4cd7ef1413ea', 'maphub-4012865806', 'Na Volvách', null, 'line', '{"type":"LineString","coordinates":[[16.368739,49.099028],[16.369311,49.099105],[16.369854,49.099258],[16.370133,49.099547]]}'),
  ('33341106-f0a7-9d10-e79b-8c54b2ccb294', 'maphub-4012865806', 'Dlouhá (Letkovice)', null, 'line', '{"type":"LineString","coordinates":[[16.350547,49.094138],[16.352031,49.094502],[16.355031,49.094725],[16.358248,49.095252]]}'),
  ('7fb235ee-933a-808b-d42c-664fcf24bb2a', 'maphub-4012865806', 'křižovatka Nová Ves', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.358236,49.095344],[16.358064,49.095038],[16.358481,49.09499],[16.358236,49.095344]]]}'),
  ('a6e48c48-4bf0-8e76-8c0e-580d3c5b04ea', 'maphub-4012865806', '"hřiště" u křížku', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.351522,49.094702],[16.3515,49.094441],[16.351735,49.094369],[16.352103,49.094475],[16.352008,49.094596],[16.351728,49.094673],[16.351522,49.094702]]]}'),
  ('b3f06053-7c94-ed8f-eccd-4751e71706cb', 'maphub-4012865806', 'Tovární (Alexovice - Němčice)', null, 'line', '{"type":"LineString","coordinates":[[16.356147,49.091124],[16.358053,49.092073],[16.360066,49.09297],[16.36181,49.093479],[16.362776,49.093778]]}'),
  ('0cae0a41-e2fc-9750-8308-2f97dc575065', 'maphub-4012865806', 'křižovatka U Brázdů', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.362032,49.093771],[16.361911,49.093675],[16.362024,49.093511],[16.362267,49.093516],[16.362429,49.093596],[16.362421,49.093771],[16.362178,49.093802],[16.362032,49.093771]]]}'),
  ('a713c9ae-e1e5-b34d-a0bd-0afdb215546d', 'maphub-4012865806', 'ZŠ Němčice', null, 'line', '{"type":"LineString","coordinates":[[16.363832,49.093926],[16.364677,49.093907],[16.364981,49.093864],[16.365228,49.093578],[16.365475,49.093279]]}'),
  ('e4da6c78-8439-0f35-08c6-1e5f4a395851', 'maphub-4012865806', 'U Parku (Alexovice)', null, 'line', '{"type":"LineString","coordinates":[[16.351246,49.089794],[16.352216,49.089825],[16.353451,49.089866],[16.354561,49.090091],[16.35539,49.090265],[16.355922,49.090337]]}'),
  ('699e5f42-2fc6-deb9-6f22-0dc8bcca3559', 'maphub-4012865806', 'přechod Horní Hlinky', 'nepřehledný pro chodce', 'polygon', '{"type":"Polygon","coordinates":[[[16.382923,49.103248],[16.382779,49.103192],[16.382779,49.103078],[16.382989,49.103026],[16.38309,49.10313],[16.383083,49.103201],[16.382923,49.103248]]]}'),
  ('76671b67-e167-0e83-7077-6bcc44207065', 'maphub-4012865806', 'zatáčka Řeznovice', null, 'line', '{"type":"LineString","coordinates":[[16.319745,49.083288],[16.319836,49.083449],[16.320069,49.083492],[16.321235,49.083212],[16.321676,49.083161],[16.321754,49.083297],[16.321559,49.083416],[16.321183,49.083458],[16.320769,49.083534],[16.32016,49.083755]]}'),
  ('b94a6e01-5d85-5337-a583-a523023c4763', 'maphub-4012865806', 'Řeznovice - Polánka', null, 'line', '{"type":"LineString","coordinates":[[16.306368,49.072378],[16.307336,49.07262],[16.307567,49.073435],[16.306967,49.074583],[16.307659,49.075006],[16.309088,49.075399]]}'),
  ('fde5dea1-71d8-e6c2-6ef4-4d9376c970c2', 'maphub-4012865806', 'Řeznovice - Pod Vinohrady', null, 'line', '{"type":"LineString","coordinates":[[16.322373,49.0874],[16.322483,49.088102],[16.321879,49.088714],[16.322978,49.088462],[16.323719,49.08785],[16.324241,49.088264],[16.325175,49.08839],[16.326933,49.089469],[16.327922,49.090117],[16.328472,49.089973],[16.329021,49.089523],[16.329708,49.089415]]}'),
  ('6e0a419d-02ff-c5cf-2a9f-dace0f775ae9', 'maphub-4012865806', 'Řeznovice - Hrubšice podél řeky', null, 'line', '{"type":"LineString","coordinates":[[16.311687,49.086625],[16.310671,49.088046],[16.309846,49.089215],[16.309105,49.089827],[16.308418,49.091608],[16.308555,49.093604],[16.308341,49.094401],[16.307484,49.095031],[16.306184,49.095269],[16.305327,49.095729],[16.304885,49.095865]]}'),
  ('74267118-9999-a9f9-982f-a16ef8edf87a', 'maphub-4012865806', 'Alexovice - Řeznovice', null, 'line', '{"type":"LineString","coordinates":[[16.327525,49.086811],[16.329612,49.087553],[16.332833,49.087905],[16.33602,49.088316],[16.338613,49.089242],[16.342884,49.089889],[16.34511,49.089747],[16.348103,49.089418]]}'),
  ('65a46369-96ae-2f75-2956-466121e54b6a', 'maphub-4012865806', 'Zatáčka - vjezd do Ivančic', null, 'line', '{"type":"LineString","coordinates":[[16.374476,49.109279],[16.375728,49.10977],[16.377605,49.113293]]}'),
  ('c6a415ae-95ec-95d6-27a6-58bdc6ad7e5f', 'maphub-4012865806', 'Zatáčka od sídliště k Tescu', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.365918,49.102284],[16.365759,49.102331],[16.365695,49.102107],[16.366221,49.102055],[16.366213,49.102258],[16.365918,49.102284]]]}'),
  ('049cd212-2ee5-1b55-a029-39b441816823', 'maphub-1164403015', 'Oslavanská', null, 'line', '{"type":"LineString","coordinates":[[16.36496,49.104146],[16.366376,49.103865],[16.371655,49.103584],[16.372985,49.103556],[16.375174,49.103191]]}'),
  ('7ef9564a-62ce-c6cc-6789-de0d926ea474', 'maphub-1164403015', 'Tesco', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.364146,49.104337],[16.363645,49.10364],[16.363826,49.103444],[16.364103,49.1032],[16.364061,49.102782],[16.364295,49.102712],[16.364529,49.103389],[16.365755,49.103144],[16.365989,49.103193],[16.366266,49.103849],[16.365051,49.104184],[16.364796,49.10403],[16.364583,49.104037],[16.364476,49.104198],[16.364551,49.104344],[16.364146,49.104337]]]}'),
  ('6faec93f-54e7-f9b5-ab91-8491336b3fc8', 'maphub-1164403015', 'Hybešova - Krumlovská', null, 'line', '{"type":"LineString","coordinates":[[16.374061,49.099401],[16.375532,49.099765],[16.375671,49.100064],[16.37571,49.100325],[16.37577,49.099973]]}'),
  ('63499d90-f9c9-78a8-8f07-11037e579581', 'maphub-1164403015', 'Krumlovská', null, 'line', '{"type":"LineString","coordinates":[[16.368134,49.091229],[16.368313,49.092635],[16.368332,49.093429],[16.368114,49.093884],[16.367438,49.094353],[16.36706,49.094561],[16.36714,49.094821],[16.367855,49.095381],[16.368213,49.095876],[16.369128,49.096487],[16.369803,49.096813],[16.371016,49.097294],[16.372328,49.097607]]}'),
  ('02e94336-7e76-e609-16be-60c25d102fb2', 'maphub-1164403015', 'Pod Rénou', null, 'line', '{"type":"LineString","coordinates":[[16.376478,49.098322],[16.380195,49.098726]]}'),
  ('0a5d2320-7d06-8b40-8387-3c6179ad19e9', 'maphub-1164403015', 'Mlýnská', null, 'line', '{"type":"LineString","coordinates":[[16.377658,49.100811],[16.378091,49.100398]]}'),
  ('e58a6ac2-e9ab-fa0a-db0f-6c465e7b7a96', 'maphub-1164403015', 'Řeznovice - mezi hřištěm a řekou', null, 'line', '{"type":"LineString","coordinates":[[16.31872,49.086032],[16.319588,49.086579],[16.320306,49.08683],[16.321642,49.086907],[16.322443,49.086939]]}'),
  ('a1bef7ac-dd77-ef6f-8927-9be496b9f990', 'maphub-3919024396', 'Oranžové hřiště', 'chybí WC', 'point', '{"type":"Point","coordinates":[16.377425,49.102897]}'),
  ('a360f838-d1ec-87cf-8b8f-e80cc3e8b798', 'maphub-3919024396', 'Dolní Hlinky', 'Chybějící odpadkový koš', 'polygon', '{"type":"Polygon","coordinates":[[[16.378213,49.104439],[16.378108,49.104419],[16.378162,49.104347],[16.378244,49.104386],[16.378213,49.104439]]]}'),
  ('d73a4bd7-1935-5d67-8da7-2b4d9f727f58', 'maphub-3919024396', 'Mola u Rény', 'poteciál oprášení projektu J. Vágnerové', 'polygon', '{"type":"Polygon","coordinates":[[[16.387713,49.09788],[16.387365,49.097866],[16.387358,49.097764],[16.387621,49.097694],[16.387728,49.097754],[16.387713,49.09788]]]}'),
  ('f1855a9d-141a-583a-3203-5b6c40bc99fa', 'maphub-3919024396', 'Letní kino', 'potenciál obnovy', 'polygon', '{"type":"Polygon","coordinates":[[[16.388439,49.094763],[16.387857,49.094867],[16.38761,49.094613],[16.387963,49.094301],[16.388369,49.094451],[16.388439,49.094763]]]}'),
  ('38a50ec7-9705-3b80-ddc1-98e263f2ce51', 'maphub-3687981227', 'Tesco - sídliště - SVČ', null, 'line', '{"type":"LineString","coordinates":[[16.365381,49.104106],[16.365537,49.106527],[16.366335,49.106718],[16.366705,49.10733],[16.366997,49.107954]]}'),
  ('b1895f39-6436-2ddb-9940-745acfc98a87', 'maphub-3687981227', 'Staré sídliště - Tesco - MŠ - SVČ', null, 'line', '{"type":"LineString","coordinates":[[16.366511,49.104019],[16.366452,49.103847],[16.366306,49.103764],[16.365907,49.102745],[16.365829,49.102222],[16.366005,49.102165],[16.366209,49.102127]]}'),
  ('bf7789b2-5cb4-38a7-2642-4f8534e90ded', 'maphub-3687981227', 'Kocberky', null, 'line', '{"type":"LineString","coordinates":[[16.366432,49.100128],[16.366267,49.099998],[16.366146,49.099913],[16.366118,49.099823],[16.366259,49.09973],[16.366393,49.099638]]}'),
  ('0654fe10-94e0-7780-5a5b-bb70a6957720', 'maphub-3687981227', 'Na Volvách', null, 'line', '{"type":"LineString","coordinates":[[16.368038,49.099026],[16.368709,49.099004],[16.369067,49.099026],[16.369559,49.099132],[16.369862,49.099245]]}'),
  ('f91a551b-85f5-0581-bbcb-18c349880f8b', 'maphub-3687981227', '? Letkovice - centrum kolem řeky', null, 'line', '{"type":"LineString","coordinates":[[16.368193,49.097753],[16.367397,49.09698],[16.365824,49.095811],[16.364708,49.095214],[16.363684,49.094934],[16.363052,49.094576],[16.361069,49.0938],[16.359325,49.092948],[16.358501,49.092757],[16.357775,49.092853],[16.356407,49.093314],[16.355302,49.093432],[16.354299,49.093415],[16.35221,49.092893]]}'),
  ('d5f67753-98d3-bc3c-cd6f-66c298a0a7d8', 'maphub-3687981227', '? Lávka přes železnici', null, 'line', '{"type":"LineString","coordinates":[[16.368299,49.097776],[16.368603,49.097782],[16.368799,49.098132],[16.368942,49.098191],[16.369656,49.098167],[16.369763,49.098816]]}'),
  ('f0ba3621-265e-31a8-d8ac-4eefccb2dd64', 'maphub-3687981227', 'Letkovská náves - Dlouhá', null, 'line', '{"type":"LineString","coordinates":[[16.357007,49.094888],[16.357335,49.094011]]}'),
  ('f991a82e-ebef-7c31-bb9a-c9398ac8f8eb', 'maphub-3687981227', 'Dlouhá - řeka (Letkovice)', null, 'line', '{"type":"LineString","coordinates":[[16.354581,49.09462],[16.354877,49.093426]]}'),
  ('9f6527d0-a6ee-78ce-abfd-1b826886f5ed', 'maphub-3687981227', 'Letkovice - Alexovice (most)', null, 'line', '{"type":"LineString","coordinates":[[16.352141,49.0929],[16.353879,49.091661],[16.354546,49.091305],[16.355136,49.091397],[16.355756,49.090909]]}'),
  ('7dc40908-b816-8ec7-3632-b90def8cbb0e', 'maphub-3687981227', 'Letkovice - Alexovice', null, 'line', '{"type":"LineString","coordinates":[[16.359267,49.092954],[16.359493,49.09259],[16.358691,49.092213],[16.359061,49.090786]]}'),
  ('73cab234-1ac9-683d-f3b8-f87287e1bdd2', 'maphub-3687981227', 'Alexovice - Němčice', null, 'line', '{"type":"LineString","coordinates":[[16.358938,49.091223],[16.36305,49.09193]]}'),
  ('86a14336-9a22-c30e-78ca-3d1a817a12dd', 'maphub-3687981227', 'Alexovice - Němčice', null, 'line', '{"type":"LineString","coordinates":[[16.360597,49.091516],[16.360817,49.090852],[16.361056,49.090864],[16.361228,49.090438]]}'),
  ('900c10bb-64ea-7d0f-180e-bbeaec8e63da', 'maphub-3687981227', 'U Brázdů - MŠ', null, 'line', '{"type":"LineString","coordinates":[[16.363804,49.09262],[16.365437,49.092758],[16.365802,49.092273],[16.365912,49.092129],[16.365901,49.091818],[16.366806,49.091796]]}'),
  ('b93beae9-8a83-3169-14d9-fa49db25d572', 'maphub-3687981227', 'ZŠ - MŠ Němčice', null, 'line', '{"type":"LineString","coordinates":[[16.365603,49.093336],[16.365901,49.092165]]}'),
  ('5c260e71-094a-3ed2-a3dc-4e3f3b056d77', 'maphub-3687981227', 'Černá (Němčice)', 'chybějící chodník', 'line', '{"type":"LineString","coordinates":[[16.365962,49.092201],[16.367479,49.092223]]}'),
  ('05156f08-bec8-1627-1cfb-8aa4e2812872', 'maphub-3687981227', 'okraj Němčic', 'chybějící komunikace a chodník', 'line', '{"type":"LineString","coordinates":[[16.368124,49.090801],[16.369964,49.090397]]}'),
  ('2ac3a4e9-47a3-facc-27f7-c0b71d32fe46', 'maphub-3687981227', 'Němčice', 'chybějící propojení', 'line', '{"type":"LineString","coordinates":[[16.370333,49.092488],[16.369728,49.091125]]}'),
  ('65242179-c5bd-8fc2-2195-025c48fe6613', 'maphub-3687981227', 'náhon - ZŠ Němčice', null, 'line', '{"type":"LineString","coordinates":[[16.362341,49.093575],[16.362525,49.093541],[16.363532,49.093695],[16.364253,49.093734],[16.364635,49.093739],[16.365076,49.093753]]}'),
  ('fce4cd30-440e-b31a-4d1f-675b83d4095b', 'maphub-3687981227', 'lávka Němčice - centrum', null, 'line', '{"type":"LineString","coordinates":[[16.366454,49.09442],[16.366122,49.09463],[16.365784,49.094743],[16.365194,49.094941],[16.364771,49.095238]]}'),
  ('279991cf-a51c-1b7f-7812-4ff23a2aa525', 'maphub-3687981227', '? Most Němčice - centrum', null, 'line', '{"type":"LineString","coordinates":[[16.371047,49.094796],[16.37186,49.09553]]}'),
  ('fd67d7c6-f363-2dde-a9e5-c773529e6dd8', 'maphub-3687981227', 'MŠ A ZŠ pro sluchově postižené', 'průchod', 'line', '{"type":"LineString","coordinates":[[16.368213,49.101396],[16.369347,49.101348],[16.369379,49.101485],[16.370245,49.101468],[16.37025,49.10153],[16.3709,49.101519]]}'),
  ('f4943cd5-e754-9c58-027e-cccba9b0cf3a', 'maphub-3687981227', 'gymnázium a ZŠ Na Brněnce', null, 'line', '{"type":"LineString","coordinates":[[16.370831,49.105598],[16.370555,49.103652]]}'),
  ('de14575d-1bff-af51-65e1-b3a8bbeb809e', 'maphub-3687981227', 'Židovský hřbitov', null, 'line', '{"type":"LineString","coordinates":[[16.376573,49.106341],[16.375448,49.106445],[16.374662,49.106626],[16.374312,49.105861],[16.374301,49.104951],[16.375087,49.104916],[16.375437,49.104923]]}'),
  ('412b8ca4-15a4-004c-0d0f-256621f56ad8', 'maphub-3687981227', 'Lipová', null, 'line', '{"type":"LineString","coordinates":[[16.373654,49.106188],[16.373516,49.105097],[16.374291,49.105041]]}'),
  ('1a68dfc2-51ae-40eb-da39-950e5f0e4e6c', 'maphub-3687981227', '? Mřenková - Hlinky', null, 'line', '{"type":"LineString","coordinates":[[16.375472,49.104924],[16.376624,49.105197]]}'),
  ('b736aa0c-49b6-a1cf-6c57-aff923308af2', 'maphub-3687981227', 'Tyršova', null, 'line', '{"type":"LineString","coordinates":[[16.383163,49.100431],[16.383851,49.101957]]}'),
  ('798241cc-c89e-d095-d48e-518c5af634e8', 'maphub-3687981227', 'Farní zahrada - pošta', null, 'line', '{"type":"LineString","coordinates":[[16.37697,49.101889],[16.377018,49.10247],[16.377285,49.102477],[16.377361,49.102771],[16.378603,49.102621]]}'),
  ('53773dfe-0d02-3d7a-5961-d3fa1cac8f3d', 'maphub-3687981227', 'Pod Rénou', null, 'line', '{"type":"LineString","coordinates":[[16.378084,49.098418],[16.377965,49.098883],[16.378604,49.099255],[16.378593,49.099674]]}'),
  ('1daa2166-2ea3-d4a4-9c06-b284146be861', 'maphub-3687981227', 'Pod Rénou', null, 'line', '{"type":"LineString","coordinates":[[16.379481,49.096083],[16.378723,49.097167],[16.378924,49.09741],[16.378352,49.098017],[16.378089,49.098362]]}'),
  ('c3e636a8-a269-3be4-0d27-20413620a8a7', 'maphub-3687981227', 'Pod Rénou', null, 'line', '{"type":"LineString","coordinates":[[16.378772,49.099984],[16.379565,49.09955],[16.380275,49.099309],[16.380559,49.098775],[16.380583,49.098015],[16.380346,49.097759],[16.380734,49.097521],[16.38109,49.097136],[16.380703,49.096042]]}'),
  ('c9ebeabe-c5d2-7e1f-9a51-3cb4893c9295', 'maphub-3687981227', 'hala HK', null, 'line', '{"type":"LineString","coordinates":[[16.382088,49.099195],[16.382781,49.099886],[16.383159,49.100433]]}'),
  ('e5bd525c-929b-b639-be61-4443f326a9af', 'maphub-3687981227', 'nové sídliště', null, 'line', '{"type":"LineString","coordinates":[[16.366398,49.106788],[16.367005,49.106747]]}'),
  ('9235db04-121c-219b-fcbe-7f2808386f8e', 'maphub-3687981227', 'nové sídliště', null, 'line', '{"type":"LineString","coordinates":[[16.365506,49.10597],[16.367317,49.105906]]}'),
  ('400930a4-94cb-98b5-79eb-b296ef9c4963', 'maphub-78187723', 'Oranžové hřiště', 'chybí WC', 'polygon', '{"type":"Polygon","coordinates":[[[16.377071,49.102969],[16.377062,49.102456],[16.377307,49.102456],[16.377358,49.102754],[16.377808,49.102683],[16.377859,49.102871],[16.377338,49.102961],[16.377071,49.102969]]]}'),
  ('8533eb82-1b11-895b-fad6-05ffef7eaa3e', 'maphub-78187723', 'Zahrada vily Panowských', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.387305,49.100193],[16.387232,49.099699],[16.388923,49.100137],[16.389301,49.100153],[16.38924,49.100305],[16.388534,49.100337],[16.387694,49.100241],[16.387305,49.100193]]]}'),
  ('fa333d88-e5aa-4920-5c9a-cf3b9ed1b989', 'maphub-78187723', 'Réna', null, 'line', '{"type":"LineString","coordinates":[[16.387405,49.09918],[16.387962,49.097734],[16.388217,49.097832],[16.388773,49.097793],[16.390336,49.097881],[16.391494,49.097832]]}'),
  ('1c546d59-5f8d-72b7-75ec-5d6e8387df9f', 'maphub-78187723', 'Tenisové kurty - zelená plocha', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.364572,49.093664],[16.364485,49.093862],[16.362569,49.093636],[16.362664,49.093393],[16.363579,49.093517],[16.363743,49.093065],[16.364779,49.093206],[16.364572,49.093664]]]}'),
  ('cce1afbd-5b8b-7ff2-a942-ec5e0fe7952b', 'maphub-78187723', 'cyklo u řeky', null, 'line', '{"type":"LineString","coordinates":[[16.387643,49.098372],[16.38598,49.098277],[16.385336,49.098407],[16.384846,49.098427],[16.384713,49.098033],[16.384416,49.097953],[16.383957,49.09798],[16.383417,49.097423],[16.382217,49.096555],[16.381488,49.096259],[16.380955,49.096098],[16.379112,49.096028],[16.377488,49.095782],[16.375946,49.095179],[16.375061,49.094571],[16.374435,49.094229],[16.373391,49.094217],[16.372347,49.094787],[16.371518,49.095406],[16.370659,49.09581],[16.369492,49.096339],[16.368455,49.097107],[16.367634,49.097511],[16.36646,49.097796],[16.365798,49.097857],[16.365509,49.098452],[16.363881,49.098523],[16.363032,49.098277],[16.362703,49.098343],[16.362184,49.098882],[16.361619,49.100008],[16.361114,49.10125],[16.361016,49.102961]]}'),
  ('9e2da49c-5a5c-4d24-36db-65ebc881b6ea', 'maphub-78187723', 'Réna', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.387977,49.097704],[16.388127,49.097507],[16.388533,49.097458],[16.388788,49.097615],[16.388758,49.097852],[16.388187,49.097871],[16.387977,49.097704]]]}'),
  ('f412912f-d0c9-ff6e-496e-8ff688f2f786', 'maphub-78187723', 'cyklo Oslavany', null, 'line', '{"type":"LineString","coordinates":[[16.360926,49.102958],[16.356606,49.104812],[16.355262,49.10469],[16.353096,49.106493],[16.351516,49.107581],[16.350547,49.108452]]}'),
  ('205043c8-df97-90ff-3480-ef007735da0f', 'maphub-78187723', 'cyklo u řeky', null, 'line', '{"type":"LineString","coordinates":[[16.371618,49.094498],[16.373126,49.09385],[16.374209,49.093665],[16.375034,49.093881],[16.376353,49.094714],[16.377908,49.095426],[16.38007,49.095644],[16.381433,49.095775],[16.382725,49.096244],[16.382163,49.095289],[16.381868,49.094319],[16.381783,49.093478],[16.381409,49.09318]]}'),
  ('5c23ab2c-eb23-f9bb-9cf2-26ed839e4c70', 'maphub-78187723', 'Hrubšice kolem řeky', null, 'line', '{"type":"LineString","coordinates":[[16.307599,49.094506],[16.307292,49.095659],[16.306067,49.096462],[16.305302,49.097164],[16.303732,49.097815],[16.299712,49.097865],[16.297262,49.097364],[16.295194,49.096261],[16.293625,49.095133]]}'),
  ('c8fd8c03-e870-5fda-6b87-bac707445eda', 'maphub-78187723', 'Letkovské rybníky - Řeznovice', null, 'line', '{"type":"LineString","coordinates":[[16.330076,49.089573],[16.332907,49.089882],[16.336621,49.090037],[16.339039,49.090114],[16.342046,49.090075],[16.344817,49.090732],[16.346291,49.090963]]}'),
  ('7aa7ba10-185d-f6dd-e3f0-b691fd384719', 'maphub-78187723', 'Pekárka', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.34279,49.089703],[16.338989,49.089167],[16.337023,49.088115],[16.337351,49.087085],[16.339087,49.087021],[16.340562,49.088137],[16.343118,49.088029],[16.344166,49.088544],[16.343969,49.08936],[16.343412,49.089574],[16.34279,49.089703]]]}'),
  ('19d235da-b289-ce86-8880-ec020fc482ae', 'maphub-78187723', 'Řeznovice - Na malých nivách', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.316344,49.08291],[16.31468,49.082256],[16.312914,49.082155],[16.312325,49.081904],[16.312274,49.081233],[16.311506,49.080546],[16.311506,49.080244],[16.310943,49.079707],[16.311967,49.079205],[16.313042,49.079205],[16.315832,49.080663],[16.317137,49.081585],[16.316779,49.08244],[16.316344,49.08291]]]}'),
  ('39fa682c-c7be-c07f-d67d-0838351e3034', 'maphub-78187723', 'Réna - kolem rozhledny', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.386766,49.097767],[16.386291,49.097606],[16.386397,49.097146],[16.38724,49.096939],[16.388118,49.097307],[16.387872,49.097617],[16.38717,49.097755],[16.386766,49.097767]]]}'),
  ('356ca057-5057-995b-9e9a-2b74f6fe487d', 'maphub-78187723', 'Stříbský mlýn', null, 'polygon', '{"type":"Polygon","coordinates":[[[16.401367,49.09453],[16.4009,49.095047],[16.400027,49.093817],[16.400266,49.092791],[16.40096,49.092532],[16.401235,49.093143],[16.401415,49.094115],[16.401367,49.09453]]]}')
) as v(id, cat_code, title, descr, kind, g)
join public.categories c on c.code = v.cat_code
on conflict (id) do nothing;

refresh materialized view public.report_metrics;

