# CLAUDE.md

Guidance for coding assistants working in this repository.

## Overview

Running Archive is a personal marathon/running log. The current app is a Vite frontend with a FastAPI API and a local SQLite database. Apple Health data can arrive through the full export importer or the personal SwiftUI HealthKit sync app.

## Key Files

```text
index.html
src/
styles.css
server/
scripts/import-apple-health.sh
sync/apple-health-import.py
data.generated.js
route-index.generated.js
city-boundaries.generated.js
routes/*.js
assets/
src/share-lab.js
server/routers/apple_sync.py
ios/RunningArchiveSync/
```

## Routine Data Update

```bash
npm run import:apple -- /path/to/apple_health_export
```

The script backs up current generated data and `server/running.db`, imports Apple Health data, rebuilds SQLite, smoke-tests generated data/API responses, and runs `npm run build`. If anything fails, it restores the previous generated data and local DB.

## Local Development

```bash
npm run api
npm run dev
```

## Deployment

```bash
./server/deploy.sh user@server
```

The deploy script builds `dist/`, syncs frontend/server/generated data/routes to `/opt/running-archive`, backs up the remote DB, and runs migration on every deployment so the server uses the newest Apple Health data.

The Xcode project is committed to Git but is not uploaded to the web server. Open `ios/RunningArchiveSync/RunningArchiveSync.xcodeproj` locally. The remote API needs `RUNNING_SYNC_TOKEN` in `/etc/running-archive.env` before iPhone uploads are enabled.

## Hidden Share Lab

Seven avatar taps or `/#/share-lab-7k3m9x2p` opens the browser-only image generator. It supports compact and detailed PNG layouts and auto-renders when the activity, layout, theme, or title changes.

## Race Classification

`sync/apple-health-import.py` classifies races by distance and morning start time:

- 41-44km -> marathon
- 20-23km -> half marathon
- start hour must be `< 12`
- display names can be overridden in `RACE_NAME_OVERRIDES`

## Do Not Commit

- `dist/`
- `node_modules/`
- `server/running.db`
- `server/running.db.backup.*`
- `sync/backups/`
- `share-output/`
