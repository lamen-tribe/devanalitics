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

### After merging identities in SortingHat UI
```bash
./scripts/update-after-merge.sh
# Skips collection (~30s). Propagates merged identities to ES indices.
# Then reload Kibana to see consolidated names in dashboards.
```

### Historical backfill (first run)
```bash
./scripts/run-backfill.sh
```

### Stop all services
```bash
./scripts/stop.sh
```

## Required `.env` Variables

```
GITHUB_TOKEN=             # repo, read:user, read:org scopes
SORTINGHAT_DB_PASSWORD=
SORTINGHAT_SECRET_KEY=
SORTINGHAT_USER=
SORTINGHAT_PASSWORD=
```

## Key Configuration Files

### `conf/setup.cfg`
sirmordred config. Uses `%(VAR)s` placeholders replaced at runtime by `sed` inside the mordred container entrypoint — **not** Python ConfigParser interpolation. Do not add new `%(VAR)s` placeholders without also adding the matching `sed -e` substitution in the `docker-compose.yml` mordred command.

Critical settings:
- `[phases] panels = false` — kidash is incompatible with ES 7.9.1 OSS; dashboards are imported separately via `bootstrap/import_kibana.py`
- `[sortinghat] path = /identities/api/` — must match the custom Django urlconf
- `[github] category = pull_request` and `[github2] category = issue` — separate backends for PRs vs issues
- To run enrichment-only (skip collection), `sed` replaces `collection = true` → `collection = false` before invoking sirmordred

### `conf/projects.json`
Defines which repos to collect. Contains only **active repos** (last push within 2 years). All three backends (`git`, `github`, `github2`) must list the same repos.

To update when new repos are added or old ones go stale, query GitHub:
```bash
gh repo list lamen-tribe --limit 100 --json name,pushedAt,isFork,isArchived
```
Then edit `projects.json` accordingly and commit.

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

### Identity deduplication workflow
1. Run a full sync: `docker compose run --rm mordred`
2. Open SortingHat UI: http://localhost:9314/identities/
3. Merge duplicate identities manually (different capitalizations, partial names, multiple emails)
4. Propagate merges to dashboards: `./scripts/update-after-merge.sh`

Known non-critical errors during enrichment:
- `Can't get github login: Copilot` — GitHub Copilot bot has no public user profile; perceval skips it
- `Connection aborted / RemoteDisconnected` for a SortingHat identity — transient connection reset; that one item gets no identity but the rest of the run continues normally

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
python3 - <<'EOF'
import json, requests
API = "http://localhost:9314/identities/api/"
q = """{ individuals(pageSize: 200) { entities {
  profile { name email isBot }
  identities { source name email username }
} pageInfo { numPages } } }"""
r = requests.post(API, json={"query": q}, headers={"Content-Type": "application/json"})
individuals = r.json()["data"]["individuals"]["entities"]
with open("bootstrap/sortinghat_identities.json", "w") as f:
    json.dump(individuals, f, indent=2)
print(f"Exported {len(individuals)} individuals")
EOF
```

**Kibana dashboards**: Management → Saved Objects → Export all → save as `bootstrap/kibana_objects.ndjson`
