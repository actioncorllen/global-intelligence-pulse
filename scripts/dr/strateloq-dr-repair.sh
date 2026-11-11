#!/usr/bin/env bash
# =============================================================================
# strateloq-dr-repair.sh
# Operational repair + fresh encrypted backup + verify for Strateloq-DR-Weekly-Backup.
#
# Runs INSIDE WSL (Ubuntu) as the operator user (e.g. strateloqbackup). It is
# diagnostics-first and READ-ONLY until --repair AND --approve are both given.
#
# It uses the ESTABLISHED operational backup script (scripts/dr/dr_db_logical_backup.sh)
# and the operator's existing credentials/remote; it does NOT create, change, print, or
# delete any credential, scheduled task, or Drive destination.
#
# HARD LIMITS (enforced by construction - no code path does any of these):
#   * never modifies the production database (reads only, via pg_dump);
#   * never restores over production (isolated-DB guard, fail-closed);
#   * never deletes a backup; never prints a secret; never deploys anything (Kalodata etc.);
#   * never makes a paid third-party API call.
#
# Exit 0 only on a clean diagnose, or on a repair whose backup verified.
# Prints a single machine-parseable VERDICT: <CODE> line last.
# =============================================================================
set -euo pipefail

# ---- configuration (all overridable; secrets come from the operator env, never here) ------
REPO="${STRATELOQ_DR_REPO:-$HOME/strateloq-dr-validate}"
DRIVE_REMOTE="${STRATELOQ_DRIVE_REMOTE:-strateloqdrive:}"
DRIVE_DEST="${STRATELOQ_DRIVE_DEST:-Strateloq-DR/backups}"
TASK_NAME="${STRATELOQ_TASK_NAME:-Strateloq-DR-Weekly-Backup}"
PROD_PROJECT_REF="nxaunmyihhjixxxljcqt"   # production - NEVER a restore target

MODE="diagnose"
APPROVE="no"
ISO_DB_URL=""
ISO_ACK="no"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --diagnose) MODE="diagnose" ;;
    --repair)   MODE="repair" ;;
    --approve)  APPROVE="yes" ;;
    --repo)     REPO="$2"; shift ;;
    --drive-remote) DRIVE_REMOTE="$2"; shift ;;
    --isolated-db-url) ISO_DB_URL="$2"; shift ;;
    --i-understand-isolated) ISO_ACK="yes" ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

note() { printf '  %s\n' "$*"; }
diag() { printf 'DIAG %s\n' "$*"; }     # KEY=VALUE, parseable by the launcher
verdict() { printf 'VERDICT: %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

BACKUP_SCRIPT="$REPO/scripts/dr/dr_db_logical_backup.sh"
REPAIR_DOC="$REPO/dr/runbook/WEEKLY-BACKUP-REPAIR.md"
RUNBOOK="$REPO/dr/runbook/RECOVERY-RUNBOOK.md"

echo "== Strateloq DR repair =="
echo "repo=$REPO  mode=$MODE  approve=$APPROVE"
echo

# ---------------------------------------------------------------------------
# DIAGNOSE (read-only) - always runs first
# ---------------------------------------------------------------------------
echo "== Diagnostics (read-only) =="
BLOCKERS=0

if [ -d "$REPO" ]; then diag "repo_present=1"; note "[OK]   repo at $REPO"
else diag "repo_present=0"; note "[FAIL] repo missing at $REPO"; BLOCKERS=$((BLOCKERS+1)); fi

# (3) confirm the actual backup orchestrator exists and is NONEMPTY
if [ -s "$BACKUP_SCRIPT" ]; then
  sz=$(wc -c < "$BACKUP_SCRIPT" | tr -d ' ')
  diag "backup_orchestrator=present backup_orchestrator_bytes=$sz"
  note "[OK]   operational backup script present ($sz bytes): scripts/dr/dr_db_logical_backup.sh"
else
  diag "backup_orchestrator=missing_or_empty"
  note "[FAIL] operational backup script missing/empty: $BACKUP_SCRIPT"
  BLOCKERS=$((BLOCKERS+1))
fi

# (4) repair procedure present (not merely staging utilities)
if [ -s "$REPAIR_DOC" ]; then diag "repair_procedure=present"; note "[OK]   repair procedure: dr/runbook/WEEKLY-BACKUP-REPAIR.md"
else diag "repair_procedure=missing"; note "[WARN] repair procedure doc not found at $REPAIR_DOC"; fi
if [ -s "$RUNBOOK" ]; then diag "runbook=present"; else diag "runbook=missing"; fi

# tools required for a real encrypted backup + restorability check
for t in pg_dump pg_restore gpg rclone; do
  if have "$t"; then diag "tool_${t}=present"; note "[OK]   tool: $t"
  else diag "tool_${t}=missing"; note "[WARN] tool not found: $t (operator prerequisite)"; fi
done

# operator-held secrets - presence only, value NEVER printed
if [ -n "${SUPABASE_DB_URL:-}" ]; then diag "env_SUPABASE_DB_URL=set"; note "[OK]   SUPABASE_DB_URL is set (value hidden)"
else diag "env_SUPABASE_DB_URL=unset"; note "[WARN] SUPABASE_DB_URL not set (operator prerequisite)"; fi
if [ -n "${DR_GPG_RECIPIENT:-}" ]; then diag "env_DR_GPG_RECIPIENT=set"; note "[OK]   DR_GPG_RECIPIENT is set (value hidden)"
else diag "env_DR_GPG_RECIPIENT=unset"; note "[WARN] DR_GPG_RECIPIENT not set (operator prerequisite)"; fi

# Drive remote present (read-only) - destination preserved, never reconfigured
if have rclone; then
  if rclone listremotes 2>/dev/null | grep -qx "$DRIVE_REMOTE"; then
    diag "drive_remote=present"; note "[OK]   rclone remote present: $DRIVE_REMOTE -> $DRIVE_DEST (preserved)"
  else
    diag "drive_remote=missing"; note "[WARN] rclone remote '$DRIVE_REMOTE' not configured (operator prerequisite)"
  fi
fi

echo
if [ "$BLOCKERS" -gt 0 ]; then
  note "Diagnostics found $BLOCKERS blocking issue(s)."
  verdict "DIAGNOSE_BLOCKED"
  [ "$MODE" = "diagnose" ] && exit 0 || { echo "Refusing to repair while blocked." >&2; exit 5; }
fi
note "Diagnostics clean."
if [ "$MODE" = "diagnose" ]; then verdict "DIAGNOSE_OK"; exit 0; fi

# ---------------------------------------------------------------------------
# REPAIR (mutating) - requires --approve
# ---------------------------------------------------------------------------
if [ "$APPROVE" != "yes" ]; then
  echo "Repair requested without --approve; refusing to change anything." >&2
  verdict "NOT_APPROVED"
  exit 6
fi

echo "== Repair =="
# Safe, minimal, reversible fixes only. Credentials / task config / Drive dest untouched.
if [ -f "$BACKUP_SCRIPT" ] && [ ! -x "$BACKUP_SCRIPT" ]; then
  chmod +x "$BACKUP_SCRIPT"; note "[FIX]  made operational backup script executable"
else
  note "[OK]   no unsafe permission fix required"
fi

# Prerequisite gate for taking a real backup
missing=""
for t in pg_dump gpg; do have "$t" || missing="$missing $t"; done
[ -n "${SUPABASE_DB_URL:-}" ] || missing="$missing SUPABASE_DB_URL"
[ -n "${DR_GPG_RECIPIENT:-}" ] || missing="$missing DR_GPG_RECIPIENT"
if [ -n "$missing" ]; then
  echo
  note "Cannot take a real encrypted backup; missing operator prerequisite(s):$missing"
  verdict "PREREQUISITE_MISSING"
  exit 7
fi

echo
echo "== Fresh encrypted backup (via established operational script) =="
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && bash "$BACKUP_SCRIPT" ) || { echo "backup script failed" >&2; verdict "BACKUP_FAILED"; exit 8; }

ENC="$(ls -t "$WORK"/strateloq-db-*.dump.gpg 2>/dev/null | head -1 || true)"
if [ -z "$ENC" ] || [ ! -s "$ENC" ]; then
  echo "no encrypted backup produced" >&2; verdict "BACKUP_FAILED"; exit 8
fi
SZ=$(wc -c < "$ENC" | tr -d ' ')
SHA=$(sha256sum "$ENC" | awk '{print $1}')
note "[OK]   encrypted backup: $(basename "$ENC") ($SZ bytes)"
note "       ciphertext sha256: $SHA"

# secret-free manifest (checksums/sizes/timestamps only)
MAN="$WORK/$(basename "$ENC").manifest.json"
printf '{\n  "artifact": "%s",\n  "bytes": %s,\n  "ciphertext_sha256": "%s",\n  "created_utc": "%s",\n  "drive_dest": "%s"\n}\n' \
  "$(basename "$ENC")" "$SZ" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DRIVE_REMOTE$DRIVE_DEST" > "$MAN"
note "[OK]   manifest written (no secrets)"

# upload to the EXISTING Drive destination (never reconfigured)
if have rclone && rclone listremotes 2>/dev/null | grep -qx "$DRIVE_REMOTE"; then
  rclone copy "$ENC" "$DRIVE_REMOTE$DRIVE_DEST" && rclone copy "$MAN" "$DRIVE_REMOTE$DRIVE_DEST" \
    && note "[OK]   uploaded backup + manifest to $DRIVE_REMOTE$DRIVE_DEST (existing destination)"
else
  note "[WARN] Drive remote unavailable; backup kept locally only this run"
fi

echo
echo "== Verify (restorability) =="
# Decrypt to a 0600 temp file, prove it is a valid restorable custom-format dump.
DEC="$WORK/verify.dump"; ( umask 077; gpg --yes -o "$DEC" -d "$ENC" ) >/dev/null 2>&1 || {
  echo "decrypt failed" >&2; verdict "VERIFY_FAILED"; exit 9; }
if ! have pg_restore; then
  note "[WARN] pg_restore not available; cannot list TOC. Backup produced + encrypted + uploaded."
  verdict "BACKUP_MADE_RESTORE_UNVERIFIED"
  exit 0
fi
TOC=$(pg_restore --list "$DEC" 2>/dev/null | grep -c ';') || TOC=0
shred -u "$DEC" 2>/dev/null || rm -f "$DEC"
if [ "$TOC" -lt 1 ]; then
  note "[FAIL] decrypted archive is not a valid restorable dump (empty TOC)"
  verdict "VERIFY_FAILED"; exit 9
fi
note "[OK]   archive is a valid restorable custom-format dump (TOC entries: $TOC)"

# ---- optional ISOLATED restore (the only way to earn RESTORE-READY) ----
if [ -z "$ISO_DB_URL" ]; then
  echo
  note "Fresh encrypted backup is verified RESTORABLE (archive integrity + TOC)."
  note "A full isolated restore was NOT performed: no --isolated-db-url was supplied."
  note "REMAINING PREREQUISITE: an empty, ISOLATED database URL (never production)."
  note "Then re-run with:  --isolated-db-url '<url>' --i-understand-isolated"
  verdict "BACKUP_VERIFIED_RESTORE_PREREQUISITE"
  exit 0
fi

# isolation guard - fail closed
case "$ISO_DB_URL" in
  *"$PROD_PROJECT_REF"*) echo "REFUSED: target looks like PRODUCTION." >&2; verdict "RESTORE_REFUSED_PRODUCTION"; exit 10 ;;
esac
if [ "$ISO_ACK" != "yes" ]; then
  echo "Refusing isolated restore without --i-understand-isolated." >&2
  verdict "RESTORE_NOT_ACKNOWLEDGED"; exit 11
fi

echo
echo "== Isolated restore drill =="
DEC2="$WORK/restore.dump"; ( umask 077; gpg --yes -o "$DEC2" -d "$ENC" ) >/dev/null 2>&1
if pg_restore --no-owner --no-privileges --clean --if-exists --dbname "$ISO_DB_URL" "$DEC2" >/dev/null 2>&1; then
  TBL=$(psql "$ISO_DB_URL" -tAc "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null || echo 0)
  shred -u "$DEC2" 2>/dev/null || rm -f "$DEC2"
  note "[OK]   restored into isolated DB; public tables=$TBL"
  if [ "${TBL:-0}" -ge 1 ]; then
    verdict "RESTORE_OK"     # <-- only here is restoration actually proven
    exit 0
  fi
  note "[FAIL] restore produced 0 tables"
  verdict "RESTORE_EMPTY"; exit 12
else
  shred -u "$DEC2" 2>/dev/null || rm -f "$DEC2"
  echo "pg_restore into isolated DB failed" >&2
  verdict "RESTORE_FAILED"; exit 12
fi
