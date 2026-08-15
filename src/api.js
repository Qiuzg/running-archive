const BASE = (import.meta.env.VITE_BASE || "") + "/api";

async function request(path, opts = {}) {
  const url = `${BASE}${path}`;
  const res = await fetch(url, opts);
  if (!res.ok) {
    if (res.status === 404) return null;
    throw new Error(`API ${res.status}: ${url}`);
  }
  if (res.status === 204) return null;
  return res.json();
}

export function fetchRoutes(params = {}) {
  const qs = new URLSearchParams(params).toString();
  return request(`/routes${qs ? "?" + qs : ""}`);
}

export function fetchRoutePreview(routeId) {
  return request(`/routes/${encodeURIComponent(routeId)}`);
}

export function fetchRoute(routeId) {
  return request(`/routes/${encodeURIComponent(routeId)}`);
}

export function fetchRaces(params = {}) {
  const qs = new URLSearchParams(params).toString();
  return request(`/races${qs ? "?" + qs : ""}`);
}

export function fetchRuns(params = {}) {
  const qs = new URLSearchParams(params).toString();
  return request(`/runs${qs ? "?" + qs : ""}`);
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
  return request("/cities");
}
