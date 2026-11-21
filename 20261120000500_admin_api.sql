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
           or (p->>'visibility' = 'pending' and r.hidden_reason = 'pending_approval')
           or (p->>'visibility' = 'merged' and r.merged_into is not null)
           or (p->>'visibility' = 'flagged' and exists (select 1 from public.flags f where f.report_id = r.id and f.resolved_at is null)))
      and (coalesce(p->>'demo', 'all') = 'all' or (p->>'demo' = 'real' and not r.is_demo) or (p->>'demo' = 'demo' and r.is_demo) or (p->>'demo' = 'maphub' and r.source = 'maphub'))
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
      'allow_custom_topic', c.allow_custom_topic, 'requires_approval', c.requires_approval, 'theme', c.theme, 'source', c.source,
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
