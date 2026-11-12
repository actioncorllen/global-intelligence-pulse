# Strateloq DR — Weekly-Backup Repair (Windows)

Diagnoses a failed `Strateloq-DR-Weekly-Backup`, repairs it, takes a **fresh encrypted
backup**, **verifies the Google Drive upload**, verifies **SHA-256 + decryption + archive
integrity**, and performs a **real isolated restore into an ephemeral local PostgreSQL
cluster** — targeting the established environment:

| | |
|---|---|
| WSL distro | `Ubuntu` |
| WSL user | `strateloqbackup` |
| Repository | `/home/strateloqbackup/strateloq-dr-validate` |
| Scheduled task | `Strateloq-DR-Weekly-Backup` (diagnosed read-only, never changed) |
| Drive remote | `strateloqdrive:` (reused, never reconfigured) |

Pieces:

- `scripts/windows/Invoke-StrateloqDR.ps1` — **Windows PowerShell 5.1** entry point (parser-validated).
- `scripts/dr/strateloq-dr-repair.sh` — WSL-side orchestrator (does the real work).
- `dr/runbook/WEEKLY-BACKUP-REPAIR.md` — the repair procedure.

## What it does

1. **Diagnose the task failure** (read-only): task state, last run, decoded `LastTaskResult`,
   missed runs, recent Task Scheduler events, and the task's **action** → the durable script it runs.
2. **Exit-code propagation self-test**: confirms `bash "exit 7"` surfaces as `7` through
   Windows → WSL → bash, so a failing backup actually registers as a failed task.
3. **Verify/repair the durable script** and the operational backup script (non-empty, parses,
   executable; `set -e` hygiene warning).
4. **Fresh encrypted backup** via the established `dr_db_logical_backup.sh`
   (`pg_dump -Fc` of production, read-only → `gpg` → shred), **uploaded and upload-verified**
   against `strateloqdrive:` (object present, size + hash match).
5. **Integrity**: ciphertext SHA-256, `gpg` decrypt, `pg_restore --list` archive check.
6. **Real isolated restore**: spins up an **ephemeral local PostgreSQL** cluster (temp dir,
   unix-socket only, `listen_addresses=''`, trust auth, destroyed after), `pg_restore`s into it,
   and counts restored tables — **no cloud DB to provision**.

It **never**: runs git (no fetch/checkout/branch-switch/overwrite); modifies production (reads
only); restores to anything but a throwaway local cluster (a provided DSN is refused unless
local + non-production); deletes a backup; prints a secret; changes the task/credentials/Drive
destination; deploys Kalodata; or makes a paid API call.

**`RESTORE_OK` is printed only when ALL THREE pass**: the scheduled-task action + exit-code
propagation, backup integrity, and the actual isolated restore. Otherwise the launcher relays
the exact blocker — it cannot fabricate `RESTORE_OK`.

## One command (run in Windows PowerShell, not inside WSL)

Fetches the corrected scripts into `~/strateloq-dr-ops/` **without** checkout/branch-switch or
touching your working tree, then diagnoses → asks approval → repairs → fresh encrypted backup →
verified Drive upload → integrity → **real local isolated restore**:

```powershell
wsl -d Ubuntu -u strateloqbackup -e bash -lc 'set -e; t=$(mktemp -d); git clone -q --no-checkout --depth 1 --branch claude/sleepy-bell-ff4a68 https://github.com/actioncorllen/global-intelligence-pulse "$t"; o="$HOME/strateloq-dr-ops"; mkdir -p "$o"; for f in scripts/windows/Invoke-StrateloqDR.ps1 scripts/dr/strateloq-dr-repair.sh dr/runbook/WEEKLY-BACKUP-REPAIR.md; do git -C "$t" show "claude/sleepy-bell-ff4a68:$f" > "$o/$(basename "$f")"; done; chmod +x "$o/strateloq-dr-repair.sh"; rm -rf "$t"'; $p = (wsl -d Ubuntu -u strateloqbackup -e wslpath -w '/home/strateloqbackup/strateloq-dr-ops/Invoke-StrateloqDR.ps1'); Copy-Item ($p | Select-Object -Last 1).Trim() "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Force; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Approve
```

- Drop the trailing `-Approve` to **only diagnose** (zero changes, no backup).
- The isolated restore needs PostgreSQL **server** tools (`initdb`, `pg_ctl`) in WSL. If they
  are absent the launcher reports `BACKUP_OK_RESTORE_PREREQUISITE`; install with
  `sudo apt-get install -y postgresql` in the WSL distro, then re-run.

## Verdicts (relayed verbatim)

| Verdict | Meaning | Restore-ready? |
|---|---|---|
| `DIAGNOSE_OK` / `DIAGNOSE_BLOCKED` | read-only health | — |
| `PREREQUISITE_MISSING` | operator tool/secret needed before a backup | no |
| `UPLOAD_FAILED` / `UPLOAD_VERIFY_FAILED` | Drive upload or its verification failed | no |
| `BACKUP_OK_RESTORE_PREREQUISITE` | backup made + uploaded + verified; local PG server tools missing | no |
| `RESTORE_BLOCKED_TASK` | backup + isolated restore passed, but task action / exit-code check failed | no |
| `RESTORE_OK` | task + integrity + **actual isolated restore** all passed | **yes** |

Validation evidence (incl. a **real** ephemeral-Postgres restore): [`SYNTAX-VALIDATION.txt`](./SYNTAX-VALIDATION.txt).
