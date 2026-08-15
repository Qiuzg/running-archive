/**
 * Central reactive state — replaces the scattered closure variables in the original IIFE.
 * Components subscribe to changes they care about.
 */

// ---- Core data ----
export const store = {
  // Server-fetched data
  races: [],
  runs: [],
  routes: [],
  cityBoundaries: [],
  profile: {},

  // Derived
  marathonTimeline: [],
  activityItems: [],
  routeEntries: [],
  availableYears: [],

  // UI state
  activePanelTab: "routes",
  heroActiveRouteId: null,
  activeRouteSource: "route", // "route" | "race"
  routeDistanceFilter: "all",
  routeVisibleCount: 80,
  routeHeatMode: false,
  selectedStatsYear: null,
  selectedStatsMonth: null,
  panelCollapsed: false,

  // Route detail cache (full coordinates + timeSeries)
  routeDetailCache: {},

  // Map engine state
  mapEngine: "leaflet",
  mapReady: false,
};

// ---- Subscribers ----
const listeners = new Map();

export function subscribe(key, fn) {
  if (!listeners.has(key)) listeners.set(key, new Set());
  listeners.get(key).add(fn);
  return () => listeners.get(key)?.delete(fn);
}

export function notify(key) {
  listeners.get(key)?.forEach((fn) => fn());
}

// ---- Convenience setters that trigger notifications ----
export function setActiveTab(tab) {
  store.activePanelTab = tab;
  store.heroActiveRouteId = null;
  notify("tab");
}

export function setActiveRoute(routeId, source = "route") {
  store.heroActiveRouteId = routeId;
  store.activeRouteSource = source;
  notify("route");
}

export function setStatsYear(year) {
  store.selectedStatsYear = year;
  notify("stats");
}

export function setStatsMonth(month) {
  store.selectedStatsMonth = month;
  notify("stats-month");
}

export function setRouteFilter(filter) {
  store.routeDistanceFilter = filter;
  store.routeVisibleCount = 80;
  notify("routes");
}

export function toggleRouteHeat() {
  store.routeHeatMode = !store.routeHeatMode;
  notify("routes-heat");
}

export function loadMoreRoutes() {
  store.routeVisibleCount += 80;
  notify("routes");
}

export function cacheRouteDetail(routeId, detail) {
  store.routeDetailCache[routeId] = detail;
}

// ---- Derived data builders (called after fetching) ----
export function rebuildDerivedData() {
  const { races, runs } = store;

  // Marathon timeline
  store.marathonTimeline = races
    .filter((r) => r.type === "marathon")
    .sort((a, b) => new Date(b.date) - new Date(a.date));

  // Activity items: races + non-race runs
  const raceSourceIds = new Set(races.map((r) => r.id).filter(Boolean));
  store.activityItems = [
    ...races.map((item) => ({ ...item, source: "race" })),
    ...runs
      .filter((item) => !raceSourceIds.has(item.id))
      .map((item) => ({ ...item, source: "run" })),
  ].sort((a, b) => new Date(b.date) - new Date(a.date));

  // Route entries
  const routeMap = new Map();
  store.routes.forEach((r) => routeMap.set(r.id, r));

  store.routeEntries = store.activityItems
    .filter((item) => item.route_id && routeMap.has(item.route_id))
    .sort((a, b) => new Date(b.date) - new Date(a.date));

  // Available years
  store.availableYears = [
    ...new Set(
      store.activityItems.map((item) => Number(String(item.date || "").slice(0, 4)))
    ),
  ]
    .filter((y) => Number.isFinite(y))
    .sort((a, b) => b - a);

  const currentYear = new Date().getFullYear();
  if (!store.selectedStatsYear || !store.availableYears.includes(store.selectedStatsYear)) {
    store.selectedStatsYear = store.availableYears.includes(currentYear)
      ? currentYear
      : store.availableYears[0] || currentYear;
  }
}
