#!/usr/bin/env bash
# =============================================================================
# sync-names-from-sortinghat.sh — Alinha o campo author_name em todos os
# índices enriquecidos do Elasticsearch com o profile.name atual de cada
# indivíduo no SortingHat.
#
# Use após:
#   - Renomear profiles no SortingHat UI
#   - Mesclar indivíduos (complementa update-after-merge.sh para docs antigos)
#
# Uso:
#   ./scripts/sync-names-from-sortinghat.sh [--dry-run]
#
# Como funciona:
#   1. Para cada indivíduo no SortingHat, coleta profile.name e a lista de
#      author_uuid (hashes das identidades) dele
#   2. Para cada uuid, busca no ES os author_name distintos
#   3. Se algum author_name divergir do profile.name, atualiza via
#      _update_by_query
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ES="http://localhost:9200"
SH="http://localhost:9314/identities/api/"
INDICES="git_enriched,github_enriched,github2_enriched"

cd "$PROJECT_DIR"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Valida .env + serviços ────────────────────────────────────────────────────
[ -f ".env" ] || error ".env não encontrado"
source .env
[ -z "${SORTINGHAT_USER:-}"     ] && error "SORTINGHAT_USER não definido"
[ -z "${SORTINGHAT_PASSWORD:-}" ] && error "SORTINGHAT_PASSWORD não definido"

curl -sf "$ES/_cluster/health" -o /dev/null || error "Elasticsearch não responde"
curl -sf -X POST "$SH" -H "Content-Type: application/json" -d '{"query":"{__typename}"}' -o /dev/null \
  || error "SortingHat não responde"

[ "$DRY_RUN" = true ] && warn "DRY RUN — nenhuma alteração será feita"

# ── Autentica no SortingHat ──────────────────────────────────────────────────
info "Autenticando no SortingHat..."
TOKEN=$(curl -s -X POST "$SH" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"mutation{tokenAuth(username:\\\"$SORTINGHAT_USER\\\",password:\\\"$SORTINGHAT_PASSWORD\\\"){token}}\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['tokenAuth']['token'])")

# ── Sincronização ────────────────────────────────────────────────────────────
info "Sincronizando author_name nos índices ES com profile.name do SortingHat..."

SH_URL="$SH" SH_TOKEN="$TOKEN" ES_URL="$ES" ES_INDICES="$INDICES" DRY="$DRY_RUN" \
python3 <<'PYEOF'
import os, json, requests, sys
from collections import defaultdict

SH   = os.environ['SH_URL']
TOK  = os.environ['SH_TOKEN']
ES   = os.environ['ES_URL']
IDX  = os.environ['ES_INDICES']
DRY  = os.environ['DRY'] == 'true'

H_SH = {"Content-Type": "application/json", "Authorization": f"JWT {TOK}"}
H_ES = {"Content-Type": "application/json"}

# 1. Coleta todos os indivíduos paginando
page = 1
individuals = []
while True:
    q = f"""{{ individuals(pageSize: 50, page: {page}) {{
      entities {{ mk profile {{ name }} identities {{ uuid }} }}
      pageInfo {{ hasNext numPages page }}
    }} }}"""
    r = requests.post(SH, json={"query": q}, headers=H_SH).json()
    data = r.get('data', {}).get('individuals', {})
    individuals.extend(data.get('entities', []))
    info = data.get('pageInfo', {})
    if not info.get('hasNext'):
        break
    page += 1

print(f"  {len(individuals)} indivíduos no SortingHat")

# 2. Para cada indivíduo, checa divergências e atualiza
total_updated = 0
total_changes = 0
report = []

for ind in individuals:
    profile_name = (ind.get('profile') or {}).get('name') or ''
    if not profile_name:
        continue  # sem profile name, não tem como alinhar

    uuids = [i['uuid'] for i in ind.get('identities', [])]
    # inclui o mk também, pois alguns docs podem ter author_uuid = mk
    uuids.append(ind['mk'])

    # 2a. Busca todos os author_name distintos no ES para esses uuids
    q = {
        "size": 0,
        "query": {"terms": {"author_uuid": list(set(uuids))}},
        "aggs": {"nomes": {"terms": {"field": "author_name", "size": 30}}}
    }
    r = requests.post(f"{ES}/{IDX}/_search", json=q, headers=H_ES).json()
    buckets = r.get('aggregations', {}).get('nomes', {}).get('buckets', [])

    # 2b. Para cada nome divergente, atualiza
    divergent = [b for b in buckets if b['key'] != profile_name]
    if not divergent:
        continue

    total_changes += 1
    lines = [f"\n  → {profile_name}"]
    for b in divergent:
        lines.append(f"      \"{b['key']}\" ({b['doc_count']} docs) → \"{profile_name}\"")
    print('\n'.join(lines))

    if not DRY:
        update = {
            "script": {
                "source": "ctx._source.author_name = params.n",
                "lang": "painless",
                "params": {"n": profile_name}
            },
            "query": {
                "bool": {
                    "must":     [{"terms": {"author_uuid": list(set(uuids))}}],
                    "must_not": [{"term":  {"author_name": profile_name}}]
                }
            }
        }
        r2 = requests.post(f"{ES}/{IDX}/_update_by_query?conflicts=proceed",
                           json=update, headers=H_ES).json()
        updated = r2.get('updated', 0)
        total_updated += updated

print(f"\n{'─'*60}")
if DRY:
    print(f"  DRY RUN: {total_changes} indivíduo(s) com divergências")
else:
    print(f"  {total_updated} documento(s) atualizado(s) em {total_changes} indivíduo(s)")
PYEOF

echo ""
if [ "$DRY_RUN" = true ]; then
    info "Rode sem --dry-run para aplicar as mudanças"
else
    success "Sincronização concluída. Recarregue o Kibana: http://localhost:5601"
fi
