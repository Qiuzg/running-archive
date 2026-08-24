#!/usr/bin/env bash
# ============================================================
# Running Archive — ECS deployment script
# Run from your local machine (or on the ECS server directly).
#   ./server/deploy.sh [ecs-host]
# ============================================================
set -euo pipefail

ECS_HOST="${1:-${ECS_HOST:-}}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="/opt/running-archive"

echo "=== 1. Build frontend ==="
cd "$PROJECT_DIR"
if [ -n "$ECS_HOST" ]; then
    BASE_PATH="${BASE_PATH:-/run/}" npm run build
else
    npm run build
fi

if [ -n "$ECS_HOST" ]; then
    echo "=== 2. Deploy to ECS ($ECS_HOST) ==="

    # Upload built files
    rsync -avz --delete \
        "$PROJECT_DIR/dist/" \
        "$ECS_HOST:$DEPLOY_DIR/dist/"

    # Upload server code
    rsync -avz --delete \
        "$PROJECT_DIR/server/" \
        "$ECS_HOST:$DEPLOY_DIR/server/" \
        --exclude '__pycache__' \
        --exclude '*.db' \
        --exclude '*.db.backup.*' \
        --exclude 'venv'

    # Upload data files (for migration)
    rsync -avz \
        "$PROJECT_DIR/data.generated.js" \
        "$PROJECT_DIR/route-index.generated.js" \
        "$PROJECT_DIR/city-boundaries.generated.js" \
        "$ECS_HOST:$DEPLOY_DIR/"

    # Upload route detail files into the routes directory.
    rsync -avz --delete \
        "$PROJECT_DIR/routes/" \
        "$ECS_HOST:$DEPLOY_DIR/routes/"

    echo "=== 3. Remote setup ==="
    ssh "$ECS_HOST" bash -s << 'REMOTE'
        set -e
        cd /opt/running-archive
        rm -f route-apple-*.js

        # Python venv. Fresh Debian/Ubuntu images may not include ensurepip.
        if ! python3 -m venv venv; then
            if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
                apt-get update
                apt-get install -y python3-venv
                rm -rf venv
                python3 -m venv venv
            else
                echo "Failed to create Python venv. Install python3-venv and retry." >&2
                exit 1
            fi
        fi
        ./venv/bin/pip install -r server/requirements.txt

        # Rebuild DB from the uploaded generated files on every deployment.
        # Keep a timestamped copy so a bad upload can be recovered manually.
        if [ -f server/running.db ]; then
            cp server/running.db "server/running.db.backup.$(date +%Y%m%d-%H%M%S)"
        fi
        ./venv/bin/python3 server/migrate.py

        # The API runs as www-data. SQLite needs write access to both the
        # database file and its parent directory for journal files.
        chown root:www-data server
        chmod 775 server
        chown www-data:www-data server/running.db
        chmod 660 server/running.db

        # Nginx config
        sudo cp server/nginx.conf /etc/nginx/sites-available/running-archive
        sudo ln -sf /etc/nginx/sites-available/running-archive /etc/nginx/sites-enabled/
        # The current production entry point proxies /run/ to port 8080. Keep
        # its inner API body limit in version control as well; otherwise the
        # default 1 MB Nginx limit rejects a single detailed HealthKit workout.
        sudo cp server/nginx-subpath.conf /etc/nginx/conf.d/running-archive.conf
        sudo nginx -t && sudo systemctl reload nginx

        # Systemd service
        sudo cp server/running-archive.service /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable running-archive
        sudo systemctl restart running-archive

        echo "=== Deployment complete ==="
        sudo systemctl status running-archive --no-pager
REMOTE

else
    echo "=== Local deployment ==="
    echo "Frontend built to: $PROJECT_DIR/dist"
    echo ""
    echo "To run locally:"
    echo "  Terminal 1: python3 -m uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload"
    echo "  Terminal 2: npx vite preview"
    echo ""
    echo "Or for production-like setup with Nginx:"
    echo "  sudo cp server/nginx.conf /etc/nginx/sites-available/running-archive"
    echo "  sudo ln -s /etc/nginx/sites-available/running-archive /etc/nginx/sites-enabled/"
    echo "  sudo systemctl reload nginx"
fi
