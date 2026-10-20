import { store, setActiveTab } from '../state.js';
import { updateHeroRoute } from '../map.js';
import { validDate } from '../analytics.js';
const SHARE_LAB_PATTERN = /^\/share-lab-7k3m9x2p\/?$/;
const pathNow = () => window.location.hash.replace(/^#/, '') || '/routes';
export function handleRoute() {
  const path = pathNow();
  if (SHARE_LAB_PATTERN.test(path)) return;
  const stats = path.match(/^\/stats(?:\/(\d{4})(?:\/(\d{1,2})(?:\/(\d{1,2}))?)?)?\/?$/);
  if (stats) {
    const year = Number(stats[1]) || store.selectedStatsYear || new Date().getFullYear();
    const month = stats[2] ? Number(stats[2]) : null;
    const day = stats[3] ? Number(stats[3]) : null;
    if (year < 1900 || (month !== null && (month < 1 || month > 12)) ||
      (day !== null && !validDate(`${year}-${String(month).padStart(2,'0')}-${String(day).padStart(2,'0')}`))) {
      navigate('/stats'); return;
    }
    store.selectedStatsYear = year;
    store.selectedStatsMonth = month === null ? null : month - 1;
    store.selectedStatsDay = day;
    setActiveTab('stats');
    return;
  }
  const route = path.match(/^\/route\/(.+)$/);
  if (route) {
    let id;
    try { id = decodeURIComponent(route[1]); } catch { navigate('/routes'); return; }
    if (store.activePanelTab !== 'routes') setActiveTab('routes');
    updateHeroRoute(id, true, 'route');
    return;
  }
  const tab = path.match(/^\/(routes|atlas|races)\/?$/);
  setActiveTab(tab ? tab[1] : 'routes');
}
export function navigate(path) {
  if (pathNow() !== path) window.location.hash = '#' + path;
}
export function syncUrlFromState() {
  if (SHARE_LAB_PATTERN.test(pathNow()) || pathNow().startsWith('/route/')) return;
  let path = `/${store.activePanelTab}`;
  if (store.activePanelTab === 'stats') {
    path += `/${store.selectedStatsYear || new Date().getFullYear()}`;
    if (store.selectedStatsMonth !== null) path += `/${store.selectedStatsMonth+1}`;
    if (store.selectedStatsDay !== null) path += `/${store.selectedStatsDay}`;
  }
  if (pathNow() !== path) window.history.replaceState(null, '', '#'+path);
}
export function initRouter() {
  window.addEventListener('hashchange', () => { handleRoute(); syncUrlFromState(); });
  // Resolve initial links after the first data request, so the correct default year is available.
}
