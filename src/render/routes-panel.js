import { store, setRouteFilter, toggleRouteHeat, loadMoreRoutes } from "../state.js";
import { formatKm, formatShortDate, escapeAttr, renderRouteSvg } from "../utils.js";
import { updateHeroRoute, showAllRoutesOnMap, hideAllRoutesFromMap, showCityLayer } from "../map.js";

const ROUTE_FILTERS = [
  { key: "all", label: "全部" },
  { key: "middle", label: "日常" },
  { key: "long", label: "长距离" },
  { key: "race", label: "比赛" },
];

function getFilterBucket(activity, route) {
  const dist = route?.distance_km || activity.distance_km || 0;
  if (activity.source === "race") return "race";
  if (dist < 8) return "short";
  if (dist >= 16) return "long";
  return "middle";
}

function getFilteredEntries() {
  const routeMap = new Map();
  store.routes.forEach(r => routeMap.set(r.id, r));
  return store.routeEntries.filter((item) => {
    const route = routeMap.get(item.route_id);
    if (!route) return false;
    return store.routeDistanceFilter === "all" || getFilterBucket(item, route) === store.routeDistanceFilter;
  });
}

function renderFilterBar(filteredCount, totalCount) {
  return `
    <div class="route-tools">
      <div class="route-tools__filters" aria-label="路线距离筛选">
        ${ROUTE_FILTERS.map(f => `
          <button class="${store.routeDistanceFilter === f.key ? "is-active" : ""}" type="button" data-route-filter="${f.key}">
            ${f.label}
          </button>`).join("")}
      </div>
      <button class="route-heat-toggle ${store.routeHeatMode ? "is-active" : ""}" type="button" data-route-heat aria-pressed="${store.routeHeatMode}">
        筛选叠图
      </button>
      <small>${filteredCount} / ${totalCount} 条</small>
    </div>`;
}

export function renderRoutesPanel(container) {
  if (!store.routeEntries.length) {
    container.innerHTML = '<p class="empty">暂无路线数据</p>';
    return;
  }

  const routeMap = new Map();
  store.routes.forEach(r => routeMap.set(r.id, r));

  const filtered = getFilteredEntries();
  const visibleLimit = store.panelCollapsed ? 3 : store.routeVisibleCount;
  const visible = filtered.slice(0, visibleLimit);

  const routeList = visible.map((item) => {
    const route = routeMap.get(item.route_id);
    if (!route) return "";
    const dateStr = item.date ? formatShortDate(item.date) : null;
    const title = item.name || route.name || "未知路线";
    const dist = formatKm(route.distance_km || item.distance_km || 0);
    const isActive = item.route_id === store.heroActiveRouteId;
    const coords = route.preview_coordinates || route.coordinates;
    const svg = coords?.length ? renderRouteSvg({ ...route, coordinates: coords }, "mini") : '<div class="route-empty">--</div>';
    return `
      <button class="hero-route-item ${isActive ? "is-active" : ""}" type="button" data-hero-route="${escapeAttr(item.route_id)}">
        <span class="hero-route-item__thumb">${svg}</span>
        <span class="hero-route-item__info">
          <strong>${title}</strong>
          <span>${dateStr ? `${dateStr.year}/${dateStr.monthDay}` : "--"} · ${dist}</span>
        </span>
      </button>`;
  }).join("");

  container.innerHTML = `
    ${renderFilterBar(filtered.length, store.routeEntries.length)}
    ${routeList || '<p class="empty">当前筛选下没有路线。</p>'}
    ${store.panelCollapsed && filtered.length > 3 ? `<p class="panel-collapsed-hint">还有 ${filtered.length - 3} 条路线 · 点击 ▲ 展开</p>` : ""}
    ${!store.panelCollapsed && filtered.length > visible.length ? `<button class="panel-load-more" type="button" data-route-load-more>再显示 ${Math.min(80, filtered.length - visible.length)} 条</button>` : ""}
  `;

  bindEvents(container, filtered.length);
}

function bindEvents(container, filteredCount) {
  container.querySelectorAll("[data-route-filter]").forEach(btn => {
    btn.addEventListener("click", () => {
      setRouteFilter(btn.dataset.routeFilter);
      syncHeatOverlay();
      renderRoutesPanel(container);
    });
  });

  const heatBtn = container.querySelector("[data-route-heat]");
  if (heatBtn) {
    heatBtn.addEventListener("click", () => {
      toggleRouteHeat();
      syncHeatOverlay();
      renderRoutesPanel(container);
    });
  }

  const loadMore = container.querySelector("[data-route-load-more]");
  if (loadMore) {
    loadMore.addEventListener("click", () => {
      loadMoreRoutes();
      renderRoutesPanel(container);
    });
  }

  container.querySelectorAll("[data-hero-route]").forEach(btn => {
    btn.addEventListener("click", () => {
      if (btn.dataset.heroRoute === store.heroActiveRouteId) return;
      updateHeroRoute(btn.dataset.heroRoute, true, "route");
    });
  });
}

function syncHeatOverlay() {
  if (store.activePanelTab !== "routes" || !store.routeHeatMode) {
    hideAllRoutesFromMap();
    showCityLayer();
    return;
  }
  const routeMap = new Map();
  store.routes.forEach(r => routeMap.set(r.id, r));
  const routeObjs = getFilteredEntries().map(item => routeMap.get(item.route_id)).filter(Boolean);
  showAllRoutesOnMap(routeObjs, "heat");
  import("../map.js").then(m => m.hideCityLayer());
}
