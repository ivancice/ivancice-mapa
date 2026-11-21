'use client';
import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react';
import type { FeatureCollection, Feature, Geometry, Point, Position } from 'geojson';
import type { GeoJSONSource, LngLatBoundsLike, Map as MLMap, MapGeoJSONFeature, StyleSpecification } from 'maplibre-gl';
import Supercluster from 'supercluster';
import type { Category, GeomKind, MapData, MapFeature } from '@/lib/types';
import { BASEMAP_ATTRIBUTION, BASEMAP_TILES, ORTHO_ATTRIBUTION, ORTHO_TILES } from '@/lib/env';
import { badgeImageName, clusterImageName, drawImage, pinImageName, PIXEL_RATIO } from '@/lib/markers';
import { bbox, heatSamples, representativePoint } from '@/lib/geo';

export type AnalysisLayer =
  | 'supporters'
  | 'drawings'
  | 'poly_overlap'
  | 'line_overlap'
  | 'point_density'
  | 'category_heat'
  | 'intensity';

export interface AnalysisData {
  polygon_overlap?: FeatureCollection | null;
  line_overlap?: FeatureCollection | null;
  hexgrid?: FeatureCollection | null;
}

export interface DrawState {
  kind: GeomKind;
  coords: Position[];
}

export interface MapViewHandle {
  flyToGeometry: (g: Geometry, maxZoom?: number) => void;
  flyTo: (center: [number, number], zoom?: number) => void;
  getCenter: () => [number, number];
}

interface Props {
  categories: Category[];
  data: MapData;
  mode: 'reports' | 'analysis';
  analysisLayers: Set<AnalysisLayer>;
  analysisData: AnalysisData;
  heatColor?: string | null;
  basemap: 'osm' | 'ortho';
  selectedId: string | null;
  highlightIds: string[];
  draw: DrawState | null;
  initialBounds?: [[number, number], [number, number]];
  initialCenter?: [number, number];
  initialZoom?: number;
  onDrawClick: (lngLat: [number, number]) => void;
  onSelect: (ids: string[]) => void;
  onReady?: () => void;
  onAnalysisInfo?: (html: string, lngLat: [number, number]) => void;
}

const EMPTY: FeatureCollection = { type: 'FeatureCollection', features: [] };
const RAMP = ['interpolate', ['linear'], ['get', 'people'], 1, '#fde68a', 2, '#fbbf24', 3, '#f97316', 5, '#dc2626', 8, '#991b1b', 15, '#4c0519'];

function baseStyle(): StyleSpecification {
  return {
    version: 8,
    sources: {
      osm: { type: 'raster', tiles: [BASEMAP_TILES], tileSize: 256, maxzoom: 19, attribution: BASEMAP_ATTRIBUTION },
      ortho: { type: 'raster', tiles: [ORTHO_TILES], tileSize: 256, maxzoom: 20, attribution: ORTHO_ATTRIBUTION }
    },
    layers: [
      { id: 'bg', type: 'background', paint: { 'background-color': '#eef1f4' } },
      { id: 'osm', type: 'raster', source: 'osm', paint: { 'raster-saturation': -0.25, 'raster-contrast': -0.05 } },
      { id: 'ortho', type: 'raster', source: 'ortho', layout: { visibility: 'none' } }
    ]
  };
}

function colorMatch(categories: Category[], prop = 'c'): unknown {
  if (!categories.length) return '#64748b';
  const m: unknown[] = ['match', ['get', prop]];
  for (const c of categories) m.push(c.id, c.color);
  m.push('#64748b');
  return m;
}

const MapView = forwardRef<MapViewHandle, Props>(function MapView(props, ref) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MLMap | null>(null);
  const [loaded, setLoaded] = useState(false);
  const propsRef = useRef(props);
  propsRef.current = props;
  const clusterIdx = useRef<Map<number, Supercluster<MapFeature['properties'], { u: number[] }>>>(new Map());
  const maplibreRef = useRef<typeof import('maplibre-gl') | null>(null);

  useImperativeHandle(ref, () => ({
    flyToGeometry(g, maxZoom = 17) {
      const map = mapRef.current;
      if (!map) return;
      const b = bbox(g);
      if (b[0] === b[2] && b[1] === b[3]) {
        map.flyTo({ center: [b[0], b[1]], zoom: Math.max(map.getZoom(), 16.5), duration: 700 });
      } else {
        map.fitBounds([[b[0], b[1]], [b[2], b[3]]] as LngLatBoundsLike, { padding: 80, maxZoom, duration: 700 });
      }
    },
    flyTo(center, zoom) {
      mapRef.current?.flyTo({ center, zoom: zoom ?? mapRef.current.getZoom(), duration: 700 });
    },
    getCenter() {
      const c = mapRef.current?.getCenter();
      return c ? [c.lng, c.lat] : [16.36, 49.09];
    }
  }));

  // --- inicializace mapy ---------------------------------------------------
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const maplibregl = await import('maplibre-gl');
      if (cancelled || !container.current) return;
      maplibreRef.current = maplibregl;
      const map = new maplibregl.Map({
        container: container.current,
        style: baseStyle(),
        // na úzkých displejích (mobil) začínáme přiblížením na město, na počítači celým územím
        ...(container.current.clientWidth < 640
          ? { center: propsRef.current.initialCenter ?? [16.3705, 49.0985], zoom: propsRef.current.initialZoom ?? 13.2 }
          : { bounds: propsRef.current.initialBounds ?? [[16.285, 49.06], [16.405, 49.115]], fitBoundsOptions: { padding: 20 } }),
        maxBounds: [[16.1, 48.98], [16.6, 49.2]],
        minZoom: 11,
        maxZoom: 19.5,
        attributionControl: { compact: true },
        dragRotate: false,
        pitchWithRotate: false,
        cooperativeGestures: false
      });
      map.touchZoomRotate.disableRotation();
      map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'bottom-right');
      map.addControl(
        new maplibregl.GeolocateControl({ positionOptions: { enableHighAccuracy: true }, trackUserLocation: false }),
        'bottom-right'
      );
      map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left');

      map.on('styleimagemissing', (e) => {
        const img = drawImage(e.id);
        if (img && !map.hasImage(e.id)) map.addImage(e.id, img, { pixelRatio: PIXEL_RATIO });
      });

      map.on('load', () => {
        setupLayers(map);
        setLoaded(true);
        propsRef.current.onReady?.();
      });
      map.on('moveend', () => updateClusters());
      map.on('click', onClick);
      map.on('mousemove', (e) => {
        if (propsRef.current.draw) {
          map.getCanvas().style.cursor = 'crosshair';
          return;
        }
        const f = map.queryRenderedFeatures(e.point, { layers: interactiveLayers(map) });
        map.getCanvas().style.cursor = f.length ? 'pointer' : '';
      });
      mapRef.current = map;
    })();
    return () => {
      cancelled = true;
      mapRef.current?.remove();
      mapRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function interactiveLayers(map: MLMap) {
    return ['pins', 'clusters', 'badges', 'report-lines', 'report-lines-hit', 'report-fill', 'an-poly-fill', 'an-line', 'an-hex', 'an-support']
      .filter((l) => map.getLayer(l) && map.getLayoutProperty(l, 'visibility') !== 'none');
  }

  function setupLayers(map: MLMap) {
    const cats = propsRef.current.categories;
    const add = (id: string) => map.addSource(id, { type: 'geojson', data: EMPTY });
    ['an-hex', 'an-poly', 'reports-poly', 'reports-line', 'an-line', 'an-heat', 'an-support', 'highlight', 'badges', 'pins', 'draw'].forEach(add);

    // analytické plochy (pod podněty)
    map.addLayer({
      id: 'an-hex', type: 'fill', source: 'an-hex',
      paint: { 'fill-color': ['interpolate', ['linear'], ['get', 'v'], 1, '#fef3c7', 3, '#fbbf24', 6, '#f97316', 12, '#dc2626', 25, '#7f1d1d'], 'fill-opacity': 0.55, 'fill-outline-color': 'rgba(255,255,255,0.6)' }
    });
    map.addLayer({ id: 'an-poly-fill', type: 'fill', source: 'an-poly', paint: { 'fill-color': RAMP as never, 'fill-opacity': ['interpolate', ['linear'], ['get', 'people'], 1, 0.28, 3, 0.5, 8, 0.7] } });
    map.addLayer({ id: 'an-poly-line', type: 'line', source: 'an-poly', paint: { 'line-color': RAMP as never, 'line-width': 1.2 } });

    // podněty – plochy
    map.addLayer({ id: 'report-fill', type: 'fill', source: 'reports-poly', paint: { 'fill-color': colorMatch(cats) as never, 'fill-opacity': 0.16 } });
    map.addLayer({
      id: 'report-outline', type: 'line', source: 'reports-poly',
      paint: { 'line-color': colorMatch(cats) as never, 'line-width': ['interpolate', ['linear'], ['get', 'p'], 1, 1.8, 10, 3, 30, 4.5], 'line-opacity': 0.9 }
    });
    // podněty – linie
    map.addLayer({
      id: 'report-lines-casing', type: 'line', source: 'reports-line', layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': '#ffffff', 'line-width': ['interpolate', ['linear'], ['get', 'p'], 1, 6, 10, 9, 30, 13], 'line-opacity': 0.85 }
    });
    map.addLayer({
      id: 'report-lines', type: 'line', source: 'reports-line', layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': colorMatch(cats) as never, 'line-width': ['interpolate', ['linear'], ['get', 'p'], 1, 3.2, 10, 6, 30, 9] }
    });
    map.addLayer({ id: 'report-lines-hit', type: 'line', source: 'reports-line', paint: { 'line-color': '#000', 'line-opacity': 0, 'line-width': 18 } });

    // překryvy linií
    map.addLayer({
      id: 'an-line', type: 'line', source: 'an-line', layout: { 'line-cap': 'round', 'line-join': 'round', 'line-sort-key': ['get', 'people'] },
      paint: { 'line-color': RAMP as never, 'line-width': ['interpolate', ['linear'], ['get', 'people'], 1, 3, 2, 6, 4, 10, 8, 15] }
    });
    // heatmapa
    map.addLayer({
      id: 'an-heat', type: 'heatmap', source: 'an-heat', maxzoom: 19,
      paint: {
        'heatmap-weight': ['get', 'w'],
        'heatmap-intensity': ['interpolate', ['linear'], ['zoom'], 12, 0.8, 16, 2.2],
        'heatmap-radius': ['interpolate', ['linear'], ['zoom'], 12, 14, 15, 28, 18, 60],
        'heatmap-opacity': 0.8,
        'heatmap-color': heatRamp(null) as never
      }
    });
    // počet podporovatelů – kruhy
    map.addLayer({
      id: 'an-support', type: 'circle', source: 'an-support',
      paint: {
        'circle-color': colorMatch(cats) as never, 'circle-opacity': 0.45, 'circle-stroke-color': colorMatch(cats) as never, 'circle-stroke-width': 1.5,
        'circle-radius': ['interpolate', ['linear'], ['sqrt', ['get', 'p']], 1, 6, 3, 14, 6, 26, 10, 42]
      }
    });
    // zvýraznění
    map.addLayer({ id: 'hl-fill', type: 'fill', source: 'highlight', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#111827', 'fill-opacity': 0.08 } });
    map.addLayer({
      id: 'hl-line', type: 'line', source: 'highlight', filter: ['!=', ['geometry-type'], 'Point'],
      paint: { 'line-color': ['case', ['get', 'sel'], '#111827', '#475569'], 'line-width': ['case', ['get', 'sel'], 3.5, 2], 'line-dasharray': ['literal', [2, 1.2]] }
    });
    map.addLayer({
      id: 'hl-point', type: 'circle', source: 'highlight', filter: ['==', ['geometry-type'], 'Point'],
      paint: { 'circle-radius': 22, 'circle-color': 'rgba(17,24,39,0.08)', 'circle-stroke-color': '#111827', 'circle-stroke-width': ['case', ['get', 'sel'], 2.5, 1.2] }
    });
    // odznaky s počty lidí u linií a ploch
    map.addLayer({
      id: 'badges', type: 'symbol', source: 'badges', minzoom: 14.5,
      layout: { 'icon-image': ['get', 'img'], 'icon-allow-overlap': false, 'icon-padding': 1, 'symbol-sort-key': ['-', 0, ['get', 'p']] }
    });
    // shluky a značky bodů
    map.addLayer({
      id: 'clusters', type: 'symbol', source: 'pins', filter: ['==', ['get', 'cl'], true],
      layout: { 'icon-image': ['get', 'img'], 'icon-allow-overlap': true, 'icon-anchor': 'center', 'symbol-sort-key': ['get', 'sort'] }
    });
    map.addLayer({
      id: 'pins', type: 'symbol', source: 'pins', filter: ['!=', ['get', 'cl'], true],
      layout: { 'icon-image': ['get', 'img'], 'icon-allow-overlap': true, 'icon-anchor': 'bottom', 'symbol-sort-key': ['get', 'sort'], 'symbol-z-order': 'source' }
    });
    // kreslení
    map.addLayer({ id: 'draw-fill', type: 'fill', source: 'draw', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#2a916e', 'fill-opacity': 0.2 } });
    map.addLayer({
      id: 'draw-line', type: 'line', source: 'draw', filter: ['!=', ['geometry-type'], 'Point'], layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': '#185e49', 'line-width': 3.5, 'line-dasharray': ['literal', [1.5, 1]] }
    });
    map.addLayer({
      id: 'draw-vertex', type: 'circle', source: 'draw', filter: ['==', ['geometry-type'], 'Point'],
      paint: {
        'circle-radius': ['case', ['get', 'first'], 8, ['get', 'single'], 10, 6],
        'circle-color': ['case', ['get', 'single'], '#2a916e', '#ffffff'],
        'circle-stroke-color': '#185e49', 'circle-stroke-width': 3
      }
    });
  }

  function heatRamp(color: string | null) {
    const c = color ?? '#dc2626';
    return ['interpolate', ['linear'], ['heatmap-density'],
      0, 'rgba(255,255,255,0)', 0.15, color ? hexToRgba(c, 0.25) : 'rgba(254,240,138,0.55)',
      0.4, color ? hexToRgba(c, 0.5) : 'rgba(251,191,36,0.75)', 0.7, color ? hexToRgba(c, 0.75) : 'rgba(249,115,22,0.85)',
      1, color ? hexToRgba(c, 0.95) : 'rgba(185,28,28,0.95)'];
  }

  // --- data podnětů ----------------------------------------------------------
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !loaded) return;
    const { data, categories } = props;
    const color = new Map(categories.map((c) => [c.id, c.color]));
    const polys: Feature[] = [];
    const lines: Feature[] = [];
    const badges: Feature[] = [];
    const points: Feature<Point, MapFeature['properties']>[] = [];
    for (const f of data.features) {
      const g = f.geometry;
      if (g.type === 'Point') points.push(f as Feature<Point, MapFeature['properties']>);
      else if (g.type === 'LineString' || g.type === 'MultiLineString') lines.push(f);
      else if (g.type === 'Polygon' || g.type === 'MultiPolygon') polys.push(f);
      if (g.type !== 'Point') {
        badges.push({
          type: 'Feature',
          geometry: { type: 'Point', coordinates: representativePoint(g) },
          properties: { id: f.properties.id, p: f.properties.p, img: badgeImageName(color.get(f.properties.c) ?? '#64748b', f.properties.p) }
        });
      }
    }
    // větší plochy pod menšími (aby šlo kliknout na menší)
    polys.sort((a, b) => area(b.geometry) - area(a.geometry));
    (map.getSource('reports-poly') as GeoJSONSource).setData({ type: 'FeatureCollection', features: polys });
    (map.getSource('reports-line') as GeoJSONSource).setData({ type: 'FeatureCollection', features: lines });
    (map.getSource('badges') as GeoJSONSource).setData({ type: 'FeatureCollection', features: badges });

    // shlukování bodů zvlášť pro každou kategorii, s unikátními lidmi
    const byCat = new Map<number, Feature<Point, MapFeature['properties']>[]>();
    for (const p of points) {
      const arr = byCat.get(p.properties.c) ?? [];
      arr.push(p);
      byCat.set(p.properties.c, arr);
    }
    const idx = new Map<number, Supercluster<MapFeature['properties'], { u: number[] }>>();
    for (const [cat, pts] of byCat) {
      const sc = new Supercluster<MapFeature['properties'], { u: number[] }>({
        radius: 55,
        maxZoom: 15,
        minPoints: 2,
        map: (p) => ({ u: [...p.u] }),
        reduce: (acc, p) => {
          const s = new Set(acc.u);
          for (const x of p.u) s.add(x);
          acc.u = [...s];
        }
      });
      sc.load(pts);
      idx.set(cat, sc);
    }
    clusterIdx.current = idx;
    updateClusters();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.data, loaded, props.categories]);

  function updateClusters() {
    const map = mapRef.current;
    if (!map || !map.getSource('pins')) return;
    const { categories, selectedId } = propsRef.current;
    const color = new Map(categories.map((c) => [c.id, c.color]));
    const b = map.getBounds();
    const box: [number, number, number, number] = [b.getWest() - 0.01, b.getSouth() - 0.01, b.getEast() + 0.01, b.getNorth() + 0.01];
    const z = Math.floor(map.getZoom());
    const out: Feature[] = [];
    for (const [cat, sc] of clusterIdx.current) {
      const col = color.get(cat) ?? '#64748b';
      for (const f of sc.getClusters(box, z)) {
        const pr = f.properties as unknown as Record<string, unknown>;
        if (pr.cluster) {
          const people = (pr.u as number[]).length;
          out.push({
            type: 'Feature', geometry: f.geometry,
            properties: { cl: true, cat, cluster_id: pr.cluster_id, count: pr.point_count, people, img: clusterImageName(col, pr.point_count as number, people), sort: people }
          });
        } else {
          const p = pr as unknown as MapFeature['properties'];
          out.push({
            type: 'Feature', geometry: f.geometry,
            properties: { cl: false, id: p.id, c: p.c, p: p.p, img: pinImageName(col, p.p, p.id === selectedId ? 's' : p.dm ? 'm' : 'n'), sort: p.id === selectedId ? 1e6 : p.p }
          });
        }
      }
    }
    (map.getSource('pins') as GeoJSONSource).setData({ type: 'FeatureCollection', features: out });
  }

  // výběr → překreslit značky
  useEffect(() => {
    if (loaded) updateClusters();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.selectedId, loaded]);

  // --- zvýraznění -----------------------------------------------------------
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !loaded) return;
    const ids = new Set([...(props.selectedId ? [props.selectedId] : []), ...props.highlightIds]);
    const feats = props.data.features
      .filter((f) => ids.has(f.properties.id))
      .map((f) => ({ ...f, properties: { ...f.properties, sel: f.properties.id === props.selectedId } }));
    (map.getSource('highlight') as GeoJSONSource).setData({ type: 'FeatureCollection', features: feats });
  }, [props.selectedId, props.highlightIds, props.data, loaded]);

  // --- podklad ----------------------------------------------------------------
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !loaded) return;
    map.setLayoutProperty('osm', 'visibility', props.basemap === 'osm' ? 'visible' : 'none');
    map.setLayoutProperty('ortho', 'visibility', props.basemap === 'ortho' ? 'visible' : 'none');
  }, [props.basemap, loaded]);

  // --- režim a analytické vrstvy ---------------------------------------------
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !loaded) return;
    const analysis = props.mode === 'analysis';
    const L = props.analysisLayers;
    const vis = (id: string, on: boolean) => map.getLayer(id) && map.setLayoutProperty(id, 'visibility', on ? 'visible' : 'none');

    // běžné zobrazení podnětů
    vis('pins', !analysis);
    vis('clusters', !analysis);
    vis('badges', !analysis);
    map.setPaintProperty('report-fill', 'fill-opacity', analysis ? 0 : 0.16);
    map.setPaintProperty('report-outline', 'line-opacity', analysis ? 0.22 : 0.9);
    map.setPaintProperty('report-lines', 'line-opacity', analysis ? 0.22 : 1);
    map.setPaintProperty('report-lines-casing', 'line-opacity', analysis ? 0 : 0.85);

    vis('an-poly-fill', analysis && L.has('poly_overlap'));
    vis('an-poly-line', analysis && L.has('poly_overlap'));
    vis('an-line', analysis && L.has('line_overlap'));
    vis('an-hex', analysis && (L.has('intensity') || L.has('drawings')));
    vis('an-support', analysis && L.has('supporters'));
    const heatOn = analysis && (L.has('point_density') || L.has('category_heat'));
    vis('an-heat', heatOn);

    (map.getSource('an-poly') as GeoJSONSource).setData((props.analysisData.polygon_overlap as FeatureCollection) ?? EMPTY);
    (map.getSource('an-line') as GeoJSONSource).setData((props.analysisData.line_overlap as FeatureCollection) ?? EMPTY);

    // šestiúhelníky: intenzita (unikátní lidé) nebo počet zakreslení
    const hex = props.analysisData.hexgrid;
    const hexProp = L.has('intensity') ? 'people' : 'objects';
    // barevná škála podle maxima v datech (sekvenční, jeden tón světlá → tmavá)
    const maxV = Math.max(2, ...(hex?.features ?? []).map((f) => Number((f.properties as Record<string, number>)[hexProp]) || 0));
    map.setPaintProperty('an-hex', 'fill-color', ['interpolate', ['linear'], ['get', 'v'],
      1, '#fef3c7', Math.max(1.01, maxV * 0.25), '#fbbf24', Math.max(1.02, maxV * 0.5), '#f97316', Math.max(1.03, maxV * 0.75), '#dc2626', Math.max(1.04, maxV), '#7f1d1d'] as never);
    (map.getSource('an-hex') as GeoJSONSource).setData(
      hex ? { type: 'FeatureCollection', features: hex.features.map((f) => ({ ...f, properties: { ...f.properties, v: (f.properties as Record<string, number>)[hexProp] } })) } : EMPTY
    );

    // podporovatelé – kruhy na reprezentativních bodech
    if (L.has('supporters')) {
      (map.getSource('an-support') as GeoJSONSource).setData({
        type: 'FeatureCollection',
        features: [...props.data.features]
          .sort((a, b) => b.properties.p - a.properties.p)
          .map((f) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: representativePoint(f.geometry) }, properties: { id: f.properties.id, c: f.properties.c, p: f.properties.p, sp: f.properties.sp } }))
      });
    }
    // heatmapa
    if (heatOn) {
      const onlyPoints = L.has('point_density') && !L.has('category_heat');
      const feats: Feature[] = [];
      for (const f of props.data.features) {
        if (onlyPoints && f.geometry.type !== 'Point') continue;
        const samples = heatSamples(f.geometry);
        const w = (onlyPoints ? 1 : Math.sqrt(f.properties.p)) / Math.max(1, Math.sqrt(samples.length));
        for (const s of samples) feats.push({ type: 'Feature', geometry: { type: 'Point', coordinates: s }, properties: { w } });
      }
      (map.getSource('an-heat') as GeoJSONSource).setData({ type: 'FeatureCollection', features: feats });
      map.setPaintProperty('an-heat', 'heatmap-color', heatRamp(onlyPoints ? null : props.heatColor ?? null) as never);
    }
  }, [props.mode, props.analysisLayers, props.analysisData, props.data, props.heatColor, loaded]);

  // --- kreslení ---------------------------------------------------------------
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !loaded) return;
    const d = props.draw;
    const feats: Feature[] = [];
    if (d && d.coords.length) {
      if (d.kind === 'point') {
        feats.push({ type: 'Feature', geometry: { type: 'Point', coordinates: d.coords[0] }, properties: { single: true, first: false } });
      } else {
        if (d.kind === 'polygon' && d.coords.length >= 3) {
          feats.push({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [[...d.coords, d.coords[0]]] }, properties: {} });
        } else if (d.coords.length >= 2) {
          feats.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: d.coords }, properties: {} });
        }
        d.coords.forEach((c, i) =>
          feats.push({ type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: { first: i === 0 && d.kind === 'polygon', single: false } })
        );
      }
    }
    (map.getSource('draw') as GeoJSONSource).setData({ type: 'FeatureCollection', features: feats });
    map.getCanvas().style.cursor = d ? 'crosshair' : '';
    map.doubleClickZoom[d ? 'disable' : 'enable']();
  }, [props.draw, loaded]);

  // --- kliknutí ---------------------------------------------------------------
  function onClick(e: { point: { x: number; y: number }; lngLat: { lng: number; lat: number } }) {
    const map = mapRef.current;
    if (!map) return;
    const p = propsRef.current;
    if (p.draw) {
      p.onDrawClick([e.lngLat.lng, e.lngLat.lat]);
      return;
    }
    const pad = 6;
    const box: [[number, number], [number, number]] = [[e.point.x - pad, e.point.y - pad], [e.point.x + pad, e.point.y + pad]];
    const hits = map.queryRenderedFeatures(box, { layers: interactiveLayers(map) });
    if (!hits.length) {
      p.onSelect([]);
      return;
    }
    const cluster = hits.find((h) => h.layer.id === 'clusters');
    const pin = hits.find((h) => h.layer.id === 'pins');
    if (pin) return p.onSelect([String(pin.properties.id)]);
    if (cluster) {
      const sc = clusterIdx.current.get(Number(cluster.properties.cat));
      if (sc) {
        const z = sc.getClusterExpansionZoom(Number(cluster.properties.cluster_id));
        map.easeTo({ center: (cluster.geometry as Point).coordinates as [number, number], zoom: Math.min(z + 0.2, 18) });
      }
      return;
    }
    const an = hits.find((h) => h.layer.id.startsWith('an-'));
    if (an && p.mode === 'analysis') {
      const html = analysisHtml(an);
      if (p.onAnalysisInfo) p.onAnalysisInfo(html, [e.lngLat.lng, e.lngLat.lat]);
      else if (maplibreRef.current && html) {
        new maplibreRef.current.Popup({ maxWidth: '280px', closeButton: true }).setLngLat(e.lngLat).setHTML(html).addTo(map);
      }
      return;
    }
    const ids: string[] = [];
    for (const h of hits) {
      const id = h.properties?.id as string | undefined;
      if (id && !ids.includes(id) && ['badges', 'report-lines', 'report-lines-hit', 'report-fill'].includes(h.layer.id)) ids.push(id);
    }
    p.onSelect(ids);
  }

  return <div ref={container} className="absolute inset-0" aria-label="Mapa podnětů" role="application" />;
});

function analysisHtml(f: MapGeoJSONFeature): string {
  const pr = f.properties as Record<string, number>;
  const people = pr.people ?? pr.p;
  const sh = pr.share ? ` (${Math.round(pr.share * 100)} % všech, kdo zakreslili)` : '';
  switch (f.layer.id) {
    case 'an-poly-fill':
      return `<b>Překryv ploch</b><br>Tuto část území označilo <b>${people}</b> ${lidi(people)}${sh}.`;
    case 'an-line':
      return `<b>Překryv tras</b><br>Tento úsek (≈${pr.length_m ?? '?'} m) zakreslilo <b>${people}</b> ${lidi(people)}${sh}.`;
    case 'an-hex':
      return `<b>Buňka intenzity</b><br>Zakreslení: <b>${pr.objects}</b><br>Autoři: <b>${pr.authors}</b><br>Unikátní lidé vč. podpor: <b>${pr.people}</b>`;
    case 'an-support':
      return `<b>Počet lidí</b><br><b>${pr.p}</b> ${lidi(pr.p)} vnímá místo jako problém (z toho ${pr.sp} podpořilo).`;
    default:
      return '';
  }
}

function lidi(n: number) {
  return n === 1 ? 'člověk' : n >= 2 && n <= 4 ? 'lidé' : 'lidí';
}

function area(g: Geometry) {
  const b = bbox(g);
  return (b[2] - b[0]) * (b[3] - b[1]);
}

function hexToRgba(hex: string, a: number) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

export default MapView;
