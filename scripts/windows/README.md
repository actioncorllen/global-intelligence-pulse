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

## Setup (two short Windows PowerShell commands — paste one at a time)

The old single mega-line was fragile: when a paste broke it, PowerShell dropped into `>>`
continuation, `wslpath` returned nothing, `Copy-Item` failed with a null value, and an **old
broken copy** of the launcher was left in place (that is the real source of the "line 67 / 169"
errors — the corrected file never landed). These two commands fix that: each is short, uses only
simple quoting, stops on the first failure, and uses a **static** WSL path (no `wslpath`, no
null `Copy-Item`).

**Step 1 — fetch the corrected scripts into WSL** (run; wait for `FETCH_OK`):

```powershell
wsl -d Ubuntu -u strateloqbackup -- bash -lc 'set -e; cd ~; rm -rf .dr-fetch; git clone -q --no-checkout --depth 1 --filter=blob:none --branch claude/sleepy-bell-ff4a68 https://github.com/actioncorllen/global-intelligence-pulse .dr-fetch; mkdir -p strateloq-dr-ops; git -C .dr-fetch show claude/sleepy-bell-ff4a68:scripts/windows/Invoke-StrateloqDR.ps1 > strateloq-dr-ops/Invoke-StrateloqDR.ps1; git -C .dr-fetch show claude/sleepy-bell-ff4a68:scripts/dr/strateloq-dr-repair.sh > strateloq-dr-ops/strateloq-dr-repair.sh; chmod +x strateloq-dr-ops/strateloq-dr-repair.sh; rm -rf .dr-fetch; echo FETCH_OK'
```

**Step 2 — copy the corrected launcher over the old one and run DIAGNOSTICS ONLY** (no backup,
no restore — only runs if Step 1 succeeded and the file is present):

```powershell
$src='\\wsl.localhost\Ubuntu\home\strateloqbackup\strateloq-dr-ops\Invoke-StrateloqDR.ps1'; if(-not (Test-Path $src)){$src='\\wsl$\Ubuntu\home\strateloqbackup\strateloq-dr-ops\Invoke-StrateloqDR.ps1'}; if((Test-Path $src) -and ((Get-Item $src).Length -gt 0)){Copy-Item $src "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Force; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1"} else {Write-Host 'Launcher missing/empty in WSL - run Step 1 first (expect FETCH_OK).'}
```

The launcher prints its version and running-file path at the top — confirm it says **v3.2.0**;
if you still see the old errors, you are running a stale file (re-run Step 1, then Step 2).

**Only after** you have reviewed the diagnostics, run the repair (fresh encrypted backup +
verified upload + integrity + real isolated local restore) by adding `-Approve`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Approve
```

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
