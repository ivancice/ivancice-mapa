-- =====================================================================
-- Sjednocené kategorie (6) + „Návrh nové kategorie“ se schválením správcem
--   1 Nebezpečná místa · 2 Cyklistická doprava · 3 Parkování a automobilová doprava
--   4 Bariéry a přerušené trasy · 5 Nepříjemná místa a pocit bezpečí
--   6 Příjemná místa a trasy · 7 Návrh nové kategorie (podnět čeká na schválení)
-- Převod je bezpečný pro již běžící databázi a lze ho spustit opakovaně:
--   • podněty ze starých kategorií a podkategorií se přesunou do nových,
--   • zakreslení z původní mapy MapHub se zařadí do nových kategorií
--     (kategorii i podkategorii lze pak ručně upravit v administraci),
--   • původní kategorie MapHub se skryjí (nemažou).
-- =====================================================================

alter table public.categories add column if not exists requires_approval boolean not null default false;

select set_config('app.skip_metrics', 'on', false);

do $$
begin
  -- převod jen u databází se starým rozdělením (z první verze aplikace)
  if exists (select 1 from public.categories where code in ('bezpecnost-pesich', 'prostupnost')) then
    insert into public.subcategories (category_id, name, default_geom, sort_order) values
      (1, 'Nebezpečný přechod', 'point', 10), (1, 'Chybějící přechod', 'point', 20),
      (1, 'Nebezpečné místo pro chodce', 'point', 30), (1, 'Chybějící nebo úzký chodník', 'line', 40),
      (1, 'Nebezpečný úsek pro cyklisty', 'line', 50), (1, 'Nebezpečné místo pro děti', 'point', 90),
      (2, 'Chybějící cyklopropojení', 'line', 10), (2, 'Chybějící cyklistická infrastruktura', 'line', 20),
      (2, 'Problematické napojení na cyklotrasu', 'point', 30), (2, 'Chybějící stojany na kola', 'point', 40),
      (2, 'Konflikt pěších a cyklistů', 'point', 50),
      (4, 'Přerušená trasa', 'line', 10), (4, 'Chybějící pěší propojení', 'line', 20),
      (4, 'Chybějící průchod', 'point', 30), (4, 'Chybějící propojení s krajinou', 'line', 40),
      (4, 'Chybějící bezbariérový přístup', 'point', 50), (4, 'Vysoký obrubník', 'point', 60),
      (4, 'Nevhodný povrch', 'line', 70), (4, 'Nepřístupná zastávka', 'point', 80),
      (5, 'Nepříjemné nebo odpuzující místo', 'polygon', 10), (5, 'Necítím se tu bezpečně (ve dne nebo v noci)', 'point', 20),
      (5, 'Neosvětlené nebo špatně osvětlené místo', 'point', 30), (5, 'Opuštěné místo, podchod nebo zákoutí', 'point', 40),
      (5, 'Nedostatečná obytnost', 'polygon', 50), (5, 'Chybějící stromy a stín', 'polygon', 60),
      (5, 'Chybějící lavičky a mobiliář', 'point', 70), (5, 'Nevyužité prostranství / místo k revitalizaci', 'polygon', 80),
      (5, 'Hluk a provoz aut', 'polygon', 90)
    on conflict (category_id, name) do nothing;

    -- přesun podnětů podle podkategorie: (stará kat., stará podkat.) → (nová kat., nová podkat.)
    with m(oc, osub, nc, nsub) as (values
      (1, 'Chybějící chodník',                         1, 'Chybějící nebo úzký chodník'),
      (1, 'Špatně osvětlené místo',                    5, 'Neosvětlené nebo špatně osvětlené místo'),
      (2, 'Nebezpečný úsek pro cyklisty',              1, 'Nebezpečný úsek pro cyklisty'),
      (4, 'Bariéra v pěší trase',                      4, 'Přerušená trasa'),
      (5, 'Nevhodné povrchy',                          5, null),
      (5, 'Chybějící mobiliář',                        5, 'Chybějící lavičky a mobiliář'),
      (5, 'Nedostatek míst k odpočinku',               5, 'Chybějící lavičky a mobiliář'),
      (5, 'Nevhodné nebo nevyužité veřejné prostranství', 5, 'Nevyužité prostranství / místo k revitalizaci'),
      (5, 'Místo vhodné k revitalizaci',               5, 'Nevyužité prostranství / místo k revitalizaci'),
      (6, 'Chybějící pěší propojení',                  4, 'Chybějící pěší propojení'),
      (6, 'Chybějící cyklistické propojení',           2, 'Chybějící cyklopropojení'),
      (6, 'Chybějící průchod',                         4, 'Chybějící průchod'),
      (6, 'Přerušená pěší trasa',                      4, 'Přerušená trasa'),
      (6, 'Chybějící propojení s krajinou',            4, 'Chybějící propojení s krajinou'),
      (6, 'Potenciál pro novou trasu',                 4, 'Chybějící pěší propojení'))
    update public.reports r
       set category_id = m.nc,
           subcategory_id = (select s2.id from public.subcategories s2 where s2.category_id = m.nc and s2.name = m.nsub)
      from m
      join public.subcategories s on s.category_id = m.oc and s.name = m.osub
     where r.category_id = m.oc and r.subcategory_id = s.id;

    -- zbylé podněty z „Prostupnosti“ (kategorie 6 bude „Příjemná místa a trasy“)
    update public.reports set category_id = 4, subcategory_id = null where category_id = 6;

    -- staré podkategorie, které v novém rozdělení nejsou
    delete from public.subcategories s
     where s.category_id in (1, 2, 4, 5, 6)
       and (s.category_id, s.name) not in (
         select category_id, name from (values
           (1,'Nebezpečný přechod'),(1,'Chybějící přechod'),(1,'Nebezpečné místo pro chodce'),(1,'Chybějící nebo úzký chodník'),
           (1,'Nebezpečný úsek pro cyklisty'),(1,'Nebezpečné místo pro děti'),
           (2,'Chybějící cyklopropojení'),(2,'Chybějící cyklistická infrastruktura'),(2,'Problematické napojení na cyklotrasu'),
           (2,'Chybějící stojany na kola'),(2,'Konflikt pěších a cyklistů'),
           (4,'Přerušená trasa'),(4,'Chybějící pěší propojení'),(4,'Chybějící průchod'),(4,'Chybějící propojení s krajinou'),
           (4,'Chybějící bezbariérový přístup'),(4,'Vysoký obrubník'),(4,'Nevhodný povrch'),(4,'Nepřístupná zastávka'),
           (5,'Nepříjemné nebo odpuzující místo'),(5,'Necítím se tu bezpečně (ve dne nebo v noci)'),
           (5,'Neosvětlené nebo špatně osvětlené místo'),(5,'Opuštěné místo, podchod nebo zákoutí'),
           (5,'Nedostatečná obytnost'),(5,'Chybějící stromy a stín'),(5,'Chybějící lavičky a mobiliář'),
           (5,'Nevyužité prostranství / místo k revitalizaci'),(5,'Hluk a provoz aut')
         ) as keep(category_id, name));

    update public.categories c set code = v.code, name = v.name, description = v.descr, color = v.color, icon = v.icon,
           default_geom = v.geom::public.geom_kind, sort_order = v.ord, is_active = true, allow_custom_topic = v.custom,
           requires_approval = v.approval, updated_at = now()
      from (values
        (1, 'nebezpecna-mista',   'Nebezpečná místa',                 'Přechody, chodníky a úseky, kde hrozí úraz nebo srážka',        '#dc2626', 'shield',    'point',   10, false, false),
        (2, 'cyklisticka-doprava','Cyklistická doprava',              'Chybějící cyklotrasy, napojení, stojany na kola',               '#0891b2', 'bike',      'line',    20, false, false),
        (3, 'parkovani-auta',     'Parkování a automobilová doprava', 'Parkování, průjezd, rychlost aut, křižovatky',                  '#ea580c', 'car',       'point',   30, false, false),
        (4, 'bariery',            'Bariéry a přerušené trasy',        'Kudy se nedá projít nebo projet – nebo jen obtížně',            '#7c3aed', 'route',     'line',    40, false, false),
        (5, 'neprijemna-mista',   'Nepříjemná místa a pocit bezpečí', 'Kde se necítíte dobře nebo bezpečně a co tam chybí',            '#ca8a04', 'bench',     'polygon', 50, false, false),
        (6, 'prijemna-mista',     'Příjemná místa a trasy',           'Co funguje dobře a stojí za zachování',                         '#16a34a', 'trees',     'line',    60, false, false),
        (7, 'navrh-kategorie',    'Návrh nové kategorie',             'Chybí vám kategorie? Navrhněte ji a zakreslete místo – zobrazí se po schválení správcem', '#64748b', 'lightbulb', 'point', 1000, true, true)
      ) as v(id, code, name, descr, color, icon, geom, ord, custom, approval)
     where c.id = v.id;

    -- dosavadní „Jiné / vlastní podnět“ → čeká na schválení správcem
    update public.reports set is_hidden = true, hidden_reason = 'pending_approval'
     where category_id = 7 and not is_hidden and custom_topic is not null;
    update public.reports set category_id = 1, subcategory_id = null
     where category_id = 7 and custom_topic is null;

    insert into public.subcategories (category_id, name, default_geom, sort_order) values
      (6, 'Příjemná pěší trasa', 'line', 10), (6, 'Příjemná cyklotrasa', 'line', 20),
      (6, 'Příjemné místo k pobytu', 'polygon', 30), (6, 'Zeleň a příroda', 'polygon', 40),
      (6, 'Místo, které stojí za zachování', 'point', 50)
    on conflict (category_id, name) do nothing;
  end if;
end $$;

-- Zakreslení z původní mapy MapHub → nové kategorie (jen ta, která ještě zůstala
-- v původních skupinách; ručně přeřazené podněty se nemění)
with m(code, nc, nsub) as (values
  ('maphub-4012865806', 1, null),
  ('maphub-1164403015', 5, 'Nepříjemné nebo odpuzující místo'),
  ('maphub-3919024396', 5, 'Nedostatečná obytnost'),
  ('maphub-3687981227', 4, 'Přerušená trasa'),
  ('maphub-78187723',   6, null))
update public.reports r
   set category_id = m.nc,
       subcategory_id = coalesce(
         (select s.id from public.subcategories s where s.category_id = m.nc and s.name = m.nsub),
         case when m.nc = 6 then (select s.id from public.subcategories s where s.category_id = 6 and s.name =
           case when r.geom_kind = 'polygon' then 'Příjemné místo k pobytu'
                when r.title ilike '%cyklo%' then 'Příjemná cyklotrasa'
                when r.geom_kind = 'line' then 'Příjemná pěší trasa'
                else 'Místo, které stojí za zachování' end) end)
  from m join public.categories c on c.code = m.code
 where r.category_id = c.id;

update public.categories set is_active = false, updated_at = now()
 where code in ('maphub-4012865806', 'maphub-1164403015', 'maphub-3919024396', 'maphub-3687981227', 'maphub-78187723');

select set_config('app.skip_metrics', 'off', false);
refresh materialized view public.report_metrics;

-- =====================================================================
-- Schválení návrhu nové kategorie správcem
--   p_category_id = null → vytvoří se nová kategorie (název z návrhu nebo p_name)
--   p_category_id = id   → podnět se zařadí do existující kategorie
-- Podnět se v obou případech zveřejní.
-- =====================================================================
create or replace function public.admin_approve_proposal(p_id uuid, p_category_id integer, p_name text, p_color text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare admin uuid := public._require_admin(); r public.reports; v_cat integer := p_category_id; v_name text;
begin
  select * into r from public.reports where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if v_cat is null then
    v_name := coalesce(public._clean(p_name, 120), r.custom_topic);
    if v_name is null then raise exception 'topic_required' using errcode = 'P0001'; end if;
    select id into v_cat from public.categories where lower(name) = lower(v_name) and not requires_approval limit 1;
    if v_cat is null then
      insert into public.categories (name, description, color, icon, default_geom, sort_order)
      values (v_name, null, coalesce(nullif(p_color, ''), '#0d9488'), 'map-pin', r.geom_kind,
              (select coalesce(max(sort_order), 0) + 10 from public.categories where not requires_approval and sort_order < 1000))
      returning id into v_cat;
    end if;
  elsif not exists (select 1 from public.categories where id = v_cat and not requires_approval) then
    raise exception 'category_required' using errcode = 'P0001';
  end if;
  update public.reports set category_id = v_cat, subcategory_id = null, is_hidden = false, hidden_reason = null
   where id = p_id;
  insert into public.audit_log (actor, action, target_type, target_id, new_data)
  values (admin, 'approve_proposal', 'report', p_id::text, jsonb_build_object('category_id', v_cat, 'topic', r.custom_topic));
  return jsonb_build_object('category_id', v_cat);
end $$;

revoke execute on function public.admin_approve_proposal(uuid, integer, text, text) from public, anon;
grant execute on function public.admin_approve_proposal(uuid, integer, text, text) to authenticated;
