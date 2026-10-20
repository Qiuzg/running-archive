import { fetchRoutes } from './api.js';
import { store, notify } from './state.js';

const pending = new Map();
const queue = [];
let active = 0;
const BATCH_SIZE = 20;

function drain() {
  while (active < 2 && queue.length) {
    const batch = queue.splice(0, BATCH_SIZE);
    active++;
    fetchRoutes({ route_ids: batch.map(item => item.id), preview_points: 1200 })
      .then(rows => {
        const received = new Map(rows.map(row => [row.id, row]));
        for (const item of batch) {
          const route = store.routes.find(route => route.id === item.id);
          const row = received.get(item.id);
          if (!route) continue;
          if (!row) { route.preview_error = true; continue; }
          route.preview_coordinates = row.preview_coordinates || [];
          route.preview_loaded = true;
          route.preview_error = false;
        }
      })
      .catch(() => {
        for (const item of batch) {
          const route = store.routes.find(route => route.id === item.id);
          if (route) route.preview_error = true;
        }
      })
      .finally(() => {
        for (const item of batch) { pending.delete(item.id); item.resolve(); }
        active--;
        notify('previews');
        drain();
      });
  }
}

export function ensureRoutePreviews(ids, { retry = false } = {}) {
  const routes = new Map(store.routes.map(route => [route.id, route]));
  const promises = [];
  for (const id of new Set(ids)) {
    const route = routes.get(id);
    if (!route || route.preview_loaded || (route.preview_error && !retry)) continue;
    if (!pending.has(id)) {
      let resolve;
      const promise = new Promise(done => { resolve = done; });
      pending.set(id, promise);
      queue.push({ id, resolve });
    }
    promises.push(pending.get(id));
  }
  // Collect the current page before starting a bounded batch.
  drain();
  return Promise.all(promises);
}
