#!/usr/bin/env python3
"""Sanitize n8n workflow export(s) into import-safe, INACTIVE definitions.

Purpose
-------
Restoring real Strateloq workflow exports through the n8n CLI (n8n 2.44.7,
SQLite) fails with `SQLITE_CONSTRAINT: FOREIGN KEY constraint failed` the moment
n8n tries to DEACTIVATE a workflow whose `activeVersionId` points at a
`workflow_history` version that is not present in the target DB (a "dangling
active version"). See dr/n8n/N8N-RESTORE-VALIDATION-001.md for the full
root-cause analysis and reproduction.

This tool removes the trigger for that path: it rewrites every export to a
minimal, import-safe shape with `active=false` and with all version/publication
metadata stripped, so the n8n importer never enters the deactivation / publish
teardown that trips the foreign key. The workflow's functional definition
(id, name, nodes, connections, settings, staticData) is preserved exactly, so
nodes, connections and credential *references* survive unchanged.

Credential handling: n8n exports never contain secret VALUES, only references
{id,name}. Those references are preserved on purpose (they are re-bound after
the credentials are recreated per dr/runbook/SECRETS-RECOVERY.md). No secret
value is ever read or written by this tool.

Usage (run with -I so a planted module in the export dir cannot be imported):
    python3 -I dr_n8n_sanitize.py <src-export-dir> <dst-sanitized-dir>

Source files are never modified; sanitized copies are written to <dst>.
"""
import json
import os
import sys

# Fields that carry the functional definition and are safe/needed for import.
KEEP = ("id", "name", "nodes", "connections", "settings", "staticData")


def sanitize(wf):
    if not isinstance(wf, dict) or "nodes" not in wf or "connections" not in wf:
        raise ValueError("not a valid workflow object (missing nodes/connections)")
    out = {k: wf[k] for k in KEEP if k in wf and wf[k] is not None}
    out["name"] = wf.get("name") or "Unnamed workflow"
    # Force inactive: a workflow imported with active=false and no activeVersionId
    # never enters n8n's deactivateWorkflow()/_unpublishViaOutbox() teardown, so the
    # workflow_publish_history.versionId -> workflow_history FK is never exercised.
    out["active"] = False
    out.setdefault("settings", {})
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: python3 -I dr_n8n_sanitize.py <src-export-dir> <dst-sanitized-dir>")
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    n = 0
    for fn in sorted(os.listdir(src)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(src, fn), encoding="utf-8") as fh:
            data = json.load(fh)
        items = data if isinstance(data, list) else [data]
        for i, wf in enumerate(items):
            clean = sanitize(wf)
            base = fn[:-5]
            outname = f"{base}.json" if len(items) == 1 else f"{base}__{i}.json"
            with open(os.path.join(dst, outname), "w", encoding="utf-8") as fh:
                json.dump(clean, fh, ensure_ascii=False, indent=2)
            n += 1
    print(f"sanitized {n} workflow(s) -> {dst}")


if __name__ == "__main__":
    main()
