#requires -Version 5.1
<#
.SYNOPSIS
    Strateloq DR weekly-backup repair launcher (Windows PowerShell 5.1 compatible).

.DESCRIPTION
    Thin Windows entry point that drives the WSL-side repair orchestrator
    (scripts/dr/strateloq-dr-repair.sh) against the ESTABLISHED environment:

        WSL distro : Ubuntu
        WSL user   : strateloqbackup
        Repository : /home/strateloqbackup/strateloq-dr-validate
        Task       : Strateloq-DR-Weekly-Backup
        Drive      : strateloqdrive:

    It is DIAGNOSTICS-FIRST and READ-ONLY by default. The repair (which takes a fresh
    encrypted backup and verifies restorability) runs ONLY after explicit approval
    (-Approve plus an interactive confirmation, or -Approve -Force).

    This launcher does NOT run git (no fetch here, no checkout, no branch switch, no
    overwrite of local work), does NOT change the scheduled task, credentials, or the Drive
    destination (it only reads their presence), and NEVER claims RESTORE-READY unless the
    orchestrator actually completed an isolated restore (verdict RESTORE_OK).

.PARAMETER Distro        WSL distribution (default: Ubuntu).
.PARAMETER WslUser       WSL operator user (default: strateloqbackup).
.PARAMETER RepoPath      Linux path to the established checkout.
.PARAMETER Orchestrator  Linux path to strateloq-dr-repair.sh (placed by the bootstrap command).
.PARAMETER TaskName      Windows scheduled task to inspect read-only.
.PARAMETER IsolatedDbUrl Empty, isolated DB URL for a full restore drill (never production).
.PARAMETER Approve       Opt in to the repair (mutating) path.
.PARAMETER Force         With -Approve, skip the interactive confirmation.

.NOTES
    Version : 3.0.0  (2026-11-11)  Target: Windows PowerShell 5.1 (also runs on 7+).
#>

[CmdletBinding()]
param(
    [string] $Distro        = 'Ubuntu',
    [string] $WslUser       = 'strateloqbackup',
    [string] $RepoPath      = '/home/strateloqbackup/strateloq-dr-validate',
    [string] $Orchestrator  = '/home/strateloqbackup/strateloq-dr-ops/strateloq-dr-repair.sh',
    [string] $TaskName      = 'Strateloq-DR-Weekly-Backup',
    [string] $IsolatedDbUrl = '',
    [switch] $Approve,
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:LauncherVersion = '3.0.0'

function Write-Section { param([string] $Title) Write-Host ''; Write-Host ('=== {0} ===' -f $Title) -ForegroundColor Cyan }
function Write-Info  { param([string] $Message) Write-Host ('  {0}' -f $Message) }
function Write-Good  { param([string] $Message) Write-Host ('  [OK]   {0}' -f $Message) -ForegroundColor Green }
function Write-Bad   { param([string] $Message) Write-Host ('  [FAIL] {0}' -f $Message) -ForegroundColor Red }
function Write-Warn2 { param([string] $Message) Write-Host ('  [WARN] {0}' -f $Message) -ForegroundColor Yellow }

function Test-IsWindows {
    if (Test-Path -Path 'variable:IsWindows') { return [bool] (Get-Variable -Name 'IsWindows' -ValueOnly) }
    return $true
}

function Invoke-Wsl {
    # Runs a bash command in the target distro as the operator user; returns captured lines.
    param([string] $BashCommand)
    $out = & wsl.exe -d $Distro -u $WslUser -e bash -lc $BashCommand 2>&1
    return @($out)
}

function Get-Verdict {
    param([string[]] $Lines)
    $v = $null
    foreach ($ln in $Lines) {
        $s = ($ln -replace "`0", '').Trim()
        if ($s -like 'VERDICT: *') { $v = $s.Substring(9).Trim() }
    }
    return $v
}

Write-Host ''
Write-Host '############################################################' -ForegroundColor Cyan
Write-Host ('#  Strateloq DR Repair Launcher  v{0}' -f $script:LauncherVersion) -ForegroundColor Cyan
Write-Host '#  Diagnostics-first  |  read-only unless approved' -ForegroundColor Cyan
Write-Host '############################################################' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Targets the established WSL install; does NOT run git, change the scheduled'   -ForegroundColor DarkGray
Write-Host 'task/credentials/Drive destination, modify production, or deploy anything.'    -ForegroundColor DarkGray

# --- environment guard ---
Write-Section 'Environment'
if (-not (Test-IsWindows)) {
    Write-Bad 'This launcher is for Windows PowerShell. Current host is not Windows.'
    Write-Host 'LAUNCHER_RESULT: ENV_UNSUPPORTED' -ForegroundColor Red
    exit 2
}
Write-Good ('PowerShell {0} on Windows.' -f $PSVersionTable.PSVersion.ToString())

$wsl = Get-Command -Name 'wsl.exe' -ErrorAction SilentlyContinue
if (-not $wsl) {
    Write-Bad 'wsl.exe not found. Install/enable WSL (Ubuntu) and retry.'
    Write-Host 'LAUNCHER_RESULT: WSL_UNAVAILABLE' -ForegroundColor Red
    exit 3
}
Write-Good ('WSL target: distro={0}  user={1}' -f $Distro, $WslUser)
Write-Info  ('Repo      : {0}' -f $RepoPath)

# --- read-only inspection of the scheduled task (never modified) ---
Write-Section 'Scheduled task (read-only)'
$task = $null
try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { $task = $null }
if ($task) {
    Write-Good ('task "{0}" exists; state={1}' -f $TaskName, $task.State)
    foreach ($act in @($task.Actions)) {
        $exe = ''
        $arg = ''
        try { $exe = [string] $act.Execute } catch { $exe = '' }
        try { $arg = [string] $act.Arguments } catch { $arg = '' }
        Write-Info ('  runs: {0} {1}' -f $exe, $arg)
    }
    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($info) { Write-Info ('  last run: {0}  last result: 0x{1:X}' -f $info.LastRunTime, [int]$info.LastTaskResult) }
    } catch { }
    Write-Info '  (configuration left unchanged)'
} else {
    Write-Warn2 ('scheduled task "{0}" not found via Get-ScheduledTask (continuing; not modifying it).' -f $TaskName)
}

# --- ensure the orchestrator is present (placed by the bootstrap command) ---
Write-Section 'Orchestrator'
$present = (Invoke-Wsl ('test -s "{0}" && echo PRESENT || echo MISSING' -f $Orchestrator))
if ((@($present) -join '') -notmatch 'PRESENT') {
    Write-Bad ('repair orchestrator not found in WSL at {0}' -f $Orchestrator)
    Write-Info 'Run the one-line bootstrap command from scripts/windows/README.md first.'
    Write-Host 'LAUNCHER_RESULT: ORCHESTRATOR_MISSING' -ForegroundColor Red
    exit 4
}
Write-Good ('repair orchestrator present: {0}' -f $Orchestrator)

# --- DIAGNOSE (read-only) ---
Write-Section 'Diagnose (read-only)'
$diagCmd = ("'{0}' --diagnose --repo '{1}'" -f $Orchestrator, $RepoPath)
$diagOut = Invoke-Wsl $diagCmd
foreach ($ln in $diagOut) { Write-Host ('  ' + (($ln -replace "`0", ''))) }
$diagVerdict = Get-Verdict -Lines $diagOut

if ($diagVerdict -eq 'DIAGNOSE_BLOCKED') {
    Write-Section 'Verdict'
    Write-Bad 'Diagnostics found blocking issues. No repair attempted. Nothing changed.'
    Write-Host 'LAUNCHER_RESULT: DIAGNOSE_BLOCKED' -ForegroundColor Red
    exit 5
}
if ($diagVerdict -ne 'DIAGNOSE_OK') {
    Write-Warn2 ('Unexpected diagnose verdict: {0}' -f $diagVerdict)
}

# --- approval gate ---
if (-not $Approve) {
    Write-Section 'Repair - NOT performed'
    Write-Info 'Diagnostics complete (read-only). No changes were made.'
    Write-Info 'To repair + take a fresh encrypted backup + verify, re-run with:'
    Write-Info '    -Approve            (prompts you to type APPROVE first)'
    Write-Info '    -Approve -Force     (unattended; skips the prompt)'
    Write-Info 'Add -IsolatedDbUrl "<empty isolated DB url>" to also run a full restore drill.'
    Write-Host 'LAUNCHER_RESULT: DIAGNOSE_OK (read-only; repair not approved)' -ForegroundColor Green
    exit 0
}

Write-Section 'Repair - approval required'
Write-Info 'This will: apply safe fixes, take a FRESH encrypted backup (read-only pg_dump of'
Write-Info 'production), upload to the existing Drive destination, and verify restorability.'
Write-Info 'It will NOT modify production, delete backups, change credentials/task/Drive, or deploy.'
if (-not $Force) {
    Write-Host ''
    Write-Host 'Type APPROVE (all caps) to proceed, anything else to abort:' -ForegroundColor Yellow
    $answer = Read-Host 'Confirm'
    if ($answer -cne 'APPROVE') {
        Write-Warn2 'Approval not given. Aborting without changes.'
        Write-Host 'LAUNCHER_RESULT: ABORTED_BY_USER' -ForegroundColor Yellow
        exit 0
    }
}

# --- REPAIR (mutating; delegated to the validated orchestrator) ---
Write-Section 'Repair + fresh encrypted backup + verify'
$repairCmd = ("'{0}' --repair --approve --repo '{1}'" -f $Orchestrator, $RepoPath)
if ($IsolatedDbUrl) {
    $repairCmd = $repairCmd + (" --isolated-db-url '{0}' --i-understand-isolated" -f $IsolatedDbUrl)
}
$repairOut = Invoke-Wsl $repairCmd
foreach ($ln in $repairOut) { Write-Host ('  ' + (($ln -replace "`0", ''))) }
$verdict = Get-Verdict -Lines $repairOut

# --- relay the orchestrator verdict verbatim (never upgrade it) ---
Write-Section 'Result'
switch ($verdict) {
    'RESTORE_OK' {
        Write-Good 'Isolated restore succeeded.'
        Write-Host 'RESTORE-READY: a fresh encrypted backup was taken AND restored into an isolated DB.' -ForegroundColor Green
        Write-Host 'LAUNCHER_RESULT: RESTORE_OK' -ForegroundColor Green
        exit 0
    }
    'BACKUP_VERIFIED_RESTORE_PREREQUISITE' {
        Write-Good 'Fresh encrypted backup taken and proven RESTORABLE (archive integrity + TOC).'
        Write-Warn2 'NOT restore-ready yet: a full isolated restore needs an empty isolated DB URL.'
        Write-Info  'Re-run with -IsolatedDbUrl "<empty isolated DB url>" to complete the restore drill.'
        Write-Host 'LAUNCHER_RESULT: BACKUP_VERIFIED_RESTORE_PREREQUISITE' -ForegroundColor Yellow
        exit 0
    }
    'BACKUP_MADE_RESTORE_UNVERIFIED' {
        Write-Warn2 'Backup made but pg_restore was unavailable to verify restorability.'
        Write-Host 'LAUNCHER_RESULT: BACKUP_MADE_RESTORE_UNVERIFIED' -ForegroundColor Yellow
        exit 0
    }
    'PREREQUISITE_MISSING' {
        Write-Bad 'Cannot take a backup: an operator prerequisite (tool/secret) is missing (see above).'
        Write-Host 'LAUNCHER_RESULT: PREREQUISITE_MISSING' -ForegroundColor Red
        exit 7
    }
    default {
        Write-Bad ('Repair did not complete cleanly. Orchestrator verdict: {0}' -f $verdict)
        Write-Host ('LAUNCHER_RESULT: {0}' -f $verdict) -ForegroundColor Red
        exit 8
    }
}
