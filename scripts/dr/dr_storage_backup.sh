#!/usr/bin/env bash
# Independent Storage backup: list every bucket object and download to a local, then
# encrypt. DB backups do NOT contain Storage bytes — this is required for generated media
# and any storefront/product assets. NEVER commit the downloaded objects.
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   (operator-held; service key is a secret)
set -euo pipefail
: "${SUPABASE_URL:?}"; : "${SUPABASE_SERVICE_ROLE_KEY:?}"
BUCKETS="${1:-pulse-generated-media}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"; DEST="strateloq-storage-${TS}"; mkdir -p "$DEST"
for B in $BUCKETS; do
  # list objects (service role) then download each
  curl -s -X POST "$SUPABASE_URL/storage/v1/object/list/$B" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -H "Content-Type: application/json" \
    -d '{"prefix":"","limit":10000}' | \
  python3 -c 'import sys,json;[print(o["name"]) for o in json.load(sys.stdin)]' | while read -r OBJ; do
    mkdir -p "$DEST/$B/$(dirname "$OBJ")"
    curl -s "$SUPABASE_URL/storage/v1/object/$B/$OBJ" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -o "$DEST/$B/$OBJ"
  done
done
tar -czf "${DEST}.tgz" "$DEST" && rm -rf "$DEST"
echo "Wrote ${DEST}.tgz — encrypt (gpg) and store offsite. Reconcile against dr/manifests/storage_manifest.json."
