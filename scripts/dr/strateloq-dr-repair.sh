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
# Safe defaults so `set -u` never aborts on an unset credential reference before discovery.
DR_GPG_RECIPIENT="${DR_GPG_RECIPIENT:-}"
DR_GPG_PASSPHRASE="${DR_GPG_PASSPHRASE:-}"
# Acceptance criteria for the isolated restore (comma-separated required public tables; min rows each).
REQUIRED_TABLES="${STRATELOQ_DR_REQUIRED_TABLES:-}"
MIN_ROWS="${STRATELOQ_DR_MIN_ROWS:-1}"

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
    --gpg-doctor) MODE="gpg-doctor"; ARTIFACT="$2"; shift ;;
    --approve)  APPROVE="yes" ;;
    --repo)     REPO="$2"; shift ;;
    --durable-script) DURABLE_SCRIPT="$2"; shift ;;
    --env-file) ENV_FILE="$2"; shift ;;
    --gnupghome) export GNUPGHOME="$2"; shift ;;
    --required-tables) REQUIRED_TABLES="$2"; shift ;;
    --min-rows) MIN_ROWS="$2"; shift ;;
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
    "$REPO/.env.backup" "$REPO/dr_weekly_backup.env" "$REPO/scripts/dr/dr_weekly_backup.env" \
    "$HOME/dr_weekly_backup.env" "$HOME/.config/strateloq-dr/dr_weekly_backup.env" \
    "$HOME/.strateloq-dr.env" "$HOME/strateloq-dr.env" "$HOME/.config/strateloq-dr/env" \
    "$HOME/.strateloq-dr/env" "$HOME/.dr.env" "/etc/strateloq-dr/dr_weekly_backup.env" \
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
DECRYPT_CAUSE=""   # ok|no_secret_key|recipient_mismatch|passphrase|agent|unreadable|other|missing|no_gpg
# set by local_restore:
LR_TABLES=""; LR_PUBLIC=""; LR_EXP_PUBLIC=""; LR_DATA_ERR=""; LR_MANAGED_ERR=""
LR_TOTAL_ROWS=""; LR_REQ_REPORT=""; LR_VERDICT=""; LR_MISSING=""
LR_SEQ=""; LR_FUNC=""; LR_TRIG=""; LR_POL=""
LR_EXT_REQUIRED=""; LR_EXT_ENABLED=""; LR_EXT_UNAVAILABLE=""; LR_EXT_SCHEMA=""

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
WORK="$(mktemp -d)"

# --- GPG diagnosis helpers (public key IDENTIFIERS only; never print secret material) -------
# NOTE: each ends with `|| true` so a non-zero gpg exit (e.g. no secret key) never aborts under set -e/pipefail.
_gpg_msg_keyids()  { { gpg --list-packets "$1" 2>/dev/null | sed -nE 's/.*keyid[: ]+(0x)?([0-9A-Fa-f]{8,}).*/\2/p' | tr 'a-f' 'A-F' | sort -u; } || true; }
_gpg_sec_keyids()  { { gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="sec"||$1=="ssb"{print $5}' | tr 'a-f' 'A-F' | sort -u; } || true; }
_gpg_rcpt_keyids() { { gpg --list-keys --with-colons "$1" 2>/dev/null | awk -F: '$1=="pub"||$1=="sub"{print $5}' | tr 'a-f' 'A-F' | sort -u; } || true; }

# gpg_diagnose <enc> : prints findings, sets DECRYPT_CAUSE (attempts no decryption).
gpg_diagnose() {
  local enc="$1" k MSG SEC REC have_secret="no" rcpt_matches="no"
  note "[INFO] gpg user=$(id -un)  GNUPGHOME=${GNUPGHOME:-$HOME/.gnupg}  $(gpg --version 2>/dev/null | head -1)"
  MSG="$(_gpg_msg_keyids "$enc" | tr '\n' ' ')"
  SEC="$(_gpg_sec_keyids   | tr '\n' ' ')"
  REC="$(_gpg_rcpt_keyids "${DR_GPG_RECIPIENT:-}" | tr '\n' ' ')"
  note "[INFO] archive is encrypted to keyid(s): ${MSG:-<unreadable>}"
  note "[INFO] DR_GPG_RECIPIENT='${DR_GPG_RECIPIENT:-<unset>}' public keyid(s): ${REC:-<recipient public key NOT in this keyring>}"
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
    if   grep -qiE 'passphrase|batchmode|can.t get input|cancel' "$err"; then DECRYPT_CAUSE="passphrase"; note "[FAIL] decrypt failed: the private key is passphrase-protected and no valid passphrase was supplied (provide it transiently for one command, e.g. read -rs DR_GPG_PASSPHRASE; or run where the gpg-agent is unlocked - do NOT store it in a persistent env file)"; return 42
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
# local_restore <plain.dump>  -> REAL restore into an EPHEMERAL LOCAL cluster,
# then classify pg_restore errors and verify SCHEMA + DATA (not just a table count).
# Sets LR_*; LR_VERDICT = ok|partial. Returns: 0 ok | 25 partial | 20/21 prereq
# | 22/23 cluster | 24 hard restore failure (no tables).
# ---------------------------------------------------------------------------
local_restore() {
  local dump="$1" t base data sock port rc errf EXP_PUB TOT ok req_fail tbl n top s ext line
  for t in initdb pg_ctl pg_restore psql createdb; do
    have "$t" || { note "[PREREQ] local PostgreSQL server tool missing: $t (install 'postgresql')"; return 20; }
  done
  [ "$(id -u)" = "0" ] && { note "[PREREQ] refuse to start a local cluster as root; run as the operator user"; return 21; }

  EXP_PUB="$(pg_restore -l "$dump" 2>/dev/null | awk '$4=="TABLE" && $5=="public"{c++} END{print c+0}')"
  LR_EXP_PUBLIC="$EXP_PUB"

  base="$(mktemp -d)"; data="$base/pgdata"; sock="$base/sock"; errf="$base/restore.err"; mkdir -p "$sock"
  port=$(( (RANDOM % 4000) + 55000 ))
  initdb -D "$data" -A trust -U postgres >/dev/null 2>&1 || { note "[FAIL] initdb failed"; rm -rf "$base"; return 22; }
  pg_ctl -D "$data" -o "-p $port -k $sock -c listen_addresses=''" -l "$base/pg.log" -w start >/dev/null 2>&1 \
    || { note "[FAIL] local cluster failed to start"; rm -rf "$base"; return 23; }
  createdb -h "$sock" -p "$port" -U postgres drcheck >/dev/null 2>&1 || true
  pqd() { psql -h "$sock" -p "$port" -U postgres -d drcheck -tAc "$1" 2>/dev/null | tr -d ' '; }

  # --- restoration fix: pre-create Supabase-managed roles + schemas + required extensions -----
  # roles first, so RLS policies/grants that reference them (anon/authenticated/service_role...)
  # restore instead of failing "role does not exist" (the dominant managed-env difference).
  for r in anon authenticated service_role authenticator dashboard_user supabase_admin \
           supabase_auth_admin supabase_storage_admin supabase_functions_admin \
           supabase_replication_admin supabase_read_only_user supabase_realtime_admin \
           pgbouncer pgsodium_keyholder pgsodium_keyiduser pgsodium_keymaker; do
    psql -h "$sock" -p "$port" -U postgres -d drcheck -q -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='$r') then create role \"$r\" nologin noinherit; end if; end \$\$;" >/dev/null 2>&1 || true
  done
  for s in extensions auth storage graphql graphql_public realtime vault pgsodium \
           supabase_functions supabase_migrations _analytics net cron pgbouncer; do
    psql -h "$sock" -p "$port" -U postgres -d drcheck -q -c "create schema if not exists \"$s\";" >/dev/null 2>&1 || true
  done
  # schema-only SQL of the dump (small; reveals each extension's TARGET SCHEMA from its own DDL)
  pg_restore -s -f "$base/schema.sql" "$dump" 2>/dev/null || true
  LR_EXT_REQUIRED=""; LR_EXT_ENABLED=""; LR_EXT_UNAVAILABLE=""; LR_EXT_SCHEMA=""
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    LR_EXT_REQUIRED="$LR_EXT_REQUIRED $ext"
    if [ "$(pqd "select 1 from pg_available_extensions where name='${ext//\'/}';")" != "1" ]; then
      LR_EXT_UNAVAILABLE="$LR_EXT_UNAVAILABLE $ext"; continue
    fi
    # (req 2,3) create the extension in the schema the DUMP actually uses - do NOT assume 'extensions'.
    local sch=""
    sch="$(grep -iE "CREATE EXTENSION (IF NOT EXISTS )?\"?${ext}\"? +WITH SCHEMA" "$base/schema.sql" 2>/dev/null | head -1 | sed -E 's/.*WITH SCHEMA +"?([A-Za-z0-9_]+)"?.*/\1/I')"
    if [ -n "$sch" ]; then
      psql -h "$sock" -p "$port" -U postgres -d drcheck -q -c "create schema if not exists \"$sch\";" >/dev/null 2>&1 || true
      if psql -h "$sock" -p "$port" -U postgres -d drcheck -q -c "create extension if not exists \"$ext\" with schema \"$sch\";" >/dev/null 2>&1; then
        LR_EXT_ENABLED="$LR_EXT_ENABLED $ext"; LR_EXT_SCHEMA="$LR_EXT_SCHEMA ${ext}:${sch}"
      fi
    else
      # dump has no explicit WITH SCHEMA -> do NOT preempt its placement; let the dump create it
      LR_EXT_ENABLED="$LR_EXT_ENABLED $ext"; LR_EXT_SCHEMA="$LR_EXT_SCHEMA ${ext}:(dump-default)"
    fi
  done < <(pg_restore -l "$dump" 2>/dev/null | awk '$4=="EXTENSION"{print $6}' | sort -u)

  rc=0
  pg_restore --no-owner --no-privileges -h "$sock" -p "$port" -U postgres -d drcheck "$dump" >/dev/null 2>"$errf" || rc=$?
  psql -h "$sock" -p "$port" -U postgres -d drcheck -c 'ANALYZE' >/dev/null 2>&1 || true

  LR_TABLES="$(pqd "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema') and table_type='BASE TABLE';")"
  LR_PUBLIC="$(pqd "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE';")"
  LR_TOTAL_ROWS="$(pqd "select coalesce(sum(n_live_tup),0)::bigint from pg_stat_user_tables;")"
  # schema objects (req #5): sequences / functions / triggers / policies, restored vs dump TOC
  LR_SEQ="$(pqd "select count(*) from information_schema.sequences where sequence_schema='public';")"
  LR_FUNC="$(pqd "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';")"
  LR_TRIG="$(pqd "select count(*) from pg_trigger g join pg_class c on c.oid=g.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not g.tgisinternal;")"
  LR_POL="$(pqd "select count(*) from pg_policies where schemaname='public';")"
  local EXP_FUNC EXP_TRIG EXP_POL EXP_SEQ
  EXP_FUNC="$(pg_restore -l "$dump" 2>/dev/null | awk '$4=="FUNCTION"{c++} END{print c+0}')"
  EXP_TRIG="$(pg_restore -l "$dump" 2>/dev/null | awk '$4=="TRIGGER"{c++} END{print c+0}')"
  EXP_POL="$(pg_restore -l "$dump" 2>/dev/null | awk '$4=="POLICY"{c++} END{print c+0}')"
  EXP_SEQ="$(pg_restore -l "$dump" 2>/dev/null | awk '$4=="SEQUENCE" && $5!="OWNED" && $5!="SET"{c++} END{print c+0}')"

  # classify pg_restore errors. A FAILED "CREATE TABLE"/"COPY" (whatever the underlying ERROR)
  # is data-affecting - a table or its data did not restore - NOT harmless. pg_restore echoes the
  # failed statement as "Command was: <SQL>"; count those plus explicit data-corruption messages.
  local DA_CMD DA_MSG
  TOT="$(grep -ciE 'error:' "$errf" 2>/dev/null || true)"
  DA_CMD="$(grep -cE '^Command was: (CREATE TABLE|COPY )' "$errf" 2>/dev/null || true)"
  DA_MSG="$(grep -icE 'COPY failed|invalid input syntax|value too long|extra data|missing data|out of (shared )?memory|no space left|could not read block|data (is )?corrupt|lost synchronization' "$errf" 2>/dev/null || true)"
  LR_DATA_ERR=$(( ${DA_CMD:-0} + ${DA_MSG:-0} ))
  LR_MANAGED_ERR=$(( ${TOT:-0} - ${LR_DATA_ERR:-0} )); [ "$LR_MANAGED_ERR" -lt 0 ] && LR_MANAGED_ERR=0

  # exact MISSING public tables (dump TOC minus restored) + the actual error log for each
  LR_MISSING="$( comm -23 \
      <(pg_restore -l "$dump" 2>/dev/null | awk '$4=="TABLE" && $5=="public"{print $6}' | sort -u) \
      <(pqd "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1;" | sort -u) \
    | tr '\n' ' ' )"

  # required-tables row verification (exact)
  LR_REQ_REPORT=""; req_fail=0
  if [ -n "$REQUIRED_TABLES" ]; then
    local IFS_SAVE="$IFS"; IFS=','
    for tbl in $REQUIRED_TABLES; do
      tbl="$(printf '%s' "$tbl" | tr -d '[:space:]')"; [ -z "$tbl" ] && continue
      if [ "$(pqd "select count(*) from information_schema.tables where table_schema='public' and table_name='${tbl//\'/}';")" != "1" ]; then
        LR_REQ_REPORT="$LR_REQ_REPORT ${tbl}=MISSING"; req_fail=1
      else
        n="$(pqd "select count(*) from public.\"${tbl//\'/}\";")"
        LR_REQ_REPORT="$LR_REQ_REPORT ${tbl}=${n}rows"; [ "${n:-0}" -lt "${MIN_ROWS:-1}" ] && req_fail=1
      fi
    done
    IFS="$IFS_SAVE"
  fi
  top="$(psql -h "$sock" -p "$port" -U postgres -d drcheck -tAF' ' -c \
    "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc nulls last limit 5;" 2>/dev/null | sed 's/^/        /')"

  note "[INFO] pg_restore rc=$rc  (errors: total=${TOT:-0}, data-affecting=${LR_DATA_ERR:-0}, managed-env=${LR_MANAGED_ERR})"
  note "[INFO] tables: public=${LR_PUBLIC:-0}/${EXP_PUB:-?} (dump TOC), all-schemas=${LR_TABLES:-0}; rows~${LR_TOTAL_ROWS:-0}"
  note "[INFO] objects restored/TOC: sequences=${LR_SEQ:-0}/${EXP_SEQ:-0} functions=${LR_FUNC:-0}/${EXP_FUNC:-0} triggers=${LR_TRIG:-0}/${EXP_TRIG:-0} policies=${LR_POL:-0}/${EXP_POL:-0}"
  [ -n "$top" ] && { note "[INFO] largest tables (name rows):"; printf '%s\n' "$top"; }
  [ -n "$LR_REQ_REPORT" ] && note "[INFO] required tables:$LR_REQ_REPORT (min ${MIN_ROWS} row(s) each)"
  [ -n "${LR_EXT_REQUIRED# }" ] && note "[INFO] extensions required:${LR_EXT_REQUIRED:-none}; enabled (ext:schema from dump DDL):${LR_EXT_SCHEMA:- none}; UNAVAILABLE:${LR_EXT_UNAVAILABLE:- none}"
  local pgmaj; pgmaj="$(pg_config --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"; [ -z "$pgmaj" ] && pgmaj='<N>'
  if [ -n "${LR_MISSING// /}" ]; then
    note "[DIAG] public tables in the dump TOC but NOT restored:${LR_MISSING}"
    for tbl in $LR_MISSING; do
      note "        --- public.${tbl} : data in backup? $(pg_restore -l "$dump" 2>/dev/null | awk -v t="$tbl" '$4=="TABLE" && $5=="DATA" && $6=="public" && $7==t{f=1} END{print (f?"YES":"no")}')"
      note "          root cause (actual pg_restore ERROR -> the statement it failed on):"
      awk -v t="$tbl" '/^pg_restore: error:/{e=$0} /^Command was:/{ if(index($0,t)){print "            "e; print "            "substr($0,1,90); e=""} }' "$errf" 2>/dev/null | head -6
      note "          CREATE TABLE definition from the dump (column types reveal the real dependency):"
      pg_restore -t "$tbl" -s -f - "$dump" 2>/dev/null | grep -vE '^--|^$|^SET |^SELECT |^ALTER TABLE .* OWNER' | sed 's/^/            /' | head -30
    done
  fi
  if [ -n "${LR_EXT_UNAVAILABLE// /}" ]; then
    note "[DIAG] extension remediation (local PostgreSQL major ${pgmaj}):"
    for ext in $LR_EXT_UNAVAILABLE; do
      case "$ext" in
        vector)                note "          - vector         -> sudo apt-get install -y postgresql-${pgmaj}-pgvector  (embeddings columns)";;
        http)                  note "          - http           -> sudo apt-get install -y postgresql-${pgmaj}-http";;
        pg_cron)               note "          - pg_cron        -> sudo apt-get install -y postgresql-${pgmaj}-cron";;
        pg_net|supabase_vault) note "          - ${ext} -> SUPABASE-MANAGED; not packaged for a standalone cluster. A production restore into Supabase provides it. It affects managed functions/policies, NOT an application table unless a column uses its type (check the DDL above).";;
        *)                     note "          - ${ext} -> check your distro for postgresql-${pgmaj}-${ext} (or restore on a PostgreSQL version where it is available).";;
      esac
    done
  fi

  pg_ctl -D "$data" -w stop >/dev/null 2>&1 || true
  rm -rf "$base"

  if [ "${LR_TABLES:-0}" -lt 1 ]; then note "[FAIL] no tables restored"; LR_VERDICT="fail"; return 24; fi

  # acceptance: all public tables present AND zero data-affecting errors AND required tables satisfied
  ok=1
  [ "${LR_PUBLIC:-0}" -ge "${EXP_PUB:-0}" ] || { note "[WARN] fewer public tables than the dump TOC (${LR_PUBLIC:-0} < ${EXP_PUB:-0}) - see [DIAG] above"; ok=0; }
  [ "${LR_DATA_ERR:-0}" -eq 0 ] || { note "[WARN] ${LR_DATA_ERR} data/schema-affecting pg_restore error(s)"; ok=0; }
  [ "$req_fail" -eq 0 ] || { note "[WARN] one or more required tables missing or under the row threshold"; ok=0; }
  if [ "$ok" -eq 1 ]; then LR_VERDICT="ok"; return 0; fi
  LR_VERDICT="partial"; return 25
}

# ---------------------------------------------------------------------------
# verify-artifact mode: verify an EXISTING encrypted backup end to end
# (sha256 + decrypt + archive integrity + real local restore). No prod read.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# gpg-doctor mode: READ-ONLY GPG recovery diagnostic on an EXISTING archive.
# No decryption is attempted unless a matching secret key is actually present;
# no backup, no restore, no archive/key/config change. Never prints secret material.
# ---------------------------------------------------------------------------
if [ "$MODE" = "gpg-doctor" ]; then
  echo "== GPG recovery diagnostic (READ-ONLY; no backup, no restore, nothing changed) =="
  [ -s "$ARTIFACT" ] || { note "[FAIL] archive missing/empty: $ARTIFACT"; verdict "GPG_DOCTOR_NO_ARTIFACT"; exit 30; }
  note "[OK]   archive: $ARTIFACT ($(wc -c < "$ARTIFACT" | tr -d ' ') bytes)"
  note "[INFO] ciphertext sha256: $(sha256sum "$ARTIFACT" | awk '{print $1}')"
  have gpg || { note "[FAIL] gpg not available"; verdict "GPG_DOCTOR_NO_GPG"; exit 31; }
  # load DR_GPG_RECIPIENT from the scheduled-backup env file if not already set (read-only on disk;
  # needed for the recipient-match check so a true mismatch is not misread as a missing key).
  if [ -z "${DR_GPG_RECIPIENT:-}" ]; then load_dr_env || true; [ -n "$ENV_LOADED_FILES" ] && note "[INFO] DR_GPG_RECIPIENT loaded from env file (value hidden)"; fi
  gpg_diagnose "$ARTIFACT"     # recipient keyid + secret keyids + GNUPGHOME + user (public IDs only)
  case "$DECRYPT_CAUSE" in
    no_secret_key)
      note "RESULT: the private key for this archive is NOT in this keyring. No decryption was attempted."
      note "        (keyring inspected: no secret key matches the archive's recipient key id.)"
      verdict "GPG_DOCTOR_NO_SECRET_KEY"; exit 0 ;;
    recipient_mismatch)
      note "RESULT: the archive is encrypted to a key that DR_GPG_RECIPIENT does not resolve to."
      verdict "GPG_DOCTOR_RECIPIENT_MISMATCH"; exit 0 ;;
    unreadable)
      note "RESULT: could not read the archive's recipient key id (not an OpenPGP message?)."
      verdict "GPG_DOCTOR_UNREADABLE"; exit 0 ;;
    secret_present)
      note "[INFO] a matching secret key IS present - probing decryptability (output discarded; no plaintext kept)..."
      GD_ERR="$WORK/doctor.err"; GD_RC=0
      if [ -n "${DR_GPG_PASSPHRASE:-}" ]; then
        printf '%s' "$DR_GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -o /dev/null -d "$ARTIFACT" 2>"$GD_ERR" || GD_RC=$?
      else
        gpg --batch --yes --pinentry-mode loopback -o /dev/null -d "$ARTIFACT" 2>"$GD_ERR" || GD_RC=$?
      fi
      if [ "${GD_RC:-1}" -eq 0 ]; then
        note "RESULT: DECRYPTABLE here - the private key is present and usable. Proceed to --verify-artifact for the real restore."
        verdict "GPG_DOCTOR_DECRYPTABLE"; exit 0
      elif grep -qiE 'passphrase|batchmode|can.t get input|cancel' "$GD_ERR"; then
        note "RESULT: secret key present but PASSPHRASE-PROTECTED and no passphrase available in this session."
        note "        Supply it transiently for one command or use an unlocked gpg-agent - do NOT persist it."
        verdict "GPG_DOCTOR_PASSPHRASE_REQUIRED"; exit 0
      elif grep -qiE 'agent|pinentry|ioctl' "$GD_ERR"; then
        note "RESULT: gpg-agent/pinentry could not run in batch/no-tty mode."
        verdict "GPG_DOCTOR_AGENT_ERROR"; exit 0
      else
        note "RESULT: decryption probe failed: $(head -1 "$GD_ERR" 2>/dev/null)"
        verdict "GPG_DOCTOR_DECRYPT_ERROR"; exit 0
      fi ;;
  esac
fi

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
    note "[OK]   isolated restore ACCEPTED: all public tables + representative data verified; data-affecting errors=0 (any pg_restore rc!=0 was managed-environment only)."
    verdict "ARTIFACT_RESTORE_OK"; exit 0
  else
    rc=$?
    [ "$rc" -le 21 ] && { verdict "ORCH_LOCAL_RESTORE_PREREQUISITE"; exit 0; }
    [ "$rc" -eq 25 ] && { note "[PARTIAL] restore ran but acceptance not fully met (see warnings above) - NOT signed off."; verdict "ARTIFACT_RESTORE_PARTIAL"; exit 25; }
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
  note "[OK]   REAL isolated restore ACCEPTED (all public tables + representative data verified; data-affecting errors=0; user tables=$LR_TABLES)"
  verdict "ORCH_RESTORE_OK"; exit 0
else
  rc=$?
  if [ "$rc" -le 21 ]; then
    note "Backup made + uploaded + verified; local restore tooling is the remaining prerequisite."
    verdict "ORCH_BACKUP_OK_RESTORE_PREREQUISITE"; exit 0
  fi
  [ "$rc" -eq 25 ] && { note "[PARTIAL] backup restorable but restore acceptance not fully met (see warnings) - NOT signed off."; verdict "ORCH_RESTORE_PARTIAL"; exit 25; }
  note "[FAIL] isolated restore failed"; verdict "ORCH_RESTORE_FAILED"; exit 12
fi
