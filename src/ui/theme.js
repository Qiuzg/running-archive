import { switchMapTiles } from "../map.js";
import { renderPanelContent } from "../render/panel-content.js";

let themeChangeCallback = null;

export function onThemeChange(fn) {
  themeChangeCallback = fn;
}

export function initTheme() {
  const saved = localStorage.getItem("theme") || "light";
  document.documentElement.dataset.theme = saved;
  updateThemeIcon(saved);
}

function updateThemeIcon(theme) {
  const icon = document.querySelector(".theme-toggle__icon");
  if (icon) icon.textContent = theme === "light" ? "☀️" : "🌙";
}

export function toggleTheme() {
  const current = document.documentElement.dataset.theme === "light" ? "dark" : "light";
  document.documentElement.dataset.theme = current;
  localStorage.setItem("theme", current);
  updateThemeIcon(current);
  switchMapTiles();
  renderPanelContent();
  if (themeChangeCallback) themeChangeCallback();
}

export function bindThemeToggle() {
  const btn = document.getElementById("themeToggle");
  if (btn) {
    btn.addEventListener("click", toggleTheme);
  }
}
