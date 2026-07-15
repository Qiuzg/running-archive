# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Static running archive site — pure HTML/CSS/JS, zero build tools. Displays marathon/half-marathon races, training runs, route maps, and yearly statistics in a single-page UI with light/dark theme support.

## File architecture

```
index.html              # Single page: hero map + topbar nav + left panel
app.js                  # All logic: data, rendering, resilient maps and charts (IIFE)
styles.css              # All styles: CSS custom properties and responsive light/dark themes
data.generated.js       # Auto-generated compact data: profile, races[], runs[]
route-index.generated.js # Auto-generated compact preview coordinates for all routes
city-boundaries.generated.js # Auto-generated: GeoJSON boundaries for race cities
routes/*.js             # ~300 files, one per route, full GPS coordinates (loaded on demand)
sync/
  apple-health-import.py # Apple Health export → generate data + routes
  strava-sync.mjs        # Strava API → generate data + routes
assets/                  # Static images and vendored Chart.js
```

## Data flow

1. `data.generated.js` sets `window.RUN_ARCHIVE_DATA` (profile, races, runs)
2. `route-index.generated.js` sets `window.RUN_ROUTE_INDEX` (lightweight: preview coordinates only)
3. `city-boundaries.generated.js` sets `window.RUN_CITY_BOUNDARIES` (GeoJSON for city highlight areas)
4. `app.js` reads both globals, builds derived state, renders UI
5. Full GPS data for a route is lazy-loaded from `routes/<routeId>.js` via dynamic `<script>` injection

## Key globals (window namespace)

- `window.RUN_ARCHIVE_DATA` — `{ profile, races[], runs[] }`
- `window.RUN_ROUTE_INDEX` — `{ [routeId]: { id, name, distanceKm, previewCoordinates, ... } }`
- `window.RUN_CITY_BOUNDARIES` — GeoJSON boundaries for race cities
- `window.RUN_ROUTE_DETAIL` — populated on demand with full coordinates per route (includes timeSeries)

## app.js module structure

The entire app is a single IIFE. Key sections in order:

### Data layer (lines 1-60)
- Reads globals, filters evening "races" via `isMorningRace()` (extracts hour from `sourceRunId` format `apple-YYYYMMDD-HHMMSS`, keeps only `hour < 12`)
- Builds `races` (filtered + sorted), `activityItems` (races + non-race runs), `routeItems`
- Computes derived data: `availableYears`, PBs, yearly/monthly totals

### Utility functions (lines 62-240)
- `formatDate()`, `formatKm()`, `parseTimeToSeconds()`, `findPB()`, `getYearDistance()`, `getMonthlyTotals()`, `getMonthActivities()`
- `projectRoutePoints()` — Mercator projection for SVG route thumbnails
- `renderRouteSvg()` — generates inline SVG for route previews (theme-aware colors via `getSvgColors()`, supports `large` and `mini` variants)
- `escapeAttr()` — safe HTML attribute quoting
- `positionTooltip()` — positions floating tooltip relative to chart-block bounds

### Data loading
- `loadRouteDetail(routeId)` — injects `<script>` for `routes/<id>.js`, uses promise + caching
- `loadLeaflet()` — lazy-loads Leaflet CSS + JS with CDN fallbacks
- `loadChartJs()` — uses the vendored Chart.js first and retains CDN fallbacks

### State persistence
- Theme: `localStorage.theme` — `"light"` (default) | `"dark"`
- Panel collapsed: `localStorage.panelCollapsed` — `"true"` | `"false"`
- Panel height: `localStorage.panelHeight` — CSS max-height value (set by drag resize)

### Summary strip (lines 310-323)
- `renderSummary()` → `#summaryStrip` — 5 floating metrics over the map (total km, yearly km, marathon PB, half PB, race count)

### Panel tab system (lines 532-595)
- `activePanelTab` state: `"routes"` | `"races"` | `"stats"`
- `switchPanelTab(tab)` — updates nav active state, manages all-routes layer, city boundary visibility, map viewport
  - **Stats tab**: shows all routes as faint overlay on map, hides city boundaries, centers map on center point at zoom 12, hides collapse toggle
  - **Routes/races**: hides all-routes layer, restores city boundaries, restores default map bounds
- `initPanelTabs()` — binds click handlers on `[data-panel-tab]` links

### Panel collapse & resize (lines 596-690)
- `initPanelCollapse()` — injects toggle button into panel header, manages collapse/expand state
  - Collapsed routes: shows 3 items; collapsed races: shows 1 item
  - Toggle hidden on stats tab and mobile (≤760px)
- **Drag-to-resize**: handle at panel top, drag to adjust `max-height`, saved to localStorage
  - On mobile with route selected: stats overlay dynamically follows panel height during drag (to avoid overlap)
  - `resetPanelHeight()` — clears custom height, restores default

### Panel content renderers
- `renderPanelRoutes(container)` — scrollable route list with SVG thumbnails, four route filters, 80-item pagination, and filtered route overlay
- `renderPanelRaces(container)` — grouped race cards with route preview + stats, collapsed shows 1 race
- `renderPanelStats(container)` — year nav (left/right arrows), hero number (annual total), monthly bar chart with 100km reference lines + cursor-following tooltip, stat cards (races, monthly avg, longest), month detail chart
- `renderMonthRecords()` — daily activity bars for selected month, clickable to show route on map

### Route link handler (lines 1002-1027)
- `initRouteLinks()` — binds `.race-card[data-route-target]` and `[data-route-target]` buttons
  - Calls `resetPanelHeight()` to avoid overlap with stats overlay
  - Triggers `updateHeroRoute()` and stats overlay rendering

### Hero map
- `initHeroMap()` — creates a resilient Leaflet/AMap map with city highlight areas and saved default bounds
  - Mobile: `zoomControl: false`, `scrollWheelZoom: false`, `doubleClickZoom: true`, `tap: true`, `touchZoom: true`
  - Desktop: `zoomControl: true`, `scrollWheelZoom: true`
  - Tile URL switches between CartoDB light/dark based on theme
  - `updateWhenIdle` and `keepBuffer` tuned for mobile performance
- `updateHeroRoute(routeId, fit)` — swaps displayed polyline, optionally fits bounds, triggers stats overlay
- `showAllRoutesOnMap()` — draws the stats overview or the current filtered route set; race routes remain highlighted
- `hideAllRoutesFromMap()` — removes the all-routes feature group
- Map center point for stats tab: hardcoded `[32.00, 118.75]` at zoom 12
- `fitBounds` padding: `[80, 120]`

### Stats overlay
- `renderStatsOverlay(routeId)` — shows aggregate stats (heart rate, pace, duration, elevation) + sparkline charts
  - Desktop loads route detail timeSeries and renders Chart.js charts for pace, elevation, and heart rate
  - Mobile initially renders only the collapsed aggregate row and preloads route detail in the background
  - Mobile chart DOM is created only after the user explicitly expands the overlay, preventing first-click flashes
  - Light/dark theme-aware chart colors via `chartColors()`
- `clearStatsOverlay()` / `destroyStatsCharts()` — cleanup for tab switches and route changes

### Theme toggle (lines 1521-1568)
- `initTheme()` — reads localStorage, defaults to `"light"`
- `switchMapTiles()` — hot-swaps Leaflet tile layer between dark/light CartoDB
- Re-renders panel content on theme change to update SVG colors

### Initialization (last ~10 lines)
Order matters: `initTheme() → renderSummary() → initPanelTabs() → initPanelCollapse() → initHeroMap() → switchPanelTab("routes") → initRouteLinks()`

## CSS architecture

Organized in sections:
- **Design tokens** (`:root`): CSS custom properties for dark theme; `[data-theme="light"]` overrides
- **Chart colors**: Theme-independent bar/fill colors
- **Reset & Base**: box-sizing, body background with radial gradients + track-line texture
- **Animations**: `fadeInUp`, `pulseGlow` (PB badge), `breathe`, `shimmer`
- **Hero section**: `.hero` (100vh grid), `.hero__map` (absolute full-bleed), `.hero__map-shade` (gradient overlay, theme-aware)
- **Stats overlay**: `.hero-stats-overlay` — absolute bottom-right card with aggregate values + sparkline charts, collapsible on mobile, light/dark variants
- **Hero panel**: 380px fixed width, `backdrop-filter: blur(18px)`, flex column layout, `contain: layout style` for grid isolation
- **Panel header**: flex row with wrap, English eyebrow + Chinese title on same line (10px padding, compact)
- **Panel collapse toggle**: edge-attached pill button, hidden on mobile
- **Panel resize handle**: horizontal grab bar at panel top, cursor ns-resize
- **Route items**: 84px thumb + text, active state with orange accent
- **Race cards**: side-by-side media/body layout, responsive stacking, route preview with overlay stats
- **Bar charts**: 12-column CSS grid, `--bar-height` custom property, blue→orange gradient on hover, 100km reference lines (dashed), JS floating tooltip
- **Month detail chart**: flexbox with `overflow-x: auto`, daily activity bars
- **Stats year nav**: centered flex row with arrow buttons
- **Stats hero number**: large centered distance display
- **Stats meta row**: 3-column stat cards
- **Summary strip**: absolute positioned over map at `top: 76px; left: 380px`
- **Zoom controls**: hidden on mobile (≤760px) via `display: none`
- **Responsive**: 4 breakpoints (1120/900/760/460px), mobile-first patterns for panel, charts, and overlays

## Race classification rules

The sync script (`apple-health-import.py`) and frontend (`app.js`) both apply the same logic:
1. Distance: 41-44km → marathon, 20-23km → half marathon
2. **Time of day**: Only morning starts (hour < 12) count as races. Extracted from `sourceRunId` format `apple-YYYYMMDD-HHMMSS`. Evening runs of similar distance are treated as training.

## Adding new data

### From Apple Health export
```bash
python3 sync/apple-health-import.py /path/to/apple_health_export.zip
```
Generates `data.generated.js`, `route-index.generated.js`, `city-boundaries.generated.js`, and `routes/*.js`.

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
