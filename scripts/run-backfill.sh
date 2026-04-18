#!/usr/bin/env bash
# First-run: full historical backfill for all repos.
# Run once before enabling weekly syncs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo "ERROR: $PROJECT_DIR/.env not found. Copy .env.example and set GITHUB_TOKEN."
  exit 1
fi

echo "==> Starting Elasticsearch + Kibana..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$PROJECT_DIR/.env" up -d elasticsearch kibana

echo "==> Waiting for Elasticsearch to be ready..."
until curl -sf http://localhost:9200/_cluster/health > /dev/null; do
  echo "   waiting..."
  sleep 5
done
echo "   Elasticsearch ready."

echo "==> Running full historical backfill (this may take a while)..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$PROJECT_DIR/.env" run --rm mordred

echo "==> Backfill complete. Kibana available at http://localhost:5601"
