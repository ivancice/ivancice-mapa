'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
import { adminApi, type AdminStats } from '@/lib/adminApi';
import { useAdmin } from '@/components/admin/AdminShell';
import { errorMessage } from '@/lib/api';
import { Spinner, inputCls } from '@/components/ui';
import { FREQUENCY_LABEL, KIND_LABEL, STATUS_LABEL, type Frequency, type GeomKind, type ReportStatus } from '@/lib/types';

function Tile({ label, value, hint }: { label: string; value: number | string; hint?: string }) {
  return (
    <div className="rounded-2xl bg-white p-4 shadow-sm">
      <div className="text-xs font-semibold text-ink-soft">{label}</div>
      <div className="mt-1 text-2xl font-extrabold tabular-nums text-ink">{value}</div>
      {hint && <div className="mt-0.5 text-[11px] text-ink-faint">{hint}</div>}
    </div>
  );
}

/** Vodorovný sloupcový graf s přímými popisky (barva = identita kategorie, text v neutrální barvě) */
function Bars({ rows, unit }: { rows: { label: string; value: number; color?: string; sub?: string }[]; unit?: string }) {
  const max = Math.max(1, ...rows.map((r) => r.value));
  return (
    <ul className="space-y-2.5">
      {rows.map((r) => (
        <li key={r.label} title={`${r.label}: ${r.value}${unit ? ' ' + unit : ''}${r.sub ? ` (${r.sub})` : ''}`}>
          <div className="flex justify-between gap-2 text-sm">
            <span className="truncate">{r.label}</span>
            <span className="shrink-0 font-semibold tabular-nums">{r.value}{r.sub && <span className="ml-1 font-normal text-ink-faint">{r.sub}</span>}</span>
          </div>
          <div className="mt-1 h-2.5 rounded bg-slate-100">
            <div className="h-full rounded" style={{ width: `${(r.value / max) * 100}%`, backgroundColor: r.color ?? '#1d7559', minWidth: r.value ? 4 : 0 }} />
          </div>
        </li>
      ))}
    </ul>
  );
}

function Card({ title, children, className }: { title: string; children: React.ReactNode; className?: string }) {
  return (
    <section className={`rounded-2xl bg-white p-4 shadow-sm ${className ?? ''}`}>
      <h2 className="mb-3 text-sm font-bold">{title}</h2>
      {children}
    </section>
  );
}

export default function Dashboard() {
  const { config } = useAdmin();
  const [district, setDistrict] = useState<number | null>(null);
  const [demo, setDemo] = useState<boolean | null>(null);
  const [s, setS] = useState<AdminStats | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    setS(null);
    adminApi.stats(district, demo).then(setS).catch((e) => setErr(errorMessage(e)));
  }, [district, demo]);

  const [pending, setPending] = useState(0);
  useEffect(() => { adminApi.reports({ visibility: 'pending', limit: 500 }).then((x) => setPending(x.length)).catch(() => {}); }, []);

  const cat = (id: number) => config.categories.find((c) => c.id === id);
  if (err) return <p className="text-red-600">{err}</p>;

  return (
    <div className="space-y-4">
      {pending > 0 && (
        <Link href="/admin/podnety/?v=pending" className="block rounded-2xl bg-amber-100 p-3 text-sm text-amber-900">
          <b>{pending} {pending === 1 ? 'návrh nové kategorie čeká' : 'návrhů nových kategorií čeká'} na schválení.</b> Zobrazit →
        </Link>
      )}
      <div className="flex flex-wrap items-end gap-3">
        <h1 className="mr-auto text-xl font-extrabold">Přehled a statistiky</h1>
        <label className="text-sm font-semibold">Území
          <select className={`${inputCls} mt-1 py-2`} value={district ?? ''} onChange={(e) => setDistrict(e.target.value ? Number(e.target.value) : null)}>
            <option value="">Celé Ivančice</option>
            {config.districts.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
          </select>
        </label>
        <label className="text-sm font-semibold">Data
          <select className={`${inputCls} mt-1 py-2`} value={demo === null ? '' : demo ? '1' : '0'} onChange={(e) => setDemo(e.target.value === '' ? null : e.target.value === '1')}>
            <option value="">Dle nastavení</option>
            <option value="0">Jen skutečná</option>
            <option value="1">Včetně ukázkových</option>
          </select>
        </label>
      </div>
      {!s ? <div className="flex justify-center py-16"><Spinner /></div> : (
        <>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-6">
            <Tile label="Podněty celkem" value={s.totals.reports} hint={`${s.totals.points} bodů · ${s.totals.lines} linií · ${s.totals.polygons} ploch`} />
            <Tile label="Zapojení lidé" value={s.totals.people} hint="autoři, podporovatelé a komentující (unikátně)" />
            <Tile label="Autoři zakreslení" value={s.totals.authors} />
            <Tile label="Unikátní podporovatelé" value={s.totals.supporters} hint={`${s.totals.supports} podpor celkem`} />
            <Tile label="Podněty se shodou" value={s.totals.with_overlap} hint="jiný člověk zakreslil totéž" />
            <Tile label="Vlastní varianty" value={s.totals.variants} />
            <Tile label="Komentáře" value={s.totals.comments} />
            <Tile label="Fotografie" value={s.totals.photos} />
            <Tile label="Délka linií" value={`${String(s.totals.line_km).replace('.', ',')} km`} />
            <Tile label="Plocha území" value={`${String(s.totals.polygon_ha).replace('.', ',')} ha`} />
            <Tile label="Odběratelé novinek" value={s.totals.newsletter} />
            <Tile label="K moderaci" value={s.totals.open_flags} hint={`${s.totals.hidden} skrytých · ${s.totals.merged} sloučených`} />
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card title="Podněty podle kategorií">
              <Bars rows={s.by_category.filter((c) => c.reports > 0 || cat(c.category_id)).map((c) => ({ label: c.name, value: c.reports, color: c.color, sub: `· ${c.people} lidí` }))} />
            </Card>
            <Card title="Podle místních částí">
              <Bars rows={s.by_district.map((d) => ({ label: d.name, value: d.reports, sub: `· ${d.people} lidí` }))} />
              <p className="mt-3 text-[11px] text-ink-faint">Bez nahraných hranic katastrů se podnět přiřazuje k nejbližšímu středu místní části (Nastavení → Místní části).</p>
            </Card>
            <Card title="Poměr bodových, liniových a plošných podnětů">
              <Bars rows={(['point', 'line', 'polygon'] as GeomKind[]).map((k) => ({ label: KIND_LABEL[k], value: s.by_kind?.[k] ?? 0, sub: s.totals.reports ? `· ${Math.round(((s.by_kind?.[k] ?? 0) / s.totals.reports) * 100)} %` : '' }))} />
            </Card>
            <Card title="Přehled prostorové shody zakreslení">
              <table className="w-full text-sm">
                <thead><tr className="text-left text-xs text-ink-soft"><th className="py-1">Typ</th><th>Podnětů</th><th>Se shodou</th><th>Prům. podíl shody</th></tr></thead>
                <tbody>
                  {s.agreement_summary.map((a) => (
                    <tr key={a.kind} className="border-t border-slate-100"><td className="py-1.5">{KIND_LABEL[a.kind]}</td><td className="tabular-nums">{a.reports}</td><td className="tabular-nums">{a.with_overlap}</td><td className="tabular-nums">{a.avg_agreement != null ? `${Math.round(a.avg_agreement * 100)} %` : '–'}</td></tr>
                  ))}
                </tbody>
              </table>
              <p className="mt-2 text-[11px] text-ink-faint">Shoda = jiný člověk zakreslil v toleranci stejnou nebo překrývající se geometrii stejné kategorie. Podíl = část délky/plochy pokrytá zakresleními ostatních.</p>
            </Card>
            <Card title="Nejvíce podporované podněty">
              <ol className="space-y-1.5 text-sm">
                {s.top_supported.map((r, i) => (
                  <li key={r.id} className="flex items-center gap-2">
                    <span className="w-5 text-right text-xs text-ink-faint">{i + 1}.</span>
                    <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ backgroundColor: cat(r.category_id)?.color }} />
                    <Link href={`/?p=${r.id}`} target="_blank" className="min-w-0 flex-1 truncate hover:underline">{r.title}</Link>
                    <span className="shrink-0 font-semibold tabular-nums">{r.people}</span>
                  </li>
                ))}
              </ol>
            </Card>
            <Card title="Nejčastěji označovaná místa">
              <ol className="space-y-1.5 text-sm">
                {s.hotspots.length === 0 && <li className="text-ink-soft">Zatím žádné shluky bodů (2+ podněty stejné kategorie do 40 m).</li>}
                {s.hotspots.map((h, i) => (
                  <li key={i} className="flex items-center gap-2">
                    <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ backgroundColor: cat(h.properties.category_id)?.color }} />
                    <span className="min-w-0 flex-1 truncate">{cat(h.properties.category_id)?.name}: {h.properties.reports} podnětů</span>
                    <span className="shrink-0 text-xs text-ink-soft">{h.properties.people} lidí</span>
                    <Link className="shrink-0 text-xs font-semibold text-brand-700" href={`/admin/mapa?lon=${h.geometry.coordinates[0]}&lat=${h.geometry.coordinates[1]}`}>mapa</Link>
                  </li>
                ))}
              </ol>
              {s.top_agreement.length > 0 && (
                <>
                  <h3 className="mb-1 mt-4 text-xs font-bold text-ink-soft">Nejvyšší shoda zakreslení</h3>
                  <ol className="space-y-1 text-sm">
                    {s.top_agreement.slice(0, 8).map((r) => (
                      <li key={r.id} className="flex gap-2"><Link href={`/?p=${r.id}`} target="_blank" className="min-w-0 flex-1 truncate hover:underline">{r.title}</Link><span className="shrink-0 text-xs text-ink-soft">+{r.overlap_people} lidí{r.agreement != null ? ` · ${Math.round(r.agreement * 100)} %` : ''}</span></li>
                    ))}
                  </ol>
                </>
              )}
            </Card>
            <Card title="Stav řešení">
              <Bars rows={(Object.keys(STATUS_LABEL) as ReportStatus[]).map((k) => ({ label: STATUS_LABEL[k], value: s.by_status?.[k] ?? 0 }))} />
            </Card>
            <Card title="Jak často se autoři v místě pohybují">
              <Bars rows={[...(Object.keys(FREQUENCY_LABEL) as Frequency[]).map((k) => ({ label: FREQUENCY_LABEL[k], value: s.by_frequency?.[k] ?? 0 })), { label: 'Neuvedeno', value: s.by_frequency?.unknown ?? 0 }]} />
            </Card>
            <Card title="Vývoj zapojení (po týdnech)" className="lg:col-span-2">
              {s.timeline.length === 0 ? <p className="text-sm text-ink-soft">Zatím bez dat.</p> : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead><tr className="text-left text-xs text-ink-soft"><th className="py-1">Týden od</th><th>Nové podněty</th><th>Nové podpory</th></tr></thead>
                    <tbody>{s.timeline.map((t) => <tr key={t.week} className="border-t border-slate-100"><td className="py-1">{new Date(t.week).toLocaleDateString('cs-CZ')}</td><td className="tabular-nums">{t.reports}</td><td className="tabular-nums">{t.supports}</td></tr>)}</tbody>
                  </table>
                </div>
              )}
            </Card>
          </div>
        </>
      )}
    </div>
  );
}
