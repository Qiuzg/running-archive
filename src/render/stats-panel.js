import { store, setStatsYear, setStatsMonth } from "../state.js";
import { formatKm, formatElapsed, escapeAttr, positionTooltip } from "../utils.js";
import { updateHeroRoute } from "../map.js";
import { resetPanelHeight } from "../ui/panel.js";

export function renderStatsPanel(container) {
  const year = store.selectedStatsYear;
  const { activityItems, races } = store;

  // Monthly totals
  const totals = Array.from({ length: 12 }, () => 0);
  activityItems.forEach((item) => {
    const d = String(item.date || "");
    if (d.startsWith(`${year}-`)) {
      totals[Number(d.slice(5, 7)) - 1] += Number(item.distance_km || 0);
    }
  });

  const max = Math.max(...totals, 1);
  const yearDist = totals.reduce((a, b) => a + b, 0);
  const yearRaces = races.filter(r => String(r.date || "").startsWith(`${year}-`));
  const marathonCount = yearRaces.filter(r => r.type === "marathon").length;
  const halfCount = yearRaces.filter(r => r.type === "half_marathon").length;
  const activeMonths = totals.filter(t => t > 0).length;
  const monthlyAvg = activeMonths > 0 ? yearDist / activeMonths : 0;

  const longest = activityItems
    .filter(item => String(item.date || "").startsWith(`${year}-`))
    .reduce((best, item) => Number(item.distance_km || 0) > Number(best.distance_km || 0) ? item : best, { distance_km: 0 });

  const yearIdx = store.availableYears.indexOf(year);
  const hasPrev = yearIdx < store.availableYears.length - 1;
  const hasNext = yearIdx > 0;

  // 100km reference lines
  const step = 100;
  const refLines = [];
  for (let v = step; v <= Math.ceil(max / step) * step; v += step) {
    const pct = (v / max) * 100;
    if (pct <= 100) refLines.push({ value: v, pct });
  }

  const bars = totals.map((t, i) => {
    const h = Math.max((t / max) * 100, t > 0 ? 6 : 2);
    return `<button class="bar ${store.selectedStatsMonth === i ? "is-active" : ""}" type="button"
      data-stats-month="${i}" data-bar-value="${t ? t.toFixed(0) : "0"}"
      aria-label="${year}年${i + 1}月跑量${formatKm(t)}" style="--bar-height: ${h}%">
      <i></i><small>${i + 1}月</small></button>`;
  }).join("");

  container.innerHTML = `
    <div class="stats-year-header">
      <div class="stats-hero-number">
        <strong>${formatKm(yearDist)}</strong>
        <span>年度总跑量</span>
      </div>
      <div class="stats-year-nav">
        <button class="stats-year-arrow" type="button" data-stats-year-prev ${hasPrev ? "" : "disabled"}>←</button>
        <strong>${year}</strong>
        <button class="stats-year-arrow" type="button" data-stats-year-next ${hasNext ? "" : "disabled"}>→</button>
      </div>
    </div>
    <div class="chart-block">
      <div class="chart-block__header"><h3>月度跑量</h3></div>
      <div class="bar-chart">
        ${refLines.map(l => `<span class="bar-ref-line" data-ref-pct="${l.pct}" style="bottom:${l.pct}%"><small>${l.value}</small></span>`).join("")}
        ${bars}
      </div>
      <div class="bar-tooltip" id="barTooltip" hidden></div>
    </div>
    <div class="stats-meta-row">
      <div class="stats-meta-item"><span>比赛</span><strong>${yearRaces.length} 场</strong><small>全马 ${marathonCount} · 半马 ${halfCount}</small></div>
      <div class="stats-meta-item"><span>月均跑量</span><strong>${formatKm(monthlyAvg)}</strong><small>${activeMonths} 个月有记录</small></div>
      <div class="stats-meta-item"><span>最长距离</span><strong>${formatKm(longest.distance_km || 0)}</strong><small>${longest.name || "--"}</small></div>
    </div>
    <div class="month-records" id="monthRecords"></div>
  `;

  bindStatsEvents(container, yearIdx, hasPrev, hasNext);
  renderMonthRecords();
  alignBarRefLines(container);
}

function bindStatsEvents(container, yearIdx, hasPrev, hasNext) {
  const prevBtn = container.querySelector("[data-stats-year-prev]");
  const nextBtn = container.querySelector("[data-stats-year-next]");

  if (hasPrev) prevBtn?.addEventListener("click", () => {
    setStatsYear(store.availableYears[yearIdx + 1]);
    store.selectedStatsMonth = null;
    renderStatsPanel(container);
  });

  if (hasNext) nextBtn?.addEventListener("click", () => {
    setStatsYear(store.availableYears[yearIdx - 1]);
    store.selectedStatsMonth = null;
    renderStatsPanel(container);
  });

  const tooltip = container.querySelector("#barTooltip");
  container.querySelectorAll("[data-stats-month]").forEach(btn => {
    btn.addEventListener("click", () => {
      const m = Number(btn.dataset.statsMonth);
      store.selectedStatsMonth = store.selectedStatsMonth === m ? null : m;
      renderStatsPanel(container);
    });
    btn.addEventListener("mouseenter", (e) => {
      if (!tooltip) return;
      tooltip.textContent = `${Number(btn.dataset.statsMonth) + 1}月 · ${btn.dataset.barValue} km`;
      tooltip.hidden = false;
      positionTooltip(tooltip, e);
    });
    btn.addEventListener("mousemove", (e) => {
      if (tooltip && !tooltip.hidden) positionTooltip(tooltip, e);
    });
    btn.addEventListener("mouseleave", () => { if (tooltip) tooltip.hidden = true; });
    btn.addEventListener("touchstart", (e) => {
      if (!tooltip) return;
      tooltip.textContent = `${Number(btn.dataset.statsMonth) + 1}月 · ${btn.dataset.barValue} km`;
      tooltip.hidden = false;
      positionTooltip(tooltip, e);
      clearTimeout(btn._tooltipTimer);
      btn._tooltipTimer = setTimeout(() => { if (tooltip) tooltip.hidden = true; }, 1500);
    }, { passive: true });
  });
}

function renderMonthRecords() {
  const container = document.getElementById("monthRecords");
  if (!container) return;

  const month = store.selectedStatsMonth;
  const year = store.selectedStatsYear;

  if (month === null) {
    container.innerHTML = `
      <div class="month-records__header">
        <div><span>${year}</span><strong>选择月份查看记录</strong></div>
      </div>
      <p class="empty empty--compact">点击上方月份柱查看当月跑步和比赛记录。</p>`;
    return;
  }

  const records = store.activityItems
    .filter(item => {
      const d = String(item.date || "");
      return d.startsWith(`${year}-`) && Number(d.slice(5, 7)) - 1 === month;
    })
    .sort((a, b) => new Date(a.date) - new Date(b.date));

  const monthTotal = records.reduce((sum, item) => sum + Number(item.distance_km || 0), 0);
  const maxDist = Math.max(...records.map(item => Number(item.distance_km || 0)), 1);
  const longest = [...records].sort((a, b) => Number(b.distance_km || 0) - Number(a.distance_km || 0))[0];

  container.innerHTML = `
    <div class="month-records__header">
      <div>
        <span>${year}</span>
        <strong>${month + 1} 月训练分布</strong>
      </div>
      <small>${records.length} 次 · ${formatKm(monthTotal)}${longest ? ` · 最长 ${formatKm(longest.distance_km)}` : ""}</small>
    </div>
    ${records.length ? `<div class="month-detail-chart ${records.length <= 8 ? "is-sparse" : ""}">${records.map(item => {
      const distance = Number(item.distance_km || 0);
      const height = Math.max((distance / maxDist) * 100, distance > 0 ? 8 : 2);
      const day = Number(String(item.date || "").slice(8, 10));
      const title = item.name || item.title || "";
      const tooltipText = `${title} · ${formatKm(distance)} · ${item.pace}/km`;
      const content = `<i style="--activity-height: ${height}%"></i><small>${day}</small>`;
      return item.route_id
        ? `<button class="month-activity-bar" type="button" data-route-target="${escapeAttr(item.route_id)}" title="${escapeAttr(tooltipText)}">${content}</button>`
        : `<div class="month-activity-bar" title="${escapeAttr(tooltipText)}">${content}</div>`;
    }).join("")}</div>` : '<p class="empty empty--compact">这个月没有记录。</p>'}
  `;

  // Bind route links
  container.querySelectorAll("[data-route-target]").forEach(el => {
    el.onclick = () => {
      if (el.dataset.routeTarget === store.heroActiveRouteId) return;
      if (store.activePanelTab === "stats") resetPanelHeight();
      updateHeroRoute(el.dataset.routeTarget, true, "route");
    };
  });
}

function alignBarRefLines(scope) {
  requestAnimationFrame(() => {
    const chart = scope.querySelector(".bar-chart");
    if (!chart) return;
    const sampleBar = chart.querySelector(".bar");
    const sampleTrack = chart.querySelector(".bar i");
    if (!sampleBar || !sampleTrack) return;
    const chartRect = chart.getBoundingClientRect();
    const barRect = sampleBar.getBoundingClientRect();
    const trackRect = sampleTrack.getBoundingClientRect();
    const plotTop = barRect.top, plotBottom = trackRect.bottom;
    const plotHeight = plotBottom - plotTop;
    if (plotHeight <= 0) return;
    chart.querySelectorAll(".bar-ref-line[data-ref-pct]").forEach(line => {
      const pct = Number(line.dataset.refPct || 0);
      line.style.bottom = chartRect.bottom - (plotBottom - (plotHeight * pct) / 100) + "px";
    });
  });
}
