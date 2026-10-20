import { notify } from './state.js';
import { escapeAttr } from './utils.js';
const base = (import.meta.env?.VITE_BASE || '') + '/generated/';
let snapshot, pending, failed = false, checkedAt = 0;

export function ensureThumbnails({ retry = false } = {}) {
  if ((snapshot && Date.now() - checkedAt < 60000) || pending || (failed && !retry)) return pending;
  pending = fetch(base + 'thumbnails.json', { cache: 'no-cache', signal: AbortSignal.timeout(15000) })
    .then(async response => {
      if (!response.ok) throw new Error('Thumbnails unavailable');
      const data = await response.json();
      if (data.version !== 1 || !data.entries || Array.isArray(data.entries)) throw new Error('Invalid thumbnails');
      checkedAt = Date.now();
      snapshot = data;
      failed = false;
    }).catch(() => { failed = true; })
    .finally(() => { pending = null; notify('thumbnails'); });
  return pending;
}

export function thumbnailFailed() { return failed; }
export function renderThumbnail(route, index) {
  const file = snapshot?.entries[route.id];
  if (typeof file === 'string' && /^[a-f0-9]{64}\.svg$/.test(file)) {
    return `<img class="route-svg route-svg--mini" src="${base}thumbnails/${file}" alt="${escapeAttr(route.name)}路线图" width="180" height="140" loading="${index < 8 ? 'eager' : 'lazy'}" decoding="async">`;
  }
  const message = !snapshot ? (failed ? '暂未加载' : '加载中') : file === null ? '无轨迹' : '正在生成';
  return `<span class="route-empty">${message}</span>`;
}
