(function () {
  const data = window.RUN_ARCHIVE_DATA || { profile: {}, races: [], runs: [] };
  const routeIndex = window.RUN_ROUTE_INDEX || window.RUN_ROUTE_DATA || {};
  window.RUN_ROUTE_DETAIL = window.RUN_ROUTE_DETAIL || {};
  const currentYear = data.profile.currentYear || new Date().getFullYear();
  const raceTypes = {
    marathon: "全马",
    half_marathon: "半马",
    "10k": "10K",
    other: "其他",
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
  let activeRouteId = null;
  let routePage = 0;
  let routeMap = null;
  let routeLayer = null;
  let leafletPromise = null;
  let chartJsPromise = null;
  let statsCharts = [];      // active Chart.js instances
  let selectedStatsYear = availableYears.includes(currentYear) ? currentYear : availableYears[0] || currentYear;
  let selectedStatsMonth = null;

  function getActivityForRoute(routeId) {
    return activityItems
      .filter((item) => item.routeId === routeId)
      .sort(byDateDesc)[0];
  }

  // Sync .is-active UI state across race cards and route items
  function updateActiveRouteUI(routeId) {
    document.querySelectorAll(".race-card[data-route-target]").forEach((card) => {
      card.classList.toggle("is-active", card.dataset.routeTarget === routeId);
    });
    document.querySelectorAll("[data-hero-route]").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.heroRoute === routeId);
    });
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
    return new Intl.DateTimeFormat("zh-CN", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date(value));
  }

  function formatShortDate(value) {
    const date = new Date(value);
    return {
      year: date.getFullYear(),
      monthDay: new Intl.DateTimeFormat("zh-CN", {
        month: "2-digit",
        day: "2-digit",
      }).format(date),
    };
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
      bg1: light ? "#f0f2f5" : "#0d141d",
      bg2: light ? "#e8eaef" : "#111a24",
      bg3: light ? "#dde1e6" : "#0f1820",
      grid: light ? "rgba(0,0,0,0.05)" : "rgba(255,255,255,0.04)",
      decor1: light ? "rgba(0,0,0,0.06)" : "rgba(255,255,255,0.06)",
      decor2: light ? "rgba(0,0,0,0.04)" : "rgba(255,255,255,0.05)",
      decor3: light ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.08)",
      routeGlow: light ? "rgba(37,99,235,0.25)" : "rgba(59,139,255,0.3)",
      route: light ? "#2563eb" : "#3b8bff",
      routeAccent: light ? "#10b981" : "#2dd4a8",
      startFill: light ? "#f0f2f5" : "#0d141d",
      startStroke: light ? "#10b981" : "#2dd4a8",
      endFill: light ? "#e04a2a" : "#ff5e3a",
      endStroke: light ? "#f0f2f5" : "#0d141d",
    };
  }

  function renderRouteSvg(route, variant = "large") {
    if (!route) {
      return '<div class="route-empty">暂无路线</div>';
    }
    const projected = projectRoutePoints(route.coordinates);
    if (!projected.length) {
      return '<div class="route-empty">路线加载中</div>';
    }
    const c = getSvgColors();
    const points = projected.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");
    const startPoint = projected[0];
    const endPoint = projected[projected.length - 1];

    return `
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
        <rect width="420" height="240" rx="8" fill="url(#route-paper-${escapeAttr(route.id)})" />
        <rect width="420" height="240" rx="8" fill="url(#route-grid-${escapeAttr(route.id)})" opacity="0.75" />
        <path d="M-18 204 C68 150 150 204 235 148 S342 86 442 122" fill="none" stroke="${c.decor1}" stroke-width="2" stroke-dasharray="8 9" opacity="0.5" />
        <path d="M26 58 C110 112 178 46 250 88 S336 166 398 78" fill="none" stroke="${c.decor2}" stroke-width="2" stroke-dasharray="4 7" opacity="0.4" />
        <path d="M16 28 H404 M16 212 H404 M22 22 V218 M398 22 V218" fill="none" stroke="${c.decor3}" stroke-width="1" />
        <polyline points="${points}" fill="none" stroke="${c.routeGlow}" stroke-width="${variant === "mini" ? 5 : 6}" stroke-linecap="round" stroke-linejoin="round" opacity="0.6" />
        <polyline points="${points}" fill="none" stroke="${c.route}" stroke-width="${variant === "mini" ? 3 : 4}" stroke-linecap="round" stroke-linejoin="round" />
        <polyline points="${points}" fill="none" stroke="${c.routeAccent}" stroke-width="${variant === "mini" ? 1.5 : 2}" stroke-linecap="round" stroke-linejoin="round" />
        <circle cx="${startPoint.x.toFixed(1)}" cy="${startPoint.y.toFixed(1)}" r="${variant === "mini" ? 6 : 8}" fill="${c.startFill}" stroke="${c.startStroke}" stroke-width="4" />
        <circle cx="${endPoint.x.toFixed(1)}" cy="${endPoint.y.toFixed(1)}" r="${variant === "mini" ? 6 : 8}" fill="${c.endFill}" stroke="${c.endStroke}" stroke-width="4" />
      </svg>
    `;
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
        <div class="race-route-preview__stats">
          <span>${formatKm(race.distanceKm)}</span>
          <strong>${race.finishTime}</strong>
          <small>${race.pace} /km</small>
        </div>
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

  function loadLeaflet() {
    if (window.L) return Promise.resolve(window.L);
    if (leafletPromise) return leafletPromise;
    leafletPromise = new Promise((resolve, reject) => {
      const link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css";
      document.head.appendChild(link);
      const script = document.createElement("script");
      script.src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js";
      script.onload = () => resolve(window.L);
      script.onerror = () => reject(new Error("Leaflet load failed"));
      document.body.appendChild(script);
    });
    return leafletPromise;
  }

  function loadChartJs() {
    if (window.Chart) return Promise.resolve(window.Chart);
    if (chartJsPromise) return chartJsPromise;
    chartJsPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "https://unpkg.com/chart.js@4.4.0/dist/chart.umd.js";
      script.onload = () => resolve(window.Chart);
      script.onerror = () => reject(new Error("Chart.js load failed"));
      document.body.appendChild(script);
    });
    return chartJsPromise;
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
        ${
          selectedStatsMonth === null
            ? ""
            : `<small>${records.length} 次 · ${formatKm(monthTotal)}${longest ? ` · 最长 ${formatKm(longest.distanceKm)}` : ""}</small>`
        }
      </div>
      ${
        selectedStatsMonth === null
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
    document.querySelectorAll("[data-panel-tab]").forEach((link) => {
      link.classList.toggle("is-active", link.dataset.panelTab === tab);
    });
    document.querySelector("#panelEyebrow").textContent =
      tab === "routes" ? "Route Atlas" : tab === "races" ? "Race Records" : "";
    document.querySelector("#panelTitle").textContent =
      tab === "routes" ? "路线足迹" : tab === "races" ? "比赛记录" : "";
    // Stats tab: full-width, hide map, hide panel header
    const heroEl = document.querySelector(".hero");
    const mapContainer = document.querySelector("#heroMap");
    const summaryStrip = document.querySelector("#summaryStrip");
    const panelHeader = document.querySelector(".hero__panel-header");
    if (tab === "stats") {
      heroEl.classList.add("hero--stats-full");
      if (mapContainer) mapContainer.style.display = "none";
      if (summaryStrip) summaryStrip.style.display = "none";
      if (panelHeader) panelHeader.style.display = "none";
    } else {
      heroEl.classList.remove("hero--stats-full");
      if (mapContainer) mapContainer.style.display = "";
      if (summaryStrip) summaryStrip.style.display = "";
      if (panelHeader) panelHeader.style.display = "";
      setTimeout(() => { if (heroMap) heroMap.invalidateSize(); }, 100);
    }
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

  function renderPanelRoutes(container) {
    const routeEntries = [...activityItems]
      .filter((item) => item.routeId && routeIndex[item.routeId])
      .sort(byDateDesc);
    if (!routeEntries.length) {
      container.innerHTML = '<p class="empty">暂无路线数据</p>';
      return;
    }
    container.innerHTML = routeEntries
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
    container.querySelectorAll("[data-hero-route]").forEach((btn) => {
      btn.addEventListener("click", () => {
        if (btn.dataset.heroRoute === heroActiveRouteId) return;
        heroActiveRouteId = btn.dataset.heroRoute;
        updateHeroRoute(heroActiveRouteId, true);
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
            <div class="race-route-preview__stats">
              <span>${formatKm(race.distanceKm)}</span>
              <strong>${race.finishTime}</strong>
              <small>${race.pace} /km</small>
            </div>
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
              <strong>${race.finishTime}</strong><span>${race.pace} /km</span>
            </div>
            ${race.notes ? `<p class="race-card__notes">${race.notes}</p>` : ""}
          </div>
        </article>
      `;
    }

    const sections = [];
    if (marathonRaces.length) {
      sections.push(`<div class="panel-section-header"><h3>全马 · ${marathonRaces.length} 场</h3></div>`);
      sections.push(`<div class="record-grid">${marathonRaces.map(renderGroupCard).join("")}</div>`);
    }
    if (halfRaces.length) {
      sections.push(`<div class="panel-section-header"><h3>半马 · ${halfRaces.length} 场</h3></div>`);
      sections.push(`<div class="record-grid">${halfRaces.map(renderGroupCard).join("")}</div>`);
    }
    if (otherRaces.length) {
      sections.push(`<div class="panel-section-header"><h3>其他比赛 · ${otherRaces.length} 场</h3></div>`);
      sections.push(`<div class="record-grid">${otherRaces.map(renderGroupCard).join("")}</div>`);
    }
    if (!sections.length) {
      sections.push('<p class="empty">还没有比赛记录。</p>');
    }

    container.innerHTML = sections.join("");
    initRouteLinks();
  }

  function renderPanelStats(container) {
    const year = selectedStatsYear;
    const totals = getMonthlyTotals(year);
    const max = Math.max(...totals, 1);
    const yearOptions = availableYears
      .map((y) => `<option value="${y}" ${y === year ? "selected" : ""}>${y}</option>`)
      .join("");
    const bars = totals
      .map((t, i) => {
        const h = Math.max((t / max) * 100, t > 0 ? 8 : 2);
        return `<button class="bar ${selectedStatsMonth === i ? "is-active" : ""}" type="button"
          data-stats-month="${i}" data-tooltip="${i + 1}月 · ${formatKm(t)}"
          aria-label="${year}年${i + 1}月跑量${formatKm(t)}" style="--bar-height: ${h}%">
          <span>${t ? t.toFixed(0) : ""}</span><i></i><small>${i + 1}月</small></button>`;
      })
      .join("");

    const yearRaces = races.filter((r) => new Date(r.date).getFullYear() === year);
    const yearMarathonCount = yearRaces.filter((r) => r.type === "marathon").length;
    const yearHalfCount = yearRaces.filter((r) => r.type === "half_marathon").length;
    const bestMonthDist = Math.max(...totals);
    const bestMonth = totals.indexOf(bestMonthDist) + 1;

    container.innerHTML = `
      <div class="stats-kpi-row">
        <div class="stats-kpi">
          <span>最高月跑量</span>
          <strong>${bestMonthDist.toFixed(1)} km</strong>
          <small>${bestMonth} 月</small>
        </div>
        <div class="stats-kpi">
          <span>比赛</span>
          <strong>${yearRaces.length} 场</strong>
          <small>全马 ${yearMarathonCount} · 半马 ${yearHalfCount}</small>
        </div>
      </div>
      <div class="chart-block">
        <div class="chart-block__header">
          <h3>${year} 月度跑量</h3>
          <div class="chart-block__header-right">
            <span class="year-total-inline">年度总跑量 <strong>${formatKm(getYearDistance(year))}</strong></span>
            <label class="year-select"><select data-stats-year-select>${yearOptions}</select></label>
          </div>
        </div>
        <div class="bar-chart">${bars}</div>
      </div>
      <div class="month-records" id="monthRecords"></div>
    `;

    document.querySelector("[data-stats-year-select]")?.addEventListener("change", (e) => {
      selectedStatsYear = Number(e.target.value);
      selectedStatsMonth = null;
      renderPanelStats(container);
    });
    container.querySelectorAll("[data-stats-month]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const m = Number(btn.dataset.statsMonth);
        selectedStatsMonth = selectedStatsMonth === m ? null : m;
        renderPanelStats(container);
      });
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
              <div class="race-route-preview__stats">
                <span>${formatKm(race.distanceKm)}</span>
                <strong>${race.finishTime}</strong>
                <small>${race.pace} /km</small>
              </div>
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
                <strong>${race.finishTime}</strong><span>${race.pace} /km</span>
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
        updateHeroRoute(routeId, true);
        updateActiveRouteUI(routeId);
      };
    });

    // Other route-target buttons (month bars, timeline links, etc.)
    document.querySelectorAll("[data-route-target]:not(.race-card)").forEach((el) => {
      el.onclick = () => {
        const routeId = el.dataset.routeTarget;
        if (routeId === heroActiveRouteId) return;
        heroActiveRouteId = routeId;
        updateHeroRoute(routeId, true);
        updateActiveRouteUI(routeId);
      };
    });
  }

  // Hero map state (shared with panel render functions)
  let heroMap = null;
  let heroRouteLine = null;
  let heroActiveRouteId = null;

  function initHeroMap() {
    const heroMapEl = document.querySelector("#heroMap");
    if (!heroMapEl) return;

    // Set initial active route
    const firstWithRoute = [...activityItems]
      .filter((item) => item.routeId && routeIndex[item.routeId])
      .sort(byDateDesc)[0];
    if (firstWithRoute) {
      heroActiveRouteId = firstWithRoute.routeId;
    }

    // City markers for marathon/half-marathon races
    const cityMarkers = [];
    const seenCities = new Set();
    for (const race of races) {
      if (race.type !== "marathon" && race.type !== "half_marathon") continue;
      const route = routeIndex[race.routeId];
      if (!route || !route.previewCoordinates || !route.previewCoordinates.length) continue;
      const cityKey = race.city || race.name;
      if (seenCities.has(cityKey)) continue;
      seenCities.add(cityKey);
      const coords = route.previewCoordinates;
      const mid = coords[Math.floor(coords.length / 2)];
      cityMarkers.push({
        city: race.city || race.name,
        name: race.name,
        latlng: [mid[1], mid[0]],
        routeId: race.routeId,
      });
    }

    let heroTileLayer = null;

    function getTileUrl() {
      const theme = document.documentElement.dataset.theme || "dark";
      return theme === "light"
        ? "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
        : "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png";
    }

    function renderHeroMap() {
      if (!window.L) return;
      heroMap = window.L.map(heroMapEl, {
        attributionControl: false,
        zoomControl: true,
        scrollWheelZoom: true,
      });
      heroTileLayer = window.L.tileLayer(getTileUrl(), {
        maxZoom: 19,
        subdomains: "abcd",
      }).addTo(heroMap);

      // City markers
      const allBounds = [];
      for (const marker of cityMarkers) {
        window.L.circleMarker(marker.latlng, {
          radius: 6,
          color: "#ff5e3a",
          fillColor: "#ff5e3a",
          fillOpacity: 0.8,
          weight: 2,
        })
          .bindTooltip(`${marker.city}<br><small>${marker.name}</small>`, { direction: "top" })
          .addTo(heroMap);
        allBounds.push(marker.latlng);
      }

      // Show the active route and collect its bounds
      const route = routeIndex[heroActiveRouteId];
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
        allBounds.push(...latlngs);
      }

      if (allBounds.length) {
        heroMap.fitBounds(allBounds, { padding: [80, 120] });
      }

      const observer = new MutationObserver(() => {
        setTimeout(() => heroMap.invalidateSize(), 350);
      });
      observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });
    }

    loadLeaflet().then(renderHeroMap).catch(() => {});
  }

  // Expose updateHeroRoute at module level for panel functions
  function updateHeroRoute(routeId, fit) {
    if (!heroMap || !window.L) return;
    if (heroRouteLine) {
      heroMap.removeLayer(heroRouteLine);
      heroRouteLine = null;
    }
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
    var validData = data.filter(function(v) { return v != null; });
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
            ticks: { color: colors.text, font: { size: 9 }, maxTicksLimit: 3, callback: function(v) { return v; } },
            grid: { color: colors.grid, drawTicks: false },
            title: { display: !!yLabel, text: yLabel || "", color: colors.text, font: { size: 10, weight: "bold" } },
          },
        },
      },
    };
    return cfg;
  }

  async function renderStatsOverlay(routeId) {
    // Destroy previous
    var existing = document.querySelector("#heroStatsOverlay");
    if (existing) existing.remove();
    destroyStatsCharts();

    var route = routeIndex[routeId];
    if (!route) return;

    var activity = getActivityForRoute(routeId);
    if (!activity) return;

    var stats = [];
    if (activity.avgHeartRate) {
      stats.push({ label: "平均心率", value: activity.avgHeartRate + " bpm", sub: activity.maxHeartRate ? "最高 " + activity.maxHeartRate : "" });
    }
    if (activity.avgPower) {
      stats.push({ label: "平均功率", value: activity.avgPower + " W" });
    }
    if (activity.pace) {
      stats.push({ label: "平均配速", value: activity.pace + " /km" });
    }
    if (activity.finishTime || activity.duration) {
      stats.push({ label: "用时", value: activity.finishTime || activity.duration });
    }
    var elevGain = route.elevationGain;
    if (elevGain != null) {
      stats.push({ label: "累计爬升", value: Math.round(elevGain) + " m" });
    }

    if (!stats.length) return;

    var mapContainer = document.querySelector("#heroMap");
    if (!mapContainer) return;

    // Build stat value row
    var valuesHtml = stats.map(function (s) {
      return '<div class="hero-stats-overlay__item"><span class="hero-stats-overlay__label">' + s.label + '</span><strong>' + s.value + '</strong>' + (s.sub ? '<small>' + s.sub + '</small>' : '') + '</div>';
    }).join("");

    var chartsHtml = "";
    var hasCharts = false;

    // Try to get timeSeries from route detail
    var timeSeries = null;
    try {
      await loadRouteDetail(routeId);
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
        var labels = timeSeries.elapsed.map(formatElapsed);

        // Determine which charts to show
        var showPace = timeSeries.pace && timeSeries.pace.some(function(p) { return p != null; });
        var showElev = timeSeries.elevation && timeSeries.elevation.some(function(e) { return e != null; });
        var showHR = timeSeries.heartRate && timeSeries.heartRate.some(function(h) { return h != null; });

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

    var toggleHtml = hasCharts ? '<button class="hero-stats-overlay__toggle" id="statsToggle" type="button" title="折叠图表" aria-label="折叠图表">▼</button>' : '';
    var html = '<div class="hero-stats-overlay" id="heroStatsOverlay"><div class="hero-stats-overlay__values">' + valuesHtml + toggleHtml + '</div>' + chartsHtml + '</div>';
    mapContainer.insertAdjacentHTML("beforeend", html);

    // Bind collapse toggle
    if (hasCharts) {
      var toggleBtn = document.querySelector("#statsToggle");
      if (toggleBtn) {
        toggleBtn.onclick = function(e) {
          e.stopPropagation();
          var overlay = document.querySelector("#heroStatsOverlay");
          if (overlay) {
            overlay.classList.toggle("hero-stats-overlay--collapsed");
            toggleBtn.textContent = overlay.classList.contains("hero-stats-overlay--collapsed") ? "▶" : "▼";
          }
        };
      }
    }

    // Render charts after DOM insertion
    if (timeSeries && window.Chart) {
      try {
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
    const saved = localStorage.getItem("theme") || "dark";
    document.documentElement.dataset.theme = saved;
    updateThemeIcon(saved);
  }

  function updateThemeIcon(theme) {
    const icon = document.querySelector(".theme-toggle__icon");
    if (icon) icon.textContent = theme === "light" ? "☀️" : "🌙";
  }

  function switchMapTiles() {
    if (!heroMap || !window.L) return;
    // Remove old tile layer and add new one matching theme
    heroMap.eachLayer((layer) => {
      if (layer instanceof window.L.TileLayer) {
        heroMap.removeLayer(layer);
      }
    });
    const url = document.documentElement.dataset.theme === "light"
      ? "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
      : "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png";
    window.L.tileLayer(url, { maxZoom: 19, subdomains: "abcd" }).addTo(heroMap);
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
    if (heroActiveRouteId) renderStatsOverlay(heroActiveRouteId);
  });

  initTheme();
  renderSummary();
  initPanelTabs();
  initHeroMap();
  switchPanelTab("routes");
  initRouteLinks();
})();
