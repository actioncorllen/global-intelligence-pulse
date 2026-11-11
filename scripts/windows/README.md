# Strateloq DR Launcher (Windows)

`Invoke-StrateloqDR.ps1` — a **diagnostics-first, read-only-by-default** launcher that
resolves the Strateloq / Global-Intelligence-Pulse checkout inside **Ubuntu WSL**, verifies
that every required Disaster-Recovery artifact is present/non-empty/readable, and (only after
explicit approval) copies the verified artifacts into a local Windows staging folder.

- **Target shell:** Windows PowerShell **5.1** (also runs on PowerShell 7+).
- **Validated with a real parser:** `System.Management.Automation.Language.Parser`
  (0 parse errors) plus an AST/token scan proving no PowerShell-7-only syntax is used.
  See [`SYNTAX-VALIDATION.txt`](./SYNTAX-VALIDATION.txt).

## What it will NOT do (hard safety boundary, enforced by construction)

The script contains **no code paths** for any of these:

- ❌ connect to / read / modify **any database** (production or recovery)
- ❌ delete **any** file, backup, or artifact
- ❌ read, write, print, or change **any credential / token / key / secret**
- ❌ deploy anything (**Kalodata** or otherwise) or trigger any remote action

It only (a) **reads** DR artifacts from the WSL checkout and (b), after approval, **copies**
them into a fresh **local** folder. It never writes back into the source and refuses a WSL
staging destination.

## Retrieve + run (one Windows PowerShell command)

Run this in **Windows PowerShell** (not inside WSL). It updates the WSL checkout to the fixed
branch, resolves the Windows path with `wslpath -w`, copies the validated launcher to your
home folder, and runs it in **diagnostics-only** mode (nothing is changed):

```powershell
$w = (wsl -e bash -lc 'd="$HOME/global-intelligence-pulse"; [ -d "$d" ] || d=$(find "$HOME" -maxdepth 5 -type d -name global-intelligence-pulse 2>/dev/null | head -1); cd "$d" && git fetch -q origin claude/sleepy-bell-ff4a68 && git checkout -q claude/sleepy-bell-ff4a68 && git pull -q --ff-only origin claude/sleepy-bell-ff4a68 && wslpath -w scripts/windows/Invoke-StrateloqDR.ps1'); Copy-Item ($w | Select-Object -Last 1).Trim() "$env:USERPROFILE\Invoke-StrateloqDR.ps1" -Force; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Invoke-StrateloqDR.ps1"
```

- If your WSL distro is not the default, add `-d <DistroName>` after `wsl` (e.g. `wsl -d Ubuntu-24.04 -e bash ...`).
- The command runs **diagnostics only**. It prints `RETRIEVED_OK` (all artifacts verified) or
  `RETRIEVED_INCOMPLETE` (one or more missing/empty) and changes nothing.

## Usage reference

```powershell
# Diagnostics only (read-only). Auto-detects the Ubuntu WSL distro and repo.
.\Invoke-StrateloqDR.ps1

# Point at an explicit checkout (skips WSL auto-detect):
.\Invoke-StrateloqDR.ps1 -RepoRoot "\\wsl.localhost\Ubuntu\home\you\global-intelligence-pulse"

# Approve the retrieval step (prompts you to type APPROVE, then copies to a local staging folder):
.\Invoke-StrateloqDR.ps1 -Approve

# Unattended retrieval (skips the prompt); choose where to stage:
.\Invoke-StrateloqDR.ps1 -Approve -Force -StageTo "C:\Users\DELL\Strateloq-DR-Retrieved"
```

### Parameters

| Parameter    | Purpose |
|--------------|---------|
| `-RepoRoot`  | Explicit Windows/UNC path to the checkout. If omitted, auto-discovers inside WSL and resolves with `wslpath -w`. |
| `-Distro`    | WSL distribution to use (default: auto-detect, prefers `Ubuntu*`). |
| `-StageTo`   | Local Windows folder for the retrieval copy. Default: `%USERPROFILE%\Strateloq-DR-Retrieved\<timestamp>`. Must be local (a WSL path is refused). |
| `-Approve`   | Opt in to the retrieval (copy) step. Without it, the launcher only diagnoses. |
| `-Force`     | With `-Approve`, skip the interactive confirmation. |

### Result codes

| Output | Meaning | Exit |
|--------|---------|------|
| `RETRIEVED_OK` | All required artifacts present, non-empty, readable | 0 |
| `RETRIEVED_INCOMPLETE` | One or more missing/empty/unreadable (no staging done) | 5 |
| `STAGED_OK` | Artifacts copied + hash-verified into the local folder | 0 |
| `STAGED_INCOMPLETE` | A copy/hash check failed | 7 |
| `STAGE_DEST_INVALID` | Staging destination was the repo or a WSL path | 6 |
| `ENV_UNSUPPORTED` / `WSL_UNAVAILABLE` / `REPO_NOT_FOUND` | Pre-flight failed; nothing changed | 2–4 |

## Required DR artifacts verified

`dr/schema/*` (tables, extensions, functions, functions_user, policies, rls_enable, triggers,
indexes, constraints_pk_unique, constraints_fk, constraints_check, migrations_manifest),
`dr/manifests/{storage_manifest.json,BACKUP-ARTIFACT-INDEX.md}`,
`dr/runbook/{RECOVERY-RUNBOOK.md,DR-INVENTORY.md}`, `dr/n8n/N8N-WORKFLOW-INVENTORY.md`,
`scripts/dr/{dr_db_logical_backup.sh,dr_storage_backup.sh,dr_git_bundle.sh,dr_n8n_export.sh}`.
