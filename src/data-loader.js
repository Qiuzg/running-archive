import { store, rebuildDerivedData } from './state.js';
import { fetchRaces, fetchRoutes, fetchRuns, fetchCities } from './api.js';
const loaders = {races: fetchRaces, routes: fetchRoutes, runs: fetchRuns, cityBoundaries: fetchCities};
export async function loadData({ onProgress = () => {} } = {}) {
  store.dataLoading = true;
  const entries = Object.entries(loaders).filter(([key]) => store.dataStatus[key] !== 'ready');
  await Promise.all(entries.map(async ([key, load]) => {
    try {
      store[key] = await load();
      store.dataStatus[key] = 'ready';
    } catch (error) {
      store.dataStatus[key] = 'error';
      console.error(`Failed to load ${key}:`, error);
    }
    rebuildDerivedData();
    onProgress(key);
  }));
  store.dataLoading = false;
  rebuildDerivedData();
}
