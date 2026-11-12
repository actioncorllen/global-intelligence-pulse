#requires -Version 5.1
<#
.SYNOPSIS
    Strateloq DR weekly-backup repair launcher (Windows PowerShell 5.1 compatible).

.DESCRIPTION
    Windows entry point that (1) diagnoses the Strateloq-DR-Weekly-Backup scheduled task
    failure, (2) verifies exit-code propagation Windows -> WSL -> bash, and (3) drives the
    WSL-side repair orchestrator (scripts/dr/strateloq-dr-repair.sh) against the ESTABLISHED
    environment:

        WSL distro : Ubuntu            WSL user : strateloqbackup
        Repository : /home/strateloqbackup/strateloq-dr-validate
        Task       : Strateloq-DR-Weekly-Backup        Drive : strateloqdrive:

    Diagnostics-first and READ-ONLY by default. The repair (fresh encrypted backup +
    verified Drive upload + integrity + REAL isolated restore into an ephemeral LOCAL
    Postgres cluster) runs ONLY after explicit approval (-Approve plus an interactive
    confirmation, or -Approve -Force).

    It runs NO git (no fetch/checkout/branch-switch/overwrite), reuses existing credentials,
    keys and the strateloqdrive: connection, never changes the scheduled task/Drive dest,
    never modifies production, never deploys Kalodata.

    RESTORE_OK is printed ONLY when ALL THREE pass: scheduled-task action + exit-code
    propagation, backup integrity, and the actual isolated restore (orchestrator ORCH_RESTORE_OK).

.NOTES
    Version : 3.1.0  (2026-11-12)  Target: Windows PowerShell 5.1 (also runs on 7+).
#>

[CmdletBinding()]
param(
    [string] $Distro        = 'Ubuntu',
    [string] $WslUser       = 'strateloqbackup',
    [string] $RepoPath      = '/home/strateloqbackup/strateloq-dr-validate',
    [string] $Orchestrator  = '/home/strateloqbackup/strateloq-dr-ops/strateloq-dr-repair.sh',
    [string] $TaskName      = 'Strateloq-DR-Weekly-Backup',
    [string] $DurableScript = '',
    [string] $EnvFile       = '',
    [switch] $NoLocalRestore,
    [switch] $Approve,
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:LauncherVersion = '3.5.2'

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

function ConvertTo-TaskResultText {
    param([int] $Code)
    switch ($Code) {
        0          { 'success (0x0)' }
        1          { 'generic failure / the invoked program returned 1 (0x1)' }
        2          { 'file not found (0x2) - the action''s program/script path is wrong' }
        3          { 'path not found (0x3)' }
        267008     { 'task is ready, has not run (0x41301 family)' }
        267009     { 'task is currently running (0x41301)' }
        267011     { 'task has not yet run (0x41303)' }
        267014     { 'last run terminated by user (0x41306)' }
        default    { ('application-specific exit code 0x{0:X} - the invoked backup program returned this' -f $Code) }
    }
}

function Get-DurableScriptFromAction {
    param([string] $Execute, [string] $Arguments)
    if ($DurableScript) { return $DurableScript }
    $hay = ('{0} {1}' -f $Execute, $Arguments)
    $m = [regex]::Match($hay, '(/[^\s"'']+\.sh)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-EnvFileFromAction {
    # Best-effort: the scheduled-backup credentials usually come from an env file the task
    # sources (e.g. `. ~/dr.env`, `source /path/env`, `--env-file X`, or a bare *.env path).
    param([string] $Execute, [string] $Arguments)
    if ($EnvFile) { return $EnvFile }
    $hay = ('{0} {1}' -f $Execute, $Arguments)
    foreach ($rx in @('(?:--env-file|source|\.)\s+(~?/[^\s"'';&|<>()]+)', '(~?/[^\s"'';&|<>()]+\.env[^\s"'';&|<>()]*)')) {
        $m = [regex]::Match($hay, $rx)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

Write-Host ''
Write-Host '############################################################' -ForegroundColor Cyan
Write-Host ('#  Strateloq DR Repair Launcher  v{0}' -f $script:LauncherVersion) -ForegroundColor Cyan
Write-Host '#  Diagnostics-first  |  read-only unless approved' -ForegroundColor Cyan
Write-Host '############################################################' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Targets the established WSL install; runs no git; reuses existing creds/keys/Drive;' -ForegroundColor DarkGray
Write-Host 'never modifies production or the scheduled task; never deploys Kalodata.'            -ForegroundColor DarkGray
if ($PSCommandPath) { Write-Host ('Running file: {0}' -f $PSCommandPath) -ForegroundColor DarkGray }

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

# --- (1) diagnose the scheduled-task failure (read-only) ---
Write-Section 'Scheduled task diagnosis (read-only)'
$taskActionPresent = $false
$resolvedDurable = ''
$resolvedEnvFile = ''
$task = $null
try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { $task = $null }
if ($task) {
    Write-Good ('task "{0}" exists; state={1}' -f $TaskName, $task.State)
    foreach ($act in @($task.Actions)) {
        $exe = ''; $arg = ''
        try { $exe = [string] $act.Execute } catch { $exe = '' }
        try { $arg = [string] $act.Arguments } catch { $arg = '' }
        if ($exe) { $taskActionPresent = $true }
        Write-Info ('  action: {0} {1}' -f $exe, $arg)
        if (-not $resolvedDurable) { $resolvedDurable = Get-DurableScriptFromAction -Execute $exe -Arguments $arg }
        if (-not $resolvedEnvFile) { $resolvedEnvFile = Get-EnvFileFromAction -Execute $exe -Arguments $arg }
    }
    # (req 10) unattended-execution readiness: logon type must not require an interactive session
    try {
        $pr = $task.Principal
        $lt = [string] $pr.LogonType
        Write-Info ('  runs as: {0}  logon-type: {1}  run-level: {2}' -f $pr.UserId, $lt, $pr.RunLevel)
        if ($lt -eq 'Password' -or $lt -eq 'S4U' -or $lt -eq 'ServiceAccount' -or $lt -eq 'Group') {
            Write-Good 'task is set to run UNATTENDED (whether the user is logged on or not).'
        } else {
            Write-Warn2 ('logon-type "{0}" may need an interactive session; for unattended weekly runs choose "Run whether user is logged on or not".' -f $lt)
        }
    } catch { }
    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($info) {
            $rc = [int] $info.LastTaskResult
            Write-Info ('  last run : {0}' -f $info.LastRunTime)
            Write-Info ('  last result: 0x{0:X} - {1}' -f $rc, (ConvertTo-TaskResultText -Code $rc))
            Write-Info ('  next run : {0}   missed runs: {1}' -f $info.NextRunTime, $info.NumberOfMissedRuns)
            if ($rc -ne 0) { Write-Warn2 'Non-zero last result => the weekly backup run failed; see the cause above and the WSL diagnostics below.' }
        }
    } catch { Write-Warn2 'Could not read Get-ScheduledTaskInfo.' }
    try {
        $evs = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational' } -MaxEvents 120 -ErrorAction SilentlyContinue |
               Where-Object { $_.Message -match [regex]::Escape($TaskName) } | Select-Object -First 4
        if ($evs) {
            Write-Info '  recent Task Scheduler events:'
            foreach ($e in $evs) {
                $firstLine = (($e.Message -split "`r?`n") | Select-Object -First 1)
                Write-Info ('    [{0}] id={1} {2}' -f $e.TimeCreated, $e.Id, $firstLine)
            }
        }
    } catch { }
    Write-Info '  (scheduled-task configuration left unchanged)'
} else {
    Write-Warn2 ('scheduled task "{0}" not found via Get-ScheduledTask (not modifying it).' -f $TaskName)
}
if ($resolvedDurable) { Write-Info ('  durable script resolved: {0}' -f $resolvedDurable) }
if (-not $resolvedEnvFile -and $EnvFile) { $resolvedEnvFile = $EnvFile }
if ($resolvedEnvFile) { Write-Info ('  scheduled-backup env file resolved: {0} (its credentials will be loaded, not printed)' -f $resolvedEnvFile) }

# --- (3) exit-code propagation self-test: Windows -> WSL -> bash ---
Write-Section 'Exit-code propagation self-test (Windows -> WSL -> bash)'
$exitProp = $false
$null = Invoke-Wsl 'exit 7'
if ($LASTEXITCODE -eq 7) { $exitProp = $true; Write-Good 'bash "exit 7" propagated as 7 (Task Scheduler will see real failures).' }
else { Write-Bad ('exit code did not propagate (got {0}, expected 7).' -f $LASTEXITCODE) }

# --- orchestrator present? (placed by the bootstrap command) ---
Write-Section 'Orchestrator'
$present = Invoke-Wsl ('test -s "{0}" && echo PRESENT || echo MISSING' -f $Orchestrator)
if ((@($present) -join '') -notmatch 'PRESENT') {
    Write-Bad ('repair orchestrator not found in WSL at {0}' -f $Orchestrator)
    Write-Info 'Run the one-line bootstrap command from scripts/windows/README.md first.'
    Write-Host 'LAUNCHER_RESULT: ORCHESTRATOR_MISSING' -ForegroundColor Red
    exit 4
}
Write-Good ('repair orchestrator present: {0}' -f $Orchestrator)

# --- (2) diagnose (read-only), incl. durable-script verification ---
Write-Section 'Diagnose (read-only)'
$durableArg = ''
if ($resolvedDurable) { $durableArg = (" --durable-script '{0}'" -f $resolvedDurable) }
$envArg = ''
if ($resolvedEnvFile) { $envArg = (" --env-file '{0}'" -f $resolvedEnvFile) }
$diagCmd = ("bash '{0}' --diagnose --repo '{1}'{2}{3}" -f $Orchestrator, $RepoPath, $durableArg, $envArg)
$diagOut = Invoke-Wsl $diagCmd
foreach ($ln in $diagOut) { Write-Host ('  ' + (($ln -replace "`0", ''))) }
$diagVerdict = Get-Verdict -Lines $diagOut
if ($diagVerdict -eq 'DIAGNOSE_BLOCKED') {
    Write-Section 'Verdict'
    Write-Bad 'Diagnostics found blocking issues. No repair attempted. Nothing changed.'
    Write-Host 'LAUNCHER_RESULT: DIAGNOSE_BLOCKED' -ForegroundColor Red
    exit 5
}

# --- (8) approval gate ---
if (-not $Approve) {
    Write-Section 'Repair - NOT performed'
    Write-Info 'Diagnostics complete (read-only). No local configuration was changed.'
    Write-Info 'To repair + fresh encrypted backup + verify upload + isolated LOCAL restore, re-run with:'
    Write-Info '    -Approve            (prompts you to type APPROVE first)'
    Write-Info '    -Approve -Force     (unattended; skips the prompt)'
    Write-Host 'LAUNCHER_RESULT: DIAGNOSE_OK (read-only; repair not approved)' -ForegroundColor Green
    exit 0
}

Write-Section 'Repair - approval required'
Write-Info 'This will apply safe fixes, take a FRESH encrypted backup (read-only pg_dump of'
Write-Info 'production), upload to the existing Drive destination and verify the upload, verify'
Write-Info 'integrity, and perform a REAL restore into an EPHEMERAL LOCAL Postgres cluster.'
Write-Info 'It will NOT modify production, delete backups, change creds/task/Drive, or deploy.'
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

# --- repair (delegated to the validated orchestrator) ---
Write-Section 'Repair + backup + verified upload + integrity + isolated local restore'
$lrArg = ''
if ($NoLocalRestore) { $lrArg = ' --no-local-restore' }
$repairCmd = ("bash '{0}' --repair --approve --repo '{1}'{2}{3}{4}" -f $Orchestrator, $RepoPath, $durableArg, $envArg, $lrArg)
$repairOut = Invoke-Wsl $repairCmd
foreach ($ln in $repairOut) { Write-Host ('  ' + (($ln -replace "`0", ''))) }
$verdict = Get-Verdict -Lines $repairOut

# --- (9) final verdict: RESTORE_OK requires task + exit-prop + orchestrator restore ---
Write-Section 'Result'
switch ($verdict) {
    'ORCH_RESTORE_OK' {
        Write-Good 'Backup made, Drive upload verified, integrity verified, isolated LOCAL restore passed.'
        if ($taskActionPresent -and $exitProp) {
            Write-Host 'RESTORE_OK' -ForegroundColor Green
            Write-Host 'LAUNCHER_RESULT: RESTORE_OK (task action + exit-code propagation + backup integrity + isolated restore all passed)' -ForegroundColor Green
            exit 0
        }
        Write-Bad 'Backup + isolated restore passed, BUT the scheduled-task / exit-code check did not.'
        if (-not $taskActionPresent) { Write-Info '  - scheduled task action was not found/readable' }
        if (-not $exitProp)          { Write-Info '  - exit-code propagation self-test failed' }
        Write-Host 'LAUNCHER_RESULT: RESTORE_BLOCKED_TASK (restore proven; fix the task/exit-code item above)' -ForegroundColor Red
        exit 9
    }
    'ORCH_RESTORE_PARTIAL' {
        Write-Warn2 'Restore ran but acceptance was not fully met (missing public tables, data-affecting pg_restore errors, or required tables under threshold).'
        Write-Warn2 'NOT restore-ready - review the per-table / error details above. Managed-environment (role/extension) errors alone do not cause this.'
        Write-Host 'LAUNCHER_RESULT: RESTORE_PARTIAL' -ForegroundColor Yellow
        exit 25
    }
    'ORCH_BACKUP_OK_RESTORE_PREREQUISITE' {
        Write-Good 'Fresh encrypted backup made, Drive upload verified, integrity verified.'
        Write-Warn2 'NOT restore-ready: install PostgreSQL server tools (initdb/pg_ctl) in WSL for the local restore.'
        Write-Host 'LAUNCHER_RESULT: BACKUP_OK_RESTORE_PREREQUISITE' -ForegroundColor Yellow
        exit 0
    }
    'ORCH_BACKUP_OK_DECRYPT_PREREQUISITE' {
        Write-Good 'Fresh encrypted backup made and Drive upload verified.'
        Write-Warn2 'NOT restore-ready: the private key is not in this keyring (held offline by design), so'
        Write-Warn2 'decryption + isolated restore must run where the private key lives. Re-run there with:'
        Write-Info  '  --verify-artifact <archive.gpg> --gnupghome <private-key GNUPGHOME>'
        Write-Host 'LAUNCHER_RESULT: BACKUP_OK_DECRYPT_PREREQUISITE' -ForegroundColor Yellow
        exit 0
    }
    'DECRYPT_RECIPIENT_MISMATCH' {
        Write-Bad 'Archive is encrypted to a key that DR_GPG_RECIPIENT does not resolve to (recipient mismatch).'
        Write-Host 'LAUNCHER_RESULT: DECRYPT_RECIPIENT_MISMATCH' -ForegroundColor Red
        exit 8
    }
    'DECRYPT_PASSPHRASE_REQUIRED' {
        Write-Bad 'Private key is passphrase-protected; supply the passphrase transiently for one command or use an unlocked gpg-agent (do NOT persist it in an env file).'
        Write-Host 'LAUNCHER_RESULT: DECRYPT_PASSPHRASE_REQUIRED' -ForegroundColor Red
        exit 8
    }
    'DECRYPT_AGENT_ERROR' {
        Write-Bad 'gpg-agent/pinentry could not run in batch/no-tty mode.'
        Write-Host 'LAUNCHER_RESULT: DECRYPT_AGENT_ERROR' -ForegroundColor Red
        exit 8
    }
    'ORCH_BACKUP_OK_RESTORE_SKIPPED' {
        Write-Warn2 'Backup made + verified; local restore skipped (-NoLocalRestore).'
        Write-Host 'LAUNCHER_RESULT: BACKUP_OK_RESTORE_SKIPPED' -ForegroundColor Yellow
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
