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
