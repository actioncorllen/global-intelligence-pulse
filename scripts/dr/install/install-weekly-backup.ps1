<#
  Strateloq DR — register the weekly Sunday backup in Windows Task Scheduler.
  The task fires on Windows and runs the backup INSIDE WSL (where gpg, rclone, pg_dump live).

  RUN THIS ON YOUR WINDOWS MACHINE (PowerShell). It is NOT run from the Claude cloud
  session — that session cannot reach your computer, so scheduling is only "installed"
  once you run this yourself and the verify step at the bottom shows the task.

  Example (use YOUR repo path — the founder's is /home/strateloqbackup/strateloq-dr-validate):
    powershell -ExecutionPolicy Bypass -File install-weekly-backup.ps1 `
        -WslDistro Ubuntu -WslUser strateloqbackup `
        -RepoPath '/home/strateloqbackup/strateloq-dr-validate' `
        -Time 03:00

  Run PowerShell AS ADMINISTRATOR if Register-ScheduledTask reports access denied
  (registering an S4U "run whether or not logged on" task can require elevation).

  Google Drive destination + GPG recipient are read from the repo's
  scripts/dr/dr_weekly_backup.env at run time — this installer does not hardcode them.
  Each run's scrubbed log + STATUS (SUCCESS/FAILED) are written under DR_BACKUP_ROOT/runs/<ts>/;
  Task Scheduler's "Last Run Result" is non-zero when a run fails (exit 1), so failures surface.

  Re-running updates the task in place (idempotent, -Force). Nothing is deleted; no duplicate task.
#>
param(
  [string]$WslDistro = "Ubuntu",
  [Parameter(Mandatory=$true)][string]$WslUser,
  [Parameter(Mandatory=$true)][string]$RepoPath,   # WSL path to the repo checkout
  [string]$Time = "03:00",                          # local time, Sunday
  [string]$TaskName = "Strateloq-DR-Weekly-Backup"
)

$ErrorActionPreference = "Stop"

# The script + env file inside the repo checkout on WSL:
$script = "$RepoPath/scripts/dr/dr_weekly_backup.sh"
$envf   = "$RepoPath/scripts/dr/dr_weekly_backup.env"

# bash -lc loads the login environment so rclone/gpg/pg_dump are on PATH and the gpg agent works.
$bashCmd = "set -e; '$script' --env '$envf'"
$wslArgs = "-d $WslDistro -u $WslUser -- bash -lc `"$bashCmd`""

$action  = New-ScheduledTaskAction -Execute "wsl.exe" -Argument $wslArgs
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Time
# Scheduler-level no-overlap (complements the flock lock inside the script):
$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Hours 6)
# Run whether or not the user is logged on, without storing a password (S4U):
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force `
  -Description "Weekly (Sun $Time) Strateloq disaster-recovery backup: Supabase DB + Storage + all n8n workflows, gpg-encrypted, uploaded to Google Drive via rclone, checksum-verified."

Write-Host ""
Write-Host "Registered '$TaskName'. VERIFY it exists (scheduling is only real once this shows it):"
Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State
(Get-ScheduledTask -TaskName $TaskName).Triggers
Write-Host "Dry run now (optional):  Start-ScheduledTask -TaskName '$TaskName'   then check the run log under DR_BACKUP_ROOT/runs/."
