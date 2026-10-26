#!/usr/bin/env python3
"""Enumerate n8n credential REFERENCES across workflow export JSONs (no values).

n8n exports carry credential *references* only — a per-node object with `id`,
`name`, and sometimes n8n metadata flags such as `__aiGatewayManaged` (set on
credentials served through n8n's AI gateway / managed AI credits). Secret VALUES
are never stored on nodes; they live encrypted in `credentials_entity`. This tool
lists the distinct (type, name, id) references and how many nodes/workflows use
each, so an operator can plan credential recovery (recreate each credential per
dr/runbook/SECRETS-RECOVERY.md, then re-bind).

Safety invariant: ONLY `id` and `name` (labels/reference ids, not secrets) and the
NAMES of metadata flag keys are ever printed — never a value. Metadata flag keys
(e.g. `__aiGatewayManaged`, or any `__`-prefixed key) are supported and surfaced
by name. If a credential reference ever carried a key whose NAME indicates a secret
payload (data/value/secret/token/password/apiKey/accessToken/oauthTokenData), the
tool treats that as a credential-inspection FAILURE and exits non-zero WITHOUT
printing the value, so a caller gating on exit status halts. Unparseable exports
are likewise a non-zero failure. Run with -I against (untrusted) export directories.

Usage:
    python3 -I dr_n8n_credential_refs.py <export-dir-or-file>

Exit output ends with `DISTINCT_CREDENTIAL_REFERENCES=<n>`; exit code 0 on success,
non-zero if credential inspection fails.
"""
import collections
import json
import os
import sys

# Key names that would indicate an actual secret payload embedded on a node (never
# expected in a legitimate n8n export). Presence => inspection failure, no value printed.
SECRET_KEY_NAMES = {
    "data", "value", "secret", "token", "password", "apikey", "accesstoken",
    "oauthtokendata", "clientsecret", "privatekey", "sessiontoken",
}


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
            # genuine inspection failure -> non-zero so a gating caller stops
            sys.exit(f"ABORT: cannot read/parse export {os.path.basename(f)}: {e}")
        for wf in (data if isinstance(data, list) else [data]):
            if isinstance(wf, dict) and "nodes" in wf:
                yield os.path.basename(f), wf


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 -I dr_n8n_credential_refs.py <export-dir-or-file>")
    src = sys.argv[1]
    refs = collections.defaultdict(lambda: {"count": 0, "workflows": set(), "flags": set()})
    wf_count = 0
    for fname, wf in iter_workflows(src):
        wf_count += 1
        wname = wf.get("name", fname)
        for node in wf.get("nodes", []):
            creds = node.get("credentials") or {}
            for ctype, cval in creds.items():
                if not isinstance(cval, dict):
                    continue
                # Guard: a key NAME indicating an embedded secret is anomalous -> fail
                # closed (never print the value), so a gating caller halts the restore.
                suspicious = sorted(k for k in cval
                                    if k.lower() in SECRET_KEY_NAMES)
                if suspicious:
                    sys.exit(f"ABORT: credential reference in {fname} (type {ctype}) carries "
                             f"secret-shaped field(s) {suspicious} — refusing to inspect; "
                             f"credential inspection FAILED (no value printed).")
                # Only id and name are emitted; every other key is a metadata flag,
                # recorded by NAME ONLY (never its value).
                key = (ctype, cval.get("name"), cval.get("id"))
                refs[key]["count"] += 1
                refs[key]["workflows"].add(wname)
                for k in cval:
                    if k not in ("id", "name"):
                        refs[key]["flags"].add(k)
    print(f"# scanned {wf_count} workflow(s); {len(refs)} distinct credential reference(s)\n")
    print(f"{'type':28} {'name':30} {'id':20} node-uses  workflows  flags")
    print("-" * 110)
    for (ctype, name, cid), meta in sorted(refs.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
        flags = ",".join(sorted(meta["flags"])) or "-"
        print(f"{str(ctype):28} {str(name):30} {str(cid):20} "
              f"{meta['count']:<9} {len(meta['workflows']):<9} {flags}")
    print(f"\nDISTINCT_CREDENTIAL_REFERENCES={len(refs)}")


if __name__ == "__main__":
    main()
