#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — Stage 2: fresh production backups + full fail-closed verification.
# Reuses the committed dr_weekly_backup.sh orchestrator (DB + storage + source/Edge git
# bundle + n8n, two-recipient encryption, SHA256SUMS, Drive upload + checksum verify).
# Then INDEPENDENTLY verifies: integrity, all 4 components present, exactly 2 recipients,
# n8n coverage == inventory, PRIMARY and ESCROW each decrypt the DB, and storage/source/n8n
# contents. Fail-closed: STOPS on the first mandatory failure; never deletes history; prod
# read-only; temp decrypted data kept in tmpfs and shredded. No secrets printed.
#
# Normal use (founder):   bash dr_stage2_backup_and_verify.sh
# Re-verify an existing local set (skips orchestrator+pull):  DR_STAGE2_SET=/path/to/set bash ...
# Automation/self-test passphrases: DR_PRIMARY_PASS / DR_ESCROW_PASS (else hidden prompt).
# Overrides: DR_P_FPR DR_E_FPR DR_RECOVERY_DIR DR_N8N_EXPECTED DR_ENV
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENVF="${DR_ENV:-$HERE/dr_weekly_backup.env}"
P_FPR="${DR_P_FPR:-AD834A2029AA703FA41B119B9D9E63310CA63035}"
E_FPR="${DR_E_FPR:-1C06355EE5FA56C9170B86206B9FA93CA44356BB}"
REC="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
N8N_EXPECTED="${DR_N8N_EXPECTED:-88}"
FAIL=0; die(){ echo "ABORT: $*" >&2; exit 1; }
no(){ echo "FAIL [$1]: ${2:-}"; FAIL=$((FAIL+1)); }
ok(){ echo "PASS [$1]: ${2:-}"; }
command -v gpg >/dev/null && command -v pg_restore >/dev/null && command -v git >/dev/null || die "need gpg, pg_restore, git"
[ -d /dev/shm ] && RAM=/dev/shm || RAM=/tmp
export TMPDIR="$RAM"
WORK=$(mktemp -d "$RAM/dr-stage2.XXXXXX"); chmod 700 "$WORK"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

getpass(){ local _e="${!1:-}" _x; if [ -n "$_e" ]; then _x="$_e"; else printf '%s' "$2" >&2; read -rs _x; echo >&2; fi
  _x="${_x%$'\r'}"; _x="${_x%$'\n'}"   # strip a trailing CR/LF a Windows/WSL terminal may append (agent cache masks it; an isolated keyring does not)
  [ -n "$_x" ] || die "empty passphrase"; printf '%s' "$_x"; }

SET=""
if [ -n "${DR_STAGE2_SET:-}" ]; then
  SET="$DR_STAGE2_SET"; echo "== verify-only mode: $SET (orchestrator + pull skipped) =="
else
  # ---------- PRECHECK: creds + both recipients + n8n creds (names only) ----------
  [ -f "$ENVF" ] || die "env file not found: $ENVF"
  # Load ONLY assignment lines (strip BOM+CR, then keep KEY=val) so a malformed comment/junk
  # line in the env file can never be executed by the shell (root cause of "c#: command not found").
  set -a; . <(sed -e "1s/^$(printf '\357\273\277')//" -e 's/\r$//' "$ENVF" | grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' || true); set +a
  for v in SUPABASE_DB_URL SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY N8N_BASE_URL N8N_API_KEY DR_GPG_RECIPIENT DR_GPG_RECIPIENT_2; do
    [ -n "${!v:-}" ] || die "required config MISSING: $v (n8n creds are mandatory here so n8n cannot be skipped)"
  done
  [ -n "${DR_BACKUP_PARENT:-}${DR_REMOTE:-}" ] || die "DR destination MISSING (DR_BACKUP_PARENT/DR_REMOTE)"
  gpg --list-keys --no-auto-key-locate "$DR_GPG_RECIPIENT"   >/dev/null 2>&1 || die "PRIMARY recipient not a local key"
  gpg --list-keys --no-auto-key-locate "$DR_GPG_RECIPIENT_2" >/dev/null 2>&1 || die "ESCROW recipient not a local key"
  echo "PRECHECK OK — creds present, both recipients local, n8n creds present"
  # ---------- RUN ORCHESTRATOR (fail-closed) ----------
  bash "$HERE/dr_weekly_backup.sh" --env "$ENVF"; RC=$?
  [ "$RC" = 0 ] || die "orchestrator exit=$RC (backup FAILED — nothing uploaded as success)"
  RUNSTATUS=$(ls -t "$HOME"/strateloq-backups/runs/*/STATUS 2>/dev/null | head -1)
  [ -n "$RUNSTATUS" ] && grep -q SUCCESS "$RUNSTATUS" || die "run STATUS not SUCCESS"
  LOG="$(dirname "$RUNSTATUS")/backup.log"
  for comp in db-dump git-bundle storage n8n-export; do
    grep -q "$comp=PASS" "$LOG" || die "component not PASS: $comp (n8n SKIP is a failure here)"
  done
  COV=$(grep -h 'n8n coverage' "$LOG" | tail -1); echo "$COV"
  TOT=$(printf '%s' "$COV" | sed -n 's/.*total=\([0-9]\+\).*/\1/p')
  [ "${TOT:-0}" -ge "$N8N_EXPECTED" ] || die "n8n coverage total=${TOT:-?} < expected $N8N_EXPECTED"
  ok components "all 4 present; n8n total=$TOT (>= $N8N_EXPECTED)"
  # ---------- PULL the set ----------
  WREMOTE="${DR_REMOTE:-$DR_BACKUP_PARENT/weekly}"
  TS=$(rclone lsf "$WREMOTE" --dirs-only | sort | tail -1 | sed 's#/$##')
  SET="$HOME/restore/$TS"; mkdir -p "$SET"; rclone copy "$WREMOTE/$TS" "$SET"
  ( cd "$SET" && rclone check . "$WREMOTE/$TS" --one-way ) && ok drive-upload "remote checksums match local" || no drive-upload "remote mismatch"
fi

# ---------- INTEGRITY (SHA-256) ----------
[ -f "$SET/SHA256SUMS" ] || die "SHA256SUMS missing in set"
( cd "$SET" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok integrity "sha256 manifest verified" || no integrity "sha256 mismatch"

# ---------- locate the 4 components ----------
DB=$(ls "$SET"/strateloq-db-*.dump.gpg 2>/dev/null | head -1)
STG=$(ls "$SET"/strateloq-storage-*.tgz.gpg 2>/dev/null | head -1)
SRC=$(ls "$SET"/strateloq-*.bundle.gpg 2>/dev/null | head -1)
N8=$(ls "$SET"/strateloq-n8n-*.tar.gpg 2>/dev/null | head -1)
for pair in "db:$DB" "storage:$STG" "source:$SRC" "n8n:$N8"; do
  [ -n "${pair#*:}" ] && [ -f "${pair#*:}" ] && ok "present-${pair%%:*}" "$(basename "${pair#*:}")" || no "present-${pair%%:*}" "component artifact missing"
done

# ---------- exactly TWO recipients on the DB (fail if !=2) ----------
if [ -n "$DB" ] && [ -f "$DB" ]; then
  NR=$(gpg --list-packets "$DB" 2>/dev/null | grep -c 'pubkey enc packet')
  [ "$NR" = 2 ] && ok recipients "exactly 2 pubkey-enc packets" || no recipients "expected 2 recipients, got $NR"
fi

# ---------- independent decrypt: PRIMARY alone, ESCROW alone (+ DB structure) ----------
PP=$(getpass DR_PRIMARY_PASS "PRIMARY passphrase (hidden): ")
EP=$(getpass DR_ESCROW_PASS  "ESCROW passphrase (hidden): ")
decrypt_db_with(){ # $1=fpr $2=pass $3=label
  local gh; gh=$(mktemp -d "$RAM/k.XXXXXX"); chmod 700 "$gh"
  echo "allow-loopback-pinentry" > "$gh/gpg-agent.conf"   # isolated home must allow loopback like ~/.gnupg
  if ! GNUPGHOME="$gh" gpg --batch --import "$REC/dr-$1.secret.asc" 2>"$gh/imp.log"; then
    no "decrypt-$3" "could not import $3 key export: $REC/dr-$1.secret.asc"; sed 's/^/     gpg: /' "$gh/imp.log" | head -3; rm -rf "$gh"; return; fi
  printf '%s' "$2" | GNUPGHOME="$gh" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$DB" >"$gh/d.dump" 2>"$gh/dec.log"
  if [ "$(head -c 5 "$gh/d.dump" 2>/dev/null)" = "PGDMP" ]; then
    ok "decrypt-$3" "$3 ALONE decrypts the DB (valid PGDMP archive)"
    if pg_restore -l "$gh/d.dump" >"$gh/toc" 2>"$gh/pgr.log"; then
      local n; n=$(grep -vc '^;' "$gh/toc")
      [ "${n:-0}" -gt 0 ] && ok "pgrestore-$3" "pg_restore -l: $n TOC entries" || no "pgrestore-$3" "pg_restore TOC empty"
    else
      no "pgrestore-$3" "pg_restore -l failed — local client ($(pg_restore --version 2>/dev/null | grep -oE '[0-9]+' | head -1)) may be older than the Supabase-17 dump; install postgresql-client-17"
      sed 's/^/     pg_restore: /' "$gh/pgr.log" | head -2
    fi
  elif grep -qi 'Bad passphrase' "$gh/dec.log"; then
    no "decrypt-$3" "$3 passphrase rejected by gpg: Bad passphrase (isolated keyring, agent-cache-independent) — value not shown"
    grep -i 'Bad passphrase' "$gh/dec.log" | head -1 | sed 's/^/     gpg: /'
  elif grep -qi 'No secret key' "$gh/dec.log"; then
    no "decrypt-$3" "$3 secret key NOT present/usable in the isolated keyring (import/capability issue, NOT a passphrase problem):"; sed 's/^/     gpg: /' "$gh/dec.log" | head -4
  else
    no "decrypt-$3" "$3 could not decrypt — true gpg diagnostics:"; sed 's/^/     gpg: /' "$gh/dec.log" | head -4
  fi
  rm -rf "$gh"
}
if [ -n "$DB" ] && [ -f "$DB" ]; then decrypt_db_with "$P_FPR" "$PP" PRIMARY; decrypt_db_with "$E_FPR" "$EP" ESCROW; fi

# ---------- contents: storage (tar), source (git bundle verify), n8n (count==inventory) ----------
dec(){ printf '%s' "$PP" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$1" 2>/dev/null; }  # uses PRIMARY
if [ -n "$STG" ] && [ -f "$STG" ]; then c=$(dec "$STG" | tar -tz 2>/dev/null | grep -c .); [ "${c:-0}" -gt 0 ] && ok contents-storage "$c entries" || no contents-storage "empty/untarable"; fi
if [ -n "$SRC" ] && [ -f "$SRC" ]; then dec "$SRC" > "$WORK/src.bundle"; git bundle verify "$WORK/src.bundle" >/dev/null 2>&1 && ok contents-source "git bundle verifies" || no contents-source "git bundle invalid"; rm -f "$WORK/src.bundle"; fi
if [ -n "$N8" ] && [ -f "$N8" ]; then jc=$(dec "$N8" | tar -t 2>/dev/null | grep -c '\.json$'); [ "${jc:-0}" -ge "$N8N_EXPECTED" ] && ok contents-n8n "$jc workflow json (>= $N8N_EXPECTED)" || no contents-n8n "n8n json count=${jc:-?} < $N8N_EXPECTED"; fi

unset PP EP
echo; echo "===== STAGE 2 RESULT: FAIL=$FAIL ====="
echo "temp (tmpfs) removed on exit; no plaintext written to persistent disk; history + production untouched."
if [ "$FAIL" = 0 ]; then
  echo "STAGE 2 = PASS — DB/storage/source(+Edge)/n8n fresh, two-recipient, integrity + both-key decrypt + contents verified."
  echo "Proceed to Stage 3 (isolated restore): fresh DB backup passed recovery verification."
else
  echo "STAGE 2 = FAIL ($FAIL) — do NOT proceed to Stage 3. See FAIL lines."
  exit 1
fi
