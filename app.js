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
  const races = [...data.races].sort(byDateDesc);
  const marathonTimeline = races.filter((race) => race.type === "marathon");
  const runs = [...data.runs].sort(byDateDesc);
  const raceSourceRunIds = new Set(data.races.map((race) => race.sourceRunId).filter(Boolean));
  const activityItems = [
    ...data.races.map((item) => ({ ...item, source: "race" })),
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
  let selectedStatsYear = availableYears.includes(currentYear) ? currentYear : availableYears[0] || currentYear;
  let selectedStatsMonth = null;

  function getActivityForRoute(routeId) {
    return activityItems
      .filter((item) => item.routeId === routeId)
      .sort(byDateDesc)[0];
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
    const candidates = data.races.filter((race) => race.type === type);
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

  function renderRouteSvg(route, variant = "large") {
    if (!route) {
      return '<div class="route-empty">暂无路线</div>';
    }
    const projected = projectRoutePoints(route.coordinates);
    if (!projected.length) {
      return '<div class="route-empty">路线加载中</div>';
    }
    const points = projected.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");
    const startPoint = projected[0];
    const endPoint = projected[projected.length - 1];

    return `
      <svg class="route-svg route-svg--${variant}" viewBox="0 0 420 240" role="img" aria-label="${escapeAttr(route.name)}路线图">
        <defs>
          <linearGradient id="route-paper-${escapeAttr(route.id)}" x1="0" x2="1" y1="0" y2="1">
            <stop offset="0%" stop-color="#fbfaf5" />
            <stop offset="54%" stop-color="#eef4f4" />
            <stop offset="100%" stop-color="#f6efe8" />
          </linearGradient>
          <pattern id="route-grid-${escapeAttr(route.id)}" width="28" height="28" patternUnits="userSpaceOnUse">
            <path d="M 28 0 L 0 0 0 28" fill="none" stroke="rgba(24,32,42,0.065)" stroke-width="1" />
          </pattern>
        </defs>
        <rect width="420" height="240" rx="8" fill="url(#route-paper-${escapeAttr(route.id)})" />
        <rect width="420" height="240" rx="8" fill="url(#route-grid-${escapeAttr(route.id)})" opacity="0.75" />
        <path d="M-18 204 C68 150 150 204 235 148 S342 86 442 122" fill="none" stroke="#d6c7ae" stroke-width="2" stroke-dasharray="8 9" opacity="0.55" />
        <path d="M26 58 C110 112 178 46 250 88 S336 166 398 78" fill="none" stroke="#98b5b2" stroke-width="2" stroke-dasharray="4 7" opacity="0.5" />
        <path d="M16 28 H404 M16 212 H404 M22 22 V218 M398 22 V218" fill="none" stroke="rgba(24,32,42,0.12)" stroke-width="1" />
        <polyline points="${points}" fill="none" stroke="#172033" stroke-width="${variant === "mini" ? 10 : 12}" stroke-linecap="round" stroke-linejoin="round" opacity="0.12" />
        <polyline points="${points}" fill="none" stroke="#1d5fd1" stroke-width="${variant === "mini" ? 7 : 9}" stroke-linecap="round" stroke-linejoin="round" />
        <polyline points="${points}" fill="none" stroke="#13a086" stroke-width="${variant === "mini" ? 2.5 : 3.5}" stroke-linecap="round" stroke-linejoin="round" />
        <circle cx="${startPoint.x.toFixed(1)}" cy="${startPoint.y.toFixed(1)}" r="${variant === "mini" ? 6 : 8}" fill="#fbfaf5" stroke="#13a086" stroke-width="4" />
        <circle cx="${endPoint.x.toFixed(1)}" cy="${endPoint.y.toFixed(1)}" r="${variant === "mini" ? 6 : 8}" fill="#e14d3f" stroke="#fbfaf5" stroke-width="4" />
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

    document.querySelector("#summaryGrid").innerHTML = [
      createMetric("累计里程", formatKm(totalKm), "比赛与训练合计"),
      createMetric(`${currentYear} 年跑量`, formatKm(getYearDistance(currentYear)), "自动按日期归档"),
      createMetric("全马 PB", marathonPB ? marathonPB.finishTime : "--", marathonPB ? marathonPB.name : "等待第一场全马"),
      createMetric("半马 PB", halfPB ? halfPB.finishTime : "--", halfPB ? halfPB.name : "等待第一场半马"),
      createMetric("完赛场次", `${data.races.length} 场`, `${marathonTimeline.length} 场全马`),
    ].join("");
  }

  function renderTimeline() {
    const html = marathonTimeline
      .sort((a, b) => new Date(a.date) - new Date(b.date))
      .map(
        (race) => `
          <article class="timeline-item">
            <div class="timeline-item__marker" aria-hidden="true"></div>
            <div class="timeline-item__body">
              <div class="timeline-item__date"><span>${formatShortDate(race.date).year}</span>${formatShortDate(race.date).monthDay}</div>
              <div class="timeline-item__copy">
                <h3>${race.name}</h3>
                ${formatPlace(race) ? `<p>${formatPlace(race)}</p>` : ""}
              </div>
              <div class="race-result">
                <span>${race.finishTime}</span>
                <small>${race.pace} /km</small>
                ${race.isPB ? '<b class="badge">PB</b>' : ""}
                ${race.routeId ? `<button class="route-link" type="button" data-route-target="${escapeAttr(race.routeId)}">路线</button>` : ""}
              </div>
            </div>
          </article>
        `,
      )
      .join("");

    document.querySelector("#raceTimeline").innerHTML = html || '<p class="empty">还没有马拉松记录。</p>';
  }

  function renderRaceCards() {
    const html = races
      .map((race) => {
        const hasPhoto = race.photos && race.photos.length > 0;
        const media = hasPhoto
          ? `<img src="${race.photos[0]}" alt="${race.name} 记录照片" />`
          : race.routeId && routeIndex[race.routeId]
            ? renderRaceRoutePreview(race)
            : `<div class="race-card__fallback"><span>${raceTypes[race.type] || "RUN"}</span><strong>${formatKm(race.distanceKm)}</strong></div>`;
        const place = formatPlace(race);
        return `
          <article class="race-card">
            <div class="race-card__media">${media}</div>
            <div class="race-card__body">
              <div class="race-card__meta">
                <span>${raceTypes[race.type] || race.type}</span>
                <span>${formatDate(race.date)}</span>
              </div>
              <h3>${race.name}</h3>
              ${place || race.bibNumber ? `<p>${[place, race.bibNumber ? `号码 ${race.bibNumber}` : ""].filter(Boolean).join(" · ")}</p>` : ""}
              <div class="race-card__result">
                <strong>${race.finishTime}</strong>
                <span>${race.pace} /km</span>
                ${race.isPB ? '<b class="badge badge--small">PB</b>' : ""}
              </div>
              ${race.notes ? `<p class="race-card__notes">${race.notes}</p>` : ""}
              ${
                race.routeId
                  ? `<button class="text-action" type="button" data-route-target="${escapeAttr(race.routeId)}">查看公开路线</button>`
                  : ""
              }
            </div>
          </article>
        `;
      })
      .join("");

    document.querySelector("#raceCards").innerHTML = html || '<p class="empty">还没有比赛记录。</p>';
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
      script.src = `./routes/${routeId}.js?v=20260701-5`;
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

    if (!routeMap) {
      routeMap = window.L.map(mapEl, {
        attributionControl: true,
        scrollWheelZoom: false,
      });
      window.L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: "&copy; OpenStreetMap contributors",
      }).addTo(routeMap);
    } else {
      routeMap.removeLayer(routeLayer);
      routeMap.remove();
      routeMap = window.L.map(mapEl, {
        attributionControl: true,
        scrollWheelZoom: false,
      });
      window.L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: "&copy; OpenStreetMap contributors",
      }).addTo(routeMap);
    }

    routeLayer = window.L.polyline(latLngs, {
      color: "#2457d6",
      weight: 5,
      opacity: 0.92,
      lineJoin: "round",
      lineCap: "round",
    }).addTo(routeMap);
    window.L.circleMarker(latLngs[0], {
      radius: 6,
      color: "#207868",
      fillColor: "#ffffff",
      fillOpacity: 1,
      weight: 3,
    }).addTo(routeMap);
    window.L.circleMarker(latLngs[latLngs.length - 1], {
      radius: 6,
      color: "#ffffff",
      fillColor: "#d94b3d",
      fillOpacity: 1,
      weight: 3,
    }).addTo(routeMap);
    routeMap.fitBounds(routeLayer.getBounds(), { padding: [28, 28] });
    setTimeout(() => routeMap.invalidateSize(), 0);
  }

  async function renderRoutes(selectedId, requestedPage) {
    const selectedRoute = routeIndex[selectedId] || routeIndex[activeRouteId] || routeItems[0];
    const featured = document.querySelector("#featuredRoute");
    const list = document.querySelector("#routeList");
    const pager = document.querySelector("#routePager");
    const summary = document.querySelector("#routeListSummary");

    if (!selectedRoute) {
      featured.innerHTML = '<p class="empty">还没有路线数据。</p>';
      list.innerHTML = "";
      if (pager) pager.innerHTML = "";
      if (summary) summary.textContent = "";
      return;
    }

    activeRouteId = selectedRoute.id;
    const selectedIndex = Math.max(0, routeItems.findIndex((route) => route.id === activeRouteId));
    const totalPages = Math.max(1, Math.ceil(routeItems.length / routesPerPage));
    if (typeof requestedPage === "number") {
      routePage = Math.min(Math.max(requestedPage, 0), totalPages - 1);
    } else if (selectedId) {
      routePage = Math.floor(selectedIndex / routesPerPage);
    }
    const start = routePage * routesPerPage;
    const pageItems = routeItems.slice(start, start + routesPerPage);

    featured.innerHTML = renderRouteDetail(selectedRoute, { coordinates: selectedRoute.previewCoordinates || [] }, true);
    let selectedDetail = null;
    try {
      selectedDetail = await loadRouteDetail(selectedRoute.id);
      if (activeRouteId === selectedRoute.id) {
        featured.innerHTML = renderRouteDetail(selectedRoute, selectedDetail);
        const loadMapButton = document.querySelector("[data-load-online-map]");
        if (loadMapButton) {
          loadMapButton.addEventListener("click", async () => {
            loadMapButton.disabled = true;
            loadMapButton.textContent = "正在加载地图...";
            try {
              await loadLeaflet();
              renderLeafletRoute(selectedRoute, selectedDetail);
              loadMapButton.textContent = "地图已加载";
            } catch (error) {
              loadMapButton.textContent = "地图加载失败";
              loadMapButton.disabled = false;
            }
          });
        }
      }
    } catch (error) {
      featured.innerHTML = renderRouteDetail(selectedRoute, null);
    }
    list.innerHTML = pageItems
      .map((route) => {
        const activity = getActivityForRoute(route.id);
        return `
          <button class="route-list__item ${route.id === selectedRoute.id ? "is-active" : ""}" type="button" data-route-id="${escapeAttr(route.id)}">
            <span class="route-list__thumb">${renderRouteSvg(routeWithPreview(route), "mini")}</span>
            <span class="route-list__copy">
              <span>${route.city}</span>
              <strong>${route.name}</strong>
              <small>${activity ? formatDate(activity.date) : "示例路线"} · ${formatKm(route.distanceKm)}</small>
            </span>
          </button>
        `;
      })
      .join("");

    if (summary) {
      summary.textContent = `${start + 1}-${Math.min(start + routesPerPage, routeItems.length)} / ${routeItems.length}`;
    }
    if (pager) {
      pager.innerHTML = `
        <button type="button" data-route-page="${routePage - 1}" ${routePage === 0 ? "disabled" : ""}>上一页</button>
        <span>${routePage + 1} / ${totalPages}</span>
        <button type="button" data-route-page="${routePage + 1}" ${routePage >= totalPages - 1 ? "disabled" : ""}>下一页</button>
      `;
    }

    document.querySelectorAll("[data-route-id]").forEach((button) => {
      button.addEventListener("click", () => renderRoutes(button.dataset.routeId));
    });
    document.querySelectorAll("[data-route-page]").forEach((button) => {
      button.addEventListener("click", () => renderRoutes(activeRouteId, Number(button.dataset.routePage)));
    });
  }

  function renderStats() {
    const totals = getMonthlyTotals(selectedStatsYear);
    const max = Math.max(...totals, 1);
    const yearControls = document.querySelector("#chartYear");
    yearControls.innerHTML = `
      <label class="year-select">
        <span>年份</span>
        <select data-stats-year-select>
          ${availableYears
            .map((year) => `<option value="${year}" ${year === selectedStatsYear ? "selected" : ""}>${year}</option>`)
            .join("")}
        </select>
      </label>
    `;
    document.querySelector("#monthChart").innerHTML = totals
      .map((total, index) => {
        const height = Math.max((total / max) * 100, total > 0 ? 8 : 2);
        const isActive = selectedStatsMonth === index;
        const value = formatKm(total);
        return `
          <button
            class="bar ${isActive ? "is-active" : ""}"
            type="button"
            data-stats-month="${index}"
            data-tooltip="${index + 1} 月 · ${value}"
            title="${index + 1} 月：${value}"
            aria-label="${selectedStatsYear} 年 ${index + 1} 月跑量 ${value}"
            style="--bar-height: ${height}%"
          >
            <span>${total ? total.toFixed(0) : ""}</span>
            <i></i>
            <small>${index + 1}月</small>
          </button>
        `;
      })
      .join("");

    const yearRuns = data.runs.filter((run) => new Date(run.date).getFullYear() === selectedStatsYear);
    const yearRaces = data.races.filter((race) => new Date(race.date).getFullYear() === selectedStatsYear);
    const longestRun = [...yearRuns].sort((a, b) => b.distanceKm - a.distanceKm)[0];
    const bestMarathon = findPB("marathon");
    const bestMonthDistance = Math.max(...totals);
    const bestMonth = totals.indexOf(bestMonthDistance) + 1;
    const yearlyRaceCount = yearRaces.length;

    document.querySelector("#insightList").innerHTML = [
      `<article><span>最长训练</span><strong>${longestRun ? formatKm(longestRun.distanceKm) : "--"}</strong><p>${longestRun ? longestRun.title : "暂无训练记录"}</p></article>`,
      `<article><span>最佳全马</span><strong>${bestMarathon ? bestMarathon.finishTime : "--"}</strong><p>${bestMarathon ? [bestMarathon.name, bestMarathon.city].filter(Boolean).join(" · ") : "暂无全马记录"}</p></article>`,
      `<article><span>${selectedStatsYear} 最高月跑量</span><strong>${bestMonthDistance.toFixed(1)} km</strong><p>${bestMonth} 月</p></article>`,
      `<article><span>${selectedStatsYear} 比赛数</span><strong>${yearlyRaceCount} 场</strong><p>${formatKm(getYearDistance(selectedStatsYear))}</p></article>`,
    ].join("");

    renderMonthRecords();
    initRouteLinks();
    document.querySelectorAll("[data-stats-year-select]").forEach((select) => {
      select.addEventListener("change", () => {
        selectedStatsYear = Number(select.value);
        selectedStatsMonth = null;
        renderStats();
      });
    });
    document.querySelectorAll("[data-stats-month]").forEach((button) => {
      button.addEventListener("click", () => {
        const month = Number(button.dataset.statsMonth);
        selectedStatsMonth = selectedStatsMonth === month ? null : month;
        renderStats();
      });
    });
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
                    const detail = `${formatDate(item.date)} · ${formatKm(distance)} · ${item.pace} /km · ${item.finishTime || item.duration}`;
                    const content = `
                      <span class="month-activity-bar__value">${formatKm(distance)}</span>
                      <i style="--activity-height: ${height}%"></i>
                      <small>${day}</small>
                    `;
                    return item.routeId
                      ? `<button
                          class="month-activity-bar"
                          type="button"
                          data-route-target="${escapeAttr(item.routeId)}"
                          data-tooltip="${escapeAttr(`${title} · ${detail}`)}"
                          title="${escapeAttr(`${title} · ${detail}`)}"
                          aria-label="${escapeAttr(`${title}，${detail}，查看路线`)}"
                        >${content}</button>`
                      : `<div
                          class="month-activity-bar"
                          data-tooltip="${escapeAttr(`${title} · ${detail}`)}"
                          title="${escapeAttr(`${title} · ${detail}`)}"
                          aria-label="${escapeAttr(`${title}，${detail}`)}"
                        >${content}</div>`;
                  },
                )
                .join("")}</div>`
            : '<p class="empty empty--compact">这个月没有记录。</p>'
      }
    `;
  }

  function activateView(viewName) {
    document.body.classList.add("is-app-mode");
    document.querySelectorAll("[data-view-panel]").forEach((panel) => {
      const isActive = panel.dataset.viewPanel === viewName;
      panel.classList.toggle("is-active", isActive);
      panel.hidden = !isActive;
    });
    document.querySelectorAll("[data-view-target]").forEach((control) => {
      control.classList.toggle("is-active", control.dataset.viewTarget === viewName);
    });
    if (viewName === "routes") {
      setTimeout(() => {
        if (routeMap) routeMap.invalidateSize();
      }, 0);
    }
  }

  function initViewSwitcher() {
    document.querySelectorAll("[data-view-target]").forEach((control) => {
      control.addEventListener("click", (event) => {
        event.preventDefault();
        activateView(control.dataset.viewTarget);
      });
    });
  }

  function initRouteLinks() {
    document.querySelectorAll("[data-route-target]").forEach((button) => {
      button.onclick = () => {
        renderRoutes(button.dataset.routeTarget);
        activateView("routes");
      };
    });
  }

  renderSummary();
  renderTimeline();
  renderRaceCards();
  renderRoutes();
  renderStats();
  initViewSwitcher();
  initRouteLinks();
})();
