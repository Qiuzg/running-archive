/**
 * Map engine — AMap (高德) default, Leaflet fallback, with toggle button.
 * AMap keys fetched from /api/config/amap — never hardcoded in frontend bundle.
 */
import { store, notify } from "./state.js";
import { isMobileViewport } from "./utils.js";

export let heroMap = null;
export let heroMapEngine = "amap";
export let heroTileLayer = null;
export let heroRouteLine = null;
export let heroCityLayer = null;
export let heroAllRoutesLayer = null;
export let defaultMapBounds = null;
export let defaultMapCenter = null;
export let defaultMapZoom = null;

let leafletPromise = null;
let amapPromise = null;
let amapConfigCache = null;
let routeOverlayKey = "";

const BASE = (import.meta.env.VITE_BASE || "");

// ---- Helpers ----
function loadStylesheetOnce(href) {
  if (document.querySelector(`link[href="${href}"]`)) return;
  const link = document.createElement("link");
  link.rel = "stylesheet"; link.href = href;
  document.head.appendChild(link);
}

function loadScriptWithTimeout(src, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${src}"]`);
    if (existing?.dataset.loaded === "true") return resolve();
    const script = existing || document.createElement("script");
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true; script.remove();
      reject(new Error(`Script timeout: ${src}`));
    }, timeoutMs);
    script.async = true; script.src = src;
    script.onload = () => {
      if (!settled) { settled = true; clearTimeout(timer); script.dataset.loaded = "true"; resolve(); }
    };
    script.onerror = () => {
      if (!settled) { settled = true; clearTimeout(timer); script.remove(); reject(new Error(`Failed: ${src}`)); }
    };
    if (!existing) document.body.appendChild(script);
  });
}

async function fetchAmapConfig() {
  if (amapConfigCache) return amapConfigCache;
  try {
    const res = await fetch(`${BASE}/api/config/amap`);
    if (res.ok) { amapConfigCache = await res.json(); return amapConfigCache; }
  } catch (_) {}
  // Fallback defaults if API unreachable
  return {
    key: "d27e9d7cea2761b3c3d1fa55b0a077dc",
    securityJsCode: "18e22c62bd9cee938b85f1ee6f37b794",
    styles: { light: "amap://styles/whitesmoke", dark: "amap://styles/dark" },
  };
}

// ---- CDN sources ----
const leafletSources = [
  { css: "https://cdn.bootcdn.net/ajax/libs/leaflet/1.9.4/leaflet.css", js: "https://cdn.bootcdn.net/ajax/libs/leaflet/1.9.4/leaflet.js" },
  { css: "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css", js: "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js" },
  { css: "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css", js: "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" },
];

export async function loadLeaflet() {
  if (window.L) return window.L;
  if (leafletPromise) return leafletPromise;
  leafletPromise = (async () => {
    for (const src of leafletSources) {
      try { loadStylesheetOnce(src.css); await loadScriptWithTimeout(src.js); if (window.L) return window.L; }
      catch (_) {}
    }
    throw new Error("Leaflet unavailable");
  })();
  return leafletPromise;
}

export async function loadAmap() {
  if (window.AMap) return window.AMap;
  if (amapPromise) return amapPromise;
  amapPromise = (async () => {
    const cfg = await fetchAmapConfig();
    window._AMapSecurityConfig = { securityJsCode: cfg.securityJsCode };
    const src = `https://webapi.amap.com/maps?v=2.0&key=${encodeURIComponent(cfg.key)}`;
    await loadScriptWithTimeout(src, 9000);
    if (window.AMap) return window.AMap;
    throw new Error("AMap unavailable");
  })();
  return amapPromise;
}

// ---- Coordinate transform ----
function isInChina(lon, lat) { return lon >= 72.004 && lon <= 137.8347 && lat >= 0.8293 && lat <= 55.8271; }
function txLt(x, y) { let r = -100+2*x+3*y+0.2*y*y+0.1*x*y+0.2*Math.sqrt(Math.abs(x)); r+=(20*Math.sin(6*x*Math.PI)+20*Math.sin(2*x*Math.PI))*2/3; r+=(20*Math.sin(y*Math.PI)+40*Math.sin(y/3*Math.PI))*2/3; r+=(160*Math.sin(y/12*Math.PI)+320*Math.sin(y*Math.PI/30))*2/3; return r; }
function txLn(x, y) { let r = 300+x+2*y+0.1*x*x+0.1*x*y+0.1*Math.sqrt(Math.abs(x)); r+=(20*Math.sin(6*x*Math.PI)+20*Math.sin(2*x*Math.PI))*2/3; r+=(20*Math.sin(x*Math.PI)+40*Math.sin(x/3*Math.PI))*2/3; r+=(150*Math.sin(x/12*Math.PI)+300*Math.sin(x/30*Math.PI))*2/3; return r; }
function wgs84ToGcj02(lon, lat) {
  if (!isInChina(lon, lat)) return [lon, lat];
  const a=6378245,ee=0.00669342162296594323;
  let dLat=txLt(lon-105,lat-35),dLon=txLn(lon-105,lat-35);
  const rad=lat/180*Math.PI,m=1-ee*Math.sin(rad)*Math.sin(rad),s=Math.sqrt(m);
  dLat=dLat*180/((a*(1-ee))/(m*s)*Math.PI); dLon=dLon*180/(a/s*Math.cos(rad)*Math.PI);
  return [lon+dLon,lat+dLat];
}
function toAmapPoint(p) { return wgs84ToGcj02(Number(p[0]), Number(p[1])); }

// ---- Helpers ----
const CITY_RADIUS = { 南京:38,杭州:42,宿迁:42,眉山:40,合肥:42,上海:36,北京:48,苏州:36,无锡:34,常州:36 };

function buildCityAreas() {
  const areas = new Map();
  const routeMap = new Map(); store.routes.forEach(r => routeMap.set(r.id, r));
  for (const race of store.races) {
    if (race.type !== "marathon" && race.type !== "half_marathon") continue;
    const route = routeMap.get(race.route_id);
    if (!route?.preview_coordinates?.length) continue;
    const key = race.city || race.name;
    const a = areas.get(key) || { city: race.city, names: [], coordinates: [] };
    a.names.push(race.name); a.coordinates.push(...route.preview_coordinates); areas.set(key, a);
  }
  return areas;
}

function getCityCenter(coords) {
  const lats = coords.map(p => p[1]), lons = coords.map(p => p[0]);
  return [lats.reduce((a,b)=>a+b,0)/lats.length, lons.reduce((a,b)=>a+b,0)/lons.length];
}

// ---- Tile (Leaflet) ----
function getTileProviders() {
  const theme = document.documentElement.dataset.theme || "dark";
  const s = theme === "light" ? "light_all" : "dark_all";
  return [
    { url: `https://{s}.basemaps.cartocdn.com/${s}/{z}/{x}/{y}{r}.png`, subs: "abcd" },
    { url: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", subs: "abc" },
  ];
}

function addResilientTileLayer(map) {
  const provs = getTileProviders();
  let idx = 0, layer = null, started = 0, done = 0, failed = 0, timer = null;
  function clear() { if (timer) { clearTimeout(timer); timer = null; } }
  function schedule() {
    clear(); timer = setTimeout(() => { if (started >= 4 && done < Math.min(4, Math.ceil(started/2))) activate(idx + 1); }, 4500);
  }
  function activate(i) {
    if (i >= provs.length) return; clear(); idx = i;
    if (layer && map.hasLayer(layer)) map.removeLayer(layer);
    started = done = failed = 0;
    const p = provs[i];
    layer = window.L.tileLayer(p.url, {
      maxZoom: 19, subdomains: p.subs,
      updateWhenIdle: isMobileViewport(), keepBuffer: isMobileViewport() ? 4 : 2, crossOrigin: true,
    });
    heroTileLayer = layer;
    layer.on("tileloadstart", () => { if (layer !== heroTileLayer) return; started++; schedule(); });
    layer.on("tileload", () => { if (layer !== heroTileLayer) return; done++; if (done >= 4) clear(); });
    layer.on("tileerror", () => { if (layer !== heroTileLayer) return; failed++; if (failed >= 2 || (started >= 4 && done === 0)) activate(idx + 1); });
    layer.addTo(map);
  }
  activate(0); return layer;
}

function initMobileDblTap(map, el) {
  if (el.dataset.dtap === "1") return; el.dataset.dtap = "1";
  let last = 0, pt = null;
  el.addEventListener("touchend", e => {
    if (!isMobileViewport() || e.changedTouches.length !== 1 || e.touches.length) return;
    if (e.target.closest?.(".leaflet-control")) return;
    const t = e.changedTouches[0], now = Date.now();
    const p = { x: t.clientX, y: t.clientY }, dist = pt ? Math.hypot(p.x-pt.x, p.y-pt.y) : Infinity;
    if (now-last <= 320 && dist <= 42) {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      const ll = map.containerPointToLatLng(window.L.point(p.x-r.left, p.y-r.top));
      map.setZoomAround(ll, Math.min(map.getZoom()+1, map.getMaxZoom?.()||19));
      last = 0; pt = null; return;
    }
    last = now; pt = p;
  }, { passive: false });
}

// ============================================
//  AMap Init
// ============================================
async function initAmap(el, cityAreas) {
  const cfg = await fetchAmapConfig();
  heroMapEngine = "amap"; el.dataset.mapEngine = "amap";

  heroMap = new window.AMap.Map(el, {
    attributionControl: false, center: toAmapPoint([118.75, 32.02]),
    doubleClickZoom: true, dragEnable: true, jogEnable: false,
    mapStyle: cfg.styles[document.documentElement.dataset.theme || "light"],
    resizeEnable: true, scrollWheel: !isMobileViewport(),
    touchZoom: true, viewMode: "2D", zoom: 5, zoomEnable: true,
  });

  // Tile load watchdog: if no tiles within 6s, AMap likely blocked → fallback
  let tilesLoaded = false;
  let watchdog = setTimeout(() => {
    if (!tilesLoaded) {
      console.warn("AMap tiles not loading, switching to Leaflet");
      fallbackToLeaflet(el, buildCityAreas());
    }
  }, 6000);

  heroMap.on("complete", () => { tilesLoaded = true; clearTimeout(watchdog); });

  heroCityLayer = [];
  let bounds = null;
  for (const area of cityAreas.values()) {
    const boundary = store.cityBoundaries.find(b => b.city === area.city);
    if (boundary) {
      const rings = extractGeoJsonRings(boundary.geojson);
      rings.forEach(ring => {
        const poly = new window.AMap.Polygon({
          path: ring.map(toAmapPoint), strokeColor: "#ff8a6e", strokeOpacity: 0.32,
          strokeWeight: 1, fillColor: "#ff5e3a", fillOpacity: 0.12, zIndex: 12,
        });
        heroCityLayer.push(poly); heroMap.add(poly);
        bounds = bounds ? (bounds.union?.(poly.getBounds()) || bounds) : poly.getBounds();
      });
    } else {
      const center = getCityCenter(area.coordinates);
      const radiusKm = CITY_RADIUS[area.city] || 36;
      const circle = new window.AMap.Circle({
        center: toAmapPoint([center[1], center[0]]), radius: radiusKm * 1000,
        strokeOpacity: 0, strokeWeight: 0, fillColor: "#ff5e3a", fillOpacity: 0.11, zIndex: 12,
      });
      heroCityLayer.push(circle); heroMap.add(circle);
    }
  }

  if (heroCityLayer.length) {
    heroMap.setFitView(heroCityLayer, false, [80, 120, 80, 120]);
    defaultMapBounds = heroCityLayer;
    const c = heroMap.getCenter(); defaultMapCenter = [c.lng, c.lat]; defaultMapZoom = heroMap.getZoom();
  }

  // Runtime error detection (AMap domain/auth errors)
  let runtimeFailed = false;
  function onErr(ev) {
    const msg = (ev.message || "") + (ev.filename || "");
    if (msg.includes("webapi.amap.com") || msg.includes("INVALID_USER_DOMAIN") || msg.includes("USERKEY")) {
      runtimeFailed = true;
    }
  }
  window.addEventListener("error", onErr, true);
  setTimeout(() => {
    window.removeEventListener("error", onErr, true);
    if (runtimeFailed) { clearTimeout(watchdog); fallbackToLeaflet(el, buildCityAreas()); }
  }, 2500);

  new MutationObserver(() => setTimeout(invalidateMapSize, 350))
    .observe(document.body, { attributes: true, attributeFilter: ["class"] });
}

function extractGeoJsonRings(geojson) {
  const rings = [];
  function read(g) {
    if (!g) return;
    if (g.type === "Polygon") { if (g.coordinates?.[0]?.length) rings.push(g.coordinates[0]); }
    else if (g.type === "MultiPolygon") g.coordinates?.forEach(p => { if (p?.[0]?.length) rings.push(p[0]); });
  }
  if (geojson.type === "FeatureCollection") geojson.features?.forEach(f => read(f.geometry));
  else if (geojson.type === "Feature") read(geojson.geometry);
  else read(geojson);
  return rings;
}

// ============================================
//  Leaflet Init
// ============================================
async function initLeaflet(el, cityAreas) {
  heroMapEngine = "leaflet"; el.dataset.mapEngine = "leaflet";

  heroMap = window.L.map(el, {
    attributionControl: false, zoomControl: !isMobileViewport(),
    scrollWheelZoom: !isMobileViewport(), doubleClickZoom: true, tap: true, touchZoom: true,
  });
  if (isMobileViewport()) initMobileDblTap(heroMap, el);
  heroTileLayer = addResilientTileLayer(heroMap);

  heroCityLayer = window.L.featureGroup().addTo(heroMap);
  let cityBounds = null;
  for (const area of cityAreas.values()) {
    const boundary = store.cityBoundaries.find(b => b.city === area.city);
    if (boundary) {
      const lyr = window.L.geoJSON(boundary.geojson, {
        style: { color: "#ff8a6e", fillColor: "#ff5e3a", fillOpacity: 0.12, opacity: 0.32, weight: 1 },
      }).bindTooltip(`${area.city}<br><small>${area.names.length} 场比赛</small>`, { direction: "top" }).addTo(heroCityLayer);
      const b = lyr.getBounds(); cityBounds = cityBounds ? cityBounds.extend(b) : b;
    } else {
      const center = getCityCenter(area.coordinates);
      const rkm = CITY_RADIUS[area.city] || 36;
      window.L.circle(center, {
        radius: rkm * 1000, color: "#ff8a6e", fillColor: "#ff5e3a",
        fillOpacity: 0.11, opacity: 0, weight: 0, interactive: true,
      }).bindTooltip(`${area.city}<br><small>${area.names.length} 场比赛</small>`, { direction: "top" }).addTo(heroCityLayer);
      const ld = rkm / 111, lod = rkm / (111 * Math.max(Math.cos(center[0] * Math.PI / 180), 0.2));
      const b = window.L.latLngBounds([center[0]-ld, center[1]-lod], [center[0]+ld, center[1]+lod]);
      cityBounds = cityBounds ? cityBounds.extend(b) : b;
    }
  }
  if (cityBounds) {
    heroMap.fitBounds(cityBounds, { padding: [80, 120] });
    defaultMapBounds = cityBounds;
    defaultMapCenter = [cityBounds.getCenter().lat, cityBounds.getCenter().lng];
    defaultMapZoom = heroMap.getZoom();
  }
  new MutationObserver(() => setTimeout(invalidateMapSize, 350))
    .observe(document.body, { attributes: true, attributeFilter: ["class"] });
}

async function fallbackToLeaflet(el, cityAreas) {
  console.warn("AMap failed, falling back to Leaflet");
  resetMapState(); el.innerHTML = "";
  try {
    await loadLeaflet();
    if (window.L) await initLeaflet(el, cityAreas);
  } catch (e) {
    console.warn("All map engines failed:", e.message);
  }
}

// ---- Main init ----
export async function initHeroMap() {
  const el = document.getElementById("heroMap");
  if (!el) return;

  const cityAreas = buildCityAreas();

  // Wait briefly for city boundaries
  if (!store.cityBoundaries.length) await new Promise(r => setTimeout(r, 300));

  // Try AMap first
  try {
    await loadAmap();
    if (window.AMap) {
      await initAmap(el, cityAreas);
      store.mapReady = true; notify("map-ready"); addMapToggle(); return;
    }
  } catch (e) { console.warn("AMap load failed:", e.message); }

  // Fallback to Leaflet
  try {
    await loadLeaflet();
    if (window.L) {
      await initLeaflet(el, cityAreas);
      store.mapReady = true; notify("map-ready"); addMapToggle(); return;
    }
  } catch (e) { console.warn("Leaflet load failed:", e.message); }
}

// ---- Toggle button ----
function addMapToggle() {
  const existing = document.getElementById("mapEngineToggle");
  if (existing) existing.remove();

  const btn = document.createElement("button");
  btn.id = "mapEngineToggle"; btn.type = "button";
  btn.className = "map-engine-toggle";
  updateToggleLabel(btn);

  btn.addEventListener("click", async () => {
    btn.disabled = true; btn.textContent = "切换中...";
    try {
      const el = document.getElementById("heroMap");
      const rid = store.heroActiveRouteId;
      const src = store.activeRouteSource;

      if (heroMapEngine === "amap") {
        resetMapState(); el.innerHTML = "";
        await loadLeaflet();
        if (!window.L) throw new Error("Leaflet unavailable");
        await initLeaflet(el, buildCityAreas());
      } else {
        resetMapState(); el.innerHTML = "";
        await loadAmap();
        if (!window.AMap) throw new Error("AMap unavailable");
        await initAmap(el, buildCityAreas());
      }
      store.mapReady = true; notify("map-ready"); addMapToggle();

      if (rid) updateHeroRoute(rid, true, src);
      if (store.activePanelTab === "stats") { showAllRoutesOnMap(store.routes, "stats"); hideCityLayer(); setStatsView(); }
    } catch (e) { console.warn("Map switch failed:", e); }
    finally { btn.disabled = false; updateToggleLabel(btn); }
  });

  // Place below summary strip
  const container = document.getElementById("summaryStrip")?.parentElement;
  if (container) container.appendChild(btn);
}

function updateToggleLabel(btn) {
  btn.innerHTML = heroMapEngine === "amap" ? "🗺️ 高德" : "🗺️ Leaflet";
  btn.title = heroMapEngine === "amap" ? "当前：高德地图 | 点击切换" : "当前：Leaflet | 点击切换";
}

function resetMapState() {
  if (heroMap?.destroy) { try { heroMap.destroy(); } catch (_) {} }
  heroMap = null; heroTileLayer = null; heroRouteLine = null;
  heroCityLayer = null; heroAllRoutesLayer = null;
  defaultMapBounds = null; defaultMapCenter = null; defaultMapZoom = null;
}

// ---- Public API ----
export function invalidateMapSize() {
  if (heroMapEngine === "amap") heroMap?.resize?.();
  else if (heroMap?.invalidateSize) heroMap.invalidateSize();
}

export function hideCityLayer() {
  if (!heroCityLayer || !heroMap) return;
  if (heroMapEngine === "amap") heroCityLayer.forEach(o => heroMap.remove(o));
  else heroMap.removeLayer(heroCityLayer);
}

export function showCityLayer() {
  if (!heroCityLayer || !heroMap) return;
  if (heroMapEngine === "amap") heroCityLayer.forEach(o => heroMap.add(o));
  else if (!heroMap.hasLayer(heroCityLayer)) heroCityLayer.addTo(heroMap);
}

export function setStatsView() {
  // Fit map to show the extent of all routes
  let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
  for (const route of store.routes) {
    const coords = route.preview_coordinates || route.coordinates;
    if (!coords?.length) continue;
    const lats = coords.map(p => p[1]);
    const lons = coords.map(p => p[0]);
    minLat = Math.min(minLat, ...lats);
    maxLat = Math.max(maxLat, ...lats);
    minLon = Math.min(minLon, ...lons);
    maxLon = Math.max(maxLon, ...lons);
  }

  if (minLat > maxLat) {
    // No coordinates found, fallback
    if (heroMapEngine === "amap") heroMap?.setZoomAndCenter?.(5, toAmapPoint([118.75, 32.02]));
    else if (heroMap?.setView) heroMap.setView([32.02, 118.75], 5);
    return;
  }

  if (heroMapEngine === "amap") {
    const sw = toAmapPoint([minLon, minLat]);
    const ne = toAmapPoint([maxLon, maxLat]);
    const bounds = new window.AMap.Bounds(sw, ne);
    heroMap?.setFitView?.([{ getBounds: () => bounds }], false, [80, 120, 80, 120]);
  } else if (window.L) {
    heroMap?.fitBounds([[minLat, minLon], [maxLat, maxLon]], { padding: [80, 120] });
  }
}

export function restoreDefaultView() {
  if (!heroMap) return;
  if (heroMapEngine === "amap") {
    if (defaultMapBounds?.length) heroMap.setFitView(defaultMapBounds, false, [80, 120, 80, 120]);
    else if (defaultMapCenter && defaultMapZoom) heroMap.setZoomAndCenter(defaultMapZoom, defaultMapCenter);
  } else {
    if (defaultMapBounds) heroMap.fitBounds(defaultMapBounds, { padding: [80, 120] });
    else if (defaultMapCenter && defaultMapZoom) heroMap.setView(defaultMapCenter, defaultMapZoom);
  }
}

export function updateHeroRoute(routeId, fit = true, source = "route") {
  if (!heroMap) return;
  store.heroActiveRouteId = routeId; store.activeRouteSource = source;

  if (heroRouteLine) {
    if (heroMapEngine === "amap") heroMap.remove(heroRouteLine);
    else heroMap.removeLayer(heroRouteLine);
    heroRouteLine = null;
  }
  hideCityLayer();

  const route = store.routes.find(r => r.id === routeId);
  const coords = route?.preview_coordinates || route?.coordinates;
  if (!coords?.length) { notify("route"); return; }

  if (heroMapEngine === "amap") {
    heroRouteLine = new window.AMap.Polyline({
      path: coords.map(toAmapPoint), strokeColor: "#3b8bff", strokeWeight: 5,
      strokeOpacity: 0.92, lineJoin: "round", lineCap: "round", zIndex: 30,
    });
    heroMap.add(heroRouteLine);
    if (fit) heroMap.setFitView([heroRouteLine], false, [80, 120, 80, 120]);
  } else if (window.L) {
    const latlngs = coords.map(([lon, lat]) => [lat, lon]);
    heroRouteLine = window.L.polyline(latlngs, {
      color: "#3b8bff", weight: 5, opacity: 0.92, lineJoin: "round", lineCap: "round",
    }).addTo(heroMap);
    if (fit) heroMap.fitBounds(heroRouteLine.getBounds(), { padding: [80, 120] });
  }
  notify("route");
}

export function showAllRoutesOnMap(routesToShow = store.routes, overlayMode = "stats") {
  if (!heroMap) return;
  const overlayRoutes = routesToShow.filter(r => (r.preview_coordinates || r.coordinates)?.length >= 2);
  const nextKey = `${heroMapEngine}:${overlayMode}:${overlayRoutes.map(r => r.id).join("|")}`;

  if (heroAllRoutesLayer && routeOverlayKey !== nextKey) { hideAllRoutesFromMap(); heroAllRoutesLayer = null; }
  routeOverlayKey = nextKey;

  if (heroMapEngine === "amap") {
    if (heroAllRoutesLayer) { heroAllRoutesLayer.forEach(o => heroMap.add(o)); return; }
    const marathonIds = new Set(store.races.filter(r => r.type === "marathon" || r.type === "half_marathon").map(r => r.route_id).filter(Boolean));
    heroAllRoutesLayer = [];
    for (const route of overlayRoutes) {
      const coords = route.preview_coordinates || route.coordinates;
      if (!coords?.length) continue;
      const isRace = marathonIds.has(route.id), isHeat = overlayMode === "heat";
      const poly = new window.AMap.Polyline({
        path: coords.map(toAmapPoint),
        strokeColor: isRace ? "#ff8a6e" : isHeat ? "#3b8bff" : "#4a6a8a",
        strokeWeight: isRace ? 2.4 : isHeat ? 1.8 : 1,
        strokeOpacity: isRace ? 0.58 : isHeat ? 0.44 : 0.28,
        lineJoin: "round", lineCap: "round", bubble: true, zIndex: isRace ? 18 : 16,
      });
      heroAllRoutesLayer.push(poly); heroMap.add(poly);
    }
    return;
  }
  if (!window.L) return;
  if (heroAllRoutesLayer) { if (!heroMap.hasLayer(heroAllRoutesLayer)) heroAllRoutesLayer.addTo(heroMap); return; }
  heroAllRoutesLayer = window.L.featureGroup().addTo(heroMap);
  const marathonIds = new Set(store.races.filter(r => r.type === "marathon" || r.type === "half_marathon").map(r => r.route_id).filter(Boolean));
  for (const route of overlayRoutes) {
    const coords = route.preview_coordinates || route.coordinates;
    if (!coords?.length) continue;
    const latlngs = coords.map(([lon, lat]) => [lat, lon]);
    const isRace = marathonIds.has(route.id), isHeat = overlayMode === "heat";
    window.L.polyline(latlngs, {
      color: isRace ? "#ff8a6e" : isHeat ? "#3b8bff" : "#4a6a8a",
      weight: isRace ? 1.8 : isHeat ? 1.2 : 0.8,
      opacity: isRace ? 0.56 : isHeat ? 0.42 : 0.28, interactive: false,
    }).addTo(heroAllRoutesLayer);
  }
}

export function hideAllRoutesFromMap() {
  if (!heroAllRoutesLayer || !heroMap) return;
  if (heroMapEngine === "amap") heroAllRoutesLayer.forEach(o => heroMap.remove(o));
  else heroMap.removeLayer(heroAllRoutesLayer);
}

export function clearHeroRoute() {
  if (heroRouteLine) {
    if (heroMapEngine === "amap") heroMap?.remove(heroRouteLine);
    else heroMap?.removeLayer(heroRouteLine);
    heroRouteLine = null;
  }
  store.heroActiveRouteId = null;
  const hero = document.querySelector(".hero");
  if (hero) hero.classList.remove("hero--route-selected", "hero--race-selected");
}

export async function switchMapTiles() {
  if (!heroMap) return;
  if (heroMapEngine === "amap") {
    const cfg = await fetchAmapConfig();
    heroMap.setMapStyle(cfg.styles[document.documentElement.dataset.theme || "light"]);
    return;
  }
  if (!window.L) return;
  heroMap.eachLayer(layer => { if (layer instanceof window.L.TileLayer) heroMap.removeLayer(layer); });
  heroTileLayer = addResilientTileLayer(heroMap);
}
