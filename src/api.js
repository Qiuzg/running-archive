const BASE = (import.meta.env?.VITE_BASE || "") + "/api";

async function request(path, { allowMissing = false, ...opts } = {}) {
  const url = `${BASE}${path}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const res = await fetch(url, { ...opts, signal: controller.signal });
    if (!res.ok) {
      if (allowMissing && res.status === 404) return null;
      throw new Error(`API ${res.status}: ${url}`);
    }
    return res.status === 204 ? null : await res.json();
  } finally { clearTimeout(timer); }
}
async function list(path) {
  const value = await request(path);
  if (!Array.isArray(value)) throw new Error(`Invalid list response: ${path}`);
  return value;
}

export function fetchRoutes(params = {}) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries({ preview_points: 0, ...params })) {
    for (const item of Array.isArray(value) ? value : [value]) query.append(key, item);
  }
  const qs = query.toString();
  return list(`/routes${qs ? "?" + qs : ""}`);
}

export function fetchRoutePreview(routeId) {
  return request(`/routes/${encodeURIComponent(routeId)}`, { allowMissing: true });
}

const routeRequests = new Map();
const routeDetails = new Map();
export function fetchRoute(routeId) {
  if (routeDetails.has(routeId)) return Promise.resolve(routeDetails.get(routeId));
  if (!routeRequests.has(routeId)) {
    const pending = request(`/routes/${encodeURIComponent(routeId)}`, { allowMissing: true })
      .then(detail => {
        if (detail) {
          routeDetails.set(routeId, detail);
          if (routeDetails.size > 8) routeDetails.delete(routeDetails.keys().next().value);
        }
        return detail;
      })
      .finally(() => routeRequests.delete(routeId));
    routeRequests.set(routeId, pending);
  }
  return routeRequests.get(routeId);
}

export function fetchRaces(params = {}) {
  const qs = new URLSearchParams(params).toString();
  return list(`/races${qs ? "?" + qs : ""}`);
}

export function fetchRuns(params = {}) {
  const qs = new URLSearchParams(params).toString();
  return list(`/runs${qs ? "?" + qs : ""}`);
}

export function fetchSummary(year) {
  return request(`/stats/summary${year ? "?year=" + year : ""}`);
}

export function fetchYearly(year) {
  return request(`/stats/yearly/${year}`);
}

export function fetchMonthly(year, month) {
  return request(`/stats/monthly/${year}/${month}`);
}

export function fetchYears() {
  return request("/stats/years");
}

export function fetchCities() {
  return list("/cities");
}

export async function fetchDataVersion() {
  const health = await request('/health', { cache: 'no-store' });
  return health.data_version || null;
}
export function clearRouteCache() { routeDetails.clear(); }
