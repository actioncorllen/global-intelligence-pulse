#!/usr/bin/env python3
# Read-only export of Supabase Storage objects for backup.
# Reads SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY from env (never printed).
# Downloads every object in every bucket into <out_dir>/<bucket>/<path>.
# Makes NO writes to Storage — list + download only.
import os
import sys
import json
import urllib.request
import urllib.error
import urllib.parse

BASE = os.environ.get("SUPABASE_URL", "").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
if not BASE or not KEY:
    sys.stderr.write("storage_export: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set\n")
    sys.exit(2)

OUT = sys.argv[1] if len(sys.argv) > 1 else "storage"
HDR = {"apikey": KEY, "Authorization": f"Bearer {KEY}"}


def _req(method, path, body=None):
    url = f"{BASE}/storage/v1{path}"
    data = json.dumps(body).encode() if body is not None else None
    h = dict(HDR)
    if data is not None:
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(r, timeout=120) as resp:
        return resp.read()


def list_buckets():
    return json.loads(_req("GET", "/bucket"))


def list_objects(bucket, prefix=""):
    """Page through objects under a prefix (Supabase returns folders + files)."""
    out = []
    offset = 0
    while True:
        page = json.loads(_req("POST", f"/object/list/{bucket}", {
            "prefix": prefix, "limit": 100, "offset": offset,
            "sortBy": {"column": "name", "order": "asc"},
        }))
        if not page:
            break
        for it in page:
            name = it.get("name")
            if name is None:
                continue
            full = f"{prefix}{name}"
            # A "folder" entry has id == None in Supabase's listing.
            if it.get("id") is None and not it.get("metadata"):
                out.extend(list_objects(bucket, full + "/"))
            else:
                out.append(full)
        if len(page) < 100:
            break
        offset += 100
    return out


def download(bucket, obj, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    enc = urllib.parse.quote(obj)
    url = f"{BASE}/storage/v1/object/{bucket}/{enc}"
    r = urllib.request.Request(url, headers=HDR, method="GET")
    with urllib.request.urlopen(r, timeout=300) as resp, open(dest, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)


def main():
    total = 0
    errors = 0
    buckets = list_buckets()
    for b in buckets:
        name = b.get("name") or b.get("id")
        if not name:
            continue
        try:
            objs = list_objects(name)
        except urllib.error.HTTPError as e:
            sys.stderr.write(f"list {name}: HTTP {e.code}\n")
            errors += 1
            continue
        for obj in objs:
            dest = os.path.join(OUT, name, obj)
            try:
                download(name, obj, dest)
                total += 1
            except urllib.error.HTTPError as e:
                sys.stderr.write(f"download {name}/{obj}: HTTP {e.code}\n")
                errors += 1
        sys.stderr.write(f"bucket {name}: {len(objs)} objects\n")
    sys.stderr.write(f"storage_export: downloaded {total} objects, {errors} errors\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
