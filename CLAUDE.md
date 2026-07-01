# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Static running archive site — pure HTML/CSS/JS, zero build tools. Displays marathon/half-marathon races, training runs, route maps, and yearly statistics in a single-page dark-themed UI.

## File architecture

```
index.html              # Single page: hero map + topbar nav + left panel
app.js                  # All logic: data, rendering, Leaflet maps (IIFE, ~870 lines)
styles.css              # All styles: CSS custom properties, dark theme (~1515 lines)
data.generated.js       # Auto-generated: profile, races[], runs[] (~4200 lines)
route-index.generated.js # Auto-generated: preview coordinates for all routes
routes/*.js             # ~300 files, one per route, full GPS coordinates (loaded on demand)
sync/
  apple-health-import.py # Apple Health export → generate data + routes
  strava-sync.mjs        # Strava API → generate data + routes
assets/                  # Static images (profile.png, etc.)
```

## Data flow

1. `data.generated.js` sets `window.RUN_ARCHIVE_DATA` (profile, races, runs)
2. `route-index.generated.js` sets `window.RUN_ROUTE_INDEX` (lightweight: preview coordinates only)
3. `app.js` reads both globals, builds derived state, renders UI
4. Full GPS data for a route is lazy-loaded from `routes/<routeId>.js` via dynamic `<script>` injection

## Key globals (window namespace)

- `window.RUN_ARCHIVE_DATA` — `{ profile, races[], runs[] }`
- `window.RUN_ROUTE_INDEX` — `{ [routeId]: { id, name, distanceKm, previewCoordinates, ... } }`
- `window.RUN_ROUTE_DETAIL` — populated on demand with full coordinates per route

## app.js module structure (~870 lines)

The entire app is a single IIFE. Key sections in order:

### Data layer (lines 1-58)
- Reads globals, filters evening "races" via `isMorningRace()` (extracts hour from `sourceRunId` format `apple-YYYYMMDD-HHMMSS`, keeps only `hour < 12`)
- Builds `races` (filtered + sorted), `activityItems` (races + non-race runs), `routeItems`
- Computes derived data: `availableYears`, PBs, yearly/monthly totals

### Utility functions (lines 60-145)
- `formatDate()`, `formatKm()`, `parseTimeToSeconds()`, `findPB()`, `getYearDistance()`, `getMonthlyTotals()`, `getMonthActivities()`
- `projectRoutePoints()` — Mercator projection for SVG route thumbnails
- `renderRouteSvg()` — generates inline SVG for route previews (dark theme, grid texture)
- `escapeAttr()` — safe HTML attribute quoting

### Data loading (lines 286-328)
- `loadRouteDetail(routeId)` — injects `<script>` for `routes/<id>.js`, uses promise + caching
- `loadLeaflet()` — lazy-loads Leaflet CSS + JS from unpkg CDN, promise with singleton

### Summary strip (lines 236-249)
- `renderSummary()` → `#summaryStrip` — 5 floating metrics (total km, yearly km, marathon PB, half PB, race count)

### Panel tab system (lines 454-506)
- `activePanelTab` state: `"routes"` | `"races"` | `"stats"`
- `switchPanelTab(tab)` — updates nav active state, toggles `.hero--stats-full` class (stats = full-width, map hidden), calls `renderPanelContent()`
- `initPanelTabs()` — binds click handlers on `[data-panel-tab]` links

### Panel content renderers (lines 508-666)
- `renderPanelRoutes(container)` — scrollable route list with SVG thumbnails, click highlights map
- `renderPanelRaces(container)` — grouped cards: 全马 / 半马 / 其他, each with route preview + stats
- `renderPanelStats(container)` — monthly bar chart + insight cards + month detail chart

### Route link handler (lines 736-746)
- `initRouteLinks()` — binds `[data-route-target]` buttons to `updateHeroRoute()` directly (no tab switch)

### Hero map (lines 748-862)
- `initHeroMap()` — creates Leaflet map, adds city markers for race cities, renders initial route, fits bounds
- `updateHeroRoute(routeId, fit)` — swaps the displayed polyline, optionally fits bounds
- Map tiles: CartoDB Dark Matter (dark theme, accessible in China)
- `fitBounds` padding: `[80, 120]`

### Initialization (lines 864-868)
Order matters: `renderSummary() → initPanelTabs() → initHeroMap() → switchPanelTab("routes") → initRouteLinks()`

## CSS architecture (~1515 lines)

Organized in sections:
- **Design tokens** (`:root`): CSS custom properties for colors, spacing, shadows, transitions
- **Reset & Base**: box-sizing, body background with radial gradients + track-line texture
- **Animations**: `fadeInUp`, `pulseGlow` (PB badge), `breathe`, `shimmer`
- **Hero section**: `.hero` (92vh grid), `.hero__map` (absolute full-bleed), `.hero__map-shade` (gradient overlay for legibility)
- **Stats full-width**: `.hero--stats-full` (hides map, panel 100% width centered)
- **Hero panel**: 380px fixed width, `backdrop-filter: blur(18px)`, scrollable body
- **Route items**: 84px thumb + text, active state with orange accent
- **Race cards**: side-by-side media/body layout, responsive stacking
- **Bar charts**: 12-column CSS grid, `--bar-height` custom property, blue→orange gradient on hover
- **Month detail chart**: flexbox with `overflow-x: auto`, tooltip via `::after` pseudo-element
- **Summary strip**: absolute positioned over map at `top: 76px; left: 380px`
- **Responsive**: 4 breakpoints (1120/900/760/460px)

## Race classification rules

The sync script (`apple-health-import.py`) and frontend (`app.js`) both apply the same logic:
1. Distance: 41-44km → marathon, 20-23km → half marathon
2. **Time of day**: Only morning starts (hour < 12) count as races. Extracted from `sourceRunId` format `apple-YYYYMMDD-HHMMSS`. Evening runs of similar distance are treated as training.

## Adding new data

### From Apple Health export
```bash
python3 sync/apple-health-import.py /path/to/apple_health_export.zip
```
Generates `data.generated.js`, `route-index.generated.js`, and `routes/*.js`.

### From Strava
Edit `sync/strava-sync.mjs` with API credentials, then run with Node.

## Deployment

- **GitHub Pages**: Push to `main` branch, served from root
- **GitLab Pages**: `.gitlab-ci.yml` copies files to `public/`, deployed on push to `main`

## Testing locally

```bash
python3 -m http.server 8080
# Open http://localhost:8080
```

No build step, no npm install needed. Just serve the directory.
