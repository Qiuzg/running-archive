// Calendar dates stay in local time; parsing ISO strings as UTC shifts some days.
export function dateKey(date = new Date()) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}
export function validDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value || '')) return false;
  const [y, m, d] = value.split('-').map(Number);
  return dateKey(new Date(y, m - 1, d)) === value;
}
export function distance(item) { return Math.max(0, Number(item.distance_km) || 0); }
export function durationSeconds(value) {
  if (!/^(\d+:)?\d{1,2}:\d{2}$/.test(value || '')) return null;
  const parts = value.split(':').map(Number);
  if (parts.at(-1) >= 60 || (parts.length === 3 && parts[1] >= 60)) return null;
  const seconds = parts.reduce((total, part) => total * 60 + part, 0);
  return seconds > 0 ? seconds : null;
}
export function recordedActivities(items, today = dateKey()) {
  return items.filter(item => validDate(item.date) && item.date <= today);
}
export function totals(items) {
  return { km: items.reduce((sum, item) => sum + distance(item), 0), count: items.length,
    days: new Set(items.map(item => item.date)).size,
    longest: items.reduce((best, item) => Math.max(best, distance(item)), 0) };
}
export function yearReview(items, year, today = dateKey()) {
  const currentYear = Number(today.slice(0, 4));
  const end = year === currentYear ? today : `${year}-12-31`;
  const month = Number(end.slice(5, 7));
  const day = Math.min(Number(end.slice(8)), new Date(year - 1, month, 0).getDate());
  const previousEnd = `${year - 1}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
  const eligible = recordedActivities(items, today);
  const current = eligible.filter(item => item.date.startsWith(`${year}-`) && item.date <= end);
  const previous = eligible.filter(item => item.date.startsWith(`${year - 1}-`) && item.date <= previousEnd);
  const summary = totals(current), baseline = totals(previous);
  return { current, previous, summary, baseline, end, previousEnd,
    change: baseline.km > 0 && year <= currentYear ? (summary.km - baseline.km) / baseline.km * 100 : null,
    monthly: Array.from({length: 12}, (_, month) => totals(current.filter(i => Number(i.date.slice(5, 7)) === month + 1)).km),
    previousMonthly: Array.from({length: 12}, (_, month) => totals(previous.filter(i => Number(i.date.slice(5, 7)) === month + 1)).km) };
}
export function monthCalendar(items, year, month) {
  const prefix = `${year}-${String(month + 1).padStart(2, '0')}-`;
  const records = items.filter(i => i.date.startsWith(prefix));
  return { records, offset: (new Date(year, month, 1).getDay() + 6) % 7,
    days: Array.from({length: new Date(year, month + 1, 0).getDate()}, (_, index) => {
      const date = `${prefix}${String(index + 1).padStart(2, '0')}`;
      const activities = records.filter(i => i.date === date);
      return { date, activities, ...totals(activities) };
    }) };
}
export const PB_DISTANCES = [
  {label: '5 km', km: 5}, {label: '10 km', km: 10},
  {label: '半程马拉松', km: 21.0975}, {label: '全程马拉松', km: 42.195},
];
export function pbHistory(items, km, today = dateKey()) {
  let best = Infinity;
  return recordedActivities(items, today).filter(item => distance(item) >= km && distance(item) <= km * 1.03)
    .map(item => ({...item, seconds: durationSeconds(item.finish_time || item.duration)}))
    .filter(item => item.seconds !== null).sort((a, b) => a.date.localeCompare(b.date) || a.seconds - b.seconds)
    .flatMap(item => {
      if (item.seconds >= best) return [];
      const improvement = Number.isFinite(best) ? best - item.seconds : null;
      best = item.seconds;
      return [{...item, improvement}];
    });
}
export function routeCity(item, route) { return String(item.city || route?.city || '').trim(); }
export function filterRoutes(items, routes, filters) {
  const lookup = new Map(routes.map(route => [route.id, route]));
  return items.filter(item => {
    const route = lookup.get(item.route_id);
    if (!route) return false;
    const bucket = item.source === 'race' ? 'race' : distance(route) >= 16 ? 'long' : 'middle';
    return !filters.kind || filters.kind === 'all' || filters.kind === bucket;
  });
}
export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
}
