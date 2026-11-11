# Strateloq DR — Weekly-Backup Repair (Windows)

Repairs a failed `Strateloq-DR-Weekly-Backup`, takes a **fresh encrypted backup**, and
**verifies it is restorable** — targeting the established environment:

| | |
|---|---|
| WSL distro | `Ubuntu` |
| WSL user | `strateloqbackup` |
| Repository | `/home/strateloqbackup/strateloq-dr-validate` |
| Scheduled task | `Strateloq-DR-Weekly-Backup` (inspected read-only, never changed) |
| Drive remote | `strateloqdrive:` (destination preserved, never reconfigured) |

Two pieces:

- `scripts/windows/Invoke-StrateloqDR.ps1` — thin **Windows PowerShell 5.1** entry point (parser-validated).
- `scripts/dr/strateloq-dr-repair.sh` — the WSL-side orchestrator that does the real work.
- `dr/runbook/WEEKLY-BACKUP-REPAIR.md` — the repair procedure it follows.

## What it does / does not do

**Diagnostics-first, read-only** until you approve. The repair then: applies only safe,
reversible fixes → runs the **established** operational backup script
`scripts/dr/dr_db_logical_backup.sh` (`pg_dump -Fc` of production, read-only → `gpg`
encrypt → shred plaintext) → uploads to the existing `strateloqdrive:Strateloq-DR/backups`
→ decrypts to a `0600` temp file and proves the archive is a valid restorable dump.

It **never**: runs git checkout / branch switch / overwrites local work; modifies the
production database (reads only); restores over production (fail-closed isolated-DB guard);
deletes a backup; prints a secret; changes the scheduled task, credentials, or Drive
destination; deploys Kalodata; or makes a paid API call.

**RESTORE-READY is only claimed when an isolated `pg_restore` actually succeeds** (verdict
`RESTORE_OK`). Without an isolated DB URL, the launcher reports the backup as *restorable*
and names the remaining prerequisite — it does **not** claim restore-ready.

## One command (run in Windows PowerShell, not inside WSL)

Fetches the corrected scripts into `~/strateloq-dr-ops/` **without** checking out or touching
your working tree (`git clone --no-checkout` into a temp dir + `git show`), then diagnoses,
asks for approval, performs the repair, takes a fresh encrypted backup, and verifies it:

```powershell
wsl -d Ubuntu -u strateloqbackup -e bash -lc 'set -e; t=$(mktemp -d); git clone -q --no-checkout --depth 1 --branch claude/sleepy-bell-ff4a68 https://github.com/actioncorllen/global-intelligence-pulse "$t"; o="$HOME/strateloq-dr-ops"; mkdir -p "$o"; for f in scripts/windows/Invoke-StrateloqDR.ps1 scripts/dr/strateloq-dr-repair.sh dr/runbook/WEEKLY-BACKUP-REPAIR.md; do git -C "$t" show "claude/sleepy-bell-ff4a68:$f" > "$o/$(basename "$f")"; done; chmod +x "$o/strateloq-dr-repair.sh"; rm -rf "$t"'; $p = (wsl -d Ubuntu -u strateloqbackup -e wslpath -w '/home/strateloqbackup/strateloq-dr-ops/Invoke-StrateloqDR.ps1'); Copy-Item ($p | Select-Object -Last 1).Trim() "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Force; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Approve
```

- To **only diagnose** (no changes, no backup), drop the trailing `-Approve`.
- To also run a **full restore drill**, add — against an **empty, isolated** DB, never production:
  `-IsolatedDbUrl "<isolated db url>"` after `-Approve`.

## Usage reference

```powershell
.\Invoke-StrateloqDR.ps1                       # diagnose only (read-only)
.\Invoke-StrateloqDR.ps1 -Approve              # repair + fresh encrypted backup + verify (prompts APPROVE)
.\Invoke-StrateloqDR.ps1 -Approve -Force       # same, unattended
.\Invoke-StrateloqDR.ps1 -Approve -IsolatedDbUrl "postgresql://.../isolated"   # + isolated restore drill
```

| Parameter | Default | Purpose |
|---|---|---|
| `-Distro` | `Ubuntu` | WSL distribution |
| `-WslUser` | `strateloqbackup` | WSL operator user |
| `-RepoPath` | `/home/strateloqbackup/strateloq-dr-validate` | established checkout |
| `-Orchestrator` | `/home/strateloqbackup/strateloq-dr-ops/strateloq-dr-repair.sh` | repair driver |
| `-TaskName` | `Strateloq-DR-Weekly-Backup` | scheduled task to inspect (read-only) |
| `-IsolatedDbUrl` | *(none)* | empty isolated DB URL for a full restore drill |
| `-Approve` / `-Force` | off | opt in to the repair; skip the prompt |

## Verdicts (relayed verbatim from the orchestrator)

| Verdict | Meaning | Restore-ready? |
|---|---|---|
| `DIAGNOSE_OK` / `DIAGNOSE_BLOCKED` | read-only health | — |
| `PREREQUISITE_MISSING` | operator tool/secret needed before a backup | no |
| `BACKUP_VERIFIED_RESTORE_PREREQUISITE` | fresh encrypted backup made + proven restorable | **no** — needs isolated DB |
| `BACKUP_MADE_RESTORE_UNVERIFIED` | backup made; `pg_restore` unavailable to verify | no |
| `RESTORE_REFUSED_PRODUCTION` / `RESTORE_NOT_ACKNOWLEDGED` | fail-closed restore guards | no |
| `RESTORE_OK` | isolated restore actually succeeded | **yes** |

Validation evidence: [`SYNTAX-VALIDATION.txt`](./SYNTAX-VALIDATION.txt).
