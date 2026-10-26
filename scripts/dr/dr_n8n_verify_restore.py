#!/usr/bin/env python3
"""Verify an n8n DR restore against its source exports and emit a PASS/FAIL report.

Compares every workflow export in --exports against the restored SQLite DB in
--data/database.sqlite and checks, with evidence:

  1. Count         : distinct workflow IDs in exports == workflows in DB
  2. Name          : each restored workflow name matches its source export
  3. Nodes         : node count + the multiset of (name, type) match
  4. Connections   : the multiset of edges (sourceNode -> targetNode) matches
  5. Inactive      : every restored workflow has active=0 and activeVersionId IS NULL
  6. DB integrity  : PRAGMA integrity_check == 'ok' and PRAGMA foreign_key_check empty
  7. Archive       : source export dir is inventoried (file count + SHA-256 manifest)
                     as evidence the originals are intact (the restore never writes
                     into --exports)

Read-only: it opens the DB read-only and never modifies exports. Run with -I.

Usage:
    python3 -I dr_n8n_verify_restore.py --exports <dir> --data <restore-data-dir> \
        [--expect 133] [--report <out.md>]

Exit code 0 only if every check PASSes.
"""
import argparse
import collections
import hashlib
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone


def load_exports(src):
    """Return {id: {...}} and a list of (filename, issue) problems."""
    wfs = {}
    problems = []
    files = sorted(f for f in os.listdir(src) if f.endswith(".json"))
    for fn in files:
        path = os.path.join(src, fn)
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception as e:  # noqa: BLE001
            problems.append((fn, f"unreadable JSON: {e}"))
            continue
        items = data if isinstance(data, list) else [data]
        for wf in items:
            if not isinstance(wf, dict) or "nodes" not in wf or "connections" not in wf:
                problems.append((fn, "not a workflow object (missing nodes/connections)"))
                continue
            wid = wf.get("id")
            if not wid:
                problems.append((fn, "export has no id (cannot match to restored row)"))
                continue
            if wid in wfs:
                problems.append((fn, f"duplicate workflow id {wid} (also in {wfs[wid]['file']})"))
            wfs[wid] = {
                "file": fn,
                "name": wf.get("name"),
                "nodes": node_sig(wf.get("nodes", [])),
                "node_count": len(wf.get("nodes", [])),
                "edges": edge_sig(wf.get("connections", {})),
            }
    return wfs, problems, files


def node_sig(nodes):
    return collections.Counter((n.get("name"), n.get("type")) for n in nodes)


def edge_sig(connections):
    """Multiset of (source, outputType, target) over the connection graph."""
    edges = collections.Counter()
    for src, outs in (connections or {}).items():
        if not isinstance(outs, dict):
            continue
        for out_type, branches in outs.items():
            for branch in branches or []:
                for link in branch or []:
                    if isinstance(link, dict):
                        edges[(src, out_type, link.get("node"))] += 1
    return edges


def load_db(db_path):
    uri = f"file:{db_path}?mode=ro"
    c = sqlite3.connect(uri, uri=True)
    cur = c.cursor()
    rows = {}
    for id_, name, active, avid, nodes, conns in cur.execute(
        "select id,name,active,activeVersionId,nodes,connections from workflow_entity"
    ):
        nn = json.loads(nodes or "[]")
        cn = json.loads(conns or "{}")
        rows[id_] = {
            "name": name,
            "active": active,
            "activeVersionId": avid,
            "nodes": node_sig(nn),
            "node_count": len(nn),
            "edges": edge_sig(cn),
        }
    integrity = cur.execute("PRAGMA integrity_check").fetchall()
    fk = cur.execute("PRAGMA foreign_key_check").fetchall()
    c.close()
    return rows, integrity, fk


def sha256_manifest(src, files):
    h = hashlib.sha256()
    per = []
    for fn in files:
        d = open(os.path.join(src, fn), "rb").read()
        fh = hashlib.sha256(d).hexdigest()
        per.append((fn, len(d), fh))
        h.update(fn.encode())
        h.update(fh.encode())
    return h.hexdigest(), per


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exports", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--expect", type=int, default=None, help="expected workflow count (e.g. 133)")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    db_path = os.path.join(args.data, "database.sqlite")
    if not os.path.isfile(db_path):
        sys.exit(f"restore DB not found: {db_path}")

    src_wfs, problems, files = load_exports(args.exports)
    db_wfs, integrity, fk = load_db(db_path)
    manifest_hash, per_file = sha256_manifest(args.exports, files)

    checks = []  # (name, passed, detail)

    # 1. count
    n_src, n_db = len(src_wfs), len(db_wfs)
    count_ok = (n_src == n_db) and (args.expect is None or n_db == args.expect)
    exp = "" if args.expect is None else f"; expected={args.expect}"
    checks.append(("count", count_ok,
                   f"source distinct ids={n_src}; restored={n_db}{exp}"))

    # 2-4. per-workflow name/nodes/connections
    name_bad, node_bad, edge_bad, missing = [], [], [], []
    for wid, s in src_wfs.items():
        d = db_wfs.get(wid)
        if d is None:
            missing.append(f"{wid} ({s['file']})")
            continue
        if s["name"] != d["name"]:
            name_bad.append(f"{wid}: export={s['name']!r} db={d['name']!r}")
        if s["nodes"] != d["nodes"]:
            node_bad.append(f"{wid}: node (name,type) multiset differs "
                            f"(export {s['node_count']} / db {d['node_count']})")
        if s["edges"] != d["edges"]:
            edge_bad.append(f"{wid}: connection edges differ")
    extra = [wid for wid in db_wfs if wid not in src_wfs]
    checks.append(("names_match", not name_bad and not missing,
                   "all names match" if not name_bad and not missing
                   else f"{len(name_bad)} mismatch, {len(missing)} missing"))
    checks.append(("nodes_match", not node_bad and not missing,
                   "all node sets match" if not node_bad and not missing
                   else f"{len(node_bad)} differ, {len(missing)} missing"))
    checks.append(("connections_match", not edge_bad and not missing,
                   "all connection graphs match" if not edge_bad and not missing
                   else f"{len(edge_bad)} differ, {len(missing)} missing"))

    # 5. inactive
    active_bad = [wid for wid, d in db_wfs.items()
                  if d["active"] not in (0, False) or d["activeVersionId"] is not None]
    checks.append(("all_inactive", not active_bad,
                   "every workflow inactive, no activeVersionId"
                   if not active_bad else f"{len(active_bad)} active/with activeVersionId"))

    # 6. DB integrity
    integ_ok = (len(integrity) == 1 and integrity[0][0] == "ok") and len(fk) == 0
    checks.append(("db_integrity", integ_ok,
                   f"integrity_check={integrity}; foreign_key_check rows={len(fk)}"))

    # 7. archive inventory (evidence originals are intact; restore never writes here)
    checks.append(("archive_inventory", True,
                   f"{len(files)} export file(s); manifest SHA-256={manifest_hash}"))

    # export-parse problems are failures if present
    checks.append(("export_parse", not problems,
                   "all exports parsed" if not problems else f"{len(problems)} problem(s)"))

    overall = all(p for _, p, _ in checks)

    # ---- console ----
    print(f"n8n DR restore verification  ({datetime.now(timezone.utc).isoformat(timespec='seconds')})")
    print(f"exports={args.exports}")
    print(f"restore DB={db_path}\n")
    for name, passed, detail in checks:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name:20} {detail}")
    if missing:
        print("\n  MISSING (in export, not restored):")
        for m in missing[:50]:
            print("    -", m)
    if extra:
        print("\n  EXTRA (restored, not in exports):")
        for m in extra[:50]:
            print("    -", m)
    for label, lst in (("NAME", name_bad), ("NODES", node_bad), ("EDGES", edge_bad)):
        for m in lst[:50]:
            print(f"  {label}: {m}")
    for fn, issue in problems[:50]:
        print(f"  EXPORT-PROBLEM: {fn}: {issue}")
    print(f"\nOVERALL: {'PASS' if overall else 'FAIL'}")

    # ---- markdown report ----
    if args.report:
        with open(args.report, "w", encoding="utf-8") as r:
            r.write(f"# Strateloq DR — n8n restore verification result\n\n")
            r.write(f"- Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}\n")
            r.write(f"- Exports: `{args.exports}`\n- Restore DB: `{db_path}`\n")
            r.write(f"- Source export files: {len(files)} | distinct workflow ids: {n_src} | "
                    f"restored workflows: {n_db}\n")
            r.write(f"- Source archive manifest SHA-256: `{manifest_hash}`\n\n")
            r.write(f"## Result: **{'PASS' if overall else 'FAIL'}**\n\n")
            r.write("| Check | Result | Detail |\n|---|---|---|\n")
            for name, passed, detail in checks:
                r.write(f"| {name} | {'✅ PASS' if passed else '❌ FAIL'} | {detail} |\n")
            if missing or extra or name_bad or node_bad or edge_bad or problems:
                r.write("\n## Discrepancies\n\n")
                for m in missing:
                    r.write(f"- MISSING (not restored): `{m}`\n")
                for m in extra:
                    r.write(f"- EXTRA (not in exports): `{m}`\n")
                for m in name_bad:
                    r.write(f"- NAME: {m}\n")
                for m in node_bad:
                    r.write(f"- NODES: {m}\n")
                for m in edge_bad:
                    r.write(f"- EDGES: {m}\n")
                for fn, issue in problems:
                    r.write(f"- EXPORT-PROBLEM: `{fn}`: {issue}\n")
            else:
                r.write("\nNo discrepancies: every restored workflow matches its source export "
                        "(name, nodes, connections), all inactive, DB integrity clean.\n")
        print(f"\nreport written: {args.report}")

    sys.exit(0 if overall else 1)


if __name__ == "__main__":
    main()
