import { store, getAtlasEntries } from "../state.js";
import { escapeAttr, formatKm, projectRoutePoints } from "../utils.js";

function getRouteKind(race) {
  if (race?.type === "marathon") return "marathon";
  if (race?.type === "half_marathon") return "half";
  return "run";
}

function renderPosterRoute(route, item, race) {
  const coordinates = route.preview_coordinates || route.coordinates || [];
  const points = projectRoutePoints(coordinates, 260, 130, 10);
  if (!points.length) return "";

  const kind = getRouteKind(race);
  const polyline = points.map(point => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");
  const title = item.name || route.name || "未命名路线";
  const distance = Number(route.distance_km || item.distance_km || 0);
  const date = String(item.date || "");

  return `<figure class="atlas-poster-route atlas-poster-route--${kind}" title="${escapeAttr(`${title} · ${formatKm(distance)} · ${date}`)}">
    <svg viewBox="0 0 260 130" role="img" aria-label="${escapeAttr(`${title}，${formatKm(distance)}`)}">
      <polyline class="atlas-poster-route__glow" points="${polyline}" />
      <polyline class="atlas-poster-route__line" points="${polyline}" />
    </svg>
  </figure>`;
}

export function renderAtlasPanel(container) {
  const entries = getAtlasEntries();
  const routeMap = new Map(store.routes.map(route => [route.id, route]));
  const raceMap = new Map(store.races
    .filter(race => race.route_id)
    .map(race => [race.route_id, race]));

  const totalDistance = entries.reduce((sum, item) => {
    const route = routeMap.get(item.route_id);
    return sum + Number(route?.distance_km || item.distance_km || 0);
  }, 0);
  const marathonCount = entries.filter(item => raceMap.get(item.route_id)?.type === "marathon").length;
  const halfCount = entries.filter(item => raceMap.get(item.route_id)?.type === "half_marathon").length;
  const regularCount = entries.length - marathonCount - halfCount;

  container.innerHTML = `<section class="atlas-poster" aria-label="超过十公里跑步轨迹统计">
    <header class="atlas-poster__header">
      <div>
        <p>ROUTE COLLECTION · ${entries.length} RUNS · ${formatKm(totalDistance).toUpperCase()}</p>
        <h1><span>Over</span><span class="atlas-poster__threshold">10km</span><span>Runs</span></h1>
      </div>
      <div class="atlas-poster__legend" aria-label="轨迹类型图例">
        <span><i class="atlas-poster__legend-run"></i>日常跑 ${regularCount}</span>
        <span><i class="atlas-poster__legend-half"></i>半马 ${halfCount}</span>
        <span><i class="atlas-poster__legend-marathon"></i>全马 ${marathonCount}</span>
      </div>
    </header>
    <div class="atlas-poster__grid">
      ${entries.map(item => {
        const route = routeMap.get(item.route_id);
        return route ? renderPosterRoute(route, item, raceMap.get(item.route_id)) : "";
      }).join("") || '<p class="empty">暂无超过 10km 的轨迹。</p>'}
    </div>
  </section>`;
}
