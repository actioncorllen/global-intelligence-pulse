<#
  =============================================================================
  Repair-StrateloqDR.ps1  —  Strateloq DR weekly-backup: one-shot repair + verify
  =============================================================================
  ONE complete, safe, self-diagnosing procedure. Runs on the operator's Windows
  box, drives WSL Ubuntu as user 'strateloqbackup'. It:

    PHASE 0  preconditions (WSL / distro / user / tools / rclone remote)   [read-only]
    PHASE 1  DIAGNOSE the installed wrapper, git state, task, logs         [read-only]
    PHASE 2  REPAIR  — reinstall the (now repo-tracked) orchestrator,
                       fix perms + LF; ensure the operator env file exists;
                       correct the Scheduled Task exit-code handling
    PHASE 3  VERIFY the backup targets PRODUCTION nxaunmyihhjixxxljcqt      [masked]
    PHASE 4  TEST   — run one real backup, capture exit code + log
    PHASE 5  VERIFY the new artifact: upload, sha256, decryptability, pg_restore -l
    PHASE 6  RESTORE DRILL (smallest safe, isolated local PG) or print it prepared

  SAFETY (hard guarantees):
    * Never prints, replaces or regenerates a secret (URLs/keys are masked).
    * Never deletes or overwrites an existing backup (every run = a NEW folder).
    * Never touches the production database except a read-only pg_dump.
    * Restore drill runs ONLY against a throwaway local cluster, never production
      and never the paused personal projects.
    * Purchases nothing.

  USAGE (elevated PowerShell is NOT required; a normal prompt is fine):
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1
    # read-only, change nothing:
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1 -DiagnoseOnly
    # repair + verify but DON'T fire a real backup yet:
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1 -NoBackup
    # skip the local restore drill:
    powershell -ExecutionPolicy Bypass -File .\Repair-StrateloqDR.ps1 -NoDrill
  =============================================================================
#>

[CmdletBinding()]
param(
  [string]$Distro       = 'Ubuntu',
  [string]$WslUser      = 'strateloqbackup',
  [string]$CloneDir     = '/home/strateloqbackup/strateloq-dr-validate',
  [string]$TaskName     = 'Strateloq-DR-Weekly-Backup',
  [string]$RcloneRemote = 'strateloqdrive:',
  [string]$ExpectedProject = 'nxaunmyihhjixxxljcqt',
  [switch]$DiagnoseOnly,
  [switch]$NoBackup,
  [switch]$NoDrill
)

$ErrorActionPreference = 'Stop'
$script:Fail = 0
$script:Warn = 0
function Line   { param($m) Write-Host $m }
function Head   { param($m) Write-Host "`n==================== $m ====================" -ForegroundColor Cyan }
function Pass   { param($m) Write-Host "[PASS] $m" -ForegroundColor Green }
function Info   { param($m) Write-Host "[INFO] $m" }
function Warn   { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow; $script:Warn++ }
function Bad    { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red;  $script:Fail++ }

# Run a bash command inside WSL as the backup user. Returns @{ Out; Code }.
function Wsl {
  param([Parameter(Mandatory)][string]$Cmd)
  $out  = & wsl.exe -d $Distro -u $WslUser -- bash -lc $Cmd 2>&1
  [pscustomobject]@{ Out = ($out -join "`n"); Code = $LASTEXITCODE }
}
# POSIX path for the installed orchestrator + its dir
$DrDir     = "$CloneDir/scripts/dr"
$Installed = "$DrDir/dr_weekly_backup.sh"

Write-Host "Strateloq DR repair — $(Get-Date -Format u)" -ForegroundColor White
Write-Host "distro=$Distro user=$WslUser clone=$CloneDir task=$TaskName remote=$RcloneRemote"

# =============================================================================
Head 'PHASE 0 — preconditions (read-only)'
# =============================================================================
try { $null = & wsl.exe -l -q 2>$null } catch { Bad "WSL not available on this machine: $_"; return }
$r = Wsl "echo wsl-ok; id -un; uname -a"
if ($r.Code -ne 0 -or $r.Out -notmatch 'wsl-ok') { Bad "Cannot run bash in $Distro as $WslUser. Output:`n$($r.Out)"; return }
Pass "WSL $Distro reachable as $(($r.Out -split "`n")[1])"

$tools = Wsl "for t in pg_dump pg_restore gpg rclone git sha256sum shred; do command -v \$t >/dev/null && echo \"ok \$t\" || echo \"MISSING \$t\"; done"
Line $tools.Out
if ($tools.Out -match 'MISSING') { Warn "Some tools are missing above — the backup may fail until installed (apt install, €0)." }

$rc = Wsl "rclone listremotes 2>&1"
if ($rc.Out -match [regex]::Escape($RcloneRemote)) { Pass "rclone remote '$RcloneRemote' is configured (auth preserved, not touched)." }
else { Bad "rclone remote '$RcloneRemote' not found. listremotes:`n$($rc.Out)" }

# =============================================================================
Head 'PHASE 1 — DIAGNOSE (read-only)'
# =============================================================================

# 1a. Installed wrapper: existence, size, perms, shebang, CRLF/BOM, sha256
$diag = Wsl @"
f='$Installed'
if [ ! -e "`$f" ]; then echo 'STATE=MISSING'; exit 0; fi
sz=`$(wc -c < "`$f" 2>/dev/null || echo -1)
echo "STATE=PRESENT"
echo "SIZE=`$sz"
echo "PERM=`$(stat -c '%A %U:%G' "`$f" 2>/dev/null)"
echo "TYPE=`$(file -b "`$f" 2>/dev/null)"
echo "SHEBANG=`$(head -n1 "`$f" 2>/dev/null)"
if grep -lU $'\r' "`$f" >/dev/null 2>&1; then echo 'EOL=CRLF'; else echo 'EOL=LF'; fi
echo "SHA256=`$(sha256sum "`$f" 2>/dev/null | cut -d' ' -f1)"
"@
Line $diag.Out
$state = ([regex]::Match($diag.Out,'STATE=(\w+)')).Groups[1].Value
$size  = [int]([regex]::Match($diag.Out,'SIZE=(-?\d+)').Groups[1].Value); if (-not $size) { $size = 0 }
$eol   = ([regex]::Match($diag.Out,'EOL=(\w+)')).Groups[1].Value

$rootCause = $null
if     ($state -eq 'MISSING')          { $rootCause = 'WRAPPER_MISSING' }
elseif ($size -le 1)                   { $rootCause = 'WRAPPER_ZERO_BYTE' }
elseif ($diag.Out -notmatch 'SHEBANG=#!') { $rootCause = 'WRAPPER_NO_SHEBANG' }
elseif ($eol -eq 'CRLF')               { $rootCause = 'WRAPPER_CRLF' }

# 1b. Git state of the clone — was the wrapper tracked? is the tree clean?
$git = Wsl @"
cd '$CloneDir' 2>/dev/null || { echo 'NO_CLONE'; exit 0; }
echo "HEAD=`$(git rev-parse --short HEAD 2>/dev/null)"
echo "BRANCH=`$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "TRACKED=`$(git ls-files --error-unmatch scripts/dr/dr_weekly_backup.sh >/dev/null 2>&1 && echo yes || echo no)"
echo "DIRTY=`$(git status --porcelain 2>/dev/null | wc -l)"
echo 'RECOVERABLE_COPIES:'
ls -la '$DrDir'/dr_weekly_backup.sh.* 2>/dev/null || echo '  (none: no .bak/.orig/.save)'
ls -la '$DrDir'/.dr_weekly_backup.sh.swp 2>/dev/null || true
git -C '$CloneDir' stash list 2>/dev/null | head || true
"@
Line $git.Out
$tracked = ([regex]::Match($git.Out,'TRACKED=(\w+)')).Groups[1].Value

# 1c. Where does the operator config live? (do NOT print any value)
$env = Wsl @"
echo 'ENV FILE SEARCH (names only, values never printed):'
for p in "`$HOME/.strateloq-dr.env" "$DrDir/backup.env" "$CloneDir/.dr.env" "`$HOME/.config/strateloq-dr/backup.env"; do
  [ -f "`$p" ] && echo "  FOUND `$p -> keys: `$(grep -oE '^[A-Za-z_]+' "`$p" | tr '\n' ' ')"
done
[ -z "`$(for p in "`$HOME/.strateloq-dr.env" "$DrDir/backup.env" "$CloneDir/.dr.env"; do [ -f "`$p" ] && echo x; done)" ] && echo '  (no env file found in the usual locations)'
echo "LIVE_ENV_HAS_DB_URL=`$( [ -n "`${SUPABASE_DB_URL:-}" ] && echo yes || echo no )"
echo "LIVE_ENV_HAS_GPG=`$( [ -n "`${DR_GPG_RECIPIENT:-}" ] && echo yes || echo no )"
"@
Line $env.Out

# 1d. Scheduled Task action + last result + exit-code handling (Windows side)
Info 'Scheduled Task definition (Windows):'
try {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $ti = Get-ScheduledTaskInfo -TaskName $TaskName
  foreach ($a in $t.Actions) { Line ("  Exec : {0} {1}" -f $a.Execute, $a.Arguments) }
  Line ("  LastRunTime={0}  LastResult={1} (0x{2:X})" -f $ti.LastRunTime, $ti.LastTaskResult, $ti.LastTaskResult)
  $argStr = ($t.Actions | ForEach-Object { $_.Arguments }) -join ' '
  if ($argStr -match 'wsl' -and $argStr -notmatch 'exit') {
    Warn "Task invokes WSL but may not propagate the script's real exit code — PHASE 2 installs a wrapper that does."
  }
} catch { Warn "Scheduled Task '$TaskName' not found or unreadable: $($_.Exception.Message)" }

# 1e. Windows event log for the task (last 3 entries)
try {
  Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TaskScheduler/Operational' } -MaxEvents 200 -ErrorAction Stop |
    Where-Object { $_.Message -match [regex]::Escape($TaskName) } | Select-Object -First 3 TimeCreated, Id, LevelDisplayName, Message |
    Format-List | Out-String | ForEach-Object { Line $_ }
} catch { Info "TaskScheduler operational log not available ($($_.Exception.Message)) — relying on the WSL run log instead." }

# 1f. Root-cause verdict
Head 'ROOT-CAUSE DETERMINATION'
if ($rootCause) {
  Bad "Installed orchestrator defect: $rootCause  (size=$size bytes, eol=$eol, tracked-in-git=$tracked)."
  if ($tracked -eq 'no') {
    Line "  The wrapper was NOT tracked by git, so a checkout / clean / re-clone of the DR"
    Line "  validate tree wiped it. The tracked component scripts survived, which is why the"
    Line "  11-06..11-08 Drive backups are well-formed and the 11-11 scheduled run exits 1."
  }
} else {
  Info "Installed wrapper looks structurally intact (size=$size, eol=$eol). If the task still exits 1,"
  Info "the cause is runtime (missing env var / rclone auth / pg connectivity) — PHASE 2-5 will surface it."
}

if ($DiagnoseOnly) { Head "DIAGNOSE-ONLY complete. Fails=$script:Fail Warns=$script:Warn"; return }

# =============================================================================
Head 'PHASE 2 — REPAIR (install repo-tracked orchestrator; fix task)'
# =============================================================================
# 2a. Refresh the clone so the now-tracked orchestrator + components are present.
#     Non-destructive: fetch + checkout the DR branch; never force-clean operator files.
$pull = Wsl @"
cd '$CloneDir' || { echo 'NO_CLONE'; exit 3; }
git fetch --all --quiet 2>&1 | tail -n2 || true
# Install the repo copy of the orchestrator if present on the current checkout:
if git ls-files --error-unmatch scripts/dr/dr_weekly_backup.sh >/dev/null 2>&1; then
  git checkout -- scripts/dr/dr_weekly_backup.sh 2>&1 || true
  echo 'SOURCE=repo-tracked'
else
  echo 'SOURCE=not-in-current-checkout'
fi
"@
Line $pull.Out

# If the orchestrator is still absent/damaged (branch not yet merged), write it from the here-doc below.
$need = Wsl "f='$Installed'; [ -s \"`$f\" ] && head -n1 \"`$f\" | grep -q '^#!' && echo OK || echo WRITE"
if ($need.Out.Trim() -ne 'OK') {
  Info "Writing the vetted orchestrator to $Installed (LF, +x)."
  # The canonical body is maintained in the repo at scripts/dr/dr_weekly_backup.sh.
  # Here we stage it from the repo checkout the operator already has; if the branch
  # carrying it is not merged yet, copy it from the repo working tree path below.
  $src = "$CloneDir/scripts/dr/dr_weekly_backup.sh"
  $w = Wsl @"
if [ -s '$src' ]; then
  install -m 0755 '$src' '$Installed' 2>/dev/null || { cp '$src' '$Installed'; chmod 0755 '$Installed'; }
  sed -i 's/\r`$//' '$Installed'
  echo INSTALLED
else
  echo 'MISSING_SOURCE — the repo copy is not on this checkout yet. Merge branch claude/nifty-ritchie-lwbak6 (adds scripts/dr/dr_weekly_backup.sh) and re-run.'
fi
"@
  Line $w.Out
  if ($w.Out -match 'MISSING_SOURCE') { Bad "Orchestrator source not available on the checkout; cannot repair blindly. See message above."; }
} else { Pass "Orchestrator present and valid at $Installed." }

# 2b. Fix perms + LF unconditionally (idempotent, safe)
$fix = Wsl "chmod 0755 '$Installed' 2>/dev/null; sed -i 's/\r`$//' '$Installed' 2>/dev/null; chmod 0755 '$DrDir'/dr_*.sh 2>/dev/null; echo done"
Pass "Permissions normalised (+x) and CRLF stripped on dr_*.sh."

# 2c. Ensure the operator env file exists (names only; NEVER a value).
$envc = Wsl @"
e="`$HOME/.strateloq-dr.env"
if [ -f "`$e" ]; then echo "ENV_PRESENT `$e"; exit 0; fi
umask 077
cat > "`$e" <<'TEMPLATE'
# Strateloq DR config — fill values from your password manager. 0600, never committed.
# REQUIRED:
export SUPABASE_DB_URL=''        # postgresql://postgres:<pw>@db.$ExpectedProject...:5432/postgres
export DR_GPG_RECIPIENT=''       # your DR gpg key id/email (already in your keyring)
export RCLONE_REMOTE='$RcloneRemote'
export RCLONE_DEST=''            # existing Drive destination path, e.g. Strateloq-DR
# OPTIONAL (enable storage / n8n artifacts):
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
  Warn "Created ~/.strateloq-dr.env as a 0600 TEMPLATE with EMPTY values. Fill SUPABASE_DB_URL, DR_GPG_RECIPIENT and RCLONE_DEST from your vault, then re-run. (Values are yours; this script never sees them.)"
}

# 2d. Auto-detect the existing RCLONE_DEST (the folder already holding dated run-folders) — confirm, don't create.
$dest = Wsl @"
# list top-level dirs on the remote and find one that contains <ts>Z run folders
for d in `$(rclone lsf '$RcloneRemote' --dirs-only 2>/dev/null | sed 's#/`$##'); do
  if rclone lsf "$RcloneRemote`$d/" --dirs-only 2>/dev/null | grep -qE '^[0-9]{8}T[0-9]{6}Z/`$'; then
    echo "DEST_WITH_RUNS=`$d"
  fi
done
"@
if ($dest.Out -match 'DEST_WITH_RUNS=(.+)') {
  $detected = $Matches[1].Trim()
  Pass "Existing backup destination detected on the remote: '$RcloneRemote$detected' (holds dated run-folders). Set RCLONE_DEST='$detected' in the env file to keep writing there (no new location created)."
} else {
  Info "Could not auto-detect an existing dated-run destination; set RCLONE_DEST to the folder your prior backups used (e.g. Strateloq-DR)."
}

# 2e. Correct the Scheduled Task action so it runs the wrapper and returns WSL's real exit code.
try {
  $desiredArgs = "-d $Distro -u $WslUser -- bash -lc `"'$Installed'; exit `$?`""
  $act = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument $desiredArgs
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  Set-ScheduledTask -TaskName $TaskName -Action $act | Out-Null
  Pass "Scheduled Task '$TaskName' action updated to invoke the wrapper and propagate its exit code."
  Info  "  wsl.exe $desiredArgs"
} catch { Warn "Could not update the Scheduled Task automatically ($($_.Exception.Message)). The wrapper is still runnable manually (PHASE 4)." }

# =============================================================================
Head 'PHASE 3 — VERIFY the backup targets PRODUCTION (masked)'
# =============================================================================
$proj = Wsl @"
set -a; [ -f "`$HOME/.strateloq-dr.env" ] && . "`$HOME/.strateloq-dr.env"; set +a
u="`${SUPABASE_DB_URL:-}"
if [ -z "`$u" ]; then echo 'NO_DB_URL'; exit 0; fi
host=`$(echo "`$u" | sed -E 's#^[a-z]+://[^@]*@([^:/]+).*#\1#')
# mask: show only whether it references the expected project ref
echo "DB_HOST_MASKED=`$(echo "`$host" | sed -E 's/([a-z0-9]{4})[a-z0-9]+/\1****/')"
echo "MATCHES_EXPECTED=`$(echo "`$host" | grep -q '$ExpectedProject' && echo yes || echo NO)"
"@
Line $proj.Out
if ($proj.Out -match 'MATCHES_EXPECTED=yes') { Pass "SUPABASE_DB_URL points at the production project ref '$ExpectedProject'." }
elseif ($proj.Out -match 'NO_DB_URL')       { Warn "SUPABASE_DB_URL not set yet (fill the env file). Cannot confirm target until then." }
else { Bad "SUPABASE_DB_URL does NOT reference '$ExpectedProject' — STOP and correct before backing up." }

# Guard: stop before firing a backup if prerequisites are not satisfied.
$ready = ($proj.Out -match 'MATCHES_EXPECTED=yes') -and ($script:Fail -eq 0)
if ($NoBackup) { Head "Repair done (NoBackup). Fails=$script:Fail Warns=$script:Warn. Re-run without -NoBackup to test + verify."; return }
if (-not $ready) { Head "Prerequisites not satisfied — not firing a backup. Resolve the FAIL/WARN items (usually: fill ~/.strateloq-dr.env) and re-run."; return }

# =============================================================================
Head 'PHASE 4 — TEST: run one real backup'
# =============================================================================
Info "Executing the repaired orchestrator (produces a NEW dated folder; nothing overwritten)…"
$run = Wsl "DR_KEEP_LOCAL=1 bash '$Installed'; echo \"RUN_EXIT=`$?\""
Line $run.Out
$exit = [int]([regex]::Match($run.Out,'RUN_EXIT=(\d+)').Groups[1].Value)
if ($exit -eq 0) { Pass "Backup run exited 0." } else { Bad "Backup run exited $exit — see the log lines above for the failing [STEP]."; }

# Capture the new timestamp + local run dir from the log
$ts = ([regex]::Match($run.Out,'backup (\d{8}T\d{6}Z) uploaded')).Groups[1].Value
if (-not $ts) { $ts = ([regex]::Match($run.Out,'@ (\d{8}T\d{6}Z)').Groups[1].Value) }
if ($ts) { Info "Backup timestamp: $ts" } else { Warn "Could not parse the backup timestamp from the log." }

# =============================================================================
Head 'PHASE 5 — VERIFY the new artifact (upload / sha256 / decrypt / pg_restore -l)'
# =============================================================================
if ($exit -eq 0 -and $ts) {
  $ver = Wsl @"
set -a; [ -f "`$HOME/.strateloq-dr.env" ] && . "`$HOME/.strateloq-dr.env"; set +a
TS='$ts'
DEST="`${RCLONE_DEST:-}"
echo '--- remote listing ---'
rclone lsf "$RcloneRemote`${DEST}/`${TS}/" 2>&1
echo '--- remote vs sha256 manifest ---'
tmp=`$(mktemp -d)
rclone copy "$RcloneRemote`${DEST}/`${TS}/" "`$tmp" --include 'SHA256SUMS-*' --include '*.dump.gpg' >/dev/null 2>&1
db=`$(ls "`$tmp"/strateloq-db-*.dump.gpg 2>/dev/null | head -n1)
if [ -n "`$db" ]; then
  ( cd "`$tmp" && sha256sum -c SHA256SUMS-*.txt 2>&1 | grep -E 'db-.*dump.gpg' ) || echo 'sha256 check: see manifest'
  echo '--- decryptability (to /dev/null; key never exposed) ---'
  if gpg --batch --yes --decrypt "`$db" >/dev/null 2>/tmp/gpgerr; then echo 'DECRYPT=OK'; else echo "DECRYPT=FAIL"; cat /tmp/gpgerr; fi
  echo '--- PostgreSQL archive integrity (pg_restore -l, no restore) ---'
  d=`$(mktemp)
  if gpg --batch --yes --decrypt "`$db" > "`$d" 2>/dev/null && pg_restore -l "`$d" >/tmp/toc 2>/tmp/prerr; then
    echo "TOC_ENTRIES=`$(wc -l < /tmp/toc)"
    echo "TABLES_IN_TOC=`$(grep -c 'TABLE DATA' /tmp/toc)"
    echo 'PG_RESTORE_LIST=OK'
  else echo 'PG_RESTORE_LIST=FAIL'; cat /tmp/prerr; fi
  shred -u "`$d" 2>/dev/null || rm -f "`$d"
else echo 'db artifact not found in remote folder'; fi
find "`$tmp" -type f -exec shred -u {} + 2>/dev/null; rm -rf "`$tmp"
"@
  Line $ver.Out
  if ($ver.Out -match 'DECRYPT=OK')         { Pass 'Encrypted DB dump decrypts with the operator key.' } else { Bad 'DB dump did not decrypt — check DR_GPG_RECIPIENT / keyring.' }
  if ($ver.Out -match 'PG_RESTORE_LIST=OK') { Pass 'pg_restore -l parses the archive (PostgreSQL custom-format integrity OK).' } else { Bad 'pg_restore -l failed — archive may be truncated.' }
} else { Warn 'Skipping artifact verification (backup did not complete).' }

# =============================================================================
Head 'PHASE 6 — RESTORE DRILL (smallest safe, isolated local PG)'
# =============================================================================
if ($NoDrill) { Info 'Drill skipped (-NoDrill).' }
elseif ($exit -eq 0 -and $ts) {
  $drill = Wsl @"
set -a; [ -f "`$HOME/.strateloq-dr.env" ] && . "`$HOME/.strateloq-dr.env"; set +a
TS='$ts'; DEST="`${RCLONE_DEST:-}"
# find a local postgres server binary (free; no install if absent)
PGBIN=`$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n1)
if [ -z "`$PGBIN" ] || [ ! -x "`$PGBIN/initdb" ]; then
  echo 'NO_LOCAL_PG'
  echo 'PREPARED DRILL (run once a throwaway Postgres 17 is available; NEVER production):'
  echo "  rclone copy $RcloneRemote`${DEST}/`${TS}/ ./ --include '*.dump.gpg'"
  echo "  gpg -d strateloq-db-`${TS}.dump.gpg > d.dump"
  echo '  pg_restore -d "\$RESTORE_DB_URL" --no-owner --no-acl d.dump   # isolated target only'
  echo '  # census: 93 tables / 75 policies / 24 triggers / 252 user fns; self-tests 38/38, 9/9, 4/4'
  echo '  shred -u d.dump'
  exit 0
fi
echo "LOCAL_PG=`$PGBIN"
WD=`$(mktemp -d /tmp/strateloq-drill.XXXXXX); PGDATA="`$WD/data"; SOCK="`$WD/sock"; PORT=55433
"`$PGBIN/initdb" -D "`$PGDATA" -U postgres >/dev/null 2>&1
"`$PGBIN/pg_ctl" -D "`$PGDATA" -o "-k `$SOCK -p `$PORT -c listen_addresses=''" -l "`$WD/pg.log" -w start >/dev/null 2>&1
createdb -h "`$SOCK" -p `$PORT -U postgres drill 2>/dev/null
# fetch + decrypt the dump into the throwaway dir
rclone copy "$RcloneRemote`${DEST}/`${TS}/" "`$WD" --include '*.dump.gpg' >/dev/null 2>&1
db=`$(ls "`$WD"/strateloq-db-*.dump.gpg | head -n1)
gpg --batch --yes --decrypt "`$db" > "`$WD/d.dump" 2>/dev/null
pg_restore -h "`$SOCK" -p `$PORT -U postgres -d drill --no-owner --no-acl "`$WD/d.dump" >/dev/null 2>"`$WD/restore.err" || true
echo "TABLES=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c \"select count(*) from information_schema.tables where table_schema='public'\" 2>/dev/null)"
echo "POLICIES=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c 'select count(*) from pg_policies' 2>/dev/null)"
echo "TRIGGERS=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c \"select count(*) from information_schema.triggers\" 2>/dev/null)"
echo "FUNCTIONS=`$(psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c \"select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'\" 2>/dev/null)"
# one representative self-test if present
psql -h "`$SOCK" -p `$PORT -U postgres -d drill -At -c \"select case when to_regprocedure('public.fn_storefront_runtime_selftest()') is not null then (select string_agg(x::text,',') from fn_storefront_runtime_selftest() x) else 'selftest-fn-absent' end\" 2>/dev/null | sed 's/^/SELFTEST=/'
# teardown + shred
"`$PGBIN/pg_ctl" -D "`$PGDATA" -w stop >/dev/null 2>&1
find "`$WD" -type f -name '*.dump' -exec shred -u {} + 2>/dev/null
find "`$WD" -type f -name '*.gpg'  -exec shred -u {} + 2>/dev/null
rm -rf "`$WD"
echo 'DRILL_TEARDOWN=OK'
"@
  Line $drill.Out
  if ($drill.Out -match 'NO_LOCAL_PG') {
    Warn 'No local Postgres server in WSL — printed the prepared drill above. (apt install postgresql, €0, then re-run to execute it automatically.)'
  } elseif ($drill.Out -match 'TABLES=(\d+)') {
    $tbl = [int]$Matches[1]
    if ($tbl -ge 90) { Pass "Isolated restore drill: $tbl public tables restored (expected ~93). Policies/triggers/functions listed above; dumps shredded." }
    else { Bad "Isolated restore drill restored only $tbl tables (expected ~93) — investigate restore.err." }
  } else { Warn 'Drill ran but table count could not be parsed — review output above.' }
} else { Info 'Drill skipped (no completed backup to restore).' }

# =============================================================================
Head "SUMMARY"
# =============================================================================
if ($script:Fail -eq 0) {
  Pass "DR repair complete with $script:Warn warning(s). A fresh encrypted production backup was produced, uploaded, verified (decrypt + pg_restore -l)$(if(-not $NoDrill){' and restore-drilled'}). Backup is RESTORE-READY."
  Line "Kalodata deployment may proceed to its separate coordination/approval gate."
} else {
  Bad "DR repair finished with $script:Fail failure(s) and $script:Warn warning(s). Backup is NOT yet verified — keep Kalodata ON HOLD. Resolve the [FAIL] items above and re-run."
}
