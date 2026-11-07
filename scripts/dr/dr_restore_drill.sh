#!/usr/bin/env bash
# Strateloq DR — ISOLATED end-to-end database restore drill (Requirement 2).
#
# This is the single-command, VALIDATED, production-guarded version of the "Manual recovery" block in
# dr/runbook/GPG-KEY-AND-DB-BACKUP.md. It proves the newest encrypted DB backup is actually recoverable:
#   checksum-verify -> decrypt (your offline key) -> pg_restore into an ISOLATED target -> VALIDATE the
#   restored database against the live production baseline -> measure RPO/RTO -> shred the plaintext.
#
# It is run on the machine that holds the private key (your WSL box) because the key is deliberately
# never in the cloud. Validation of the RESULT can then be re-checked independently from the cloud via
# the Supabase MCP tools against the isolated project.
#
# NEVER restores over production: it refuses outright if RESTORE_DB_URL points at the production ref.
# Reads nothing from, and writes nothing to, production. The plaintext dump is shredded on every exit.
#
# Required (env or flags):
#   RESTORE_DB_URL   postgres connection string for the ISOLATED target (never logged). The password
#                    may be OMITTED (recommended): the drill then reads it once from the terminal and
#                    hands it to libpq via a restricted mode-600 temporary PGPASSFILE that is shredded
#                    on exit — never via PGPASSWORD, argv, shell history or logs. This is immune to the
#                    shell-quoting/whitespace corruption that makes PGPASSWORD fail where an interactive
#                    psql prompt (which reads the tty directly) succeeds for the SAME password.
#                    e.g. postgresql://postgres.zdeedmuocbbkuwuovlbz@aws-1-eu-west-1.pooler.supabase.com:5432/postgres
#   DR_DUMP          path to the encrypted dump  strateloq-db-<ts>.dump.gpg
# Optional:
#   DR_RESTORE_SUMS  path to SHA256SUMS covering DR_DUMP (checksum-verify before decrypt)
#   DR_RESET_PUBLIC=1    drop+recreate the public schema first for a pristine restore (recommended;
#                        the isolated target may hold a stale earlier drill)
#   DR_GPG_PASSPHRASE    backup-key passphrase (CR/LF stripped); if unset the drill prompts hidden on
#                        /dev/tty. Decryption mirrors Stage 2: ONE key is imported into a throwaway
#                        keyring, so a two-recipient dump cannot make gpg pick the wrong key/passphrase.
#   DR_P_FPR             fingerprint of the recovery key to decrypt with (default: PRIMARY, as Stage 2)
#   DR_RECOVERY_DIR      dir holding the key exports (default: $HOME/strateloq-backups/recovery)
#   DR_KEY_FILE          explicit secret-key export to import (default: $DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc)
#   DR_RESTORE_CONFIRM=1 required to actually restore (guard against an accidental run)
#   EXPECT_TABLES / EXPECT_ROUTINES / EXPECT_POLICIES / EXPECT_TRIGGERS
#                        structural expectations; default to the live production baseline captured
#                        2026-10-28 (151 / 794 / 101 / 31). Override only when drilling an older dump.
set -euo pipefail

# ---- args / env -------------------------------------------------------------
ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env)   ENV_FILE="$2"; shift 2;;
    --dump)  DR_DUMP="$2"; shift 2;;
    --sums)  DR_RESTORE_SUMS="$2"; shift 2;;
    --reset) DR_RESET_PUBLIC=1; shift;;
    --confirm) DR_RESTORE_CONFIRM=1; shift;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# Load an env file if given (same file as the weekly backup; only RESTORE_DB_URL etc. are read from it).
# BOM/CRLF-tolerant, like the other dr scripts: only well-formed KEY=VALUE lines are exported.
if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || { echo "ERROR: --env file not found: $ENV_FILE" >&2; exit 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#$'\xEF\xBB\xBF'}"; line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue;; esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # only pull keys this drill actually uses; leave the rest (the weekly env has many)
    case "$key" in
      RESTORE_DB_URL|DR_DUMP|DR_RESTORE_SUMS|DR_RESET_PUBLIC|DR_GPG_PASSPHRASE|EXPECT_*)
        eval "export $line";;
    esac
  done < "$ENV_FILE"
fi

: "${RESTORE_DB_URL:?set RESTORE_DB_URL (ISOLATED target; never production)}"
: "${DR_DUMP:?set DR_DUMP (path to strateloq-db-<ts>.dump.gpg)}"
DR_RESTORE_SUMS="${DR_RESTORE_SUMS:-}"
DR_RESET_PUBLIC="${DR_RESET_PUBLIC:-0}"
EXPECT_TABLES="${EXPECT_TABLES:-151}"
EXPECT_ROUTINES="${EXPECT_ROUTINES:-794}"
EXPECT_POLICIES="${EXPECT_POLICIES:-101}"
EXPECT_TRIGGERS="${EXPECT_TRIGGERS:-31}"

PROD_REF="nxaunmyihhjixxxljcqt"   # Strateloq Technologies production — must NEVER be the restore target

# ---- preflight --------------------------------------------------------------
for t in gpg pg_restore psql sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $t" >&2; exit 2; }
done
command -v shred >/dev/null 2>&1 || echo "WARN: 'shred' not found; will fall back to rm for the plaintext dump" >&2
[ -f "$DR_DUMP" ] || { echo "ERROR: DR_DUMP not found: $DR_DUMP" >&2; exit 2; }

# Production guard — fail CLOSED. Refuse if the target string references the production project ref.
if printf '%s' "$RESTORE_DB_URL" | grep -q "$PROD_REF"; then
  echo "REFUSED: RESTORE_DB_URL references the PRODUCTION project ($PROD_REF). This drill never restores over production." >&2
  exit 3
fi

# Extract connection fields WITHOUT the password, so we can (a) confirm the isolated target and
# (b) build a restricted temporary .pgpass when the URL carries no password. urlsplit is tolerant of
# any special characters; we never print or store the password here.
_url_fields="$(python3 -I - "$RESTORE_DB_URL" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
host = p.hostname or ''
port = str(p.port or 5432)
db   = (p.path or '/').lstrip('/') or 'postgres'
user = p.username or ''
haspw = '1' if p.password is not None else '0'
print('\t'.join([host, port, db, user, haspw]))
PY
)"
IFS=$'\t' read -r PGH PGP PGDB PGU URL_HASPW <<<"$_url_fields"
echo "== Strateloq DR restore drill =="
echo "Target (isolated): host=$PGH port=$PGP db=$PGDB user=$PGU"
echo "Encrypted dump:    $DR_DUMP"

if [ "${DR_RESTORE_CONFIRM:-0}" != "1" ]; then
  echo
  echo "Dry preview only. Re-run with --confirm (or DR_RESTORE_CONFIRM=1) to perform the restore + validation." >&2
  exit 0
fi

# ---- T0: RPO data point (age of this backup) --------------------------------
base="$(basename "$DR_DUMP")"
ts="$(printf '%s' "$base" | grep -oE '[0-9]{8}T[0-9]{6}Z' | head -1 || true)"
now_epoch="$(date -u +%s)"
if [ -n "$ts" ]; then
  bk_epoch="$(date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null || echo 0)"
else
  bk_epoch="$(date -u -r "$DR_DUMP" +%s 2>/dev/null || echo 0)"
fi
if [ "$bk_epoch" -gt 0 ]; then
  age_h=$(( (now_epoch - bk_epoch) / 3600 ))
  echo "T0  backup timestamp: ${ts:-<file mtime>}  (age ≈ ${age_h}h — this is the RPO data point)"
else
  echo "T0  backup timestamp: unknown (could not parse); RPO not measurable from filename"
fi

# ---- checksum verify (integrity in transit) ---------------------------------
if [ -n "$DR_RESTORE_SUMS" ] && [ -f "$DR_RESTORE_SUMS" ]; then
  ( cd "$(dirname "$DR_DUMP")" && sha256sum -c "$(basename "$DR_RESTORE_SUMS")" 2>/dev/null | grep -F "$base" ) \
    && echo "checksum: OK (matches SHA256SUMS)" \
    || { echo "ERROR: checksum verification FAILED for $base against $DR_RESTORE_SUMS" >&2; exit 4; }
else
  echo "checksum: $(sha256sum "$DR_DUMP" | awk '{print $1}')  (no SHA256SUMS supplied to compare against)"
fi

# ---- private, mode-700 workspace; shred plaintext + any temp pgpass on ANY exit ----
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dr-restore.XXXXXX")"; chmod 700 "$WORK"
PLAIN="$WORK/d.dump"
PASSFILE="$WORK/pgpass"        # restricted temp libpq password file (created below only if needed)
cleanup() {
  for f in "$PLAIN" "$PASSFILE"; do
    [ -f "$f" ] && { shred -u "$f" 2>/dev/null || rm -f "$f"; }
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- secure DB authentication (no PGPASSWORD / argv / history / logs) -------
# Interactive psql works because it reads the password straight from the terminal. PGPASSWORD can
# FAIL for the SAME password if the shell altered it on assignment (unquoted/"-quoted $, ! or
# backtick; a leading/trailing space stripped when IFS is unset; a stray CR from a pasted value) —
# SCRAM rejects one wrong byte exactly like a wrong password. To be immune to all of that, when the
# URL carries no password we read it ONCE from /dev/tty (as psql itself does) and hand it to libpq
# via a mode-600 PGPASSFILE. Honours a pre-set PGPASSFILE/PGPASSWORD or an in-URL password for
# automation; otherwise PGPASSWORD is never used.
if [ "${URL_HASPW:-0}" = "0" ] && [ -z "${PGPASSFILE:-}" ] && [ -z "${PGPASSWORD:-}" ]; then
  if [ -r /dev/tty ]; then
    printf 'Isolated DR DB password (hidden): ' >&2
    IFS= read -rs _pw < /dev/tty; echo >&2
  else
    echo "ERROR: no terminal available to read the DB password. Supply a mode-600 PGPASSFILE instead." >&2
    exit 2
  fi
  _pw="${_pw%$'\r'}"; _pw="${_pw%$'\n'}"              # tolerate a pasted CRLF; typed input is unaffected
  [ -n "$_pw" ] || { echo "ERROR: empty DB password" >&2; exit 2; }
  _epw="${_pw//\\/\\\\}"; _epw="${_epw//:/\\:}"; unset _pw   # escape \ then : for the .pgpass format
  ( umask 077; printf '%s:%s:%s:%s:%s\n' "$PGH" "$PGP" "$PGDB" "$PGU" "$_epw" > "$PASSFILE" )
  unset _epw
  chmod 600 "$PASSFILE"
  export PGPASSFILE="$PASSFILE"
  echo "   auth: restricted temporary PGPASSFILE (mode 600, shredded on exit); PGPASSWORD not used"
fi

t1_epoch="$(date -u +%s)"; echo "T1  restore start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- decrypt — IDENTICAL to Stage 2's proven PRIMARY path (dr_stage2_backup_and_verify.sh) ----
# The production dump is encrypted to TWO recipients (PRIMARY + ESCROW). Decrypting in your AMBIENT
# ~/.gnupg (which holds BOTH secret keys) lets gpg select the OTHER key for a PKESK packet and then
# reject your PRIMARY passphrase as "Bad passphrase" — exactly why Stage 3 failed while Stage 2 (which
# imports ONLY the chosen key into a throwaway keyring) passed. So we do the same here: import ONE key
# into an isolated keyring with loopback enabled, and decrypt with a CR/LF-stripped passphrase.
DR_P_FPR="${DR_P_FPR:-AD834A2029AA703FA41B119B9D9E63310CA63035}"      # PRIMARY (Stage 2 default)
DR_RECOVERY_DIR="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
DR_KEY_FILE="${DR_KEY_FILE:-$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc}"

# passphrase: from DR_GPG_PASSPHRASE or a hidden /dev/tty prompt — CR/LF stripped (a Windows/WSL
# terminal appends CR; Stage 2 strips it, an ambient agent cache can mask it, an isolated keyring cannot)
if [ -n "${DR_GPG_PASSPHRASE:-}" ]; then
  _pp="${DR_GPG_PASSPHRASE%$'\r'}"; _pp="${_pp%$'\n'}"
elif [ -r /dev/tty ]; then
  printf 'Backup key passphrase (hidden): ' >&2; IFS= read -rs _pp < /dev/tty; echo >&2
  _pp="${_pp%$'\r'}"; _pp="${_pp%$'\n'}"
else
  echo "ERROR: no DR_GPG_PASSPHRASE and no terminal to prompt for the backup key passphrase" >&2; exit 4
fi
[ -n "$_pp" ] || { echo "ERROR: empty backup key passphrase" >&2; exit 4; }

GH="$WORK/gh"
if [ -f "$DR_KEY_FILE" ]; then
  mkdir -p "$GH"; chmod 700 "$GH"
  echo "allow-loopback-pinentry" > "$GH/gpg-agent.conf"   # isolated home must allow loopback like ~/.gnupg
  if ! GNUPGHOME="$GH" gpg --batch --import "$DR_KEY_FILE" 2>"$GH/imp.log"; then
    echo "ERROR: could not import the recovery key export: $DR_KEY_FILE" >&2
    sed 's/^/   gpg: /' "$GH/imp.log" | head -3 >&2; unset _pp; exit 4; fi
  printf '%s' "$_pp" | GNUPGHOME="$GH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    -d "$DR_DUMP" > "$PLAIN" 2>"$GH/dec.log" || true
  echo "   decrypt: isolated keyring, imported ONLY $DR_P_FPR (deterministic key selection — Stage-2-equivalent)"
  DEC_LOG="$GH/dec.log"
else
  echo "   WARN: recovery key export not found ($DR_KEY_FILE); falling back to the ambient keyring" >&2
  printf '%s' "$_pp" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --decrypt "$DR_DUMP" > "$PLAIN" 2>"$WORK/dec.log" || true
  DEC_LOG="$WORK/dec.log"
fi
unset _pp
if [ ! -s "$PLAIN" ]; then
  echo "ERROR: decryption produced no output." >&2
  [ -f "$DEC_LOG" ] && sed 's/^/   gpg: /' "$DEC_LOG" | head -5 >&2
  if grep -qi 'Bad passphrase' "$DEC_LOG" 2>/dev/null; then
    echo "   -> gpg rejected the passphrase for the imported key $DR_P_FPR (isolated keyring, agent-cache-independent)." >&2
  elif grep -qi 'No secret key\|decryption failed: No secret key' "$DEC_LOG" 2>/dev/null; then
    echo "   -> the imported key cannot decrypt this dump (wrong key / not a recipient), NOT a passphrase problem." >&2
  fi
  exit 4
fi
head -c 5 "$PLAIN" | grep -q 'PGDMP' || { echo "ERROR: decrypted output is not a PostgreSQL custom archive (no PGDMP magic)" >&2; exit 4; }

# ---- integrity: the dump's own table of contents ----------------------------
toc="$(pg_restore -l "$PLAIN" | grep -cvE '^(;|$)' || true)"
echo "   decrypted OK; pg_restore TOC entries: $toc"

# ---- optional pristine reset of the isolated target -------------------------
# The isolated target may hold a STALE earlier drill; reset public for a clean, honest validation.
if [ "$DR_RESET_PUBLIC" = "1" ]; then
  echo "   resetting public schema on the isolated target for a pristine restore"
  # Role-portable: current_user is the connecting role (postgres via the Supabase pooler; the local
  # superuser under a plain-Postgres drill). Grants here just restore schema usability — object-level
  # privileges are intentionally out of scope for the drill (the dump is taken --no-privileges and the
  # runbook reconciles roles/grants separately).
  psql "$RESTORE_DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
drop schema if exists public cascade;
create schema public;
grant all on schema public to current_user;
grant usage on schema public to public;
SQL
fi

# ---- restore ----------------------------------------------------------------
# Supabase->Supabase restores emit NON-FATAL errors on managed schemas/roles (auth, storage, extensions,
# supabase_* roles) that already exist on the target. pg_restore continues past them by default; we
# capture the count and still validate the application-owned public schema, which is the recoverable
# asset. (A bare-metal restore into plain Postgres 17 would not hit the managed-object conflicts.)
RLOG="$WORK/pg_restore.log"
set +e
pg_restore -d "$RESTORE_DB_URL" --no-owner --no-privileges --clean --if-exists "$PLAIN" 2> "$RLOG"
rc=$?
set -e
errs="$(grep -c '^pg_restore: error:' "$RLOG" 2>/dev/null || true)"; errs="${errs:-0}"
echo "   pg_restore exit=$rc; non-fatal errors reported: $errs (managed-schema/role conflicts are expected on Supabase→Supabase)"

t2_epoch="$(date -u +%s)"; echo "T2  restore complete: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- validate the restored database -----------------------------------------
# A failing query (e.g. a relation missing after a partial restore, or auth.* on a plain-Postgres
# target) must be REPORTED as a failed check, never abort the drill — so q never returns nonzero
# (important under `set -o pipefail`). An errored query yields "" which the checks treat as 0/mismatch.
q() { psql "$RESTORE_DB_URL" -tAc "$1" 2>/dev/null | tr -d '[:space:]' || true; }

act_tables="$(q "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
act_routines="$(q "select count(*) from information_schema.routines where routine_schema='public'")"
act_policies="$(q "select count(*) from pg_policies where schemaname='public'")"
act_triggers="$(q "select count(*) from information_schema.triggers where trigger_schema='public'")"
act_rls="$(q "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and c.relrowsecurity")"
act_authusers="$(q "select count(*) from auth.users")"

# anchor data tables (must be present AND populated) — thresholds are ~10% of backup-time magnitudes
a_trend="$(q "select count(*) from public.trend_signals")"
a_clusters="$(q "select count(*) from public.trend_clusters")"
a_opps="$(q "select count(*) from public.opportunities")"
a_fx="$(q "select count(*) from public.fx_rates")"

# advertising FAIL-CLOSED invariant: no executable / no ACTIVE authority must survive the restore
msa_total="$(q "select count(*) from public.marketing_spend_authority")"
msa_exec="$(q "select count(*) from public.marketing_spend_authority where executable")"
msa_active="$(q "select count(*) from public.marketing_spend_authority where status='ACTIVE'")"

pass=0; fail=0
check() { # name expected actual op
  local name="$1" exp="$2" act="$3" op="${4:-eq}" ok=0
  case "$op" in
    eq) [ "$act" = "$exp" ] && ok=1;;
    ge) [ "${act:-0}" -ge "$exp" ] 2>/dev/null && ok=1;;
  esac
  if [ "$ok" = 1 ]; then printf '  PASS  %-28s expected %s, got %s\n' "$name" "$exp" "$act"; pass=$((pass+1))
  else printf '  FAIL  %-28s expected %s %s, got %s\n' "$name" "$op" "$exp" "$act"; fail=$((fail+1)); fi
}

echo
echo "== Validation (restored isolated DB vs production baseline) =="
check "public tables"        "$EXPECT_TABLES"   "$act_tables"
check "public routines"      "$EXPECT_ROUTINES" "$act_routines"
check "public policies"      "$EXPECT_POLICIES" "$act_policies"
check "public user triggers" "$EXPECT_TRIGGERS" "$act_triggers"
check "RLS-enabled tables"   "$EXPECT_TABLES"   "$act_rls"
check "trend_signals rows"   "10000" "$a_trend"    ge
check "trend_clusters rows"  "500"   "$a_clusters" ge
check "opportunities rows"   "300"   "$a_opps"     ge
check "fx_rates rows"        "100"   "$a_fx"       ge
check "ad authority total"   "6"     "$msa_total"
check "ad authority executable (fail-closed)" "0" "$msa_exec"
check "ad authority ACTIVE  (fail-closed)"    "0" "$msa_active"
echo "  INFO  auth.users restored: $act_authusers (auth is reconciled separately per runbook step 7; not a pass/fail here)"

t3_epoch="$(date -u +%s)"
rto_min=$(( (t3_epoch - t1_epoch + 59) / 60 ))
echo
echo "== Measurements =="
[ "$bk_epoch" -gt 0 ] && echo "  RPO (backup age at drill): ≈ $(( (now_epoch - bk_epoch) / 3600 )) h"
echo "  RTO (restore+validate):    ≈ ${rto_min} min  (T3−T1)"

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS — $pass checks passed, 0 failed. Encrypted backup is RECOVERABLE into an isolated target."
  echo "Teardown: plaintext dump shredded. Reset or pause the isolated project when done (do not leave a 2nd data copy)."
  exit 0
else
  echo "RESULT: FAIL — $pass passed, $fail failed. See the failing checks above; inspect $RLOG before it is removed." >&2
  echo "        (the plaintext dump is shredded on exit regardless)"
  exit 1
fi
