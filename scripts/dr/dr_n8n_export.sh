#!/usr/bin/env bash
# Export every n8n workflow DEFINITION to JSON for DR. n8n's API never returns credential
# secret values, so exports are safe to keep — but review before committing and keep only
# Strateloq/Pulse workflows. Credentials are recovered separately (dr/runbook/SECRETS-RECOVERY.md).
#   N8N_BASE_URL   https://<instance>.app.n8n.cloud
#   N8N_API_KEY    operator-held n8n API key (a secret)
set -euo pipefail
: "${N8N_BASE_URL:?}"; : "${N8N_API_KEY:?}"
DEST="${1:-dr/n8n/export-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$DEST"
curl -s "$N8N_BASE_URL/api/v1/workflows?limit=250" -H "X-N8N-API-KEY: $N8N_API_KEY" | \
python3 -c '
import sys,json,re,os
dest=os.environ["DEST"]; data=json.load(sys.stdin).get("data",[])
for w in data:
    name=re.sub(r"[^A-Za-z0-9_-]","_",w.get("name",""))[:60]
    json.dump(w, open(f"{dest}/{w[\"id\"]}_{name}.json","w"), indent=2)
print(f"exported {len(data)} workflows to {dest}")
' DEST="$DEST"
echo "Review exports for any accidental inline secrets before committing (n8n stores creds by reference, not value)."
