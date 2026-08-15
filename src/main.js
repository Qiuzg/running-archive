/**
 * Running Archive v2 — Main entry point.
 */
import { store, rebuildDerivedData, setActiveTab, subscribe } from "./state.js";
import { fetchRaces, fetchRoutes, fetchRuns, fetchCities } from "./api.js";
import { renderSummary } from "./render/summary.js";
import { renderPanelContent } from "./render/panel-content.js";
import { renderStatsOverlay, clearStatsOverlay } from "./render/overlay.js";
import { initHeroMap, showAllRoutesOnMap, hideAllRoutesFromMap, hideCityLayer, showCityLayer, setStatsView, restoreDefaultView, updateHeroRoute, clearHeroRoute } from "./map.js";
import { initTheme, bindThemeToggle } from "./ui/theme.js";
import { initPanelCollapse, syncMobileStatsOverlayLayout } from "./ui/panel.js";
import { initRouter, handleRoute, syncUrlFromState, navigate } from "./ui/router.js";

async function loadData() {
  const [races, routes, runs, cities] = await Promise.all([
    fetchRaces(),
    fetchRoutes(),
    fetchRuns(),
    fetchCities(),
  ]);
  store.races = races || [];
  store.routes = routes || [];
  store.runs = runs || [];
  store.cityBoundaries = cities || [];
  rebuildDerivedData();
}

function switchPanelTab(tab) {
  // Note: store.activePanelTab is already set by setActiveTab() before this is called.
  // Do NOT call setActiveTab() here — it would trigger notify("tab") → infinite recursion.
  clearStatsOverlay();
  clearHeroRoute();  // Remove selected route line and reset zoom

  // Update tab link active state
  document.querySelectorAll("[data-panel-tab]").forEach(link => {
    link.classList.toggle("is-active", link.dataset.panelTab === tab);
  });

  const eyebrow = document.getElementById("panelEyebrow");
  const title = document.getElementById("panelTitle");
  if (eyebrow) eyebrow.textContent = tab === "routes" ? "Route Atlas" : tab === "races" ? "Race Records" : "Year in Motion";
  if (title) title.textContent = tab === "routes" ? "路线足迹" : tab === "races" ? "比赛记录" : "年度统计";

  const toggle = document.getElementById("panelCollapseToggle");
  if (tab === "stats") {
    showAllRoutesOnMap(store.routes, "stats");
    hideCityLayer();
    setStatsView();
    if (toggle) toggle.style.display = "none";
  } else {
    hideAllRoutesFromMap();
    showCityLayer();
    restoreDefaultView();
    if (toggle) toggle.style.display = "";
  }

  setTimeout(() => import("./map.js").then(m => m.invalidateMapSize()), 100);
  renderPanelContent();
  syncUrlFromState();
}

async function init() {
  initTheme();
  bindThemeToggle();
  initPanelCollapse();

  // Must subscribe BEFORE initRouter — router triggers setActiveTab → notify("tab")
  subscribe("tab", () => switchPanelTab(store.activePanelTab));
  subscribe("route", () => {
    const routeId = store.heroActiveRouteId;
    document.querySelectorAll(".race-card[data-route-target], [data-hero-route]").forEach(el => {
      const target = el.dataset.routeTarget || el.dataset.heroRoute;
      el.classList.toggle("is-active", target === routeId);
    });
    const hero = document.querySelector(".hero");
    if (hero) {
      hero.classList.toggle("hero--route-selected", !!routeId);
      hero.classList.toggle("hero--race-selected", !!routeId && store.activeRouteSource === "race");
    }
    syncMobileStatsOverlayLayout();
    if (routeId && store.activeRouteSource === "route") navigate(`/route/${routeId}`);
  });
  subscribe("route", () => {
    if (store.heroActiveRouteId && store.activePanelTab !== "stats") {
      renderStatsOverlay(store.heroActiveRouteId);
    }
  });

  initRouter();

  await loadData();

  renderSummary();
  renderPanelContent();
  initHeroMap();

  document.querySelectorAll("[data-panel-tab]").forEach(link => {
    link.addEventListener("click", (e) => {
      e.preventDefault();
      navigate(`/${link.dataset.panelTab}`);
    });
  });

  window.addEventListener("resize", () => syncMobileStatsOverlayLayout());

  if (window.location.hash) await handleRoute();
  renderPanelContent();
}

init().catch(err => console.error("App initialization failed:", err));
