'use client';
import { useCallback, useEffect, useState } from 'react';
import { adminApi } from '@/lib/adminApi';
import { useAdmin } from '@/components/admin/AdminShell';
import { errorMessage } from '@/lib/api';
import { Button, Spinner, inputCls, toast } from '@/components/ui';
import { formatDate } from '@/lib/geo';
import { deleteStoragePhotos } from '@/lib/photos';

type Setting = { key: string; value: unknown; is_public: boolean; description: string | null };

const GROUPS: { title: string; keys: string[] }[] = [
  { title: 'Provoz a texty', keys: ['operator_name', 'operator_url', 'contributions_open', 'contribute_requires_login', 'support_requires_verified', 'photos_enabled', 'intro_title', 'intro_subtitle', 'intro_text', 'project_end'] },
  { title: 'Ochrana osobních údajů (GDPR)', keys: ['privacy_controller', 'privacy_contact', 'privacy_dpo', 'retention_text'] },
  { title: 'Mapa a územní rozsah', keys: ['map_bounds', 'map_center', 'map_zoom', 'service_area'] },
  { title: 'Prostorové analýzy a tolerance', keys: ['duplicate_radius_m', 'point_tolerance_m', 'line_tolerance_m', 'line_angle_deg', 'line_segment_m', 'polygon_tolerance_m', 'hex_size_m'] },
  { title: 'Ochrana proti spamu', keys: ['rate_reports_anon', 'rate_reports_verified', 'rate_comments', 'rate_supports', 'max_photos'] }
];

export default function SettingsAdmin() {
  const { reloadConfig, config } = useAdmin();
  const [settings, setSettings] = useState<Setting[] | null>(null);
  const load = useCallback(() => adminApi.settings().then(setSettings).catch((e) => toast(errorMessage(e), 'error')), []);
  useEffect(() => { load(); }, [load]);

  async function save(key: string, value: unknown) {
    try {
      await adminApi.setSetting(key, value);
      toast('Uloženo');
      await load();
      await reloadConfig();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  }

  if (!settings) return <div className="flex justify-center p-10"><Spinner /></div>;
  const byKey = new Map(settings.map((s) => [s.key, s]));
  const showDemo = byKey.get('show_demo')?.value === true;

  return (
    <div className="max-w-4xl space-y-4">
      <h1 className="text-xl font-extrabold">Nastavení</h1>

      <section className="rounded-2xl border-2 border-amber-200 bg-amber-50 p-4 text-sm">
        <h2 className="font-bold">Testovací prostředí s ukázkovými daty</h2>
        <p className="mt-1 text-amber-900">Ukázková data jsou označena jako <b>ukázka</b> a ve veřejné mapě je zobrazen pruh „Testovací provoz“. Před veřejným spuštěním je smažte – skutečné podněty zůstanou nedotčeny.</p>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button variant="outline" onClick={async () => { try { const r = await adminApi.seedDemo(80); toast(`Vloženo ${r.created} ukázkových podnětů`); load(); reloadConfig(); } catch (e) { toast(errorMessage(e), 'error'); } }}>Vložit ukázková data</Button>
          <Button variant="danger" onClick={async () => {
            if (!confirm('Smazat všechna ukázková data?')) return;
            try { const r = await adminApi.deleteDemo(); await deleteStoragePhotos(r.photo_paths ?? []); toast(`Smazáno ${r.deleted} ukázkových podnětů`); load(); reloadConfig(); } catch (e) { toast(errorMessage(e), 'error'); }
          }}>Smazat ukázková data</Button>
          <label className="ml-auto flex items-center gap-2 font-semibold"><input type="checkbox" checked={showDemo} onChange={(e) => save('show_demo', e.target.checked)} /> Zobrazovat ukázková data</label>
        </div>
        {config.demo_visible && <p className="mt-2 font-semibold text-amber-900">⚠ Ukázková data jsou nyní veřejně viditelná.</p>}
      </section>

      {GROUPS.map((g) => (
        <section key={g.title} className="rounded-2xl bg-white p-4 shadow-sm">
          <h2 className="mb-3 font-bold">{g.title}</h2>
          <div className="space-y-3">
            {g.keys.map((k) => byKey.get(k)).filter(Boolean).map((s) => <SettingRow key={s!.key} s={s!} onSave={save} />)}
          </div>
        </section>
      ))}

      <Admins />
      <Districts onDone={reloadConfig} />
      <ImportGeojson onDone={reloadConfig} />
      <Newsletter />
      <Audit />
    </div>
  );
}

function SettingRow({ s, onSave }: { s: Setting; onSave: (k: string, v: unknown) => void }) {
  const isBool = typeof s.value === 'boolean';
  const isNum = typeof s.value === 'number';
  const isStr = typeof s.value === 'string';
  const [v, setV] = useState(isStr ? (s.value as string) : isNum ? String(s.value) : JSON.stringify(s.value));
  if (isBool) {
    return (
      <label className="flex items-center gap-3 text-sm">
        <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={s.value as boolean} onChange={(e) => onSave(s.key, e.target.checked)} />
        <span><b>{s.description ?? s.key}</b> <span className="font-mono text-[11px] text-ink-faint">{s.key}</span></span>
      </label>
    );
  }
  const long = isStr && ((s.value as string).length > 60 || s.key.includes('text'));
  return (
    <div className="text-sm">
      <div className="mb-1"><b>{s.description ?? s.key}</b> <span className="font-mono text-[11px] text-ink-faint">{s.key}</span></div>
      <div className="flex gap-2">
        {long ? <textarea className={`${inputCls} min-h-[70px]`} value={v} onChange={(e) => setV(e.target.value)} />
          : <input className={`${inputCls} ${isNum ? 'max-w-[160px]' : ''} ${!isStr && !isNum ? 'font-mono text-xs' : ''}`} type={isNum ? 'number' : 'text'} value={v} onChange={(e) => setV(e.target.value)} />}
        <Button variant="outline" onClick={() => {
          try {
            onSave(s.key, isStr ? v : isNum ? Number(v) : JSON.parse(v));
          } catch {
            toast('Neplatný formát (očekáván JSON)', 'error');
          }
        }}>Uložit</Button>
      </div>
    </div>
  );
}

function Admins() {
  const [a, setA] = useState<Awaited<ReturnType<typeof adminApi.admins>> | null>(null);
  const [email, setEmail] = useState('');
  const load = useCallback(() => adminApi.admins().then(setA), []);
  useEffect(() => { load(); }, [load]);
  return (
    <section className="rounded-2xl bg-white p-4 text-sm shadow-sm">
      <h2 className="mb-2 font-bold">Administrátoři</h2>
      <p className="text-ink-soft">Zadaný e-mail získá oprávnění po přihlášení magic linkem.</p>
      <ul className="mt-2 space-y-1">
        {a?.invited.map((e) => (
          <li key={e} className="flex items-center gap-2">
            <span className="flex-1">{e} {a.active.some((x) => x.email?.toLowerCase() === e) ? <span className="text-xs text-brand-700">aktivní</span> : <span className="text-xs text-ink-faint">čeká na přihlášení</span>}</span>
            <button className="text-xs text-red-600" onClick={async () => { try { await adminApi.removeAdmin(e); load(); } catch (er) { toast(errorMessage(er), 'error'); } }}>odebrat</button>
          </li>
        ))}
      </ul>
      <div className="mt-2 flex gap-2">
        <input className={inputCls} type="email" placeholder="e-mail nového administrátora" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Button variant="outline" onClick={async () => { if (!email) return; await adminApi.addAdmin(email); setEmail(''); load(); toast('Přidáno'); }}>Přidat</Button>
      </div>
    </section>
  );
}

function readFile(f: File): Promise<unknown> {
  return f.text().then((t) => JSON.parse(t));
}

function Districts({ onDone }: { onDone: () => void }) {
  const { config } = useAdmin();
  return (
    <section className="rounded-2xl bg-white p-4 text-sm shadow-sm">
      <h2 className="mb-2 font-bold">Místní části – hranice</h2>
      <p className="text-ink-soft">
        Pro přesné statistiky nahrajte hranice katastrálních území jako GeoJSON (WGS 84) s vlastností <code>name</code> (např. „Letkovice“). Hranice lze získat z RÚIAN (ČÚZK) nebo exportem z OpenStreetMap – viz README.
      </p>
      <ul className="mt-2 flex flex-wrap gap-2">
        {config.districts.map((d) => <li key={d.id} className="rounded-full bg-slate-100 px-2.5 py-1 text-xs">{d.name} {d.has_boundary ? '✓ hranice' : '· jen střed'}</li>)}
      </ul>
      <input type="file" accept=".geojson,.json,application/geo+json" className="mt-3 text-sm" onChange={async (e) => {
        const f = e.target.files?.[0];
        if (!f) return;
        try { const r = await adminApi.importDistricts(await readFile(f)); toast(`Nahráno ${r.imported} hranic, podněty přepočítány`); onDone(); } catch (er) { toast(errorMessage(er), 'error'); }
      }} />
    </section>
  );
}

function ImportGeojson({ onDone }: { onDone: () => void }) {
  const { config } = useAdmin();
  const [fc, setFc] = useState<{ features: { properties?: Record<string, unknown> }[] } | null>(null);
  const [onlyCats, setOnlyCats] = useState(false);
  const [defCat, setDefCat] = useState('');
  const [author, setAuthor] = useState('Původní mapa (MapHub)');
  const gmap = new Map<string, string>((((fc as unknown as { groups?: { id: unknown; title?: string; name?: string }[] })?.groups) ?? []).map((g) => [String(g.id), String(g.title ?? g.name ?? g.id)]));
  const groups = fc ? [...new Set(fc.features.map((f) => String(f.properties?.category ?? f.properties?.group_title ?? f.properties?.layer ?? gmap.get(String(f.properties?.group)) ?? f.properties?.group ?? '(bez skupiny)')))] : [];
  return (
    <section className="rounded-2xl bg-white p-4 text-sm shadow-sm">
      <h2 className="mb-2 font-bold">Import dat (např. původní mapa MapHub)</h2>
      <p className="text-ink-soft">
        V MapHub otevřete mapu → <i>Export</i> → <i>GeoJSON</i> a soubor nahrajte zde. Skupiny (kategorie) původní mapy se převezmou jako nové kategorie se zdrojem „MapHub“
        a podněty se vloží jako záznamy původní mapy. Lze importovat i jen kategorie.
      </p>
      <input type="file" accept=".geojson,.json" className="mt-3" onChange={async (e) => {
        const f = e.target.files?.[0];
        if (!f) return;
        try { setFc((await readFile(f)) as typeof fc); } catch { toast('Soubor není platný GeoJSON', 'error'); }
      }} />
      {fc && (
        <div className="mt-3 space-y-2 rounded-2xl bg-slate-50 p-3">
          <div><b>{fc.features.length}</b> prvků · skupiny: {groups.join(', ')}</div>
          <label className="flex items-center gap-2"><input type="checkbox" checked={onlyCats} onChange={(e) => setOnlyCats(e.target.checked)} /> Importovat pouze kategorie</label>
          <label className="block">Kategorie pro prvky bez skupiny
            <select className={`${inputCls} mt-1`} value={defCat} onChange={(e) => setDefCat(e.target.value)}>
              <option value="">– přeskočit –</option>
              {config.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
          <label className="block">Autor importovaných podnětů
            <input className={`${inputCls} mt-1`} value={author} onChange={(e) => setAuthor(e.target.value)} />
          </label>
          <Button variant="primary" onClick={async () => {
            try {
              const r = await adminApi.importGeojson(fc, { only_categories: onlyCats, default_category_id: defCat || null, author_name: author, source: 'maphub' });
              toast(`Importováno ${r.imported} podnětů, ${r.categories_created} nových kategorií, přeskočeno ${r.skipped}`);
              setFc(null);
              onDone();
            } catch (e) { toast(errorMessage(e), 'error'); }
          }}>Importovat</Button>
        </div>
      )}
    </section>
  );
}

function Newsletter() {
  return (
    <section className="rounded-2xl bg-white p-4 text-sm shadow-sm">
      <h2 className="mb-2 font-bold">Odběratelé informací o výsledcích</h2>
      <p className="text-ink-soft">Pouze uživatelé, kteří udělili samostatný souhlas. Seznam používejte jen k informování o výsledcích mapování a novinkách projektu.</p>
      <Button variant="outline" className="mt-2" onClick={async () => {
        try {
          const list = await adminApi.newsletter();
          const csv = '﻿email;prezdivka;souhlas_udelen\r\n' + list.map((x) => `${x.email};${(x.nickname ?? '').replace(/;/g, ',')};${x.consent_at ?? ''}`).join('\r\n');
          const a = document.createElement('a');
          a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
          a.download = 'odberatele.csv';
          a.click();
          toast(`${list.length} odběratelů`);
        } catch (e) { toast(errorMessage(e), 'error'); }
      }}>Stáhnout CSV</Button>
    </section>
  );
}

function Audit() {
  const [log, setLog] = useState<Awaited<ReturnType<typeof adminApi.audit>> | null>(null);
  return (
    <section className="rounded-2xl bg-white p-4 text-sm shadow-sm">
      <h2 className="mb-2 font-bold">Auditní záznam zásahů</h2>
      {!log ? <Button variant="outline" onClick={() => adminApi.audit(200).then(setLog)}>Zobrazit posledních 200 záznamů</Button> : (
        <div className="max-h-96 overflow-y-auto">
          <table className="w-full text-xs">
            <tbody>{log.map((l) => <tr key={l.id} className="border-t border-slate-100"><td className="py-1 pr-2 text-ink-faint">{formatDate(l.created_at)}</td><td className="pr-2">{l.actor ?? '—'}</td><td className="pr-2 font-semibold">{l.action}</td><td className="text-ink-soft">{l.target_type} {l.target_id}</td></tr>)}</tbody>
          </table>
        </div>
      )}
    </section>
  );
}
