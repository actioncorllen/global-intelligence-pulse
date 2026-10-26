#!/usr/bin/env python3
"""Enumerate n8n credential REFERENCES across workflow export JSONs (no values).

n8n exports carry credential *references* only — a per-node object with `id`,
`name`, and sometimes n8n metadata flags such as `__aiGatewayManaged` (set on
credentials served through n8n's AI gateway / managed AI credits). Secret VALUES
are never stored on nodes; they live encrypted in `credentials_entity`. This tool
lists the distinct (type, name, id) references and how many nodes/workflows use
each, so an operator can plan credential recovery (recreate each credential per
dr/runbook/SECRETS-RECOVERY.md, then re-bind).

With --detail it drills down per credential to the exact referencing workflows
(id, name, active) and nodes (name, node type, and the service HOST for URL-bearing
nodes), which is the evidence needed to decide whether a credential is genuinely
required and where it must be recovered. --type/--name focus on one credential.

Safety invariant: ONLY `id`, `name`, metadata flag KEY names, node names/types, and
a URL's scheme+HOST (never its path or query string) are ever printed — never a
secret value. If a credential reference carries a key whose NAME indicates a secret
payload (data/value/secret/token/password/apiKey/accessToken/oauthTokenData/…), the
tool fails closed (non-zero, no value printed). Unparseable exports likewise fail
non-zero. Run with -I against (untrusted) export directories.

Usage:
    python3 -I dr_n8n_credential_refs.py <export-dir-or-file> [--detail]
        [--type <credType>] [--name <credName>]

Summary output ends with `DISTINCT_CREDENTIAL_REFERENCES=<n>`; exit 0 on success,
non-zero if credential inspection fails.
"""
import argparse
import collections
import json
import os
import sys
from urllib.parse import urlsplit

# Key names that would indicate an actual secret payload embedded on a node (never
# expected in a legitimate n8n export). Presence => inspection failure, no value printed.
SECRET_KEY_NAMES = {
    "data", "value", "secret", "token", "password", "apikey", "accesstoken",
    "oauthtokendata", "clientsecret", "privatekey", "sessiontoken",
}


def service_host(node):
    """Return a safe scheme://host for a node's URL, or None. Never path/query."""
    params = node.get("parameters") or {}
    url = params.get("url")
    if not isinstance(url, str) or not url:
        return None
    if url.startswith("="):            # n8n expression — may embed an expression ref
        return "(expression url)"
    try:
        parts = urlsplit(url)
    except ValueError:
        return "(unparseable url)"
    if parts.scheme and parts.netloc:
        return f"{parts.scheme}://{parts.netloc}"   # host only, no path/query
    return None


def iter_workflows(path):
    if os.path.isfile(path):
        files = [path]
    else:
        files = [os.path.join(path, f) for f in sorted(os.listdir(path)) if f.endswith(".json")]
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as e:
            sys.exit(f"ABORT: cannot read/parse export {os.path.basename(f)}: {e}")
        for wf in (data if isinstance(data, list) else [data]):
            if isinstance(wf, dict) and "nodes" in wf:
                yield os.path.basename(f), wf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="export dir or single workflow JSON file")
    ap.add_argument("--detail", action="store_true",
                    help="list referencing workflows (id/name/active) and nodes (name/type/host)")
    ap.add_argument("--type", default=None, help="only this credential type")
    ap.add_argument("--name", default=None, help="only this credential name")
    args = ap.parse_args()

    refs = collections.defaultdict(lambda: {"count": 0, "workflows": set(), "flags": set(),
                                            "uses": []})
    wf_count = 0
    for fname, wf in iter_workflows(args.src):
        wf_count += 1
        wname = wf.get("name", fname)
        wid = wf.get("id") or fname
        active = bool(wf.get("active"))
        archived = bool(wf.get("isArchived"))
        for node in wf.get("nodes", []):
            creds = node.get("credentials") or {}
            for ctype, cval in creds.items():
                if not isinstance(cval, dict):
                    continue
                suspicious = sorted(k for k in cval if k.lower() in SECRET_KEY_NAMES)
                if suspicious:
                    sys.exit(f"ABORT: credential reference in {fname} (type {ctype}) carries "
                             f"secret-shaped field(s) {suspicious} — refusing to inspect; "
                             f"credential inspection FAILED (no value printed).")
                if args.type and ctype != args.type:
                    continue
                if args.name and cval.get("name") != args.name:
                    continue
                key = (ctype, cval.get("name"), cval.get("id"))
                r = refs[key]
                r["count"] += 1
                r["workflows"].add(wname)
                for k in cval:
                    if k not in ("id", "name"):
                        r["flags"].add(k)
                r["uses"].append({
                    "wid": wid, "wname": wname,
                    "state": "archived" if archived else ("active" if active else "inactive"),
                    "node": node.get("name"), "ntype": node.get("type"),
                    "host": service_host(node),
                })

    print(f"# scanned {wf_count} workflow(s); {len(refs)} distinct credential reference(s)"
          + (f" matching type={args.type} name={args.name}" if (args.type or args.name) else "") + "\n")
    print(f"{'type':28} {'name':30} {'id':20} node-uses  workflows  flags")
    print("-" * 110)
    for (ctype, name, cid), meta in sorted(refs.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
        flags = ",".join(sorted(meta["flags"])) or "-"
        print(f"{str(ctype):28} {str(name):30} {str(cid):20} "
              f"{meta['count']:<9} {len(meta['workflows']):<9} {flags}")

    if args.detail:
        print("\n# DETAIL — referencing workflows and nodes (host only; no secret, no path/query)")
        for (ctype, name, cid), meta in sorted(refs.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
            print(f"\n== {ctype} / {name!r} (id={cid}) ==")
            # one line per (workflow,node), grouped by workflow
            by_wf = collections.defaultdict(list)
            for u in meta["uses"]:
                by_wf[(u["wid"], u["wname"], u["state"])].append(u)
            for (wid, wname, state), uses in sorted(by_wf.items(), key=lambda kv: kv[0][0]):
                print(f"  workflow {wid} [{state}] {wname!r}")
                for u in uses:
                    host = f"  host={u['host']}" if u["host"] else ""
                    print(f"      node {u['node']!r}  type={u['ntype']}{host}")

    print(f"\nDISTINCT_CREDENTIAL_REFERENCES={len(refs)}")


if __name__ == "__main__":
    main()
