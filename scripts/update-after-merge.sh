#!/usr/bin/env bash
# =============================================================================
# update-after-merge.sh — Re-enriquecer dados após merge de identidades no
# SortingHat. NÃO re-coleta dados do GitHub/git (muito mais rápido: ~30s).
#
# Uso:
#   ./scripts/update-after-merge.sh
#
# Quando usar:
#   Após fazer merge de identidades em http://localhost:9314/identities/
#   para que os dashboards do Kibana reflitam os nomes consolidados.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_DIR/logs/enrich-$(date +%Y%m%d-%H%M%S).log"

cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Valida .env ───────────────────────────────────────────────────────────────
[ -f ".env" ] || error ".env não encontrado"
source .env
[ -z "${GITHUB_TOKEN:-}"           ] && error "GITHUB_TOKEN não definido"
[ -z "${SORTINGHAT_USER:-}"        ] && error "SORTINGHAT_USER não definido"
[ -z "${SORTINGHAT_PASSWORD:-}"    ] && error "SORTINGHAT_PASSWORD não definido"

# ── Verifica serviços ─────────────────────────────────────────────────────────
info "Verificando serviços..."
docker compose ps elasticsearch | grep -q "healthy" || error "Elasticsearch não está healthy. Rode: docker compose up -d"
docker compose ps sortinghat    | grep -q "healthy" || error "SortingHat não está healthy. Rode: docker compose up -d"
success "Serviços OK"

# ── Enriquecimento sem coleta ─────────────────────────────────────────────────
info "Propagando identidades mescladas para os índices Elasticsearch..."
info "Log: $LOG_FILE"

docker compose run --rm mordred sh -c "
  sed \
    -e \"s|%(GITHUB_TOKEN)s|\$GITHUB_TOKEN|g\" \
    -e \"s|%(SORTINGHAT_USER)s|\$SORTINGHAT_USER|g\" \
    -e \"s|%(SORTINGHAT_PASSWORD)s|\$SORTINGHAT_PASSWORD|g\" \
    -e \"s|^collection = true|collection = false|\" \
    /home/user/conf/setup.cfg > /tmp/setup.cfg && \
  sirmordred -c /tmp/setup.cfg
" 2>&1 | tee "$LOG_FILE" | grep --line-buffered -E "phase (starts|finished)|finished in|ERROR|CRITICAL" || true

# ── Resultado ─────────────────────────────────────────────────────────────────
if grep -q "enrichment phase finished" "$LOG_FILE" 2>/dev/null; then
    echo ""
    success "Enriquecimento concluído! Recarregue o Kibana para ver as mudanças."
    echo -e "  📊 ${BLUE}http://localhost:5601${NC}"
else
    warn "Processo encerrou com possíveis avisos. Verifique: $LOG_FILE"
fi
