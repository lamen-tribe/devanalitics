#!/usr/bin/env python3
"""Import Kibana saved objects (index-patterns, visualizations, dashboards)."""
import requests, sys, os

KIBANA = os.environ.get("KIBANA_URL", "http://localhost:5601")
H = {"kbn-xsrf": "true"}

script_dir = os.path.dirname(os.path.abspath(__file__))
ndjson_path = os.path.join(script_dir, "kibana_objects.ndjson")

with open(ndjson_path, "rb") as f:
    r = requests.post(
        f"{KIBANA}/api/saved_objects/_import?overwrite=true",
        headers=H,
        files={"file": ("kibana_objects.ndjson", f, "application/ndjson")},
    )

if r.status_code in (200, 201):
    result = r.json()
    print(f"✅ Kibana: {result.get('successCount', '?')} objetos importados")
    errors = result.get("errors", [])
    if errors:
        print(f"  ⚠ {len(errors)} erros parciais:")
        for e in errors[:5]:
            print(f"    - {e['type']}:{e['id']}: {e.get('error',{}).get('message','?')}")
else:
    print(f"❌ Kibana import falhou: {r.status_code} {r.text[:200]}")
    sys.exit(1)
