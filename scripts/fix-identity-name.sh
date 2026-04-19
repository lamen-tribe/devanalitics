#!/usr/bin/env bash
# =============================================================================
# fix-identity-name.sh — Corrige author_name em todos os índices ES para
# documentos que já têm o author_uuid correto (ligado ao indivíduo certo no
# SortingHat) mas ainda mostram o nome bruto do git nos dashboards.
#
# Isso é necessário quando o GrimoireLab enriqueceu o documento ANTES do
# merge de identidades no SortingHat, e como autorefresh=false, ele não
# re-processa documentos já enriquecidos.
#
# Uso:
#   ./scripts/fix-identity-name.sh "nome errado" "Nome Correto"
#
# Exemplo:
#   ./scripts/fix-identity-name.sh "rafael" "Rafael Braz"
#   ./scripts/fix-identity-name.sh "andre"  "Andre Raposo"
#
# O script:
#   1. Busca todos os author_uuid distintos para o "nome errado"
#   2. Para cada uuid, verifica se pertence ao "Nome Correto" no SortingHat
#   3. Atualiza author_name nos índices git_enriched, github_enriched,
#      github2_enriched via ES _update_by_query
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ES="http://localhost:9200"
INDICES="git_enriched,github_enriched,github2_enriched"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Args ──────────────────────────────────────────────────────────────────────
[ $# -lt 2 ] && error "Uso: $0 \"nome errado\" \"Nome Correto\""
WRONG_NAME="$1"
CORRECT_NAME="$2"

info "Corrigindo: \"$WRONG_NAME\" → \"$CORRECT_NAME\""

# ── Verifica ES ───────────────────────────────────────────────────────────────
curl -sf "$ES/_cluster/health" -o /dev/null || error "Elasticsearch não responde em $ES"

# ── Busca todos os UUIDs com o nome errado ────────────────────────────────────
info "Buscando UUIDs com author_name = \"$WRONG_NAME\"..."

UUIDS=$(curl -s "$ES/$INDICES/_search" \
  -H "Content-Type: application/json" \
  -d "{
    \"size\": 0,
    \"query\": {\"term\": {\"author_name\": \"$WRONG_NAME\"}},
    \"aggs\": {\"uuids\": {\"terms\": {\"field\": \"author_uuid\", \"size\": 50}}}
  }" | python3 -c "
import json, sys
r = json.load(sys.stdin)
buckets = r.get('aggregations', {}).get('uuids', {}).get('buckets', [])
total_docs = sum(b['doc_count'] for b in buckets)
print(f'TOTAL_DOCS={total_docs}')
for b in buckets:
    print(b['key'])
")

TOTAL_DOCS=$(echo "$UUIDS" | grep "^TOTAL_DOCS=" | cut -d= -f2)
UUID_LIST=$(echo "$UUIDS" | grep -v "^TOTAL_DOCS=")

if [ -z "$UUID_LIST" ]; then
    success "Nenhum documento encontrado com author_name = \"$WRONG_NAME\". Nada a fazer."
    exit 0
fi

UUID_COUNT=$(echo "$UUID_LIST" | wc -l | tr -d ' ')
info "Encontrados $TOTAL_DOCS documentos com $UUID_COUNT UUID(s) distintos:"
echo "$UUID_LIST" | while read -r uuid; do echo "  - $uuid"; done

# ── Monta o array JSON de UUIDs para o update_by_query ───────────────────────
UUID_JSON=$(echo "$UUID_LIST" | python3 -c "
import sys, json
uuids = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(uuids))
")

# ── Atualiza author_name nos índices ─────────────────────────────────────────
info "Atualizando author_name para \"$CORRECT_NAME\" nos índices: $INDICES..."

RESULT=$(curl -s -X POST "$ES/$INDICES/_update_by_query?conflicts=proceed" \
  -H "Content-Type: application/json" \
  -d "{
    \"script\": {
      \"source\": \"ctx._source.author_name = params.name\",
      \"lang\": \"painless\",
      \"params\": {\"name\": \"$CORRECT_NAME\"}
    },
    \"query\": {
      \"bool\": {
        \"must\": [{\"terms\": {\"author_uuid\": $UUID_JSON}}],
        \"must_not\": [{\"term\": {\"author_name\": \"$CORRECT_NAME\"}}]
      }
    }
  }")

UPDATED=$(echo "$RESULT" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('updated', 0))")
FAILURES=$(echo "$RESULT" | python3 -c "import json,sys; r=json.load(sys.stdin); print(len(r.get('failures', [])))")

if [ "$FAILURES" -gt 0 ]; then
    warn "Concluído com $FAILURES falha(s). Documentos atualizados: $UPDATED"
else
    echo ""
    success "$UPDATED documentos corrigidos: \"$WRONG_NAME\" → \"$CORRECT_NAME\""
    echo -e "  Recarregue o Kibana: ${BLUE}http://localhost:5601${NC}"
fi
