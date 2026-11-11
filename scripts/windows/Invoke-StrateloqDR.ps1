#requires -Version 5.1
<#
.SYNOPSIS
    Strateloq DR retrieval + verification launcher (Windows PowerShell 5.1 compatible).

.DESCRIPTION
    Resolves the Strateloq / Global-Intelligence-Pulse repository checkout that lives
    inside an Ubuntu WSL distribution, then verifies that every required Disaster-Recovery
    artifact is present, non-empty and readable. It is DIAGNOSTICS-FIRST and READ-ONLY by
    default: a normal run changes nothing on disk and only prints a truthful report.

    The optional retrieval step (copying the verified artifacts to a local Windows staging
    folder for offline safekeeping) is the ONLY action that writes anything, it writes only
    into a fresh local folder, and it runs ONLY after explicit approval (-Approve plus an
    interactive confirmation, or -Approve -Force for automation).

    HARD SAFETY BOUNDARY (enforced by construction - this script contains no code paths for
    any of the following):
      * It NEVER connects to, reads from, or modifies any production or recovery database.
      * It NEVER deletes any file, backup, or artifact.
      * It NEVER reads, writes, prints, or changes any credential, token, key, or secret.
      * It NEVER deploys anything (Kalodata or otherwise) and triggers no remote action.
    It only (a) reads DR artifacts from the WSL checkout and (b), after approval, copies
    them into a local Windows folder.

.PARAMETER RepoRoot
    Explicit path to the repository root (a Windows path such as a UNC WSL path
    '\\wsl.localhost\Ubuntu\home\you\global-intelligence-pulse' or a drive path). If omitted,
    the launcher auto-discovers the checkout inside WSL and resolves it with 'wslpath -w'.

.PARAMETER Distro
    WSL distribution to search (default: auto-detect, preferring a distro whose name starts
    with 'Ubuntu').

.PARAMETER StageTo
    Local Windows folder to copy verified artifacts into when -Approve is supplied.
    Default: "$env:USERPROFILE\Strateloq-DR-Retrieved\<timestamp>". Must be a local Windows
    path (not the repo itself and not a WSL path).

.PARAMETER Approve
    Opt in to the retrieval (staging) step. Without it, the launcher only diagnoses/reports.

.PARAMETER Force
    With -Approve, skip the interactive "type APPROVE" confirmation (for unattended runs).

.EXAMPLE
    .\Invoke-StrateloqDR.ps1
    Diagnostics only. Resolves the WSL repo, verifies all DR artifacts, prints RETRIEVED_OK
    or RETRIEVED_INCOMPLETE. Nothing is written.

.EXAMPLE
    .\Invoke-StrateloqDR.ps1 -Approve
    Diagnoses, and only if everything verifies and you type APPROVE, copies the artifacts to
    a local staging folder.

.NOTES
    Version : 2.0.0  (2026-11-11 rebuild - parser-validated)
    Target  : Windows PowerShell 5.1 (and PowerShell 7+).
#>

[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $Distro,
    [string] $StageTo,
    [switch] $Approve,
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LauncherVersion = '2.0.0'

# ---- required DR artifacts (relative paths, backslash form for Join-Path) ------------------
$script:RequiredArtifacts = @(
    'dr\schema\tables.sql',
    'dr\schema\extensions.sql',
    'dr\schema\functions.sql',
    'dr\schema\functions_user.sql',
    'dr\schema\policies.sql',
    'dr\schema\rls_enable.sql',
    'dr\schema\triggers.sql',
    'dr\schema\indexes.sql',
    'dr\schema\constraints_pk_unique.sql',
    'dr\schema\constraints_fk.sql',
    'dr\schema\constraints_check.sql',
    'dr\schema\migrations_manifest.txt',
    'dr\manifests\storage_manifest.json',
    'dr\manifests\BACKUP-ARTIFACT-INDEX.md',
    'dr\runbook\RECOVERY-RUNBOOK.md',
    'dr\runbook\DR-INVENTORY.md',
    'dr\n8n\N8N-WORKFLOW-INVENTORY.md',
    'scripts\dr\dr_db_logical_backup.sh',
    'scripts\dr\dr_storage_backup.sh',
    'scripts\dr\dr_git_bundle.sh',
    'scripts\dr\dr_n8n_export.sh'
)

# ---- small helpers -------------------------------------------------------------------------

function Write-Section {
    param([string] $Title)
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Title) -ForegroundColor Cyan
}

function Write-Info  { param([string] $Message) Write-Host ('  {0}' -f $Message) }
function Write-Good  { param([string] $Message) Write-Host ('  [OK]   {0}' -f $Message) -ForegroundColor Green }
function Write-Bad   { param([string] $Message) Write-Host ('  [FAIL] {0}' -f $Message) -ForegroundColor Red }
function Write-Warn2 { param([string] $Message) Write-Host ('  [WARN] {0}' -f $Message) -ForegroundColor Yellow }

function Test-IsWindows {
    # 5.1 is always Windows; on 7+ check the automatic variable.
    if (Test-Path -Path 'variable:IsWindows') { return [bool] (Get-Variable -Name 'IsWindows' -ValueOnly) }
    return $true
}

function Get-WslDistros {
    # Returns an array of distro names, or @() if wsl.exe is unavailable.
    $wsl = Get-Command -Name 'wsl.exe' -ErrorAction SilentlyContinue
    if (-not $wsl) { return @() }
    $prev = $env:WSL_UTF8
    try {
        $env:WSL_UTF8 = '1'
        $raw = & wsl.exe --list --quiet 2>$null
    } catch {
        $raw = $null
    } finally {
        if ($null -eq $prev) { Remove-Item -Path 'env:WSL_UTF8' -ErrorAction SilentlyContinue }
        else { $env:WSL_UTF8 = $prev }
    }
    if (-not $raw) { return @() }
    $names = @()
    foreach ($line in @($raw)) {
        $clean = ($line -replace "`0", '').Trim()
        if ($clean.Length -gt 0) { $names += $clean }
    }
    return $names
}

function Select-Distro {
    param([string[]] $Names, [string] $Preferred)
    if ($Preferred) {
        foreach ($n in $Names) { if ($n -eq $Preferred) { return $n } }
        Write-Warn2 ('Requested distro "{0}" not found; falling back to auto-detect.' -f $Preferred)
    }
    foreach ($n in $Names) { if ($n -like 'Ubuntu*') { return $n } }
    if ($Names.Count -gt 0) { return $Names[0] }
    return $null
}

function Resolve-RepoFromWsl {
    param([string] $DistroName)
    # Discover the checkout inside the distro and resolve it to a Windows path with wslpath.
    $finder = 'd="$HOME/global-intelligence-pulse"; ' +
              'if [ ! -d "$d" ]; then d=$(find "$HOME" -maxdepth 5 -type d -name global-intelligence-pulse 2>/dev/null | head -1); fi; ' +
              'if [ -z "$d" ]; then exit 3; fi; ' +
              'wslpath -w "$d"'
    try {
        $winPath = & wsl.exe -d $DistroName -e bash -lc $finder 2>$null
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    if (-not $winPath) { return $null }
    return (($winPath -join '') -replace "`0", '').Trim()
}

# ---- diagnostics report object -------------------------------------------------------------

function Get-ArtifactReport {
    param([string] $Root)
    $rows = @()
    foreach ($rel in $script:RequiredArtifacts) {
        $full = Join-Path -Path $Root -ChildPath $rel
        $exists   = $false
        $size     = 0
        $readable = $false
        $note     = ''
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $exists = $true
            try {
                $item = Get-Item -LiteralPath $full
                $size = [int64] $item.Length
            } catch {
                $note = 'stat failed'
            }
            if ($size -gt 0) {
                try {
                    $stream = [System.IO.File]::OpenRead($full)
                    $stream.Close()
                    $readable = $true
                } catch {
                    $note = 'not readable'
                }
            } else {
                $note = 'empty (0 bytes)'
            }
        } else {
            $note = 'missing'
        }
        $ok = ($exists -and ($size -gt 0) -and $readable)
        $rows += [pscustomobject]@{
            Relative = $rel
            Full     = $full
            Exists   = $exists
            Size     = $size
            Readable = $readable
            Ok       = $ok
            Note     = $note
        }
    }
    return $rows
}

# ---- main ----------------------------------------------------------------------------------

Write-Host ''
Write-Host '############################################################' -ForegroundColor Cyan
Write-Host ('#  Strateloq DR Launcher  v{0}' -f $script:LauncherVersion) -ForegroundColor Cyan
Write-Host '#  Diagnostics-first  |  read-only unless approved' -ForegroundColor Cyan
Write-Host '############################################################' -ForegroundColor Cyan
Write-Host ''
Write-Host 'This launcher will NOT: touch any database, delete any backup, read or'   -ForegroundColor DarkGray
Write-Host 'change any credential/secret, or deploy anything (Kalodata or otherwise).' -ForegroundColor DarkGray

# --- environment guard ---
Write-Section 'Environment'
if (-not (Test-IsWindows)) {
    Write-Bad 'This launcher is for Windows PowerShell. Current host is not Windows.'
    Write-Host 'LAUNCHER_RESULT: ENV_UNSUPPORTED' -ForegroundColor Red
    exit 2
}
Write-Good ('PowerShell {0} on Windows.' -f $PSVersionTable.PSVersion.ToString())

# --- resolve repository root ---
Write-Section 'Resolve repository (Ubuntu WSL checkout)'
$resolvedRoot = $null

if ($RepoRoot) {
    Write-Info ('Using explicit -RepoRoot: {0}' -f $RepoRoot)
    $resolvedRoot = $RepoRoot
} else {
    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Bad 'wsl.exe not available or no WSL distributions are installed.'
        Write-Info 'Re-run with -RepoRoot pointing at the checkout, e.g.'
        Write-Info '  -RepoRoot "\\wsl.localhost\Ubuntu\home\you\global-intelligence-pulse"'
        Write-Host 'LAUNCHER_RESULT: WSL_UNAVAILABLE' -ForegroundColor Red
        exit 3
    }
    Write-Info ('WSL distributions: {0}' -f ($distros -join ', '))
    $chosen = Select-Distro -Names $distros -Preferred $Distro
    if (-not $chosen) {
        Write-Bad 'Could not select a WSL distribution.'
        Write-Host 'LAUNCHER_RESULT: WSL_NO_DISTRO' -ForegroundColor Red
        exit 3
    }
    Write-Info ('Selected distribution: {0}' -f $chosen)
    $resolvedRoot = Resolve-RepoFromWsl -DistroName $chosen
    if (-not $resolvedRoot) {
        Write-Bad ('Repository checkout not found inside distribution "{0}".' -f $chosen)
        Write-Info 'Expected at ~/global-intelligence-pulse. Clone/pull it, or pass -RepoRoot.'
        Write-Host 'LAUNCHER_RESULT: REPO_NOT_FOUND' -ForegroundColor Red
        exit 4
    }
    Write-Good ('Resolved via wslpath: {0}' -f $resolvedRoot)
}

if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    Write-Bad ('Repository root is not a readable directory: {0}' -f $resolvedRoot)
    Write-Host 'LAUNCHER_RESULT: REPO_UNREADABLE' -ForegroundColor Red
    exit 4
}
Write-Good ('Repository root is accessible: {0}' -f $resolvedRoot)

# --- verify required artifacts (read-only) ---
Write-Section 'Verify required DR artifacts (read-only)'
$report = Get-ArtifactReport -Root $resolvedRoot

$okCount   = 0
$failCount = 0
foreach ($row in $report) {
    if ($row.Ok) {
        $okCount++
        Write-Good ('{0,9} bytes  {1}' -f $row.Size, $row.Relative)
    } else {
        $failCount++
        Write-Bad ('{0,-14}  {1}' -f $row.Note, $row.Relative)
    }
}

Write-Section 'Verdict'
$total = $report.Count
Write-Info ('Artifacts verified: {0}/{1} present, non-empty and readable.' -f $okCount, $total)

if ($failCount -gt 0) {
    # Honest reporting: never claim success when required files are missing/empty/unreadable.
    Write-Bad ('{0} required artifact(s) are missing, empty, or unreadable.' -f $failCount)
    Write-Host ''
    Write-Host 'RETRIEVED_INCOMPLETE' -ForegroundColor Red
    Write-Host ('LAUNCHER_RESULT: RETRIEVED_INCOMPLETE ({0}/{1} ok)' -f $okCount, $total) -ForegroundColor Red
    Write-Host 'No retrieval/staging performed (diagnostics failed). Nothing was changed.' -ForegroundColor Red
    exit 5
}

Write-Good 'All required DR artifacts verified.'
Write-Host ''
Write-Host 'RETRIEVED_OK' -ForegroundColor Green
Write-Host ('LAUNCHER_RESULT: RETRIEVED_OK ({0}/{1} ok)' -f $okCount, $total) -ForegroundColor Green

# --- approval-gated retrieval (the only step that writes anything) ---
if (-not $Approve) {
    Write-Host ''
    Write-Section 'Retrieval (staging) - NOT performed'
    Write-Info 'Diagnostics passed. No changes were made (read-only run).'
    Write-Info 'To copy the verified artifacts to a local offline staging folder, re-run with:'
    Write-Info '    -Approve            (prompts you to type APPROVE first)'
    Write-Info '    -Approve -Force     (unattended; skips the prompt)'
    exit 0
}

Write-Host ''
Write-Section 'Retrieval (staging) - approval required'

# default + validate staging destination (must be a local Windows path, not repo/WSL)
if (-not $StageTo) {
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $StageTo = Join-Path -Path $env:USERPROFILE -ChildPath ('Strateloq-DR-Retrieved\' + $stamp)
}
if ($StageTo -like '\\wsl*' -or $StageTo -like '\\wsl.localhost*') {
    Write-Bad 'StageTo must be a LOCAL Windows folder, not a WSL path (refusing to write back into the source).'
    Write-Host 'LAUNCHER_RESULT: STAGE_DEST_INVALID' -ForegroundColor Red
    exit 6
}
$rootFull = (Resolve-Path -LiteralPath $resolvedRoot).Path
if ($StageTo.TrimEnd('\') -ieq $rootFull.TrimEnd('\')) {
    Write-Bad 'StageTo must not be the repository root.'
    Write-Host 'LAUNCHER_RESULT: STAGE_DEST_INVALID' -ForegroundColor Red
    exit 6
}

Write-Info ('Staging destination: {0}' -f $StageTo)
Write-Info ('Files to copy      : {0}' -f $total)
Write-Info 'Action             : COPY only (read from WSL -> write to local folder). No deletes.'

if (-not $Force) {
    Write-Host ''
    Write-Host 'Type APPROVE (all caps) to copy the verified artifacts, anything else to abort:' -ForegroundColor Yellow
    $answer = Read-Host 'Confirm'
    if ($answer -cne 'APPROVE') {
        Write-Warn2 'Approval not given. Aborting without changes.'
        Write-Host 'LAUNCHER_RESULT: STAGE_ABORTED_BY_USER' -ForegroundColor Yellow
        exit 0
    }
}

# perform the copy (create fresh staging dir; never delete)
if (-not (Test-Path -LiteralPath $StageTo)) {
    New-Item -ItemType Directory -Path $StageTo -Force | Out-Null
}

$copied = 0
$copyFail = 0
foreach ($row in $report) {
    $destFile = Join-Path -Path $StageTo -ChildPath $row.Relative
    $destDir  = Split-Path -Path $destFile -Parent
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    try {
        Copy-Item -LiteralPath $row.Full -Destination $destFile -Force
        $srcHash = (Get-FileHash -LiteralPath $row.Full    -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $destFile     -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) {
            $copied++
            Write-Good ('copied + hash-verified  {0}' -f $row.Relative)
        } else {
            $copyFail++
            Write-Bad ('hash mismatch after copy  {0}' -f $row.Relative)
        }
    } catch {
        $copyFail++
        Write-Bad ('copy failed  {0}  ({1})' -f $row.Relative, $_.Exception.Message)
    }
}

Write-Section 'Retrieval result'
if ($copyFail -gt 0) {
    Write-Bad ('{0} file(s) failed to stage.' -f $copyFail)
    Write-Host ('LAUNCHER_RESULT: STAGED_INCOMPLETE ({0}/{1} copied) -> {2}' -f $copied, $total, $StageTo) -ForegroundColor Red
    exit 7
}
Write-Good ('All {0} artifacts staged and hash-verified into: {1}' -f $copied, $StageTo)
Write-Host ('LAUNCHER_RESULT: STAGED_OK ({0}/{1} copied) -> {2}' -f $copied, $total, $StageTo) -ForegroundColor Green
exit 0
