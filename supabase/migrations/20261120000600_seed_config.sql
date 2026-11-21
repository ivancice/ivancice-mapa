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
