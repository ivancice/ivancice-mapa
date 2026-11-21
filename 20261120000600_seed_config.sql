-- =====================================================================
-- Výchozí konfigurace: nastavení, kategorie, podkategorie, místní části
-- (bez smyšlených podnětů – ukázková data se vkládají jen na vyžádání
--  v administraci a jsou označena is_demo = true)
-- =====================================================================

insert into public.app_settings (key, value, is_public, description) values
  ('contributions_open',        'true',  true,  'Přijímají se nové podněty'),
  ('support_requires_verified', 'true',  true,  'Podpora podnětu vyžaduje přihlášení e-mailem (ověřená identita)'),
  ('contribute_requires_login', 'true',  true,  'Přidávat podněty a komentáře mohou jen uživatelé přihlášení e-mailem (pak lze v Supabase vypnout anonymní přihlášení)'),
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
insert into public.categories (id, code, name, description, color, icon, default_geom, sort_order, allow_custom_topic, requires_approval) values
  (1, 'nebezpecna-mista',   'Nebezpečná místa',                      'Přechody, chodníky, křižovatky a úseky nebezpečné pro pěší a cyklisty', '#dc2626', 'shield',         'point',   10, false, false),
  (2, 'cyklisticka-doprava','Cyklistická doprava',                   'Chybějící cyklotrasy, napojení, stojany na kola',                       '#0891b2', 'bike',           'line',    20, false, false),
  (3, 'parkovani-auta',     'Parkování a automobilová doprava',      'Parkování, průjezd, rychlost aut, křižovatky',                          '#ea580c', 'car',            'point',   30, false, false),
  (4, 'bariery',            'Bariéry a přerušené trasy',             'Chybějící propojení a průchody, bariéry, nepřístupná místa',            '#7c3aed', 'route',          'line',    40, false, false),
  (5, 'neprijemna-mista',   'Nepříjemná místa a pocit bezpečí',     'Kde se necítíte dobře nebo bezpečně a co tam chybí',                     '#ca8a04', 'bench',          'polygon', 50, false, false),
  (6, 'prijemna-mista',     'Příjemná místa a trasy',                'Kudy a kde se chodí a jezdí dobře – co zachovat a rozvíjet',            '#16a34a', 'trees',          'line',    60, false, false),
  (7, 'navrh-kategorie',    'Návrh nové kategorie',                  'Chybí vám kategorie? Navrhněte ji a zakreslete místo – zobrazí se po schválení správcem', '#64748b', 'lightbulb', 'point', 1000, true, true)
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.categories', 'id'), greatest((select max(id) from public.categories), 1));

insert into public.subcategories (category_id, name, default_geom, sort_order) values
  (1, 'Nebezpečný přechod', 'point', 10),
  (1, 'Chybějící přechod', 'point', 20),
  (1, 'Nebezpečné místo pro chodce', 'point', 30),
  (1, 'Chybějící nebo úzký chodník', 'line', 40),
  (1, 'Nebezpečný úsek pro cyklisty', 'line', 50),
  (1, 'Nebezpečné místo pro děti', 'point', 90),
  (2, 'Chybějící cyklopropojení', 'line', 10),
  (2, 'Chybějící cyklistická infrastruktura', 'line', 20),
  (2, 'Problematické napojení na cyklotrasu', 'point', 30),
  (2, 'Chybějící stojany na kola', 'point', 40),
  (2, 'Konflikt pěších a cyklistů', 'point', 50),
  (3, 'Nedostatek parkovacích míst', 'polygon', 10),
  (3, 'Nevhodně organizované parkování', 'polygon', 20),
  (3, 'Nelegální nebo nebezpečné parkování', 'point', 30),
  (3, 'Problematický průjezd', 'line', 40),
  (3, 'Nadměrná rychlost', 'line', 50),
  (3, 'Konfliktní křižovatka', 'point', 60),
  (4, 'Přerušená trasa', 'line', 10),
  (4, 'Chybějící pěší propojení', 'line', 20),
  (4, 'Chybějící průchod', 'point', 30),
  (4, 'Chybějící propojení s krajinou', 'line', 40),
  (4, 'Chybějící bezbariérový přístup', 'point', 50),
  (4, 'Vysoký obrubník', 'point', 60),
  (4, 'Nevhodný povrch', 'line', 70),
  (4, 'Nepřístupná zastávka', 'point', 80),
  (5, 'Nepříjemné nebo odpuzující místo', 'polygon', 10),
  (5, 'Necítím se tu bezpečně (ve dne nebo v noci)', 'point', 20),
  (5, 'Neosvětlené nebo špatně osvětlené místo', 'point', 30),
  (5, 'Opuštěné místo, podchod nebo zákoutí', 'point', 40),
  (5, 'Nedostatečná obytnost', 'polygon', 50),
  (5, 'Chybějící stromy a stín', 'polygon', 60),
  (5, 'Chybějící lavičky a mobiliář', 'point', 70),
  (5, 'Nevyužité prostranství / místo k revitalizaci', 'polygon', 80),
  (5, 'Hluk a provoz aut', 'polygon', 90),
  (6, 'Příjemná pěší trasa', 'line', 10),
  (6, 'Příjemná cyklotrasa', 'line', 20),
  (6, 'Příjemné místo k pobytu', 'polygon', 30),
  (6, 'Zeleň a příroda', 'polygon', 40),
  (6, 'Místo, které stojí za zachování', 'point', 50)
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
