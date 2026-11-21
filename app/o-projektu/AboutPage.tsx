'use client';
import Link from 'next/link';
import { usePublicConfig } from '@/lib/useConfig';
import ShareTools from '@/components/pages/ShareTools';


export default function About() {
  const cfg = usePublicConfig();
  const s = cfg?.settings ?? {};
  return (
    <main className="mx-auto max-w-3xl px-5 py-8">
      <Link href="/" className="text-sm font-semibold text-brand-700">← Zpět na mapu</Link>
      <h1 className="mt-4 text-2xl font-extrabold text-brand-800">{(s.intro_title as string) ?? 'Ivančice očima pěších a cyklistů'}</h1>
      <p className="mt-1 text-lg italic text-ink-soft">{(s.intro_subtitle as string) ?? ''}</p>
      <div className="prose-cz mt-4 text-[15px] leading-relaxed">
        <p>{(s.intro_text as string) ?? ''}</p>
        <h2>Jak mapa funguje</h2>
        <ul>
          <li><b>Přidejte podnět</b> – zvolte téma, zakreslete bod (konkrétní místo), linii (trasu, úsek) nebo plochu (území) a krátce popište problém či návrh.</li>
          <li><b>Podpořte existující podněty</b> tlačítkem „Také to vnímám jako problém“. Číslo ve značce ukazuje počet unikátních lidí, které místo trápí. Každý může podnět podpořit jen jednou.</li>
          <li><b>Zakreslete vlastní variantu</b> – pokud vidíte rozsah problému nebo průběh trasy jinak. Původní zakreslení zůstávají zachována.</li>
          <li><b>Analytické zobrazení</b> ukazuje, kde se zakreslení různých lidí překrývají, a mapu intenzity problémů. Každý člověk se v analýze počítá jen jednou.</li>
        </ul>
        <h2>Kategorie</h2>
        <ul>
          {(cfg?.categories ?? []).map((c) => (
            <li key={c.id}><span className="mr-1 inline-block h-3 w-3 rounded-full align-middle" style={{ backgroundColor: c.color }} /> <b>{c.name}</b>{c.description ? ` – ${c.description}` : ''}</li>
          ))}
        </ul>
        <h2>Co se s podněty stane</h2>
        <p>Podněty prověří správce mapy a předá je městu. U podnětů může být zveřejněn stav řešení (nový, prověřuje se, předán městu, v řešení, vyřešeno). Data poslouží jako podklad pro dopravní koncepce, územní studie a projekty veřejných prostranství.</p>
        <h2>Kdo mapu provozuje</h2>
        <p>
          {(s.operator_name as string) || 'Provozovatel'}
          {(s.operator_url as string) ? <> – <a href={s.operator_url as string} target="_blank" rel="noopener">{s.operator_url as string}</a></> : null}.
          Výsledky mapování předáme Městu Ivančice jako podklad pro plánování.
        </p>
        <p><Link href="/ochrana-osobnich-udaju">Zásady zpracování osobních údajů</Link></p>
      </div>
      <h2 className="mt-8 text-lg font-bold">Sdílejte mapu</h2>
      <ShareTools />
      <p className="mt-10 text-xs text-ink-faint">Mapové podklady © přispěvatelé OpenStreetMap, ortofoto © ČÚZK.</p>
    </main>
  );
}
