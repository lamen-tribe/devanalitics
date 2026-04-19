# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack Overview

**devanalitics** uses [GrimoireLab](https://chaoss.github.io/grimoirelab/) to collect and visualize developer activity from the `lamen-tribe` GitHub org.

Services (all via `docker-compose.yml`):
- **Elasticsearch 7.9.1 OSS** + **Kibana 7.9.1 OSS** — storage and dashboards (ports 9200, 5601)
- **MariaDB 10.11** + **Redis 7** — backing stores for SortingHat
- **SortingHat** — identity deduplication service (port 9314 → container 8000)
- **sortinghat-worker** — async RQ worker for SortingHat tasks
- **mordred** — one-shot sirmordred container: collects git + GitHub data, enriches, merges identities

## Common Operations

### First deploy (new environment)
```bash
cp .env.example .env  # fill in required values
./bootstrap.sh
```

### Start services
```bash
docker compose up -d
```

### Full sync (collect + enrich all repos)
```bash
docker compose run --rm mordred
# or for scheduled weekly sync:
./scripts/run-weekly-sync.sh
```

### Historical backfill (first run)
```bash
./scripts/run-backfill.sh
```

### Stop all services
```bash
./scripts/stop.sh
```

## Identity Management

### Full workflow after merging identities in SortingHat UI

```
SortingHat UI merge → update-after-merge.sh → (if name still wrong) → fix-identity-name.sh
```

**Step 1 — Merge in the UI:** http://localhost:9314/identities/

**Step 2 — Propagate to ES:**
```bash
./scripts/update-after-merge.sh
# Skips collection (~30s). Re-enriches all 3 indices with the new identity mappings.
```

**Step 3 — Fix stale names (if still wrong after step 2):**

With `autorefresh = false` in `setup.cfg`, sirmordred does **not** re-enrich documents that already have `author_uuid` populated. Old commits enriched before the SortingHat merge keep the raw git name. Two options:

**Option A — Bulk sync all individuals (preferred after SortingHat profile renames):**
```bash
./scripts/sync-names-from-sortinghat.sh --dry-run  # preview changes
./scripts/sync-names-from-sortinghat.sh             # apply
```
Iterates every SortingHat individual, collects all its identity uuids, and forces `author_name` in ES to match the current `profile.name`. **This is the authoritative sync** — SortingHat profile is the source of truth.

**Option B — Fix a single name manually:**
```bash
./scripts/fix-identity-name.sh "nome errado" "Nome Correto"

# Example:
./scripts/fix-identity-name.sh "rafael"               "Rafael Braz"
./scripts/fix-identity-name.sh "Rafael Rodrigues Braz" "Rafael Braz"
```

Both scripts use `author_uuid` (per-identity hash, not the individual's `mk`) to find documents and bulk-update `author_name` across `git_enriched`, `github_enriched`, and `github2_enriched` via ES `_update_by_query`. Then reload Kibana.

**If you manually renamed things in ES before aligning SortingHat profiles**, running `sync-names-from-sortinghat.sh` will revert them to match SortingHat (since SH is the source of truth). Rename the profile in the SortingHat UI first if you want a specific display name.

### Why names stay wrong after a SortingHat merge

Two root causes:

1. **`autorefresh = false`** — mordred enriches each raw item only once. After a merge, only *new* items get the resolved profile name; existing docs keep the git raw name. Fix with `fix-identity-name.sh`.

2. **Transient `RemoteDisconnected` from SortingHat** — one identity lookup fails mid-enrichment; that item is stored without resolution. Fix by re-running `update-after-merge.sh` (usually succeeds on retry).

### Adding a missing identity to SortingHat via API

When a commit has `email=None` (git configured without email) and SortingHat can't match it by name alone:

```bash
source .env
TOKEN=$(curl -s -X POST http://localhost:9314/identities/api/ \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"mutation{tokenAuth(username:\\\"$SORTINGHAT_USER\\\",password:\\\"$SORTINGHAT_PASSWORD\\\"){token}}\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['tokenAuth']['token'])")

# Add identity (no email)
NEW_UUID=$(curl -s -X POST http://localhost:9314/identities/api/ \
  -H "Content-Type: application/json" -H "Authorization: JWT $TOKEN" \
  -d '{"query":"mutation{addIdentity(source:\"git\",name:\"nome\"){uuid}}"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['addIdentity']['uuid'])")

# Merge into target individual (use the individual's mk)
curl -s -X POST http://localhost:9314/identities/api/ \
  -H "Content-Type: application/json" -H "Authorization: JWT $TOKEN" \
  -d "{\"query\":\"mutation{merge(fromUuids:[\\\"$NEW_UUID\\\"],toUuid:\\\"TARGET_MK\\\"){uuid}}\"}"
```

To find the `mk` of an individual: query ES for a correctly-enriched commit by that person and use `author_uuid`, then look it up in SortingHat.

### Maintaining `conf/projects.json`

Contains only **active repos** (last push within 2 years). All three backends (`git`, `github`, `github2`) must list the same repos.

To refresh when repos go stale or new ones are created:
```bash
gh repo list lamen-tribe --limit 100 --json name,pushedAt,isFork,isArchived
```
Filter out forks, archived, profile repos (`.github`, `lamen-tribe`, `demo-repository`), and repos with `pushedAt` older than 2 years. Edit `projects.json` and commit.

## Key Configuration Files

### `conf/setup.cfg`
sirmordred config. Uses `%(VAR)s` placeholders replaced at runtime by `sed` inside the mordred container entrypoint — **not** Python ConfigParser interpolation. Do not add new `%(VAR)s` placeholders without also adding the matching `sed -e` substitution in the `docker-compose.yml` mordred command.

Critical settings:
- `[phases] panels = false` — kidash is incompatible with ES 7.9.1 OSS; dashboards are imported separately via `bootstrap/import_kibana.py`
- `[sortinghat] path = /identities/api/` — must match the custom Django urlconf
- `[github] category = pull_request` and `[github2] category = issue` — separate backends for PRs vs issues
- To run enrichment-only (skip collection), `sed` replaces `collection = true` → `collection = false` before invoking sirmordred (done automatically by `update-after-merge.sh`)

### `conf/sortinghat_settings.py` + `conf/sh_custom_urls.py`
Custom Django settings and URL patterns for SortingHat. Mounted into the container via `PYTHONPATH=/sh_custom`. The SortingHat Vue SPA is hardcoded with `BASE_URL="/identities/"`, so all URLs must be under that prefix. The urlconf wires `/identities/api/` for GraphQL and serves the SPA for everything else.

## Architecture Notes

### Why custom SortingHat urlconf?
The SortingHat SPA (`grimoirelab/grimoirelab:latest`) has `BASE_URL="/identities/"` baked into the compiled JS. It calls `/identities/api/` for GraphQL. The default Django config serves at `/api/`. The custom `sh_custom_urls.py` adds the `/identities/` prefix without `FORCE_SCRIPT_NAME` (which caused double-prefixing `/identities/identities/api/`).

### Why sed for setup.cfg variables?
Python's ConfigParser does its own `%(VAR)s` interpolation and fails if the variable isn't defined in the same config file. The mordred entrypoint replaces env vars with `sed -e "s|%(VAR)s|$VAR|g"` before passing the config to sirmordred.

### SortingHat `--no-auth` mode
SortingHat runs with `--no-auth` in docker-compose. The `import_sortinghat.py` bootstrap script tries JWT auth first and falls back to no-auth. The GraphQL endpoint is `csrf_exempt` in the custom urlconf.

### Kibana index patterns
- `git_enriched` — commits from git
- `github_enriched` — pull requests
- `github2_enriched` — issues
- `productivity` — multi-index pattern spanning `git_enriched,github_enriched` used by the "Dev Productivity" dashboard

### Cross-source visualizations (Kibana 7.9 OSS)
Kibana 7.9 OSS cannot JOIN indices. The `productivity` multi-index pattern lets aggregations span both sources:
- Use a `filters` aggregation with `group` schema (inputs: `_index:git_enriched` and `_index:github_enriched`) to split bar/line charts by source
- Use separate `searchSourceJSON` queries to filter individual metric panels (e.g., Total Commits queries only `git_enriched`)
- The `author_name` field is shared across both indices after enrichment

### Known non-critical errors during enrichment
- `Can't get github login: Copilot` — GitHub Copilot bot has no public user profile; perceval skips it
- `Connection aborted / RemoteDisconnected` for a SortingHat identity — transient connection reset; that item gets no identity resolution but the rest of the run continues. Re-run `update-after-merge.sh` to fix.

## Bootstrap Artifacts

| File | Purpose |
|------|---------|
| `bootstrap/kibana_objects.ndjson` | Exported Kibana saved objects (index-patterns, vizs, dashboards) |
| `bootstrap/sortinghat_identities.json` | Merged developer identities exported from SortingHat |
| `bootstrap/import_kibana.py` | Imports ndjson via `/api/saved_objects/_import?overwrite=true` |
| `bootstrap/import_sortinghat.py` | Adds identities + merges + sets profiles via GraphQL |

### Re-exporting after changes

**SortingHat identities** (run from host, SortingHat must be up):
```bash
source .env
TOKEN=$(curl -s -X POST http://localhost:9314/identities/api/ \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"mutation{tokenAuth(username:\\\"$SORTINGHAT_USER\\\",password:\\\"$SORTINGHAT_PASSWORD\\\"){token}}\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['tokenAuth']['token'])")

curl -s -X POST http://localhost:9314/identities/api/ \
  -H "Content-Type: application/json" -H "Authorization: JWT $TOKEN" \
  -d '{"query":"{ individuals(pageSize: 200) { entities { mk profile { name email isBot } identities { source name email username } } pageInfo { numPages } } }"}' \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
individuals = data['data']['individuals']['entities']
with open('bootstrap/sortinghat_identities.json', 'w') as f:
    json.dump(individuals, f, indent=2)
print(f'Exported {len(individuals)} individuals')
"
```

**Kibana dashboards**: Management → Saved Objects → Export all → save as `bootstrap/kibana_objects.ndjson`
