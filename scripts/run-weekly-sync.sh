#!/usr/bin/env bash
# Weekly incremental sync. Add to crontab:
#   0 6 * * 1 /path/to/run-weekly-sync.sh >> /path/to/logs/cron.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_DIR/logs/sync-$(date +%Y%m%d-%H%M%S).log"

echo "==> [$(date)] Weekly sync started" | tee -a "$LOG_FILE"

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo "ERROR: $PROJECT_DIR/.env not found." | tee -a "$LOG_FILE"
  exit 1
fi

# Ensure ES + Kibana are up
docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$PROJECT_DIR/.env" up -d elasticsearch kibana

until curl -sf http://localhost:9200/_cluster/health > /dev/null; do
  sleep 5
done

docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$PROJECT_DIR/.env" run --rm mordred 2>&1 | tee -a "$LOG_FILE"

echo "==> [$(date)] Weekly sync finished" | tee -a "$LOG_FILE"
