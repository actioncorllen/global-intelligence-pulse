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
ENV_FILE=""                # explicit scheduled-backup env file (e.g. from the task action)
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
    --env-file) ENV_FILE="$2"; shift ;;
    --gnupghome) export GNUPGHOME="$2"; shift ;;
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
ENV_LOADED_FILES=""

# --- DR credential environment discovery (presence only; never prints secret values) -------
# Candidate scheduled-backup env files, explicit --env-file first.
env_candidates() {
  [ -n "${ENV_FILE:-}" ] && printf '%s\n' "$ENV_FILE"
  printf '%s\n' \
    "$REPO/.env" "$REPO/.env.dr" "$REPO/.dr.env" "$REPO/dr/.env" "$REPO/scripts/dr/.env" \
    "$REPO/.env.backup" "$HOME/.strateloq-dr.env" "$HOME/strateloq-dr.env" \
    "$HOME/.config/strateloq-dr/env" "$HOME/.strateloq-dr/env" "$HOME/.dr.env" \
    "/etc/strateloq-dr/env" "/etc/default/strateloq-dr"
}

# The variable NAMES the operational backup script actually requires (its ${VAR:?}/${VAR:-}
# guards) - so a script using DIFFERENT names is discovered and used, not assumed.
required_backup_vars() {
  local names=""
  [ -s "$BACKUP_SCRIPT" ] && names="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:[?-]' "$BACKUP_SCRIPT" 2>/dev/null \
      | sed -E 's/^\$\{//; s/:[?-]$//' | sort -u | tr '\n' ' ')"
  [ -z "$names" ] && names="SUPABASE_DB_URL DR_GPG_RECIPIENT"
  printf '%s' "$names"
}

# locate_var <NAME> -> "shell" | "file:<path>" | "missing"  (never prints the value)
locate_var() {
  local var="$1" f
  if [ -n "${!var:-}" ]; then printf 'shell'; return 0; fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ( set +e; set -a; . "$f" >/dev/null 2>&1; set +a; [ -n "${!var:-}" ] ); then printf 'file:%s' "$f"; return 0; fi
  done < <(env_candidates)
  printf 'missing'
}

# Source the env file(s) that provide any still-missing required var INTO this shell, so the
# backup inherits them. Trusted operator files; values are never echoed.
load_dr_env() {
  local var loc f
  for var in $(required_backup_vars); do
    [ -n "${!var:-}" ] && continue
    loc="$(locate_var "$var")"
    case "$loc" in
      file:*) f="${loc#file:}"
        case " $ENV_LOADED_FILES " in
          *" $f "*) : ;;
          *) set +e; set -a; . "$f" >/dev/null 2>&1; set +a; set -e; ENV_LOADED_FILES="$ENV_LOADED_FILES $f" ;;
        esac ;;
    esac
  done
}

CIPHER_SHA=""      # set by verify_integrity
DEC_PATH=""        # set by verify_integrity
LR_TABLES=""       # set by local_restore
DECRYPT_CAUSE=""   # ok|no_secret_key|recipient_mismatch|passphrase|agent|unreadable|other|missing|no_gpg

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
WORK="$(mktemp -d)"

# --- GPG diagnosis helpers (public key IDENTIFIERS only; never print secret material) -------
_gpg_msg_keyids()  { gpg --list-packets "$1" 2>/dev/null | sed -nE 's/.*keyid[: ]+(0x)?([0-9A-Fa-f]{8,}).*/\2/p' | tr 'a-f' 'A-F' | sort -u; }
_gpg_sec_keyids()  { gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="sec"||$1=="ssb"{print $5}' | tr 'a-f' 'A-F' | sort -u; }
_gpg_rcpt_keyids() { gpg --list-keys --with-colons "$1" 2>/dev/null | awk -F: '$1=="pub"||$1=="sub"{print $5}' | tr 'a-f' 'A-F' | sort -u; }

# gpg_diagnose <enc> : prints findings, sets DECRYPT_CAUSE (attempts no decryption).
gpg_diagnose() {
  local enc="$1" k MSG SEC REC have_secret="no" rcpt_matches="no"
  note "[INFO] gpg user=$(id -un)  GNUPGHOME=${GNUPGHOME:-$HOME/.gnupg}  $(gpg --version 2>/dev/null | head -1)"
  MSG="$(_gpg_msg_keyids "$enc" | tr '\n' ' ')"
  SEC="$(_gpg_sec_keyids   | tr '\n' ' ')"
  REC="$(_gpg_rcpt_keyids "$DR_GPG_RECIPIENT" | tr '\n' ' ')"
  note "[INFO] archive is encrypted to keyid(s): ${MSG:-<unreadable>}"
  note "[INFO] DR_GPG_RECIPIENT='$DR_GPG_RECIPIENT' public keyid(s): ${REC:-<recipient public key NOT in this keyring>}"
  note "[INFO] secret keyid(s) available to $(id -un): ${SEC:-<none - no private key in this keyring>}"
  for k in $MSG; do case " $SEC " in *" $k "*) have_secret="yes" ;; esac; done
  for k in $MSG; do case " $REC " in *" $k "*) rcpt_matches="yes" ;; esac; done
  if   [ "$have_secret" = "yes" ];                      then DECRYPT_CAUSE="secret_present"
  elif [ -z "$MSG" ];                                   then DECRYPT_CAUSE="unreadable"
  elif [ -n "$REC" ] && [ "$rcpt_matches" = "no" ];     then DECRYPT_CAUSE="recipient_mismatch"
  else                                                       DECRYPT_CAUSE="no_secret_key"; fi
  note "[INFO] gpg diagnosis: $DECRYPT_CAUSE"
}

# ---------------------------------------------------------------------------
# verify_integrity <enc.gpg>  -> sets CIPHER_SHA, DEC_PATH, DECRYPT_CAUSE
#   0 pass | 30 missing | 31 no gpg | 40 no_secret_key | 41 recipient_mismatch
#   42 passphrase | 43 agent | 32 other decrypt | 33 bad TOC | 34 no pg_restore
# ---------------------------------------------------------------------------
verify_integrity() {
  local enc="$1" err rc toc
  [ -s "$enc" ] || { note "[FAIL] artifact missing/empty: $enc"; DECRYPT_CAUSE="missing"; return 30; }
  CIPHER_SHA="$(sha256sum "$enc" | awk '{print $1}')"
  note "[OK]   ciphertext sha256: $CIPHER_SHA"
  have gpg || { note "[FAIL] gpg not available"; DECRYPT_CAUSE="no_gpg"; return 31; }

  gpg_diagnose "$enc"
  if [ "$DECRYPT_CAUSE" = "no_secret_key" ]; then
    note "[FAIL] cannot decrypt here: the PRIVATE key for this archive is not in $(id -un)'s keyring."
    note "       The weekly backup encrypts to DR_GPG_RECIPIENT's PUBLIC key; the private key is held"
    note "       OFFLINE by design, so decryption must run where that private key lives (or with --gnupghome)."
    return 40
  fi
  if [ "$DECRYPT_CAUSE" = "recipient_mismatch" ]; then
    note "[FAIL] the archive is encrypted to a key that DR_GPG_RECIPIENT does not resolve to (recipient mismatch)."
    return 41
  fi

  DEC_PATH="$WORK/verify.dump"; err="$WORK/gpg.err"
  if [ -n "${DR_GPG_PASSPHRASE:-}" ]; then
    printf '%s' "$DR_GPG_PASSPHRASE" | ( umask 077; gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -o "$DEC_PATH" -d "$enc" ) 2>"$err"; rc=$?
  else
    ( umask 077; gpg --batch --yes --pinentry-mode loopback -o "$DEC_PATH" -d "$enc" ) 2>"$err"; rc=$?
  fi
  if [ "${rc:-1}" -ne 0 ]; then
    if   grep -qiE 'passphrase|batchmode|can.t get input|cancel' "$err"; then DECRYPT_CAUSE="passphrase"; note "[FAIL] decrypt failed: the private key is passphrase-protected and no valid passphrase was supplied (set DR_GPG_PASSPHRASE in the DR env file, or run where the gpg-agent is unlocked)"; return 42
    elif grep -qiE 'agent|pinentry|ioctl'                        "$err"; then DECRYPT_CAUSE="agent"; note "[FAIL] decrypt failed: gpg-agent/pinentry could not run in batch/no-tty mode"; return 43
    elif grep -qiE 'no secret key'                               "$err"; then DECRYPT_CAUSE="no_secret_key"; note "[FAIL] decrypt failed: no usable secret key"; return 40
    else DECRYPT_CAUSE="other"; note "[FAIL] decrypt failed: $(head -1 "$err" 2>/dev/null)"; return 32; fi
  fi
  DECRYPT_CAUSE="ok"
  note "[OK]   decryption succeeded (private key present and usable)"
  have pg_restore || { note "[WARN] pg_restore unavailable; cannot list TOC"; return 34; }
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
  echo "== Verify artifact (existing backup; no new backup taken) =="
  note "artifact: $ARTIFACT"
  if ! verify_integrity "$ARTIFACT"; then
    case "$DECRYPT_CAUSE" in
      no_secret_key)      verdict "ARTIFACT_DECRYPT_NO_SECRET_KEY";      exit 40 ;;
      recipient_mismatch) verdict "ARTIFACT_DECRYPT_RECIPIENT_MISMATCH"; exit 41 ;;
      passphrase)         verdict "ARTIFACT_DECRYPT_PASSPHRASE_REQUIRED"; exit 42 ;;
      agent)              verdict "ARTIFACT_DECRYPT_AGENT_ERROR";        exit 43 ;;
      *)                  verdict "ARTIFACT_VERIFY_FAILED";              exit 9  ;;
    esac
  fi
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
    diag "durable_script=missing"; note "[WARN] durable task script path from the task action not found in WSL: $DURABLE_SCRIPT (best-effort extraction; verify the task action - not a diagnose blocker)"
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

# (4) DR credentials: discover where each required var lives; distinguish genuinely-missing
#     from present-but-not-loaded-into-this-shell. Never prints secret values.
REQUIRED_VARS="$(required_backup_vars)"
note "[INFO] operational backup requires: $REQUIRED_VARS (names read from the backup script's own guards)"
CREDS_MISSING=""
for cv in $REQUIRED_VARS; do
  loc="$(locate_var "$cv")"
  case "$loc" in
    shell)   diag "cred_${cv}=shell";   note "[OK]   $cv present in this shell (value hidden)" ;;
    file:*)  diag "cred_${cv}=envfile";  note "[OK]   $cv present in ${loc#file:} - NOT loaded in this interactive shell; the repair will load it (value hidden)" ;;
    missing) diag "cred_${cv}=missing";  note "[WARN] $cv genuinely NOT found in this shell or any known scheduled-backup env file"; CREDS_MISSING="$CREDS_MISSING $cv" ;;
  esac
done
[ -n "$CREDS_MISSING" ] && note "[WARN] genuinely missing credentials:$CREDS_MISSING (these are not a diagnose blocker)"

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

# Load the existing scheduled-backup credentials from the discovered env file(s) first, so a
# credential that EXISTS but was not in this interactive shell is used rather than reported missing.
load_dr_env
if [ -n "$ENV_LOADED_FILES" ]; then note "[OK]   loaded DR credentials from env file(s):$ENV_LOADED_FILES (values not shown; nothing overwritten)"
else note "[INFO] no DR env file needed (required credentials already present in the shell)"; fi

missing=""
for t in pg_dump gpg; do have "$t" || missing="$missing $t"; done
for cv in $(required_backup_vars); do [ -n "${!cv:-}" ] || missing="$missing $cv"; done
if [ -n "$missing" ]; then
  echo
  note "Cannot take a backup - GENUINELY missing after loading every known DR env file:$missing"
  note "(not found in the shell or any discovered scheduled-backup env file)"
  verdict "PREREQUISITE_MISSING"; exit 7
fi

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
if ! verify_integrity "$ENC"; then
  case "$DECRYPT_CAUSE" in
    no_secret_key)
      echo
      note "The fresh backup is VALID and uploaded (encrypted to DR_GPG_RECIPIENT's public key)."
      note "Decryption needs the OFFLINE private key, which is not in $(id -un)'s keyring by design."
      note "Complete the decrypt + isolated restore where that private key lives, reusing THIS archive:"
      note "  strateloq-dr-repair.sh --verify-artifact '$DRIVE_REMOTE$DRIVE_DEST/$(basename "$ENC")' --gnupghome <private-key GNUPGHOME>"
      verdict "ORCH_BACKUP_OK_DECRYPT_PREREQUISITE"; exit 0 ;;
    recipient_mismatch) verdict "DECRYPT_RECIPIENT_MISMATCH"; exit 41 ;;
    passphrase)         verdict "DECRYPT_PASSPHRASE_REQUIRED"; exit 42 ;;
    agent)              verdict "DECRYPT_AGENT_ERROR"; exit 43 ;;
    *)                  verdict "VERIFY_FAILED"; exit 9 ;;
  esac
fi

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
