'use client';
import Link from 'next/link';
import { usePublicConfig } from '@/lib/useConfig';


export default function Privacy() {
  const cfg = usePublicConfig();
  const s = cfg?.settings ?? {};
  const controller = (s.privacy_controller as string) || 'Správce mapy (doplňte v administraci)';
  const contact = (s.privacy_contact as string) || '(doplňte kontakt)';
  const dpo = (s.privacy_dpo as string) || '';
  const retention = (s.retention_text as string) || '';

  return (
    <main className="mx-auto max-w-3xl px-5 py-8">
      <Link href="/" className="text-sm font-semibold text-brand-700">← Zpět na mapu</Link>
      <h1 className="mt-4 text-2xl font-extrabold">Zásady zpracování osobních údajů</h1>
      <div className="prose-cz mt-4 text-[15px] leading-relaxed text-ink">
        <p>Tyto informace vysvětlují, jak aplikace <b>Ivančice očima pěších a cyklistů</b>, kterou provozuje {(s.operator_name as string) || 'provozovatel uvedený níže'}, zpracovává osobní údaje v souladu s nařízením (EU) 2016/679 (GDPR) a zákonem č. 110/2019 Sb.</p>

        <h2>Správce osobních údajů (provozovatel)</h2>
        <p>{controller}<br />Kontakt pro dotazy a uplatnění práv: {contact}{dpo && <><br />Pověřenec pro ochranu osobních údajů: {dpo}</>}</p>

        <h2>Jaké údaje zpracováváme a proč</h2>
        <ul>
          <li><b>Jméno nebo přezdívka</b> (povinné) – zobrazuje se veřejně u vašich podnětů a komentářů. Můžete použít přezdívku.</li>
          <li><b>Obsah podnětů</b> – zakreslení v mapě, popis, návrh řešení, fotografie, četnost pohybu v místě. Zveřejňuje se v mapě a slouží k vyhodnocení potřeb obyvatel při plánování města.</li>
          <li><b>E-mail</b> (nepovinný) – nikdy se nezveřejňuje. Slouží k přihlášení ověřovacím odkazem, k případnému doplňujícímu dotazu k vašemu podnětu a – pouze se samostatným souhlasem – k zasílání informací o výsledcích mapování a novinkách.</li>
          <li><b>Technické údaje</b> – pseudonymní identifikátor relace (pro zajištění, že každý podpoří podnět jen jednou, a pro ochranu proti spamu), čas vložení. IP adresy jsou zpracovávány poskytovatelem hostingu pouze pro zajištění bezpečnosti provozu.</li>
        </ul>

        <h2>Právní základ</h2>
        <ul>
          <li>Oprávněný zájem provozovatele – uskutečnění participativního mapování a předání jeho souhrnných výsledků jako podkladu pro plánování rozvoje Ivančic (čl. 6 odst. 1 písm. f) GDPR). Proti tomuto zpracování můžete vznést námitku.</li>
          <li>Souhlas – zasílání informací o výsledcích a novinkách (čl. 6 odst. 1 písm. a) GDPR). Souhlas je dobrovolný, samostatný a lze jej kdykoli odvolat v nastavení účtu nebo e-mailem správci.</li>
          <li>Oprávněný zájem – ochrana aplikace proti zneužití a spamu (čl. 6 odst. 1 písm. f) GDPR).</li>
        </ul>

        <h2>Kdo má k údajům přístup</h2>
        <p>Veřejnost vidí pouze obsah podnětů a jméno či přezdívku. Počet podporovatelů se zobrazuje jen jako číslo – kdo podnět podpořil, se nezveřejňuje. Úplné údaje vidí pouze pověření administrátoři provozovatele. Zpracovateli jsou poskytovatelé technické infrastruktury (databáze a přihlašování Supabase – servery v EU, hosting webu, služba pro odesílání e-mailů). Souhrnné výsledky mapování (podněty, zakreslení, počty podpor – bez e-mailů a dalších kontaktních údajů) může provozovatel předat Městu Ivančice a zpracovatelům územních a dopravních studií.</p>

        <h2>Fotografie</h2>
        <p>Nahrávejte prosím jen fotografie, na kterých nejsou rozpoznatelné osoby ani registrační značky. Údaje o poloze (EXIF) se z fotografií při nahrání odstraňují. Nevhodné fotografie správce skryje nebo smaže.</p>

        <h2>Doba uchování</h2>
        <p>{retention || 'Údaje uchováváme po dobu nezbytnou k vyhodnocení participativního mapování.'}</p>

        <h2>Vaše práva</h2>
        <p>Máte právo na přístup k údajům, jejich opravu, výmaz, omezení zpracování, vznést námitku a odvolat souhlas. Svůj účet můžete kdykoli smazat sami v aplikaci (Můj účet → Smazat účet a údaje) – smažou se kontaktní údaje a podpory, podněty zůstanou v mapě anonymně. Máte také právo podat stížnost u Úřadu pro ochranu osobních údajů (www.uoou.cz).</p>

        <h2>Cookies a místní úložiště</h2>
        <p>Aplikace používá pouze technicky nezbytné cookies a místní úložiště prohlížeče pro udržení přihlášení a zapamatování, že jste viděli úvodní nápovědu. Nepoužíváme reklamní ani analytické cookies třetích stran. Mapové podklady se načítají ze serverů OpenStreetMap a ČÚZK.</p>
      </div>
    </main>
  );
}
