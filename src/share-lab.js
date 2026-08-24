import { fetchRoute } from "./api.js";
import { store } from "./state.js";
import QRCode from "qrcode";

export const SHARE_LAB_PATH = "/share-lab-7k3m9x2p";
const SESSION_KEY = "running-archive-share-lab";
const TAP_COUNT = 7;
const TAP_WINDOW_MS = 4000;
const CARD_WIDTH = 1080;
const COMPACT_CARD_HEIGHT = 1680;
const DETAILED_CARD_HEIGHT = 2800;
const PROFILE_URL = new URL("../assets/profile.png", import.meta.url).href;
const SITE_URL = new URL(import.meta.env.BASE_URL || "/", window.location.origin).href;

let tapTimes = [];
let overlay = null;
let selectedRun = null;
let renderedBlob = null;
let generationSerial = 0;
let autoGenerateTimer = null;
const routeCache = new Map();

function isSharePath() {
  return window.location.hash.replace(/^#/, "").replace(/\/$/, "") === SHARE_LAB_PATH;
}

function activate() {
  sessionStorage.setItem(SESSION_KEY, "1");
  window.location.hash = `#${SHARE_LAB_PATH}`;
  openShareLab();
}

function bindSecretGesture() {
  const avatar = document.querySelector(".brand__mark--photo");
  if (!avatar) return;
  avatar.title = "Run Log";
  avatar.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    const now = Date.now();
    tapTimes = tapTimes.filter((time) => now - time < TAP_WINDOW_MS);
    tapTimes.push(now);
    if (tapTimes.length >= TAP_COUNT) {
      tapTimes = [];
      activate();
    }
  });
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function eligibleRuns() {
  const seen = new Set();
  return [...store.runs, ...store.races]
    .filter((run) => run.route_id && !seen.has(run.id) && seen.add(run.id))
    .sort((a, b) => String(b.date).localeCompare(String(a.date)))
    .slice(0, 80);
}

function runLabel(run) {
  const name = run.name || "户外跑步";
  return `${run.date} · ${Number(run.distance_km || 0).toFixed(2)} km · ${name}`;
}

function makeOverlay() {
  const runs = eligibleRuns();
  overlay = document.createElement("section");
  overlay.className = "share-lab";
  overlay.setAttribute("aria-label", "隐藏分享实验室");
  overlay.innerHTML = `
    <header class="share-lab__header">
      <div>
        <p class="eyebrow">Private Tool</p>
        <h1>分享实验室</h1>
        <p>选择一条跑步记录，在当前设备直接生成图片。</p>
      </div>
      <button class="share-lab__close" type="button" aria-label="关闭">×</button>
    </header>
    <div class="share-lab__workspace">
      <aside class="share-lab__controls">
        <label>跑步记录
          <select id="shareRunSelect">
            ${runs.map((run) => `<option value="${escapeHtml(run.id)}">${escapeHtml(runLabel(run))}</option>`).join("")}
          </select>
        </label>
        <label>图片标题
          <input id="shareTitle" maxlength="28" value="今日跑步" />
        </label>
        <label>图片样式
          <select id="shareLayout">
            <option value="compact">精简 · 1080 × 1680</option>
            <option value="detailed">详细 · 1080 × 2800</option>
          </select>
        </label>
        <label>图片配色
          <select id="shareTheme">
            <option value="auto">跟随网站</option>
            <option value="light">日间</option>
            <option value="dark">夜间</option>
          </select>
        </label>
        <button class="share-lab__primary" id="shareGenerate" type="button">重新生成分享图片</button>
        <button id="shareNative" type="button" disabled>分享到手机…</button>
        <a id="shareDownload" class="share-lab__download is-disabled" download="running-share.png">下载 PNG</a>
        <p class="share-lab__status" id="shareStatus">图片只在你的浏览器中生成，不会上传。</p>
      </aside>
      <div class="share-lab__preview">
        <canvas id="shareCanvas" width="${CARD_WIDTH}" height="${COMPACT_CARD_HEIGHT}" aria-label="分享图片预览"></canvas>
      </div>
    </div>`;
  document.body.append(overlay);

  overlay.querySelector(".share-lab__close").addEventListener("click", closeShareLab);
  overlay.querySelector("#shareGenerate").addEventListener("click", generateSelectedCard);
  overlay.querySelector("#shareNative").addEventListener("click", shareGeneratedCard);
  overlay.querySelector("#shareDownload").addEventListener("click", (event) => {
    if (!renderedBlob) event.preventDefault();
  });
  overlay.querySelector("#shareRunSelect").addEventListener("change", () => scheduleGenerate(0, "正在切换路线…"));
  overlay.querySelector("#shareLayout").addEventListener("change", () => scheduleGenerate(0, "正在切换图片样式…"));
  overlay.querySelector("#shareTheme").addEventListener("change", () => scheduleGenerate(0, "正在切换配色…"));
  overlay.querySelector("#shareTitle").addEventListener("input", () => scheduleGenerate(260, "正在更新标题…"));
}

function closeShareLab() {
  overlay?.remove();
  overlay = null;
  renderedBlob = null;
  clearTimeout(autoGenerateTimer);
  window.location.hash = "#/routes";
}

function scheduleGenerate(delay = 0, message = "正在更新图片…") {
  renderedBlob = null;
  generationSerial += 1;
  clearTimeout(autoGenerateTimer);
  const download = overlay?.querySelector("#shareDownload");
  download?.classList.add("is-disabled");
  const shareButton = overlay?.querySelector("#shareNative");
  if (shareButton) shareButton.disabled = true;
  setStatus(message);
  autoGenerateTimer = setTimeout(generateSelectedCard, delay);
}

function openShareLab() {
  if (overlay) return;
  sessionStorage.setItem(SESSION_KEY, "1");
  makeOverlay();
  if (!eligibleRuns().length) {
    setStatus("没有找到带轨迹的跑步记录。", true);
    overlay.querySelector("#shareGenerate").disabled = true;
    return;
  }
  requestAnimationFrame(generateSelectedCard);
}

function setStatus(message, isError = false) {
  const status = overlay?.querySelector("#shareStatus");
  if (!status) return;
  status.textContent = message;
  status.classList.toggle("is-error", isError);
}

function roundedRect(ctx, x, y, width, height, radius) {
  ctx.beginPath();
  ctx.roundRect(x, y, width, height, radius);
}

function drawRoute(ctx, coordinates, box, colors) {
  const points = (coordinates || [])
    .map(([lon, lat]) => [Number(lon), Number(lat)])
    .filter(([lon, lat]) => Number.isFinite(lon) && Number.isFinite(lat));
  if (points.length < 2) return;
  const lons = points.map(([lon]) => lon);
  const lats = points.map(([, lat]) => lat);
  const minLon = Math.min(...lons), maxLon = Math.max(...lons);
  const minLat = Math.min(...lats), maxLat = Math.max(...lats);
  const spanLon = Math.max(maxLon - minLon, 0.00001);
  const spanLat = Math.max(maxLat - minLat, 0.00001);
  const scale = Math.min(box.width / spanLon, box.height / spanLat);
  const usedWidth = spanLon * scale;
  const usedHeight = spanLat * scale;
  const ox = box.x + (box.width - usedWidth) / 2;
  const oy = box.y + (box.height - usedHeight) / 2;
  const project = ([lon, lat]) => [ox + (lon - minLon) * scale, oy + (maxLat - lat) * scale];

  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.beginPath();
  points.forEach((point, index) => {
    const [x, y] = project(point);
    if (index) ctx.lineTo(x, y); else ctx.moveTo(x, y);
  });
  ctx.strokeStyle = colors.routeShadow;
  ctx.lineWidth = 20;
  ctx.stroke();
  ctx.strokeStyle = colors.route;
  ctx.lineWidth = 10;
  ctx.stroke();

  const [sx, sy] = project(points[0]);
  const [ex, ey] = project(points.at(-1));
  [[sx, sy, colors.start], [ex, ey, colors.finish]].forEach(([x, y, fill]) => {
    ctx.beginPath();
    ctx.arc(x, y, 13, 0, Math.PI * 2);
    ctx.fillStyle = fill;
    ctx.fill();
    ctx.lineWidth = 6;
    ctx.strokeStyle = colors.card;
    ctx.stroke();
  });
}

function chartValues(values) {
  return (values || []).map(Number).filter(Number.isFinite);
}

function drawChart(ctx, values, x, y, width, height, color) {
  const clean = chartValues(values);
  if (clean.length < 2) return;
  const min = Math.min(...clean), max = Math.max(...clean);
  const span = Math.max(max - min, 1);
  ctx.beginPath();
  clean.forEach((value, index) => {
    const px = x + (index / (clean.length - 1)) * width;
    const py = y + height - ((value - min) / span) * height;
    if (index) ctx.lineTo(px, py); else ctx.moveTo(px, py);
  });
  ctx.strokeStyle = color;
  ctx.lineWidth = 4;
  ctx.lineJoin = "round";
  ctx.stroke();
}

function colorsFor(theme) {
  const dark = theme === "dark";
  return dark ? {
    background: "#080c12", card: "#101722", ink: "#f0f3f8", dim: "#8896a8",
    line: "rgba(255,255,255,.09)", accent: "#ff6b48", route: "#55c8ff",
    routeShadow: "rgba(8,12,18,.84)", start: "#2dd4a8", finish: "#ff5e3a",
    detailedPanel: "rgba(16,23,34,.76)", detailedFooter: "rgba(16,23,34,.78)",
  } : {
    background: "#f3f6f9", card: "#ffffff", ink: "#1a1d24", dim: "#6b7280",
    line: "rgba(20,28,40,.09)", accent: "#e04a2a", route: "#2379e8",
    routeShadow: "rgba(255,255,255,.94)", start: "#10b981", finish: "#e04a2a",
    detailedPanel: "rgba(255,255,255,.78)", detailedFooter: "rgba(255,255,255,.82)",
  };
}

function resolveTheme(requestedTheme) {
  return requestedTheme === "auto"
    ? (document.documentElement.dataset.theme === "light" ? "light" : "dark")
    : requestedTheme;
}

function drawCompactCard(canvas, run, route, title, requestedTheme) {
  const actualTheme = resolveTheme(requestedTheme);
  const c = colorsFor(actualTheme);
  const ctx = canvas.getContext("2d");
  canvas.width = CARD_WIDTH;
  canvas.height = COMPACT_CARD_HEIGHT;
  ctx.clearRect(0, 0, CARD_WIDTH, COMPACT_CARD_HEIGHT);
  ctx.fillStyle = c.background;
  ctx.fillRect(0, 0, CARD_WIDTH, COMPACT_CARD_HEIGHT);

  const gradient = ctx.createRadialGradient(870, 120, 20, 870, 120, 620);
  gradient.addColorStop(0, actualTheme === "dark" ? "rgba(59,139,255,.18)" : "rgba(37,99,235,.12)");
  gradient.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, CARD_WIDTH, 720);

  ctx.fillStyle = c.accent;
  ctx.font = "800 28px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("TODAY RUN", 72, 96);
  ctx.fillStyle = c.ink;
  ctx.font = "850 66px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText(title || "今日跑步", 72, 174);
  ctx.fillStyle = c.dim;
  ctx.font = "650 27px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.textAlign = "right";
  ctx.fillText(`${run.date || ""}  ${run.city || ""}`, 1008, 98);
  ctx.textAlign = "left";

  roundedRect(ctx, 54, 230, 972, 740, 34);
  ctx.fillStyle = c.card;
  ctx.fill();
  drawRoute(ctx, route.coordinates || route.preview_coordinates, { x: 125, y: 300, width: 830, height: 590 }, c);

  const stats = [
    ["距离", Number(run.distance_km || route.distance_km || 0).toFixed(2), "km"],
    ["平均配速", run.pace || "--", "/km"],
    ["用时", run.duration || run.finish_time || "--", ""],
    ["平均心率", run.avg_heart_rate || "--", "bpm"],
    ["累计爬升", Math.round(route.elevation_gain || 0), "m"],
  ];
  const statWidth = 972 / stats.length;
  stats.forEach(([label, value, unit], index) => {
    const x = 54 + statWidth * index;
    if (index) {
      ctx.fillStyle = c.line;
      ctx.fillRect(x, 1018, 2, 176);
    }
    ctx.fillStyle = c.accent;
    ctx.font = "750 22px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText(label, x + 22, 1064);
    ctx.fillStyle = c.ink;
    ctx.font = "850 34px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText(String(value), x + 22, 1117);
    ctx.fillStyle = c.dim;
    ctx.font = "650 20px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText(unit, x + 22, 1153);
  });

  roundedRect(ctx, 54, 1230, 972, 300, 30);
  ctx.fillStyle = c.card;
  ctx.fill();
  ctx.fillStyle = c.ink;
  ctx.font = "800 28px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("运动趋势", 82, 1280);
  ctx.fillStyle = c.dim;
  ctx.font = "650 20px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("配速 · 海拔 · 心率", 82, 1315);
  const ts = route.time_series || {};
  drawChart(ctx, ts.pace, 330, 1270, 640, 55, "#3b8bff");
  drawChart(ctx, ts.elevation, 330, 1360, 640, 55, "#e87a20");
  drawChart(ctx, ts.heartRate || ts.heart_rate, 330, 1450, 640, 55, c.accent);

  ctx.fillStyle = c.dim;
  ctx.font = "650 22px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("RUN LOG · 我的跑步档案", 72, 1610);
  ctx.textAlign = "right";
  ctx.fillStyle = c.accent;
  ctx.font = "850 23px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("KEEP MOVING", 1008, 1610);
  ctx.textAlign = "left";
}

function loadImage(source, useCors = false) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    if (useCors) img.crossOrigin = "anonymous";
    const timer = setTimeout(() => reject(new Error("图片加载超时")), 4500);
    img.onload = () => { clearTimeout(timer); resolve(img); };
    img.onerror = () => { clearTimeout(timer); reject(new Error("图片加载失败")); };
    img.src = source;
  });
}

function mercatorPoint([lon, lat], zoom) {
  const size = 256 * (2 ** zoom);
  const safeLat = Math.max(-85.0511, Math.min(85.0511, lat));
  const sin = Math.sin(safeLat * Math.PI / 180);
  return [
    (lon + 180) / 360 * size,
    (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * size,
  ];
}

function detailedMapTransform(coordinates) {
  const points = (coordinates || []).map(([lon, lat]) => [Number(lon), Number(lat)])
    .filter(([lon, lat]) => Number.isFinite(lon) && Number.isFinite(lat));
  const fitWidth = 820;
  const fitHeight = 1050;
  let zoom = 3;
  let world = [];
  for (let candidate = 17; candidate >= 3; candidate -= 1) {
    const projected = points.map((point) => mercatorPoint(point, candidate));
    const xs = projected.map(([x]) => x), ys = projected.map(([, y]) => y);
    if (Math.max(...xs) - Math.min(...xs) <= fitWidth && Math.max(...ys) - Math.min(...ys) <= fitHeight) {
      zoom = candidate;
      world = projected;
      break;
    }
  }
  if (!world.length) world = points.map((point) => mercatorPoint(point, zoom));
  const xs = world.map(([x]) => x), ys = world.map(([, y]) => y);
  const centerX = (Math.min(...xs) + Math.max(...xs)) / 2;
  const centerY = (Math.min(...ys) + Math.max(...ys)) / 2;
  return {
    points,
    zoom,
    centerX,
    centerY,
    project: (point) => {
      const [x, y] = mercatorPoint(point, zoom);
      return [x - centerX + 540, y - centerY + 830];
    },
  };
}

async function drawDetailedMap(ctx, coordinates, theme) {
  const transform = detailedMapTransform(coordinates);
  ctx.fillStyle = theme === "dark" ? "#111822" : "#edf1f4";
  ctx.fillRect(0, 0, CARD_WIDTH, DETAILED_CARD_HEIGHT);
  if (!transform.points.length) return transform;

  const tileSize = 256;
  const worldLeft = transform.centerX - 540;
  const worldRight = transform.centerX + 540;
  const worldTop = transform.centerY - 830;
  const worldBottom = worldTop + DETAILED_CARD_HEIGHT;
  const maxTile = 2 ** transform.zoom;
  const tileJobs = [];
  for (let tileX = Math.floor(worldLeft / tileSize); tileX <= Math.floor(worldRight / tileSize); tileX += 1) {
    for (let tileY = Math.floor(worldTop / tileSize); tileY <= Math.floor(worldBottom / tileSize); tileY += 1) {
      if (tileY < 0 || tileY >= maxTile) continue;
      const wrappedX = ((tileX % maxTile) + maxTile) % maxTile;
      const subdomain = ["a", "b", "c", "d"][(wrappedX + tileY) % 4];
      const style = theme === "dark" ? "dark_all" : "light_all";
      const url = `https://${subdomain}.basemaps.cartocdn.com/${style}/${transform.zoom}/${wrappedX}/${tileY}@2x.png`;
      tileJobs.push(loadImage(url, true).then((image) => ({
        image,
        x: tileX * tileSize - worldLeft,
        y: tileY * tileSize - worldTop,
      })).catch(() => null));
    }
  }
  const tiles = await Promise.all(tileJobs);
  tiles.filter(Boolean).forEach(({ image, x, y }) => ctx.drawImage(image, x, y, tileSize, tileSize));
  return transform;
}

function drawProjectedRoute(ctx, transform, c) {
  if (transform.points.length < 2) return;
  const projected = transform.points.map(transform.project);
  const path = () => {
    ctx.beginPath();
    projected.forEach(([x, y], index) => index ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
  };
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  path();
  ctx.strokeStyle = c.routeShadow;
  ctx.lineWidth = 18;
  ctx.stroke();
  path();
  ctx.strokeStyle = c.accent;
  ctx.lineWidth = 9;
  ctx.stroke();
  [[...projected[0], c.start], [...projected.at(-1), c.finish]].forEach(([x, y, fill]) => {
    ctx.beginPath();
    ctx.arc(x, y, 13, 0, Math.PI * 2);
    ctx.fillStyle = fill;
    ctx.fill();
    ctx.lineWidth = 6;
    ctx.strokeStyle = c.card;
    ctx.stroke();
  });
}

function drawDetailedChart(ctx, label, values, y, color, c, reverse = false, unit = "") {
  roundedRect(ctx, 54, y, 972, 174, 0);
  ctx.fillStyle = c.detailedPanel;
  ctx.fill();
  ctx.fillStyle = c.ink;
  ctx.font = "800 25px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText(label, 84, y + 56);
  const clean = chartValues(values);
  if (clean.length < 2) {
    ctx.fillStyle = c.dim;
    ctx.font = "650 20px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText("暂无数据", 84, y + 100);
    return;
  }
  const min = Math.min(...clean), max = Math.max(...clean);
  const span = Math.max(max - min, 1);
  const chartX = 255, chartY = y + 24, chartWidth = 660, chartHeight = 112;
  ctx.strokeStyle = c.line;
  ctx.lineWidth = 2;
  [0, .5, 1].forEach((ratio) => {
    const lineY = chartY + chartHeight * ratio;
    ctx.beginPath(); ctx.moveTo(chartX, lineY); ctx.lineTo(chartX + chartWidth, lineY); ctx.stroke();
  });
  ctx.beginPath();
  clean.forEach((value, index) => {
    const x = chartX + index / (clean.length - 1) * chartWidth;
    const ratio = (value - min) / span;
    const py = chartY + (reverse ? ratio : 1 - ratio) * chartHeight;
    if (index) ctx.lineTo(x, py); else ctx.moveTo(x, py);
  });
  ctx.strokeStyle = color;
  ctx.lineWidth = 4;
  ctx.lineJoin = "round";
  ctx.stroke();
  ctx.fillStyle = c.dim;
  ctx.font = "650 18px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.textAlign = "right";
  ctx.fillText(`${Math.round(max)}${unit}`, 990, chartY + 17);
  ctx.fillText(`${Math.round(min)}${unit}`, 990, chartY + chartHeight);
  ctx.textAlign = "left";
}

function drawCircularImage(ctx, image, x, y, size) {
  ctx.save();
  ctx.beginPath();
  ctx.arc(x + size / 2, y + size / 2, size / 2, 0, Math.PI * 2);
  ctx.clip();
  const side = Math.min(image.naturalWidth, image.naturalHeight);
  const sx = (image.naturalWidth - side) / 2;
  const sy = (image.naturalHeight - side) / 2;
  ctx.drawImage(image, sx, sy, side, side, x, y, size, size);
  ctx.restore();
}

async function drawDetailedCard(canvas, run, route, title, requestedTheme) {
  const actualTheme = resolveTheme(requestedTheme);
  const c = colorsFor(actualTheme);
  canvas.width = CARD_WIDTH;
  canvas.height = DETAILED_CARD_HEIGHT;
  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, CARD_WIDTH, DETAILED_CARD_HEIGHT);
  ctx.fillStyle = c.background;
  ctx.fillRect(0, 0, CARD_WIDTH, DETAILED_CARD_HEIGHT);
  const coordinates = route.coordinates || route.preview_coordinates || [];
  const assets = Promise.all([
    loadImage(PROFILE_URL).catch(() => null),
    QRCode.toDataURL(SITE_URL, { width: 220, margin: 1, errorCorrectionLevel: "M" })
      .then((url) => loadImage(url)).catch(() => null),
  ]);
  const transform = await drawDetailedMap(ctx, coordinates, actualTheme);

  let fade = ctx.createLinearGradient(0, 0, 0, DETAILED_CARD_HEIGHT);
  fade.addColorStop(0, actualTheme === "dark" ? "rgba(8,12,18,.91)" : "rgba(243,246,249,.92)");
  fade.addColorStop(.14, actualTheme === "dark" ? "rgba(8,12,18,.18)" : "rgba(243,246,249,.14)");
  fade.addColorStop(.5, actualTheme === "dark" ? "rgba(8,12,18,.06)" : "rgba(243,246,249,.04)");
  fade.addColorStop(.64, actualTheme === "dark" ? "rgba(8,12,18,.18)" : "rgba(243,246,249,.18)");
  fade.addColorStop(.82, actualTheme === "dark" ? "rgba(8,12,18,.3)" : "rgba(243,246,249,.28)");
  fade.addColorStop(1, actualTheme === "dark" ? "rgba(8,12,18,.42)" : "rgba(243,246,249,.38)");
  ctx.fillStyle = fade;
  ctx.fillRect(0, 0, CARD_WIDTH, DETAILED_CARD_HEIGHT);
  drawProjectedRoute(ctx, transform, c);

  const [avatar, qr] = await assets;
  if (avatar) drawCircularImage(ctx, avatar, 54, 48, 82);
  ctx.fillStyle = c.accent;
  ctx.font = "850 24px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("TODAY RUN", 160, 79);
  ctx.fillStyle = c.ink;
  ctx.font = "850 58px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText(title || "今日跑步", 160, 137);
  ctx.fillStyle = c.dim;
  ctx.font = "700 24px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.textAlign = "right";
  ctx.fillText(run.date || "", 1020, 78);
  ctx.fillText(run.city || route.city || "", 1020, 116);
  ctx.textAlign = "left";

  roundedRect(ctx, 52, 215, 360, 54, 16);
  ctx.fillStyle = actualTheme === "dark" ? "rgba(16,23,34,.9)" : "rgba(255,255,255,.9)";
  ctx.fill();
  ctx.fillStyle = c.dim;
  ctx.font = "700 19px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText(`RUN LOG · ${route.city || run.city || "户外路线"}`, 72, 249);

  const stats = [
    ["平均心率", run.avg_heart_rate || "--", "bpm"],
    ["平均功率", run.avg_power ? Math.round(run.avg_power) : "--", "W"],
    ["平均配速", run.pace || "--", "/km"],
    ["用时", run.duration || run.finish_time || "--", "hh:mm:ss"],
    ["累计爬升", Math.round(route.elevation_gain || 0), "m"],
  ];
  roundedRect(ctx, 54, 1570, 972, 166, 22);
  ctx.fillStyle = actualTheme === "dark" ? "rgba(16,23,34,.94)" : "rgba(255,255,255,.94)";
  ctx.fill();
  const statWidth = 972 / stats.length;
  stats.forEach(([label, value, unit], index) => {
    const x = 54 + statWidth * index;
    if (index) { ctx.fillStyle = c.line; ctx.fillRect(x, 1590, 2, 126); }
    ctx.fillStyle = c.accent;
    ctx.font = "750 19px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText(label, x + 21, 1613);
    ctx.fillStyle = c.ink;
    ctx.font = "850 31px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText(String(value), x + 21, 1663);
    ctx.fillStyle = c.dim;
    ctx.font = "650 16px -apple-system, BlinkMacSystemFont, sans-serif";
    ctx.fillText(unit, x + 21, 1696);
  });

  roundedRect(ctx, 54, 1770, 972, 574, 24);
  ctx.fillStyle = c.detailedPanel;
  ctx.fill();
  ctx.fillStyle = c.ink;
  ctx.font = "850 30px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("详细折线图", 82, 1821);
  ctx.fillStyle = c.dim;
  ctx.font = "650 20px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.textAlign = "right";
  ctx.fillText("配速 · 爬升 · 心率", 994, 1820);
  ctx.textAlign = "left";
  const ts = route.time_series || {};
  drawDetailedChart(ctx, "配速", ts.pace, 1847, "#3b8bff", c, true, "′");
  drawDetailedChart(ctx, "海拔", ts.elevation, 2018, "#e87a20", c, false, "m");
  drawDetailedChart(ctx, "心率", ts.heartRate || ts.heart_rate, 2189, c.accent, c, false, "");

  roundedRect(ctx, 0, 2418, CARD_WIDTH, 382, 0);
  ctx.fillStyle = c.detailedFooter;
  ctx.fill();
  if (qr) {
    roundedRect(ctx, 62, 2502, 206, 206, 24);
    ctx.fillStyle = "#ffffff";
    ctx.fill();
    ctx.drawImage(qr, 75, 2515, 180, 180);
  }
  ctx.fillStyle = c.ink;
  ctx.font = "850 31px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("扫码查看我的跑步档案", 306, 2567);
  ctx.fillStyle = c.dim;
  ctx.font = "650 21px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText(SITE_URL, 306, 2610);
  ctx.fillText(`${Number(run.distance_km || route.distance_km || 0).toFixed(2)} km · ${run.date || ""}`, 306, 2652);
  ctx.textAlign = "right";
  ctx.fillStyle = c.accent;
  ctx.font = "900 22px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText("RUN LOG", 1012, 2698);
  ctx.textAlign = "left";
}

function canvasBlob(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error("无法导出画布")), "image/png", 0.96);
  });
}

async function generateSelectedCard() {
  if (!overlay) return;
  const requestSerial = ++generationSerial;
  const button = overlay.querySelector("#shareGenerate");
  const runId = overlay.querySelector("#shareRunSelect").value;
  const targetRun = eligibleRuns().find((run) => run.id === runId);
  if (!targetRun) return;
  button.disabled = true;
  setStatus("正在读取完整轨迹…");
  try {
    let route = routeCache.get(targetRun.route_id);
    if (!route) {
      route = await fetchRoute(targetRun.route_id);
      if (route) routeCache.set(targetRun.route_id, route);
    }
    if (requestSerial !== generationSerial || !overlay) return;
    if (!route) throw new Error("没有找到这条路线");
    const canvas = overlay.querySelector("#shareCanvas");
    const layout = overlay.querySelector("#shareLayout").value;
    const args = [canvas, targetRun, route, overlay.querySelector("#shareTitle").value.trim(), overlay.querySelector("#shareTheme").value];
    if (layout === "detailed") await drawDetailedCard(...args);
    else drawCompactCard(...args);
    if (requestSerial !== generationSerial || !overlay) return;
    selectedRun = targetRun;
    renderedBlob = await canvasBlob(overlay.querySelector("#shareCanvas"));
    if (requestSerial !== generationSerial || !overlay) return;
    const filename = `run-${selectedRun.date || "share"}-${layout}.png`;
    const download = overlay.querySelector("#shareDownload");
    if (download.href.startsWith("blob:")) URL.revokeObjectURL(download.href);
    download.href = URL.createObjectURL(renderedBlob);
    download.download = filename;
    download.classList.remove("is-disabled");
    const file = new File([renderedBlob], filename, { type: "image/png" });
    const canShare = !!navigator.share && (!navigator.canShare || navigator.canShare({ files: [file] }));
    overlay.querySelector("#shareNative").disabled = !canShare;
    setStatus(canShare ? "生成完成，可以下载或分享到手机。" : "生成完成，当前环境可下载 PNG。", false);
  } catch (error) {
    if (requestSerial !== generationSerial) return;
    console.error(error);
    setStatus(`生成失败：${error.message}`, true);
  } finally {
    if (requestSerial === generationSerial && overlay) button.disabled = false;
  }
}

async function shareGeneratedCard() {
  if (!renderedBlob || !selectedRun || !navigator.share) return;
  const layout = overlay?.querySelector("#shareLayout")?.value || "compact";
  const file = new File([renderedBlob], `run-${selectedRun.date || "share"}-${layout}.png`, { type: "image/png" });
  try {
    await navigator.share({ files: [file], title: "我的跑步记录" });
  } catch (error) {
    if (error.name !== "AbortError") setStatus(`分享失败：${error.message}`, true);
  }
}

export function initShareLab() {
  bindSecretGesture();
  const syncFromUrl = () => {
    if (isSharePath()) openShareLab();
    else if (overlay) {
      overlay.remove();
      overlay = null;
    }
  };
  window.addEventListener("hashchange", syncFromUrl);
  syncFromUrl();
}
