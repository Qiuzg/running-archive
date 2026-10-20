import { refreshLiveData } from "./live-data.js";
import { ensureRoutePreviews } from "./preview-loader.js";
/**
 * Running Archive v2 — Main entry point.
 */
import { store, subscribe } from "./state.js";
import { loadData } from "./data-loader.js";
import { syncHeatOverlay } from "./render/routes-panel.js";
import { renderSummary } from "./render/summary.js";
import { renderPanelContent } from "./render/panel-content.js";
import { renderStatsOverlay, clearStatsOverlay } from "./render/overlay.js";
import { initHeroMap, loadAmap, syncMapView, refreshMapData, hideAllRoutesFromMap, hideCityLayer, showCityLayer, updateHeroRoute, clearHeroRoute } from "./map.js";
import { initTheme, bindThemeToggle } from "./ui/theme.js";
import { initPanelCollapse, syncMobileStatsOverlayLayout } from "./ui/panel.js";
import { initRouter, handleRoute, syncUrlFromState, navigate } from "./ui/router.js";
import { initShareLab } from "./share-lab.js";

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
  const focused = document.activeElement;
  const focusSelector = tab === 'stats' && focused?.closest('.panel-content')
    ? focused.matches('[data-month]') ? `[data-month="${focused.dataset.month}"]`
    : focused.matches('[data-day]') ? `[data-day="${focused.dataset.day}"]`
    : focused.matches('.review-year select') ? '.review-year select' : null : null;
  clearStatsOverlay();
  clearHeroRoute();  // Remove selected route line and reset zoom

  // Update tab link active state
  document.querySelectorAll("[data-panel-tab]").forEach(link => {
    link.classList.toggle("is-active", link.dataset.panelTab === tab);
    if (link.dataset.panelTab === tab) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
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
  hero?.classList.toggle("hero--stats-full", tab === "stats");

  const toggle = document.getElementById("panelCollapseToggle");
  if (tab === "stats") {
    hideAllRoutesFromMap();
    hideCityLayer();
    if (toggle) toggle.style.display = "none";
  } else if (tab === "atlas") {
    hideAllRoutesFromMap();
    hideCityLayer();
    if (toggle) toggle.style.display = "none";
  } else {
    hideAllRoutesFromMap();
    showCityLayer();

    if (toggle) toggle.style.display = "";
  }


  if (tab === "routes") syncHeatOverlay();
  renderPanelContent();
  if (tab === 'routes' || tab === 'races') {
    window.scrollTo({ top: 0, behavior: 'instant' });
    syncMapView();
  }
  if (focusSelector) document.querySelector(focusSelector)?.focus({preventScroll: true});
}

async function init() {
  initTheme();
  bindThemeToggle();
  initPanelCollapse();

  // Must subscribe BEFORE initRouter — router triggers setActiveTab → notify("tab")
  subscribe("tab", () => switchPanelTab(store.activePanelTab));
  subscribe('thumbnails', () => {
    if (['routes', 'races'].includes(store.activePanelTab)) renderPanelContent();
  });
  subscribe('previews', () => {
    renderPanelContent();
    if (store.activePanelTab === 'routes' && store.routeHeatMode) syncHeatOverlay();
  });
  subscribe("map-ready", () => {
    if (store.activePanelTab === 'routes') syncHeatOverlay();
    if (['stats', 'atlas'].includes(store.activePanelTab)) hideCityLayer();
    if (store.heroActiveRouteId) updateHeroRoute(store.heroActiveRouteId, true, store.activeRouteSource);
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
    if (routeId && store.activeRouteSource === "route") navigate(`/route/${encodeURIComponent(routeId)}`);
  });
  subscribe("route", () => {
    if (store.heroActiveRouteId && store.activePanelTab !== "stats") {
      renderStatsOverlay(store.heroActiveRouteId);
    }
  });

  renderLoadingState();
  initRouter();

  document.addEventListener('click', async event => {
    if (event.target.closest('[data-retry-previews]')) {
      ensureRoutePreviews(store.routes.filter(route => route.preview_error).map(route => route.id), { retry: true });
      return;
    }
    if (!event.target.closest('[data-retry-load]') || store.dataLoading) return;
    const pending = loadData();
    renderPanelContent();
    await pending;
    renderSummary();
    renderPanelContent();
    await refreshMapData();
    if (store.activePanelTab === 'routes') syncHeatOverlay();
  });
  // Download the map SDK while the API requests are in flight.
  loadAmap().catch(() => {});
  await loadData({ onProgress: () => {
    renderSummary();
    renderPanelContent();
  } });

  initShareLab();

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

  handleRoute();
  syncUrlFromState();
  renderPanelContent();
}

init().catch(renderFatalInitError);

// Check lightweight versions; fetch lists only when server data changes.
let lastSnapshotCheck = 0;
async function refreshVisibleData() {
  if (document.hidden || store.dataLoading) return;
  try {
    const changed = await refreshLiveData();
    const snapshotDue = Date.now() - lastSnapshotCheck >= 60000;
    if (changed) renderSummary();
    if (changed || (snapshotDue && ['routes', 'races', 'atlas'].includes(store.activePanelTab))) {
      const panel = document.getElementById('heroPanelBody');
      const scroll = panel?.scrollTop;
      renderPanelContent();
      if (panel) panel.scrollTop = scroll;
      lastSnapshotCheck = Date.now();
    }
  } catch (error) {
    console.warn('Automatic data refresh will retry:', error.message);
  }
}
setInterval(refreshVisibleData, 15000);
document.addEventListener('visibilitychange', refreshVisibleData);
window.addEventListener('online', refreshVisibleData);
