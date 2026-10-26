#!/usr/bin/env python3
"""Enumerate n8n credential REFERENCES across workflow export JSONs (no values).

n8n exports carry credential *references* only — `{id, name}` per node — never
secret values. This tool lists the distinct (type, name, id) references and how
many nodes/workflows use each, so an operator can plan credential recovery
(recreate each credential per dr/runbook/SECRETS-RECOVERY.md, then re-bind).

It asserts that each credential reference contains only {id, name} and prints a
clear error if any export ever carried an unexpected field, so it can never leak
a value. Run with -I against (untrusted) export directories.

Usage:
    python3 -I dr_n8n_credential_refs.py <export-dir-or-file>

Exit output ends with `DISTINCT_CREDENTIAL_REFERENCES=<n>` for scripting.
"""
import collections
import json
import os
import sys


def iter_workflows(path):
    if os.path.isfile(path):
        files = [path]
    else:
        files = [os.path.join(path, f) for f in sorted(os.listdir(path)) if f.endswith(".json")]
    for f in files:
        with open(f, encoding="utf-8") as fh:
            data = json.load(fh)
        for wf in (data if isinstance(data, list) else [data]):
            if isinstance(wf, dict) and "nodes" in wf:
                yield os.path.basename(f), wf


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 -I dr_n8n_credential_refs.py <export-dir-or-file>")
    src = sys.argv[1]
    refs = collections.defaultdict(lambda: {"count": 0, "workflows": set()})
    wf_count = 0
    for fname, wf in iter_workflows(src):
        wf_count += 1
        wname = wf.get("name", fname)
        for node in wf.get("nodes", []):
            creds = node.get("credentials") or {}
            for ctype, cval in creds.items():
                if not isinstance(cval, dict):
                    continue
                extra = set(cval.keys()) - {"id", "name"}
                if extra:
                    sys.exit(f"ABORT: credential reference in {fname} has unexpected "
                             f"field(s) {sorted(extra)} — refusing to print (possible secret).")
                key = (ctype, cval.get("name"), cval.get("id"))
                refs[key]["count"] += 1
                refs[key]["workflows"].add(wname)
    print(f"# scanned {wf_count} workflow(s); {len(refs)} distinct credential reference(s)\n")
    print(f"{'type':28} {'name':30} {'id':20} node-uses  workflows")
    print("-" * 100)
    for (ctype, name, cid), meta in sorted(refs.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
        print(f"{str(ctype):28} {str(name):30} {str(cid):20} {meta['count']:<9} {len(meta['workflows'])}")
    print(f"\nDISTINCT_CREDENTIAL_REFERENCES={len(refs)}")


if __name__ == "__main__":
    main()
