#!/usr/bin/env python3
"""Assess n8n credential-recovery READINESS from workflow exports — no secrets, no network.

For every distinct credential REFERENCE in the exports (type, name, id + any n8n
metadata flags such as __aiGatewayManaged), this tool reports whether recovery is
ready, giving a PASS / PARTIAL / BLOCKED verdict and flagging exactly which
credentials need the operator's manual action. It never prints a secret value,
never contacts a provider, never modifies anything (read-only).

Readiness dimensions (all offline):
  * production      : referenced by at least one ACTIVE (active==true) workflow
  * type_available  : the credential TYPE is hostable by the target n8n (checked
                      against a committed credential-type registry file)
  * documented      : the credential name OR type appears in SECRETS-RECOVERY.md
                      (a recreation source is on record)
  * mechanism       : key          -> operator recreates key/token and pastes it
                      oauth2        -> interactive OAuth reconnect (MANUAL)
                      shared-secret -> regenerate + set on BOTH sides (MANUAL)
                      ai-gateway    -> n8n-managed credit credential (MANUAL decision)

Status per credential:
  READY   : type_available AND documented AND mechanism == key
  MANUAL  : type_available AND documented but mechanism needs operator interaction
  BLOCKED : type not hostable (node install needed) OR no documented recovery source

Overall: BLOCKED if any BLOCKED; else PARTIAL if any MANUAL; else PASS.

Usage:
  python3 -I dr_n8n_credential_readiness.py --exports <dir> \
      [--cred-types dr/n8n/n8n-2.44.7-credential-types.txt] \
      [--secrets-doc dr/runbook/SECRETS-RECOVERY.md] [--report <out.md>]
"""
import argparse
import collections
import json
import os
import sys

# credential TYPEs whose recovery is an interactive OAuth reconnect
SHARED_SECRET_TYPES = {"httpHeaderAuth"}  # shared secret set on both sides (edge <-> n8n)


def mechanism(ctype, flags):
    if "__aiGatewayManaged" in flags:
        return "ai-gateway"
    if "oauth2" in ctype.lower():
        return "oauth2"
    if ctype in SHARED_SECRET_TYPES:
        return "shared-secret"
    return "key"


def iter_workflows(path):
    files = ([path] if os.path.isfile(path)
             else [os.path.join(path, f) for f in sorted(os.listdir(path)) if f.endswith(".json")])
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
    ap.add_argument("--exports", required=True)
    here = os.path.dirname(os.path.abspath(__file__))     # <repo>/scripts/dr
    repo = os.path.dirname(os.path.dirname(here))         # <repo>
    ap.add_argument("--cred-types", default=os.path.join(repo, "dr/n8n/n8n-2.44.7-credential-types.txt"))
    ap.add_argument("--docs", default=",".join([
        os.path.join(repo, "dr/runbook/SECRETS-RECOVERY.md"),
        os.path.join(repo, "dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md"),
    ]), help="comma-separated recovery docs used for the coverage check")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    known_types = set()
    if os.path.isfile(args.cred_types):
        for line in open(args.cred_types, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                known_types.add(line)
    secrets_text = ""
    for doc in args.docs.split(","):
        doc = doc.strip()
        if doc and os.path.isfile(doc):
            secrets_text += "\n" + open(doc, encoding="utf-8").read()

    refs = collections.defaultdict(lambda: {"ids": set(), "nodes": 0, "wf": set(),
                                            "active_wf": set(), "flags": set()})
    wf_total = wf_active = 0
    for fname, wf in iter_workflows(args.exports):
        wf_total += 1
        active = bool(wf.get("active"))
        wf_active += active
        wname = wf.get("name", fname)
        for node in wf.get("nodes", []):
            for ctype, cval in (node.get("credentials") or {}).items():
                if not isinstance(cval, dict):
                    continue
                r = refs[(ctype, cval.get("name"))]
                r["ids"].add(cval.get("id"))
                r["nodes"] += 1
                r["wf"].add(wname)
                if active:
                    r["active_wf"].add(wname)
                for k in cval:
                    if k not in ("id", "name"):
                        r["flags"].add(k)

    rows = []
    for (ctype, name), r in sorted(refs.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
        mech = mechanism(ctype, r["flags"])
        available = (ctype in known_types) if known_types else None
        documented = bool(name and name in secrets_text) or (ctype in secrets_text)
        if available is False or not documented:
            status = "BLOCKED"
        elif mech in ("oauth2", "shared-secret", "ai-gateway"):
            status = "MANUAL"
        else:
            status = "READY"
        rows.append({
            "type": ctype, "name": name, "mech": mech,
            "available": available, "documented": documented,
            "production": bool(r["active_wf"]),
            "nodes": r["nodes"], "wf": len(r["wf"]), "active_wf": len(r["active_wf"]),
            "flags": sorted(r["flags"]), "status": status,
        })

    any_blocked = any(x["status"] == "BLOCKED" for x in rows)
    any_manual = any(x["status"] == "MANUAL" for x in rows)
    overall = "BLOCKED" if any_blocked else ("PARTIAL" if any_manual else "PASS")

    def av(x):
        return "?" if x["available"] is None else ("yes" if x["available"] else "NO")

    print(f"credential-recovery readiness  (exports={args.exports})")
    print(f"workflows scanned={wf_total} active={wf_active} | distinct credential refs={len(rows)}\n")
    print(f"{'status':8} {'prod':5} {'type':22} {'name':30} {'mech':13} avail doc")
    print("-" * 100)
    for x in rows:
        print(f"{x['status']:8} {'YES' if x['production'] else '-':5} {x['type']:22} "
              f"{str(x['name']):30} {x['mech']:13} {av(x):5} {'yes' if x['documented'] else 'NO'}")
    manual = [x for x in rows if x["status"] == "MANUAL"]
    blocked = [x for x in rows if x["status"] == "BLOCKED"]
    if manual:
        print("\nREQUIRES MANUAL ACTION:")
        for x in manual:
            why = {"oauth2": "interactive OAuth reconnect",
                   "shared-secret": "regenerate shared secret + set on both sides",
                   "ai-gateway": "n8n-managed credit credential — supply own key or enable AI gateway"}[x["mech"]]
            print(f"  - {x['type']} \"{x['name']}\": {why}")
    if blocked:
        print("\nBLOCKED:")
        for x in blocked:
            reason = "credential type not hostable by target n8n" if x["available"] is False \
                     else "no documented recovery source in SECRETS-RECOVERY.md"
            print(f"  - {x['type']} \"{x['name']}\": {reason}")
    print(f"\nOVERALL READINESS: {overall}")

    if args.report:
        with open(args.report, "w", encoding="utf-8") as rp:
            rp.write("# n8n credential-recovery readiness result\n\n")
            rp.write(f"- Exports: `{args.exports}`\n")
            rp.write(f"- Workflows scanned: {wf_total} (active: {wf_active}); distinct credential refs: {len(rows)}\n")
            rp.write(f"- Credential-type registry: `{args.cred_types}` ({len(known_types)} types)\n\n")
            rp.write(f"## Overall readiness: **{overall}**\n\n")
            rp.write("| Status | Production | Type | Name | Mechanism | Type hostable | Documented |\n")
            rp.write("|---|---|---|---|---|---|---|\n")
            for x in rows:
                rp.write(f"| {x['status']} | {'yes' if x['production'] else '-'} | `{x['type']}` | "
                         f"{x['name']} | {x['mech']} | {av(x)} | {'yes' if x['documented'] else 'NO'} |\n")
            if manual:
                rp.write("\n### Requires manual action\n")
                for x in manual:
                    rp.write(f"- `{x['type']}` \"{x['name']}\" — {x['mech']}\n")
            if blocked:
                rp.write("\n### Blocked\n")
                for x in blocked:
                    rp.write(f"- `{x['type']}` \"{x['name']}\"\n")
        print(f"\nreport written: {args.report}")

    sys.exit(0 if overall == "PASS" else (1 if overall == "PARTIAL" else 2))


if __name__ == "__main__":
    main()
