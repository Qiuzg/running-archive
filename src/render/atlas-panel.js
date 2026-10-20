import { escapeAttr, formatKm } from "../utils.js";

let snapshot = null;
let pending = null;
let checkedAt = 0;

async function loadSnapshot() {
  if (snapshot && Date.now() - checkedAt < 60000) return snapshot;
  if (!pending) {
    pending = fetch(`${import.meta.env?.VITE_BASE || ""}/generated/atlas.json`, {
      cache: "no-cache", signal: AbortSignal.timeout(15000),
    }).then(async response => {
      if (!response.ok) throw new Error("Atlas unavailable");
      const data = await response.json();
      if (data.version !== 1 || !Array.isArray(data.entries) || typeof data.generated_at !== "string") throw new Error("Invalid atlas");
      snapshot = data;
      checkedAt = Date.now();
      return data;
    }).finally(() => { pending = null; });
  }
  return pending;
}

function renderPosterRoute(item) {
  const kind = ["run", "half", "marathon"].includes(item.kind) ? item.kind : "run";
  const title = `${item.name} · ${formatKm(item.distance_km)} · ${item.date}`;
  const points = escapeAttr(item.points);
  return `<figure class="atlas-poster-route atlas-poster-route--${kind}" title="${escapeAttr(title)}">
    <svg viewBox="0 0 260 130" role="img" aria-label="${escapeAttr(title)}">
      <polyline class="atlas-poster-route__glow" points="${points}" />
      <polyline class="atlas-poster-route__line" points="${points}" />
    </svg>
  </figure>`;
}

export function renderAtlasPanel(container) {
  if (snapshot) renderSnapshot(container);
  else container.innerHTML = '<p class="empty">正在读取路线集…</p>';
  loadSnapshot().then(() => {
    if (container.isConnected) renderSnapshot(container);
  }).catch(() => {
    if (!container.isConnected) return;
    if (!snapshot) container.innerHTML = '<p class="empty">路线集暂时无法读取。</p>';
    const retry = document.createElement("button");
    retry.className = "panel-load-more";
    retry.textContent = snapshot ? "更新失败，当前显示上次快照 · 重试" : "重新加载路线集";
    retry.onclick = () => renderAtlasPanel(container);
    container.append(retry);
  });
}

function renderSnapshot(container) {
  const entries = snapshot.entries;
  const totalDistance = entries.reduce((sum, item) => sum + Number(item.distance_km || 0), 0);
  const marathonCount = entries.filter(item => item.kind === "marathon").length;
  const halfCount = entries.filter(item => item.kind === "half").length;
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
    <p class="atlas-poster__updated">更新于 ${escapeAttr(snapshot.generated_at.slice(0, 16).replace("T", " "))} · 同步后自动更新</p>
    <div class="atlas-poster__grid">
      ${entries.map(renderPosterRoute).join("") || '<p class="empty">暂无超过 10km 的轨迹。</p>'}
    </div>
  </section>`;
}
