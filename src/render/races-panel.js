import { store } from "../state.js";
import { formatKm, formatDate, escapeAttr, renderRouteSvg } from "../utils.js";
import { updateHeroRoute } from "../map.js";
import { resetPanelHeight } from "../ui/panel.js";

const RACE_TYPES = { marathon: "全马", half_marathon: "半马", "10k": "10K", other: "其他" };

export function renderRacesPanel(container) {
  const allRaces = [...store.races].sort((a, b) => new Date(b.date) - new Date(a.date));
  const visibleRaces = store.panelCollapsed ? allRaces.slice(0, 1) : allRaces;
  const hiddenCount = store.panelCollapsed ? Math.max(0, allRaces.length - 1) : 0;

  if (!visibleRaces.length) {
    container.innerHTML = '<p class="empty">还没有比赛记录。</p>';
    return;
  }

  const routeMap = new Map();
  store.routes.forEach(r => routeMap.set(r.id, r));

  container.innerHTML = `
    <div class="record-grid">${visibleRaces.map(race => renderRaceCard(race, routeMap)).join("")}</div>
    ${hiddenCount > 0 ? `<p class="panel-collapsed-hint">还有 ${hiddenCount} 场比赛 · 点击 ▲ 展开</p>` : ""}
  `;

  bindRaceCardEvents(container);
}

function renderRaceCard(race, routeMap) {
  const route = race.route_id ? routeMap.get(race.route_id) : null;
  const place = [race.city, race.country].filter(Boolean).join(" · ");
  const hasRoute = race.route_id && route;

  let media;
  if (race.photos?.length) {
    media = `<img src="${race.photos[0]}" alt="${race.name}" />`;
  } else if (route?.preview_coordinates?.length) {
    media = `<div class="race-route-preview">${renderRouteSvg({ ...route, coordinates: route.preview_coordinates }, "mini")}</div>`;
  } else {
    media = `<div class="race-card__fallback"><span>${RACE_TYPES[race.type] || "RUN"}</span><strong>${formatKm(race.distance_km)}</strong></div>`;
  }

  const isActive = hasRoute && race.route_id === store.heroActiveRouteId;
  return `
    <article class="race-card ${isActive ? "is-active" : ""}" ${hasRoute ? `data-route-target="${escapeAttr(race.route_id)}"` : ""}>
      <div class="race-card__media">${media}</div>
      <div class="race-card__body">
        <div class="race-card__meta">
          <span>${formatDate(race.date)}</span>
          ${race.is_pb ? '<b class="badge badge--small">PB</b>' : ""}
        </div>
        <h3>${race.name}</h3>
        ${place || race.bib_number ? `<p>${[place, race.bib_number ? `号码 ${race.bib_number}` : ""].filter(Boolean).join(" · ")}</p>` : ""}
        <div class="race-card__result">
          <span>${formatKm(race.distance_km)}</span>
          <strong>${race.finish_time}</strong>
          <span>${race.pace} /km</span>
        </div>
        ${race.notes ? `<p class="race-card__notes">${race.notes}</p>` : ""}
      </div>
    </article>`;
}

function bindRaceCardEvents(container) {
  container.querySelectorAll(".race-card[data-route-target]").forEach(card => {
    card.onclick = (event) => {
      if (event.target.closest("button, a, input, select, textarea")) return;
      const routeId = card.dataset.routeTarget;
      if (routeId === store.heroActiveRouteId) return;
      resetPanelHeight();
      updateHeroRoute(routeId, true, "race");
    };
  });
}
