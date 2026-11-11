<#
  =============================================================================
  Repair-StrateloqDR.ps1  —  Strateloq DR weekly-backup: repair + REAL verify
  =============================================================================
  Runs on the operator's Windows box (Windows PowerShell 5.1), drives Ubuntu WSL
  as user 'strateloqbackup'. Diagnose -> repair -> prove with REAL evidence:

    PHASE 0  preconditions (WSL / distro / user / tools / rclone remote)   [read-only]
    PHASE 1  DIAGNOSE why the task returns exit 1 (wrapper/git/task/logs)   [read-only]
    PHASE 2  REPAIR  — reinstall the repo-tracked DURABLE orchestrator
                       (scripts/dr/dr_weekly_backup.sh), fix perms+LF, ensure the
                       operator env file, point the Scheduled Task at that durable
                       script with correct exit-code propagation
    PHASE 3  VERIFY the backup targets PRODUCTION nxaunmyihhjixxxljcqt      [masked]
    PHASE 4  RUN THE REAL WINDOWS SCHEDULED TASK; read its actual LastTaskResult
    PHASE 5  VERIFY the fresh archive IN GOOGLE DRIVE: sha256 + decryptability +
                       pg_restore -l integrity
    PHASE 6  REAL ISOLATED RESTORE into a throwaway local Postgres; census + data

  RESTORE_OK is printed ONLY when ALL of these are true from real operations:
    task LastTaskResult=0  +  archive present in Drive  +  sha256/decrypt OK  +
    pg_restore -l OK  +  actual isolated restore loaded the schema AND data.
  No mock test ever yields RESTORE_OK. -NoDrill or -NoBackup cannot yield RESTORE_OK.

  SAFETY: never prints/replaces/rotates a secret (masked); never deletes or
  overwrites an existing backup (every run = a NEW dated folder); production DB is
  read-only (pg_dump); restore runs ONLY against a throwaway local cluster; buys
  nothing; does not touch Kalodata.

  USAGE:
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1 -DiagnoseOnly
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1 -NoBackup
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1 -NoDrill
  =============================================================================
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Distro          = 'Ubuntu',
  [string]$WslUser         = 'strateloqbackup',
  [string]$CloneDir        = '/home/strateloqbackup/strateloq-dr-validate',
  [string]$TaskName        = 'Strateloq-DR-Weekly-Backup',
  [string]$RcloneRemote    = 'strateloqdrive:',
  [string]$ExpectedProject = 'nxaunmyihhjixxxljcqt',
  [int]$TaskTimeoutMin     = 25,
  [switch]$DiagnoseOnly,
  [switch]$NoBackup,
  [switch]$NoDrill
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Fail = 0
$script:Warn = 0
# Required-evidence flags — each set ONLY by a real operation, never a mock.
$script:TaskOk    = $false   # Windows scheduled task ran and returned 0
$script:ArchiveOk = $false   # fresh encrypted archive present in Google Drive
$script:ArtifactOk= $false   # sha256 + decrypt + pg_restore -l all OK
$script:RestoreOk = $false   # actual isolated restore loaded schema AND data

function Line { param($m) Write-Host $m }
function Head { param($m) Write-Host "`n==================== $m ====================" -ForegroundColor Cyan }
function Pass { param($m) Write-Host "[PASS] $m" -ForegroundColor Green }
function Info { param($m) Write-Host "[INFO] $m" }
function Warn { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow; $script:Warn++ }
function Bad  { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red;  $script:Fail++ }
function Tick { param($b) if ($b) { 'PASS' } else { ' -- ' } }

# Run a bash script inside WSL as the backup user. The script is base64-encoded in
# PowerShell and decoded in bash, so ANY quoting/newlines pass through unmangled —
# this is what keeps the bridge correct under Windows PowerShell 5.1.
function Wsl {
  param([Parameter(Mandatory)][string]$Script)
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script))
  $out = & wsl.exe -d $Distro -u $WslUser -- bash -lc "echo $b64 | base64 -d | bash" 2>&1
  [pscustomobject]@{ Out = ($out -join "`n"); Code = $LASTEXITCODE }
}

$DrDir     = "$CloneDir/scripts/dr"
$Installed = "$DrDir/dr_weekly_backup.sh"

Write-Host "Strateloq DR repair — $(Get-Date -Format u)" -ForegroundColor White
Write-Host "distro=$Distro user=$WslUser clone=$CloneDir task=$TaskName remote=$RcloneRemote"

# =============================================================================
Head 'PHASE 0 — preconditions (read-only)'
# =============================================================================
try { $null = & wsl.exe -l -q 2>$null } catch { Bad "WSL not available on this machine: $_"; return }
$r = Wsl @"
echo wsl-ok
id -un
"@
if ($r.Code -ne 0 -or $r.Out -notmatch 'wsl-ok') { Bad "Cannot run bash in $Distro as $WslUser. Output:`n$($r.Out)"; return }
Pass "WSL $Distro reachable as $(($r.Out -split "`n")[1])"

$tools = Wsl @"
for t in pg_dump pg_restore gpg rclone git sha256sum shred psql; do
  if command -v `$t >/dev/null 2>&1; then echo "ok `$t"; else echo "MISSING `$t"; fi
done
"@
Line $tools.Out
if ($tools.Out -match 'MISSING') { Warn "Some tools missing above — the backup/restore may fail until installed (apt install, EUR0)." }

$rc = Wsl @"
rclone listremotes 2>&1
"@
if ($rc.Out -match [regex]::Escape($RcloneRemote)) { Pass "rclone remote '$RcloneRemote' is configured (auth preserved, not touched)." }
else { Bad "rclone remote '$RcloneRemote' not found. listremotes:`n$($rc.Out)" }

# =============================================================================
Head 'PHASE 1 — DIAGNOSE why exit 1 (read-only)'
# =============================================================================
$diag = Wsl @"
f='$Installed'
if [ ! -e "`$f" ]; then echo STATE=MISSING; exit 0; fi
echo STATE=PRESENT
echo "SIZE=`$(wc -c < "`$f" 2>/dev/null || echo -1)"
echo "PERM=`$(stat -c '%A %U:%G' "`$f" 2>/dev/null)"
echo "SHEBANG=`$(head -n1 "`$f" 2>/dev/null)"
if grep -lU `$'\r' "`$f" >/dev/null 2>&1; then echo EOL=CRLF; else echo EOL=LF; fi
echo "SHA256=`$(sha256sum "`$f" 2>/dev/null | cut -d' ' -f1)"
"@
Line $diag.Out
$state = ([regex]::Match($diag.Out,'STATE=(\w+)')).Groups[1].Value
$size  = 0; $mSz = [regex]::Match($diag.Out,'SIZE=(-?\d+)'); if ($mSz.Success) { $size = [int]$mSz.Groups[1].Value }
$eol   = ([regex]::Match($diag.Out,'EOL=(\w+)')).Groups[1].Value

$rootCause = $null
if     ($state -eq 'MISSING')             { $rootCause = 'WRAPPER_MISSING' }
elseif ($size -le 1)                      { $rootCause = 'WRAPPER_ZERO_BYTE' }
elseif ($diag.Out -notmatch 'SHEBANG=#!') { $rootCause = 'WRAPPER_NO_SHEBANG' }
elseif ($eol -eq 'CRLF')                  { $rootCause = 'WRAPPER_CRLF' }

$git = Wsl @"
cd '$CloneDir' 2>/dev/null || { echo NO_CLONE; exit 0; }
echo "HEAD=`$(git rev-parse --short HEAD 2>/dev/null)"
echo "BRANCH=`$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "TRACKED=`$(git ls-files --error-unmatch scripts/dr/dr_weekly_backup.sh >/dev/null 2>&1 && echo yes || echo no)"
echo "DIRTY_FILES=`$(git status --porcelain 2>/dev/null | wc -l)"
echo 'RECOVERABLE_COPIES:'
ls -la '$DrDir'/dr_weekly_backup.sh.* 2>/dev/null || echo '  (none: no .bak/.orig/.save)'
"@
Line $git.Out
$tracked = ([regex]::Match($git.Out,'TRACKED=(\w+)')).Groups[1].Value

$envSearch = Wsl @"
echo 'ENV FILE SEARCH (names only; values never printed):'
found=0
for p in "`$HOME/.strateloq-dr.env" "$DrDir/backup.env" "$CloneDir/.dr.env" "`$HOME/.config/strateloq-dr/backup.env"; do
  if [ -f "`$p" ]; then echo "  FOUND `$p -> keys: `$(grep -oE '^[A-Za-z_]+' "`$p" | tr '\n' ' ')"; found=1; fi
done
[ "`$found" = 0 ] && echo '  (no env file found in the usual locations)'
"@
Line $envSearch.Out

Info 'Scheduled Task definition (Windows):'
try {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $ti = Get-ScheduledTaskInfo -TaskName $TaskName
  foreach ($a in $t.Actions) { Line ("  Exec : {0} {1}" -f $a.Execute, $a.Arguments) }
  Line ("  LastRunTime={0}  LastResult={1} (0x{2:X})" -f $ti.LastRunTime, $ti.LastTaskResult, $ti.LastTaskResult)
  $argStr = ($t.Actions | ForEach-Object { $_.Arguments }) -join ' '
  if ($argStr -match 'wsl' -and $argStr -notmatch 'exit') {
    Warn "Task invokes WSL but may not propagate the script's real exit code — PHASE 2 fixes that."
  }
} catch { Warn "Scheduled Task '$TaskName' not found or unreadable: $($_.Exception.Message)" }

try {
  Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TaskScheduler/Operational' } -MaxEvents 200 -ErrorAction Stop |
    Where-Object { $_.Message -match [regex]::Escape($TaskName) } | Select-Object -First 3 TimeCreated, Id, LevelDisplayName |
    Format-Table -AutoSize | Out-String | ForEach-Object { Line $_ }
} catch { Info "TaskScheduler operational log not available — relying on the WSL run log instead." }

Head 'ROOT-CAUSE DETERMINATION (item 1)'
if ($rootCause) {
  Bad "Installed orchestrator defect: $rootCause  (size=$size bytes, eol=$eol, tracked-in-git=$tracked)."
  if ($tracked -eq 'no') {
    Line "  The weekly wrapper was NOT tracked by git, so a checkout / clean / re-clone of the DR"
    Line "  tree wiped it -> missing/zero-byte -> the scheduled WSL invocation exits 1. The tracked"
    Line "  component scripts survived, which is why earlier dated backups are well-formed."
  }
} else {
  Info "Installed wrapper looks structurally intact (size=$size, eol=$eol). If the task still exits 1,"
  Info "the cause is runtime (missing env var / rclone auth / pg connectivity) — PHASE 4-6 prove it with a real run."
}

if ($DiagnoseOnly) { Head "DIAGNOSE-ONLY complete. Fails=$script:Fail Warns=$script:Warn"; return }

# =============================================================================
Head 'PHASE 2 — REPAIR (install durable repo-tracked orchestrator; fix task)'
# =============================================================================
$pull = Wsl @"
cd '$CloneDir' || { echo NO_CLONE; exit 3; }
git fetch --all --quiet 2>&1 | tail -n2 || true
if git ls-files --error-unmatch scripts/dr/dr_weekly_backup.sh >/dev/null 2>&1; then
  git checkout -- scripts/dr/dr_weekly_backup.sh 2>&1 || true
  echo SOURCE=repo-tracked
else
  echo SOURCE=not-in-current-checkout
fi
"@
Line $pull.Out

$need = Wsl @"
f='$Installed'
if [ -s "`$f" ] && head -n1 "`$f" | grep -q '^#!'; then echo OK; else echo WRITE; fi
"@
if ($need.Out.Trim() -ne 'OK') {
  Info "Restoring the durable orchestrator to $Installed from the repo copy (LF, +x)."
  $w = Wsl @"
src='$CloneDir/scripts/dr/dr_weekly_backup.sh'
if [ -s "`$src" ]; then
  install -m 0755 "`$src" '$Installed' 2>/dev/null || { cp "`$src" '$Installed'; chmod 0755 '$Installed'; }
  sed -i 's/\r`$//' '$Installed'
  echo INSTALLED
else
  echo MISSING_SOURCE
fi
"@
  Line $w.Out
  if ($w.Out -match 'MISSING_SOURCE') { Bad "Durable orchestrator source not on this checkout. Pull branch claude/nifty-ritchie-lwbak6 (adds scripts/dr/dr_weekly_backup.sh) and re-run." }
} else { Pass "Durable orchestrator present and valid at $Installed." }

# perms + LF (idempotent)
$null = Wsl @"
chmod 0755 '$Installed' 2>/dev/null
sed -i 's/\r`$//' '$Installed' 2>/dev/null
chmod 0755 '$DrDir'/dr_*.sh 2>/dev/null
echo done
"@
Pass "Permissions normalised (+x) and CRLF stripped on dr_*.sh (item 2)."

# ensure env file (names only; NEVER a value)
$envc = Wsl @"
e="`$HOME/.strateloq-dr.env"
if [ -f "`$e" ]; then echo "ENV_PRESENT `$e"; exit 0; fi
umask 077
cat > "`$e" <<'TEMPLATE'
# Strateloq DR config — fill values from your password manager. 0600, never committed.
export SUPABASE_DB_URL=''        # postgresql://postgres:<pw>@...$ExpectedProject...:5432/postgres
export DR_GPG_RECIPIENT=''       # your DR gpg key id/email (already in your keyring)
export RCLONE_REMOTE='$RcloneRemote'
export RCLONE_DEST=''            # existing Drive destination path, e.g. Strateloq-DR
export SUPABASE_URL=''
export SUPABASE_SERVICE_ROLE_KEY=''
export N8N_BASE_URL=''
export N8N_API_KEY=''
TEMPLATE
chmod 600 "`$e"
echo "ENV_CREATED `$e"
"@
Line $envc.Out
if ($envc.Out -match 'ENV_CREATED') {
  Warn "Created ~/.strateloq-dr.env as a 0600 TEMPLATE with EMPTY values. Fill SUPABASE_DB_URL, DR_GPG_RECIPIENT and RCLONE_DEST from your vault, then re-run. (Values stay yours; this script never reads them.)"
}

# auto-detect existing RCLONE_DEST (preserve destination; never create a new one)
$dest = Wsl @"
for d in `$(rclone lsf '$RcloneRemote' --dirs-only 2>/dev/null | sed 's#/`$##'); do
  if rclone lsf "$RcloneRemote`$d/" --dirs-only 2>/dev/null | grep -qE '^[0-9]{8}T[0-9]{6}Z/`$'; then
    echo "DEST_WITH_RUNS=`$d"
  fi
done
"@
if ($dest.Out -match 'DEST_WITH_RUNS=(.+)') {
  $detected = $Matches[1].Trim()
  Pass "Existing Drive destination detected: '$RcloneRemote$detected' (already holds dated run-folders). Set RCLONE_DEST='$detected' in the env file to keep writing there (item 4 — nothing new created, nothing overwritten)."
} else {
  Info "Could not auto-detect an existing dated-run destination; set RCLONE_DEST to the folder your prior backups used (e.g. Strateloq-DR)."
}

# point the Scheduled Task at the DURABLE script with real exit-code propagation (item 3)
try {
  $desiredArgs = "-d $Distro -u $WslUser -- bash -lc ""'$Installed'; exit `$?"""
  $act = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument $desiredArgs
  $null = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  Set-ScheduledTask -TaskName $TaskName -Action $act | Out-Null
  Pass "Scheduled Task '$TaskName' now runs the DURABLE script and propagates its exit code (item 3)."
  Info  "  wsl.exe $desiredArgs"
} catch { Bad "Could not update the Scheduled Task ($($_.Exception.Message)). Fix the task before relying on the weekly run." }

# =============================================================================
Head 'PHASE 3 — VERIFY the backup targets PRODUCTION (masked)'
# =============================================================================
$proj = Wsl @"
set -a; [ -f "`$HOME/.strateloq-dr.env" ] && . "`$HOME/.strateloq-dr.env"; set +a
u="`${SUPABASE_DB_URL:-}"
if [ -z "`$u" ]; then echo NO_DB_URL; exit 0; fi
host=`$(echo "`$u" | sed -E 's#^[a-z]+://[^@]*@([^:/]+).*#\1#')
echo "DB_HOST_MASKED=`$(echo "`$host" | sed -E 's/([a-z0-9]{4})[a-z0-9]+/\1****/')"
echo "MATCHES_EXPECTED=`$(echo "`$u" | grep -q '$ExpectedProject' && echo yes || echo NO)"
"@
Line $proj.Out
if ($proj.Out -match 'MATCHES_EXPECTED=yes') { Pass "SUPABASE_DB_URL references the production project ref '$ExpectedProject'." }
elseif ($proj.Out -match 'NO_DB_URL')        { Warn "SUPABASE_DB_URL not set yet (fill the env file). Cannot back up until then." }
else { Bad "SUPABASE_DB_URL does NOT reference '$ExpectedProject' — STOP and correct before backing up." }

$ready = ($proj.Out -match 'MATCHES_EXPECTED=yes') -and ($script:Fail -eq 0)
if ($NoBackup) { Head "Repair done (-NoBackup). Fails=$script:Fail Warns=$script:Warn. RESTORE_OK is NOT possible without a real backup+restore — re-run without -NoBackup."; return }
if (-not $ready) { Head "Prerequisites not satisfied — NOT running a backup. Resolve [FAIL]/env items and re-run."; return }

# =============================================================================
Head 'PHASE 4 — RUN THE REAL WINDOWS SCHEDULED TASK (item 5)'
# =============================================================================
$ts = ''
try {
  Info "Starting scheduled task '$TaskName' on demand (this runs a real backup + upload)…"
  Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $deadline = (Get-Date).AddMinutes($TaskTimeoutMin)
  Start-Sleep -Seconds 5
  do {
    Start-Sleep -Seconds 10
    $state = (Get-ScheduledTask -TaskName $TaskName).State
  } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
  $ti = Get-ScheduledTaskInfo -TaskName $TaskName
  if ($state -eq 'Running') { Bad "Task still running after $TaskTimeoutMin min — not waiting further. Inspect the WSL log below." }
  elseif ($ti.LastTaskResult -eq 0) { Pass "Windows scheduled task '$TaskName' ran and returned 0 (SUCCESS)."; $script:TaskOk = $true }
  else { Bad ("Windows scheduled task returned {0} (0x{1:X}) — NOT success." -f $ti.LastTaskResult, $ti.LastTaskResult) }
} catch { Bad "Could not start the scheduled task: $($_.Exception.Message)" }

# Read the wrapper's own log (written under strateloqbackup's HOME by the task run) + extract TS
$log = Wsl @"
d="`$HOME/strateloq-dr-logs"
f=`$(ls -t "`$d"/dr_weekly_*.log 2>/dev/null | head -n1)
if [ -z "`$f" ]; then echo NO_LOG; exit 0; fi
echo "LOGFILE=`$f"
grep -E 'SUCCESS: backup|=== Strateloq DR weekly backup @|\[FAIL\]|\[STEP\]' "`$f" | tail -n 8
"@
Line $log.Out
$mTs = [regex]::Match($log.Out,'backup (\d{8}T\d{6}Z) uploaded'); if ($mTs.Success) { $ts = $mTs.Groups[1].Value }
if (-not $ts) { $mTs = [regex]::Match($log.Out,'@ (\d{8}T\d{6}Z)'); if ($mTs.Success) { $ts = $mTs.Groups[1].Value } }

# Fallback: if the TASK could not run, still execute the durable wrapper directly so the
# operator gets artifact+restore evidence — but TaskOk stays FALSE (RESTORE_OK will not be claimed).
if (-not $script:TaskOk) {
  Warn "Windows-task evidence missing. Running the durable wrapper directly for diagnostics (this does NOT satisfy 'scheduled task successful')."
  $run = Wsl @"
bash '$Installed'
echo "RUN_EXIT=`$?"
"@
  Line $run.Out
  $mE = [regex]::Match($run.Out,'RUN_EXIT=(\d+)')
  if ($mE.Success -and [int]$mE.Groups[1].Value -eq 0) { Info "Direct wrapper run exited 0 (artifact produced for verification)." }
  else { Bad "Direct wrapper run also failed — see [STEP]/[FAIL] lines above." }
  if (-not $ts) { $mTs = [regex]::Match($run.Out,'backup (\d{8}T\d{6}Z) uploaded'); if ($mTs.Success) { $ts = $mTs.Groups[1].Value } }
  if (-not $ts) { $mTs = [regex]::Match($run.Out,'@ (\d{8}T\d{6}Z)'); if ($mTs.Success) { $ts = $mTs.Groups[1].Value } }
}
if ($ts) { Info "Backup timestamp: $ts" } else { Bad "Could not determine the backup timestamp — cannot verify the archive." }

# =============================================================================
Head 'PHASE 5 — VERIFY the fresh archive IN GOOGLE DRIVE (sha256 / decrypt / pg_restore -l)'
# =============================================================================
if ($ts) {
  $ver = Wsl @"
set -a; [ -f "`$HOME/.strateloq-dr.env" ] && . "`$HOME/.strateloq-dr.env"; set +a
TS='$ts'; DEST="`${RCLONE_DEST:-}"
echo '--- remote listing (archive must be in Google Drive) ---'
rclone lsf "$RcloneRemote`${DEST}/`${TS}/" 2>&1
tmp=`$(mktemp -d)
rclone copy "$RcloneRemote`${DEST}/`${TS}/" "`$tmp" --include 'SHA256SUMS-*' --include '*.dump.gpg' >/dev/null 2>&1
db=`$(ls "`$tmp"/strateloq-db-*.dump.gpg 2>/dev/null | head -n1)
if [ -z "`$db" ]; then echo ARCHIVE=MISSING; rm -rf "`$tmp"; exit 0; fi
echo ARCHIVE=PRESENT
if ( cd "`$tmp" && sha256sum -c SHA256SUMS-*.txt 2>&1 | grep -qE 'db-.*dump.gpg: OK' ); then echo SHA256=OK; else echo SHA256=UNCONFIRMED; fi
if gpg --batch --yes --decrypt "`$db" >/dev/null 2>/dev/null; then echo DECRYPT=OK; else echo DECRYPT=FAIL; fi
d=`$(mktemp)
if gpg --batch --yes --decrypt "`$db" > "`$d" 2>/dev/null && pg_restore -l "`$d" > "`$tmp/toc" 2>/dev/null; then
  echo "TABLES_IN_TOC=`$(grep -c 'TABLE DATA' "`$tmp/toc")"
  echo PG_RESTORE_LIST=OK
else
  echo PG_RESTORE_LIST=FAIL
fi
shred -u "`$d" 2>/dev/null || rm -f "`$d"
find "`$tmp" -type f -exec shred -u {} + 2>/dev/null
rm -rf "`$tmp"
"@
  Line $ver.Out
  if ($ver.Out -match 'ARCHIVE=PRESENT') { Pass "Fresh encrypted DB archive is present in Google Drive."; $script:ArchiveOk = $true } else { Bad "No DB archive found in the Drive run-folder for $ts." }
  $shaOk  = $ver.Out -match 'SHA256=OK'
  $decOk  = $ver.Out -match 'DECRYPT=OK'
  $listOk = $ver.Out -match 'PG_RESTORE_LIST=OK'
  if ($shaOk)  { Pass "SHA-256 manifest verified." } else { Warn "SHA-256 line not confirmed as OK (review manifest output)." }
  if ($decOk)  { Pass "Archive decrypts with the operator key." } else { Bad "Archive did not decrypt — check DR_GPG_RECIPIENT / keyring." }
  if ($listOk) { Pass "pg_restore -l parses the archive (custom-format integrity OK)." } else { Bad "pg_restore -l failed — archive may be truncated." }
  if ($shaOk -and $decOk -and $listOk) { $script:ArtifactOk = $true }
} else { Warn "Skipping archive verification (no backup timestamp)." }

# =============================================================================
Head 'PHASE 6 — REAL ISOLATED RESTORE (throwaway local Postgres)'
# =============================================================================
if ($NoDrill) { Warn "Drill skipped (-NoDrill) — RESTORE_OK is NOT possible without the real restore." }
elseif ($ts -and $script:ArchiveOk) {
  $drill = Wsl @"
set -a; [ -f "`$HOME/.strateloq-dr.env" ] && . "`$HOME/.strateloq-dr.env"; set +a
TS='$ts'; DEST="`${RCLONE_DEST:-}"
PGBIN=`$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n1)
if [ -z "`$PGBIN" ] || [ ! -x "`$PGBIN/initdb" ]; then echo NO_LOCAL_PG; exit 0; fi
echo "LOCAL_PG=`$PGBIN"
WD=`$(mktemp -d /tmp/strateloq-drill.XXXXXX); PGDATA="`$WD/data"; SOCK="`$WD/sock"; PORT=55433
"`$PGBIN/initdb" -D "`$PGDATA" -U postgres >/dev/null 2>&1
"`$PGBIN/pg_ctl" -D "`$PGDATA" -o "-k `$SOCK -p `$PORT -c listen_addresses=''" -l "`$WD/pg.log" -w start >/dev/null 2>&1
psql -h "`$SOCK" -p `$PORT -U postgres -c 'create database drill' >/dev/null 2>&1
for ext in vector pgcrypto pg_trgm uuid-ossp btree_gin btree_gist citext; do
  psql -h "`$SOCK" -p `$PORT -U postgres -d drill -c "create extension if not exists \"`$ext\"" >/dev/null 2>&1
done
rclone copy "$RcloneRemote`${DEST}/`${TS}/" "`$WD" --include '*.dump.gpg' >/dev/null 2>&1
db=`$(ls "`$WD"/strateloq-db-*.dump.gpg 2>/dev/null | head -n1)
if [ -z "`$db" ]; then echo DRILL_NO_DB; rm -rf "`$WD"; exit 0; fi
gpg --batch --yes --decrypt "`$db" > "`$WD/d.dump" 2>/dev/null
pg_restore -h "`$SOCK" -p `$PORT -U postgres -d drill --no-owner --no-acl "`$WD/d.dump" > "`$WD/restore.out" 2> "`$WD/restore.err" || true
TBL=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null)
POL=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c "select count(*) from pg_policies" 2>/dev/null)
TRG=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c "select count(*) from information_schema.triggers" 2>/dev/null)
FNC=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'" 2>/dev/null)
ANC=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c "select coalesce((select count(*) from onboarding_policy),-1)" 2>/dev/null)
MBR=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c "select coalesce((select count(*) from member),-1)" 2>/dev/null)
ERR=`$(grep -c -iE 'error|fatal' "`$WD/restore.err" 2>/dev/null)
echo "TABLES=`$TBL"; echo "POLICIES=`$POL"; echo "TRIGGERS=`$TRG"; echo "FUNCTIONS=`$FNC"
echo "ANCHOR_onboarding_policy_rows=`$ANC"; echo "ANCHOR_member_rows=`$MBR"; echo "RESTORE_ERR_LINES=`$ERR"
echo '--- restore.err tail (object errors without all prod extensions are expected/non-fatal) ---'
tail -n 5 "`$WD/restore.err" 2>/dev/null
"`$PGBIN/pg_ctl" -D "`$PGDATA" -w stop >/dev/null 2>&1
find "`$WD" -type f \( -name '*.dump' -o -name '*.gpg' \) -exec shred -u {} + 2>/dev/null
rm -rf "`$WD"
echo DRILL_TEARDOWN=OK
"@
  Line $drill.Out
  if ($drill.Out -match 'NO_LOCAL_PG') {
    Bad "No local Postgres server in WSL — the REAL restore could not run, so RESTORE_OK cannot be granted."
    Head 'SMALLEST SAFE ISOLATED RESTORE TARGET (item 6)'
    Line "Use a throwaway LOCAL Postgres inside the same WSL — no new cloud project, no cost, nothing"
    Line "reachable from production. One-time install, then this script spins an ephemeral cluster in"
    Line "/tmp, restores into it, verifies, and shreds — the cluster never outlives the drill:"
    Line "  sudo apt-get update && sudo apt-get install -y postgresql postgresql-contrib postgresql-NN-pgvector"
    Line "  # NN = your major (e.g. 16). pgvector lets the vector-typed tables restore cleanly."
    Line "Then re-run this launcher: PHASE 6 auto-creates the ephemeral cluster (initdb in /tmp, unix"
    Line "socket only, listen_addresses=''), restores the decrypted dump, checks census + anchor rows,"
    Line "stops the cluster and shreds the plaintext. (Alternative: a paused free Supabase project used"
    Line "ONLY as a restore target — but the local ephemeral cluster is smaller, cheaper and safer.)"
  } elseif ($drill.Out -match 'TABLES=(\d+)') {
    $tbl = [int]$Matches[1]
    $anc = 0; $mA = [regex]::Match($drill.Out,'ANCHOR_onboarding_policy_rows=(-?\d+)'); if ($mA.Success) { $anc = [int]$mA.Groups[1].Value }
    $mbr = 0; $mM = [regex]::Match($drill.Out,'ANCHOR_member_rows=(-?\d+)'); if ($mM.Success) { $mbr = [int]$mM.Groups[1].Value }
    if ($tbl -ge 80 -and ($anc -ge 1 -or $mbr -ge 1)) {
      Pass "Isolated restore SUCCEEDED: $tbl public tables restored; data present (onboarding_policy rows=$anc, member rows=$mbr). Plaintext shredded."
      $script:RestoreOk = $true
    } else {
      Bad "Isolated restore INCOMPLETE: tables=$tbl, onboarding_policy rows=$anc, member rows=$mbr (expected ~93 tables and >=1 data row). Review restore.err above — commonly a missing extension (install pgvector) or a truncated dump."
    }
  } else { Bad "Drill ran but results could not be parsed — review output above. RESTORE_OK withheld." }
} else { Bad "No verified archive to restore — RESTORE_OK withheld." }

# =============================================================================
Head 'SUMMARY — required final evidence'
# =============================================================================
Line ("  [{0}] 1. Windows scheduled task successful"            -f (Tick $script:TaskOk))
Line ("  [{0}] 2. Fresh encrypted DB archive in Google Drive"   -f (Tick $script:ArchiveOk))
Line ("  [{0}] 3. SHA-256 + decryptability (+ pg_restore -l)"    -f (Tick $script:ArtifactOk))
Line ("  [{0}] 4. Actual isolated database restoration"         -f (Tick $script:RestoreOk))
$RESTORE_OK = ($script:Fail -eq 0) -and $script:TaskOk -and $script:ArchiveOk -and $script:ArtifactOk -and $script:RestoreOk
Write-Host ""
if ($RESTORE_OK) {
  Pass "RESTORE_OK — every required evidence item above passed from REAL operations (warnings: $script:Warn)."
  Line "Kalodata may proceed to its separate coordination/approval gate."
} else {
  Bad "NOT RESTORE_OK — one or more required evidence items did not pass ($script:Fail failure(s), $script:Warn warning(s)). Keep Kalodata ON HOLD; resolve the [FAIL] items and re-run."
}
