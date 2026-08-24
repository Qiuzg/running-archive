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
import { initShareLab } from "./share-lab.js";

async function loadData() {
  const loaders = [
    ["races", fetchRaces],
    ["routes", fetchRoutes],
    ["runs", fetchRuns],
    ["cityBoundaries", fetchCities],
  ];
  const results = await Promise.allSettled(loaders.map(([, fn]) => fn()));
  const failures = [];

  results.forEach((result, index) => {
    const [key] = loaders[index];
    if (result.status === "fulfilled") {
      store[key] = result.value || [];
      return;
    }
    store[key] = [];
    failures.push({ key, error: result.reason });
    console.error(`Failed to load ${key}:`, result.reason);
  });

  rebuildDerivedData();
  return failures;
}

function renderLoadWarning(failures) {
  if (!failures.length) return;
  const body = document.getElementById("heroPanelBody");
  if (!body) return;

  const labels = {
    races: "比赛",
    routes: "路线",
    runs: "训练",
    cityBoundaries: "城市边界",
  };
  const warning = document.createElement("p");
  warning.className = "empty empty--compact app-load-warning";
  warning.textContent = `${failures.map((item) => labels[item.key] || item.key).join("、")}数据暂时加载失败，页面已先显示可用内容。`;
  body.prepend(warning);
}

function renderLoadingState() {
  const body = document.getElementById("heroPanelBody");
  if (!body) return;
  body.innerHTML = '<p class="empty app-load-warning">数据加载中...</p>';
}

function renderFatalInitError(err) {
  console.error("App initialization failed:", err);
  const body = document.getElementById("heroPanelBody");
  if (!body) return;
  body.innerHTML = "";
  const message = document.createElement("p");
  message.className = "empty app-load-warning";
  message.textContent = "页面初始化失败，请刷新重试。";
  body.append(message);
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

  const panelLabels = {
    routes: ["Route Atlas", "路线足迹"],
    atlas: ["Long Run Atlas", "长距离轨迹"],
    races: ["Race Records", "比赛记录"],
    stats: ["Year in Motion", "年度统计"],
  };
  const [eyebrowText, titleText] = panelLabels[tab] || panelLabels.routes;
  const eyebrow = document.getElementById("panelEyebrow");
  const title = document.getElementById("panelTitle");
  if (eyebrow) eyebrow.textContent = eyebrowText;
  if (title) title.textContent = titleText;

  const hero = document.querySelector(".hero");
  hero?.classList.toggle("hero--atlas", tab === "atlas");

  const toggle = document.getElementById("panelCollapseToggle");
  if (tab === "stats") {
    showAllRoutesOnMap(store.routes, "stats");
    hideCityLayer();
    setStatsView();
    if (toggle) toggle.style.display = "none";
  } else if (tab === "atlas") {
    hideAllRoutesFromMap();
    hideCityLayer();
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
  subscribe("map-ready", () => {
    if (store.activePanelTab === "stats") {
      showAllRoutesOnMap(store.routes, "stats");
      hideCityLayer();
      setStatsView();
    }
  });
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

  renderLoadingState();
  initRouter();

  const loadFailures = await loadData();

  initShareLab();

  renderSummary();
  renderPanelContent();
  renderLoadWarning(loadFailures);
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

init().catch(renderFatalInitError);
