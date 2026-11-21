'use client';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import { ChartColumn, Info, Layers, ListFilter, Map as MapIcon, Plus, Satellite, User } from 'lucide-react';
import type { Position } from 'geojson';
import MapView, { type AnalysisData, type AnalysisLayer, type MapViewHandle } from '@/components/map/MapView';
import { CategoryStep, DrawToolbar, NearbyDialog, ReportForm, SuccessModal, defaultKind, type Draft } from '@/components/AddFlow';
import { ReportDetailPanel } from '@/components/ReportDetail';
import { FiltersPanel, applyFilters, defaultFilters, type Filters } from '@/components/FiltersPanel';
import { AccountDialog } from '@/components/AccountDialog';
import { Button, CategoryBadge, Modal, Sheet, Spinner, Toaster, toast } from '@/components/ui';
import { api, errorMessage } from '@/lib/api';
import { getSupabase } from '@/lib/supabase/client';
import { distanceM } from '@/lib/geo';
import { BASE_PATH } from '@/lib/env';
import type { DrawGeometry, MapData, MyProfile, NearbyReport, PublicConfig, ReportDetail } from '@/lib/types';
import { KIND_LABEL, visibleCategories } from '@/lib/types';

const EMPTY: MapData = { type: 'FeatureCollection', features: [] };

function draftGeometry(d: Draft): DrawGeometry | null {
  if (d.kind === 'point') return d.coords[0] ? { type: 'Point', coordinates: d.coords[0] } : null;
  if (d.kind === 'line') return d.coords.length >= 2 ? { type: 'LineString', coordinates: d.coords } : null;
  return d.coords.length >= 3 ? { type: 'Polygon', coordinates: [[...d.coords, d.coords[0]]] } : null;
}

type Step = null | 'category' | 'draw' | 'nearby' | 'form';

export default function MapApp({ embed = false }: { embed?: boolean }) {
  const mapRef = useRef<MapViewHandle>(null);
  const [config, setConfig] = useState<PublicConfig | null>(null);
  const [raw, setRaw] = useState<MapData>(EMPTY);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [filters, setFilters] = useState<Filters | null>(null);
  const [mode, setMode] = useState<'reports' | 'analysis'>('reports');
  const [layers, setLayers] = useState<Set<AnalysisLayer>>(new Set(['intensity']));
  const [analysisData, setAnalysisData] = useState<AnalysisData>({});
  const [analysisLoading, setAnalysisLoading] = useState(false);
  const [basemap, setBasemap] = useState<'osm' | 'ortho'>('osm');
  const [selected, setSelected] = useState<string | null>(null);
  const [chooser, setChooser] = useState<string[] | null>(null);
  const [highlight, setHighlight] = useState<string[]>([]);
  const [step, setStep] = useState<Step>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [nearby, setNearby] = useState<NearbyReport[]>([]);
  const [done, setDone] = useState<{ id: string; no: number; pending?: boolean } | null>(null);
  const [profile, setProfile] = useState<MyProfile | null>(null);
  const [account, setAccount] = useState<{ reason?: string } | null>(null);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [intro, setIntro] = useState(false);

  // --- načtení dat -------------------------------------------------------------
  const loadData = useCallback(async () => {
    try {
      setRaw(await api.mapData());
    } catch (e) {
      setLoadErr(errorMessage(e));
    }
  }, []);

  const loadProfile = useCallback(async () => {
    try {
      setProfile(await api.myProfile());
    } catch {
      setProfile(null);
    }
  }, []);

  useEffect(() => {
    (async () => {
      try {
        const c = await api.config();
        setConfig(c);
        setFilters(defaultFilters(c));
      } catch (e) {
        setLoadErr(errorMessage(e));
      }
    })();
    loadData();
    loadProfile();
    const { data: sub } = getSupabase().auth.onAuthStateChange((ev) => {
      if (ev === 'SIGNED_IN' || ev === 'SIGNED_OUT' || ev === 'USER_UPDATED') loadProfile();
    });
    const t = setInterval(() => document.visibilityState === 'visible' && loadData(), 90_000);
    const params = new URLSearchParams(window.location.search);
    const p = params.get('p');
    if (p) setSelected(p);
    if (params.get('login') === 'ok') toast('Jste přihlášeni. Děkujeme!');
    if (params.get('login') === 'error') toast('Přihlašovací odkaz je neplatný nebo vypršel. Požádejte prosím o nový.', 'error');
    const moved = Number(params.get('moved') ?? 0);
    if (moved > 0) toast(`Vaše podněty (${moved}) byly převedeny do přihlášeného účtu.`);
    if (params.get('login') || params.get('moved')) {
      params.delete('login');
      params.delete('moved');
      window.history.replaceState(null, '', `${window.location.pathname}${params.toString() ? `?${params}` : ''}`);
    }
    if (!embed && !p) {
      try {
        if (!localStorage.getItem('intro-seen')) setIntro(true);
      } catch { /* soukromý režim */ }
    }
    return () => {
      sub.subscription.unsubscribe();
      clearInterval(t);
    };
  }, [loadData, loadProfile, embed]);

  // URL s vybraným podnětem (sdílení)
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (selected) params.set('p', selected);
    else params.delete('p');
    const qs = params.toString();
    window.history.replaceState(null, '', `${window.location.pathname}${qs ? `?${qs}` : ''}`);
  }, [selected]);

  const data = useMemo(() => (filters ? applyFilters(raw, filters) : raw), [raw, filters]);

  // --- analytické vrstvy ---------------------------------------------------------
  const catKey = useMemo(() => {
    if (!filters || !config) return 'all';
    return filters.categories.size === visibleCategories(config).length ? 'all' : [...filters.categories].sort().join(',');
  }, [filters, config]);

  useEffect(() => {
    if (mode !== 'analysis') return;
    const cats = catKey === 'all' ? null : catKey ? catKey.split(',').map(Number) : [-1];
    const jobs: Promise<void>[] = [];
    const next: AnalysisData = {};
    setAnalysisLoading(true);
    if (layers.has('poly_overlap')) jobs.push(api.analysis('polygon_overlap', cats).then((d) => { next.polygon_overlap = d; }));
    if (layers.has('line_overlap')) jobs.push(api.analysis('line_overlap', cats).then((d) => { next.line_overlap = d; }));
    if (layers.has('intensity') || layers.has('drawings')) jobs.push(api.analysis('hexgrid', cats).then((d) => { next.hexgrid = d; }));
    Promise.all(jobs)
      .then(() => setAnalysisData(next))
      .catch((e) => toast(errorMessage(e), 'error'))
      .finally(() => setAnalysisLoading(false));
  }, [mode, layers, catKey, raw]);

  const heatColor = useMemo(() => {
    if (!config || !filters || filters.categories.size !== 1) return null;
    return config.categories.find((c) => filters.categories.has(c.id))?.color ?? null;
  }, [config, filters]);

  // --- přidání podnětu -------------------------------------------------------------
  const contributionsOpen = config?.settings.contributions_open !== false || profile?.is_admin;

  function startAdd() {
    if (config?.settings.contribute_requires_login && !profile?.is_verified) {
      setAccount({ reason: 'Pro přidání podnětu se prosím přihlaste. Zadejte e-mail, pošleme vám odkaz – bez hesla. Po přihlášení se vrátíte do mapy a můžete podnět zakreslit.' });
      return;
    }
    setSelected(null);
    setChooser(null);
    setFiltersOpen(false);
    if (mode === 'analysis') setMode('reports');
    setStep('category');
  }

  function pickCategory(catId: number, subId: number | null) {
    const cat = config?.categories.find((c) => c.id === catId);
    setDraft({ category_id: catId, subcategory_id: subId, kind: defaultKind(cat, subId), coords: [], variant_of: null });
    setStep('draw');
  }

  function onDrawClick(ll: [number, number]) {
    const d = draftRef.current;
    if (!d) return;
    let next: Draft;
    if (d.kind === 'point') next = { ...d, coords: [ll] };
    else if (d.kind === 'polygon' && d.coords.length >= 3 && distanceM(d.coords[0], ll) < 12) {
      finishDraw();
      return;
    } else next = { ...d, coords: [...d.coords, ll as Position] };
    draftRef.current = next;
    setDraft(next);
  }

  const draftRef = useRef(draft);
  draftRef.current = draft;

  async function finishDraw() {
    const d = draftRef.current;
    if (!d) return;
    const g = draftGeometry(d);
    if (!g) return;
    if (d.variant_of || !d.category_id) {
      setStep('form');
      return;
    }
    try {
      const n = await api.nearby(g, d.category_id);
      if (n.length) {
        setNearby(n);
        setStep('nearby');
        return;
      }
    } catch {
      /* kontrola okolí je jen doporučení */
    }
    setStep('form');
  }

  function cancelAdd() {
    setStep(null);
    setDraft(null);
    setNearby([]);
  }

  function startVariant(r: ReportDetail) {
    setDraft({
      category_id: r.category_id, subcategory_id: r.subcategory_id, kind: r.kind, coords: [],
      variant_of: r.id, variant_title: r.title, title: r.title
    });
    setHighlight([r.id]);
    setSelected(null);
    setStep('draw');
    toast('Zakreslete vlastní rozsah nebo trasu. Původní zakreslení je zvýrazněno.', 'info');
  }

  async function supportFromNearby(id: string) {
    if (config?.settings.support_requires_verified !== false && !profile?.is_verified) {
      setAccount({ reason: 'Pro podporu podnětu se prosím přihlaste odkazem zaslaným na e-mail. Zajistíme tak, že každý hlasuje jen jednou.' });
      return;
    }
    try {
      await api.setSupport(id, true);
      toast('Děkujeme! Podnět jste podpořili.');
      cancelAdd();
      await loadData();
      setSelected(id);
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  }

  const onSelect = useCallback((ids: string[]) => {
    setHighlight([]);
    if (ids.length === 0) {
      setSelected(null);
      setChooser(null);
    } else if (ids.length === 1) {
      setChooser(null);
      setSelected(ids[0]);
    } else {
      setSelected(null);
      setChooser(ids);
    }
  }, []);

  const openReport = useCallback((id: string) => {
    setChooser(null);
    setSelected(id);
    const f = raw.features.find((x) => x.properties.id === id);
    if (f) mapRef.current?.flyToGeometry(f.geometry);
  }, [raw]);

  if (loadErr && !config) {
    return (
      <div className="flex h-dvh items-center justify-center p-6 text-center">
        <div><p className="font-semibold">Aplikaci se nepodařilo načíst.</p><p className="mt-1 text-sm text-ink-soft">{loadErr}</p>
          <Button className="mt-4" variant="primary" onClick={() => window.location.reload()}>Zkusit znovu</Button></div>
      </div>
    );
  }

  const s = config?.settings;
  const catOf = (id?: number | null) => config?.categories.find((c) => c.id === id);
  const draftGeom = draft ? draftGeometry(draft) : null;

  return (
    <div className="relative h-dvh w-full overflow-hidden">
      <Toaster />
      {config && (
        <MapView
          ref={mapRef}
          categories={visibleCategories(config)}
          data={data}
          mode={mode}
          analysisLayers={layers}
          analysisData={analysisData}
          heatColor={heatColor}
          basemap={basemap}
          selectedId={selected}
          highlightIds={highlight}
          draw={step === 'draw' && draft ? { kind: draft.kind, coords: draft.coords } : null}
          initialBounds={s?.map_bounds}
          initialCenter={s?.map_center}
          initialZoom={s?.map_zoom}
          onDrawClick={onDrawClick}
          onSelect={onSelect}
          onReady={() => {
            // sdílený výřez mapy: ?lon=16.37&lat=49.10&z=16
            const q = new URLSearchParams(window.location.search);
            const lon = Number(q.get('lon')), lat = Number(q.get('lat')), z = Number(q.get('z'));
            if (lon && lat) mapRef.current?.flyTo([lon, lat], z || 16);
            const m = q.get('mode');
            if (m === 'analysis') setMode('analysis');
          }}
        />
      )}
      {!config && <div className="absolute inset-0 flex items-center justify-center"><Spinner className="h-8 w-8 text-brand-600" /></div>}

      {/* záhlaví */}
      {step !== 'draw' && (
        <header className="pointer-events-none absolute inset-x-0 top-0 z-20 flex items-start gap-2 p-2 md:p-3">
          <div className="pointer-events-auto min-w-0 max-w-[min(560px,calc(100%-7rem))] rounded-2xl bg-white/95 px-3.5 py-2.5 shadow-panel backdrop-blur md:px-4">
            <h1 className="truncate text-[15px] font-extrabold leading-tight text-brand-800 md:text-lg">{s?.intro_title ?? 'Ivančice očima pěších a cyklistů'}</h1>
            <p className="hidden truncate text-xs text-ink-soft sm:block md:text-sm">{s?.intro_subtitle ?? 'Společně mapujeme, jak se nám v Ivančicích chodí, jezdí na kole a žije.'}</p>
          </div>
          <div className="pointer-events-auto ml-auto flex gap-1.5">
            {!embed && (
              <Link href="/o-projektu" className="flex h-11 w-11 items-center justify-center rounded-2xl bg-white shadow-panel" aria-label="O projektu">
                <Info className="h-5 w-5" />
              </Link>
            )}
            <button onClick={() => setAccount({})} className={clsx('flex h-11 w-11 items-center justify-center rounded-2xl shadow-panel', profile?.is_verified ? 'bg-brand-600 text-white' : 'bg-white')} aria-label="Účet a přihlášení">
              <User className="h-5 w-5" />
            </button>
          </div>
        </header>
      )}

      {/* režim, filtry, podklad */}
      {step !== 'draw' && config && (
        <div className="absolute left-2 top-[68px] z-20 flex flex-col gap-1.5 md:left-3 md:top-[84px]">
          <div className="flex rounded-2xl bg-white p-1 shadow-panel">
            <button onClick={() => setMode('reports')} className={clsx('flex items-center gap-1.5 rounded-xl px-3 py-1.5 text-sm font-semibold', mode === 'reports' ? 'bg-brand-600 text-white' : 'text-ink-soft')}>
              <MapIcon className="h-4 w-4" /> Podněty
            </button>
            <button onClick={() => { setMode('analysis'); setSelected(null); }} className={clsx('flex items-center gap-1.5 rounded-xl px-3 py-1.5 text-sm font-semibold', mode === 'analysis' ? 'bg-brand-600 text-white' : 'text-ink-soft')}>
              <ChartColumn className="h-4 w-4" /> Analýza
            </button>
          </div>
          <div className="flex gap-1.5">
            <button onClick={() => { setFiltersOpen(true); setSelected(null); }} className="flex items-center gap-1.5 rounded-2xl bg-white px-3 py-2 text-sm font-semibold shadow-panel">
              <ListFilter className="h-4 w-4" /> Vrstvy a filtry
              {filters && (filters.categories.size < visibleCategories(config).length || filters.minPeople > 1 || filters.minOverlap > 0 || filters.district || filters.kinds.size < 3 || filters.status !== 'any') && <span className="h-2 w-2 rounded-full bg-orange-500" />}
            </button>
            <button onClick={() => setBasemap(basemap === 'osm' ? 'ortho' : 'osm')} className="flex items-center gap-1.5 rounded-2xl bg-white px-3 py-2 text-sm font-semibold shadow-panel" aria-label="Přepnout mapový podklad">
              {basemap === 'osm' ? <Satellite className="h-4 w-4" /> : <Layers className="h-4 w-4" />}
              <span className="hidden sm:inline">{basemap === 'osm' ? 'Letecká' : 'Mapa'}</span>
            </button>
          </div>
          {mode === 'analysis' && (
            <div className="max-w-[260px] rounded-2xl bg-white/95 p-2.5 text-xs shadow-panel">
              <div className="font-semibold">Analytické zobrazení {analysisLoading && <Spinner className="ml-1 inline h-3 w-3" />}</div>
              <div className="mt-1 h-2 rounded-full" style={{ background: 'linear-gradient(90deg,#fde68a,#fbbf24,#f97316,#dc2626,#991b1b)' }} />
              <div className="mt-0.5 flex justify-between text-[10px] text-ink-soft"><span>1 člověk</span><span>více lidí</span></div>
              <button className="mt-1 font-semibold text-brand-700" onClick={() => setFiltersOpen(true)}>Vybrat vrstvy ({layers.size})</button>
            </div>
          )}
        </div>
      )}

      {config?.demo_visible && step !== 'draw' && (
        <div className="absolute inset-x-0 top-[120px] z-10 mx-auto w-fit max-w-[90%] rounded-full bg-amber-100 px-3 py-1 text-center text-xs font-semibold text-amber-900 shadow max-md:left-auto max-md:right-2 max-md:mx-0 max-md:max-w-[150px] max-md:rounded-2xl md:top-3">
          Testovací provoz – zobrazená data jsou smyšlená ukázka
        </div>
      )}

      {/* hlavní tlačítko */}
      {step === null && !selected && !chooser && !filtersOpen && config && (
        <div className="absolute inset-x-0 bottom-0 z-20 flex justify-center p-3 pb-[max(1rem,env(safe-area-inset-bottom))] md:bottom-4 md:justify-start md:pl-4">
          {contributionsOpen ? (
            <button onClick={startAdd} className="flex items-center gap-2 rounded-full bg-brand-600 px-6 py-3.5 text-base font-bold text-white shadow-panel transition hover:bg-brand-700 active:scale-95">
              <Plus className="h-5 w-5" /> Přidat podnět
            </button>
          ) : (
            <div className="rounded-full bg-white px-5 py-3 text-sm font-semibold shadow-panel">Sběr podnětů je uzavřen. Děkujeme!</div>
          )}
        </div>
      )}

      {embed && (
        <a href={`${BASE_PATH}/`} target="_blank" rel="noopener" className="absolute right-2 top-[64px] z-20 rounded-xl bg-white px-2.5 py-1.5 text-xs font-semibold text-brand-800 shadow-panel md:top-[72px]">Otevřít celou mapu ↗</a>
      )}

      {/* --- panely --- */}
      {config && step === 'category' && <CategoryStep config={config} onPick={pickCategory} onClose={cancelAdd} />}
      {config && step === 'draw' && draft && (
        <DrawToolbar
          draft={draft}
          category={catOf(draft.category_id)}
          onKind={(k) => setDraft({ ...draft, kind: k, coords: k === 'point' ? draft.coords.slice(-1) : draft.coords })}
          onUndo={() => setDraft({ ...draft, coords: draft.coords.slice(0, -1) })}
          onClear={() => setDraft({ ...draft, coords: [] })}
          onFinish={finishDraw}
          onCancel={() => { cancelAdd(); setHighlight([]); }}
        />
      )}
      {config && step === 'nearby' && draft && (
        <NearbyDialog
          items={nearby}
          category={catOf(draft.category_id)}
          onSupport={supportFromNearby}
          onDetail={(id) => { cancelAdd(); openReport(id); }}
          onContinue={() => setStep('form')}
          onClose={() => setStep('draw')}
        />
      )}
      {config && step === 'form' && draft && draftGeom && (
        <ReportForm
          config={config}
          draft={draft}
          geometry={draftGeom}
          profile={profile}
          onCategory={(c, sub) => setDraft({ ...draft, category_id: c, subcategory_id: sub })}
          onBack={() => setStep('draw')}
          onCancel={cancelAdd}
          onDone={async (res) => {
            setStep(null);
            setDraft(null);
            setHighlight([]);
            setDone(res);
            await Promise.all([loadData(), loadProfile()]);
          }}
        />
      )}
      {done && (
        <SuccessModal
          id={done.id}
          no={done.no}
          pending={done.pending}
          verified={!!profile?.is_verified}
          onClose={() => setDone(null)}
          onShow={() => { const id = done.id; setDone(null); openReport(id); }}
          onLogin={() => { setDone(null); setAccount({}); }}
        />
      )}

      {config && selected && step === null && (
        <ReportDetailPanel
          id={selected}
          config={config}
          profile={profile}
          onClose={() => { setSelected(null); setHighlight([]); }}
          onChanged={() => { loadData(); loadProfile(); }}
          onCreateVariant={startVariant}
          onHighlight={setHighlight}
          onOpen={openReport}
          onLogin={(reason) => setAccount({ reason })}
          onZoom={(r) => mapRef.current?.flyToGeometry(r.geometry)}
        />
      )}

      {config && chooser && (
        <Sheet open onClose={() => setChooser(null)} title={`V tomto místě je ${chooser.length} zakreslení`}>
          <p className="mb-2 text-sm text-ink-soft">Zakreslení se překrývají. Vyberte, které chcete zobrazit.</p>
          <ul className="divide-y divide-slate-100">
            {chooser.map((id) => {
              const f = raw.features.find((x) => x.properties.id === id);
              if (!f) return null;
              const c = catOf(f.properties.c);
              return (
                <li key={id}>
                  <button className="flex w-full items-center gap-3 py-2.5 text-left" onClick={() => openReport(id)}>
                    {c && <CategoryBadge color={c.color} icon={c.icon} size="sm" />}
                    <span className="min-w-0 flex-1"><span className="block truncate font-medium">{f.properties.t}</span><span className="text-xs text-ink-soft">{KIND_LABEL[f.properties.k]} · {f.properties.p}× vnímáno jako problém</span></span>
                  </button>
                </li>
              );
            })}
          </ul>
        </Sheet>
      )}

      {config && filtersOpen && filters && (
        <FiltersPanel
          config={config} data={raw} filters={filters} setFilters={setFilters}
          mode={mode} setMode={setMode} layers={layers} setLayers={setLayers}
          onClose={() => setFiltersOpen(false)} loadingAnalysis={analysisLoading}
        />
      )}

      {config && account && (
        <AccountDialog profile={profile} config={config} reason={account.reason} onClose={() => setAccount(null)} onChanged={() => { loadProfile(); loadData(); }} onOpenReport={openReport} />
      )}

      {intro && config && (
        <Modal open onClose={() => { setIntro(false); try { localStorage.setItem('intro-seen', '1'); } catch { /* */ } }}
          title={s?.intro_title ?? 'Ivančice očima pěších a cyklistů'}
          footer={<Button variant="primary" onClick={() => { setIntro(false); try { localStorage.setItem('intro-seen', '1'); } catch { /* */ } }}>Začít mapovat</Button>}>
          <p className="text-[15px] text-ink-soft">{s?.intro_text}</p>
          <ol className="mt-4 space-y-3 text-sm">
            <li className="flex gap-3"><span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-600 font-bold text-white">1</span><span><b>Přidejte podnět</b> – vyberte téma a zakreslete bod, trasu nebo území.</span></li>
            <li className="flex gap-3"><span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-600 font-bold text-white">2</span><span><b>Podpořte ostatní</b> – tlačítkem „Také to vnímám jako problém“. Číslo ve značce ukazuje, kolik lidí to trápí.</span></li>
            <li className="flex gap-3"><span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-600 font-bold text-white">3</span><span><b>Zakreslete po svém</b> – vidíte-li problém jinak, vytvořte vlastní variantu. V analýze se ukáže, kde se lidé shodují.</span></li>
          </ol>
          <p className="mt-4 text-xs text-ink-soft">{s?.operator_name && !String(s.operator_name).startsWith('(') ? <>Mapu provozuje {String(s.operator_name)}. </> : null}{s?.contribute_requires_login ? 'Pro přidání podnětu se přihlásíte e-mailem (bez hesla). ' : 'Bez registrace, stačí jméno nebo přezdívka. '}<Link href="/ochrana-osobnich-udaju" className="underline">Ochrana osobních údajů</Link></p>
        </Modal>
      )}
    </div>
  );
}
