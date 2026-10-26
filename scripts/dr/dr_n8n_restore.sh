#!/usr/bin/env bash
# Strateloq DR — n8n workflow RESTORE into an isolated local instance (€0, offline).
#
# Restores n8n workflow DEFINITIONS from JSON exports into a disposable, isolated
# n8n instance (Docker, n8n 2.44.7, SQLite) with EXECUTION and EXTERNAL ACCESS
# DISABLED. This is a verification / disaster-recovery restore, not a production
# cutover: workflows are restored INACTIVE and are never activated or connected
# to any provider.
#
# Why this exists
# ---------------
# Importing real (active) workflow exports straight through `n8n import:workflow`
# fails with:
#     SQLITE_CONSTRAINT: FOREIGN KEY constraint failed
# as soon as n8n tries to DEACTIVATE a workflow whose activeVersionId points at a
# workflow_history version that is not present in the target DB. Editing the JSON
# (clearing ids/version) does NOT help — n8n reads activeVersionId from the
# EXISTING DB row, not the JSON — and `--activeState=fromJson` only works in
# queue/multi-main mode. Full root cause + reproduction + evidence:
#     dr/n8n/N8N-RESTORE-VALIDATION-001.md
#
# The fix implemented here:
#   1. SANITIZE every export to active=false with version/publication metadata
#      stripped (dr_n8n_sanitize.py) so the importer never enters the
#      deactivation/publish teardown that trips the FK.
#   2. Import into a FRESH data dir (owner + personal project are auto-seeded by
#      migrations), or --repair an instance already polluted by earlier attempts
#      (null out dangling active versions + clear stale publication rows).
#   3. Import OFFLINE (--network none), telemetry/diagnostics OFF, never activate.
#
# Non-destructive: source exports are read-only and never modified.
#
# Usage:
#   dr_n8n_restore.sh --exports <dir> [--data <dir>] [--image <img>] [--repair] [--verify-only]
#
#   --exports DIR    directory of n8n workflow export JSONs (read-only)
#   --data DIR       data dir for the isolated restore instance
#                    (default: ./n8n-restore-data)
#   --image IMG      n8n image (default: n8nio/n8n:2.44.7)
#   --repair         repair a pre-existing --data DB before import (recovers an
#                    instance left in the FK-failing state by earlier attempts)
#   --verify-only    skip import; just list what is already in --data
#
# Requirements: docker, python3. The restore instance never needs network.
set -euo pipefail

IMAGE="n8nio/n8n:2.44.7"
DATA="./n8n-restore-data"
EXPORTS=""
REPAIR=0
VERIFY_ONLY=0
HERE="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --exports) EXPORTS="$2"; shift 2;;
    --data) DATA="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --repair) REPAIR=1; shift;;
    --verify-only) VERIFY_ONLY=1; shift;;
    -h|--help) sed -n '1,45p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

mkdir -p "$DATA"
DATA_ABS="$(cd "$DATA" && pwd)"

# Make the data dir writable by the container's node user (uid 1000).
if [ "$(id -u)" = "0" ]; then
  chown -R 1000:1000 "$DATA_ABS" 2>/dev/null || true
else
  chmod -R a+rwX "$DATA_ABS" 2>/dev/null || true
fi

# Isolation env: no telemetry, no version checks, no templates, no onboarding,
# IPv4 listen (some hosts lack IPv6). Workflows are imported inactive; the CLI
# import never opens a port and we run it with --network none.
ISO_ENV=(
  -e N8N_DIAGNOSTICS_ENABLED=false
  -e N8N_VERSION_NOTIFICATIONS_ENABLED=false
  -e N8N_TEMPLATES_ENABLED=false
  -e N8N_PERSONALIZATION_ENABLED=false
  -e N8N_ONBOARDING_FLOW_DISABLED=true
  -e EXTERNAL_FRONTEND_HOOKS_URLS=
  -e N8N_LISTEN_ADDRESS=0.0.0.0
  -e GENERIC_TIMEZONE=UTC
)

run_n8n() {  # run_n8n <extra -v mounts...> -- <n8n args...>
  local mounts=() ; while [ "$1" != "--" ]; do mounts+=("$1"); shift; done; shift
  docker run --rm --network none "${ISO_ENV[@]}" \
    -v "$DATA_ABS:/home/node/.n8n" "${mounts[@]}" "$IMAGE" "$@"
}

if [ "$VERIFY_ONLY" = 1 ]; then
  echo "== workflows currently in $DATA_ABS =="
  run_n8n -- list:workflow
  exit 0
fi

[ -n "$EXPORTS" ] || { echo "--exports is required" >&2; exit 2; }
[ -d "$EXPORTS" ] || { echo "--exports dir not found: $EXPORTS" >&2; exit 2; }

# 1) Sanitize (never touches the source exports).
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SAN="$WORK/sanitized"
python3 -I "$HERE/dr_n8n_sanitize.py" "$EXPORTS" "$SAN"

# 2) Credential-reference inventory (references only, no values).
#    Credential inspection is a gate: if it fails, STOP before importing anything.
echo "== credential references across exports (no values) =="
if ! python3 -I "$HERE/dr_n8n_credential_refs.py" "$EXPORTS"; then
  echo "ERROR: credential inspection failed — aborting restore; no workflows were imported." >&2
  exit 1
fi

# 3) Optional repair of a pre-existing (polluted) DB.
if [ "$REPAIR" = 1 ] && [ -f "$DATA_ABS/database.sqlite" ]; then
  echo "== repairing pre-existing restore DB (clearing dangling active versions) =="
  python3 -I - "$DATA_ABS/database.sqlite" <<'PYREPAIR'
import sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db); cur = c.cursor()
cur.execute("PRAGMA foreign_keys=OFF")
cur.execute("UPDATE workflow_entity SET active=0, activeVersionId=NULL "
            "WHERE active=1 OR activeVersionId IS NOT NULL")
for t in ("workflow_publication_outbox", "workflow_published_version",
          "workflow_publish_history", "workflow_publication_retry_state"):
    try:
        cur.execute(f"DELETE FROM {t}")
    except sqlite3.Error:
        pass
c.commit()
print("repair done: active rows and dangling activeVersionId cleared")
PYREPAIR
fi

# 4) Import INACTIVE, offline. Default --activeState=false deactivates all.
echo "== importing sanitized workflows (inactive, offline) =="
run_n8n -v "$SAN:/import:ro" -- import:workflow --separate --input=/import

# 5) Verify via n8n's own view.
echo "== verification: n8n list:workflow =="
run_n8n -- list:workflow

echo "== DONE. Instance is isolated and inactive. Activate nothing; recreate"
echo "   credentials per dr/runbook/SECRETS-RECOVERY.md and dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md =="
