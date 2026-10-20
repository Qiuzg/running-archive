// Legacy imports may omit the city or assign a nearby city (e.g. 仁寿 → 成都).
// An explicit city in the race name takes precedence when its boundary is known.
const cityName = value => String(value || '').trim().replace(/市$/, '');

export function resolveRaceCity(race, boundaries) {
  const knownCities = boundaries.map(boundary => cityName(boundary.city)).filter(Boolean);
  const namedCity = knownCities.sort((a, b) => b.length - a.length)
    .find(city => String(race.name || '').includes(city));
  return namedCity || cityName(race.city);
}

export function raceCityAreas(races, routes, boundaries) {
  const areas = new Map();
  const routeMap = new Map(routes.map(route => [route.id, route]));
  for (const race of races) {
    if (!['marathon', 'half_marathon'].includes(race.type)) continue;
    const route = routeMap.get(race.route_id);
    if (!route) continue;
    const city = resolveRaceCity(race, boundaries);
    const boundary = boundaries.find(boundary => cityName(boundary.city) === city);
    if (!boundary && !route.preview_coordinates?.length) continue;
    const key = city || race.name;
    const area = areas.get(key) || {
      city, names: [], coordinates: [],
      boundary,
    };
    area.names.push(race.name);
    area.coordinates.push(...(route.preview_coordinates || []));
    areas.set(key, area);
  }
  return areas;
}
