#!/usr/bin/env python3
"""Import merged identities into SortingHat."""
import json, requests, sys, os, time

SH_URL  = os.environ.get("SORTINGHAT_URL", "http://localhost:9314")
API     = f"{SH_URL}/identities/api/"
SH_USER = os.environ.get("SORTINGHAT_USER", "admin")
SH_PASS = os.environ.get("SORTINGHAT_PASSWORD", "")

script_dir = os.path.dirname(os.path.abspath(__file__))
identities_path = os.path.join(script_dir, "sortinghat_identities.json")

# ── Authenticate ─────────────────────────────────────────────────────────
def get_token():
    r = requests.post(API, json={
        "query": f'mutation {{ tokenAuth(username: "{SH_USER}", password: "{SH_PASS}") {{ token }} }}'
    }, headers={"Content-Type": "application/json"})
    return r.json()["data"]["tokenAuth"]["token"]

def gql(query, variables=None, token=None):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"JWT {token}"
    r = requests.post(API, json={"query": query, "variables": variables or {}}, headers=h)
    return r.json()

# Try with auth, fall back to no-auth
try:
    token = get_token()
    print("✅ Autenticado no SortingHat")
except Exception:
    token = None
    print("⚠ Sem autenticação (no-auth mode)")

# ── Load identities file ──────────────────────────────────────────────────
with open(identities_path) as f:
    individuals = json.load(f)

print(f"📂 {len(individuals)} indivíduos para importar...")

ADD_ID = """
mutation AddIdentity($source: String!, $name: String, $email: String, $username: String) {
  addIdentity(source: $source, name: $name, email: $email, username: $username) {
    uuid
  }
}
"""

MERGE = """
mutation MergeIndividuals($fromUuids: [String]!, $toUuid: String!) {
  merge(fromUuids: $fromUuids, toUuid: $toUuid) {
    uuid
  }
}
"""

UPDATE_PROFILE = """
mutation UpdateProfile($uuid: String!, $data: ProfileInputType!) {
  updateProfile(uuid: $uuid, data: $data) {
    uuid
  }
}
"""

ok = skipped = errors = 0

for individual in individuals:
    profile  = individual.get("profile", {})
    identities = individual.get("identities", [])
    if not identities:
        continue

    # Add each identity and collect resulting uuids
    uuids = []
    for ident in identities:
        resp = gql(ADD_ID, {
            "source":   ident.get("source") or "unknown",
            "name":     ident.get("name")   or None,
            "email":    ident.get("email")  or None,
            "username": ident.get("username") or None,
        }, token)
        if "errors" in resp and resp["errors"]:
            msg = resp["errors"][0]["message"]
            if "already exists" in msg.lower():
                # extract existing uuid from error or re-query
                skipped += 1
                continue
            errors += 1
        else:
            uid = resp.get("data", {}).get("addIdentity", {}).get("uuid")
            if uid:
                uuids.append(uid)

    # Merge all identities of this individual into one
    if len(uuids) > 1:
        gql(MERGE, {"fromUuids": uuids[1:], "toUuid": uuids[0]}, token)

    # Set display name from profile
    if uuids and profile.get("name"):
        gql(UPDATE_PROFILE, {
            "uuid": uuids[0],
            "data": {
                "name":  profile.get("name"),
                "email": profile.get("email") or None,
                "isBot": profile.get("isBot") or False,
            }
        }, token)
        ok += 1

print(f"✅ SortingHat: {ok} indivíduos importados, {skipped} já existiam, {errors} erros")
