import { store } from "../state.js";
import { formatElapsed, isMobileViewport } from "../utils.js";
import { fetchRoute } from "../api.js";

let statsCharts = [];
let overlayRequestId = 0;

function chartColors() {
  const isLight = document.documentElement.dataset.theme === "light";
  return {
    grid: isLight ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.10)",
    text: isLight ? "rgba(0,0,0,0.45)" : "rgba(255,255,255,0.45)",
    line: isLight ? "#1a73e8" : "#5b9aff",
    fill: isLight ? "rgba(26,115,232,0.08)" : "rgba(91,154,255,0.10)",
    elevation: isLight ? "#e87a20" : "#ff9e4a",
  };
}

function destroyCharts() {
  statsCharts.forEach(c => c.destroy?.());
  statsCharts = [];
}

const CHART_DEFS = {
  pace: {
    id: "chartPace",
    title: "配速趋势",
    unit: "分钟/公里",
    axisUnit: "min/km",
    note: "越高越快",
    reverseY: true,
    sanitize: value => Number.isFinite(value) && value >= 2.5 && value <= 12 ? value : null,
    tick: value => formatPaceValue(value),
    mobileTick: value => Math.round(value),
  },
  elevation: {
    id: "chartElev",
    title: "海拔变化",
    unit: "米",
    axisUnit: "m",
    note: "路线起伏",
    reverseY: false,
    sanitize: value => Number.isFinite(value) ? value : null,
    tick: value => `${Math.round(value)}m`,
    mobileTick: value => Math.round(value),
  },
  heartRate: {
    id: "chartHR",
    title: "心率趋势",
    unit: "bpm",
    axisUnit: "bpm",
    note: "运动强度",
    reverseY: false,
    sanitize: value => Number.isFinite(value) && value >= 60 && value <= 230 ? value : null,
    tick: value => `${Math.round(value)}`,
    mobileTick: value => Math.round(value),
  },
};

function formatPaceValue(value) {
  if (!Number.isFinite(value) || value <= 0) return "";
  const seconds = Math.round(value * 60);
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}/km`;
}

function sanitizeSeries(data, type) {
  const def = CHART_DEFS[type];
  return (data || []).map(value => def.sanitize(Number(value)));
}

function seriesLabels(elapsed, fallbackElapsed, length) {
  const exact = (elapsed || []).map(Number);
  if (exact.length === length && exact.every(Number.isFinite)) {
    return exact.map(formatElapsed);
  }

  const fallback = (fallbackElapsed || []).map(Number).filter(Number.isFinite);
  if (fallback.length === length) return fallback.map(formatElapsed);
  if (fallback.length >= 2 && length >= 2) {
    const start = fallback[0];
    const end = fallback.at(-1);
    return Array.from({ length }, (_, index) => (
      formatElapsed(start + (end - start) * index / (length - 1))
    ));
  }
  return Array.from({ length }, (_, index) => formatElapsed(index));
}

function hasSeriesData(data) {
  return data?.some(value => value != null);
}

function buildChartHtml(type) {
  const def = CHART_DEFS[type];
  return `<div class="hero-stats-overlay__chart hero-stats-overlay__chart--${type}">
    <div class="hero-stats-overlay__chart-head">
      <span>${def.title}</span>
      <small>${def.unit} · ${def.note}</small>
    </div>
    <canvas id="${def.id}"></canvas>
  </div>`;
}

function makeSparkConfig(labels, data, lineColor, fillColor, type) {
  const colors = chartColors();
  const def = CHART_DEFS[type];
  const mobile = isMobileViewport();
  const validData = data.filter(v => v != null);
  let yMin, yMax;
  if (validData.length >= 2) {
    yMin = Math.min(...validData);
    yMax = Math.max(...validData);
    const pad = (yMax - yMin) * 0.12 || 1;
    yMin = Math.floor(yMin - pad);
    yMax = Math.ceil(yMax + pad);
    if (type === "pace") {
      yMin = Math.max(2, yMin);
      yMax = Math.min(14, yMax);
    }
    if (type === "heartRate") {
      yMin = Math.max(40, yMin);
      yMax = Math.min(230, yMax);
    }
  }
  return {
    type: "line",
    data: { labels, datasets: [{ data, borderColor: lineColor, backgroundColor: fillColor, borderWidth: mobile ? 1.8 : 1.5, pointRadius: 0, pointHoverRadius: 4, pointHoverBackgroundColor: lineColor, tension: 0.2, fill: true, spanGaps: true }] },
    options: {
      responsive: true, maintainAspectRatio: false, animation: false,
      interaction: { intersect: false, mode: "nearest" },
      plugins: { legend: { display: false }, tooltip: { enabled: false } },
      layout: { padding: mobile ? { top: 2, right: 2, bottom: 0, left: 0 } : 0 },
      scales: {
        x: {
          display: true,
          ticks: {
            color: colors.text,
            font: { size: mobile ? 10 : 9, weight: mobile ? 600 : 400 },
            maxTicksLimit: mobile ? 6 : 6,
            maxRotation: 0,
            autoSkip: true,
          },
          grid: { color: colors.grid, drawTicks: false },
          border: { color: colors.grid },
        },
        y: {
          display: true,
          position: "right",
          reverse: def.reverseY,
          min: yMin,
          max: yMax,
          title: {
            display: mobile,
            text: def.axisUnit,
            color: colors.text,
            font: { size: 10, weight: 700 },
            padding: { top: 0, bottom: 0 },
          },
          ticks: {
            color: colors.text,
            font: { size: mobile ? 10 : 9, weight: mobile ? 650 : 400 },
            maxTicksLimit: 3,
            callback: v => mobile ? def.mobileTick(Number(v)) : def.tick(Number(v)),
          },
          grid: { color: colors.grid, drawTicks: false },
          border: { color: colors.grid },
        },
      },
    },
  };
}

function createStatsChart(Chart, type, labels, data, lineColor, fillColor) {
  const canvas = document.getElementById(CHART_DEFS[type].id);
  if (!canvas || !hasSeriesData(data)) return;
  statsCharts.push(new Chart(canvas, makeSparkConfig(labels, data, lineColor, fillColor, type)));
}

export function clearStatsOverlay() {
  overlayRequestId += 1;
  const existing = document.getElementById("heroStatsOverlay");
  if (existing) existing.remove();
  destroyCharts();
}

function insertOverlayHtml(html) {
  const existing = document.getElementById("heroStatsOverlay");
  if (existing) existing.remove();
  const overlayContainer = document.querySelector(".hero") || document.getElementById("heroMap");
  if (overlayContainer) {
    overlayContainer.insertAdjacentHTML("beforeend", html);
  }
}

export async function renderStatsOverlay(routeId) {
  clearStatsOverlay();
  const requestId = overlayRequestId;
  if (store.activePanelTab === "stats" || routeId !== store.heroActiveRouteId) return;

  const route = store.routes.find(r => r.id === routeId);
  if (!route) return;
  const activity = store.activityItems.find(a => a.route_id === routeId);
  if (!activity) return;

  const compact = isMobileViewport();
  const stats = [];
  if (activity.avg_heart_rate) {
    stats.push({
      label: compact ? "心率" : "平均心率",
      value: compact ? activity.avg_heart_rate + "bpm" : activity.avg_heart_rate + " bpm",
      sub: compact ? "" : activity.max_heart_rate ? "最高 " + activity.max_heart_rate : "",
      compact: true,
    });
  }
  const averagePower = Number(activity.avg_power);
  if (Number.isFinite(averagePower) && averagePower > 0 && !compact) {
    stats.push({ label: "平均功率", value: Math.round(averagePower) + " W", compact: false });
  }
  if (activity.pace) {
    stats.push({ label: compact ? "配速" : "平均配速", value: compact ? activity.pace + "/km" : activity.pace + " /km", compact: true });
  }
  if (activity.finish_time || activity.duration) {
    stats.push({ label: "用时", value: activity.finish_time || activity.duration, compact: true });
  }
  if (route.elevation_gain != null) {
    stats.push({
      label: compact ? "爬升" : "累计爬升",
      value: compact ? Math.round(route.elevation_gain) + "m" : Math.round(route.elevation_gain) + " m",
      compact: true,
    });
  }
  if (!stats.length) return;

  const valuesHtml = stats.map(s => {
    const cls = s.compact === false ? " hero-stats-overlay__item--optional" : "";
    return `<div class="hero-stats-overlay__item${cls}"><span class="hero-stats-overlay__label">${s.label}</span><strong>${s.value}</strong>${s.sub ? `<small>${s.sub}</small>` : ""}</div>`;
  }).join("");

  if (compact) {
    const mobileHtml = `<div class="hero-stats-overlay hero-stats-overlay--collapsed" id="heroStatsOverlay">
      <button class="hero-stats-overlay__toggle" id="statsToggle" type="button" title="展开图表" aria-label="展开图表">⌃</button>
      <div class="hero-stats-overlay__values">${valuesHtml}</div></div>`;
    insertOverlayHtml(mobileHtml);
    bindMobileToggle(requestId, routeId);
    return;
  }

  // Desktop: load route detail and render charts
  insertOverlayHtml(`<div class="hero-stats-overlay" id="heroStatsOverlay"><div class="hero-stats-overlay__values">${valuesHtml}</div></div>`);

  try {
    const detail = await fetchRoute(routeId);
    if (requestId !== overlayRequestId) return;
    if (!detail?.time_series?.elapsed?.length || detail.time_series.elapsed.length < 2) return;

    const ts = detail.time_series;
    const labels = ts.elapsed.map(formatElapsed);
    const colors = chartColors();

    const paceData = sanitizeSeries(ts.pace, "pace");
    const elevData = sanitizeSeries(ts.elevation, "elevation");
    const hrData = sanitizeSeries(ts.heartRate, "heartRate");
    const hrLabels = seriesLabels(ts.heartRateElapsed || ts.heart_rate_elapsed, ts.elapsed, hrData.length);
    const hasPace = hasSeriesData(paceData);
    const hasElev = hasSeriesData(elevData);
    const hasHR = hasSeriesData(hrData);

    if (!hasPace && !hasElev && !hasHR) return;

    let chartsHtml = '<div class="hero-stats-overlay__charts">';
    if (hasPace) chartsHtml += buildChartHtml("pace");
    if (hasElev) chartsHtml += buildChartHtml("elevation");
    if (hasHR) chartsHtml += buildChartHtml("heartRate");
    chartsHtml += '</div>';

    const html = `<div class="hero-stats-overlay" id="heroStatsOverlay">
      <button class="hero-stats-overlay__toggle" id="statsToggle" type="button" title="折叠图表" aria-label="折叠图表">⌄</button>
      <div class="hero-stats-overlay__values">${valuesHtml}</div>${chartsHtml}</div>`;
    insertOverlayHtml(html);

    if (requestId !== overlayRequestId) return;

    const { Chart } = await import("chart.js/auto");
    createStatsChart(Chart, "pace", labels, paceData, colors.line, colors.fill);
    createStatsChart(Chart, "elevation", labels, elevData, colors.elevation, "rgba(255,158,74,0.08)");
    createStatsChart(Chart, "heartRate", hrLabels, hrData, "#ff5e3a", "rgba(255,94,58,0.10)");

    bindDesktopToggle();
  } catch (e) {
    console.warn("Stats overlay chart creation failed:", e);
  }
}

function bindDesktopToggle() {
  const toggle = document.getElementById("statsToggle");
  if (!toggle) return;
  toggle.onclick = (e) => {
    e.stopPropagation();
    const overlay = document.getElementById("heroStatsOverlay");
    if (!overlay) return;
    overlay.classList.toggle("hero-stats-overlay--collapsed");
    const collapsed = overlay.classList.contains("hero-stats-overlay--collapsed");
    toggle.textContent = collapsed ? "⌃" : "⌄";
    if (!collapsed) {
      setTimeout(() => statsCharts.forEach(c => c?.resize?.()), 40);
    }
  };
}

let mobileDetailPromise = null;

function bindMobileToggle(requestId, routeId) {
  const toggle = document.getElementById("statsToggle");
  if (!toggle) return;

  mobileDetailPromise = fetchRoute(routeId)
    .then(detail => detail?.time_series?.elapsed?.length >= 2 ? detail.time_series : null)
    .catch(() => null);

  toggle.onclick = async (e) => {
    e.stopPropagation();
    const overlay = document.getElementById("heroStatsOverlay");
    if (!overlay || requestId !== overlayRequestId || routeId !== store.heroActiveRouteId) return;

    const collapsed = overlay.classList.contains("hero-stats-overlay--collapsed");
    if (!collapsed) {
      overlay.classList.add("hero-stats-overlay--collapsed");
      toggle.textContent = "⌃";
      return;
    }

    if (overlay.querySelector(".hero-stats-overlay__charts")) {
      overlay.classList.remove("hero-stats-overlay--collapsed");
      toggle.textContent = "⌄";
      setTimeout(() => statsCharts.forEach(c => c?.resize?.()), 40);
      return;
    }

    toggle.disabled = true;
    try {
      const ts = await mobileDetailPromise;
      const paceData = sanitizeSeries(ts?.pace, "pace");
      const elevData = sanitizeSeries(ts?.elevation, "elevation");
      const hrData = sanitizeSeries(ts?.heartRate, "heartRate");
      const hrLabels = seriesLabels(ts?.heartRateElapsed || ts?.heart_rate_elapsed, ts?.elapsed, hrData.length);
      const hasPace = hasSeriesData(paceData);
      const hasElev = hasSeriesData(elevData);
      const hasHR = hasSeriesData(hrData);
      if (!hasPace && !hasElev && !hasHR) { toggle.remove(); return; }

      const { Chart } = await import("chart.js/auto");
      if (requestId !== overlayRequestId || routeId !== store.heroActiveRouteId) return;

      const colors = chartColors();
      const labels = ts.elapsed.map(formatElapsed);
      let chartsHtml = '<div class="hero-stats-overlay__charts">';
      if (hasPace) chartsHtml += buildChartHtml("pace");
      if (hasElev) chartsHtml += buildChartHtml("elevation");
      if (hasHR) chartsHtml += buildChartHtml("heartRate");
      chartsHtml += '</div>';

      overlay.insertAdjacentHTML("beforeend", chartsHtml);
      overlay.classList.remove("hero-stats-overlay--collapsed");

      createStatsChart(Chart, "pace", labels, paceData, colors.line, colors.fill);
      createStatsChart(Chart, "elevation", labels, elevData, colors.elevation, "rgba(255,158,74,0.08)");
      createStatsChart(Chart, "heartRate", hrLabels, hrData, "#ff5e3a", "rgba(255,94,58,0.10)");

      toggle.textContent = "⌄";
    } catch (err) {
      const chartsEl = overlay.querySelector(".hero-stats-overlay__charts");
      if (chartsEl) chartsEl.remove();
      overlay.classList.add("hero-stats-overlay--collapsed");
    } finally {
      toggle.disabled = false;
    }
  };
}
