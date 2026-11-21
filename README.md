# Ivančice očima pěších a cyklistů

*Společně mapujeme, jak se nám v Ivančicích chodí, jezdí na kole a žije.*

Webová aplikace pro participativní mapování problémů, potřeb a příležitostí v dopravě, mobilitě a veřejném prostoru
Ivančic a místních částí (Letkovice, Alexovice, Budkovice, Řeznovice, Němčice, Hrubšice).

Obyvatelé zakreslují **body, linie a plochy**, podporují podněty ostatních tlačítkem **„Také to vnímám jako problém“**,
kreslí **vlastní prostorové varianty** a v **analytickém zobrazení** vidí, kde se jejich zakreslení překrývají.
Správce má administraci se statistikami, moderací, správou kategorií a **exportem do CSV, GeoJSON a Shapefile (S-JTSK)**.

* Splnění zadání bod po bodu: [docs/SPLNENI-ZADANI.md](docs/SPLNENI-ZADANI.md)
* **Nasazení zdarma krok za krokem (pro spolek): [docs/NASAZENI-ZDARMA.md](docs/NASAZENI-ZDARMA.md)**

---

## Jak aplikace funguje

```
 prohlížeč návštěvníka                        Supabase (zdarma, EU)
┌───────────────────────────┐   HTTPS/API   ┌────────────────────────────────┐
│ statický web (HTML + JS)  │ ────────────► │ PostgreSQL + PostGIS (data,    │
│ – mapa MapLibre + OSM     │               │   analýzy, oprávnění RLS)      │
│ – formuláře, administrace │               │ přihlašování (odkaz z e-mailu) │
│ – export SHP/CSV/GeoJSON  │               │ úložiště fotografií            │
└───────────────────────────┘               └────────────────────────────────┘
   hosting: GitHub Pages / jakýkoli webhosting (zdarma)
```

Web je **čistě statický** – žádný vlastní server. Složku `out/` lze nahrát na GitHub Pages (zdarma, nastaveno
v `.github/workflows/deploy.yml`) nebo na libovolný webhosting přes FTP.

| Vrstva | Použito |
|---|---|
| Frontend | Next.js 15 (statický export), React 19, TypeScript, Tailwind CSS |
| Mapa | MapLibre GL JS, OpenStreetMap, ortofoto ČÚZK (CC BY 4.0), Supercluster |
| Databáze | Supabase – PostgreSQL + PostGIS, Row Level Security |
| Přihlášení | Supabase Auth – anonymní relace + přihlášení odkazem z e-mailu (bez hesla) |
| Fotografie | Supabase Storage (lze vypnout v administraci) |
| Provoz zdarma | GitHub Pages, denní „ping“ proti uspání databáze, noční záloha – vše GitHub Actions |

```
app/                    stránky (mapa, /embed, /o-projektu, /ochrana-osobnich-udaju, /admin/*, /auth/callback)
components/             mapa, přidání podnětu, detail, filtry, účet, administrace
lib/                    klient Supabase, API, geometrie, mapové značky, export SHP/CSV/ZIP
supabase/migrations/    databáze: schéma, oprávnění, funkce, analýzy, výchozí kategorie (spouští se jednou)
supabase/tests/         testy databázových funkcí
supabase/templates/     české šablony e-mailů
.github/workflows/      nasazení webu, udržení databáze v provozu, noční záloha
```

## Bezpečnost a ochrana dat

* Všechny tabulky mají zapnuté **RLS**; veřejnost nemá přímý přístup k tabulkám s podněty, hlasy ani profily.
  Čtení i zápis probíhá přes databázové funkce s validací vstupů.
* Veřejně se zobrazuje jen jméno/přezdívka a **počet** podporovatelů – nikdy e-maily ani identita hlasujících.
* Jeden člověk = jeden hlas; autor se počítá automaticky a sám sebe podpořit nemůže.
* Podpora vyžaduje přihlášení e-mailem (lze vypnout). Podnět lze vložit bez registrace.
* Administrátorská práva ověřuje databáze v každé funkci – včetně exportu dat.
* Každý zásah administrátora se zapisuje do auditního záznamu; sloučené duplicity zůstávají v databázi.

## Prostorové analýzy

Výpočty probíhají v PostGIS (metrická projekce UTM 33N); každý člověk se v jedné analýze počítá jen jednou.

| Analýza | Metoda | Tolerance (nastavitelné) |
|---|---|---|
| Překryvy ploch | zakreslení každého člověka se sjednotí, území se rozřeže na dílčí plochy a u každé se spočítá, kolik lidí ji pokrývá | hranice ±5 m |
| Překryvy linií | úseky 25 m; shoda = jiná linie do 15 m s podobným směrem (±35°), kolmé křížení se nepočítá | 15 m, 35° |
| Shluky bodů | DBSCAN pro body stejné kategorie | 40 m |
| Mapa intenzity | šestiúhelníky 150 m: zakreslení, autoři, unikátní lidé (autoři + podporovatelé) | 150 m |
| Míra shody podnětu | počet dalších lidí se shodným zakreslením stejné kategorie + podíl délky/plochy pokrytý ostatními | dle výše |

## Původní mapa MapHub

Instalace databáze už obsahuje **všech 81 zakreslení z původní mapy** (maphub.net/kristri/ivancice-ocima-pesich-a-cyklistu)
a jejích **5 původních kategorií** – Nebezpečná místa pro pěší a cyklisty; Nepříjemná nebo odpuzující místa;
Nedostatečná obytnost, chybějící vybavení; Bariéra prostupnosti / přerušení; Příjemná trasa nebo místo.
Jsou označeny „MapHub“ a jako autor je uvedena „Původní mapa (MapHub)“ (migrace `…800_maphub_data.sql`,
zdrojová data v `data/maphub-puvodni-mapa.geojson`). Nové kategorie ze zadání tvoří rozšíření původního systému.
Případné pozdější změny na MapHub lze doplnit importem (*Nastavení → Import dat*, export GeoJSON z MapHub).

## Hranice místních částí

Bez nahraných hranic se podnět přiřadí nejbližší místní části. Přesné hranice: na [overpass-turbo.eu](https://overpass-turbo.eu)
spusťte dotaz níže, *Export → GeoJSON*, vlastnost `name` upravte na názvy místních částí v aplikaci
(„Němčice u Ivančic“ → „Němčice“) a soubor nahrajte v *Nastavení → Místní části*.

```
[out:json][timeout:60];
( relation(427621); relation(432675); relation(436328); relation(433103);
  relation(436373); relation(436388); relation(435420); relation(436398); );
out geom;
```

## Testovací provoz

*Administrace → Nastavení → Vložit ukázková data* vloží ~90 smyšlených podnětů (označených „ukázka“, ve veřejné mapě
je pruh „Testovací provoz“). Před spuštěním je smažte jedním tlačítkem; skutečné podněty zůstanou.

## Vývoj

```bash
npm install
cp .env.example .env.local     # doplňte adresu a klíč Supabase
npm run dev                    # http://localhost:3000
npm run build                  # statický web do složky out/
```

Lokální Supabase (vyžaduje Docker): `npx supabase start` a `npx supabase db reset` (použije `supabase/config.toml`).
Testy databáze (jen na vývojové databázi!): `DATABASE_URL=postgresql://... npm test`.

## Rozšíření do budoucna

Každá kategorie má pole `theme` (mobilita, zeleň, bezpečnost, občanská vybavenost…) – nová témata platformy
přidáte v administraci bez programování. Data jsou v PostGIS a lze je připojit přímo do QGIS.
