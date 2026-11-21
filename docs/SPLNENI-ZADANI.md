# Splnění zadání – přehled po bodech

Legenda: ✅ hotovo a ověřeno testem · ☑️ hotovo · ⚠️ vyžaduje doplnění na straně provozovatele

| § | Požadavek | Stav | Kde / jak |
|---|---|---|---|
| 1 | Body, linie, plochy; hlasování; varianty; překryvy; analýzy; export | ✅ | celá aplikace, viz níže |
| 1 | Propojení s databází, připravenost ke spuštění | ✅ | Supabase/PostgreSQL + PostGIS, migrace v `supabase/migrations` |
| 2 | Název, podtitulek, přátelský a mobilní vzhled, barvy kategorií | ✅ | texty editovatelné v administraci; paleta kategorií ověřena na rozlišitelnost pro barvoslabé (+ ikony a popisky) |
| 2 | Přidání podnětu během desítek sekund | ✅ | 3 kroky: téma → klepnutí do mapy → název + jméno → Odeslat |
| 3 | OpenStreetMap, střed na Ivančice + místní části | ✅ | na počítači výřez celého území, na mobilu přiblížení na město; nastavitelné |
| 3 | Plynulý zoom, mobil i PC, vrstvy, filtry | ✅ | MapLibre GL, panel *Vrstvy a filtry* |
| 3 | Letecký snímek s licencí | ✅ | ortofoto ČÚZK (otevřená data, CC BY 4.0), přepínač *Letecká / Mapa* |
| 3 | Překryvy a intenzita | ✅ | režim *Analýza* |
| 4 | Bod / linie / plocha, doporučený typ u kategorie, možnost změnit | ✅ | výchozí typ u kategorie i podkategorie; přepínač Bod/Linie/Plocha při kreslení; zpět, smazat, délka/výměra |
| 5 | Kategorie a podkategorie dle zadání | ✅ | 7 kategorií, 35 podkategorií (migrace `…600_seed_config.sql`) |
| 5 | Převzetí původních kategorií a zakreslení z MapHub | ✅ | **všech 81 zakreslení a 5 původních kategorií je součástí instalace** (označeno „MapHub“); pozdější změny lze doplnit importem GeoJSON exportu z MapHub v administraci |
| 5 | Správa kategorií: přidat/odebrat, názvy, podkategorie, barvy, ikony, typ geometrie, pořadí | ✅ | *Administrace → Kategorie* (použité kategorie se jen deaktivují, data zůstanou) |
| 6 | Povinné: kategorie, název, jméno; nepovinné: komentář, foto, řešení, e-mail | ✅ | formulář; validace i v databázi |
| 6 | Otázka „Jak často se na tomto místě pohybujete?“ | ✅ | 4 možnosti, ve statistikách i exportu |
| 6 | Foto z mobilu (fotoaparát) i galerie | ✅ | tlačítka *Vyfotit* / *Z galerie*; zmenšení na 1600 px, odstranění EXIF/GPS; fotky lze v administraci vypnout |
| 6 | Potvrzení o přidání | ✅ | dialog s číslem podnětu a odkazem ke sdílení |
| 7 | Povinná přezdívka, nepovinný e-mail, e-mail neveřejný | ✅ | ověřeno testy (e-mail ani ID uživatelů nejsou ve veřejných datech) |
| 7 | Dobrovolný odběr informací se samostatným souhlasem | ✅ | samostatné zaškrtávací pole; čas udělení souhlasu; export odběratelů pro správce |
| 7 | Zásady ochrany osobních údajů | ✅ | `/ochrana-osobnich-udaju`; ⚠️ doplnit správce a kontakt v Nastavení |
| 7 | Přihlášení bez hesla (magic link) | ✅ | Supabase Auth; anonymní relace se po ověření e-mailu převede na účet bez ztráty příspěvků |
| 7–8 | Spolehlivá identifikace, 1 hlas na podnět | ✅ | hlasování jen ověřeným e-mailem (lze vypnout), unikátní klíč v DB |
| 8 | Tlačítko „Také to vnímám jako problém“, odebrání podpory, komentář a foto | ✅ | detail podnětu |
| 8 | Veřejně jen počet podporovatelů | ✅ | |
| 8 | Upozornění na blízké podobné podněty, podpořit / detail / přesto vytvořit | ✅ | stejná kategorie do 60 m (nastavitelné); nic se automaticky neslučuje |
| 9 | Vlastní prostorová varianta, zachování původních zakreslení, nelze přepsat cizí | ✅ | „Zakreslit po svém“ v detailu; varianta odkazuje na původní; autor smí upravit jen text svého podnětu |
| 9A | Překryvy ploch: průhlednost, počet unikátních uživatelů na části území, sytost | ✅ | PostGIS polygonizace, tolerance 5 m; test: 3 lidé, opakované zakreslení stejného člověka se nepočítá |
| 9B | Překryvy linií: výraznější úseky, počet lidí, míra shody | ✅ | úseky 25 m, tolerance 15 m + směr ±35° (kolmé křížení se nepočítá – ověřeno testem) |
| 9C | Shlukování bodů stejné kategorie, počet podnětů i unikátních podporovatelů | ✅ | shluky v mapě po kategoriích: velké číslo = podněty, odznak = unikátní lidé |
| 9D | Rozlišení autorů / podporovatelů / objektů / překryvu, žádné dvojí započítání | ✅ | v detailu, statistikách i exportu (`n_autoru`, `n_podpor`, `n_lidi`, `shoda_lidi`) |
| 10 | Značky ve tvaru kapky s počtem unikátních podporovatelů, barva dle kategorie, větší při více hlasech | ✅ | kresleno na canvas; linie a plochy mají odznak s číslem |
| 10 | Shlukování při oddálení, jednotlivé značky při přiblížení | ✅ | Supercluster po kategoriích |
| 11 | Detail: vše dle zadání + další zakreslení v lokalitě | ✅ | „Další zakreslení zde“ (150 m) zvýrazní okolí v mapě |
| 12 | Filtry: kategorie, typ, min. podporovatelé, míra shody, vrstvy, legenda | ✅ | + filtr místní části a stavu řešení |
| 12 | Analytické vrstvy (7 druhů) a přepínání běžné/analytické zobrazení | ✅ | intenzita, počet zakreslení, podporovatelé, překryvy ploch, překryvy linií, hustota bodů, heatmapa kategorií |
| 13 | Zabezpečená administrace | ✅ | role v DB, kontrola v každé funkci; testy odmítnutí |
| 13 | Mapa i seznam, editace, moderace, skrytí, sloučení se zachováním dat, stavy, statistiky, filtry, export, analytické výstupy, koncentrace | ✅ | `/admin/*`; sloučení zachová záznamy, autory a komentáře |
| 13 | Stavy Nový…Vyřešeno, veřejné jen pokud povolí | ✅ | přepínač „Zobrazit stav veřejně“ + veřejná poznámka |
| 14 | Dashboard se všemi ukazateli, celé Ivančice i místní části | ✅ | `/admin` |
| 15 | Export CSV, GeoJSON, SHP s atributy; původní zakreslení i analytické vrstvy; pro QGIS | ✅ | ověřeno GDAL/ogrinfo; S-JTSK (EPSG:5514), WGS 84, UTM 33N; UTF-8 (.cpg), .prj |
| 16 | Next.js, MapLibre, OSM, Supabase/PostGIS, Supabase Auth, cloudové úložiště | ✅ | web je statický (GitHub Pages / libovolný hosting zdarma), data v Supabase |
| 16 | Data jen v databázi, ne v prohlížeči | ✅ | v prohlížeči jen přihlašovací relace a příznak úvodní nápovědy |
| 16 | Zabezpečení, spam, osobní údaje, zálohy, rychlost, rozšiřitelnost | ✅ | RLS + RPC, limity, honeypot, Turnstile; noční záloha a udržení provozu přes GitHub Actions; mezipaměť analýz |
| 17 | Vlastní URL, doména, iframe, sdílení, QR kód, bez instalace | ✅ | `/embed`, `/o-projektu` (QR + kód iframe); sdílení odkazu na konkrétní podnět (`?p=`) i výřez mapy (`?lon=&lat=&z=`); PWA manifest |
| 18 | Nahlášení nevhodného obsahu, moderace fotek, GDPR texty | ✅ | nahlášení podnětu/komentáře/fotky, fronta moderace; výmaz účtu uživatelem |
| 19 | Testovací prostředí s ukázkovými daty, smazatelné; nevydávat smyšlené za skutečné | ✅ | ukázková data označena, viditelný pruh „Testovací provoz“, mazání jedním tlačítkem |
| 19 | Ověření hlavních procesů | ✅ | viz níže |
| 20 | Rozšiřitelnost na další témata | ✅ | pole `theme` u kategorií, kategorie bez programování |

## Ověření (provedeno při vývoji)

* **Databáze:** 72 automatických kontrol (`supabase/tests/rpc_tests.sql`) na čisté databázi PostgreSQL 16 + PostGIS 3.4.
* **Prohlížeč (Chrome, mobil 390×844 i desktop):** anonymní přidání bodu s fotkou → přihlášení magic linkem →
  podpora (číslo ve značce 1 → 2), odebrání a opětovná podpora → komentář → vlastní varianta (linie) →
  upozornění na blízký podnět → dvě překrývající se plochy dvou lidí (překryv = 2) → analytické zobrazení →
  administrace (dashboard, změna veřejného stavu, nahlášení a skrytí komentáře) → export 7 kombinací vrstev/formátů →
  převod příspěvků anonymní relace po přihlášení. Vše prošlo – jak pro web v kořeni domény, tak pro umístění v podadresáři (GitHub Pages).
* **Výkon:** 600 podnětů – mapová data 30 ms, analýzy 0,1–2 s při prvním výpočtu, poté z mezipaměti (≈2 ms).

Pozn.: testy v prohlížeči běžely proti lokální testovací náhradě Supabase API (skutečná databáze se všemi funkcemi
a oprávněními, zjednodušená vrstva přihlašování). Před spuštěním proto projděte kontrolní seznam v README na reálném
Supabase projektu – zejména doručování e-mailů.

## Na co nezapomenout před spuštěním

Postup nasazení zdarma: [NASAZENI-ZDARMA.md](NASAZENI-ZDARMA.md).

1. Doplnit provozovatele (spolek), sídlo, IČO a kontakt (*Nastavení*).
2. Nastavit vlastní SMTP (např. Brevo zdarma) a české e-mailové šablony.
3. (Původní data z MapHub jsou už součástí instalace.)
4. Nahrát hranice místních částí (pro přesné statistiky).
5. Smazat ukázková data.
