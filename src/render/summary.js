import { store } from "../state.js";
import { formatKm } from "../utils.js";
import { parseTimeToSeconds } from "../utils.js";

function findPB(type) {
  const candidates = store.races.filter((r) => r.type === type);
  if (!candidates.length) return null;
  return candidates.reduce((best, race) =>
    parseTimeToSeconds(race.finish_time) < parseTimeToSeconds(best.finish_time) ? race : best
  );
}

function getYearDistance(year) {
  return store.activityItems
    .filter((item) => String(item.date || "").startsWith(`${year}-`))
    .reduce((sum, item) => sum + Number(item.distance_km || 0), 0);
}

export function renderSummary() {
  const totalKm = store.activityItems.reduce((sum, item) => sum + Number(item.distance_km || 0), 0);
  const marathonPB = findPB("marathon");
  const halfPB = findPB("half_marathon");
  const currentYear = new Date().getFullYear();
  const yearKm = getYearDistance(currentYear);

  const strip = document.getElementById("summaryStrip");
  if (!strip) return;

  const createMetric = (label, value, detail) => `
    <article class="metric">
      <span class="metric__label">${label}</span>
      <strong>${value}</strong>
      <small>${detail}</small>
    </article>`;

  strip.innerHTML = [
    createMetric("累计里程", formatKm(totalKm), "比赛与训练合计"),
    createMetric(`${currentYear} 年跑量`, formatKm(yearKm), "自动按日期归档"),
    createMetric("全马 PB", marathonPB ? marathonPB.finish_time : "--", marathonPB ? marathonPB.name : "等待第一场全马"),
    createMetric("半马 PB", halfPB ? halfPB.finish_time : "--", halfPB ? halfPB.name : "等待第一场半马"),
    createMetric("完赛场次", `${store.races.length} 场`, `${store.marathonTimeline.length} 场全马`),
  ].join("");
}
