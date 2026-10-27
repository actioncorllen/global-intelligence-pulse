#!/usr/bin/env bash
# Strateloq DR — diagnose & fix INTERACTIVE GPG key generation failing with
#   gpg: agent_genkey failed: Permission denied
# while an automated probe "passes". The probe in fix-gpg-agent-wsl.sh uses
# --pinentry-mode loopback, so it supplies the passphrase itself and NEVER invokes
# pinentry — it only proves the key store is writable. The interactive command drives
# gpg-agent -> pinentry-curses -> your terminal, which is where the real failure is.
#
# This script does NOT reset the homedir, NOT use loopback, NOT create/delete throwaway
# keys, and NOT weaken passphrase protection. It:
#   1. prints the facts that differ between probe and interactive (effective GNUPGHOME,
#      GPG_TTY, the terminal's owner/perms, pinentry-program resolution, agent processes)
#   2. applies the safe, security-preserving pinentry fixes (GPG_TTY + updatestartuptty +
#      a fresh user-owned agent)
#   3. turns on gpg-agent debug logging and runs the REAL interactive key generation
#      (you type the passphrase) — so a success genuinely creates the protected key, and a
#      failure captures the exact agent-log cause
#   4. restores gpg-agent.conf and shreds the debug log
#
# Run as your normal user (e.g. strateloqbackup), in a REAL terminal, NOT sudo:
#   scripts/dr/diagnose-gpg-pinentry.sh
set -uo pipefail
[ "$(id -u)" = 0 ] && { echo "Run as your normal user, not root/sudo." >&2; exit 2; }

GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"; export GNUPGHOME
UID_NAME="$(id -un)"
KEY_UID="Strateloq Technologies Backup <support@strateloq.com>"
EFFHOME="$(gpgconf --list-dirs homedir 2>/dev/null)"
CONF="$GNUPGHOME/gpg-agent.conf"
DBGLOG="$GNUPGHOME/.dr-agent-debug.log"

echo "== interactive-pinentry diagnosis =="
echo "--- effective homedir gpg will use (must be the one you fixed) ---"
echo "  GNUPGHOME=$GNUPGHOME"
echo "  gpgconf homedir=$EFFHOME"
[ "$EFFHOME" != "$GNUPGHOME" ] && echo "  !! MISMATCH: interactive gpg uses $EFFHOME, which may be the OLD/broken homedir."
echo "--- terminal (pinentry-curses must be able to open it) ---"
echo "  tty=$(tty 2>/dev/null)   GPG_TTY=${GPG_TTY:-<unset>}"
T="$(tty 2>/dev/null)"; [ -e "$T" ] && { ls -ld "$T" | sed 's/^/  /'; [ -w "$T" ] && echo "  terminal writable by you: yes" || echo "  !! terminal NOT writable by you"; }
[ -z "${GPG_TTY:-}" ] && echo "  !! GPG_TTY is unset — the #1 cause of interactive pinentry failures."
echo "--- pinentry-program resolution ---"
PP="$(awk '/^pinentry-program/{print $2; exit}' "$CONF" 2>/dev/null)"; PP="${PP:-/usr/bin/pinentry}"
echo "  configured: $PP"; ls -l "$PP" 2>&1 | sed 's/^/  /'; RPP="$(readlink -f "$PP" 2>/dev/null)"; echo "  resolves to: ${RPP:-<broken>}"
[ -x "${RPP:-/nonexistent}" ] && echo "  executable: yes" || echo "  !! pinentry not executable (would give 'No pinentry', not 'Permission denied')"
findmnt -no TARGET,OPTIONS --target "${RPP:-/usr/bin}" 2>/dev/null | grep -q noexec && echo "  !! pinentry is on a noexec mount"
echo "--- gpg-agent processes (flag any not owned by $UID_NAME) ---"
ps -eo user=,pid=,args= 2>/dev/null | grep '[g]pg-agent' | sed 's/^/  /' || echo "  (none running)"

echo "--- TERM / standalone-GETPIN caveat ---"
echo "  TERM=${TERM:-<unset>}"
[ -z "${TERM:-}" ] && { export TERM=xterm-256color; echo "  TERM was unset -> set TERM=xterm-256color (curses needs a valid TERM)"; }
echo "  NOTE: running 'pinentry-curses' + typing GETPIN by hand shares ONE terminal for both the"
echo "        Assuan protocol and the curses dialog, so it times out (ERR 83886142 = PINENTRY/Timeout)."
echo "        That is a TEST ARTIFACT, not proof pinentry is broken in real agent use. We verify via a"
echo "        real agent-driven key-gen below instead."

echo "--- selecting the smallest-durable pinentry (prefer line-mode pinentry-tty on WSL) ---"
PENTRY=""
for cand in /usr/bin/pinentry-tty /usr/bin/pinentry-curses; do [ -x "$cand" ] && { PENTRY="$cand"; break; }; done
if [ "$PENTRY" = "/usr/bin/pinentry-curses" ] && [ ! -x /usr/bin/pinentry-tty ]; then
  echo "  pinentry-tty not installed. It is the robust fix for curses Timeout on WSL (free):"
  echo "      sudo apt-get install -y pinentry-tty"
  echo "  Proceeding with pinentry-curses + a valid TERM for now; if it times out, install pinentry-tty and re-run."
fi
[ -z "$PENTRY" ] && { echo "  no pinentry found; install one: sudo apt-get install -y pinentry-tty" >&2; exit 2; }
echo "  using pinentry-program: $PENTRY"

echo "--- applying safe pinentry fixes (no key/security change) ---"
export GPG_TTY; GPG_TTY="$(tty)"
touch "$CONF"; chmod 600 "$CONF"
# set exactly one pinentry-program line to the selected program
if grep -q '^pinentry-program' "$CONF" 2>/dev/null; then
  sed -i "s#^pinentry-program.*#pinentry-program $PENTRY#" "$CONF"
else
  echo "pinentry-program $PENTRY" >> "$CONF"
fi
grep -q 'export GPG_TTY' "$HOME/.bashrc" 2>/dev/null || echo 'export GPG_TTY=$(tty)' >> "$HOME/.bashrc"
gpgconf --kill all 2>/dev/null || true
gpgconf --launch gpg-agent 2>/dev/null || true
gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true

echo "--- enabling gpg-agent debug logging (temporary; restored at the end) ---"
[ -f "$CONF" ] && cp -a "$CONF" "$CONF.dr-bak"
{ echo "log-file $DBGLOG"; echo "debug ipc,run"; } >> "$CONF"
: > "$DBGLOG"; chmod 600 "$DBGLOG"
gpgconf --kill gpg-agent 2>/dev/null || true
gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true

echo
echo ">>> Now generating your REAL key — enter a STRONG passphrase at the pinentry prompt."
echo ">>> (passphrase is never printed or logged; this creates a protected key if it succeeds)"
gpg --quick-generate-key "$KEY_UID" rsa4096 encrypt 2y
RC=$?

echo "--- restoring gpg-agent.conf + removing debug ---"
if [ -f "$CONF.dr-bak" ]; then mv -f "$CONF.dr-bak" "$CONF"; else sed -i '/^log-file .*\.dr-agent-debug\.log$/d; /^debug ipc,run$/d' "$CONF" 2>/dev/null; fi
gpgconf --kill gpg-agent 2>/dev/null || true

if [ $RC -eq 0 ]; then
  echo "RESULT: PASS — interactive key generation SUCCEEDED (protected key created in $EFFHOME)."
  gpg --list-keys "support@strateloq.com" | sed 's/^/  /'
  shred -u "$DBGLOG" 2>/dev/null || rm -f "$DBGLOG"
  echo "NEXT: dr/runbook/GPG-KEY-AND-DB-BACKUP.md steps 3-6 (key backup + Supabase DB backup)."
  exit 0
fi

echo "RESULT: FAIL — interactive key generation still failed (rc=$RC). Exact agent-log cause:"
grep -iE "pinentry|tty|permission|operation not permitted|can't (open|create|connect|exec)|ioctl|No pinentry|cancel" "$DBGLOG" 2>/dev/null | tail -12 | sed 's/^/  log: /'
cat <<'TREE'

Decision tree (match the agent-log line above):
  * "Timeout" / "curses" / source PINENTRY (e.g. ERR 83886142) -> curses UI cannot run in this WSL
        terminal. Smallest durable fix = switch to line-mode pinentry-tty (secure; no loopback):
        sudo apt-get install -y pinentry-tty
        (this script then selects it automatically on the next run), or run in a native WSL terminal.
  * "No pinentry" / "can't connect to the PIN entry"   -> pinentry-program path/exec problem:
        sudo apt-get install -y pinentry-tty pinentry-curses   (free)
  * "...tty..." / "Inappropriate ioctl" / "cannot open '/dev/tty'" -> terminal binding:
        run in a NATIVE WSL terminal (not the VS Code integrated terminal); then:
        export GPG_TTY=$(tty); gpgconf --kill all; gpg-connect-agent updatestartuptty /bye; retry
  * "Permission denied" on a private-keys-v1.d/*.key path -> the interactive run is using a DIFFERENT
        homedir than the probe fixed. Check the MISMATCH line above and:  export GNUPGHOME=<fixed path>
  * "Operation not permitted" -> immutable attr:  sudo chattr -i -R "$GNUPGHOME"  (then retry)
Then re-run this script. (Do NOT use --pinentry-mode loopback with an empty passphrase.)
TREE
shred -u "$DBGLOG" 2>/dev/null || rm -f "$DBGLOG"
exit 1
