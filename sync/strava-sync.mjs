import { mkdir, readdir, unlink, writeFile } from "node:fs/promises";

const token = process.env.STRAVA_ACCESS_TOKEN;
const limit = Number(process.env.STRAVA_ACTIVITY_LIMIT || 30);
const privacyTrimPoints = Number(process.env.ROUTE_PRIVACY_TRIM_POINTS || 8);
const privacyRadiusMeters = Number(process.env.ROUTE_PRIVACY_RADIUS_METERS || 600);

if (!token) {
  throw new Error("Missing STRAVA_ACCESS_TOKEN. Keep it in your shell environment, not in frontend files.");
}

async function strava(path) {
  const response = await fetch(`https://www.strava.com/api/v3${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!response.ok) {
    throw new Error(`Strava API failed: ${response.status} ${await response.text()}`);
  }

  return response.json();
}

function toTime(seconds = 0) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return [h, m, s].map((part) => String(part).padStart(2, "0")).join(":");
}

function toPace(seconds = 0, km = 1) {
  if (!seconds || !km) return "--";
  const pace = Math.round(seconds / km);
  const m = Math.floor(pace / 60);
  const s = pace % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function classifyRun(activity) {
  if (activity.type === "Race" || activity.workout_type === 1) return "race";
  if (activity.distance >= 25000) return "long";
  return "easy";
}

function trimRoute(latlng) {
  if (!Array.isArray(latlng) || latlng.length <= privacyTrimPoints * 2 + 2) return [];
  return latlng
    .slice(privacyTrimPoints, latlng.length - privacyTrimPoints)
    .map(([lat, lon]) => [Number(lon.toFixed(6)), Number(lat.toFixed(6))]);
}

function downsamplePoints(points, maxPoints) {
  if (!maxPoints || points.length <= maxPoints) return points;
  const step = (points.length - 1) / (maxPoints - 1);
  const sampled = Array.from({ length: maxPoints }, (_, index) => points[Math.round(index * step)]);
  sampled[0] = points[0];
  sampled[sampled.length - 1] = points[points.length - 1];
  return sampled;
}

const activities = await strava(`/athlete/activities?per_page=${limit}`);
const runs = [];
const routes = {};

for (const activity of activities.filter((item) => item.type === "Run")) {
  const km = Number((activity.distance / 1000).toFixed(2));
  const routeId = `strava-${activity.id}`;
  const streams = await strava(`/activities/${activity.id}/streams?keys=latlng&key_by_type=true`);
  const coordinates = trimRoute(streams.latlng?.data);
  const hasRoute = coordinates.length > 1;

  runs.push({
    id: String(activity.id),
    date: activity.start_date_local.slice(0, 10),
    title: activity.name,
    distanceKm: km,
    duration: toTime(activity.moving_time),
    pace: toPace(activity.moving_time, km),
    runType: classifyRun(activity),
    location: activity.location_city || "公开位置",
    routeId: hasRoute ? routeId : undefined,
    notes: "由 Strava 同步。",
  });

  if (hasRoute) {
    routes[routeId] = {
      id: routeId,
      name: `${activity.name}公开路线`,
      city: activity.location_city || "公开位置",
      distanceKm: km,
      privacy: "起终点附近已裁剪",
      hiddenStartEndMeters: privacyRadiusMeters,
      source: "strava",
      coordinates,
    };
  }
}

const dataOutput = `window.RUN_ARCHIVE_DATA = ${JSON.stringify(
  {
    profile: {
      runnerName: "跑者档案",
      currentYear: new Date().getFullYear(),
      syncPlan: {
        source: "Apple Watch",
        bridge: "Strava / HealthFit / RunGap",
        publicPrivacyRadiusMeters: privacyRadiusMeters,
      },
    },
    races: [],
    runs,
  },
)};\n`;

const routeIndex = {};
await mkdir(new URL("../routes/", import.meta.url), { recursive: true });
for (const file of await readdir(new URL("../routes/", import.meta.url))) {
  if (file.endsWith(".js")) {
    await unlink(new URL(`../routes/${file}`, import.meta.url));
  }
}

for (const [routeId, route] of Object.entries(routes)) {
  const { coordinates, ...metadata } = route;
  routeIndex[routeId] = {
    ...metadata,
    pointCount: coordinates.length,
    previewCoordinates: downsamplePoints(coordinates, 220),
    routeFile: `./routes/${routeId}.js`,
  };
  await writeFile(
    new URL(`../routes/${routeId}.js`, import.meta.url),
    `window.RUN_ROUTE_DETAIL = window.RUN_ROUTE_DETAIL || {};\nwindow.RUN_ROUTE_DETAIL[${JSON.stringify(routeId)}] = ${JSON.stringify(route)};\n`,
  );
}

const routeOutput = `window.RUN_ROUTE_INDEX=${JSON.stringify(routeIndex)};\n`;

await writeFile(new URL("../data.generated.js", import.meta.url), dataOutput);
await writeFile(new URL("../route-index.generated.js", import.meta.url), routeOutput);

console.log(`Synced ${runs.length} runs and ${Object.keys(routes).length} public routes.`);
