import { ensureThumbnails, renderThumbnail, thumbnailFailed } from "../thumbnail-loader.js";
import { routeCity, escapeHtml } from "../analytics.js";
import { store, loadMoreRoutes } from "../state.js";
import { formatKm, formatShortDate, escapeAttr } from "../utils.js";
import { updateHeroRoute, hideAllRoutesFromMap, showCityLayer } from "../map.js";

export function renderRoutesPanel(container) {
  if (!store.routeEntries.length) {
    container.innerHTML = '<p class="empty">暂无路线数据</p>';
    return;
  }

  const routeMap = new Map();
  store.routes.forEach(r => routeMap.set(r.id, r));

  const filtered = store.routeEntries;
  const visibleLimit = store.panelCollapsed ? 3 : store.routeVisibleCount;
  const visible = filtered.slice(0, visibleLimit);

  ensureThumbnails();

  const routeList = visible.map((item, index) => {
    const route = routeMap.get(item.route_id);
    if (!route) return "";
    const dateStr = item.date ? formatShortDate(item.date) : null;
    const title = item.name || route.name || "未知路线";
    const dist = formatKm(route.distance_km || item.distance_km || 0);
    const isActive = item.route_id === store.heroActiveRouteId;
    const svg = renderThumbnail(route, index);
    return `
      <button class="hero-route-item ${isActive ? "is-active" : ""}" type="button" data-hero-route="${escapeAttr(item.route_id)}">
        <span class="hero-route-item__thumb">${svg}</span>
        <span class="hero-route-item__info">
          <strong>${escapeHtml(title)}</strong>
          <span>${dateStr ? `${dateStr.year}/${dateStr.monthDay}` : "--"} · ${dist}${routeCity(item, route) ? ` · ${escapeHtml(routeCity(item, route))}` : ""}</span>
        </span>
      </button>`;
  }).join("");

  container.innerHTML = `
    ${thumbnailFailed() ? '<button class="panel-load-more" type="button" data-retry-thumbnails>缩略图加载失败，点击重试</button>' : ""}
    ${routeList || '<p class="empty">暂无路线。</p>'}
    ${store.panelCollapsed && filtered.length > 3 ? `<p class="panel-collapsed-hint">还有 ${filtered.length - 3} 条路线 · 点击 ▲ 展开</p>` : ""}
    ${!store.panelCollapsed && filtered.length > visible.length ? `<button class="panel-load-more" type="button" data-route-load-more>再显示 ${Math.min(20, filtered.length - visible.length)} 条</button>` : ""}
  `;

  bindEvents(container);
}

function bindEvents(container) {
  container.querySelector('[data-retry-thumbnails]')?.addEventListener('click', () => ensureThumbnails({ retry: true }));

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

export function syncHeatOverlay() {
  hideAllRoutesFromMap();
  showCityLayer();
}
