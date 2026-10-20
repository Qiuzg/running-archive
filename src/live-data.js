import { store, rebuildDerivedData } from './state.js';
import { fetchRaces, fetchRoutes, fetchRuns, fetchCities, fetchDataVersion, clearRouteCache } from './api.js';
let version = null;
let pending = null;

// Publish a complete generation together; failures keep the last usable data.
export function refreshLiveData() {
  if (pending) return pending;
  pending = (async () => {
    if (store.dataLoading) return false;
    const next = await fetchDataVersion();
    if (!next || next === version) return false;
    const [races, routes, runs, cityBoundaries] = await Promise.all([fetchRaces(), fetchRoutes(), fetchRuns(), fetchCities()]);
    if (await fetchDataVersion() !== next) return false;
    Object.assign(store, { races, routes, runs, cityBoundaries, routeDetailCache: {} });
    for (const key of ['races', 'routes', 'runs', 'cityBoundaries']) store.dataStatus[key] = 'ready';
    clearRouteCache();
    rebuildDerivedData();
    version = next;
    return true;
  })().finally(() => { pending = null; });
  return pending;
}
