#!/usr/bin/env bash
# Stop the GrimoireLab stack (Elasticsearch + Kibana).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Stopping devanalitics stack..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" down

echo "==> Done. Data volumes preserved."
