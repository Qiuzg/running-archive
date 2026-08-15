import { store, notify } from "../state.js";
import { isMobileViewport } from "../utils.js";
import { renderPanelContent } from "../render/panel-content.js";
import { invalidateMapSize } from "../map.js";

function getMaxPanelHeightWithOverlay() {
  return Math.max(118, window.innerHeight - 220);
}

export function syncMobileStatsOverlayLayout() {
  const overlay = document.getElementById("heroStatsOverlay");
  if (!overlay) return;
  const hero = document.querySelector(".hero");
  const panel = document.querySelector(".hero__panel");
  const routeSelected = hero && hero.classList.contains("hero--route-selected");
  if (!isMobileViewport() || !routeSelected || store.activePanelTab === "stats" || !panel) {
    overlay.style.bottom = "";
    return;
  }
  const maxPanelHeight = getMaxPanelHeightWithOverlay();
  let panelHeight = panel.getBoundingClientRect().height;
  if (panelHeight > maxPanelHeight) {
    panel.style.maxHeight = maxPanelHeight + "px";
    panelHeight = panel.getBoundingClientRect().height;
  }
  overlay.style.bottom = 8 + panelHeight + 16 + "px";
}

export function resetPanelHeight() {
  const panel = document.querySelector(".hero__panel");
  if (panel) {
    panel.style.maxHeight = "";
    localStorage.removeItem("panelHeight");
    setTimeout(() => invalidateMapSize(), 300);
  }
}

export function initPanelCollapse() {
  const header = document.querySelector(".hero__panel-header");
  const panel = document.querySelector(".hero__panel");
  if (!header || !panel) return;

  const btn = document.createElement("button");
  btn.className = "panel-collapse-toggle";
  btn.type = "button";
  btn.id = "panelCollapseToggle";
  btn.setAttribute("aria-label", "折叠面板");
  btn.innerHTML = "<span>▼</span>";
  header.appendChild(btn);

  const collapsed = localStorage.getItem("panelCollapsed") === "true";
  if (collapsed) {
    panel.classList.add("hero__panel--collapsed");
    btn.innerHTML = "<span>▲</span>";
    btn.setAttribute("aria-label", "展开面板");
    store.panelCollapsed = true;
  }

  btn.addEventListener("click", () => {
    panel.classList.toggle("hero__panel--collapsed");
    const isCollapsed = panel.classList.contains("hero__panel--collapsed");
    btn.innerHTML = isCollapsed ? "<span>▲</span>" : "<span>▼</span>";
    btn.setAttribute("aria-label", isCollapsed ? "展开面板" : "折叠面板");
    localStorage.setItem("panelCollapsed", isCollapsed);
    store.panelCollapsed = isCollapsed;
    renderPanelContent();
    setTimeout(() => invalidateMapSize(), 300);
  });

  // Drag-to-resize handle
  const handle = document.createElement("div");
  handle.className = "panel-resize-handle";
  handle.id = "panelResizeHandle";
  panel.insertBefore(handle, panel.firstChild);

  const savedHeight = localStorage.getItem("panelHeight");
  if (savedHeight) panel.style.maxHeight = savedHeight;

  let dragging = false, startY = 0, startHeight = 0;

  function onDragStart(e) {
    dragging = true;
    handle.classList.add("is-dragging");
    startY = e.touches ? e.touches[0].clientY : e.clientY;
    startHeight = panel.getBoundingClientRect().height;
    document.body.style.userSelect = "none";
    document.body.style.cursor = "ns-resize";
    e.preventDefault();
  }

  function onDragMove(e) {
    if (!dragging) return;
    const clientY = e.touches ? e.touches[0].clientY : e.clientY;
    const delta = startY - clientY;
    const mobile = isMobileViewport();
    const heroEl = document.querySelector(".hero");
    const routeSelected = heroEl && heroEl.classList.contains("hero--route-selected");
    const maxHeight = mobile && routeSelected ? getMaxPanelHeightWithOverlay() : window.innerHeight - 80;
    const minHeight = mobile && routeSelected ? 118 : 200;
    const newHeight = Math.max(minHeight, Math.min(maxHeight, startHeight + delta));
    panel.style.maxHeight = newHeight + "px";
    syncMobileStatsOverlayLayout();
  }

  function onDragEnd() {
    if (!dragging) return;
    dragging = false;
    handle.classList.remove("is-dragging");
    document.body.style.userSelect = "";
    document.body.style.cursor = "";
    localStorage.setItem("panelHeight", panel.style.maxHeight);
    syncMobileStatsOverlayLayout();
    invalidateMapSize();
  }

  handle.addEventListener("mousedown", onDragStart);
  handle.addEventListener("touchstart", onDragStart, { passive: false });
  document.addEventListener("mousemove", onDragMove);
  document.addEventListener("touchmove", onDragMove, { passive: false });
  document.addEventListener("mouseup", onDragEnd);
  document.addEventListener("touchend", onDragEnd);
}
