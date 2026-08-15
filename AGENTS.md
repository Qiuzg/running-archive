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
  render/                   # Summary, overlay, route/race/stats panels
  ui/                       # Router, theme, panel collapse/layout
styles.css                  # Global responsive styles and themes
server/                     # FastAPI API, SQLAlchemy models, migration, deploy
scripts/import-apple-health.sh # Safe Apple Health import pipeline
sync/apple-health-import.py # Apple Health XML/GPX parser
data.generated.js           # Generated runs/races/profile data
route-index.generated.js    # Generated route preview index
city-boundaries.generated.js # Generated city GeoJSON
routes/*.js                 # Generated full route details and time series
assets/                     # Static assets
```

## Data Flow

1. User exports Apple Health data as either an extracted `apple_health_export` directory or zip.
2. `scripts/import-apple-health.sh <path>` backs up generated data and `server/running.db`.
3. `sync/apple-health-import.py` updates `data.generated.js`, `route-index.generated.js`, and `routes/*.js`.
4. `server/migrate.py` rebuilds SQLite tables from the generated files.
5. The import script validates generated JS, route references, FastAPI responses, and `npm run build`.
6. The frontend fetches data from `/api/routes`, `/api/races`, `/api/runs`, `/api/stats/*`, and `/api/cities`.

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
