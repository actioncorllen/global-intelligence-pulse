<#
  =============================================================================
  Invoke-StrateloqDR.ps1  —  Windows launcher for the Strateloq DR repair
  =============================================================================
  Orchestrates the whole procedure from your existing Windows + Ubuntu-WSL setup,
  with NO manual git branch management and NO copying of multiple scripts:

    STEP 1  Retrieve the committed repair files into the EXISTING WSL repo,
            non-destructively (git fetch + `git show <ref>:path > file`; no branch
            switch, no checkout of the tree, no `git clean`, nothing deleted).
    STEP 2  Check the installed wrapper + its dependencies (via DiagnoseOnly).
    STEP 3  Run Repair-StrateloqDR.ps1 in -DiagnoseOnly (changes nothing).
    STEP 4  Report EXACTLY what it intends to change — derived from the evidence,
            NOT from an assumption that the wrapper was the sole cause.
    STEP 5  Safety gate: stop on any hard blocker; otherwise confirm.
    STEP 6  Repair only after the gate passes.
    STEP 7  Verify a fresh backup, its encrypted archive, and an isolated restore.

  Preserved and never touched: rclone auth, gpg keys, Google Drive destinations,
  existing backup archives. The Task Scheduler job is changed only if the evidence
  shows its exit-code handling is broken. Production DB is read-only (pg_dump).
  Kalodata is not deployed or modified.

  Run it through the one-line bootstrap (see scripts/dr/README.md), or directly:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-StrateloqDR.ps1
  Flags: -AutoApprove (skip the confirm prompt), -NoBackup, -NoDrill.
  =============================================================================
#>
[CmdletBinding()]
param(
  [string]$Distro          = 'Ubuntu',
  [string]$WslUser         = 'strateloqbackup',
  [string]$CloneDir        = '/home/strateloqbackup/strateloq-dr-validate',
  [string]$Branch          = 'claude/nifty-ritchie-lwbak6',
  [string]$TaskName        = 'Strateloq-DR-Weekly-Backup',
  [string]$RcloneRemote    = 'strateloqdrive:',
  [string]$ExpectedProject = 'nxaunmyihhjixxxljcqt',
  [switch]$AutoApprove,
  [switch]$NoBackup,
  [switch]$NoDrill
)
$ErrorActionPreference = 'Stop'
function Head { param($m) Write-Host "`n==================== $m ====================" -ForegroundColor Cyan }
function Pass { param($m) Write-Host "[PASS] $m" -ForegroundColor Green }
function Info { param($m) Write-Host "[INFO] $m" }
function Warn { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Bad  { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red }
function Wsl  { param([string]$Cmd)
  $o = & wsl.exe -d $Distro -u $WslUser -- bash -lc $Cmd 2>&1
  [pscustomobject]@{ Out = ($o -join "`n"); Code = $LASTEXITCODE }
}
# Resolve the Windows UNC path to a POSIX dir inside the distro, with \\wsl$ fallback.
function Get-WslDirUnc { param($PosixDir)
  $rel = $PosixDir.TrimStart('/').Replace('/','\')
  $a = "\\wsl.localhost\$Distro\$rel"
  if (Test-Path $a) { return $a }
  $b = "\\wsl`$\$Distro\$rel"
  if (Test-Path $b) { return $b }
  return $a
}

Write-Host "Strateloq DR launcher — $(Get-Date -Format u)" -ForegroundColor White
Write-Host "distro=$Distro user=$WslUser clone=$CloneDir branch=$Branch"

# Sanity: WSL reachable as the backup user
$probe = Wsl 'echo ok; id -un'
if ($probe.Code -ne 0 -or $probe.Out -notmatch 'ok') { Bad "Cannot run bash in $Distro as $WslUser.`n$($probe.Out)"; exit 2 }

# =============================================================================
Head 'STEP 1 — retrieve committed repair files (non-destructive)'
# =============================================================================
$files = 'dr_weekly_backup.sh Repair-StrateloqDR.ps1 Invoke-StrateloqDR.ps1 README.md'
$ret = Wsl @"
cd '$CloneDir' || { echo 'NO_CLONE'; exit 3; }
PRE=`$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "CURRENT_BRANCH=`$PRE (not switched)"
if ! git fetch origin '$Branch' -q 2>/tmp/fetcherr; then echo 'FETCH_FAIL'; cat /tmp/fetcherr; exit 4; fi
for f in $files; do
  if git show origin/'$Branch':scripts/dr/`$f > "scripts/dr/.`$f.new" 2>/dev/null && [ -s "scripts/dr/.`$f.new" ]; then
    if cmp -s "scripts/dr/.`$f.new" "scripts/dr/`$f" 2>/dev/null; then rm -f "scripts/dr/.`$f.new"; echo "UNCHANGED `$f";
    else mv "scripts/dr/.`$f.new" "scripts/dr/`$f"; echo "UPDATED   `$f"; fi
  else rm -f "scripts/dr/.`$f.new"; echo "ABSENT_ON_BRANCH `$f"; fi
done
chmod +x scripts/dr/*.sh scripts/dr/*.ps1 2>/dev/null
sed -i 's/\r`$//' scripts/dr/*.sh 2>/dev/null
POST=`$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "BRANCH_AFTER=`$POST"
"@
Write-Host $ret.Out
if ($ret.Code -ne 0 -or $ret.Out -match 'NO_CLONE|FETCH_FAIL') { Bad "Could not retrieve repair files (see above)."; exit 4 }
foreach ($need in @('Repair-StrateloqDR.ps1','dr_weekly_backup.sh')) {
  if ($ret.Out -match "ABSENT_ON_BRANCH $([regex]::Escape($need))") { Bad "$need is not on branch $Branch — cannot proceed."; exit 5 }
}
Pass "Repair files present in $CloneDir/scripts/dr (no branch switch, nothing deleted)."

$DrUncDir  = Get-WslDirUnc "$CloneDir/scripts/dr"
$RepairPs1 = Join-Path $DrUncDir 'Repair-StrateloqDR.ps1'
if (-not (Test-Path $RepairPs1)) { Bad "Repair script not visible at $RepairPs1"; exit 5 }
Info "Repair script: $RepairPs1"

# Common args forwarded to the repair script
$common = @('-Distro',$Distro,'-WslUser',$WslUser,'-CloneDir',$CloneDir,
            '-TaskName',$TaskName,'-RcloneRemote',$RcloneRemote,'-ExpectedProject',$ExpectedProject)

# =============================================================================
Head 'STEP 2+3 — DIAGNOSE (checks wrapper + dependencies; changes nothing)'
# =============================================================================
$diag = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RepairPs1 @common -DiagnoseOnly 2>&1
$diagText = ($diag | Out-String)
Write-Host $diagText
$diagFails = 0
$m = [regex]::Match($diagText,'Fails=(\d+)'); if ($m.Success) { $diagFails = [int]$m.Groups[1].Value }

# =============================================================================
Head 'STEP 4 — intended changes (derived from the evidence above)'
# =============================================================================
$plan = New-Object System.Collections.Generic.List[string]
$wrapperDefect = $diagText -match 'WRAPPER_(MISSING|ZERO_BYTE|NO_SHEBANG|CRLF)'
$taskDefect    = $diagText -match 'propagate the script'
$envAbsent     = $diagText -match 'no env file found'
if ($wrapperDefect) {
  $rc = [regex]::Match($diagText,'WRAPPER_(MISSING|ZERO_BYTE|NO_SHEBANG|CRLF)').Value
  $plan.Add("Reinstall the orchestrator from the repo-tracked copy (evidence: $rc).")
} else {
  $plan.Add("Orchestrator looks intact — NO reinstall presumed; a verification backup run will surface any RUNTIME cause (env / rclone / pg).")
}
$plan.Add("Normalise perms (+x) and strip CRLF on dr_*.sh (idempotent; no-op if already clean).")
if ($taskDefect) { $plan.Add("Correct the Task Scheduler action so it returns WSL's real exit code (schedule/trigger unchanged otherwise).") }
else             { $plan.Add("Leave the Task Scheduler action as-is (exit-code handling looks correct).") }
if ($envAbsent)  { $plan.Add("Create ~/.strateloq-dr.env as a 0600 template with EMPTY values (you fill them from your vault).") }
else             { $plan.Add("Leave the existing operator env file untouched.") }
$i=1; foreach ($p in $plan) { Write-Host ("  {0}. {1}" -f $i++, $p) }
Write-Host ""
Info "WILL NOT TOUCH: rclone auth, gpg keys, Google Drive destinations, existing backup archives, the production database (read-only pg_dump only)."
Info "If no structural defect was found, the true cause is proven by STEP 7 (a real backup + restore), not assumed."

# =============================================================================
Head 'STEP 5 — safety gate'
# =============================================================================
if ($diagFails -gt 0) {
  Bad "Diagnose reported $diagFails hard blocker(s) (e.g. WSL unreachable / rclone remote missing). Not proceeding. Resolve those and re-run."
  exit 6
}
Pass "No hard blockers. Preservation guarantees stated above."
if (-not $AutoApprove) {
  $ans = Read-Host "Proceed with repair + verified backup$(if(-not $NoDrill){' + isolated restore drill'})? [y/N]"
  if ($ans -notmatch '^(y|yes)$') { Info "Declined — nothing changed. Re-run with -AutoApprove to skip this prompt."; exit 0 }
}

# =============================================================================
Head 'STEP 6+7 — REPAIR, then verify backup / archive / isolated restore'
# =============================================================================
$full = @() + $common
if ($NoBackup) { $full += '-NoBackup' }
if ($NoDrill)  { $full += '-NoDrill' }
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RepairPs1 @full 2>&1
$outText = ($out | Out-String)
Write-Host $outText

# =============================================================================
Head 'LAUNCHER VERDICT'
# =============================================================================
$summary = ($outText -split "`n") | Where-Object { $_ -match '^\[(PASS|FAIL)\].*(RESTORE-READY|NOT yet verified|restore-drilled|RESTORE-READY\.)' } | Select-Object -Last 1
if ($outText -match 'Backup is RESTORE-READY' -and $outText -notmatch 'NOT yet verified') {
  Pass "Complete. Fresh encrypted production backup produced, uploaded, verified (decrypt + pg_restore -l)$(if(-not $NoDrill){' and restore-drilled'}). RESTORE-READY."
  Write-Host "Kalodata remains on hold for its separate deployment/approval gate (not touched here)." -ForegroundColor White
  exit 0
} else {
  Bad "Repair did not reach RESTORE-READY. Review the [FAIL] lines above. Keep Kalodata ON HOLD."
  exit 1
}
