#!/usr/bin/env bash
# Strateloq DR — diagnose & durably fix GPG "agent_genkey failed: Permission denied" on WSL,
# for the case where a THROWAWAY/temp homedir generates keys fine but the REAL ~/.gnupg still fails.
#
# Why that happens: key generation works anywhere writable (e.g. /tmp), so a temp-homedir test can
# PASS while the real ~/.gnupg is still broken. The real homedir fails because something specific to
# it denies the agent's write of private-keys-v1.d/<FPR>.key:
#   * EACCES "Permission denied"      -> private-keys-v1.d not owned/writable by you (e.g. root-owned
#                                        residue of `sudo gpg`), or a filesystem (DrvFs/9p, /mnt/c)
#                                        where chmod/chown don't actually take effect
#   * EPERM  "Operation not permitted"-> immutable/append attribute (chattr +i/+a)
#   * EROFS  "Read-only file system"  -> mount is read-only
# This script identifies which, by probing a key-gen INTO THE REAL HOMEDIR with agent debug logging,
# then applies the matched fix and RE-VERIFIES IN THE REAL HOMEDIR (not /tmp).
#
# Durable remedy (sudo-free, non-destructive): if the in-place fix is not enough, move the broken
# ~/.gnupg aside (a rename needs write on ~ only, so it works even if a SUBdir is root-owned) and
# create a fresh one. The old directory is PRESERVED as ~/.gnupg.broken.<ts> (never deleted) so any
# existing keys can be re-imported. If ~ itself is on a non-native filesystem, it relocates GNUPGHOME
# to native ext4. It never creates or uses a root-owned key.
#
# Run as your normal user (e.g. strateloqbackup), NOT sudo:
#   scripts/dr/fix-gpg-agent-wsl.sh [--diagnose-only] [--reset-home]
set -uo pipefail

if [ "$(id -u)" = "0" ]; then
  echo "REFUSING to run as root — running gpg as root is what creates root-owned files that cause this." >&2
  echo "Re-run as your normal user (e.g. strateloqbackup), without sudo." >&2; exit 2
fi

MODE="auto"; [ "${1:-}" = "--diagnose-only" ] && MODE="diag"; [ "${1:-}" = "--reset-home" ] && MODE="reset"
GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"
ME="$(id -un)"; GRP="$(id -gn)"
echo "== GPG real-homedir fix ==  user=$ME  GNUPGHOME=$GNUPGHOME  gpg=$(gpg --version|head -1|awk '{print $NF}')"

native_fs() { case "$1" in ext2/ext3|ext4|xfs|btrfs|tmpfs|overlayfs|overlay) return 0;; *) return 1;; esac; }

print_next() {
  echo
  echo "NEXT (interactive — you type the passphrase; it is never printed or stored):"
  echo "  export GPG_TTY=\$(tty)"
  if [ -n "${TARGET:-}" ] && [ "$TARGET" != "$HOME/.gnupg" ]; then
    echo "  export GNUPGHOME=$TARGET      # relocation above — also add this to ~/.bashrc"
  fi
  echo '  gpg --quick-generate-key "Strateloq Technologies Backup <support@strateloq.com>" rsa4096 encrypt 2y'
  echo "Then follow dr/runbook/GPG-KEY-AND-DB-BACKUP.md (key backup + database backup)."
}

# Probe: generate a throwaway RSA key INTO the given homedir; delete it on success.
# Returns 0 on success; on failure prints gpg's exact errno line (Permission denied / Operation not
# permitted / Read-only) which classifies the cause. Uses loopback passphrase (no interaction).
probe_genkey() {
  local gh="$1" pp fpr log rc
  mkdir -p "$gh/private-keys-v1.d" 2>/dev/null
  log="$(mktemp)"
  pp="probe-$RANDOM$RANDOM"
  GNUPGHOME="$gh" gpg --no-options --batch --yes --pinentry-mode loopback --passphrase "$pp" \
     --quick-generate-key "DR probe <probe@local.invalid>" rsa2048 encrypt 1y >/dev/null 2>"$log"
  rc=$?
  if [ $rc -eq 0 ]; then
    fpr="$(GNUPGHOME="$gh" gpg --with-colons --list-keys probe@local.invalid 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
    [ -n "$fpr" ] && GNUPGHOME="$gh" gpg --batch --yes --delete-secret-and-public-key "$fpr" >/dev/null 2>&1
    rm -f "$log"; return 0
  fi
  grep -iE "agent_genkey failed|Permission denied|Operation not permitted|Read-only|No such file" "$log" 2>/dev/null | sort -u | sed 's/^/     /'
  rm -f "$log"; return 1
}

# ---------------- DIAGNOSE ----------------
echo "--- filesystem under the homedir (must be native: ext4/xfs/btrfs; NOT 9p/drvfs/v9fs/9P) ---"
FST="$(stat -f -c '%T' "$GNUPGHOME" 2>/dev/null || stat -f -c '%T' "$HOME" 2>/dev/null)"
echo "  fs=$FST   $(findmnt -no SOURCE,FSTYPE,OPTIONS --target "$GNUPGHOME" 2>/dev/null || true)"
native_fs "$FST" || echo "  WARNING: '$FST' is not a native Linux fs — chmod/chown may not take effect; relocation needed."
case "$GNUPGHOME$HOME" in */mnt/*) echo "  WARNING: homedir is under a Windows mount (/mnt/...).";; esac
echo "--- ownership / perms / attributes / ACL (what a plain 'ls -l' check misses) ---"
ls -lan "$GNUPGHOME" 2>/dev/null | sed 's/^/  /' || echo "  (absent)"
[ -e "$GNUPGHOME/private-keys-v1.d" ] && { echo "  private-keys-v1.d:"; ls -land "$GNUPGHOME/private-keys-v1.d" | sed 's/^/    /'; }
command -v lsattr >/dev/null && { echo "  lsattr:"; lsattr -d "$GNUPGHOME" "$GNUPGHOME/private-keys-v1.d" 2>/dev/null | sed 's/^/    /'; }
command -v getfacl >/dev/null && { echo "  getfacl private-keys-v1.d:"; getfacl -p "$GNUPGHOME/private-keys-v1.d" 2>/dev/null | grep -vE '^#' | sed 's/^/    /'; }
FOREIGN="$(find "$GNUPGHOME" ! -user "$ME" 2>/dev/null)"
[ -n "$FOREIGN" ] && { echo "  foreign-owned (NOT $ME):"; echo "$FOREIGN" | sed 's/^/    /'; }
echo "--- gpg-agent processes (flag any not owned by $ME, or bound to this homedir) ---"
ps -eo user=,pid=,args= 2>/dev/null | grep '[g]pg-agent' | sed 's/^/  /' || echo "  (none running)"
echo "--- probe: generate a throwaway key INTO THE REAL homedir (captures the exact errno) ---"
if probe_genkey "$GNUPGHOME"; then echo "  REAL-homedir key-gen already WORKS."; REAL_OK=1; else echo "  REAL-homedir key-gen FAILS (see agent lines above)."; REAL_OK=0; fi

[ "$MODE" = "diag" ] && { echo "diagnose-only: no changes made."; exit 0; }
[ "${REAL_OK:-0}" = 1 ] && [ "$MODE" != "reset" ] && { echo "Nothing to fix — proceed to create your real key (see runbook)."; exit 0; }

# ---------------- IN-PLACE FIX (skip straight to reset if --reset-home) ----------------
echo "--- stopping gpg-agent(s) for $ME ---"
GNUPGHOME="$GNUPGHOME" gpgconf --kill all 2>/dev/null || true
pkill -u "$ME" gpg-agent 2>/dev/null || true

if [ "$MODE" != "reset" ]; then
  # clear immutable/append (needs root); strip ACLs; fix ownership (needs root); fix perms
  if command -v lsattr >/dev/null && lsattr -d "$GNUPGHOME/private-keys-v1.d" 2>/dev/null | grep -q '[ia]'; then
    echo "--- clearing immutable/append attribute ---"
    chattr -i -a -R "$GNUPGHOME" 2>/dev/null || { echo "  need root: sudo chattr -i -a -R \"$GNUPGHOME\"  (then re-run)"; }
  fi
  if command -v getfacl >/dev/null && getfacl -p "$GNUPGHOME/private-keys-v1.d" 2>/dev/null | grep -q '^user:[^:]'; then
    echo "--- stripping extra ACLs ---"; setfacl -b "$GNUPGHOME" "$GNUPGHOME/private-keys-v1.d" 2>/dev/null || true
  fi
  if [ -n "$FOREIGN" ]; then
    echo "--- repairing ownership -> $ME:$GRP ---"
    if sudo -n true 2>/dev/null; then sudo chown -R "$ME:$GRP" "$GNUPGHOME"; else echo "  (will use the sudo-free homedir reset instead)"; fi
  fi
  mkdir -p "$GNUPGHOME/private-keys-v1.d" "$GNUPGHOME/openpgp-revocs.d" 2>/dev/null
  chmod 700 "$GNUPGHOME" 2>/dev/null; find "$GNUPGHOME" -type d -exec chmod 700 {} + 2>/dev/null
  find "$GNUPGHOME" -type f -exec chmod 600 {} + 2>/dev/null
  touch "$GNUPGHOME/gpg-agent.conf" 2>/dev/null; chmod 600 "$GNUPGHOME/gpg-agent.conf" 2>/dev/null
  grep -q '^pinentry-program' "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || echo "pinentry-program /usr/bin/pinentry-curses" >> "$GNUPGHOME/gpg-agent.conf"
  gpgconf --create-socketdir 2>/dev/null || true
  echo "--- verifying IN THE REAL homedir ---"
  if probe_genkey "$GNUPGHOME"; then
    echo "RESULT: PASS — real homedir now generates keys (verified in $GNUPGHOME)."; print_next; exit 0
  fi
  echo "In-place fix insufficient — applying the durable homedir reset (old dir preserved)."
fi

# ---------------- DURABLE RESET (sudo-free, non-destructive) ----------------
if [ ! -w "$HOME" ]; then echo "ERROR: \$HOME ($HOME) is not writable by $ME — cannot reset safely." >&2; exit 1; fi
TARGET="$GNUPGHOME"
if ! native_fs "$FST"; then
  TARGET="$HOME/.gnupg"
  NFS="$(stat -f -c '%T' "$HOME" 2>/dev/null)"
  if ! native_fs "$NFS"; then
    echo "ERROR: \$HOME is also on a non-native fs ($NFS). Put GNUPGHOME on ext4 (the WSL VHD), e.g.:" >&2
    echo "  mkdir -p /home/$ME/.gnupg-dr && chmod 700 /home/$ME/.gnupg-dr && export GNUPGHOME=/home/$ME/.gnupg-dr" >&2
    echo "  (add that export to ~/.bashrc). Then re-run this script." >&2; exit 1
  fi
  echo "Relocating to native fs: GNUPGHOME=$TARGET"
fi
TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -e "$TARGET" ]; then
  echo "--- moving $TARGET aside -> $TARGET.broken.$TS (preserved, NOT deleted) ---"
  mv "$TARGET" "$TARGET.broken.$TS"
fi
mkdir -p "$TARGET/private-keys-v1.d" "$TARGET/openpgp-revocs.d"
chmod 700 "$TARGET" "$TARGET/private-keys-v1.d" "$TARGET/openpgp-revocs.d"
echo "pinentry-program /usr/bin/pinentry-curses" > "$TARGET/gpg-agent.conf"; chmod 600 "$TARGET/gpg-agent.conf"
grep -q 'GPG_TTY' "$HOME/.bashrc" 2>/dev/null || echo 'export GPG_TTY=$(tty)' >> "$HOME/.bashrc"
GNUPGHOME="$TARGET" gpgconf --create-socketdir 2>/dev/null || true
GNUPGHOME="$TARGET" gpgconf --launch gpg-agent 2>/dev/null || true

echo "--- verifying IN THE REAL homedir ($TARGET) ---"
if probe_genkey "$TARGET"; then
  echo "RESULT: PASS — $TARGET now generates keys (verified in the real homedir)."
  [ "$TARGET" != "$HOME/.gnupg" ] && echo "NOTE: set 'export GNUPGHOME=$TARGET' in ~/.bashrc so all tools use it."
  echo "Old keyring preserved at ${TARGET}.broken.$TS (re-import with: gpg --import <that>/*.gpg if it held real keys)."
  print_next; exit 0
else
  echo "RESULT: FAIL — still cannot generate in $TARGET. Re-run with --diagnose-only and send the output;"
  echo "the agent lines above name the exact path/errno. A non-native filesystem is the likely remaining cause."
  exit 1
fi
