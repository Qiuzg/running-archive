/**
 * Client-side URL routing via hash.
 * Supports:
 *   /#/routes              → routes tab
 *   /#/atlas               → long-distance route atlas
 *   /#/races               → races tab
 *   /#/stats/2025          → stats tab, year 2025
 *   /#/stats/2025/3        → stats tab, year 2025, month 3
 *   /#/route/<routeId>     → selects a specific route
 */
import { store, setActiveTab, setStatsYear, setStatsMonth } from "../state.js";
import { updateHeroRoute } from "../map.js";

const SHARE_LAB_PATTERN = /^\/share-lab-7k3m9x2p\/?$/;

// Match patterns: /routes, /atlas, /races, /stats/2025, /stats/2025/3, /route/apple-20230409-080438
const ROUTE_PATTERNS = [
  { pattern: SHARE_LAB_PATTERN, handler: () => {} },
  { pattern: /^\/routes\/?$/, handler: () => { setActiveTab("routes"); } },
  { pattern: /^\/atlas\/?$/, handler: () => { setActiveTab("atlas"); } },
  { pattern: /^\/races\/?$/, handler: () => { setActiveTab("races"); } },
  { pattern: /^\/stats\/(\d{4})\/(\d{1,2})\/?$/, handler: (m) => {
    setActiveTab("stats");
    setStatsYear(Number(m[1]));
    setStatsMonth(Number(m[2]) - 1);
  }},
  { pattern: /^\/stats\/(\d{4})\/?$/, handler: (m) => {
    setActiveTab("stats");
    setStatsYear(Number(m[1]));
    store.selectedStatsMonth = null;
  }},
  { pattern: /^\/stats\/?$/, handler: () => { setActiveTab("stats"); } },
  { pattern: /^\/route\/(.+)$/, handler: (m) => {
    const routeId = m[1];
    store.heroActiveRouteId = routeId;
    store.activeRouteSource = "route";
    if (store.activePanelTab === "stats") setActiveTab("routes");
    updateHeroRoute(routeId, true, "route");
    // Do NOT call clearStatsOverlay() — overlay lifecycle is managed by the "route" subscriber
  }},
];

function parseHash() {
  const hash = window.location.hash.replace(/^#/, "") || "/routes";
  return hash;
}

export function handleRoute() {
  const path = parseHash();
  for (const { pattern, handler } of ROUTE_PATTERNS) {
    const match = path.match(pattern);
    if (match) {
      handler(match);
      return;
    }
  }
  // Default: routes tab
  setActiveTab("routes");
}

export function navigate(path) {
  const current = window.location.hash.replace(/^#/, "");
  // Don't trigger hashchange if already at the target path
  if (current === path) return;
  window.location.hash = "#" + path;
}

export function syncUrlFromState() {
  if (SHARE_LAB_PATTERN.test(parseHash())) return;
  const { activePanelTab, selectedStatsYear, selectedStatsMonth } = store;
  let path;
  if (activePanelTab === "stats") {
    if (selectedStatsMonth !== null) {
      path = `/stats/${selectedStatsYear}/${selectedStatsMonth + 1}`;
    } else {
      path = `/stats/${selectedStatsYear}`;
    }
  } else {
    path = `/${activePanelTab}`;
  }
  const current = window.location.hash.replace(/^#/, "");
  if (current !== path) {
    window.history.replaceState(null, "", "#" + path);
  }
}

export function initRouter() {
  window.addEventListener("hashchange", () => {
    handleRoute();
    syncUrlFromState();
  });
  // Initial route
  if (window.location.hash) {
    handleRoute();
  }
}
