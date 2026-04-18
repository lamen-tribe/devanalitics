#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Deploy completo do devanalitics em um novo ambiente
# Uso: ./bootstrap.sh
# Requisitos: docker, docker compose, python3, curl
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Pré-requisitos ────────────────────────────────────────────────────────
info "Verificando pré-requisitos..."
command -v docker      >/dev/null 2>&1 || error "docker não encontrado"
docker compose version >/dev/null 2>&1 || error "docker compose não encontrado"
command -v python3     >/dev/null 2>&1 || error "python3 não encontrado"
command -v curl        >/dev/null 2>&1 || error "curl não encontrado"
success "Pré-requisitos OK"

# ── .env ─────────────────────────────────────────────────────────────────
if [ ! -f ".env" ]; then
    error ".env não encontrado. Crie o arquivo com:\n  GITHUB_TOKEN=...\n  SORTINGHAT_DB_PASSWORD=...\n  SORTINGHAT_SECRET_KEY=...\n  SORTINGHAT_USER=admin\n  SORTINGHAT_PASSWORD=..."
fi
# Valida variáveis obrigatórias
source .env
[ -z "${GITHUB_TOKEN:-}"            ] && error "GITHUB_TOKEN não definido no .env"
[ -z "${SORTINGHAT_DB_PASSWORD:-}"  ] && error "SORTINGHAT_DB_PASSWORD não definido no .env"
[ -z "${SORTINGHAT_SECRET_KEY:-}"   ] && error "SORTINGHAT_SECRET_KEY não definido no .env"
[ -z "${SORTINGHAT_USER:-}"         ] && error "SORTINGHAT_USER não definido no .env"
[ -z "${SORTINGHAT_PASSWORD:-}"     ] && error "SORTINGHAT_PASSWORD não definido no .env"
success ".env carregado"

# ── Diretórios necessários ────────────────────────────────────────────────
mkdir -p logs tmp
success "Diretórios criados"

# ── Helpers ───────────────────────────────────────────────────────────────
wait_healthy() {
    local service=$1 timeout=${2:-120}
    info "Aguardando $service ficar healthy..."
    local elapsed=0
    until docker compose ps "$service" 2>/dev/null | grep -q "healthy"; do
        sleep 5; elapsed=$((elapsed+5))
        [ $elapsed -ge $timeout ] && error "$service não ficou healthy em ${timeout}s"
        echo -n "."
    done
    echo ""
    success "$service healthy"
}

wait_http() {
    local url=$1 label=$2 timeout=${3:-120}
    info "Aguardando $label ($url)..."
    local elapsed=0
    until curl -sf "$url" -o /dev/null 2>/dev/null; do
        sleep 5; elapsed=$((elapsed+5))
        [ $elapsed -ge $timeout ] && error "$label não respondeu em ${timeout}s"
        echo -n "."
    done
    echo ""
    success "$label OK"
}

# ── 1. Infra base: ES + Kibana + MariaDB + Redis ──────────────────────────
info "▶ Subindo infra base (ES, Kibana, MariaDB, Redis)..."
docker compose up -d elasticsearch kibana mariadb redis

wait_healthy elasticsearch 180
wait_healthy mariadb        120
# Kibana não tem healthcheck — aguarda HTTP
wait_http "http://localhost:5601/api/status" "Kibana" 180

# ── 2. SortingHat ─────────────────────────────────────────────────────────
info "▶ Subindo SortingHat..."
docker compose up -d sortinghat
wait_healthy sortinghat 180
docker compose up -d sortinghat-worker
success "SortingHat + worker rodando"

# ── 3. Importar identidades no SortingHat ─────────────────────────────────
if [ -f "bootstrap/sortinghat_identities.json" ]; then
    info "▶ Importando identidades no SortingHat..."
    SORTINGHAT_URL="http://localhost:9314" \
    SORTINGHAT_USER="$SORTINGHAT_USER" \
    SORTINGHAT_PASSWORD="$SORTINGHAT_PASSWORD" \
    python3 bootstrap/import_sortinghat.py
else
    warn "bootstrap/sortinghat_identities.json não encontrado — pulando importação de identidades"
fi

# ── 4. Coletar e enriquecer dados com Mordred ─────────────────────────────
info "▶ Executando Mordred (coleta + enriquecimento)..."
info "   Isso pode levar de 5 a 20 minutos dependendo dos repositórios..."

docker compose run --rm mordred 2>&1 | tee logs/mordred_bootstrap.log | \
    grep --line-buffered -E "phase (starts|finished)|collection starts for|ERROR|Starting SirMordred" || true

# Verifica se enriquecimento ocorreu
if grep -q "enrichment phase finished" logs/mordred_bootstrap.log 2>/dev/null; then
    success "Mordred concluído"
else
    warn "Mordred pode ter terminado com avisos — veja logs/mordred_bootstrap.log"
fi

# ── 5. Importar dashboards e visualizações no Kibana ─────────────────────
if [ -f "bootstrap/kibana_objects.ndjson" ]; then
    info "▶ Importando dashboards no Kibana..."
    KIBANA_URL="http://localhost:5601" \
    python3 bootstrap/import_kibana.py
else
    warn "bootstrap/kibana_objects.ndjson não encontrado — pulando importação de dashboards"
fi

# ── Resumo ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Bootstrap concluído com sucesso!        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  📊 Kibana:      ${BLUE}http://localhost:5601${NC}"
echo -e "     Dashboards: Git | GitHub Pull Requests | Dev Productivity"
echo ""
echo -e "  👤 SortingHat:  ${BLUE}http://localhost:9314/identities/${NC}"
echo ""
echo -e "  🔄 Para re-sincronizar dados:"
echo -e "     ${YELLOW}docker compose run --rm mordred${NC}"
echo ""
