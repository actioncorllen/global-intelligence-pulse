#!/usr/bin/env bash
# Strateloq DR — diagnose & durably fix GPG "agent_genkey failed: Permission denied" on WSL.
#
# Root cause this repairs (reproduced + verified): gpg-agent runs as YOUR user but cannot write
# the new private key into ~/.gnupg/private-keys-v1.d because that directory (or files in it) are
# owned by root — the residue of an earlier `sudo gpg`. The public keybox is created fine, so
# ~/.gnupg "looks" OK and the socket exists, yet key generation fails. A top-level ~/.gnupg check
# misses the private-keys-v1.d subdirectory.
#
# This script: diagnoses (ownership, perms, agent log, pinentry, mount type, socketdir), then
# applies a durable fix — stop agents, return ownership of the WHOLE homedir to you (one sudo
# chown; NO key is ever created or run as root), set strict perms, ensure the key subdirs exist,
# set GPG_TTY + curses pinentry, recreate the socket dir, relaunch the agent — and verifies the
# machinery with a THROWAWAY key in a temp homedir (your real keyring is untouched). It never
# generates your real key (that step is interactive, so you set the passphrase yourself) and never
# uses a root-owned key as a workaround.
#
# Usage (as your normal user, e.g. strateloqbackup — NOT sudo):
#   scripts/dr/fix-gpg-agent-wsl.sh [--diagnose-only]
set -uo pipefail

if [ "$(id -u)" = "0" ]; then
  echo "REFUSING to run as root. Running gpg as root is what created the root-owned files causing" >&2
  echo "this failure. Re-run as your normal user (e.g. strateloqbackup), without sudo." >&2
  exit 2
fi

DIAG_ONLY=0; [ "${1:-}" = "--diagnose-only" ] && DIAG_ONLY=1
GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"
ME="$(id -un)"; GRP="$(id -gn)"
echo "== GPG agent fix ==  user=$ME  GNUPGHOME=$GNUPGHOME  gpg=$(gpg --version | head -1 | awk '{print $NF}')"

# ---------- DIAGNOSE ----------
echo "--- mount type (WSL note: ~/.gnupg must be on ext4, NOT /mnt/c or a 9p/drvfs mount) ---"
df -T "$GNUPGHOME" 2>/dev/null | sed 's/^/  /' || echo "  (homedir not present yet)"
case "$GNUPGHOME" in
  /mnt/*) echo "  WARNING: GNUPGHOME is on a Windows mount — gpg-agent sockets/permissions do not work there."
          echo "           Set it to ext4, e.g.:  export GNUPGHOME=\$HOME/.gnupg   (add to ~/.bashrc)";;
esac
echo "--- gpgconf dirs ---"; gpgconf --list-dirs 2>/dev/null | sed 's/^/  /'
echo "--- ~/.gnupg ownership/perms ---"
ls -lan "$GNUPGHOME" 2>/dev/null | sed 's/^/  /' || echo "  (absent)"
[ -d "$GNUPGHOME/private-keys-v1.d" ] && { echo "--- private-keys-v1.d ---"; ls -lan "$GNUPGHOME/private-keys-v1.d" | sed 's/^/  /'; }
FOREIGN="$(find "$GNUPGHOME" ! -user "$ME" 2>/dev/null)"
if [ -n "$FOREIGN" ]; then echo "  !! foreign-owned entries (NOT $ME) — THIS is the cause:"; echo "$FOREIGN" | sed 's/^/     /'; else echo "  ownership: all entries owned by $ME"; fi
echo "--- runtime socket dir ---"; echo "  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"; ls -lan "/run/user/$(id -u)" 2>/dev/null | sed 's/^/  /' || echo "  (/run/user/$(id -u) absent — normal on WSL without systemd)"
if [ -f "$GNUPGHOME/gpg-agent.conf" ]; then echo "--- gpg-agent.conf ---"; sed 's/^/  /' "$GNUPGHOME/gpg-agent.conf"; fi
LOG="$(gpgconf --list-dirs homedir 2>/dev/null)/gpg-agent.log"
[ -f "$GNUPGHOME/agent.log" ] && { echo "--- agent.log tail ---"; tail -6 "$GNUPGHOME/agent.log" | sed 's/^/  /'; }

if [ "$DIAG_ONLY" = 1 ]; then echo "diagnose-only: no changes made."; exit 0; fi

# ---------- FIX ----------
echo "--- stopping any running gpg-agent (as $ME) ---"
gpgconf --kill all 2>/dev/null || true
pkill -u "$ME" gpg-agent 2>/dev/null || true

if [ -n "$FOREIGN" ]; then
  echo "--- repairing ownership of $GNUPGHOME -> $ME:$GRP (one sudo chown; no keys touched) ---"
  if sudo -n true 2>/dev/null || sudo true; then
    sudo chown -R "$ME:$GRP" "$GNUPGHOME"
  else
    echo "  sudo unavailable/declined. Run this one command, then re-run this script:" >&2
    echo "    sudo chown -R $ME:$GRP \"$GNUPGHOME\"" >&2
    exit 3
  fi
fi

echo "--- ensuring key subdirs + strict perms ---"
mkdir -p "$GNUPGHOME/private-keys-v1.d" "$GNUPGHOME/openpgp-revocs.d"
chmod 700 "$GNUPGHOME"
find "$GNUPGHOME" -type d -exec chmod 700 {} + 2>/dev/null || true
find "$GNUPGHOME" -type f -exec chmod 600 {} + 2>/dev/null || true

echo "--- ensuring curses pinentry + GPG_TTY ---"
touch "$GNUPGHOME/gpg-agent.conf"; chmod 600 "$GNUPGHOME/gpg-agent.conf"
grep -q '^pinentry-program' "$GNUPGHOME/gpg-agent.conf" || echo "pinentry-program /usr/bin/pinentry-curses" >> "$GNUPGHOME/gpg-agent.conf"
if ! grep -q 'GPG_TTY' "$HOME/.bashrc" 2>/dev/null; then
  { echo 'export GPG_TTY=$(tty)'; } >> "$HOME/.bashrc"
  echo "  added 'export GPG_TTY=\$(tty)' to ~/.bashrc"
fi
export GPG_TTY; GPG_TTY="$(tty 2>/dev/null || true)"

echo "--- recreating socket dir + relaunching agent ---"
gpgconf --create-socketdir 2>/dev/null || true
gpgconf --kill all 2>/dev/null || true
gpgconf --launch gpg-agent 2>/dev/null || true

# ---------- VERIFY MACHINERY (throwaway key in a temp homedir; real keyring untouched) ----------
echo "--- verifying key-generation machinery with a throwaway key (temp homedir) ---"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
if GNUPGHOME="$T" gpg --batch --pinentry-mode loopback --passphrase 'verify-machinery' \
     --quick-generate-key 'DR verify <verify@local.invalid>' rsa2048 encrypt 1y >/dev/null 2>&1; then
  echo "verify-machinery test $(date -u)" > "$T/h.txt"
  GNUPGHOME="$T" gpg --yes --batch --encrypt --recipient verify@local.invalid "$T/h.txt" 2>/dev/null
  GNUPGHOME="$T" gpg --yes --batch --pinentry-mode loopback --passphrase 'verify-machinery' \
     --decrypt "$T/h.txt.gpg" > "$T/h.dec" 2>/dev/null
  if cmp -s "$T/h.txt" "$T/h.dec"; then
    echo "  RESULT: PASS — key-gen + encrypt + decrypt all work as $ME."
  else echo "  RESULT: FAIL — encrypt/decrypt mismatch (investigate agent.log)."; exit 1; fi
else
  echo "  RESULT: FAIL — key generation still failing. Re-run with --diagnose-only and inspect the agent log."
  exit 1
fi

cat <<EOF

NEXT (interactive — you type the passphrase; it is never printed or stored):
  export GPG_TTY=\$(tty)
  gpg --quick-generate-key "Strateloq Technologies Backup <support@strateloq.com>" rsa4096 encrypt 2y
Then follow dr/runbook/GPG-KEY-AND-DB-BACKUP.md for the key backup + database backup.
EOF
