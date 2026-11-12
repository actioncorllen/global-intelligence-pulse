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

## Setup (four plain Windows PowerShell commands — no `bash -lc`, via `/mnt/c/Users/DELL/`)

The earlier `bash -lc` mega-line was what failed (`fatal: not a git repository`, `trap: usage`)
— a PowerShell→bash quoting problem. These commands avoid it entirely: each is a **plain
`wsl <cmd> <args>`** call (no `bash -lc`, no login shell, no shell redirect) or a PowerShell
file write, and the two scripts move through `C:\Users\DELL\` = `/mnt/c/Users/DELL/` — the
copy path you confirmed works. Run them in order.

**1 — fetch the branch into your existing WSL repo** (no checkout, no working-tree change):

```powershell
wsl -d Ubuntu -u strateloqbackup git -C /home/strateloqbackup/strateloq-dr-validate fetch https://github.com/actioncorllen/global-intelligence-pulse claude/sleepy-bell-ff4a68
```

**2 — write the corrected launcher to `C:\Users\DELL\`** (capture → file; no bash redirect):

```powershell
wsl -d Ubuntu -u strateloqbackup git -C /home/strateloqbackup/strateloq-dr-validate show FETCH_HEAD:scripts/windows/Invoke-StrateloqDR.ps1 | Out-File -Encoding ascii "$env:USERPROFILE\Invoke-StrateloqDR.ps1"
```

**3 — write the corrected orchestrator to `C:\Users\DELL\` with Unix line endings**:

```powershell
$o = wsl -d Ubuntu -u strateloqbackup git -C /home/strateloqbackup/strateloq-dr-validate show FETCH_HEAD:scripts/dr/strateloq-dr-repair.sh; [IO.File]::WriteAllText("$env:USERPROFILE\strateloq-dr-repair.sh", (($o -join "`n") + "`n"))
```

**4 — run DIAGNOSTICS ONLY** (no backup, no restore); the orchestrator runs from `/mnt/c`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Orchestrator /mnt/c/Users/DELL/strateloq-dr-repair.sh
```

The launcher prints its version and running-file path at the top — confirm **v3.3.0**. The
diagnosis now reports each credential as *present in this shell*, *present in <env file>
(will be loaded for the backup)*, or *genuinely missing* — so `SUPABASE_DB_URL` /
`DR_GPG_RECIPIENT` living in your scheduled-backup env file is **not** reported as missing.

**Only after** reviewing the diagnostics, run the repair (fresh encrypted backup + verified
Drive upload + integrity + real isolated local restore) by adding `-Approve`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Orchestrator /mnt/c/Users/DELL/strateloq-dr-repair.sh -Approve
```

- If your scheduled-backup env file is in a non-standard location the diagnostic doesn't find,
  point at it with `-EnvFile /home/strateloqbackup/<your-dr-env-file>` (its secrets are loaded,
  never printed).
- The isolated restore needs PostgreSQL **server** tools (`initdb`, `pg_ctl`) in WSL. If absent
  the launcher reports `BACKUP_OK_RESTORE_PREREQUISITE`; install with
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
