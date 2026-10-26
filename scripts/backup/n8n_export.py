#!/usr/bin/env python3
# Read-only export of n8n workflows for backup.
# Reads N8N_BASE_URL + N8N_API_KEY from env (never printed).
# Saves each workflow as <out_dir>/<id>.json. List + fetch only; no writes.
#
# NOTE: the n8n public API returns workflow definitions and credential *references*
# (ids/names), NOT the secret values of credentials. So this export does not
# contain raw credential secrets — those stay in n8n's own encrypted store.
import os
import sys
import json
import urllib.request
import urllib.error

BASE = os.environ.get("N8N_BASE_URL", "").rstrip("/")
KEY = os.environ.get("N8N_API_KEY", "")
if not BASE or not KEY:
    sys.stderr.write("n8n_export: N8N_BASE_URL / N8N_API_KEY not set\n")
    sys.exit(2)

OUT = sys.argv[1] if len(sys.argv) > 1 else "n8n"
HDR = {"X-N8N-API-KEY": KEY, "Accept": "application/json"}


def _get(path):
    r = urllib.request.Request(f"{BASE}{path}", headers=HDR, method="GET")
    with urllib.request.urlopen(r, timeout=120) as resp:
        return json.loads(resp.read())


def main():
    os.makedirs(OUT, exist_ok=True)
    count = 0
    cursor = None
    while True:
        path = "/api/v1/workflows?limit=100" + (f"&cursor={cursor}" if cursor else "")
        try:
            page = _get(path)
        except urllib.error.HTTPError as e:
            sys.stderr.write(f"list workflows: HTTP {e.code}\n")
            return 1
        for wf in page.get("data", []):
            wid = str(wf.get("id"))
            with open(os.path.join(OUT, f"{wid}.json"), "w") as f:
                json.dump(wf, f, indent=2, sort_keys=True)
            count += 1
        cursor = page.get("nextCursor")
        if not cursor:
            break
    sys.stderr.write(f"n8n_export: saved {count} workflows\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
