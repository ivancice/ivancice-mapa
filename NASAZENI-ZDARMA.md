# Nasazení zdarma – návod krok za krokem (pro spolek)

Celé řešení běží na bezplatných službách:

| Co | Služba | Cena |
|---|---|---|
| Databáze, přihlašování, fotografie | **Supabase** – tarif Free | 0 Kč |
| Webové stránky | **GitHub Pages** | 0 Kč |
| Udržení databáze v provozu, zálohy | **GitHub Actions** | 0 Kč |
| Odesílání přihlašovacích e-mailů | **Brevo** (nebo jiný SMTP) – bezplatný tarif | 0 Kč |

Potřebujete jen e-mailovou adresu spolku. Celé nastavení zabere zhruba hodinu. Nic se neinstaluje do počítače
(kromě jednoho volitelného programu pro nahrání souborů na GitHub).

---

## Krok 1 – Databáze (Supabase)

1. Zaregistrujte se na **supabase.com** (ideálně e-mailem spolku).
2. **New project**
   * *Name:* `ivancice-mapa`
   * *Database Password:* vygenerujte a **uložte si ho** (budete ho potřebovat pro zálohy).
   * *Region:* **Central EU (Frankfurt)** – kvůli GDPR.
   * Plán **Free**.
3. Počkejte, až se projekt vytvoří (1–2 minuty).
4. Vlevo **SQL Editor → New query**. Otevřete soubor `supabase/INSTALACE-VSE-V-JEDNOM.sql` z balíčku
   (v Poznámkovém bloku), zkopírujte **celý** obsah, vložte do editoru a klikněte **Run**.
   Výsledek má skončit bez chyby („Success“). Tím se vytvoří celá databáze včetně kategorií.
5. **Administrátor** – v SQL Editoru spusťte (s vaším e-mailem):
   ```sql
   insert into public.admin_emails (email) values ('vas.email@spolek.cz');
   ```
6. **Authentication → Sign In / Providers**
   * *Email* – zapnuto.
   * **Allow anonymous sign-ins – zapnout** (lidé mohou vložit podnět bez registrace).
7. **Project Settings → API** (nebo *API Keys*) – poznamenejte si:
   * **Project URL** (např. `https://abcdefgh.supabase.co`)
   * **anon public** klíč (případně *Publishable key*). Tento klíč je veřejný, nevadí, že bude vidět.

## Krok 2 – Odesílání e-mailů (Brevo)

Vestavěné e-maily Supabase zvládnou jen několik zpráv za hodinu – pro veřejnou mapu nestačí.

1. Zaregistrujte se na **brevo.com** (bezplatný tarif).
2. Ověřte odesílací adresu spolku (Senders) a v *SMTP & API* si zobrazte **SMTP údaje**
   (server `smtp-relay.brevo.com`, port `587`, login a SMTP klíč).
3. V Supabase: **Authentication → Emails → SMTP Settings** → *Enable custom SMTP* a vyplňte:
   * *Sender email:* adresa spolku, *Sender name:* `Ivančice očima pěších a cyklistů`
   * *Host / Port / Username / Password:* údaje z Brevo.
4. **Authentication → Emails → Templates** – vložte české šablony ze složky `supabase/templates/`:
   * *Magic Link* ← `magic_link.html` (předmět: *Přihlášení do mapy Ivančice očima pěších a cyklistů*)
   * *Confirm signup* ← `confirmation.html`
   * *Change Email Address* ← `email_change.html`
5. **Authentication → Rate Limits** – zvyšte *emails sent per hour* např. na 100.

(Místo Brevo lze použít SMTP vašeho e-mailového hostingu – údaje vám sdělí poskytovatel.)

## Krok 3 – Web (GitHub Pages)

1. Zaregistrujte se na **github.com** (bezplatný účet; jako jméno použijte např. zkratku spolku).
2. **New repository** → název `ivancice-mapa`, **Public**, vytvořit.
3. **Nahrání souborů** – vyberte jednu cestu:
   * **GitHub Desktop** (doporučeno, desktop.github.com): *File → Clone repository* → vyberte `ivancice-mapa`,
     do vytvořené složky zkopírujte obsah rozbaleného balíčku (složku `ivancice-mapa`, včetně skryté složky `.github`),
     pak *Commit to main* → *Push origin*.
   * nebo přes web: *Add file → Upload files* a přetáhněte obsah rozbalené složky (GitHub přijme max. 100 souborů
     najednou – nahrajte tedy po složkách; složku `.github` nezapomeňte).
4. **Settings → Pages** → *Build and deployment* → *Source*: **GitHub Actions**.
5. **Settings → Secrets and variables → Actions → záložka Variables → New repository variable** – vytvořte:

   | Název | Hodnota |
   |---|---|
   | `SUPABASE_URL` | Project URL ze Supabase |
   | `SUPABASE_ANON_KEY` | anon / publishable klíč ze Supabase |
   | `SITE_URL` | `https://<váš-github-účet>.github.io/ivancice-mapa` |
   | `BASE_PATH` | `/ivancice-mapa` |
   | `TURNSTILE_SITE_KEY` | *(nepovinné – viz níže)* |

6. **Actions → Nasazení webu → Run workflow.** Po 2–3 minutách je web na adrese ze `SITE_URL`.
   (Každá další změna souborů v repozitáři web automaticky znovu sestaví.)
7. Zpět v **Supabase → Authentication → URL Configuration**:
   * *Site URL:* `https://<váš-github-účet>.github.io/ivancice-mapa`
   * *Redirect URLs:* přidejte `https://<váš-github-účet>.github.io/ivancice-mapa/auth/callback/`

## Krok 4 – Provoz zdarma bez starostí

* **Udržení databáze v provozu:** bezplatný projekt Supabase se po týdnu bez návštěv uspí. Úloha
  *Udržení databáze v provozu* (GitHub Actions) se jednou denně připojí a tomu zabrání. Běží automaticky
  (používá proměnné z kroku 3). Zkontrolovat ji můžete v záložce *Actions*.
  GitHub naplánované úlohy vypne, pokud se v repozitáři 60 dní nic nezmění – pošle o tom e-mail a stačí
  v záložce *Actions* kliknout na **Enable workflow**.
* **Noční záloha:** v *Settings → Secrets and variables → Actions* → záložka **Secrets** (ne Variables!)
  vytvořte `SUPABASE_DB_URL` s hodnotou ze Supabase *Connect → Connection string → URI* (s vloženým heslem
  z kroku 1; použijte variantu *Session pooler*). Záloha se pak každou noc uloží do *Actions* (30 dní).

## Krok 5 – Nastavení v aplikaci

1. Otevřete `…/ivancice-mapa/admin/`, přihlaste se e-mailem z kroku 1.5 (přijde odkaz).
2. **Nastavení → Provoz a texty:** název spolku (*Provozovatel mapy*), web spolku.
3. **Nastavení → Ochrana osobních údajů:** název spolku, sídlo, IČO a kontaktní e-mail – zobrazí se
   v Zásadách zpracování osobních údajů.
4. **Fotografie:** volba *Umožnit přidávání fotografií* – vypnutím šetříte místo (bezplatné úložiště má 1 GB,
   což je cca 3 000 fotografií).
5. **Původní mapa MapHub** (81 zakreslení, 5 kategorií) se nahrála už v kroku 1.4 – nic dalšího není třeba.
6. **Testování:** *Vložit ukázková data* → vyzkoušejte vše na mobilu → **Smazat ukázková data**.
7. **O projektu** (`…/o-projektu/`): odkaz, QR kód pro plakáty a kód pro vložení do webu spolku (iframe).

## Volitelně

* **Ochrana proti robotům (Cloudflare Turnstile, zdarma):** na dash.cloudflare.com → *Turnstile* → přidejte web,
  *Site key* vložte do proměnné `TURNSTILE_SITE_KEY` (GitHub) a *Secret key* do Supabase →
  *Authentication → Attack Protection → CAPTCHA*. Doporučeno, pokud by se objevil spam.
* **Vlastní doména** (např. `mapa.spolek.cz`): u správce domény vytvořte záznam `CNAME mapa → <účet>.github.io`,
  na GitHubu přidejte proměnnou `CUSTOM_DOMAIN=mapa.spolek.cz`, změňte `SITE_URL=https://mapa.spolek.cz`
  a `BASE_PATH` nastavte prázdné; spusťte znovu *Nasazení webu* a v *Settings → Pages* zapněte *Enforce HTTPS*.
  Nakonec upravte *Site URL* a *Redirect URLs* v Supabase.
* **Jiný hosting:** příkazem `npm run build` vznikne složka `out/`, kterou lze nahrát přes FTP na libovolný
  webhosting (pokud web neběží v kořeni domény, nastavte před sestavením `NEXT_PUBLIC_BASE_PATH`).

## Kdy by se vyplatilo platit

Pokud by mapa sloužila dlouhodobě a chtěli byste jistotu automatických denních záloh přímo u poskytovatele
a vyšší limity, stačí v Supabase přejít na tarif Pro (cca 25 USD/měsíc). Nic jiného se nemění.

## Kontrolní seznam před spuštěním

- [ ] přihlášení e-mailem funguje (odkaz dorazí do 1 minuty, i do mobilního e-mailu)
- [ ] přidání bodu, linie a plochy z mobilu (případně s fotografií)
- [ ] podpora podnětu a její odebrání – číslo ve značce se mění
- [ ] „Zakreslit po svém“ (vlastní varianta)
- [ ] analytické zobrazení: překryvy ploch a linií, mapa intenzity
- [ ] administrace: změna stavu, skrytí, sloučení duplicit, moderace
- [ ] export SHP do QGIS
- [ ] vyplněn provozovatel a kontakt v zásadách ochrany osobních údajů
- [ ] smazána ukázková data
