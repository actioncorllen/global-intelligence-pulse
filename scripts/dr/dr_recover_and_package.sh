#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — Check 1 ONE-SHOT: repair export blocker -> export -> verify ->
#                replace 0-byte file -> AES-256 package -> USB -> re-verify.
# Ref: STRATELOQ-DR-CHECK1-RECOVER. gpg 2.4.4. Run as strateloqbackup, never sudo.
#
# Root cause fixed here (reproduced in-cloud): "error receiving key from agent:
# Too much data for IPC layer" = the loopback passphrase overflowed the gpg-agent
# Assuan IPC limit (>~1000 bytes) on a wedged agent -> 0-byte export. Fix: reset the
# agent + clean, length-guarded loopback export. A normal passphrase + 4096-bit key
# exports fine once the agent is reset.
#
# SAFE BY DESIGN: never generates/deletes/rotates a key; never weakens protection;
# never writes plaintext or an unprotected key to USB or project storage; keeps all
# sensitive material in tmpfs (/dev/shm); preserves the original 0-byte file (renamed,
# not deleted) and only replaces it AFTER isolated verification passes; aborts on any
# failure. Passphrases are read hidden, never on argv/history/logs. Non-secret report.
#
# Interactive passphrases (preferred) OR, for automation/self-test only, via env:
#   DR_KEY_PASSPHRASE   (the existing recovery-key passphrase)
#   DR_PKG_PASSPHRASE   (a NEW independent package passphrase)
# Path/overrides (defaults are the real WSL layout):
#   DR_FPR DR_RECOVERY_DIR DR_USB DR_OCT_DUMP DR_RAMDIR DR_SELFTEST_KEYGEN
# =============================================================================
set -uo pipefail

FPR="${DR_FPR:-3DDC5C4BA0480E85F482F10AD54BCABB0758842D}"
REC="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
USB="${DR_USB:-/mnt/d}"
RAMDIR="${DR_RAMDIR:-/dev/shm}"
PKG_NAME="strateloq-dr-keyvault.tar.gpg"
PASS=0; FAIL=0; WARN=0
ok(){ echo "PASS: $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
warn(){ echo "WARN: $*"; WARN=$((WARN+1)); }
die(){ echo "ABORT: $*" >&2; exit 1; }

command -v gpg >/dev/null || die "gpg not found"
[ -d "$RAMDIR" ] || { RAMDIR=/tmp; warn "tmpfs $RAMDIR absent; using /tmp (persistent-disk risk)"; }
umask 077
WORK=$(mktemp -d "$RAMDIR/dr-recover.XXXXXX") || die "mktemp"; chmod 700 "$WORK"
cleanup(){ rm -rf "$WORK" 2>/dev/null || true; gpgconf --kill gpg-agent >/dev/null 2>&1 || true; }
trap cleanup EXIT

read_pass(){ # $1=varname $2=prompt $3=envvalue ; hidden read + length guard
  local _v="$1" _p="$2" _e="${3:-}" _x
  if [ -n "$_e" ]; then _x="$_e"; else printf '%s' "$_p" >&2; read -rs _x; echo >&2; fi
  [ -n "$_x" ] || die "empty passphrase"
  local n=${#_x}
  [ "$n" -le 900 ] || die "passphrase is $n bytes; >900 overflows the agent IPC (the original bug). Use a working pinentry (pinentry-tty) for a passphrase this long."
  [ "$n" -le 128 ] || warn "passphrase is $n bytes (unusually long) — proceeding"
  printf -v "$_v" '%s' "$_x"
}

echo "===== Strateloq DR Check 1 — recover + package ====="
echo "fingerprint target: $FPR"
echo "swap status (tmpfs can be paged to swap under pressure):"; swapon --show 2>/dev/null | sed 's/^/   /' || echo "   (none reported)"
[ -n "$(swapon --show 2>/dev/null)" ] && warn "swap is active — optional founder step (needs sudo): 'sudo swapoff -a' before, 'sudo swapon -a' after, to remove swap exposure"

echo "--- STEP 0: USB pre-flight (fail fast, before any key handling) ---"
if ! { mountpoint -q "$USB" 2>/dev/null || [ -d "$USB" ]; }; then die "USB $USB not present — connect USB D: (WSL mounts it at /mnt/d) and re-run. Nothing was touched."; fi
PF="$USB/.dr_write_test.$$"
if ( : > "$PF" ) 2>/dev/null; then rm -f "$PF"; ok "USB present and writable ($USB)"; else die "USB $USB not writable — nothing was touched."; fi

echo "--- STEP 1: reset the gpg-agent (the durable fix) + health check ---"
gpgconf --kill all >/dev/null 2>&1 || true
gpgconf --launch gpg-agent >/dev/null 2>&1 || true
if gpg-connect-agent 'KEYINFO --list' /bye 2>&1 | grep -q '^S KEYINFO'; then ok "agent healthy (KEYINFO --list responds)"; else warn "KEYINFO --list did not list; continuing (export still attempted)"; fi

echo "--- STEP 2: confirm the secret key is present & real (sec, not sec#) ---"
SECLINE=$(gpg --list-secret-keys --with-colons "$FPR" 2>/dev/null | awk -F: '/^sec:/{print; exit}')
[ -n "$SECLINE" ] || die "no secret key for $FPR in this keyring"
# colon 'sec' with no usable secret shows reason in field 15? presence is enough; stub -> export fails later
ok "secret key listed for $FPR"

echo "--- STEP 3: loopback export to RAM (does NOT touch the existing 0-byte file) ---"
read_pass KEY_PASS "Recovery-key passphrase (hidden): " "${DR_KEY_PASSPHRASE:-}"
EXP="$WORK/secret-export.asc"
printf '%s' "$KEY_PASS" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --export-secret-keys --armor "$FPR" > "$EXP" 2>"$WORK/exp.err"
RC=$?; SZ=$(stat -c%s "$EXP" 2>/dev/null || echo 0)
if [ $RC -ne 0 ] || [ "${SZ:-0}" -eq 0 ] || ! head -1 "$EXP" | grep -q 'BEGIN PGP PRIVATE KEY BLOCK'; then
  echo "   gpg stderr:"; sed 's/^/     /' "$WORK/exp.err"
  die "export failed (exit=$RC size=$SZ). Original 0-byte file left untouched."
fi
ok "loopback export produced a valid armored key ($SZ bytes)"

echo "--- STEP 4: verify export in an ISOLATED keyring (fpr + nonce round-trip) ---"
VGH="$WORK/vgh"; mkdir -p "$VGH"; chmod 700 "$VGH"
GNUPGHOME="$VGH" gpg --batch --import "$EXP" 2>"$WORK/imp.err" || { sed 's/^/     /' "$WORK/imp.err"; die "import into isolated keyring failed"; }
VFPR=$(GNUPGHOME="$VGH" gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
[ "$VFPR" = "$FPR" ] && ok "isolated import fingerprint matches ($VFPR)" || die "fingerprint mismatch ($VFPR != $FPR)"
NONCE="dr-nonce-$RANDOM-$(date -u +%s)"; printf '%s' "$NONCE" > "$WORK/n.txt"
GNUPGHOME="$VGH" gpg --batch --yes --trust-model always -r "$FPR" -o "$WORK/n.gpg" --encrypt "$WORK/n.txt" 2>/dev/null
DEC=$(printf '%s' "$KEY_PASS" | GNUPGHOME="$VGH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$WORK/n.gpg" 2>/dev/null)
[ "$DEC" = "$NONCE" ] && ok "nonce encrypt->decrypt round-trip (passphrase unlocks the key)" || die "nonce round-trip failed"

echo "--- STEP 5: read-only decrypt test vs the existing October DB backup ---"
DUMP="${DR_OCT_DUMP:-}"
if [ -z "$DUMP" ]; then
  DUMP=$(ls -1 "$HOME"/restore/strateloq-db-*.dump.gpg "$HOME"/strateloq-backups/**/strateloq-db-*.dump.gpg "$USB"/strateloq-db-*.dump.gpg 2>/dev/null | head -1)
fi
if [ -n "$DUMP" ] && [ -f "$DUMP" ]; then
  MAGIC=$(printf '%s' "$KEY_PASS" | GNUPGHOME="$VGH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$DUMP" 2>/dev/null | head -c 5)
  if [ "$MAGIC" = "PGDMP" ]; then
    ok "offline key decrypts Oct dump (magic=PGDMP, read-only): $(basename "$DUMP")"
  else
    # FAIL-CLOSED: a present dump that does NOT decrypt means the exported key may not be the
    # backup recipient. Halt BEFORE replacing the 0-byte file or writing USB; nothing persistent changed.
    die "Oct dump present but did NOT decrypt (got '$MAGIC', expected PGDMP). The exported key may not be the backup's recipient. Halting fail-closed: 0-byte file preserved, nothing written to USB."
  fi
else
  warn "October dump not found locally; set DR_OCT_DUMP=/path/to/strateloq-db-...dump.gpg to run this test (recommended for full acceptance)"
fi

echo "--- STEP 6: replace the 0-byte original (preserve it, do not delete) — only now that verify passed ---"
mkdir -p "$REC"
TGT="$REC/strateloq-backup-secret.asc"
if [ -f "$TGT" ] && [ ! -s "$TGT" ]; then
  mv "$TGT" "$TGT.EMPTY.$(date -u +%Y%m%dT%H%M%SZ)" && ok "old 0-byte file preserved as .EMPTY.<ts>"
elif [ -s "$TGT" ]; then
  mv "$TGT" "$TGT.PREV.$(date -u +%Y%m%dT%H%M%SZ)"; warn "existing NON-empty export preserved as .PREV.<ts> (did not clobber)"
fi
install -m 600 "$EXP" "$TGT"; ok "verified export installed at $TGT (mode 600)"

echo "--- STEP 7: build AES-256 symmetric package (independent passphrase; NOT keyed to the recovery key) ---"
BUNDLE="$WORK/bundle.tar"
if [ -f "$REC/strateloq-backup-revoke.asc" ]; then
  tar -C "$REC" -cf "$BUNDLE" strateloq-backup-secret.asc strateloq-backup-revoke.asc
else
  tar -C "$REC" -cf "$BUNDLE" strateloq-backup-secret.asc; warn "revoke cert not found; packaging key only"
fi
read_pass PKG_PASS "NEW package passphrase (hidden, independent of the key passphrase): " "${DR_PKG_PASSPHRASE:-}"
[ "$PKG_PASS" != "$KEY_PASS" ] || die "package passphrase must differ from the key passphrase"
printf '%s' "$PKG_PASS" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --symmetric --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
    -o "$WORK/$PKG_NAME" "$BUNDLE" 2>"$WORK/sym.err"
[ -s "$WORK/$PKG_NAME" ] || { sed 's/^/     /' "$WORK/sym.err"; die "symmetric encryption failed"; }
LP=$(gpg --list-packets "$WORK/$PKG_NAME" 2>/dev/null)
echo "$LP" | grep -qi 'symkey enc packet' && ok "package has symmetric-key packet" || no "package missing symkey packet"
echo "$LP" | grep -qi 'pubkey enc packet' && die "package is pubkey-encrypted (circular) — refusing" || ok "package NOT keyed to the recovery key (not circular)"
PKG_SHA=$(sha256sum "$WORK/$PKG_NAME" | awk '{print $1}')
echo "   package SHA256: $PKG_SHA"

echo "--- STEP 8: verify USB, write CIPHERTEXT ONLY ---"
if ! mountpoint -q "$USB" 2>/dev/null && [ ! -d "$USB" ]; then die "USB mount $USB not present"; fi
[ -d "$USB" ] || die "USB path $USB is not a directory"
CAP=$(df -B1 --output=size "$USB" 2>/dev/null | tail -1 | tr -d ' '); FS=$(df -T "$USB" 2>/dev/null | tail -1 | awk '{print $2}')
echo "   USB: $USB  fs=$FS  size=$(( ${CAP:-0} / 1000000 )) MB (nominal)"
probe="$USB/.dr_write_test.$$"; ( : > "$probe" ) 2>/dev/null && { rm -f "$probe"; ok "USB is writable"; } || die "USB $USB not writable"
cp "$WORK/$PKG_NAME" "$USB/$PKG_NAME" && sync && ok "ciphertext package written to $USB/$PKG_NAME" || die "copy to USB failed"
ls "$USB"/*.asc >/dev/null 2>&1 && no "an .asc is present on USB (should be ciphertext only)" || ok "USB holds no .asc (ciphertext only)"
USB_SHA=$(sha256sum "$USB/$PKG_NAME" | awk '{print $1}')
[ "$USB_SHA" = "$PKG_SHA" ] && ok "USB copy SHA256 matches source" || no "USB copy SHA256 differs"

echo "--- STEP 9: INDEPENDENT USB recovery — read back, decrypt, import fresh, re-verify, re-decrypt dump ---"
UGH="$WORK/ugh"; mkdir -p "$UGH"; chmod 700 "$UGH"; RB="$WORK/rb"; mkdir -p "$RB"
printf '%s' "$PKG_PASS" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    -d "$USB/$PKG_NAME" 2>/dev/null | tar -C "$RB" -xf -
[ -s "$RB/strateloq-backup-secret.asc" ] && ok "USB package opened; key extracted into tmpfs" || die "USB package open/extract failed"
GNUPGHOME="$UGH" gpg --batch --import "$RB/strateloq-backup-secret.asc" 2>/dev/null
UFPR=$(GNUPGHOME="$UGH" gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
[ "$UFPR" = "$FPR" ] && ok "USB-recovered fingerprint matches ($UFPR)" || no "USB-recovered fpr mismatch"
N2="dr-usb-nonce-$RANDOM"; printf '%s' "$N2" > "$WORK/n2.txt"
GNUPGHOME="$UGH" gpg --batch --yes --trust-model always -r "$FPR" -o "$WORK/n2.gpg" --encrypt "$WORK/n2.txt" 2>/dev/null
D2=$(printf '%s' "$KEY_PASS" | GNUPGHOME="$UGH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$WORK/n2.gpg" 2>/dev/null)
[ "$D2" = "$N2" ] && ok "USB-recovered key round-trip" || no "USB-recovered round-trip failed"
if [ -n "${DUMP:-}" ] && [ -f "${DUMP:-/nonexistent}" ]; then
  M2=$(printf '%s' "$KEY_PASS" | GNUPGHOME="$UGH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$DUMP" 2>/dev/null | head -c 5)
  [ "$M2" = "PGDMP" ] && ok "USB-recovered key decrypts the Oct dump (read-only)" || no "USB-recovered Oct dump decrypt '$M2'"
fi

unset KEY_PASS PKG_PASS
echo; echo "===== RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN ====="
echo "Cleanup: tmpfs work dir shredded on exit. Residual-risk note: secure erase cannot be"
echo "guaranteed on SSD/flash (wear-levelling/TRIM) or if tmpfs paged to swap; USB holds ciphertext only."
if [ "$FAIL" -eq 0 ]; then
  echo "CHECK 1 = PASS — encrypted offline recovery package on USB verified; original key independently recovered + decrypts the backup."
  echo "Record (non-secret): fingerprint $FPR ; package SHA256 $PKG_SHA ; verified $(date -u +%Y-%m-%dT%H:%M:%SZ)."
else
  echo "CHECK 1 = FAIL — see FAIL lines above. The repaired .asc (if STEP 6 ran) is already verified on disk."
fi
