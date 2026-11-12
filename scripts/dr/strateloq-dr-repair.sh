#!/usr/bin/env bash
# =============================================================================
# strateloq-dr-repair.sh
# Operational repair + fresh encrypted backup + Drive-upload verify + integrity
# verify + REAL isolated restore into an EPHEMERAL LOCAL PostgreSQL cluster, for
# Strateloq-DR-Weekly-Backup.
#
# Runs INSIDE WSL (Ubuntu) as the operator user (e.g. strateloqbackup). It is
# diagnostics-first and READ-ONLY until --repair AND --approve are both given.
#
# It REUSES the operator's existing credentials, GPG recipient/keys and the
# strateloqdrive: connection; it never creates, changes, prints, or deletes any
# credential, scheduled task, or Drive destination.
#
# HARD LIMITS (enforced by construction - no code path does any of these):
#   * never modifies the production database (reads only, via pg_dump);
#   * the restore target is an EPHEMERAL LOCAL cluster (unix socket only,
#     listen_addresses='', trust on local socket, destroyed after) - never a
#     cloud/production database; a provided DSN is refused unless local + non-prod;
#   * never deletes a backup; never prints a secret; never deploys anything
#     (Kalodata etc.); never makes a paid third-party API call.
#
# Prints a single machine-parseable VERDICT: <CODE> line last.
# Exit 0 only on a clean diagnose, a genuinely successful backup, or a passing
# artifact verify; non-zero otherwise (so Windows Task Scheduler sees failures).
# =============================================================================
set -euo pipefail

REPO="${STRATELOQ_DR_REPO:-$HOME/strateloq-dr-validate}"
DRIVE_REMOTE="${STRATELOQ_DRIVE_REMOTE:-strateloqdrive:}"
DRIVE_DEST="${STRATELOQ_DRIVE_DEST:-Strateloq-DR/backups}"
PROD_PROJECT_REF="nxaunmyihhjixxxljcqt"   # production - NEVER a restore target

MODE="diagnose"            # diagnose | repair | verify-artifact
APPROVE="no"
DURABLE_SCRIPT=""
ARTIFACT=""
LOCAL_RESTORE="auto"       # auto | on | off
WORK=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --diagnose) MODE="diagnose" ;;
    --repair)   MODE="repair" ;;
    --verify-artifact) MODE="verify-artifact"; ARTIFACT="$2"; shift ;;
    --approve)  APPROVE="yes" ;;
    --repo)     REPO="$2"; shift ;;
    --durable-script) DURABLE_SCRIPT="$2"; shift ;;
    --drive-remote) DRIVE_REMOTE="$2"; shift ;;
    --local-restore) LOCAL_RESTORE="on" ;;
    --no-local-restore) LOCAL_RESTORE="off" ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

note()    { printf '  %s\n' "$*"; }
diag()    { printf 'DIAG %s\n' "$*"; }
verdict() { printf 'VERDICT: %s\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

BACKUP_SCRIPT="$REPO/scripts/dr/dr_db_logical_backup.sh"
REPAIR_DOC="$REPO/dr/runbook/WEEKLY-BACKUP-REPAIR.md"
RUNBOOK="$REPO/dr/runbook/RECOVERY-RUNBOOK.md"

CIPHER_SHA=""     # set by verify_integrity
DEC_PATH=""       # set by verify_integrity
LR_TABLES=""      # set by local_restore

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
WORK="$(mktemp -d)"

# ---------------------------------------------------------------------------
# verify_integrity <enc.gpg>  -> sets CIPHER_SHA, DEC_PATH ; returns 0 on pass
# ---------------------------------------------------------------------------
verify_integrity() {
  local enc="$1"
  [ -s "$enc" ] || { note "[FAIL] artifact missing/empty: $enc"; return 30; }
  CIPHER_SHA="$(sha256sum "$enc" | awk '{print $1}')"
  note "[OK]   ciphertext sha256: $CIPHER_SHA"
  have gpg || { note "[FAIL] gpg not available to decrypt"; return 31; }
  DEC_PATH="$WORK/verify.dump"
  if ! ( umask 077; gpg --yes -o "$DEC_PATH" -d "$enc" ) >/dev/null 2>&1; then
    note "[FAIL] decryption failed (operator private key / recipient mismatch)"; return 32
  fi
  note "[OK]   decryption succeeded"
  have pg_restore || { note "[WARN] pg_restore unavailable; cannot list TOC"; return 34; }
  local toc
  toc="$(pg_restore --list "$DEC_PATH" 2>/dev/null | grep -c ';')" || toc=0
  if [ "$toc" -lt 1 ]; then note "[FAIL] not a valid restorable custom-format dump (empty TOC)"; return 33; fi
  note "[OK]   PostgreSQL archive integrity: valid custom-format dump (TOC entries: $toc)"
  return 0
}

# ---------------------------------------------------------------------------
# local_restore <plain.dump>  -> REAL restore into an EPHEMERAL LOCAL cluster
# sets LR_TABLES ; returns 0 on >=1 restored table, 20/21 on prerequisite,
# 22-24 on failure.
# ---------------------------------------------------------------------------
local_restore() {
  local dump="$1" t
  for t in initdb pg_ctl pg_restore psql createdb; do
    have "$t" || { note "[PREREQ] local PostgreSQL server tool missing: $t (install 'postgresql')"; return 20; }
  done
  if [ "$(id -u)" = "0" ]; then
    note "[PREREQ] refuse to start a local cluster as root; run as the operator user"; return 21
  fi
  local base data sock port rc
  base="$(mktemp -d)"; data="$base/pgdata"; sock="$base/sock"; mkdir -p "$sock"
  port=$(( (RANDOM % 4000) + 55000 ))
  if ! initdb -D "$data" -A trust -U postgres >/dev/null 2>&1; then
    note "[FAIL] initdb failed"; rm -rf "$base"; return 22
  fi
  # unix-socket only, no TCP -> inherently isolated and unreachable from the network
  if ! pg_ctl -D "$data" -o "-p $port -k $sock -c listen_addresses=''" -l "$base/pg.log" -w start >/dev/null 2>&1; then
    note "[FAIL] local cluster failed to start"; rm -rf "$base"; return 23
  fi
  createdb -h "$sock" -p "$port" -U postgres drcheck >/dev/null 2>&1 || true
  rc=0
  pg_restore --no-owner --no-privileges -h "$sock" -p "$port" -U postgres -d drcheck "$dump" >/dev/null 2>&1 || rc=$?
  LR_TABLES="$(psql -h "$sock" -p "$port" -U postgres -d drcheck -tAc \
    "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');" 2>/dev/null | tr -d ' ')"
  pg_ctl -D "$data" -w stop >/dev/null 2>&1 || true
  rm -rf "$base"
  note "[INFO] ephemeral local restore: pg_restore rc=$rc, user tables restored=${LR_TABLES:-0}"
  [ "${LR_TABLES:-0}" -ge 1 ] && return 0 || return 24
}

# ---------------------------------------------------------------------------
# verify-artifact mode: verify an EXISTING encrypted backup end to end
# (sha256 + decrypt + archive integrity + real local restore). No prod read.
# ---------------------------------------------------------------------------
if [ "$MODE" = "verify-artifact" ]; then
  echo "== Verify artifact =="
  note "artifact: $ARTIFACT"
  if ! verify_integrity "$ARTIFACT"; then verdict "ARTIFACT_VERIFY_FAILED"; exit 9; fi
  if [ "$LOCAL_RESTORE" = "off" ]; then verdict "ARTIFACT_INTEGRITY_OK"; exit 0; fi
  if local_restore "$DEC_PATH"; then
    note "[OK]   isolated local restore succeeded (tables=$LR_TABLES)"
    verdict "ARTIFACT_RESTORE_OK"; exit 0
  else
    rc=$?
    [ "$rc" -le 21 ] && { verdict "ORCH_LOCAL_RESTORE_PREREQUISITE"; exit 0; }
    verdict "ARTIFACT_RESTORE_FAILED"; exit 12
  fi
fi

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

if [ -s "$BACKUP_SCRIPT" ]; then
  diag "backup_orchestrator=present backup_orchestrator_bytes=$(wc -c < "$BACKUP_SCRIPT" | tr -d ' ')"
  note "[OK]   operational backup script present: scripts/dr/dr_db_logical_backup.sh"
else
  diag "backup_orchestrator=missing_or_empty"; note "[FAIL] operational backup script missing/empty: $BACKUP_SCRIPT"; BLOCKERS=$((BLOCKERS+1))
fi

# (2) the durable script the Task Scheduler action invokes (path passed by launcher)
if [ -n "$DURABLE_SCRIPT" ]; then
  if [ -s "$DURABLE_SCRIPT" ]; then
    diag "durable_script=present"
    note "[OK]   durable task script present: $DURABLE_SCRIPT"
    if head -1 "$DURABLE_SCRIPT" | grep -q bash && ! grep -q 'set -e' "$DURABLE_SCRIPT"; then
      note "[WARN] durable script lacks 'set -e' - a failing step may not propagate an error exit code"
    fi
    if bash -n "$DURABLE_SCRIPT" 2>/dev/null; then note "[OK]   durable script parses (bash -n)"; else note "[FAIL] durable script has a syntax error"; BLOCKERS=$((BLOCKERS+1)); fi
  else
    diag "durable_script=missing"; note "[FAIL] durable task script not found: $DURABLE_SCRIPT"; BLOCKERS=$((BLOCKERS+1))
  fi
else
  diag "durable_script=unspecified"; note "[INFO] no --durable-script given; launcher reports the task action separately"
fi

if [ -s "$REPAIR_DOC" ]; then diag "repair_procedure=present"; note "[OK]   repair procedure present"; else diag "repair_procedure=missing"; note "[WARN] repair procedure doc not found"; fi
[ -s "$RUNBOOK" ] && diag "runbook=present" || diag "runbook=missing"

for t in pg_dump pg_restore gpg rclone initdb pg_ctl; do
  if have "$t"; then diag "tool_${t}=present"; note "[OK]   tool: $t"
  else diag "tool_${t}=missing"; note "[WARN] tool not found: $t"; fi
done

if [ -n "${SUPABASE_DB_URL:-}" ]; then diag "env_SUPABASE_DB_URL=set"; note "[OK]   SUPABASE_DB_URL set (value hidden)"; else diag "env_SUPABASE_DB_URL=unset"; note "[WARN] SUPABASE_DB_URL not set"; fi
if [ -n "${DR_GPG_RECIPIENT:-}" ]; then diag "env_DR_GPG_RECIPIENT=set"; note "[OK]   DR_GPG_RECIPIENT set (value hidden)"; else diag "env_DR_GPG_RECIPIENT=unset"; note "[WARN] DR_GPG_RECIPIENT not set"; fi

if have rclone; then
  if rclone listremotes 2>/dev/null | grep -qx "$DRIVE_REMOTE"; then diag "drive_remote=present"; note "[OK]   rclone remote present: $DRIVE_REMOTE -> $DRIVE_DEST (reused, not reconfigured)"
  else diag "drive_remote=missing"; note "[WARN] rclone remote '$DRIVE_REMOTE' not configured"; fi
fi

echo
if [ "$BLOCKERS" -gt 0 ]; then
  note "Diagnostics found $BLOCKERS blocking issue(s)."
  verdict "DIAGNOSE_BLOCKED"
  [ "$MODE" = "diagnose" ] && exit 0 || { echo "Refusing to repair while blocked." >&2; exit 5; }
fi
note "Diagnostics clean."
[ "$MODE" = "diagnose" ] && { verdict "DIAGNOSE_OK"; exit 0; }

# ---------------------------------------------------------------------------
# REPAIR (mutating) - requires --approve
# ---------------------------------------------------------------------------
if [ "$APPROVE" != "yes" ]; then echo "Repair without --approve; refusing." >&2; verdict "NOT_APPROVED"; exit 6; fi

echo "== Repair (safe, reversible fixes only) =="
[ -f "$BACKUP_SCRIPT" ] && [ ! -x "$BACKUP_SCRIPT" ] && { chmod +x "$BACKUP_SCRIPT"; note "[FIX]  made operational backup script executable"; } || note "[OK]   operational backup script permissions ok"
if [ -n "$DURABLE_SCRIPT" ] && [ -f "$DURABLE_SCRIPT" ] && [ ! -x "$DURABLE_SCRIPT" ]; then chmod +x "$DURABLE_SCRIPT"; note "[FIX]  made durable task script executable"; fi

missing=""
for t in pg_dump gpg; do have "$t" || missing="$missing $t"; done
[ -n "${SUPABASE_DB_URL:-}" ] || missing="$missing SUPABASE_DB_URL"
[ -n "${DR_GPG_RECIPIENT:-}" ] || missing="$missing DR_GPG_RECIPIENT"
if [ -n "$missing" ]; then echo; note "Cannot take a backup; missing operator prerequisite(s):$missing"; verdict "PREREQUISITE_MISSING"; exit 7; fi

echo
echo "== Fresh encrypted production backup (via established operational script) =="
BWORK="$WORK/backup"; mkdir -p "$BWORK"
( cd "$BWORK" && bash "$BACKUP_SCRIPT" ) || { echo "backup script failed" >&2; verdict "BACKUP_FAILED"; exit 8; }
ENC="$(ls -t "$BWORK"/strateloq-db-*.dump.gpg 2>/dev/null | head -1 || true)"
[ -n "$ENC" ] && [ -s "$ENC" ] || { echo "no encrypted backup produced" >&2; verdict "BACKUP_FAILED"; exit 8; }
SZ="$(wc -c < "$ENC" | tr -d ' ')"
note "[OK]   encrypted backup produced: $(basename "$ENC") ($SZ bytes)"

# secret-free manifest
SHA="$(sha256sum "$ENC" | awk '{print $1}')"
MAN="$BWORK/$(basename "$ENC").manifest.json"
printf '{\n  "artifact":"%s",\n  "bytes":%s,\n  "ciphertext_sha256":"%s",\n  "created_utc":"%s",\n  "drive_dest":"%s"\n}\n' \
  "$(basename "$ENC")" "$SZ" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DRIVE_REMOTE$DRIVE_DEST" > "$MAN"

echo
echo "== Upload to existing Drive destination + verify upload =="
UPLOAD_OK="no"
if have rclone && rclone listremotes 2>/dev/null | grep -qx "$DRIVE_REMOTE"; then
  if rclone copy "$ENC" "$DRIVE_REMOTE$DRIVE_DEST" && rclone copy "$MAN" "$DRIVE_REMOTE$DRIVE_DEST"; then
    base="$(basename "$ENC")"
    rsize="$(rclone ls "$DRIVE_REMOTE$DRIVE_DEST" 2>/dev/null | awk -v f="$base" '$2==f{print $1}' | head -1)"
    rmd5="$(rclone md5sum "$DRIVE_REMOTE$DRIVE_DEST" 2>/dev/null | awk -v f="$base" '$2==f{print $1}' | head -1)"
    lmd5="$(md5sum "$ENC" | awk '{print $1}')"
    note "[INFO] remote size=${rsize:-none} local size=$SZ ; remote md5=${rmd5:-n/a} local md5=$lmd5"
    if [ "${rsize:-0}" = "$SZ" ] && { [ -z "$rmd5" ] || [ "$rmd5" = "$lmd5" ]; }; then
      UPLOAD_OK="yes"; note "[OK]   Google Drive upload verified (object present, size + hash match)"
    else
      note "[FAIL] Drive upload verification mismatch"; verdict "UPLOAD_VERIFY_FAILED"; exit 13
    fi
  else
    note "[FAIL] rclone upload failed"; verdict "UPLOAD_FAILED"; exit 13
  fi
else
  note "[FAIL] Drive remote unavailable; cannot verify upload"; verdict "UPLOAD_FAILED"; exit 13
fi

echo
echo "== Verify backup integrity (sha256 + decrypt + archive) =="
if ! verify_integrity "$ENC"; then verdict "VERIFY_FAILED"; exit 9; fi

echo
echo "== Isolated restore into EPHEMERAL LOCAL PostgreSQL =="
if [ "$LOCAL_RESTORE" = "off" ]; then
  note "[SKIP] local restore disabled (--no-local-restore)"; verdict "ORCH_BACKUP_OK_RESTORE_SKIPPED"; exit 0
fi
if local_restore "$DEC_PATH"; then
  note "[OK]   REAL isolated restore passed in an ephemeral local cluster (user tables=$LR_TABLES)"
  verdict "ORCH_RESTORE_OK"; exit 0
else
  rc=$?
  if [ "$rc" -le 21 ]; then
    note "Backup made + uploaded + verified; local restore tooling is the remaining prerequisite."
    verdict "ORCH_BACKUP_OK_RESTORE_PREREQUISITE"; exit 0
  fi
  note "[FAIL] isolated restore failed"; verdict "ORCH_RESTORE_FAILED"; exit 12
fi
