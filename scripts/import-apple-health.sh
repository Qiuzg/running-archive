#!/usr/bin/env bash
# Import a fresh Apple Health export and verify the site before it can be deployed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/import-apple-health.sh /path/to/apple_health_export
  scripts/import-apple-health.sh /path/to/apple_health_export.zip

The script updates generated data, rebuilds the SQLite database, runs smoke
checks, and builds the Vite frontend. If any step fails, generated data and the
local database are restored from a timestamped backup.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

EXPORT_PATH="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_ROOT="$PROJECT_DIR/sync/backups"
BACKUP_DIR="$BACKUP_ROOT/apple-health-$(date +%Y%m%d-%H%M%S)"

if [ ! -e "$EXPORT_PATH" ]; then
  echo "Apple Health export not found: $EXPORT_PATH" >&2
  exit 2
fi

restore_backup() {
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    return
  fi

  echo ""
  echo "Import failed. Restoring generated data from: $BACKUP_DIR" >&2
  [ -f "$BACKUP_DIR/data.generated.js" ] && cp "$BACKUP_DIR/data.generated.js" "$PROJECT_DIR/data.generated.js"
  [ -f "$BACKUP_DIR/route-index.generated.js" ] && cp "$BACKUP_DIR/route-index.generated.js" "$PROJECT_DIR/route-index.generated.js"
  [ -f "$BACKUP_DIR/city-boundaries.generated.js" ] && cp "$BACKUP_DIR/city-boundaries.generated.js" "$PROJECT_DIR/city-boundaries.generated.js"
  if [ -d "$BACKUP_DIR/routes" ]; then
    rm -rf "$PROJECT_DIR/routes"
    cp -a "$BACKUP_DIR/routes" "$PROJECT_DIR/routes"
  fi
  if [ -f "$BACKUP_DIR/running.db" ]; then
    cp "$BACKUP_DIR/running.db" "$PROJECT_DIR/server/running.db"
  else
    rm -f "$PROJECT_DIR/server/running.db"
  fi
  exit "$exit_code"
}
trap restore_backup EXIT

cd "$PROJECT_DIR"
mkdir -p "$BACKUP_DIR"

echo "=== 1. Backup current generated data ==="
[ -f data.generated.js ] && cp data.generated.js "$BACKUP_DIR/data.generated.js"
[ -f route-index.generated.js ] && cp route-index.generated.js "$BACKUP_DIR/route-index.generated.js"
[ -f city-boundaries.generated.js ] && cp city-boundaries.generated.js "$BACKUP_DIR/city-boundaries.generated.js"
[ -d routes ] && cp -a routes "$BACKUP_DIR/routes"
[ -f server/running.db ] && cp server/running.db "$BACKUP_DIR/running.db"

echo "=== 2. Import Apple Health export ==="
python3 sync/apple-health-import.py "$EXPORT_PATH"

echo "=== 3. Validate generated JavaScript ==="
node --check data.generated.js
node --check route-index.generated.js
node --check app.js
node --check sync/strava-sync.mjs
python3 -m py_compile sync/apple-health-import.py server/migrate.py

echo "=== 4. Rebuild local API database ==="
python3 server/migrate.py

echo "=== 5. Smoke-test generated data and API ==="
node -e "global.window={};require('./data.generated.js');require('./route-index.generated.js');const d=window.RUN_ARCHIVE_DATA;const routes=window.RUN_ROUTE_INDEX;const missing=d.runs.filter(r=>r.routeId&&!routes[r.routeId]);if(missing.length){throw new Error('Missing route refs: '+missing.slice(0,5).map(r=>r.id).join(','));}console.log('Generated data OK:',d.runs.length+' runs,',d.races.length+' races,',Object.keys(routes).length+' routes');"
python3 - <<'PY'
from fastapi.testclient import TestClient
from server.main import app

client = TestClient(app)
for path in ["/api/health", "/api/routes?limit=1", "/api/runs?limit=1", "/api/races"]:
    response = client.get(path)
    response.raise_for_status()
print("API smoke test OK")
PY

echo "=== 6. Build frontend ==="
npm run build

echo ""
echo "Import completed successfully."
echo "Backup kept at: $BACKUP_DIR"
