/**
 * Panel content dispatcher — renders the correct panel based on active tab.
 * Extracted to its own module to avoid circular dependencies between main.js, theme.js, and panel.js.
 */
import { store } from "../state.js";
import { renderRoutesPanel } from "./routes-panel.js";
import { renderRacesPanel } from "./races-panel.js";
import { renderStatsPanel } from "./stats-panel.js";
import { renderAtlasPanel } from "./atlas-panel.js";

export function renderPanelContent() {
  const root = document.getElementById("heroPanelBody");
  const subtitle = document.getElementById("panelSubtitle");
  if (!root) return;
  if (store.activePanelTab === "atlas") {
    root.innerHTML = '<div class="panel-content"></div>';
    if (subtitle) subtitle.textContent = "";
    renderAtlasPanel(root.firstElementChild);
    return;
  }
  const labels = {races: '比赛', runs: '训练', routes: '路线', cityBoundaries: '城市边界'};
  const failed = Object.keys(labels).filter(key => store.dataStatus[key] === 'error');
  const required = store.activePanelTab === 'races' ? ['races']
    : store.activePanelTab === 'stats' ? ['races', 'runs'] : ['races', 'runs', 'routes'];
  root.innerHTML = '';
  if (failed.length || store.dataLoading) {
    const banner = document.createElement('div');
    banner.className = 'data-status';
    banner.setAttribute('role', 'status');
    banner.innerHTML = `<div><strong>${store.dataLoading ? '正在加载跑步记录…' : '部分数据暂时无法加载'}</strong><p>${failed.length ? failed.map(key => labels[key]).join('、') + '数据尚未就绪。' : ''}加载失败不会被统计为零。</p></div><button type="button" data-retry-load ${store.dataLoading ? 'disabled' : ''}>${store.dataLoading ? '加载中…' : '重试'}</button>`;
    root.append(banner);
  }
  if (store.routes.some(route => route.preview_error)) {
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.className = 'panel-load-more';
    retry.dataset.retryPreviews = '';
    retry.textContent = '部分轨迹未加载，点击重试';
    root.append(retry);
  }
  const body = document.createElement('div');
  body.className = 'panel-content';
  root.append(body);
  if (required.some(key => store.dataStatus[key] !== 'ready')) {
    if (subtitle) subtitle.textContent = '';
    body.innerHTML = '<p class="empty">数据就绪后，将显示完整的记录与统计。</p>';
    return;
  }

  if (store.activePanelTab === "routes") {
    if (subtitle) subtitle.textContent = "";
    renderRoutesPanel(body);
  } else if (store.activePanelTab === "atlas") {
    if (subtitle) subtitle.textContent = "";
    renderAtlasPanel(body);
  } else if (store.activePanelTab === "races") {
    if (subtitle) subtitle.textContent = `${store.races.length} 场比赛 · ${store.marathonTimeline.length} 场全马`;
    renderRacesPanel(body);
  } else if (store.activePanelTab === "stats") {
    if (subtitle) subtitle.textContent = "";
    renderStatsPanel(body);
  }
}
