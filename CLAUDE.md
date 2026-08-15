# CLAUDE.md

Guidance for coding assistants working in this repository.

## Overview

Running Archive is a personal marathon/running log. The current app is a Vite frontend with a FastAPI API and a local SQLite database. Apple Health exports are converted into generated JS data files, then migrated into `server/running.db`.

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
