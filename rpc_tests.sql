-- =====================================================================
-- Testy databázových funkcí (spouštějte na testovací databázi!)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rpc_tests.sql
-- Testy vytvoří dočasné uživatele a podněty a na konci je smažou.
-- =====================================================================
\set QUIET on
\pset pager off
\pset tuples_only on
\pset format unaligned

-- úklid po případném předchozím neúspěšném běhu
reset role;
delete from public.reports where author_key in (
  '00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000f1') or source = 'demo' or author_name = 'Anonym' or title = 'Z původní mapy';
delete from public.categories where name in ('Původní skupina', 'Testovací kategorie');
delete from public.supports where user_id::text like '00000000-0000-0000-0000-0000000000%';
delete from auth.users where email like '%@test.local' or id = '00000000-0000-0000-0000-0000000000f1';

update public.app_settings set value = 'false' where key = 'contribute_requires_login';

-- uživatelé ---------------------------------------------------------------
insert into public.admin_emails(email) values ('admin@test.local') on conflict do nothing;
insert into auth.users (id, email, is_anonymous) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local', false),
  ('00000000-0000-0000-0000-0000000000a1', 'alice@test.local', false),
  ('00000000-0000-0000-0000-0000000000b1', 'bob@test.local', false),
  ('00000000-0000-0000-0000-0000000000c1', 'cyril@test.local', false),
  ('00000000-0000-0000-0000-0000000000f1', null, true)
on conflict do nothing;

create or replace function pg_temp.act(p_uid text, p_anon boolean default false) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', p_anon)::text, false);
end $$;

create or replace function pg_temp.expect_error(p_sql text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm <> p_msg and sqlerrm not like '%' || p_msg || '%' then
      raise exception 'TEST FAIL: expected error %, got %', p_msg, sqlerrm;
    end if;
    raise notice 'ok – očekávaná chyba: %', p_msg;
    return;
  end;
  raise exception 'TEST FAIL: expected error % but statement succeeded: %', p_msg, p_sql;
end $$;

create or replace function pg_temp.check(p_cond boolean, p_label text) returns void language plpgsql as $$
begin
  if not coalesce(p_cond, false) then raise exception 'TEST FAIL: %', p_label; end if;
  raise notice 'ok – %', p_label;
end $$;

grant execute on all functions in schema pg_temp to authenticated, anon;

-- profil admina vznikl triggerem s rolí admin
select pg_temp.check((select is_admin from public.profiles where id = '00000000-0000-0000-0000-00000000000a'), 'admin profil z admin_emails');
select pg_temp.check(not (select is_admin from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'), 'běžný uživatel není admin');

-- 1) Anonymní relace vytvoří bodový podnět --------------------------------
set role authenticated;
select pg_temp.act('00000000-0000-0000-0000-0000000000f1', true);

select pg_temp.expect_error($$select public.create_report('{"category_id":1,"title":"x","author_name":"A","kind":"point","geometry":{"type":"Point","coordinates":[16.3775,49.1014]}}')$$, 'title_required');
select pg_temp.expect_error($$select public.create_report('{"category_id":1,"title":"Přechod u školy","author_name":"","kind":"point","geometry":{"type":"Point","coordinates":[16.3775,49.1014]}}')$$, 'name_required');
select pg_temp.expect_error($$select public.create_report('{"category_id":1,"title":"Mimo území","author_name":"A","kind":"point","geometry":{"type":"Point","coordinates":[14.42,50.08]}}')$$, 'outside_area');
select pg_temp.expect_error($$select public.create_report('{"category_id":1,"title":"Robot","author_name":"A","website":"http://spam","kind":"point","geometry":{"type":"Point","coordinates":[16.3775,49.1014]}}')$$, 'spam_detected');
select pg_temp.expect_error($$select public.create_report('{"category_id":1,"title":"Špatný typ","author_name":"A","kind":"line","geometry":{"type":"Point","coordinates":[16.3775,49.1014]}}')$$, 'geometry_kind_mismatch');

select public.create_report(jsonb_build_object(
  'category_id', 1, 'subcategory_id', (select id from public.subcategories where name = 'Nebezpečný přechod'),
  'title', 'Nebezpečný přechod u náměstí', 'author_name', 'Franta', 'description', 'Auta nezastavují.',
  'frequency', 'daily', 'kind', 'point', 'email', 'franta@example.com', 'newsletter', true,
  'geometry', '{"type":"Point","coordinates":[16.37752,49.10144]}'::jsonb,
  'photos', '[{"path":"00000000-0000-0000-0000-0000000000f1/a.jpg","width":800,"height":600}]'::jsonb)) as r1 \gset
select (:'r1'::jsonb)->>'id' as r1_id \gset

reset role;
select pg_temp.check((select district_id = (select id from public.districts where name = 'Ivančice') from public.reports where id = :'r1_id'), 'místní část přiřazena');
select pg_temp.check((select newsletter and contact_email = 'franta@example.com' from public.profiles where id = '00000000-0000-0000-0000-0000000000f1'), 'souhlas s novinkami uložen');
select pg_temp.check((select count(*) = 1 from public.photos where report_id = :'r1_id'), 'fotografie připojena');
set role authenticated;

select pg_temp.expect_error($$select public.create_report('{"category_id":1,"title":"Cizí foto","author_name":"A","kind":"point","geometry":{"type":"Point","coordinates":[16.3775,49.1014]},"photos":[{"path":"00000000-0000-0000-0000-0000000000a1/x.jpg"}]}')$$, 'invalid_photo_path');

-- fotografie lze vypnout v nastavení – pak se nepřipojí
reset role;
update public.app_settings set value = 'false' where key = 'photos_enabled';
set role authenticated;
select pg_temp.act('00000000-0000-0000-0000-0000000000f1', true);
select public.create_report('{"category_id":2,"title":"Bez fotek","author_name":"A","kind":"point","geometry":{"type":"Point","coordinates":[16.3700,49.0950]},"photos":[{"path":"00000000-0000-0000-0000-0000000000f1/b.jpg"}]}')->>'id' as nophoto_id \gset
reset role;
select pg_temp.check((select count(*) = 0 from public.photos where report_id = :'nophoto_id'), 'vypnuté fotografie se nepřipojí');
update public.app_settings set value = 'true' where key = 'photos_enabled';
delete from public.reports where id = :'nophoto_id';
set role authenticated;

-- 2) Podpora: anonym nesmí (vyžaduje ověření), ověřený může jednou -----------
select pg_temp.expect_error(format('select public.set_support(%L, true)', :'r1_id'), 'verification_required');

select pg_temp.act('00000000-0000-0000-0000-0000000000b1');
select pg_temp.check((public.set_support(:'r1_id', true)->>'people')::int = 2, 'Bob podpořil → 2 lidé');
select pg_temp.check((public.set_support(:'r1_id', true)->>'people')::int = 2, 'opakovaná podpora se nezapočítá');
select pg_temp.check((public.get_report(:'r1_id')->>'my_support')::boolean, 'detail: moje podpora');
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((public.set_support(:'r1_id', true)->>'people')::int = 3, 'Alice podpořila → 3 lidé');
select pg_temp.check((public.set_support(:'r1_id', false)->>'people')::int = 2, 'Alice odebrala podporu → 2 lidé');
select pg_temp.check((public.set_support(:'r1_id', true)->>'supporters')::int = 2, 'Alice znovu podpořila → 2 podporovatelé');

-- autor nemůže podpořit vlastní
reset role;
update auth.users set email = 'anon-converted@test.local', is_anonymous = false where id = '00000000-0000-0000-0000-0000000000f1';
set role authenticated;
select pg_temp.act('00000000-0000-0000-0000-0000000000f1');
select pg_temp.expect_error(format('select public.set_support(%L, true)', :'r1_id'), 'own_report');

-- 3) Blízké podněty stejné kategorie --------------------------------------
select pg_temp.act('00000000-0000-0000-0000-0000000000c1');
select pg_temp.check(jsonb_array_length(public.nearby_reports('{"type":"Point","coordinates":[16.3776,49.1015]}', 1)) = 1, 'nalezen blízký podnět');
select pg_temp.check(jsonb_array_length(public.nearby_reports('{"type":"Point","coordinates":[16.3776,49.1015]}', 2)) = 0, 'jiná kategorie se nenabízí');

-- 4) Překryvy ploch: tři lidé, plochy se částečně překrývají -----------------
do $$
declare u text; i int := 0;
begin
  foreach u in array array['00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1'] loop
    perform pg_temp.act(u);
    perform public.create_report(jsonb_build_object('category_id', 2, 'title', 'Nevyužité prostranství ' || i,
      'author_name', 'U' || i, 'kind', 'polygon',
      'geometry', ST_AsGeoJSON(ST_Buffer(ST_SetSRID(ST_MakePoint(16.3800 + i * 0.0007, 49.1030), 4326), 0.001, 8))::jsonb));
    i := i + 1;
  end loop;
end $$;
select pg_temp.check(
  (select max((f->'properties'->>'people')::int) from jsonb_array_elements(public.analysis_polygon_overlap(array[2])->'features') f) = 3,
  'překryv ploch: nejvyšší shoda = 3 lidé');
select pg_temp.check(
  (select count(*) from jsonb_array_elements(public.analysis_polygon_overlap(array[2])->'features') f) = 3,
  'překryv ploch: vrstvy pro 1, 2 a 3 lidi');
select pg_temp.check((public.analysis_polygon_overlap(array[2])->>'total_people')::int = 3, 'překryv ploch: celkem 3 lidé');

-- stejný člověk zakreslí druhou překrývající se plochu → nesmí se započítat dvakrát
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select public.create_report(jsonb_build_object('category_id', 2, 'title', 'Totéž znovu', 'author_name', 'Alice', 'kind', 'polygon',
  'geometry', ST_AsGeoJSON(ST_Buffer(ST_SetSRID(ST_MakePoint(16.3801, 49.1030), 4326), 0.0009, 8))::jsonb)) \gset
select pg_temp.check(
  (select max((f->'properties'->>'people')::int) from jsonb_array_elements(public.analysis_polygon_overlap(array[2])->'features') f) = 3,
  'jeden člověk se v překryvu počítá jednou');

-- 5) Překryvy linií: dvě podobné trasy + jedna kolmá ---------------------------
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select public.create_report('{"category_id":2,"title":"Chybí cyklostezka podél řeky","author_name":"Alice","kind":"line","geometry":{"type":"LineString","coordinates":[[16.3700,49.0990],[16.3750,49.1000],[16.3800,49.1010]]}}') \gset
select pg_temp.act('00000000-0000-0000-0000-0000000000b1');
select public.create_report('{"category_id":2,"title":"Cyklotrasa podél řeky","author_name":"Bob","kind":"line","geometry":{"type":"LineString","coordinates":[[16.3702,49.09905],[16.3751,49.10008],[16.3790,49.10085]]}}')->>'id' as line_b \gset
select pg_temp.act('00000000-0000-0000-0000-0000000000c1');
select public.create_report('{"category_id":2,"title":"Kolmá ulice","author_name":"Cyril","kind":"line","geometry":{"type":"LineString","coordinates":[[16.3750,49.0985],[16.3750,49.1015]]}}')->>'id' as line_c \gset

select pg_temp.check(
  (select max((f->'properties'->>'people')::int) from jsonb_array_elements(public.analysis_line_overlap(array[2])->'features') f) = 2,
  'překryv linií: shodné úseky = 2 lidé (kolmá linie se nepočítá)');
select pg_temp.check(
  (public.get_report(:'line_b')->>'overlap_people')::int = 1,
  'metrika shody linie: 1 další člověk');
select pg_temp.check(
  (public.get_report(:'line_b')->>'agreement')::numeric > 0.8,
  'metrika shody linie: podíl > 80 %');
select pg_temp.check(
  (public.get_report(:'line_c')->>'overlap_people')::int = 0,
  'kolmá linie nemá shodu');

-- 6) Body: shluk stejné kategorie ------------------------------------------
select pg_temp.act('00000000-0000-0000-0000-0000000000c1');
select public.create_report('{"category_id":1,"title":"Také nebezpečný přechod","author_name":"Cyril","kind":"point","geometry":{"type":"Point","coordinates":[16.37760,49.10150]}}')->>'id' as dup_id \gset
select pg_temp.check(
  (select (f->'properties'->>'reports')::int = 2 and (f->'properties'->>'people')::int = 4
     from jsonb_array_elements(public.analysis_point_clusters(array[1])->'features') f
     order by (f->'properties'->>'reports')::int desc limit 1),
  'shluk bodů: 2 podněty, 4 unikátní lidé (2 autoři + Bob + Alice)');
select pg_temp.check(jsonb_array_length(public.analysis_hexgrid(null, 200)->'features') > 0, 'šestiúhelníková síť intenzity');

-- 7) Mapa: unikátní lidé v datech pro shluky ----------------------------------
select pg_temp.check(
  (select (f->'properties'->>'p')::int = 3 and jsonb_array_length(f->'properties'->'u') = 3
   from jsonb_array_elements(public.get_map_data()->'features') f where f->'properties'->>'id' = :'r1_id'),
  'mapa: značka nese 3 unikátní lidi');

-- 8) Komentář a nahlášení ----------------------------------------------------
select pg_temp.check((public.add_comment(:'r1_id', 'Souhlasím, ráno je to hrozné.', 'Cyril') ? 'id'), 'komentář přidán');
select pg_temp.check((public.flag_content(:'r1_id', null, null, 'spam', 'test') ? 'id'), 'nahlášení obsahu');
select pg_temp.check(jsonb_array_length(public.get_report(:'r1_id')->'comments') = 1, 'komentář v detailu');

-- 9) Varianta: vlastní zakreslení odkazuje na původní, původní zůstává --------------
select pg_temp.act('00000000-0000-0000-0000-0000000000b1');
select public.create_report(jsonb_build_object('category_id', 1, 'title', 'Moje varianta – přechod o kus dál', 'author_name', 'Bob',
  'kind', 'line', 'variant_of', :'r1_id', 'geometry', '{"type":"LineString","coordinates":[[16.3774,49.1013],[16.3780,49.1017]]}'::jsonb)) \gset
select pg_temp.check(jsonb_array_length(public.get_report(:'r1_id')->'variants') = 1, 'varianta navázána na původní podnět');

-- 10) Bezpečnost: přímý přístup k tabulkám, admin funkce ---------------------
select pg_temp.expect_error('select * from public.reports limit 1', 'permission denied');
select pg_temp.expect_error('select * from public.profiles limit 1', 'permission denied');
select pg_temp.expect_error('select * from public.supports limit 1', 'permission denied');
select pg_temp.expect_error($$update public.categories set name = 'hack' where id = 1$$, 'permission denied');
select pg_temp.expect_error('select public.admin_stats()', 'forbidden');
select pg_temp.expect_error('select public.admin_list_reports()', 'forbidden');
select pg_temp.expect_error($$select public.admin_set_setting('show_demo', 'true')$$, 'forbidden');
select pg_temp.expect_error(format('select public.update_my_report(%L, %L, null, null)', :'r1_id', 'Přepsáno'), 'forbidden');
select pg_temp.check(public.get_my_profile()->>'email' = 'bob@test.local', 'vlastní profil obsahuje vlastní e-mail');
select pg_temp.check(position('franta@example.com' in public.get_report(:'r1_id')::text) = 0, 'detail nezveřejňuje e-mail');
select pg_temp.check(position('franta@example.com' in public.get_map_data()::text) = 0, 'mapová data nezveřejňují e-mail');
select pg_temp.check(position('0000000000f1' in public.get_map_data()::text) = 0, 'mapová data nezveřejňují ID uživatelů');

set role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', false);
select pg_temp.check(jsonb_array_length(public.get_map_data()->'features') >= 8, 'anonymní návštěvník vidí mapu');
select pg_temp.expect_error($$select public.create_report('{}')$$, 'permission denied');

-- 11) Administrace -----------------------------------------------------------
set role authenticated;
select pg_temp.act('00000000-0000-0000-0000-00000000000a');
select pg_temp.check((public.admin_stats()->'totals'->>'reports')::int >= 9, 'statistiky: počet podnětů');
select pg_temp.check((public.admin_stats((select id from public.districts where name = 'Ivančice'))->'totals'->>'reports')::int >= 1, 'statistiky za místní část');
select pg_temp.check(jsonb_array_length(public.admin_list_reports('{"with_contacts":true}')) >= 9, 'admin seznam');
select pg_temp.check(position('franta@example.com' in public.admin_list_reports('{"with_contacts":true}')::text) > 0, 'admin vidí kontakt');

-- sloučení duplicit: Cyrilův bod do původního
select pg_temp.check((public.admin_merge_reports(:'r1_id'::uuid,
  array[:'dup_id'::uuid])->>'merged')::int = 1, 'sloučení duplicity');
select pg_temp.check((public.get_report(:'r1_id')->>'people')::int = 4, 'po sloučení: 4 unikátní lidé');
select pg_temp.check(jsonb_array_length(public.get_report(:'r1_id')->'merged_reports') = 1, 'sloučený záznam zůstává v databázi');

-- stav a jeho zveřejnění
select public.admin_update_report(:'r1_id', '{"status":"forwarded","status_public":true,"status_note":"Předáno odboru dopravy"}');
select pg_temp.act('00000000-0000-0000-0000-0000000000c1');
select pg_temp.check(public.get_report(:'r1_id')->>'status' = 'forwarded', 'veřejný stav viditelný');
select pg_temp.act('00000000-0000-0000-0000-00000000000a');

-- skrytí nevhodného obsahu
select public.admin_update_report(:'line_c', '{"is_hidden":true,"hidden_reason":"test"}');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.get_map_data()->'features') f where f->'properties'->>'t' = 'Kolmá ulice'), 'skrytý podnět není v mapě');

-- kategorie
select pg_temp.check((public.admin_save_category('{"name":"Testovací kategorie","color":"#123456","default_geom":"line"}')->>'id') is not null, 'nová kategorie');
select pg_temp.check((public.admin_delete_category((select (x->>'id')::int from jsonb_array_elements(public.admin_list_categories()) x where x->>'name' = 'Testovací kategorie'))->>'deleted')::boolean, 'smazání nepoužité kategorie');

-- export
select pg_temp.check(jsonb_array_length(public.admin_export_reports(true, false, 5514)) >= 9, 'export S-JTSK');
select pg_temp.check((select (f->'geometry'->'coordinates'->>0)::numeric < -500000
   from jsonb_array_elements(public.admin_export_reports(false, false, 5514)) f where f->'properties'->>'typ_geom' = 'point' limit 1), 'souřadnice v S-JTSK (záporné X)');

-- ukázková data
select pg_temp.check((public.admin_seed_demo(30)->>'created')::int = 40, 'ukázková data vložena (30 + 10 překryvů)');
select pg_temp.check((public.get_public_config()->>'demo_visible')::boolean, 'ukázková data viditelná');
select pg_temp.check((public.admin_delete_demo()->>'deleted')::int = 40, 'ukázková data smazána');
select pg_temp.check(not (public.get_public_config()->>'demo_visible')::boolean, 'po smazání nejsou ukázková data');

-- import GeoJSON (MapHub)
select pg_temp.check((public.admin_import_geojson('{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"title":"Z původní mapy","group":"Původní skupina"},"geometry":{"type":"Point","coordinates":[16.378,49.102]}}]}')->>'imported')::int = 1, 'import GeoJSON');
select pg_temp.check(exists (select 1 from jsonb_array_elements(public.admin_list_categories()) x where x->>'name' = 'Původní skupina' and x->>'source' = 'maphub'), 'import vytvořil původní kategorii');

-- výmaz účtu (GDPR)
select pg_temp.act('00000000-0000-0000-0000-0000000000b1');
select public.delete_my_account();
reset role;
select pg_temp.check(not exists (select 1 from auth.users where id = '00000000-0000-0000-0000-0000000000b1'), 'účet smazán');
select pg_temp.check((select count(*) from public.reports where author_name = 'Anonym') >= 2, 'podněty anonymizovány');

-- návrh nové kategorie (čeká na schválení správcem) --------------------------
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_error($q$select public.create_report('{"category_id":7,"title":"Bez tématu","author_name":"Alice","kind":"point","geometry":{"type":"Point","coordinates":[16.371,49.099]}}')$q$, 'topic_required');
select public.create_report('{"category_id":7,"custom_topic":"Test osvětlení","title":"Tma u lávky","author_name":"Alice","kind":"point","geometry":{"type":"Point","coordinates":[16.371,49.099]}}') as prop \gset
select pg_temp.check(((:'prop')::jsonb->>'pending')::boolean, 'návrh kategorie čeká na schválení');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.get_map_data()->'features') f where f->'properties'->>'id' = (:'prop')::jsonb->>'id'), 'návrh není na veřejné mapě');
select pg_temp.check(exists (select 1 from jsonb_array_elements(public.my_reports()) x where (x->>'pending')::boolean), 'autor vidí návrh jako čekající');
select pg_temp.expect_error(format($q$select public.admin_approve_proposal(%L, null, null, null)$q$, (:'prop')::jsonb->>'id'), 'forbidden');
select pg_temp.act('00000000-0000-0000-0000-00000000000a');
select pg_temp.check((public.admin_approve_proposal(((:'prop')::jsonb->>'id')::uuid, null, 'Test osvětlení', null)->>'category_id') is not null, 'správce schválil novou kategorii');
select pg_temp.check(exists (select 1 from jsonb_array_elements(public.get_public_config()->'categories') c where c->>'name' = 'Test osvětlení'), 'nová kategorie je v nabídce');
select pg_temp.check(not (public.get_report(((:'prop')::jsonb->>'id')::uuid)->>'is_hidden')::boolean, 'podnět je po schválení zveřejněn');
reset role;
delete from public.reports where title = 'Tma u lávky';
delete from public.categories where name = 'Test osvětlení';

-- povinné přihlášení e-mailem ----------------------------------------------
reset role;
insert into auth.users (id, email, is_anonymous) values ('00000000-0000-0000-0000-0000000000f2', null, true) on conflict do nothing;
update public.app_settings set value = 'true' where key = 'contribute_requires_login';
select pg_temp.act('00000000-0000-0000-0000-0000000000f2', true);
select pg_temp.expect_error($q$select public.create_report('{"category_id":2,"title":"Anonymní pokus","author_name":"X","kind":"point","geometry":{"type":"Point","coordinates":[16.37,49.09]}}')$q$, 'login_required');
select pg_temp.act('00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((public.create_report('{"category_id":2,"title":"Přihlášená Alice","author_name":"Alice","kind":"point","geometry":{"type":"Point","coordinates":[16.37,49.09]}}')->>'id') is not null, 'přihlášený může přidat i při povinném přihlášení');
reset role;
update public.app_settings set value = 'false' where key = 'contribute_requires_login';
delete from auth.users where id = '00000000-0000-0000-0000-0000000000f2';

-- úklid --------------------------------------------------------------------
reset role;
delete from public.reports where author_key in (
  '00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000f1') or source = 'demo' or author_name = 'Anonym' or title = 'Z původní mapy';
delete from public.categories where name = 'Původní skupina';
update public.app_settings set value = 'false' where key = 'show_demo';
update public.app_settings set value = 'true' where key = 'contribute_requires_login';
delete from public.flags; delete from public.audit_log;
delete from auth.users where email like '%@test.local';
delete from public.admin_emails where email = 'admin@test.local';
select 'VŠECHNY TESTY PROŠLY' as vysledek;
