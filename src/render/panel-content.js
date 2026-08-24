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
  const body = document.getElementById("heroPanelBody");
  const subtitle = document.getElementById("panelSubtitle");
  if (!body) return;

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
