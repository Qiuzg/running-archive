# AGENTS.md

Guidance for Codex when working in this repository.

## Overview

Running Archive is a personal marathon/running log. The current app is a Vite frontend with a FastAPI API and a local SQLite database. Apple Health exports are still converted into generated JS data files first, then migrated into `server/running.db`.

## Architecture

```text
index.html                  # Vite entry
src/                        # Frontend modules
  main.js                   # App bootstrap: data fetch, router, panel, map
  api.js                    # Fetch helpers for /api/*
  state.js                  # Shared client state and derived data
  map.js                    # Leaflet/Amap map runtime and route rendering
  share-lab.js              # Hidden compact/detailed PNG share generator
  render/                   # Summary, overlay, route/race/stats panels
  ui/                       # Router, theme, panel collapse/layout
styles.css                  # Global responsive styles and themes
server/                     # FastAPI API, SQLAlchemy models, migration, deploy
  routers/apple_sync.py     # Token-protected HealthKit incremental ingestion
scripts/import-apple-health.sh # Safe Apple Health import pipeline
sync/apple-health-import.py # Apple Health XML/GPX parser
data.generated.js           # Generated runs/races/profile data
route-index.generated.js    # Generated route preview index
city-boundaries.generated.js # Generated city GeoJSON
routes/*.js                 # Generated full route details and time series
assets/                     # Static assets
ios/RunningArchiveSync/     # Native SwiftUI archive/share/HealthKit sync app
```

## Data Flow

1. User exports Apple Health data as either an extracted `apple_health_export` directory or zip.
2. `scripts/import-apple-health.sh <path>` backs up generated data and `server/running.db`.
3. `sync/apple-health-import.py` updates `data.generated.js`, `route-index.generated.js`, and `routes/*.js`.
4. `server/migrate.py` rebuilds SQLite tables from the generated files.
5. The import script validates generated JS, route references, FastAPI responses, and `npm run build`.
6. The frontend fetches data from `/api/routes`, `/api/races`, `/api/runs`, `/api/stats/*`, and `/api/cities`.

Alternatively, the personal iPhone app uses HealthKit directly as the data source for its archive,
details, charts, and share images. It builds lightweight statistics from workout summaries, progressively
caches routes and detailed payloads in SwiftData, and does not require the web database for local use.
The optional sync tab posts selected HealthKit workouts to `/api/sync/apple-workouts` with
`RUNNING_SYNC_TOKEN`. The API trims the first and last 600 route meters and upserts the route/run.
`server/migrate.py` preserves these `healthkit` records across generated-data rebuilds.

## Common Commands

```bash
npm run import:apple -- /path/to/apple_health_export
npm run api
npm run dev
npm run build
./server/deploy.sh user@server
```

Use `npm run import:apple` for routine Apple Health updates. It restores the previous generated data and local DB automatically if any validation step fails.

## Deployment

`server/deploy.sh` builds the frontend, rsyncs `dist/`, `server/`, generated data, and `routes/` to `/opt/running-archive`, then backs up the remote SQLite database and runs `server/migrate.py` on every deployment.

The Xcode project is versioned in Git but is not uploaded by the web deployment. Open `ios/RunningArchiveSync/RunningArchiveSync.xcodeproj` locally and sign it with a Personal Team. Production HealthKit uploads require HTTPS and `/etc/running-archive.env` containing `RUNNING_SYNC_TOKEN`.

If no host argument is supplied, `server/deploy.sh` only performs a local build and prints local run instructions.

## Race Classification

`sync/apple-health-import.py` classifies races by:

1. Distance: 41-44km -> marathon, 20-23km -> half marathon
2. Time: only morning starts (`hour < 12`) count as races
3. Optional display names: `RACE_NAME_OVERRIDES`

## Notes

- Do not commit `dist/`, `node_modules/`, `server/running.db`, `sync/backups/`, or `share-output/`.
- Generated route files are large and numerous; use explicit git pathspecs when staging.
- The app still keeps generated JS data files as the portable source for migration and static fallback workflows.
- The hidden share lab is available through seven avatar taps or `/#/share-lab-7k3m9x2p`; route/layout/theme/title changes auto-render compact or detailed PNGs in the browser.
