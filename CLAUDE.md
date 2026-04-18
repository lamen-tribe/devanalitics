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

## Running the Stack

### First deploy (new environment)
```bash
cp .env.example .env  # fill in required values
./bootstrap.sh
```

### Day-to-day
```bash
# Start all services
docker compose up -d

# Re-sync data (incremental)
docker compose run --rm mordred

# Historical backfill
./scripts/run-backfill.sh

# Weekly cron (add to crontab)
# 0 6 * * 1 /path/to/scripts/run-weekly-sync.sh >> logs/cron.log 2>&1
```

### Stop
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
sirmordred config. Uses `%(VAR)s` placeholders that are **not** ConfigParser interpolation — they are replaced at runtime by `sed` inside the mordred container entrypoint. Do not use `%()s` for new values unless the entrypoint sed command also substitutes them.

Critical settings:
- `[phases] panels = false` — kidash is incompatible with ES 7.9.1 OSS; dashboards are imported separately
- `[sortinghat] path = /identities/api/` — must match the custom Django urlconf
- `[github] category = pull_request` and `[github2] category = issue` — separate backends for PRs vs issues

### `conf/projects.json`
Defines which repos to collect. Add/remove repos here to change collection scope. Both `git` (clone URLs) and `github` (`owner/repo` pairs) sections must list the same repos.

### `conf/sortinghat_settings.py` + `conf/sh_custom_urls.py`
Custom Django settings and URL patterns for SortingHat. Mounted into the container via `PYTHONPATH=/sh_custom`. The SortingHat Vue SPA is hardcoded with `BASE_URL="/identities/"`, so all URLs must be under that prefix. The urlconf wires `/identities/api/` for GraphQL and serves the SPA for everything else.

## Architecture Notes

### Why custom SortingHat urlconf?
The SortingHat SPA (`grimoirelab/grimoirelab:latest`) has `BASE_URL="/identities/"` baked into the compiled JS. It calls `/identities/api/` for GraphQL. The default Django config serves at `/api/`. The custom `sh_custom_urls.py` adds the `/identities/` prefix without `FORCE_SCRIPT_NAME` (which caused double-prefixing).

### Why sed for setup.cfg variables?
Python's ConfigParser does its own `%(VAR)s` interpolation, so env vars can't be passed directly as `%(ENV_VAR)s`. The mordred entrypoint replaces them with `sed -e "s|%(VAR)s|$VAR|g"` before running sirmordred.

### Kibana index patterns
- `git_enriched` — commits from git
- `github_enriched` — pull requests
- `github2_enriched` — issues
- `productivity` — multi-index pattern spanning `git_enriched,github_enriched` used by the "Dev Productivity" dashboard

### Cross-source visualizations
Kibana 7.9 OSS cannot JOIN indices. The `productivity` multi-index pattern lets aggregations span both sources. Use a `filters` aggregation with `group` schema (with `_index:git_enriched` and `_index:github_enriched` filter inputs) to split metrics by data source in bar/line charts. Use separate `searchSourceJSON` queries (`_index:git_enriched` / `_index:github_enriched`) to filter individual metric visualizations.

## Bootstrap Artifacts

| File | Purpose |
|------|---------|
| `bootstrap/kibana_objects.ndjson` | Exported Kibana saved objects (index-patterns, vizs, dashboards) |
| `bootstrap/sortinghat_identities.json` | Merged developer identities exported from SortingHat |
| `bootstrap/import_kibana.py` | Imports ndjson via `/api/saved_objects/_import?overwrite=true` |
| `bootstrap/import_sortinghat.py` | Adds identities + merges + sets profiles via GraphQL |

To re-export after adding/merging identities in the SortingHat UI:
```python
# SortingHat GraphQL — export individuals
query { individuals(pageSize: 200) { entities { profile { name email isBot }
  identities { source name email username } } pageInfo { numPages } } }
```

To re-export Kibana objects: **Management → Saved Objects → Export all**.
