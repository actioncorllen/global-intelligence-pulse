#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — OFFLINE USB recovery verification.
#
# Proves USB D: holds a COMPLETE, independently-recoverable offline backup set, WITHOUT deleting,
# overwriting or modifying anything already on the drive. It:
#   1. inspects the USB and free space;
#   2. copies the verified set (default 20261107T113707Z) into a NEW clearly-named folder (cp -n,
#      never clobbering existing files) — database, Storage, source, n8n and SHA256SUMS;
#   3. verifies the copied files against the set's own SHA256SUMS manifest;
#   4. confirms the PRIMARY recovery-key file on the USB matches its known-good checksum AND imports
#      with the expected fingerprint;
#   5. confirms the PRIMARY key decrypts the COPIED database archive (reusing the existing local
#      gpg-agent — no new keys, at most one passphrase prompt if the agent cache has expired).
# Plaintext from the decrypt test is written only to local tmpfs and shredded; nothing on the USB is
# modified except the one new backup folder. Idempotent: a re-run re-verifies and copies only what is
# missing. A concise PASS/FAIL report is printed and saved to $HOME.
#
# Windows D: is /mnt/d under WSL. Override with DR_USB. Other env: DR_SET_TS, DR_SET_SRC (source dir of
# the set; auto-discovered if unset), DR_RECOVERY_DIR, DR_P_FPR, DR_STATE, DR_PRIMARY_KEY_SHA256.
# =============================================================================
set -uo pipefail

DR_USB="${DR_USB:-/mnt/d}"
DR_SET_TS="${DR_SET_TS:-20261107T113707Z}"
DR_RECOVERY_DIR="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
DR_P_FPR="${DR_P_FPR:-AD834A2029AA703FA41B119B9D9E63310CA63035}"
DR_STATE="${DR_STATE:-$HOME/.strateloq-dr}"
TARGET="$DR_USB/Strateloq-Verified-Backup-$DR_SET_TS"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$HOME/strateloq-usb-verify-report-${TS}.md"
PASS=0; FAIL=0; SKIP=0

[ -d /dev/shm ] && RAM=/dev/shm || RAM=/tmp
export TMPDIR="$RAM"; WORK="$(mktemp -d "$RAM/dr-usb.XXXXXX")"; chmod 700 "$WORK"
GH="$DR_STATE/gnupg"; PP=""; UNLOCKED=0; USE_AGENT=0

log(){ printf '%s\n' "$*" >> "$REPORT"; }
con(){ printf '%s\n' "$*"; }
sect(){ con ""; con "== $* =="; log ""; log "## $*"; }
pass(){ PASS=$((PASS+1)); con "  [PASS] $*"; log "- **PASS** — $*"; }
fail(){ FAIL=$((FAIL+1)); con "  [FAIL] $*" >&2; log "- **FAIL** — $*"; }
skip(){ SKIP=$((SKIP+1)); con "  [SKIP] $*"; log "- **SKIP** — $*"; }
info(){ con "        $*"; log "    - $*"; }
die(){ con "ABORT: $*" >&2; log "ABORT: $*"; printf '%s\n' "see $REPORT"; exit 2; }
cleanup(){ set +e; find "$WORK" -type f -exec shred -u {} \; >/dev/null 2>&1; rm -rf "$WORK"; unset PP; }
trap cleanup EXIT INT TERM

# ---- reuse the existing gpg-agent unlock (isolated keyring, PRIMARY only; cached => no prompt) ----
preset_bin(){ command -v gpg-preset-passphrase 2>/dev/null || { for p in /usr/lib/gnupg/gpg-preset-passphrase /usr/libexec/gpg-preset-passphrase /usr/lib/gnupg2/gpg-preset-passphrase; do [ -x "$p" ] && { echo "$p"; return; }; done; }; }
grips(){ GNUPGHOME="$GH" gpg --batch --with-keygrip --list-secret-keys --with-colons 2>/dev/null|awk -F: '/^grp:/{print $10}'; }
any_cached(){ local g; for g in $(grips); do GNUPGHOME="$GH" gpg-connect-agent "keyinfo $g" /bye 2>/dev/null|awk '/^S KEYINFO/{print $7}'|grep -q '^1$' && return 0; done; return 1; }
ensure_unlocked(){ [ "$UNLOCKED" = 1 ] && return 0
  local kf="$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc"; [ -f "$kf" ] || kf="$USB_KEY"
  [ -f "$kf" ] || { info "no PRIMARY key file to import for decrypt"; return 1; }
  mkdir -p "$GH"; chmod 700 "$GH"
  [ -f "$GH/gpg-agent.conf" ] || printf '%s\n' "allow-loopback-pinentry" "allow-preset-passphrase" "default-cache-ttl 3600" "max-cache-ttl 7200" > "$GH/gpg-agent.conf"
  GNUPGHOME="$GH" gpg --batch --import "$kf" 2>/dev/null
  # check the cache BEFORE any reload (reloadagent would flush the passphrase a prior run cached)
  if any_cached; then USE_AGENT=1; UNLOCKED=1; info "unlock: PRIMARY already cached in the local gpg-agent (no prompt)"; return 0; fi
  printf '%s\n' "allow-loopback-pinentry" "allow-preset-passphrase" "default-cache-ttl 3600" "max-cache-ttl 7200" > "$GH/gpg-agent.conf"
  GNUPGHOME="$GH" gpg-connect-agent reloadagent /bye >/dev/null 2>&1
  [ -r /dev/tty ] || { info "agent cache empty and no terminal — cannot decrypt without a prompt"; return 1; }
  printf 'PRIMARY backup-key passphrase (hidden, asked once): ' >&2; IFS= read -rs PP < /dev/tty; echo >&2
  PP="${PP%$'\r'}"; PP="${PP%$'\n'}"; [ -n "$PP" ] || { info "empty passphrase"; return 1; }
  local pb; pb="$(preset_bin)"
  if [ -n "$pb" ]; then local g ok=1; for g in $(grips); do printf '%s' "$PP"|GNUPGHOME="$GH" "$pb" --preset "$g" >/dev/null 2>&1 || ok=0; done
    { [ "$ok" = 1 ] && any_cached; } && { USE_AGENT=1; unset PP; info "unlock: PRIMARY cached in the local gpg-agent (bounded TTL)"; } || USE_AGENT=0
  else USE_AGENT=0; fi
  UNLOCKED=1
}
decrypt(){ ensure_unlocked || return 1
  if [ "$USE_AGENT" = 1 ]; then GNUPGHOME="$GH" gpg --batch --yes -d "$1" > "$2" 2>"$WORK/gpg.err"
  else printf '%s' "$PP"|GNUPGHOME="$GH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$1" > "$2" 2>"$WORK/gpg.err"; fi; }

con "Strateloq DR — offline USB verification  ($TS)"; log "# Strateloq DR — offline USB verification report"; log "Date: $TS · set: $DR_SET_TS · USB: $DR_USB"
for t in gpg sha256sum tar python3 cp df; do command -v "$t" >/dev/null 2>&1 || die "required tool missing: $t"; done

# ---- 1. inspect USB + free space; preserve existing ----
sect "1. USB inspection (read-only; nothing existing is touched)"
[ -d "$DR_USB" ] || die "USB not found at $DR_USB (is D: mounted? in WSL it appears as /mnt/d)"
pass "USB present at $DR_USB"
info "free space: $(df -h "$DR_USB" | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
AVAIL_KB="$(df -Pk "$DR_USB" | awk 'NR==2{print $4}')"
info "existing top-level entries (preserved):"
ls -1 "$DR_USB" 2>/dev/null | sed 's/^/        • /' | tee -a "$REPORT" >/dev/null; ls -1 "$DR_USB" 2>/dev/null | sed 's/^/          /'

# ---- locate the source set: local first, else retrieve the ENCRYPTED set from Google Drive ----
sect "Locate verified set $DR_SET_TS (local, else rclone from Google Drive)"
DR_RCLONE_REMOTE="${DR_RCLONE_REMOTE:-strateloqdrive}"
DR_RCLONE_PATH="${DR_RCLONE_PATH:-Strateloq Technologies — Backups/weekly/$DR_SET_TS}"
SRC="${DR_SET_SRC:-}"
# (a) explicit / well-known local set dirs
if [ -z "$SRC" ]; then
  for d in "$HOME/restore/$DR_SET_TS" "$HOME/strateloq-backups/weekly/$DR_SET_TS" "$HOME/strateloq-backups/$DR_SET_TS" "$HOME/strateloq-backups/runs/$DR_SET_TS" "./$DR_SET_TS"; do
    [ -d "$d" ] && [ -f "$d/SHA256SUMS" ] && { SRC="$d"; break; }
  done
fi
# (b) broader local find for the set's DB archive (handles other layouts without globstar)
if [ -z "$SRC" ]; then
  HIT="$(find "$HOME" -maxdepth 5 -type f -name "strateloq-db-*${DR_SET_TS}*.dump.gpg" 2>/dev/null | head -1)"
  [ -n "$HIT" ] && [ -f "$(dirname "$HIT")/SHA256SUMS" ] && SRC="$(dirname "$HIT")"
fi
# (c) retrieve the existing ENCRYPTED set from Google Drive via the configured rclone remote.
#     This downloads .gpg files only — it is NOT a new backup, and nothing is uploaded.
if [ -z "$SRC" ] || [ ! -f "$SRC/SHA256SUMS" ]; then
  if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx "${DR_RCLONE_REMOTE}:"; then
    STAGE="$HOME/restore/$DR_SET_TS"; mkdir -p "$STAGE"
    info "set not present locally — retrieving from ${DR_RCLONE_REMOTE}:${DR_RCLONE_PATH} (encrypted .gpg only; no new backup, no upload)"
    if rclone copy "${DR_RCLONE_REMOTE}:${DR_RCLONE_PATH}" "$STAGE" --transfers 4 --checkers 8 --retries 3 2>"$WORK/rclone.log"; then
      if [ -f "$STAGE/SHA256SUMS" ]; then SRC="$STAGE"; pass "retrieved the verified set from Google Drive to $STAGE"
      else info "rclone copy finished but SHA256SUMS not found under $STAGE (check DR_RCLONE_PATH)"; fi
    else info "rclone copy failed: $(tail -n1 "$WORK/rclone.log" 2>/dev/null)"; fi
  else
    info "rclone not installed or remote '${DR_RCLONE_REMOTE}:' not configured — cannot retrieve from Drive"
  fi
fi
[ -n "$SRC" ] && [ -d "$SRC" ] && [ -f "$SRC/SHA256SUMS" ] || die "could not locate or retrieve set $DR_SET_TS (local dirs + rclone ${DR_RCLONE_REMOTE}:${DR_RCLONE_PATH}). Set DR_SET_SRC=/path, or DR_RCLONE_PATH to the Drive folder, and re-run."
pass "source set located: $SRC"
SET_KB="$(du -sk "$SRC" | awk '{print $1}')"
[ "${AVAIL_KB:-0}" -gt "$((SET_KB + 51200))" ] && pass "free space sufficient (set ≈ $((SET_KB/1024)) MB, free ≈ $((AVAIL_KB/1024)) MB)" || fail "insufficient free space (need ≈ $((SET_KB/1024)) MB, free ≈ $((AVAIL_KB/1024)) MB) — NOT copying"

# ---- 2+3+4. copy the set into a NEW folder (cp -n never overwrites existing) ----
sect "2–4. Copy set into $TARGET (cp -n; existing USB files untouched)"
if [ "${AVAIL_KB:-0}" -gt "$((SET_KB + 51200))" ]; then
  mkdir -p "$TARGET"
  cp -n -p "$SRC"/* "$TARGET"/ 2>/dev/null
  pass "copied set into new folder: $TARGET (older USB backups and ZIPs left unchanged)"
else skip "copy skipped due to space check above"; fi
DB_USB="$(ls "$TARGET"/strateloq-db-*.dump.gpg 2>/dev/null|head -1)"
for pair in "database:$(ls "$TARGET"/strateloq-db-*.dump.gpg 2>/dev/null|head -1)" \
            "storage:$(ls "$TARGET"/strateloq-storage-*.tgz.gpg 2>/dev/null|head -1)" \
            "source:$(ls "$TARGET"/strateloq-*.bundle.gpg 2>/dev/null|head -1)" \
            "n8n:$(ls "$TARGET"/strateloq-n8n-*.tar.gpg 2>/dev/null|head -1)" \
            "SHA256SUMS:$(ls "$TARGET"/SHA256SUMS 2>/dev/null|head -1)"; do
  nm="${pair%%:*}"; pth="${pair#*:}"; [ -n "$pth" ] && [ -f "$pth" ] && pass "component present on USB: $nm ($(basename "$pth"))" || fail "component MISSING on USB: $nm"
done

# ---- 5. verify copied files against the set's SHA256SUMS ----
sect "5. Integrity of copied files vs SHA256SUMS"
if [ -f "$TARGET/SHA256SUMS" ]; then
  ( cd "$TARGET" && sha256sum -c SHA256SUMS >"$WORK/sums.out" 2>&1 )
  if [ $? -eq 0 ]; then pass "all copied files verify against SHA256SUMS ($(grep -c ': OK' "$WORK/sums.out") files)"
  else fail "sha256 verification FAILED on USB copy"; grep -v ': OK' "$WORK/sums.out"|sed 's/^/        /'|tee -a "$REPORT" >/dev/null; grep -v ': OK' "$WORK/sums.out"|sed 's/^/        /'; fi
else fail "no SHA256SUMS in $TARGET"; fi

# ---- 6. PRIMARY recovery-key file on USB: checksum + identity ----
sect "6. PRIMARY recovery-key on USB (checksum + fingerprint)"
KEYS_DIR="$(find "$DR_USB" -maxdepth 1 -type d -iname '*Recovery-Keys*' 2>/dev/null|head -1)"
USB_KEY=""
if [ -n "$KEYS_DIR" ]; then
  while IFS= read -r cand; do
    gh2="$WORK/kchk"; rm -rf "$gh2"; mkdir -p "$gh2"; chmod 700 "$gh2"
    fpr="$(GNUPGHOME="$gh2" gpg --batch --import "$cand" 2>/dev/null; GNUPGHOME="$gh2" gpg --batch --with-colons --list-keys 2>/dev/null|awk -F: '/^fpr:/{print $10;exit}')"
    rm -rf "$gh2"
    [ "$fpr" = "$DR_P_FPR" ] && { USB_KEY="$cand"; break; }
  done < <(find "$KEYS_DIR" -type f \( -iname '*.asc' -o -iname '*.gpg' -o -iname '*.key' \) 2>/dev/null)
fi
if [ -n "$USB_KEY" ]; then
  pass "PRIMARY key file found on USB and imports with the expected fingerprint $DR_P_FPR ($(basename "$USB_KEY"))"
  usb_sha="$(sha256sum "$USB_KEY"|awk '{print $1}')"
  good="${DR_PRIMARY_KEY_SHA256:-}"; [ -z "$good" ] && [ -f "$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc" ] && good="$(sha256sum "$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc"|awk '{print $1}')"
  if [ -n "$good" ]; then [ "$usb_sha" = "$good" ] && pass "USB PRIMARY key sha256 matches the known-good copy (${usb_sha:0:16}…)" || fail "USB PRIMARY key sha256 ${usb_sha:0:16}… does NOT match known-good ${good:0:16}…"
  else skip "no known-good reference checksum available (set DR_PRIMARY_KEY_SHA256 or keep dr-<fpr>.secret.asc in $DR_RECOVERY_DIR); fingerprint identity verified above"; fi
else fail "no PRIMARY key file matching fingerprint $DR_P_FPR found under $DR_USB (Recovery-Keys folder)"; fi

# ---- 7. PRIMARY decrypts the COPIED database archive ----
sect "7. PRIMARY decrypts the COPIED database archive (offline recoverability)"
if [ -n "$DB_USB" ] && [ -f "$DB_USB" ]; then
  if decrypt "$DB_USB" "$WORK/db.plain"; then
    [ "$(head -c5 "$WORK/db.plain")" = "PGDMP" ] && pass "PRIMARY key decrypts the USB database archive to a valid PostgreSQL dump (PGDMP) — offline recovery proven" || fail "decrypt produced non-PGDMP output"
    shred -u "$WORK/db.plain" 2>/dev/null || rm -f "$WORK/db.plain"
  else fail "PRIMARY could not decrypt the USB database archive"; sed 's/^/        gpg: /' "$WORK/gpg.err" 2>/dev/null|head -3; fi
else skip "no database archive on USB to decrypt"; fi

# ---- report ----
sect "Result"
RESULT="PASS"; [ "$FAIL" -gt 0 ] && RESULT="FAIL"
con ""; con "OFFLINE USB VERIFICATION: $RESULT   (pass=$PASS fail=$FAIL skip=$SKIP)"
log ""; log "**OFFLINE USB VERIFICATION: $RESULT** — pass=$PASS, fail=$FAIL, skip=$SKIP"
log "Existing USB files/folders were not deleted, overwritten or modified; only the new folder $TARGET was added. No new keys; plaintext shredded."
con "Report: $REPORT"
cp -f "$REPORT" "$TARGET/VERIFICATION-REPORT-${TS}.md" 2>/dev/null && con "Report copy saved alongside the set on USB."
[ "$FAIL" -eq 0 ]
