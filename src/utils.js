/**
 * Utility functions — formatting, projection, SVG generation.
 * Migrated from the app.js IIFE.
 */

const dateCache = new Map();
const shortDateCache = new Map();

export function parseDateValue(value) {
  const text = String(value || "");
  const match = text.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (match) {
    return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  }
  return new Date(value);
}

export function formatDate(value) {
  if (dateCache.has(value)) return dateCache.get(value);
  const date = parseDateValue(value);
  const formatted = new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
  dateCache.set(value, formatted);
  return formatted;
}

export function formatShortDate(value) {
  if (shortDateCache.has(value)) return shortDateCache.get(value);
  const date = parseDateValue(value);
  const formatted = {
    year: date.getFullYear(),
    monthDay: new Intl.DateTimeFormat("zh-CN", {
      month: "2-digit",
      day: "2-digit",
    }).format(date),
  };
  shortDateCache.set(value, formatted);
  return formatted;
}

export function formatKm(value) {
  return `${Number(value).toFixed(value >= 100 ? 0 : 1)} km`;
}

export function parseTimeToSeconds(value) {
  if (!value) return Infinity;
  const parts = value.split(":").map(Number);
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return Infinity;
}

export function displayText(value, fallback = "--") {
  return value === undefined || value === null || value === "" ? fallback : value;
}

export function escapeAttr(value) {
  return String(value ?? "").replace(/"/g, "&quot;");
}

export function isMobileViewport() {
  return window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
}

// ---- Mercator projection for SVG route thumbnails ----
export function projectRoutePoints(coordinates, width = 420, height = 240, padding = 28) {
  if (!coordinates || coordinates.length < 2) return [];
  const mercator = coordinates.map(([lon, lat]) => {
    const clampedLat = Math.max(Math.min(lat, 85.05112878), -85.05112878);
    const x = (lon * Math.PI) / 180;
    const y = Math.log(Math.tan(Math.PI / 4 + (clampedLat * Math.PI) / 360));
    return { x, y };
  });
  const minX = Math.min(...mercator.map((p) => p.x));
  const maxX = Math.max(...mercator.map((p) => p.x));
  const minY = Math.min(...mercator.map((p) => p.y));
  const maxY = Math.max(...mercator.map((p) => p.y));
  const spanX = maxX - minX || 1;
  const spanY = maxY - minY || 1;
  const scale = Math.min((width - padding * 2) / spanX, (height - padding * 2) / spanY);
  const drawnWidth = spanX * scale;
  const drawnHeight = spanY * scale;
  const offsetX = (width - drawnWidth) / 2;
  const offsetY = (height - drawnHeight) / 2;

  return mercator.map((point) => ({
    x: offsetX + (point.x - minX) * scale,
    y: height - offsetY - (point.y - minY) * scale,
  }));
}

export function getSvgColors() {
  const light = document.documentElement.dataset.theme === "light";
  return {
    bg1: light ? "#f7fbff" : "#0a0f18",
    bg2: light ? "#eef8f3" : "#0d141d",
    bg3: light ? "#fff3ec" : "#0b1019",
    grid: light ? "rgba(37,99,235,0.08)" : "rgba(255,255,255,0.04)",
    decor1: light ? "rgba(16,185,129,0.12)" : "rgba(255,255,255,0.06)",
    decor2: light ? "rgba(224,74,42,0.10)" : "rgba(255,255,255,0.05)",
    decor3: light ? "rgba(37,99,235,0.12)" : "rgba(255,255,255,0.08)",
    routeGlow: light ? "rgba(37,99,235,0.25)" : "rgba(59,139,255,0.3)",
    route: light ? "#2563eb" : "#3b8bff",
    routeAccent: light ? "#10b981" : "#2dd4a8",
    startFill: light ? "#f8fbff" : "#0a0f18",
    startStroke: light ? "#10b981" : "#2dd4a8",
    endFill: light ? "#e04a2a" : "#ff5e3a",
    endStroke: light ? "#dde1e6" : "#0a0f18",
  };
}

const routeSvgCache = new Map();

export function renderRouteSvg(route, variant = "large") {
  if (!route) {
    return '<div class="route-empty">暂无路线</div>';
  }
  const theme = document.documentElement.dataset.theme || "dark";
  const cacheKey = route.id
    ? `${theme}:${variant}:${route.id}:${route.coordinates?.length || route.preview_coordinates?.length || 0}`
    : null;
  if (cacheKey && routeSvgCache.has(cacheKey)) {
    return routeSvgCache.get(cacheKey);
  }
  const coords = route.coordinates || route.preview_coordinates || [];
  const projected = projectRoutePoints(coords, 420, 240, variant === "mini" ? 12 : 28);
  if (!projected.length) {
    return '<div class="route-empty">路线加载中</div>';
  }
  const c = getSvgColors();
  const points = projected.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(" ");
  const startPoint = projected[0];
  const endPoint = projected[projected.length - 1];
  const isMini = variant === "mini";

  const svg = `
    <svg class="route-svg route-svg--${variant}" viewBox="0 0 420 240" role="img" aria-label="${escapeAttr(route.name)}路线图">
      <defs>
        <linearGradient id="rp-${escapeAttr(route.id)}" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0%" stop-color="${c.bg1}" />
          <stop offset="54%" stop-color="${c.bg2}" />
          <stop offset="100%" stop-color="${c.bg3}" />
        </linearGradient>
        <pattern id="rg-${escapeAttr(route.id)}" width="28" height="28" patternUnits="userSpaceOnUse">
          <path d="M 28 0 L 0 0 0 28" fill="none" stroke="${c.grid}" stroke-width="1" />
        </pattern>
      </defs>
      ${isMini ? "" : `
      <rect width="420" height="240" rx="8" fill="url(#rp-${escapeAttr(route.id)})" />
      <rect width="420" height="240" rx="8" fill="url(#rg-${escapeAttr(route.id)})" opacity="0.75" />
      `}
      <polyline points="${points}" fill="none" stroke="${c.routeGlow}" stroke-width="${isMini ? 5 : 6}" stroke-linecap="round" stroke-linejoin="round" opacity="0.6" />
      <polyline points="${points}" fill="none" stroke="${c.route}" stroke-width="${isMini ? 3 : 4}" stroke-linecap="round" stroke-linejoin="round" />
      <polyline points="${points}" fill="none" stroke="${c.routeAccent}" stroke-width="${isMini ? 1.5 : 2}" stroke-linecap="round" stroke-linejoin="round" />
      <circle cx="${startPoint.x.toFixed(1)}" cy="${startPoint.y.toFixed(1)}" r="${isMini ? 6 : 8}" fill="${c.startFill}" stroke="${c.startStroke}" stroke-width="4" />
      <circle cx="${endPoint.x.toFixed(1)}" cy="${endPoint.y.toFixed(1)}" r="${isMini ? 6 : 8}" fill="${c.endFill}" stroke="${c.endStroke}" stroke-width="4" />
    </svg>
  `;
  if (cacheKey) routeSvgCache.set(cacheKey, svg);
  return svg;
}

export function positionTooltip(el, event) {
  const chartBlock = el.closest(".chart-block");
  if (!chartBlock) return;
  const rect = chartBlock.getBoundingClientRect();
  const x = (event.touches ? event.touches[0].clientX : event.clientX) - rect.left + 12;
  const y = (event.touches ? event.touches[0].clientY : event.clientY) - rect.top - 32;
  el.style.left = x + "px";
  el.style.top = y + "px";
}

export function formatElapsed(seconds) {
  if (seconds == null) return "";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0) return h + ":" + String(m).padStart(2, "0") + "h";
  return m + "min";
}
