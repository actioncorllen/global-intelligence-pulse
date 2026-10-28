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
#   RESTORE_DB_URL   postgres connection string for the ISOLATED target (a secret; never logged).
#                    e.g. postgresql://postgres.zdeedmuocbbkuwuovlbz:<pw>@aws-0-eu-west-1.pooler.supabase.com:5432/postgres
#   DR_DUMP          path to the encrypted dump  strateloq-db-<ts>.dump.gpg
# Optional:
#   DR_RESTORE_SUMS  path to SHA256SUMS covering DR_DUMP (checksum-verify before decrypt)
#   DR_RESET_PUBLIC=1    drop+recreate the public schema first for a pristine restore (recommended;
#                        the isolated target may hold a stale earlier drill)
#   DR_GPG_PASSPHRASE    supply the key passphrase non-interactively via gpg loopback; if unset, gpg
#                        prompts you interactively (more secure — nothing in env/argv)
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

# Show the target WITHOUT the password, so the operator can confirm it is the isolated project.
TARGET_DESC="$(python3 -I - "$RESTORE_DB_URL" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("host=%s port=%s db=%s user=%s" % (p.hostname, p.port, (p.path or '/').lstrip('/'), p.username))
PY
)"
echo "== Strateloq DR restore drill =="
echo "Target (isolated): $TARGET_DESC"
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

# ---- private, mode-700 workspace; shred plaintext on ANY exit ---------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dr-restore.XXXXXX")"; chmod 700 "$WORK"
PLAIN="$WORK/d.dump"
cleanup() {
  if [ -f "$PLAIN" ]; then
    shred -u "$PLAIN" 2>/dev/null || rm -f "$PLAIN"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

t1_epoch="$(date -u +%s)"; echo "T1  restore start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- decrypt (uses YOUR offline private key) --------------------------------
if [ -n "${DR_GPG_PASSPHRASE:-}" ]; then
  printf '%s' "$DR_GPG_PASSPHRASE" | \
    gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt "$DR_DUMP" > "$PLAIN"
else
  echo "   (gpg will prompt for your backup key passphrase)"
  gpg --yes --decrypt "$DR_DUMP" > "$PLAIN"
fi
[ -s "$PLAIN" ] || { echo "ERROR: decryption produced an empty file" >&2; exit 4; }

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
