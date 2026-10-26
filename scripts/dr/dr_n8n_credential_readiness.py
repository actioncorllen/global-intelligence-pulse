#!/usr/bin/env python3
"""Assess n8n credential-recovery READINESS from workflow exports — no secrets, no network.

For every distinct credential REFERENCE in the exports (type, name, id + any n8n
metadata flags such as __aiGatewayManaged) this tool reports, per credential:

  * usage   : active-production / inactive / archived  (from each referencing
              workflow's active + isArchived flags; active wins, then inactive, then archived)
  * scope   : in-scope / out-of-scope  (whether any referencing workflow id is in the
              Strateloq inventory allowlist; without an allowlist, scope = unknown)
  * type hostable : credential TYPE exists in the target n8n (committed registry)
  * documented    : credential name OR type appears in the recovery docs
  * mechanism     : key / oauth2 / shared-secret / ai-gateway  (drives the MANUAL flag)

Status per credential:
  READY   : hostable + documented + key
  MANUAL  : hostable + documented but needs an interactive/both-sides step
  BLOCKED : a REQUIRED Strateloq source is unknown — undocumented or type-not-hostable
            for an in-scope (or scope-unknown) credential
  FOREIGN : undocumented/not-hostable but belongs ONLY to out-of-scope (co-resident,
            non-Strateloq) workflows — not a Strateloq recovery item

Scope-aware verdict (over in-scope + scope-unknown credentials; FOREIGN excluded):
  BLOCKED if any such credential is BLOCKED; else PARTIAL if any MANUAL; else PASS.
BLOCKED is kept wherever a required recovery source remains unknown — the tool never
invents a source. It never prints a secret value, contacts a provider, or modifies
anything (read-only).

Usage:
  python3 -I dr_n8n_credential_readiness.py --exports <dir> \
      [--strateloq-ids dr/n8n/strateloq-workflow-ids.txt] \
      [--cred-types dr/n8n/n8n-2.44.7-credential-types.txt] \
      [--docs <SECRETS-RECOVERY.md,N8N-CREDENTIAL-RECOVERY-PLAN.md>] [--report <out.md>]
"""
import argparse
import collections
import json
import os
import sys

SHARED_SECRET_TYPES = {"httpHeaderAuth"}  # shared secret set on both sides (edge <-> n8n)


def mechanism(ctype, flags):
    if "__aiGatewayManaged" in flags:
        return "ai-gateway"
    if "oauth2" in ctype.lower():
        return "oauth2"
    if ctype in SHARED_SECRET_TYPES:
        return "shared-secret"
    return "key"


def workflow_state(wf):
    if wf.get("isArchived"):
        return "archived"
    return "active" if wf.get("active") else "inactive"


def load_lines(path):
    out = set()
    if path and os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line)
    return out


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


def primary_usage(states):
    for s in ("active-production", "inactive", "archived"):
        key = "active" if s == "active-production" else s
        if key in states:
            return s
    return "unused"


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))     # <repo>/scripts/dr
    repo = os.path.dirname(os.path.dirname(here))         # <repo>
    ap.add_argument("--exports", required=True)
    ap.add_argument("--strateloq-ids", default=os.path.join(repo, "dr/n8n/strateloq-workflow-ids.txt"),
                    help="allowlist of in-scope Strateloq workflow ids; '' to disable scope split")
    ap.add_argument("--cred-types", default=os.path.join(repo, "dr/n8n/n8n-2.44.7-credential-types.txt"))
    ap.add_argument("--docs", default=",".join([
        os.path.join(repo, "dr/runbook/SECRETS-RECOVERY.md"),
        os.path.join(repo, "dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md"),
    ]), help="comma-separated recovery docs used for the coverage check")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    known_types = load_lines(args.cred_types)
    allow = load_lines(args.strateloq_ids)
    have_scope = bool(allow)
    secrets_text = ""
    for doc in args.docs.split(","):
        doc = doc.strip()
        if doc and os.path.isfile(doc):
            secrets_text += "\n" + open(doc, encoding="utf-8").read()

    refs = collections.defaultdict(lambda: {"states": set(), "in_scope": False, "out_scope": False,
                                            "nodes": 0, "wf": set(), "flags": set()})
    counts = collections.Counter()
    wf_total = 0
    for fname, wf in iter_workflows(args.exports):
        wf_total += 1
        state = workflow_state(wf)
        counts[state] += 1
        in_scope = (wf.get("id") in allow) if have_scope else None
        for node in wf.get("nodes", []):
            for ctype, cval in (node.get("credentials") or {}).items():
                if not isinstance(cval, dict):
                    continue
                r = refs[(ctype, cval.get("name"))]
                r["states"].add(state)
                r["nodes"] += 1
                r["wf"].add(wf.get("id") or fname)
                if in_scope is True:
                    r["in_scope"] = True
                elif in_scope is False:
                    r["out_scope"] = True
                for k in cval:
                    if k not in ("id", "name"):
                        r["flags"].add(k)

    rows = []
    for (ctype, name), r in sorted(refs.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
        mech = mechanism(ctype, r["flags"])
        available = (ctype in known_types) if known_types else None
        documented = bool(name and name in secrets_text) or (ctype in secrets_text)
        usage = primary_usage(r["states"])
        if not have_scope:
            scope = "unknown"
        elif r["in_scope"]:
            scope = "in-scope"
        else:
            scope = "out-of-scope"
        unhostable = available is False
        if documented and not unhostable:
            status = "READY" if mech == "key" else "MANUAL"
        else:
            # undocumented, or type not hostable -> required source/host unknown
            status = "FOREIGN" if scope == "out-of-scope" else "BLOCKED"
        rows.append({
            "type": ctype, "name": name, "mech": mech, "usage": usage, "scope": scope,
            "available": available, "documented": documented, "status": status,
            "nodes": r["nodes"], "wf": len(r["wf"]),
        })

    # scope-aware verdict over Strateloq-relevant creds (exclude FOREIGN)
    relevant = [x for x in rows if x["status"] != "FOREIGN"]
    verdict = ("BLOCKED" if any(x["status"] == "BLOCKED" for x in relevant)
               else "PARTIAL" if any(x["status"] == "MANUAL" for x in relevant) else "PASS")

    def av(x):
        return "?" if x["available"] is None else ("yes" if x["available"] else "NO")

    print(f"credential-recovery readiness  (exports={args.exports})")
    print(f"workflows scanned={wf_total}  (active={counts['active']} inactive={counts['inactive']} "
          f"archived={counts['archived']}) | distinct credential refs={len(rows)} | "
          f"scope split={'on' if have_scope else 'off'}\n")
    hdr = f"{'status':8} {'usage':17} {'scope':12} {'type':22} {'name':28} {'mech':13} host doc"
    print(hdr); print("-" * len(hdr))
    for x in sorted(rows, key=lambda y: (y["status"], y["type"])):
        print(f"{x['status']:8} {x['usage']:17} {x['scope']:12} {x['type']:22} "
              f"{str(x['name']):28} {x['mech']:13} {av(x):4} {'yes' if x['documented'] else 'NO'}")

    def group(st):
        return [x for x in rows if x["status"] == st]

    if group("BLOCKED"):
        print("\nBLOCKED — required Strateloq recovery source unknown (keep BLOCKED; supply source, do NOT invent):")
        for x in group("BLOCKED"):
            why = "type not hostable (node install)" if x["available"] is False else "no documented recovery source"
            print(f"  - [{x['usage']}] {x['type']} \"{x['name']}\": {why}")
    if group("MANUAL"):
        print("\nMANUAL — ready but needs your interactive action:")
        for x in group("MANUAL"):
            why = {"oauth2": "interactive OAuth reconnect",
                   "shared-secret": "regenerate shared secret + set on both sides",
                   "ai-gateway": "n8n-managed credit credential — supply own key or enable AI gateway"}.get(x["mech"], x["mech"])
            print(f"  - [{x['usage']}] {x['type']} \"{x['name']}\": {why}")
    if group("FOREIGN"):
        print("\nFOREIGN — out-of-scope (co-resident non-Strateloq workflows); not a Strateloq recovery item:")
        for x in group("FOREIGN"):
            print(f"  - [{x['usage']}] {x['type']} \"{x['name']}\"")

    print(f"\nSTRATELOQ-SCOPED READINESS: {verdict}"
          + (f"   (+{len(group('FOREIGN'))} foreign out-of-scope credential(s) excluded)" if group("FOREIGN") else ""))

    if args.report:
        with open(args.report, "w", encoding="utf-8") as rp:
            rp.write("# n8n credential-recovery readiness result\n\n")
            rp.write(f"- Exports: `{args.exports}`\n")
            rp.write(f"- Workflows: {wf_total} (active {counts['active']}, inactive {counts['inactive']}, "
                     f"archived {counts['archived']}); distinct credential refs: {len(rows)}\n")
            rp.write(f"- Scope split: {'on' if have_scope else 'off'}; credential-type registry: "
                     f"{len(known_types)} types\n\n")
            rp.write(f"## Strateloq-scoped readiness: **{verdict}**")
            if group("FOREIGN"):
                rp.write(f"  (+{len(group('FOREIGN'))} foreign out-of-scope excluded)")
            rp.write("\n\n| Status | Usage | Scope | Type | Name | Mechanism | Hostable | Documented |\n")
            rp.write("|---|---|---|---|---|---|---|---|\n")
            for x in sorted(rows, key=lambda y: (y["status"], y["type"])):
                rp.write(f"| {x['status']} | {x['usage']} | {x['scope']} | `{x['type']}` | {x['name']} | "
                         f"{x['mech']} | {av(x)} | {'yes' if x['documented'] else 'NO'} |\n")
        print(f"\nreport written: {args.report}")

    sys.exit(0 if verdict == "PASS" else (1 if verdict == "PARTIAL" else 2))


if __name__ == "__main__":
    main()
