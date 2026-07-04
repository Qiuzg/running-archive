(function () {
  const data = window.RUN_ARCHIVE_DATA || { profile: {}, races: [], runs: [] };
  const routeIndex = window.RUN_ROUTE_INDEX || window.RUN_ROUTE_DATA || {};
  const cityBoundaries = window.RUN_CITY_BOUNDARIES || {};
  window.RUN_ROUTE_DETAIL = window.RUN_ROUTE_DETAIL || {};
  const currentYear = data.profile.currentYear || new Date().getFullYear();
  const raceTypes = {
    marathon: "全马",
    half_marathon: "半马",
    "10k": "10K",
    other: "其他",
  };
  const cityHighlightRadiusKm = {
    南京: 38,
    杭州: 42,
    宿迁: 42,
    眉山: 40,
    合肥: 42,
    上海: 36,
    北京: 48,
    苏州: 36,
    无锡: 34,
    常州: 36,
  };
  const amapConfig = {
    key: "d27e9d7cea2761b3c3d1fa55b0a077dc",
    cloudflareHosts: ["running-archive.pages.dev"],
    enabledStorageKey: "RUN_USE_AMAP",
    localSecurityStorageKey: "RUN_AMAP_SECURITY_JSCODE",
  };
  const amapStyles = {
    light: "amap://styles/whitesmoke",
    dark: "amap://styles/dark",
  };
  const byDateDesc = (a, b) => new Date(b.date) - new Date(a.date);

  // Filter out evening "races" — real races start in the morning (before noon).
  // Extract start hour from sourceRunId (format: apple-YYYYMMDD-HHMMSS).
  function isMorningRace(race) {
    const id = race.sourceRunId || race.id || "";
    const match = id.match(/[_-](\d{2})(\d{2})(\d{2})$/);
    if (!match) return true; // can't parse time — keep it
    const hour = parseInt(match[1], 10);
    return hour < 12;
  }

  const races = [...data.races].filter(isMorningRace).sort(byDateDesc);
  const marathonTimeline = races.filter((race) => race.type === "marathon");
  const runs = [...data.runs].sort(byDateDesc);
  const raceSourceRunIds = new Set(races.map((race) => race.sourceRunId).filter(Boolean));
  const activityItems = [
    ...races.map((item) => ({ ...item, source: "race" })),
    ...data.runs
      .filter((item) => !raceSourceRunIds.has(item.id))
      .map((item) => ({ ...item, source: "run" })),
  ];
  const routesPerPage = 18;
  const availableYears = [...new Set(activityItems.map((item) => new Date(item.date).getFullYear()))]
    .filter((year) => Number.isFinite(year))
    .sort((a, b) => b - a);
  const activityByRouteId = new Map();
  activityItems.forEach((item) => {
    if (!item.routeId) return;
    const current = activityByRouteId.get(item.routeId);
    if (!current || new Date(item.date) > new Date(current.date)) {
      activityByRouteId.set(item.routeId, item);
    }
  });
  const routeEntries = activityItems
    .filter((item) => item.routeId && routeIndex[item.routeId])
    .sort(byDateDesc);
  const shortDateCache = new Map();
  const dateCache = new Map();
  const routeSvgCache = new Map();
  let activeRouteId = null;
  let routePage = 0;
  let routeMap = null;
  let routeLayer = null;
  let leafletPromise = null;
  let amapPromise = null;
  let chartJsPromise = null;
  let statsCharts = [];      // active Chart.js instances
  let statsOverlayRequestId = 0;
  let selectedStatsYear = availableYears.includes(currentYear) ? currentYear : availableYears[0] || currentYear;
  let selectedStatsMonth = null;

  const leafletSources = [
    {
      css: "https://cdn.bootcdn.net/ajax/libs/leaflet/1.9.4/leaflet.css",
      js: "https://cdn.bootcdn.net/ajax/libs/leaflet/1.9.4/leaflet.js",
    },
    {
      css: "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css",
      js: "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js",
    },
    {
      css: "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css",
      js: "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js",
    },
  ];
  const chartJsSources = [
    "https://cdn.bootcdn.net/ajax/libs/Chart.js/4.4.0/chart.umd.js",
    "https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.js",
    "https://unpkg.com/chart.js@4.4.0/dist/chart.umd.js",
  ];

  function getActivityForRoute(routeId) {
    return activityByRouteId.get(routeId) || null;
  }

  // Sync .is-active UI state across race cards and route items
  function updateActiveRouteUI(routeId) {
    document.querySelectorAll(".race-card[data-route-target]").forEach((card) => {
      card.classList.toggle("is-active", card.dataset.routeTarget === routeId);
    });
    document.querySelectorAll("[data-hero-route]").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.heroRoute === routeId);
    });
    if (window.matchMedia?.("(max-width: 760px)").matches) {
      setTimeout(() => {
        const activeItem = document.querySelector(".hero-route-item.is-active, .race-card.is-active");
        activeItem?.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }, 0);
    }
  }

  function setRouteSelectedState(selected, source = "route") {
    const hero = document.querySelector(".hero");
    if (!hero) return;
    hero.classList.toggle("hero--route-selected", selected);
    hero.classList.toggle("hero--race-selected", selected && source === "race");
  }

  const routeItems = Object.values(routeIndex).sort((a, b) => {
    const activityA = getActivityForRoute(a.id);
    const activityB = getActivityForRoute(b.id);
    const dateA = activityA?.date || "0000-00-00";
    const dateB = activityB?.date || "0000-00-00";
    return new Date(dateB) - new Date(dateA);
  });

  function parseTimeToSeconds(value) {
    if (!value) return Infinity;
    const parts = value.split(":").map(Number);
    if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length === 2) return parts[0] * 60 + parts[1];
    return Infinity;
  }

  function formatDate(value) {
    if (dateCache.has(value)) return dateCache.get(value);
    const formatted = new Intl.DateTimeFormat("zh-CN", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date(value));
    dateCache.set(value, formatted);
    return formatted;
  }

  function formatShortDate(value) {
    if (shortDateCache.has(value)) return shortDateCache.get(value);
    const date = new Date(value);
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

  function formatKm(value) {
    return `${Number(value).toFixed(value >= 100 ? 0 : 1)} km`;
  }

  function displayText(value, fallback = "--") {
    return value === undefined || value === null || value === "" ? fallback : value;
  }

  function formatPlace(item) {
    return [item.city, item.country].filter(Boolean).join(" · ");
  }

  function findPB(type) {
    const candidates = races.filter((race) => race.type === type);
    if (!candidates.length) return null;
    return candidates.reduce((best, race) =>
      parseTimeToSeconds(race.finishTime) < parseTimeToSeconds(best.finishTime) ? race : best,
    );
  }

  function getYearDistance(year) {
    return activityItems
      .filter((item) => new Date(item.date).getFullYear() === year)
      .reduce((sum, item) => sum + Number(item.distanceKm || 0), 0);
  }

  function getMonthlyTotals(year) {
    const totals = Array.from({ length: 12 }, () => 0);
    activityItems.forEach((item) => {
      const date = new Date(item.date);
      if (date.getFullYear() === year) {
        totals[date.getMonth()] += Number(item.distanceKm || 0);
      }
    });
    return totals;
  }

  function getMonthActivities(year, month) {
    return activityItems
      .filter((item) => {
        const date = new Date(item.date);
        return date.getFullYear() === year && date.getMonth() === month;
      })
      .sort(byDateDesc);
  }

  function createMetric(label, value, detail) {
    return `
      <article class="metric">
        <span class="metric__label">${label}</span>
        <strong>${value}</strong>
        <small>${detail}</small>
      </article>
    `;
  }

  function escapeAttr(value) {
    return String(value ?? "").replace(/"/g, "&quot;");
  }

  function positionTooltip(el, event) {
    const chartBlock = el.closest(".chart-block");
    if (!chartBlock) return;
    const rect = chartBlock.getBoundingClientRect();
    const x = (event.touches ? event.touches[0].clientX : event.clientX) - rect.left + 12;
    const y = (event.touches ? event.touches[0].clientY : event.clientY) - rect.top - 32;
    el.style.left = x + "px";
    el.style.top = y + "px";
  }

  function isMobileViewport() {
    return window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
  }

  function getMaxPanelHeightWithOverlay() {
    return Math.max(118, window.innerHeight - 220);
  }

  function syncMobileStatsOverlayLayout() {
    const overlay = document.querySelector("#heroStatsOverlay");
    if (!overlay) return;

    const hero = document.querySelector(".hero");
    const panel = document.querySelector(".hero__panel");
    const routeSelected = hero && hero.classList.contains("hero--route-selected");
    if (!isMobileViewport() || !routeSelected || activePanelTab === "stats" || !panel) {
      overlay.style.bottom = "";
      return;
    }

    const maxPanelHeight = getMaxPanelHeightWithOverlay();
    let panelHeight = panel.getBoundingClientRect().height;
    if (panelHeight > maxPanelHeight) {
      panel.style.maxHeight = maxPanelHeight + "px";
      panelHeight = panel.getBoundingClientRect().height;
    }

    // Overlay sits above the bottom panel (panel bottom: 8px, gap: 16px).
    overlay.style.bottom = 8 + panelHeight + 16 + "px";
  }

  function alignBarReferenceLines(scope = document) {
    const chart = scope.querySelector(".bar-chart");
    if (!chart) return;
    const sampleBar = chart.querySelector(".bar");
    const sampleTrack = chart.querySelector(".bar i");
    if (!sampleBar || !sampleTrack) return;

    const chartRect = chart.getBoundingClientRect();
    const barRect = sampleBar.getBoundingClientRect();
    const trackRect = sampleTrack.getBoundingClientRect();
    const plotTop = barRect.top;
    const plotBottom = trackRect.bottom;
    const plotHeight = plotBottom - plotTop;
    if (plotHeight <= 0) return;

    chart.querySelectorAll(".bar-ref-line[data-ref-pct]").forEach((line) => {
      const pct = Number(line.dataset.refPct || 0);
      const y = plotBottom - (plotHeight * pct) / 100;
      line.style.bottom = chartRect.bottom - y + "px";
    });
  }

  function projectRoutePoints(coordinates, width = 420, height = 240, padding = 28) {
    if (!coordinates || coordinates.length < 2) return [];
    const mercator = coordinates.map(([lon, lat]) => {
      const clampedLat = Math.max(Math.min(lat, 85.05112878), -85.05112878);
      const x = (lon * Math.PI) / 180;
      const y = Math.log(Math.tan(Math.PI / 4 + (clampedLat * Math.PI) / 360));
      return { x, y };
    });
    const minX = Math.min(...mercator.map((point) => point.x));
    const maxX = Math.max(...mercator.map((point) => point.x));
    const minY = Math.min(...mercator.map((point) => point.y));
    const maxY = Math.max(...mercator.map((point) => point.y));
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

  function getSvgColors() {
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

  function renderRouteSvg(route, variant = "large") {
    if (!route) {
      return '<div class="route-empty">暂无路线</div>';
    }
    const theme = document.documentElement.dataset.theme || "dark";
    const cacheKey = route.id
      ? `${theme}:${variant}:${route.id}:${route.coordinates?.length || route.previewCoordinates?.length || 0}`
      : null;
    if (cacheKey && routeSvgCache.has(cacheKey)) {
      return routeSvgCache.get(cacheKey);
    }
    const projected = projectRoutePoints(route.coordinates, 420, 240, variant === "mini" ? 12 : 28);
    if (!projected.length) {
      return '<div class="route-empty">路线加载中</div>';
    }
    const c = getSvgColors();
    const paperRadius = variant === "mini" ? 0 : 8;
    const points = projected.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");
    const startPoint = projected[0];
    const endPoint = projected[projected.length - 1];

    const isMini = variant === "mini";
    const svg = `
      <svg class="route-svg route-svg--${variant}" viewBox="0 0 420 240" role="img" aria-label="${escapeAttr(route.name)}路线图">
        <defs>
          <linearGradient id="route-paper-${escapeAttr(route.id)}" x1="0" x2="1" y1="0" y2="1">
            <stop offset="0%" stop-color="${c.bg1}" />
            <stop offset="54%" stop-color="${c.bg2}" />
            <stop offset="100%" stop-color="${c.bg3}" />
          </linearGradient>
          <pattern id="route-grid-${escapeAttr(route.id)}" width="28" height="28" patternUnits="userSpaceOnUse">
            <path d="M 28 0 L 0 0 0 28" fill="none" stroke="${c.grid}" stroke-width="1" />
          </pattern>
        </defs>
        ${isMini ? "" : `
        <rect width="420" height="240" rx="${paperRadius}" fill="url(#route-paper-${escapeAttr(route.id)})" />
        <rect width="420" height="240" rx="${paperRadius}" fill="url(#route-grid-${escapeAttr(route.id)})" opacity="0.75" />
        <path d="M-18 204 C68 150 150 204 235 148 S342 86 442 122" fill="none" stroke="${c.decor1}" stroke-width="2" stroke-dasharray="8 9" opacity="0.5" />
        <path d="M26 58 C110 112 178 46 250 88 S336 166 398 78" fill="none" stroke="${c.decor2}" stroke-width="2" stroke-dasharray="4 7" opacity="0.4" />
        <path d="M16 28 H404 M16 212 H404 M22 22 V218 M398 22 V218" fill="none" stroke="${c.decor3}" stroke-width="1" />
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

  function routeWithPreview(route) {
    return {
      ...route,
      coordinates: route?.coordinates || route?.previewCoordinates || [],
    };
  }

  function renderRaceRoutePreview(race) {
    const route = routeIndex[race.routeId];
    if (!route?.previewCoordinates?.length) {
      return `<div class="race-card__fallback"><span>${raceTypes[race.type] || "RUN"}</span><strong>${formatKm(race.distanceKm)}</strong></div>`;
    }

    return `
      <div class="race-route-preview">
        ${renderRouteSvg(routeWithPreview(route), "mini")}
      </div>
    `;
  }

  function renderSummary() {
    const totalKm = activityItems.reduce((sum, item) => sum + Number(item.distanceKm || 0), 0);
    const marathonPB = findPB("marathon");
    const halfPB = findPB("half_marathon");
    const strip = document.querySelector("#summaryStrip");
    if (!strip) return;
    strip.innerHTML = [
      createMetric("累计里程", formatKm(totalKm), "比赛与训练合计"),
      createMetric(`${currentYear} 年跑量`, formatKm(getYearDistance(currentYear)), "自动按日期归档"),
      createMetric("全马 PB", marathonPB ? marathonPB.finishTime : "--", marathonPB ? marathonPB.name : "等待第一场全马"),
      createMetric("半马 PB", halfPB ? halfPB.finishTime : "--", halfPB ? halfPB.name : "等待第一场半马"),
      createMetric("完赛场次", `${races.length} 场`, `${marathonTimeline.length} 场全马`),
    ].join("");
  }

  function renderRouteDetail(route, detail, isPreview = false) {
    const activity = getActivityForRoute(route.id);
    const coordinates = detail?.coordinates || route.previewCoordinates || [];
    const routeForDrawing = { ...route, ...detail, coordinates };
    const routeDate = activity?.date ? formatDate(activity.date) : "--";
    const routePlace = route.city || activity?.location || "--";
    const duration = activity?.finishTime || activity?.duration || "--";
    const pace = activity?.pace ? `${activity.pace} /km` : "--";
    return `
      <div class="route-map-card__header">
        <div>
          <p class="eyebrow">Selected Route</p>
          <h3>${route.name}</h3>
        </div>
        <span>${formatKm(route.distanceKm)}</span>
      </div>
      <div class="route-map-card__canvas">
        <div class="route-map-actions">
          <button class="map-action" type="button" data-load-online-map>加载在线地图底图</button>
          <span>本地轨迹优先显示，在线地图较慢时不会挡住路线。</span>
        </div>
        <div class="map-canvas" id="routeMap" aria-label="${escapeAttr(route.name)}地图" hidden></div>
        <div class="map-fallback" id="routeMapFallback">${renderRouteSvg(routeForDrawing)}</div>
      </div>
      <div class="route-facts">
        <article><span>日期</span><strong>${routeDate}</strong></article>
        <article><span>地点</span><strong>${displayText(routePlace)}</strong></article>
        <article><span>距离</span><strong>${formatKm(activity?.distanceKm || route.distanceKm)}</strong></article>
        <article><span>用时</span><strong>${duration}</strong></article>
        <article><span>配速</span><strong>${pace}</strong></article>
      </div>
      <p class="route-note">起终点附近已隐藏，公开页面不展示精确住址附近轨迹。${isPreview ? "完整轨迹加载后会自动替换当前预览。" : ""}</p>
    `;
  }

  function loadRouteDetail(routeId) {
    if (window.RUN_ROUTE_DETAIL[routeId]) {
      return Promise.resolve(window.RUN_ROUTE_DETAIL[routeId]);
    }
    return new Promise((resolve, reject) => {
      const existing = document.querySelector(`script[data-route-script="${escapeAttr(routeId)}"]`);
      if (existing) {
        if (existing.dataset.loaded === "true" || window.RUN_ROUTE_DETAIL[routeId]) {
          resolve(window.RUN_ROUTE_DETAIL[routeId]);
          return;
        }
        existing.addEventListener("load", () => resolve(window.RUN_ROUTE_DETAIL[routeId]));
        existing.addEventListener("error", reject);
        return;
      }
      const script = document.createElement("script");
      script.src = `./routes/${routeId}.js?v=20260702-6`;
      script.dataset.routeScript = routeId;
      script.onload = () => {
        script.dataset.loaded = "true";
        resolve(window.RUN_ROUTE_DETAIL[routeId]);
      };
      script.onerror = () => reject(new Error(`Cannot load route ${routeId}`));
      document.body.appendChild(script);
    });
  }

  function loadStylesheetOnce(href) {
    if (document.querySelector(`link[href="${escapeAttr(href)}"]`)) return;
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    document.head.appendChild(link);
  }

  function loadScriptWithTimeout(src, timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      const existing = document.querySelector(`script[src="${escapeAttr(src)}"]`);
      if (existing?.dataset.loaded === "true") {
        resolve();
        return;
      }

      const script = existing || document.createElement("script");
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        script.remove();
        reject(new Error(`Script load timed out: ${src}`));
      }, timeoutMs);

      script.async = true;
      script.src = src;
      script.onload = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        script.dataset.loaded = "true";
        resolve();
      };
      script.onerror = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        script.remove();
        reject(new Error(`Script load failed: ${src}`));
      };

      if (!existing) document.body.appendChild(script);
    });
  }

  function loadLeaflet() {
    if (window.L) return Promise.resolve(window.L);
    if (leafletPromise) return leafletPromise;
    leafletPromise = (async () => {
      let lastError = null;
      for (const source of leafletSources) {
        try {
          loadStylesheetOnce(source.css);
          await loadScriptWithTimeout(source.js);
          if (window.L) return window.L;
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError || new Error("Leaflet load failed");
    })();
    return leafletPromise;
  }

  function shouldUseAmap() {
    try {
      return Boolean(amapConfig.key && localStorage.getItem(amapConfig.enabledStorageKey) === "true");
    } catch (_) {
      return false;
    }
  }

  function getLocalAmapSecurityCode() {
    try {
      return localStorage.getItem(amapConfig.localSecurityStorageKey) || "";
    } catch (_) {
      return "";
    }
  }

  function getAmapSecurityConfig() {
    const host = window.location.hostname;
    if (amapConfig.cloudflareHosts.includes(host)) {
      return { serviceHost: `${window.location.origin}/_AMapService` };
    }
    const localSecurityCode = getLocalAmapSecurityCode();
    return localSecurityCode ? { securityJsCode: localSecurityCode } : {};
  }

  function loadAmap() {
    if (window.AMap) return Promise.resolve(window.AMap);
    if (amapPromise) return amapPromise;
    amapPromise = (async () => {
      window._AMapSecurityConfig = getAmapSecurityConfig();
      const src = `https://webapi.amap.com/maps?v=2.0&key=${encodeURIComponent(amapConfig.key)}`;
      await loadScriptWithTimeout(src, 9000);
      if (window.AMap) return window.AMap;
      throw new Error("AMap load failed");
    })();
    return amapPromise;
  }

  function isInChina(lon, lat) {
    return lon >= 72.004 && lon <= 137.8347 && lat >= 0.8293 && lat <= 55.8271;
  }

  function transformLat(x, y) {
    let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
    ret += ((20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0) / 3.0;
    ret += ((20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin((y / 3.0) * Math.PI)) * 2.0) / 3.0;
    ret += ((160.0 * Math.sin((y / 12.0) * Math.PI) + 320 * Math.sin((y * Math.PI) / 30.0)) * 2.0) / 3.0;
    return ret;
  }

  function transformLon(x, y) {
    let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
    ret += ((20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0) / 3.0;
    ret += ((20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin((x / 3.0) * Math.PI)) * 2.0) / 3.0;
    ret += ((150.0 * Math.sin((x / 12.0) * Math.PI) + 300.0 * Math.sin((x / 30.0) * Math.PI)) * 2.0) / 3.0;
    return ret;
  }

  function wgs84ToGcj02(lon, lat) {
    if (!isInChina(lon, lat)) return [lon, lat];
    const a = 6378245.0;
    const ee = 0.00669342162296594323;
    let dLat = transformLat(lon - 105.0, lat - 35.0);
    let dLon = transformLon(lon - 105.0, lat - 35.0);
    const radLat = (lat / 180.0) * Math.PI;
    let magic = Math.sin(radLat);
    magic = 1 - ee * magic * magic;
    const sqrtMagic = Math.sqrt(magic);
    dLat = (dLat * 180.0) / (((a * (1 - ee)) / (magic * sqrtMagic)) * Math.PI);
    dLon = (dLon * 180.0) / ((a / sqrtMagic) * Math.cos(radLat) * Math.PI);
    return [lon + dLon, lat + dLat];
  }

  function toAmapPoint(point) {
    return wgs84ToGcj02(Number(point[0]), Number(point[1]));
  }

  function loadChartJs() {
    if (window.Chart) return Promise.resolve(window.Chart);
    if (chartJsPromise) return chartJsPromise;
    chartJsPromise = (async () => {
      let lastError = null;
      for (const src of chartJsSources) {
        try {
          await loadScriptWithTimeout(src);
          if (window.Chart) return window.Chart;
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError || new Error("Chart.js load failed");
    })();
    return chartJsPromise;
  }

  function getTileProviders() {
    const theme = document.documentElement.dataset.theme || "dark";
    const cartoStyle = theme === "light" ? "light_all" : "dark_all";
    return [
      {
        name: `carto-${cartoStyle}`,
        url: `https://{s}.basemaps.cartocdn.com/${cartoStyle}/{z}/{x}/{y}{r}.png`,
        subdomains: "abcd",
      },
      {
        name: "openstreetmap",
        url: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
        subdomains: "abc",
      },
    ];
  }

  function getTileOptions(provider) {
    const isMobile = window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
    return {
      maxZoom: 19,
      subdomains: provider.subdomains,
      updateWhenIdle: isMobile,
      keepBuffer: isMobile ? 4 : 2,
      crossOrigin: true,
    };
  }

  function addResilientTileLayer(map) {
    const providers = getTileProviders();
    let providerIndex = 0;
    let activeLayer = null;
    let loadStarted = 0;
    let loadFinished = 0;
    let loadFailed = 0;
    let fallbackTimer = null;

    function clearFallbackTimer() {
      if (fallbackTimer) {
        clearTimeout(fallbackTimer);
        fallbackTimer = null;
      }
    }

    function switchProvider() {
      if (providerIndex >= providers.length - 1) return;
      providerIndex += 1;
      activateProvider(providerIndex);
    }

    function scheduleFallback() {
      clearFallbackTimer();
      fallbackTimer = setTimeout(() => {
        if (loadStarted >= 4 && loadFinished < Math.min(4, Math.ceil(loadStarted / 2))) {
          switchProvider();
        }
      }, 4500);
    }

    function activateProvider(index) {
      clearFallbackTimer();
      if (activeLayer && map.hasLayer(activeLayer)) {
        map.removeLayer(activeLayer);
      }

      loadStarted = 0;
      loadFinished = 0;
      loadFailed = 0;
      const provider = providers[index];
      const layer = window.L.tileLayer(provider.url, getTileOptions(provider));
      activeLayer = layer;
      heroTileLayer = layer;
      layer.on("tileloadstart", () => {
        if (layer !== activeLayer) return;
        loadStarted += 1;
        scheduleFallback();
      });
      layer.on("tileload", () => {
        if (layer !== activeLayer) return;
        loadFinished += 1;
        if (loadFinished >= 4) clearFallbackTimer();
      });
      layer.on("tileerror", () => {
        if (layer !== activeLayer) return;
        loadFailed += 1;
        if (loadFailed >= 2 || (loadStarted >= 4 && loadFinished === 0)) {
          switchProvider();
        }
      });
      layer.addTo(map);
    }

    activateProvider(providerIndex);
    return activeLayer;
  }

  function initMobileDoubleTapZoom(map, mapEl) {
    if (!map || !mapEl || mapEl.dataset.doubleTapZoomBound === "true") return;
    mapEl.dataset.doubleTapZoomBound = "true";

    let lastTapTime = 0;
    let lastTapPoint = null;
    const maxTapGapMs = 320;
    const maxTapDistancePx = 42;

    mapEl.addEventListener("touchend", (event) => {
      if (!isMobileViewport() || event.changedTouches.length !== 1 || event.touches.length) return;
      if (event.target.closest?.(".leaflet-control")) return;

      const touch = event.changedTouches[0];
      const now = Date.now();
      const point = { x: touch.clientX, y: touch.clientY };
      const distance = lastTapPoint
        ? Math.hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y)
        : Infinity;
      const isDoubleTap = now - lastTapTime <= maxTapGapMs && distance <= maxTapDistancePx;

      if (isDoubleTap) {
        event.preventDefault();
        const rect = mapEl.getBoundingClientRect();
        const containerPoint = window.L.point(point.x - rect.left, point.y - rect.top);
        const latLng = map.containerPointToLatLng(containerPoint);
        const maxZoom = map.getMaxZoom ? map.getMaxZoom() : 19;
        map.setZoomAround(latLng, Math.min(map.getZoom() + 1, maxZoom));
        lastTapTime = 0;
        lastTapPoint = null;
        return;
      }

      lastTapTime = now;
      lastTapPoint = point;
    }, { passive: false });
  }

  function renderLeafletRoute(route, detail) {
    const mapEl = document.querySelector("#routeMap");
    const fallbackEl = document.querySelector("#routeMapFallback");
    if (!mapEl || !fallbackEl) return;
    if (!window.L || !detail?.coordinates || detail.coordinates.length < 2) {
      return;
    }

    mapEl.hidden = false;
    fallbackEl.hidden = true;
    const latLngs = detail.coordinates.map(([lon, lat]) => [lat, lon]);

    // Create map once; on subsequent calls just swap layers
    if (!routeMap) {
      routeMap = window.L.map(mapEl, {
        attributionControl: true,
        scrollWheelZoom: false,
      });
      window.L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
        maxZoom: 19,
        attribution: "&copy; CartoDB",
        subdomains: "abcd",
      }).addTo(routeMap);
    }

    // Remove previous layers before adding new ones
    if (routeLayer) routeMap.removeLayer(routeLayer);
    if (routeMap._startMarker) routeMap.removeLayer(routeMap._startMarker);
    if (routeMap._endMarker) routeMap.removeLayer(routeMap._endMarker);

    routeLayer = window.L.polyline(latLngs, {
      color: "#2457d6",
      weight: 5,
      opacity: 0.92,
      lineJoin: "round",
      lineCap: "round",
    }).addTo(routeMap);
    routeMap._startMarker = window.L.circleMarker(latLngs[0], {
      radius: 6,
      color: "#207868",
      fillColor: "#ffffff",
      fillOpacity: 1,
      weight: 3,
    }).addTo(routeMap);
    routeMap._endMarker = window.L.circleMarker(latLngs[latLngs.length - 1], {
      radius: 6,
      color: "#ffffff",
      fillColor: "#d94b3d",
      fillOpacity: 1,
      weight: 3,
    }).addTo(routeMap);
    routeMap.fitBounds(routeLayer.getBounds(), { padding: [28, 28] });
    setTimeout(() => routeMap.invalidateSize(), 0);
  }

  function renderMonthRecords() {
    const container = document.querySelector("#monthRecords");
    if (!container) return;
    const month = selectedStatsMonth ?? new Date().getMonth();
    const records =
      selectedStatsMonth === null
        ? []
        : getMonthActivities(selectedStatsYear, month).sort((a, b) => new Date(a.date) - new Date(b.date));
    const monthTotal = records.reduce((sum, item) => sum + Number(item.distanceKm || 0), 0);
    const maxDistance = Math.max(...records.map((item) => Number(item.distanceKm || 0)), 1);
    const longest = [...records].sort((a, b) => Number(b.distanceKm || 0) - Number(a.distanceKm || 0))[0];
    container.innerHTML = `
      <div class="month-records__header">
        <div>
          <span>${selectedStatsYear}</span>
          <strong>${selectedStatsMonth === null ? "选择月份查看记录" : `${month + 1} 月训练分布`}</strong>
        </div>
        ${selectedStatsMonth === null
        ? ""
        : `<small>${records.length} 次 · ${formatKm(monthTotal)}${longest ? ` · 最长 ${formatKm(longest.distanceKm)}` : ""}</small>`
      }
      </div>
      ${selectedStatsMonth === null
        ? '<p class="empty empty--compact">点击上方月份柱查看当月跑步和比赛记录。</p>'
        : records.length
          ? `<div class="month-detail-chart ${records.length <= 8 ? "is-sparse" : ""}" aria-label="${selectedStatsYear} 年 ${month + 1} 月跑步柱状图">${records
            .map(
              (item) => {
                const distance = Number(item.distanceKm || 0);
                const height = Math.max((distance / maxDistance) * 100, distance > 0 ? 8 : 2);
                const day = new Date(item.date).getDate();
                const title = item.name || item.title;
                const tooltip = `${title} · ${formatKm(distance)} · ${item.pace}/km`;
                const content = `
                      <i style="--activity-height: ${height}%"></i>
                      <small>${day}</small>
                    `;
                return item.routeId
                  ? `<button
                          class="month-activity-bar"
                          type="button"
                          data-route-target="${escapeAttr(item.routeId)}"
                          title="${escapeAttr(tooltip)}"
                          aria-label="${escapeAttr(`${tooltip}，查看路线`)}"
                        >${content}</button>`
                  : `<div
                          class="month-activity-bar"
                          title="${escapeAttr(tooltip)}"
                          aria-label="${escapeAttr(tooltip)}"
                        >${content}</div>`;
              },
            )
            .join("")}</div>`
          : '<p class="empty empty--compact">这个月没有记录。</p>'
      }
    `;
  }

  let activePanelTab = "routes";

  function switchPanelTab(tab) {
    activePanelTab = tab;
    setRouteSelectedState(false);
    clearStatsOverlay();
    document.querySelectorAll("[data-panel-tab]").forEach((link) => {
      link.classList.toggle("is-active", link.dataset.panelTab === tab);
    });
    document.querySelector("#panelEyebrow").textContent =
      tab === "routes" ? "Route Atlas" : tab === "races" ? "Race Records" : "Year in Motion";
    document.querySelector("#panelTitle").textContent =
      tab === "routes" ? "路线足迹" : tab === "races" ? "比赛记录" : "年度统计";
    // Stats tab: keep map but show all routes as background
    const heroEl = document.querySelector(".hero");
    const mapContainer = document.querySelector("#heroMap");
    const summaryStrip = document.querySelector("#summaryStrip");
    const panelHeader = document.querySelector(".hero__panel-header");
    heroEl.classList.remove("hero--stats-full");
    if (mapContainer) mapContainer.style.display = "";
    if (summaryStrip) summaryStrip.style.display = "";
    if (panelHeader) panelHeader.style.display = "";
    clearStatsOverlay();
    setRouteSelectedState(false);
    // Show all route traces on map for stats overview
    if (tab === "stats") {
      showAllRoutesOnMap();
      // Hide city boundary highlights on stats page
      hideHeroCityLayer();
      // Center map on route centroid with zoomed-in view
      setHeroStatsView();
    } else {
      hideAllRoutesFromMap();
      // Restore city boundary highlights when leaving stats
      showHeroCityLayer();
      // Reset map to default bounds
      restoreHeroDefaultView();
    }
    // Hide collapse toggle on stats tab (not useful there)
    const toggle = document.querySelector("#panelCollapseToggle");
    if (toggle) toggle.style.display = tab === "stats" ? "none" : "";
    setTimeout(() => {
      invalidateHeroMapSize();
    }, 100);
    renderPanelContent();
  }

  function renderPanelContent() {
    const body = document.querySelector("#heroPanelBody");
    const subtitle = document.querySelector("#panelSubtitle");
    if (!body) return;
    if (activePanelTab === "routes") {
      subtitle.textContent = "";
      renderPanelRoutes(body);
    } else if (activePanelTab === "races") {
      subtitle.textContent = `${races.length} 场比赛 · ${marathonTimeline.length} 场全马`;
      renderPanelRaces(body);
    } else if (activePanelTab === "stats") {
      subtitle.textContent = "";
      renderPanelStats(body);
    }
  }

  function initPanelTabs() {
    document.querySelectorAll("[data-panel-tab]").forEach((link) => {
      link.addEventListener("click", (event) => {
        event.preventDefault();
        switchPanelTab(link.dataset.panelTab);
      });
    });
  }

  function initPanelCollapse() {
    const header = document.querySelector(".hero__panel-header");
    const panel = document.querySelector(".hero__panel");
    if (!header || !panel) return;

    // Inject toggle button into header
    const btn = document.createElement("button");
    btn.className = "panel-collapse-toggle";
    btn.type = "button";
    btn.id = "panelCollapseToggle";
    btn.setAttribute("aria-label", "折叠面板");
    btn.innerHTML = "<span>▼</span>";
    header.appendChild(btn);

    // Restore saved state
    const collapsed = localStorage.getItem("panelCollapsed") === "true";
    if (collapsed) {
      panel.classList.add("hero__panel--collapsed");
      btn.innerHTML = "<span>▲</span>";
      btn.setAttribute("aria-label", "展开面板");
    }

    btn.addEventListener("click", () => {
      panel.classList.toggle("hero__panel--collapsed");
      const isCollapsed = panel.classList.contains("hero__panel--collapsed");
      btn.innerHTML = isCollapsed ? "<span>▲</span>" : "<span>▼</span>";
      btn.setAttribute("aria-label", isCollapsed ? "展开面板" : "折叠面板");
      localStorage.setItem("panelCollapsed", isCollapsed);
      // Re-render to show fewer/more items
      renderPanelContent();
      setTimeout(() => {
        invalidateHeroMapSize();
      }, 300);
    });

    // ---- Drag-to-resize handle (at top of panel) ----
    var handle = document.createElement("div");
    handle.className = "panel-resize-handle";
    handle.id = "panelResizeHandle";
    panel.insertBefore(handle, panel.firstChild);

    var savedHeight = localStorage.getItem("panelHeight");
    if (savedHeight) {
      panel.style.maxHeight = savedHeight;
    }

    var dragging = false;
    var startY = 0;
    var startHeight = 0;

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
      var clientY = e.touches ? e.touches[0].clientY : e.clientY;
      var delta = startY - clientY;
      var isMobile = isMobileViewport();
      var heroEl = document.querySelector(".hero");
      var routeSelected = heroEl && heroEl.classList.contains("hero--route-selected");
      var maxHeight = isMobile && routeSelected ? getMaxPanelHeightWithOverlay() : window.innerHeight - 80;
      var minHeight = isMobile && routeSelected ? 118 : 200;
      var newHeight = Math.max(minHeight, Math.min(maxHeight, startHeight + delta));
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
      invalidateHeroMapSize();
    }

    handle.addEventListener("mousedown", onDragStart);
    handle.addEventListener("touchstart", onDragStart, { passive: false });
    document.addEventListener("mousemove", onDragMove);
    document.addEventListener("touchmove", onDragMove, { passive: false });
    document.addEventListener("mouseup", onDragEnd);
    document.addEventListener("touchend", onDragEnd);
  }

  // Reset panel height to default (used when route is selected from stats)
  function resetPanelHeight() {
    var panel = document.querySelector(".hero__panel");
    if (panel) {
      panel.style.maxHeight = "";
      localStorage.removeItem("panelHeight");
      if (heroMap) setTimeout(invalidateHeroMapSize, 300);
    }
  }

  function renderPanelRoutes(container) {
    if (!routeEntries.length) {
      container.innerHTML = '<p class="empty">暂无路线数据</p>';
      return;
    }
    const panel = document.querySelector(".hero__panel");
    const collapsed = panel && panel.classList.contains("hero__panel--collapsed");
    const visible = collapsed ? routeEntries.slice(0, 3) : routeEntries;
    container.innerHTML = visible
      .map((item) => {
        const route = routeIndex[item.routeId];
        const activity = getActivityForRoute(item.routeId);
        const dateStr = activity ? formatShortDate(activity.date) : null;
        const title = item.name || item.title || route.name || "未知路线";
        const dist = formatKm(route.distanceKm || item.distanceKm || 0);
        const isActive = item.routeId === heroActiveRouteId;
        const svg = route.previewCoordinates
          ? renderRouteSvg(routeWithPreview(route), "mini")
          : '<div class="route-empty">--</div>';
        return `
          <button class="hero-route-item ${isActive ? "is-active" : ""}" type="button" data-hero-route="${escapeAttr(item.routeId)}">
            <span class="hero-route-item__thumb">${svg}</span>
            <span class="hero-route-item__info">
              <strong>${title}</strong>
              <span>${dateStr ? `${dateStr.year}/${dateStr.monthDay}` : "--"} · ${dist}</span>
            </span>
          </button>
        `;
      })
      .join("");
    if (collapsed && routeEntries.length > 3) {
      container.innerHTML += `<p class="panel-collapsed-hint">还有 ${routeEntries.length - 3} 条路线 · 点击 ▲ 展开</p>`;
    }
    container.querySelectorAll("[data-hero-route]").forEach((btn) => {
      btn.addEventListener("click", () => {
        if (btn.dataset.heroRoute === heroActiveRouteId) return;
        heroActiveRouteId = btn.dataset.heroRoute;
        updateHeroRoute(heroActiveRouteId, true, "route");
        updateActiveRouteUI(heroActiveRouteId);
      });
    });
  }

  function renderPanelRaces(container) {
    const marathonRaces = races.filter((r) => r.type === "marathon");
    const halfRaces = races.filter((r) => r.type === "half_marathon");
    const otherRaces = races.filter((r) => r.type !== "marathon" && r.type !== "half_marathon");

    function renderGroupCard(race) {
      const hasPhoto = race.photos && race.photos.length > 0;
      const place = [race.city, race.country].filter(Boolean).join(" · ");
      let media;
      if (hasPhoto) {
        media = `<img src="${race.photos[0]}" alt="${race.name}" />`;
      } else if (race.routeId && routeIndex[race.routeId]?.previewCoordinates?.length) {
        media = `
          <div class="race-route-preview">
            ${renderRouteSvg(routeWithPreview(routeIndex[race.routeId]), "mini")}
          </div>`;
      } else {
        media = `<div class="race-card__fallback"><span>${raceTypes[race.type] || "RUN"}</span><strong>${formatKm(race.distanceKm)}</strong></div>`;
      }
      const hasRoute = race.routeId && routeIndex[race.routeId];
      const isActive = hasRoute && race.routeId === heroActiveRouteId;
      return `
        <article class="race-card ${isActive ? "is-active" : ""}" ${hasRoute ? `data-route-target="${escapeAttr(race.routeId)}"` : ""}>
          <div class="race-card__media">${media}</div>
          <div class="race-card__body">
            <div class="race-card__meta"><span>${formatDate(race.date)}</span>${race.isPB ? '<b class="badge badge--small">PB</b>' : ""}</div>
            <h3>${race.name}</h3>
            ${place || race.bibNumber ? `<p>${[place, race.bibNumber ? `号码 ${race.bibNumber}` : ""].filter(Boolean).join(" · ")}</p>` : ""}
            <div class="race-card__result">
              <span>${formatKm(race.distanceKm)}</span><strong>${race.finishTime}</strong><span>${race.pace} /km</span>
            </div>
            ${race.notes ? `<p class="race-card__notes">${race.notes}</p>` : ""}
          </div>
        </article>
      `;
    }

    const panel = document.querySelector(".hero__panel");
    const collapsed = panel && panel.classList.contains("hero__panel--collapsed");
    const allRaces = [...races].sort(byDateDesc);
    const visibleRaces = collapsed ? allRaces.slice(0, 1) : allRaces;
    const hiddenCount = collapsed ? Math.max(0, allRaces.length - 1) : 0;

    let sections = [];
    if (visibleRaces.length) {
      sections.push(`<div class="record-grid">${visibleRaces.map(renderGroupCard).join("")}</div>`);
    }
    if (!sections.length) {
      sections.push('<p class="empty">还没有比赛记录。</p>');
    }

    container.innerHTML = sections.join("");
    if (collapsed && hiddenCount > 0) {
      container.innerHTML += `<p class="panel-collapsed-hint">还有 ${hiddenCount} 场比赛 · 点击 ▲ 展开</p>`;
    }
    initRouteLinks();
  }

  function renderPanelStats(container) {
    const year = selectedStatsYear;
    const totals = getMonthlyTotals(year);
    const max = Math.max(...totals, 1);
    const yearDist = getYearDistance(year);
    const yearRaces = races.filter((r) => new Date(r.date).getFullYear() === year);
    const yearMarathonCount = yearRaces.filter((r) => r.type === "marathon").length;
    const yearHalfCount = yearRaces.filter((r) => r.type === "half_marathon").length;
    const activeMonths = totals.filter(t => t > 0).length;
    const monthlyAvg = activeMonths > 0 ? yearDist / activeMonths : 0;
    const longestRun = activityItems
      .filter(item => new Date(item.date).getFullYear() === year)
      .reduce((best, item) => Number(item.distanceKm || 0) > Number(best.distanceKm || 0) ? item : best, { distanceKm: 0 });
    const yearIdx = availableYears.indexOf(year);
    const hasPrev = yearIdx < availableYears.length - 1;
    const hasNext = yearIdx > 0;

    // Build reference lines at 100 km intervals
    const step = 100;
    const refLines = [];
    for (let v = step; v <= Math.ceil(max / step) * step; v += step) {
      const pct = (v / max) * 100;
      if (pct <= 100) refLines.push({ value: v, pct: pct });
    }

    const bars = totals
      .map((t, i) => {
        const h = Math.max((t / max) * 100, t > 0 ? 6 : 2);
        return `<button class="bar ${selectedStatsMonth === i ? "is-active" : ""}" type="button"
          data-stats-month="${i}" data-bar-value="${t ? t.toFixed(0) : "0"}"
          aria-label="${year}年${i + 1}月跑量${formatKm(t)}" style="--bar-height: ${h}%">
          <i></i><small>${i + 1}月</small></button>`;
      })
      .join("");

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
        <div class="chart-block__header">
          <h3>月度跑量</h3>
        </div>
        <div class="bar-chart">
          ${refLines.map(l => `<span class="bar-ref-line" data-ref-pct="${l.pct}" style="bottom:${l.pct}%"><small>${l.value}</small></span>`).join("")}
          ${bars}
        </div>
        <div class="bar-tooltip" id="barTooltip" hidden></div>
      </div>
      <div class="stats-meta-row">
        <div class="stats-meta-item">
          <span>比赛</span>
          <strong>${yearRaces.length} 场</strong>
          <small>全马 ${yearMarathonCount} · 半马 ${yearHalfCount}</small>
        </div>
        <div class="stats-meta-item">
          <span>月均跑量</span>
          <strong>${formatKm(monthlyAvg)}</strong>
          <small>${activeMonths} 个月有记录</small>
        </div>
        <div class="stats-meta-item">
          <span>最长距离</span>
          <strong>${formatKm(longestRun.distanceKm || 0)}</strong>
          <small>${longestRun.name || longestRun.title || "--"}</small>
        </div>
      </div>
      <div class="month-records" id="monthRecords"></div>
    `;
    alignBarReferenceLines(container);

    // Year navigation
    container.querySelector("[data-stats-year-prev]")?.addEventListener("click", () => {
      if (hasPrev) {
        selectedStatsYear = availableYears[yearIdx + 1];
        selectedStatsMonth = null;
        renderPanelStats(container);
      }
    });
    container.querySelector("[data-stats-year-next]")?.addEventListener("click", () => {
      if (hasNext) {
        selectedStatsYear = availableYears[yearIdx - 1];
        selectedStatsMonth = null;
        renderPanelStats(container);
      }
    });
    // Month bar clicks + hover tooltip
    const tooltip = container.querySelector("#barTooltip");
    container.querySelectorAll("[data-stats-month]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const m = Number(btn.dataset.statsMonth);
        selectedStatsMonth = selectedStatsMonth === m ? null : m;
        renderPanelStats(container);
      });
      btn.addEventListener("mouseenter", (e) => {
        if (!tooltip) return;
        const val = btn.dataset.barValue;
        const month = Number(btn.dataset.statsMonth) + 1;
        tooltip.textContent = `${month}月 · ${val} km`;
        tooltip.hidden = false;
        positionTooltip(tooltip, e);
      });
      btn.addEventListener("mousemove", (e) => {
        if (tooltip && !tooltip.hidden) positionTooltip(tooltip, e);
      });
      btn.addEventListener("mouseleave", () => {
        if (tooltip) tooltip.hidden = true;
      });
    });
    // Touch: show on tap, hide after delay
    container.querySelectorAll("[data-stats-month]").forEach((btn) => {
      btn.addEventListener("touchstart", (e) => {
        if (!tooltip) return;
        const val = btn.dataset.barValue;
        const month = Number(btn.dataset.statsMonth) + 1;
        tooltip.textContent = `${month}月 · ${val} km`;
        tooltip.hidden = false;
        positionTooltip(tooltip, e);
        clearTimeout(btn._tooltipTimer);
        btn._tooltipTimer = setTimeout(() => { if (tooltip) tooltip.hidden = true; }, 1500);
      }, { passive: true });
    });
    renderMonthRecords();
    initRouteLinks();
  }

  // Extract HTML generation from renderTimeline for reuse
  function renderTimelineHTML() {
    return marathonTimeline
      .sort((a, b) => new Date(a.date) - new Date(b.date))
      .map((race) => {
        const place = [race.city, race.country].filter(Boolean).join(" · ");
        return `
          <article class="timeline-item">
            <div class="timeline-item__body">
              <div class="timeline-item__date"><span>${formatShortDate(race.date).year}</span>${formatShortDate(race.date).monthDay}</div>
              <div class="timeline-item__copy">
                <h3>${race.name}</h3>
                ${place ? `<p>${place}</p>` : ""}
              </div>
              <div class="race-result">
                <span>${race.finishTime}</span>
                <small>${race.pace} /km</small>
                ${race.isPB ? '<b class="badge">PB</b>' : ""}
                ${race.routeId ? `<button class="route-link" type="button" data-route-target="${escapeAttr(race.routeId)}">路线</button>` : ""}
              </div>
            </div>
          </article>
        `;
      })
      .join("") || '<p class="empty">还没有马拉松记录。</p>';
  }

  function renderRaceCardsHTML() {
    return races
      .map((race) => {
        const hasPhoto = race.photos && race.photos.length > 0;
        const place = [race.city, race.country].filter(Boolean).join(" · ");
        let media;
        if (hasPhoto) {
          media = `<img src="${race.photos[0]}" alt="${race.name}" />`;
        } else if (race.routeId && routeIndex[race.routeId]?.previewCoordinates?.length) {
          media = `
            <div class="race-route-preview">
              ${renderRouteSvg(routeWithPreview(routeIndex[race.routeId]), "mini")}
            </div>`;
        } else {
          media = `<div class="race-card__fallback"><span>${raceTypes[race.type] || "RUN"}</span><strong>${formatKm(race.distanceKm)}</strong></div>`;
        }
        const hasRoute = race.routeId && routeIndex[race.routeId];
        const isActive = hasRoute && race.routeId === heroActiveRouteId;
        return `
          <article class="race-card ${isActive ? "is-active" : ""}" ${hasRoute ? `data-route-target="${escapeAttr(race.routeId)}"` : ""}>
            <div class="race-card__media">${media}</div>
            <div class="race-card__body">
              <div class="race-card__meta"><span>${raceTypes[race.type] || race.type}</span><span>${formatDate(race.date)}</span></div>
              <h3>${race.name}</h3>
              ${place || race.bibNumber ? `<p>${[place, race.bibNumber ? `号码 ${race.bibNumber}` : ""].filter(Boolean).join(" · ")}</p>` : ""}
              <div class="race-card__result">
                <span>${formatKm(race.distanceKm)}</span><strong>${race.finishTime}</strong><span>${race.pace} /km</span>
                ${race.isPB ? '<b class="badge badge--small">PB</b>' : ""}
              </div>
              ${race.notes ? `<p class="race-card__notes">${race.notes}</p>` : ""}
            </div>
          </article>
        `;
      })
      .join("") || '<p class="empty">还没有比赛记录。</p>';
  }

  function initRouteLinks() {
    // Race cards — entire card is clickable (skip nested interactive elements)
    document.querySelectorAll(".race-card[data-route-target]").forEach((card) => {
      card.onclick = (event) => {
        if (event.target.closest("button, a, input, select, textarea")) return;
        const routeId = card.dataset.routeTarget;
        if (routeId === heroActiveRouteId) return;
        heroActiveRouteId = routeId;
        updateHeroRoute(routeId, true, "race");
        updateActiveRouteUI(routeId);
      };
    });

    // Other route-target buttons (month bars, timeline links, etc.)
    document.querySelectorAll("[data-route-target]:not(.race-card)").forEach((el) => {
      el.onclick = () => {
        const routeId = el.dataset.routeTarget;
        if (routeId === heroActiveRouteId) return;
        heroActiveRouteId = routeId;
        // Reset panel height to default when clicking route from stats
        if (activePanelTab === "stats") resetPanelHeight();
        updateHeroRoute(routeId, true, "route");
        updateActiveRouteUI(routeId);
      };
    });
  }

  // Hero map state (shared with panel render functions)
  let heroMapEngine = "leaflet";
  let heroMap = null;
  let heroTileLayer = null;
  let heroRouteLine = null;
  let heroCityLayer = null;
  let heroActiveRouteId = null;
  let heroAllRoutesLayer = null;
  let defaultMapBounds = null;
  let defaultMapCenter = null;
  let defaultMapZoom = null;

  function invalidateHeroMapSize() {
    if (!heroMap) return;
    if (heroMapEngine === "amap") {
      heroMap.resize?.();
    } else if (heroMap.invalidateSize) {
      heroMap.invalidateSize();
    }
  }

  function addAmapOverlays(overlays) {
    if (!heroMap || !overlays?.length) return;
    overlays.forEach((overlay) => heroMap.add(overlay));
  }

  function removeAmapOverlays(overlays) {
    if (!heroMap || !overlays?.length) return;
    overlays.forEach((overlay) => heroMap.remove(overlay));
  }

  function hideHeroCityLayer(clear = false) {
    if (!heroCityLayer || !heroMap) return;
    if (heroMapEngine === "amap") {
      removeAmapOverlays(heroCityLayer);
    } else {
      heroMap.removeLayer(heroCityLayer);
      if (clear) heroCityLayer = null;
    }
  }

  function showHeroCityLayer() {
    if (!heroCityLayer || !heroMap) return;
    if (heroMapEngine === "amap") {
      addAmapOverlays(heroCityLayer);
    } else if (!heroMap.hasLayer(heroCityLayer)) {
      heroCityLayer.addTo(heroMap);
    }
  }

  function setHeroStatsView() {
    if (!heroMap) return;
    if (heroMapEngine === "amap") {
      heroMap.setZoomAndCenter(12, toAmapPoint([118.75, 32.02]));
    } else if (window.L) {
      heroMap.setView([32.02, 118.75], 12);
    }
  }

  function restoreHeroDefaultView() {
    if (!heroMap) return;
    if (heroMapEngine === "amap") {
      if (defaultMapBounds?.length) {
        heroMap.setFitView(defaultMapBounds, false, [80, 120, 80, 120]);
      } else if (defaultMapCenter && defaultMapZoom) {
        heroMap.setZoomAndCenter(defaultMapZoom, defaultMapCenter);
      }
    } else if (defaultMapBounds) {
      heroMap.fitBounds(defaultMapBounds, { padding: [80, 120] });
    } else if (defaultMapCenter && defaultMapZoom) {
      heroMap.setView(defaultMapCenter, defaultMapZoom);
    }
  }

  function getGeoJsonRings(geojson) {
    const rings = [];
    function readGeometry(geometry) {
      if (!geometry) return;
      if (geometry.type === "Polygon") {
        if (geometry.coordinates?.[0]?.length) rings.push(geometry.coordinates[0]);
      } else if (geometry.type === "MultiPolygon") {
        geometry.coordinates?.forEach((polygon) => {
          if (polygon?.[0]?.length) rings.push(polygon[0]);
        });
      }
    }
    if (geojson.type === "FeatureCollection") {
      geojson.features?.forEach((feature) => readGeometry(feature.geometry));
    } else if (geojson.type === "Feature") {
      readGeometry(geojson.geometry);
    } else {
      readGeometry(geojson);
    }
    return rings;
  }

  function getCityCenter(coordinates) {
    const lons = coordinates.map((point) => point[0]);
    const lats = coordinates.map((point) => point[1]);
    return [
      lats.reduce((sum, value) => sum + value, 0) / lats.length,
      lons.reduce((sum, value) => sum + value, 0) / lons.length,
    ];
  }

  function createAmapCityOverlays(cityAreas) {
    const overlays = [];
    for (const area of cityAreas.values()) {
      const boundary = cityBoundaries[area.city];
      const rings = boundary ? getGeoJsonRings(boundary) : [];
      if (rings.length) {
        rings.forEach((ring) => {
          overlays.push(new window.AMap.Polygon({
            path: ring.map(toAmapPoint),
            strokeColor: "#ff8a6e",
            strokeOpacity: 0.32,
            strokeWeight: 1,
            fillColor: "#ff5e3a",
            fillOpacity: 0.12,
            zIndex: 12,
          }));
        });
      } else {
        const center = getCityCenter(area.coordinates);
        const radiusKm = cityHighlightRadiusKm[area.city] || 36;
        overlays.push(new window.AMap.Circle({
          center: toAmapPoint([center[1], center[0]]),
          radius: radiusKm * 1000,
          strokeOpacity: 0,
          strokeWeight: 0,
          fillColor: "#ff5e3a",
          fillOpacity: 0.11,
          zIndex: 12,
        }));
      }
    }
    return overlays;
  }

  function showAllRoutesOnMap() {
    if (!heroMap) return;
    if (heroMapEngine === "amap") {
      if (heroAllRoutesLayer) {
        addAmapOverlays(heroAllRoutesLayer);
        return;
      }
      const marathonRouteIds = new Set(races.filter(r => r.type === "marathon" || r.type === "half_marathon").map(r => r.routeId).filter(Boolean));
      const priorityRoutes = routeItems.filter(r => marathonRouteIds.has(r.id));
      const otherRoutes = routeItems.filter(r => !marathonRouteIds.has(r.id));
      const ordered = [...otherRoutes, ...priorityRoutes];
      heroAllRoutesLayer = [];
      for (const route of ordered) {
        const coords = route.previewCoordinates;
        if (!coords || coords.length < 2) continue;
        const isRaceRoute = marathonRouteIds.has(route.id);
        heroAllRoutesLayer.push(new window.AMap.Polyline({
          path: coords.map(toAmapPoint),
          strokeColor: isRaceRoute ? "#ff8a6e" : "#4a6a8a",
          strokeWeight: isRaceRoute ? 2 : 1,
          strokeOpacity: isRaceRoute ? 0.5 : 0.28,
          lineJoin: "round",
          lineCap: "round",
          bubble: true,
          zIndex: isRaceRoute ? 18 : 16,
        }));
      }
      addAmapOverlays(heroAllRoutesLayer);
      return;
    }
    if (!window.L) return;
    if (heroAllRoutesLayer) {
      if (!heroMap.hasLayer(heroAllRoutesLayer)) heroAllRoutesLayer.addTo(heroMap);
      return;
    }
    heroAllRoutesLayer = window.L.featureGroup().addTo(heroMap);
    const allRouteEntries = routeItems;
    // Sort so marathon/half routes are drawn on top
    const marathonRouteIds = new Set(races.filter(r => r.type === "marathon" || r.type === "half_marathon").map(r => r.routeId).filter(Boolean));
    const priorityRoutes = allRouteEntries.filter(r => marathonRouteIds.has(r.id));
    const otherRoutes = allRouteEntries.filter(r => !marathonRouteIds.has(r.id));
    const ordered = [...otherRoutes, ...priorityRoutes];
    for (const route of ordered) {
      const coords = route.previewCoordinates;
      if (!coords || coords.length < 2) continue;
      const latlngs = coords.map(([lon, lat]) => [lat, lon]);
      const isRaceRoute = marathonRouteIds.has(route.id);
      window.L.polyline(latlngs, {
        color: isRaceRoute ? "#ff8a6e" : "#4a6a8a",
        weight: isRaceRoute ? 1.5 : 0.8,
        opacity: isRaceRoute ? 0.5 : 0.28,
        lineJoin: "round",
        lineCap: "round",
        interactive: false,
      }).addTo(heroAllRoutesLayer);
    }
  }

  function hideAllRoutesFromMap() {
    if (!heroAllRoutesLayer || !heroMap) return;
    if (heroMapEngine === "amap") {
      removeAmapOverlays(heroAllRoutesLayer);
    } else {
      heroMap.removeLayer(heroAllRoutesLayer);
    }
  }

  function initHeroMap() {
    const heroMapEl = document.querySelector("#heroMap");
    if (!heroMapEl) return;
    let amapRuntimeFailed = false;
    let amapFallbackStarted = false;
    let restoreConsoleError = null;

    // City highlight areas for marathon/half-marathon races
    const cityAreas = new Map();
    for (const race of races) {
      if (race.type !== "marathon" && race.type !== "half_marathon") continue;
      const route = routeIndex[race.routeId];
      if (!route || !route.previewCoordinates || !route.previewCoordinates.length) continue;
      const cityKey = race.city || race.name;
      const area = cityAreas.get(cityKey) || {
        city: race.city || race.name,
        names: [],
        coordinates: [],
      };
      area.names.push(race.name);
      area.coordinates.push(...route.previewCoordinates);
      cityAreas.set(cityKey, area);
    }

    function getCircleBounds(center, radiusKm) {
      const latDelta = radiusKm / 111;
      const lonDelta = radiusKm / (111 * Math.max(Math.cos((center[0] * Math.PI) / 180), 0.2));
      return window.L.latLngBounds(
        [center[0] - latDelta, center[1] - lonDelta],
        [center[0] + latDelta, center[1] + lonDelta],
      );
    }

    function handleAmapRuntimeError(event) {
      const filename = event.filename || "";
      const message = event.message || "";
      if (filename.includes("webapi.amap.com") || message.includes("INVALID_USER_DOMAIN")) {
        amapRuntimeFailed = true;
      }
    }

    function clearAmapRuntimeWatcher() {
      window.removeEventListener("error", handleAmapRuntimeError, true);
      if (restoreConsoleError) {
        restoreConsoleError();
        restoreConsoleError = null;
      }
    }

    function watchAmapConsoleErrors() {
      if (restoreConsoleError) return;
      const originalConsoleError = console.error;
      console.error = function (...args) {
        const message = args.map((item) => String(item)).join(" ");
        if (message.includes("INVALID_USER_DOMAIN") || message.includes("USERKEY")) {
          amapRuntimeFailed = true;
        }
        originalConsoleError.apply(console, args);
      };
      restoreConsoleError = () => {
        console.error = originalConsoleError;
      };
    }

    function resetHeroMapState() {
      if (heroMap?.destroy) {
        try {
          heroMap.destroy();
        } catch (_) {
          // Ignore cleanup failures while falling back to Leaflet.
        }
      }
      heroMapEl.innerHTML = "";
      heroMap = null;
      heroTileLayer = null;
      heroRouteLine = null;
      heroCityLayer = null;
      heroAllRoutesLayer = null;
      defaultMapBounds = null;
      defaultMapCenter = null;
      defaultMapZoom = null;
    }

    function fallbackToLeaflet(error) {
      if (amapFallbackStarted) return;
      amapFallbackStarted = true;
      clearAmapRuntimeWatcher();
      console.warn("AMap unavailable, falling back to Leaflet:", error);
      resetHeroMapState();
      initLeafletFallback();
    }

    function renderAmapHeroMap() {
      if (!window.AMap) return;
      heroMapEngine = "amap";
      const isMobile = window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
      heroMapEl.dataset.mapEngine = "amap";
      heroMap = new window.AMap.Map(heroMapEl, {
        attributionControl: false,
        center: toAmapPoint([118.75, 32.02]),
        doubleClickZoom: true,
        dragEnable: true,
        jogEnable: false,
        mapStyle: amapStyles[document.documentElement.dataset.theme || "light"],
        resizeEnable: true,
        scrollWheel: !isMobile,
        touchZoom: true,
        viewMode: "2D",
        zoom: 5,
        zoomEnable: true,
      });

      heroCityLayer = createAmapCityOverlays(cityAreas);
      addAmapOverlays(heroCityLayer);
      if (heroCityLayer.length) {
        heroMap.setFitView(heroCityLayer, false, [80, 120, 80, 120]);
        defaultMapBounds = heroCityLayer;
        const center = heroMap.getCenter();
        defaultMapCenter = [center.lng, center.lat];
        defaultMapZoom = heroMap.getZoom();
      }

      const observer = new MutationObserver(() => {
        setTimeout(invalidateHeroMapSize, 350);
      });
      observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });

      setTimeout(() => {
        if (amapRuntimeFailed) {
          fallbackToLeaflet(new Error("AMap runtime error"));
        } else {
          clearAmapRuntimeWatcher();
        }
      }, 2500);
    }

    function renderLeafletHeroMap() {
      if (!window.L) return;
      heroMapEngine = "leaflet";
      var isMobile = window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
      heroMapEl.dataset.mapEngine = "leaflet";
      heroMap = window.L.map(heroMapEl, {
        attributionControl: false,
        zoomControl: !isMobile,
        scrollWheelZoom: !isMobile,
        doubleClickZoom: true,
        tap: true,
        touchZoom: true,
      });
      initMobileDoubleTapZoom(heroMap, heroMapEl);
      heroTileLayer = addResilientTileLayer(heroMap);

      // City highlight areas
      heroCityLayer = window.L.featureGroup().addTo(heroMap);
      let cityBounds = null;
      for (const area of cityAreas.values()) {
        const boundary = cityBoundaries[area.city];
        if (boundary && window.L.geoJSON) {
          const layer = window.L.geoJSON(boundary, {
            style: {
              color: "#ff8a6e",
              fillColor: "#ff5e3a",
              fillOpacity: 0.12,
              opacity: 0.32,
              weight: 1,
              className: "race-city-area",
            },
          })
            .bindTooltip(`${area.city}<br><small>${area.names.length} 场比赛</small>`, { direction: "top" })
            .addTo(heroCityLayer);
          const bounds = layer.getBounds();
          cityBounds = cityBounds ? cityBounds.extend(bounds) : bounds;
        } else {
          const center = getCityCenter(area.coordinates);
          const radiusKm = cityHighlightRadiusKm[area.city] || 36;
          window.L.circle(center, {
            radius: radiusKm * 1000,
            color: "#ff8a6e",
            fillColor: "#ff5e3a",
            fillOpacity: 0.11,
            opacity: 0,
            weight: 0,
            interactive: true,
            className: "race-city-area",
          })
            .bindTooltip(`${area.city}<br><small>${area.names.length} 场比赛</small>`, { direction: "top" })
            .addTo(heroCityLayer);
          const bounds = getCircleBounds(center, radiusKm);
          cityBounds = cityBounds ? cityBounds.extend(bounds) : bounds;
        }
      }

      if (cityBounds) {
        heroMap.fitBounds(cityBounds, { padding: [80, 120] });
        defaultMapBounds = cityBounds;
        defaultMapCenter = [cityBounds.getCenter().lat, cityBounds.getCenter().lng];
        defaultMapZoom = heroMap.getZoom();
      }

      const observer = new MutationObserver(() => {
        setTimeout(invalidateHeroMapSize, 350);
      });
      observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });
    }

    const initLeafletFallback = () => loadLeaflet().then(renderLeafletHeroMap).catch((error) => {
      console.warn("Hero map initialization failed:", error);
    });

    if (shouldUseAmap()) {
      window.addEventListener("error", handleAmapRuntimeError, true);
      watchAmapConsoleErrors();
      loadAmap().then(renderAmapHeroMap).catch((error) => {
        fallbackToLeaflet(error);
      });
    } else {
      initLeafletFallback();
    }
  }

  // Expose updateHeroRoute at module level for panel functions
  function updateHeroRoute(routeId, fit, source = "route") {
    if (!heroMap) return;
    setRouteSelectedState(true, source);

    if (heroMapEngine === "amap") {
      if (heroRouteLine) {
        heroMap.remove(heroRouteLine);
        heroRouteLine = null;
      }
      hideHeroCityLayer();
      const route = routeIndex[routeId];
      const coords = route && route.previewCoordinates;
      if (coords && coords.length) {
        heroRouteLine = new window.AMap.Polyline({
          path: coords.map(toAmapPoint),
          strokeColor: "#3b8bff",
          strokeWeight: 5,
          strokeOpacity: 0.92,
          lineJoin: "round",
          lineCap: "round",
          zIndex: 30,
        });
        heroMap.add(heroRouteLine);
        if (fit) {
          heroMap.setFitView([heroRouteLine], false, [80, 120, 80, 120]);
        }
      }
      renderStatsOverlay(routeId);
      return;
    }

    if (!window.L) return;
    if (heroRouteLine) {
      heroMap.removeLayer(heroRouteLine);
      heroRouteLine = null;
    }
    hideHeroCityLayer(true);
    const route = routeIndex[routeId];
    const coords = route && route.previewCoordinates;
    if (coords && coords.length) {
      const latlngs = coords.map(([lon, lat]) => [lat, lon]);
      heroRouteLine = window.L.polyline(latlngs, {
        color: "#3b8bff",
        weight: 5,
        opacity: 0.92,
        lineJoin: "round",
        lineCap: "round",
      }).addTo(heroMap);
      if (fit) {
        heroMap.fitBounds(heroRouteLine.getBounds(), { padding: [80, 120] });
      }
    }
    renderStatsOverlay(routeId);
  }

  // ---- Stats overlay with sparkline charts ----

  function clearStatsOverlay() {
    statsOverlayRequestId += 1;
    var existing = document.querySelector("#heroStatsOverlay");
    if (existing) existing.remove();
    destroyStatsCharts();
  }

  function destroyStatsCharts() {
    statsCharts.forEach(function (c) { c.destroy(); });
    statsCharts = [];
  }

  function chartColors() {
    var isLight = document.documentElement.dataset.theme === "light";
    return {
      grid: isLight ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.10)",
      text: isLight ? "rgba(0,0,0,0.45)" : "rgba(255,255,255,0.45)",
      line: isLight ? "#1a73e8" : "#5b9aff",
      fill: isLight ? "rgba(26,115,232,0.08)" : "rgba(91,154,255,0.10)",
      elevation: isLight ? "#e87a20" : "#ff9e4a",
    };
  }

  function formatElapsed(seconds) {
    if (seconds == null) return "";
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    if (h > 0) return h + ":" + String(m).padStart(2, "0") + "h";
    return m + "min";
  }

  function makeSparkConfig(labels, data, lineColor, fillColor, yLabel, reverseY) {
    var colors = chartColors();
    // Calculate y-axis range from data with tight padding for readability
    var validData = data.filter(function (v) { return v != null; });
    var yMin, yMax;
    if (validData.length >= 2) {
      yMin = Math.min.apply(null, validData);
      yMax = Math.max.apply(null, validData);
      var pad = (yMax - yMin) * 0.12 || 1;  // 12% padding, min 1 unit
      yMin = Math.floor(yMin - pad);
      yMax = Math.ceil(yMax + pad);
    }
    var cfg = {
      type: "line",
      data: {
        labels: labels,
        datasets: [{
          data: data,
          borderColor: lineColor,
          backgroundColor: fillColor,
          borderWidth: 1.5,
          pointRadius: 0,
          pointHoverRadius: 4,
          pointHoverBackgroundColor: lineColor,
          tension: 0.2,
          fill: true,
          spanGaps: true,
        }],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: { intersect: false, mode: "nearest" },
        plugins: { legend: { display: false }, tooltip: { enabled: false } },
        scales: {
          x: {
            display: true,
            ticks: { color: colors.text, font: { size: 9 }, maxTicksLimit: 6, maxRotation: 0 },
            grid: { color: colors.grid, drawTicks: false },
          },
          y: {
            display: true,
            position: "right",
            reverse: reverseY || false,
            min: yMin,
            max: yMax,
            ticks: { color: colors.text, font: { size: 9 }, maxTicksLimit: 3, callback: function (v) { return v; } },
            grid: { color: colors.grid, drawTicks: false },
            title: { display: !!yLabel, text: yLabel || "", color: colors.text, font: { size: 10, weight: "bold" } },
          },
        },
      },
    };
    return cfg;
  }

  async function renderStatsOverlay(routeId) {
    clearStatsOverlay();
    var requestId = statsOverlayRequestId;
    if (activePanelTab === "stats" || routeId !== heroActiveRouteId) return;

    var route = routeIndex[routeId];
    if (!route) return;

    var activity = getActivityForRoute(routeId);
    if (!activity) return;

    var compactOverlay = window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
    var stats = [];
    if (activity.avgHeartRate) {
      stats.push({
        label: compactOverlay ? "心率" : "平均心率",
        value: compactOverlay ? activity.avgHeartRate + "bpm" : activity.avgHeartRate + " bpm",
        sub: compactOverlay ? "" : activity.maxHeartRate ? "最高 " + activity.maxHeartRate : "",
        compact: true,
      });
    }
    if (activity.avgPower && !compactOverlay) {
      stats.push({ label: "平均功率", value: activity.avgPower + " W", compact: false });
    }
    if (activity.pace) {
      stats.push({
        label: compactOverlay ? "配速" : "平均配速",
        value: compactOverlay ? activity.pace + "/km" : activity.pace + " /km",
        compact: true,
      });
    }
    if (activity.finishTime || activity.duration) {
      stats.push({ label: "用时", value: activity.finishTime || activity.duration, compact: true });
    }
    var elevGain = route.elevationGain;
    if (elevGain != null) {
      stats.push({
        label: compactOverlay ? "爬升" : "累计爬升",
        value: compactOverlay ? Math.round(elevGain) + "m" : Math.round(elevGain) + " m",
        compact: true,
      });
    }

    if (!stats.length) return;

    var mapContainer = document.querySelector("#heroMap");
    var overlayContainer = document.querySelector(".hero") || mapContainer;
    if (!mapContainer || !overlayContainer) return;

    // Build stat value row
    var valuesHtml = stats.map(function (s) {
      var itemClass = s.compact === false ? " hero-stats-overlay__item--optional" : "";
      return '<div class="hero-stats-overlay__item' + itemClass + '"><span class="hero-stats-overlay__label">' + s.label + '</span><strong>' + s.value + '</strong>' + (s.sub ? '<small>' + s.sub + '</small>' : '') + '</div>';
    }).join("");

    var chartsHtml = "";
    var hasCharts = false;

    var timeSeries = null;
    try {
      await loadRouteDetail(routeId);
      if (requestId !== statsOverlayRequestId || activePanelTab === "stats" || routeId !== heroActiveRouteId) return;
      var detail = window.RUN_ROUTE_DETAIL[routeId];
      if (detail && detail.timeSeries && detail.timeSeries.elapsed && detail.timeSeries.elapsed.length >= 2) {
        timeSeries = detail.timeSeries;
      }
    } catch (e) {
      // Route detail not available, just show aggregate values
    }

    if (timeSeries) {
      try {
        await loadChartJs();
        if (requestId !== statsOverlayRequestId || activePanelTab === "stats" || routeId !== heroActiveRouteId) return;
        var labels = timeSeries.elapsed.map(formatElapsed);

        // Determine which charts to show
        var showPace = timeSeries.pace && timeSeries.pace.some(function (p) { return p != null; });
        var showElev = timeSeries.elevation && timeSeries.elevation.some(function (e) { return e != null; });
        var showHR = timeSeries.heartRate && timeSeries.heartRate.some(function (h) { return h != null; });

        if (showPace || showElev || showHR) {
          hasCharts = true;
          chartsHtml = '<div class="hero-stats-overlay__charts">';
          if (showPace) chartsHtml += '<div class="hero-stats-overlay__chart"><canvas id="chartPace"></canvas></div>';
          if (showElev) chartsHtml += '<div class="hero-stats-overlay__chart"><canvas id="chartElev"></canvas></div>';
          if (showHR) chartsHtml += '<div class="hero-stats-overlay__chart"><canvas id="chartHR"></canvas></div>';
          chartsHtml += '</div>';
        }
      } catch (e) {
        chartsHtml = "";
      }
    }

    var toggleHtml = hasCharts ? '<button class="hero-stats-overlay__toggle" id="statsToggle" type="button" title="折叠图表" aria-label="折叠图表" aria-expanded="true">⌄</button>' : '';
    var html = '<div class="hero-stats-overlay" id="heroStatsOverlay">' + toggleHtml + '<div class="hero-stats-overlay__values">' + valuesHtml + '</div>' + chartsHtml + '</div>';
    if (requestId !== statsOverlayRequestId || activePanelTab === "stats" || routeId !== heroActiveRouteId) return;
    overlayContainer.insertAdjacentHTML("beforeend", html);
    var insertedOverlay = document.querySelector("#heroStatsOverlay");
    var shouldCollapseCharts = hasCharts && window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
    if (insertedOverlay && shouldCollapseCharts) {
      insertedOverlay.classList.add("hero-stats-overlay--collapsed");
    }
    syncMobileStatsOverlayLayout();

    // Bind collapse toggle
    if (hasCharts) {
      var toggleBtn = document.querySelector("#statsToggle");
      if (toggleBtn) {
        if (shouldCollapseCharts) {
          toggleBtn.textContent = "⌃";
          toggleBtn.title = "展开图表";
          toggleBtn.setAttribute("aria-label", "展开图表");
          toggleBtn.setAttribute("aria-expanded", "false");
        }
        toggleBtn.onclick = function (e) {
          e.stopPropagation();
          var overlay = document.querySelector("#heroStatsOverlay");
          if (overlay) {
            overlay.classList.toggle("hero-stats-overlay--collapsed");
            var collapsed = overlay.classList.contains("hero-stats-overlay--collapsed");
            toggleBtn.textContent = collapsed ? "⌃" : "⌄";
            toggleBtn.title = collapsed ? "展开图表" : "折叠图表";
            toggleBtn.setAttribute("aria-label", collapsed ? "展开图表" : "折叠图表");
            toggleBtn.setAttribute("aria-expanded", collapsed ? "false" : "true");
          }
        };
      }
    }

    // Render charts after DOM insertion
    if (timeSeries && window.Chart) {
      try {
        if (requestId !== statsOverlayRequestId || activePanelTab === "stats" || routeId !== heroActiveRouteId) return;
        var colors = chartColors();
        var labels = timeSeries.elapsed.map(formatElapsed);

        var paceCanvas = document.querySelector("#chartPace");
        if (paceCanvas) {
          var paceCfg = makeSparkConfig(labels, timeSeries.pace, colors.line, colors.fill, "min/km", true);
          statsCharts.push(new window.Chart(paceCanvas, paceCfg));
        }

        var elevCanvas = document.querySelector("#chartElev");
        if (elevCanvas) {
          var elevCfg = makeSparkConfig(labels, timeSeries.elevation, colors.elevation, "rgba(255,158,74,0.08)", "m", false);
          statsCharts.push(new window.Chart(elevCanvas, elevCfg));
        }

        var hrCanvas = document.querySelector("#chartHR");
        if (hrCanvas) {
          var hrColor = "#ff5e3a";
          var hrCfg = makeSparkConfig(labels, timeSeries.heartRate, hrColor, "rgba(255,94,58,0.10)", "bpm", false);
          statsCharts.push(new window.Chart(hrCanvas, hrCfg));
        }
      } catch (e) {
        console.warn("Stats chart creation failed:", e);
      }
    }
  }

  // ---- Theme toggle ----
  function initTheme() {
    const saved = localStorage.getItem("theme") || "light";
    document.documentElement.dataset.theme = saved;
    updateThemeIcon(saved);
  }

  function updateThemeIcon(theme) {
    const icon = document.querySelector(".theme-toggle__icon");
    if (icon) icon.textContent = theme === "light" ? "☀️" : "🌙";
  }

  function switchMapTiles() {
    if (!heroMap) return;
    if (heroMapEngine === "amap") {
      heroMap.setMapStyle(amapStyles[document.documentElement.dataset.theme || "light"]);
      return;
    }
    if (!window.L) return;
    // Remove old tile layer and add new one matching theme
    heroMap.eachLayer((layer) => {
      if (layer instanceof window.L.TileLayer) {
        heroMap.removeLayer(layer);
      }
    });
    heroTileLayer = addResilientTileLayer(heroMap);
  }

  document.querySelector("#themeToggle")?.addEventListener("click", () => {
    const current = document.documentElement.dataset.theme === "light" ? "dark" : "light";
    document.documentElement.dataset.theme = current;
    localStorage.setItem("theme", current);
    updateThemeIcon(current);
    switchMapTiles();
    // Re-render panel to update SVG route preview colors
    renderPanelContent();
    // Refresh stats overlay chart colors
    if (activePanelTab === "stats") {
      clearStatsOverlay();
    } else if (heroActiveRouteId) {
      renderStatsOverlay(heroActiveRouteId);
    }
  });
  window.addEventListener("resize", () => {
    syncMobileStatsOverlayLayout();
    if (activePanelTab === "stats") alignBarReferenceLines(document);
  });

  initTheme();
  renderSummary();
  initPanelTabs();
  initPanelCollapse();
  initHeroMap();
  switchPanelTab("routes");
  initRouteLinks();
})();
