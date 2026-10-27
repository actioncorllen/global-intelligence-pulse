#!/usr/bin/env bash
# Independent Storage backup: RECURSIVELY list every object in each private bucket and download it
# with the service role, into a local tree; the caller (dr_backup_resume.sh / dr_weekly_backup.sh)
# gpg-encrypts the resulting tar. DB backups do NOT contain Storage bytes — this captures the
# generated media and product imports.
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   (operator-held; the service key is a secret)
#
# Why a rewrite of the list/download core (same script, same interface): the old one-liner assumed
# `/storage/v1/object/list/<bucket>` returns a flat ARRAY of file objects and did NOT recurse. In
# this project every object is nested (e.g. <uuid>/<uuid>/<uuid>/file.png, max depth 4), so a
# non-recursive list returns only top-level FOLDER placeholders (id=null) — nothing real is backed
# up — and when the API returns an error OBJECT (a dict) the old `o["name"]` raised
# "TypeError: string indices must be integers". This version recurses into folders, downloads actual
# files, paginates, and fails CLOSED with the API's message (never the credential) on any error.
set -euo pipefail
: "${SUPABASE_URL:?}"; : "${SUPABASE_SERVICE_ROLE_KEY:?}"
BUCKETS="${1:-pulse-generated-media}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"; DEST="strateloq-storage-${TS}"; mkdir -p "$DEST"

# List (recursively) + download every object. Python stdlib only; key read from env, never printed.
# shellcheck disable=SC2086
python3 -I - "$DEST" $BUCKETS <<'PY'
import os, sys, json, pathlib, urllib.request, urllib.parse, urllib.error

BASE = os.environ["SUPABASE_URL"].rstrip("/")
KEY  = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
DEST = sys.argv[1]
BUCKETS = sys.argv[2:]
HDRS = {"Authorization": "Bearer " + KEY, "apikey": KEY}

def _req(method, path, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in HDRS.items():
        req.add_header(k, v)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        # Surface the API's own error text (no credentials in it); never the request headers.
        detail = e.read().decode("utf-8", "replace")[:300]
        raise SystemExit("ERROR: Storage API %s %s -> HTTP %s: %s" % (method, path, e.code, detail))
    except urllib.error.URLError as e:
        raise SystemExit("ERROR: Storage API %s %s -> network error: %s" % (method, path, e.reason))

def list_prefix(bucket, prefix):
    """One prefix level, paginated. Returns the raw list of entries (files + folder placeholders)."""
    out, offset, limit = [], 0, 100
    while True:
        body = {"prefix": prefix, "limit": limit, "offset": offset,
                "sortBy": {"column": "name", "order": "asc"}}
        raw = _req("POST", "/storage/v1/object/list/%s" % urllib.parse.quote(bucket), body)
        try:
            items = json.loads(raw)
        except Exception:
            raise SystemExit("ERROR: Storage list for %s/%s returned non-JSON" % (bucket, prefix))
        # The exact bug this fixes: an error response is a DICT, not a list.
        if isinstance(items, dict):
            raise SystemExit("ERROR: Storage list for %s/%s returned an error object: %s"
                             % (bucket, prefix, json.dumps(items)[:300]))
        if not isinstance(items, list):
            raise SystemExit("ERROR: Storage list for %s/%s returned %s, expected a list"
                             % (bucket, prefix, type(items).__name__))
        out.extend(items)
        if len(items) < limit:
            return out
        offset += limit

def walk(bucket, prefix, files):
    for it in list_prefix(bucket, prefix):
        if not isinstance(it, dict):
            raise SystemExit("ERROR: Storage list item in %s/%s is %s, expected an object"
                             % (bucket, prefix, type(it).__name__))
        name = it.get("name")
        if not name:
            continue
        full = prefix + name
        # A folder placeholder has id == None (and no file metadata); a file has a real id.
        if it.get("id") is None:
            walk(bucket, full + "/", files)
        else:
            files.append(full)

grand = 0
for b in BUCKETS:
    files = []
    walk(b, "", files)
    for f in files:
        raw = _req("GET", "/storage/v1/object/%s/%s" % (urllib.parse.quote(b), urllib.parse.quote(f)))
        p = pathlib.Path(DEST) / b / f
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(raw)
    sys.stderr.write("  [storage] bucket %s: %d object(s) downloaded\n" % (b, len(files)))
    grand += len(files)
sys.stderr.write("  [storage] total objects downloaded: %d\n" % grand)
PY

tar -czf "${DEST}.tgz" "$DEST" && rm -rf "$DEST"
echo "Wrote ${DEST}.tgz — caller encrypts (gpg) + uploads. Reconcile against dr/manifests/storage_manifest.json."
