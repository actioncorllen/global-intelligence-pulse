#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — hardened LOCAL key generation + independent verification.
# Generates PRIMARY + ESCROW RSA-4096 OpenPGP keys, protects each, verifies each in an
# ISOLATED keyring, and proves PRIMARY-alone AND ESCROW-alone each decrypt the SAME test
# archive. FAIL-CLOSED: aborts on any keygen/export/verify failure; never treats an empty or
# incomplete export as success. Does NOT touch production recipients, scheduled tasks, existing
# archives, or historical keys (it only ADDS two new keys). STOPS before config activation (Step D).
# Run as strateloqbackup on WSL, never sudo. Reuses the committed scripts/dr/dr_verify_offline_key.sh.
#
# Passphrases: hidden interactive prompt by default; for automation/self-test only, via
#   DR_PRIMARY_PASS / DR_ESCROW_PASS. Never pass them on argv.
# Overrides (defaults are the real layout): DR_PRIMARY_UID DR_ESCROW_UID DR_RECOVERY_DIR DR_RAMDIR
# Self-test: DR_KEYGEN_SELFTEST=1 uses a throwaway GNUPGHOME + throwaway UIDs (no real keyring touched).
# =============================================================================
set -uo pipefail
RAMDIR="${DR_RAMDIR:-/dev/shm}"
REC="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
PRIMARY_UID="${DR_PRIMARY_UID:-Strateloq DR Primary <dr-primary@strateloq.com>}"
ESCROW_UID="${DR_ESCROW_UID:-Strateloq DR Escrow <dr-escrow@strateloq.com>}"
PASS=0; FAIL=0
ok(){ echo "PASS: $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
die(){ echo "ABORT: $*" >&2; exit 1; }

command -v gpg >/dev/null || die "gpg not found"
[ -f scripts/dr/dr_verify_offline_key.sh ] || die "run from the repo root (scripts/dr/dr_verify_offline_key.sh not found)"
[ -d "$RAMDIR" ] || { RAMDIR=/tmp; echo "WARN: tmpfs $RAMDIR absent; using /tmp (persistent-disk risk)"; }
umask 077
WORK=$(mktemp -d "$RAMDIR/dr-keygen.XXXXXX") || die mktemp; chmod 700 "$WORK"
export TMPDIR="$RAMDIR"
cleanup(){ rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

if [ "${DR_KEYGEN_SELFTEST:-0}" = 1 ]; then
  export GNUPGHOME="$WORK/selftest-home"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  echo "allow-loopback-pinentry" > "$GNUPGHOME/gpg-agent.conf"; gpgconf --kill all >/dev/null 2>&1 || true
  PRIMARY_UID="Selftest Primary <selftest-primary@example.invalid>"
  ESCROW_UID="Selftest Escrow <selftest-escrow@example.invalid>"
  REC="$WORK/recovery"
  echo "== SELF-TEST MODE: throwaway GNUPGHOME=$GNUPGHOME; real keyring untouched =="
fi
mkdir -p "$REC"

echo "===== Strateloq DR — key generation + independent verification ====="
echo "--- swap exposure (Req 10): tmpfs can page to swap under memory pressure ---"
swapon --show 2>/dev/null | sed 's/^/   /' || echo "   (swapon not available)"
[ -n "$(swapon --show 2>/dev/null)" ] && echo "   WARN: swap active — optional (needs sudo): 'sudo swapoff -a' before, 'sudo swapon -a' after." || echo "   no swap active"

echo "--- existing keyring (READ-ONLY; historical keys preserved — Req 2/11) ---"
PRE_KEYS=$(gpg --list-keys --with-colons 2>/dev/null | grep -c '^pub') || true
echo "   existing public keys before: $PRE_KEYS (none will be modified or deleted)"

# ---- passphrase capture (hidden; guard against empty + the >900B agent-IPC overflow) ----
getpass(){ # $1=label $2=envname
  local _l="$1" _e="${!2:-}" _x
  if [ -n "$_e" ]; then _x="$_e"; else printf '%s' "$_l" >&2; read -rs _x; echo >&2; fi
  [ -n "$_x" ] || die "empty passphrase ($_l)"
  [ "${#_x}" -le 900 ] || die "passphrase >900 bytes would overflow the gpg-agent IPC"
  printf '%s' "$_x"
}

gen_and_export(){ # $1=UID $2=passphrase -> echoes FPR ; FAIL-CLOSED
  local uid="$1" pw="$2" fpr exp
  printf '%s' "$pw" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
     --quick-generate-key "$uid" rsa4096 encrypt 2y >/dev/null 2>"$WORK/gen.err" \
     || { sed 's/^/   gpg: /' "$WORK/gen.err" >&2; die "key generation failed for: $uid"; }
  fpr=$(gpg --list-keys --with-colons "$uid" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
  [ -n "$fpr" ] || die "could not read fingerprint after keygen for: $uid"
  exp="$REC/dr-$fpr.secret.asc"
  printf '%s' "$pw" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
     --export-secret-keys --armor "$fpr" > "$exp" 2>"$WORK/exp.err" \
     || { sed 's/^/   gpg: /' "$WORK/exp.err" >&2; die "secret export failed for $fpr"; }
  # Req 4/5: never accept an empty/incomplete export
  [ -s "$exp" ] || die "export is EMPTY for $fpr (0 bytes)"
  head -1 "$exp" | grep -q 'BEGIN PGP PRIVATE KEY BLOCK' || die "export is not a PRIVATE KEY BLOCK for $fpr"
  cp "$HOME/.gnupg/openpgp-revocs.d/$fpr.rev" "$REC/dr-$fpr.revoke.asc" 2>/dev/null || \
     cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$REC/dr-$fpr.revoke.asc" 2>/dev/null || true
  printf '%s' "$fpr"
}

echo "--- generate + export PRIMARY (Req 1,3,4,5,6) ---"
PP=$(getpass "NEW PRIMARY passphrase (hidden): " DR_PRIMARY_PASS)
FPRP=$(gen_and_export "$PRIMARY_UID" "$PP") || exit 1
ok "PRIMARY generated + protected export valid: $FPRP"
echo "--- generate + export ESCROW (separate passphrase) ---"
PE=$(getpass "NEW ESCROW passphrase (hidden, DIFFERENT): " DR_ESCROW_PASS)
[ "$PE" != "$PP" ] || die "ESCROW passphrase must differ from PRIMARY"
FPRE=$(gen_and_export "$ESCROW_UID" "$PE") || exit 1
ok "ESCROW generated + protected export valid: $FPRE"

echo "--- verify EACH independently in an isolated keyring (Req 8) — reuse committed verifier ---"
DR_GPG_PASSPHRASE="$PP" OFFLINE_KEY="$REC/dr-$FPRP.secret.asc" bash scripts/dr/dr_verify_offline_key.sh >"$WORK/vp.log" 2>&1
grep -q '^RESULT: PASS' "$WORK/vp.log" && grep -q "$FPRP" "$WORK/vp.log" && ok "PRIMARY verifier PASS ($FPRP)" || { sed 's/^/   /' "$WORK/vp.log"; die "PRIMARY verification FAILED"; }
DR_GPG_PASSPHRASE="$PE" OFFLINE_KEY="$REC/dr-$FPRE.secret.asc" bash scripts/dr/dr_verify_offline_key.sh >"$WORK/ve.log" 2>&1
grep -q '^RESULT: PASS' "$WORK/ve.log" && grep -q "$FPRE" "$WORK/ve.log" && ok "ESCROW verifier PASS ($FPRE)" || { sed 's/^/   /' "$WORK/ve.log"; die "ESCROW verification FAILED"; }

echo "--- two-recipient test: PRIMARY-alone AND ESCROW-alone each decrypt the SAME archive (Req 9) ---"
NONCE="strateloq-dr-2r-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
printf '%s' "$NONCE" > "$WORK/t.txt"
gpg --batch --yes --no-auto-key-locate --trust-model always --encrypt -r "$FPRP" -r "$FPRE" -o "$WORK/t.gpg" "$WORK/t.txt" 2>"$WORK/enc.err" \
   || { sed 's/^/   gpg: /' "$WORK/enc.err"; die "two-recipient encrypt failed"; }
NPKT=$(gpg --list-packets "$WORK/t.gpg" 2>/dev/null | grep -c 'pubkey enc packet')
[ "$NPKT" = "2" ] && ok "archive encrypted to BOTH recipients (2 pubkey-enc packets)" || no "expected 2 pubkey-enc packets, got $NPKT"
# isolated keyring with ONLY primary secret:
GHP="$WORK/ghP"; mkdir -p "$GHP"; chmod 700 "$GHP"
GNUPGHOME="$GHP" gpg --batch --import "$REC/dr-$FPRP.secret.asc" 2>/dev/null
DP=$(printf '%s' "$PP" | GNUPGHOME="$GHP" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$WORK/t.gpg" 2>/dev/null)
[ "$DP" = "$NONCE" ] && ok "PRIMARY ALONE decrypts the archive" || no "PRIMARY-alone decrypt failed"
# isolated keyring with ONLY escrow secret:
GHE="$WORK/ghE"; mkdir -p "$GHE"; chmod 700 "$GHE"
GNUPGHOME="$GHE" gpg --batch --import "$REC/dr-$FPRE.secret.asc" 2>/dev/null
DE=$(printf '%s' "$PE" | GNUPGHOME="$GHE" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$WORK/t.gpg" 2>/dev/null)
[ "$DE" = "$NONCE" ] && ok "ESCROW ALONE decrypts the archive" || no "ESCROW-alone decrypt failed"
unset PP PE DR_GPG_PASSPHRASE 2>/dev/null || true

POST_KEYS=$(gpg --list-keys --with-colons 2>/dev/null | grep -c '^pub') || true
echo; echo "===== RESULT: PASS=$PASS FAIL=$FAIL ====="
echo "keyring public keys: before=$PRE_KEYS after=$POST_KEYS (added the 2 new keys; historical keys preserved)"
echo "All secret-material handling stayed in $RAMDIR (tmpfs); protected exports in $REC (passphrase-protected, never plaintext)."
if [ "$FAIL" -eq 0 ]; then
  echo "KEYGEN+VERIFY = PASS"
  echo "  PRIMARY fingerprint : $FPRP"
  echo "  ESCROW  fingerprint : $FPRE"
  echo "  PRIMARY verification: PASS"
  echo "  ESCROW  verification: PASS"
  echo "  Two-recipient test  : PASS (either key alone decrypts)"
  echo "NEXT (founder, manual): move dr-<fpr>.secret.asc + revoke certs to SEPARATE offline locations;"
  echo "  store each passphrase in your password manager (one entry each). Then STOP — Step D (set"
  echo "  DR_GPG_RECIPIENT_2 in dr_weekly_backup.env) is a separate, approved activation, not done here."
else
  echo "KEYGEN+VERIFY = FAIL — see FAIL lines; nothing activated; historical keys/archives untouched."
  exit 1
fi
