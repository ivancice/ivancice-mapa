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
