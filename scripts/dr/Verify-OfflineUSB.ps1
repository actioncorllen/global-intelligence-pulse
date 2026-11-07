<#
  Strateloq DR - offline USB verification launcher (Windows side).

  Why: WSL does not reliably auto-mount the removable USB at /mnt/d between sessions
  (errors: "mount point does not exist", "Invalid argument", 0x2000). Windows, however,
  always sees the USB as a drive letter. So this launcher reads the USB through Windows,
  stages the already-present backup set + PRIMARY key into a C: temp folder, and runs the
  tested WSL verifier (dr_usb_verify.sh, DR_VERIFY_ONLY) over /mnt/c - which is always
  mounted in WSL. No dependency on mounting /mnt/d.

  The USB is only READ (every existing file preserved). No keys are regenerated, nothing is
  re-downloaded, no new backups are made, and no passphrase is printed or persisted.

  Run it with the one command the assistant provided, or:  powershell -ExecutionPolicy Bypass -File Verify-OfflineUSB.ps1
#>
param(
  [string]$UsbDrive = '',          # optional: force a drive (e.g. 'E:'); empty = auto-detect by content
  [string]$SetTs    = '20261107T113707Z'
)
$ErrorActionPreference = 'Stop'
function Die($m){ Write-Host ("OFFLINE USB VERIFICATION: FAIL - " + $m) -ForegroundColor Red; exit 1 }

$setName = "Strateloq-Verified-Backup-$SetTs"
# A drive IS the Strateloq USB when it carries the verified set (with SHA256SUMS) AND the keys folder.
function Test-StrateloqUsb($root){
  try {
    return (Test-Path -LiteralPath ([IO.Path]::Combine($root, $setName, 'SHA256SUMS'))) -and
           (Test-Path -LiteralPath ([IO.Path]::Combine($root, 'Strateloq-Recovery-Keys')))
  } catch { return $false }
}

Write-Host '== discover the USB by its Strateloq backup structure (drive letter is not assumed) =='
$root = $null
if($UsbDrive){
  $r = ($UsbDrive.TrimEnd('\') + '\')
  if(-not (Test-Path -LiteralPath $r)){ Die ("specified drive $UsbDrive is not present in Windows") }
  if(-not (Test-StrateloqUsb $r)){ Die ("drive $UsbDrive does not contain $setName\SHA256SUMS and Strateloq-Recovery-Keys") }
  $root = $r
} else {
  $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.DriveType -eq 'Removable' -or $_.DriveType -eq 'Fixed') }
  $matches = @($drives | Where-Object { Test-StrateloqUsb $_.RootDirectory.FullName })
  if($matches.Count -eq 0){
    $rem = @($drives | Where-Object { $_.DriveType -eq 'Removable' } | ForEach-Object { $_.Name })
    Write-Host ("  ready removable drives seen: " + $(if($rem.Count){ ($rem -join ', ') } else { '(none)' }))
    Die ("no drive contains $setName - Windows cannot currently see the USB with this backup set. " +
         "Prerequisite: plug the USB in and wait for Windows to assign it a drive letter (it should appear in File Explorer); " +
         "then re-run. If your set is a different date, pass -SetTs <ts>. The USB is never formatted, initialised or modified.")
  }
  if($matches.Count -gt 1){
    $cands = ($matches | ForEach-Object { $_.Name }) -join ', '
    Die ("multiple drives contain $setName ($cands) - re-run with -UsbDrive <letter:> to choose. Not guessing.")
  }
  $root = $matches[0].RootDirectory.FullName
}
$root = $root.TrimEnd('\') + '\'
$set  = [IO.Path]::Combine($root, $setName)
$keys = [IO.Path]::Combine($root, 'Strateloq-Recovery-Keys')
Write-Host ("  selected USB: $root  (contains $setName + Strateloq-Recovery-Keys)")

$stage = Join-Path $env:TEMP ('strateloq-usb-verify-' + $SetTs)
if(Test-Path -LiteralPath $stage){ Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Write-Host ('== stage set to ' + $stage + ' (read-only copy FROM the USB; USB untouched) ==')
Copy-Item -LiteralPath $set  -Destination $stage -Recurse -Force
Copy-Item -LiteralPath $keys -Destination $stage -Recurse -Force

$w = (@(wsl.exe wslpath "$stage")[0]).Trim()   # first line only (robust if wsl returns an array)
if([string]::IsNullOrWhiteSpace($w)){ Die 'could not map the staging folder into WSL (/mnt/c)' }

# Run the tested verifier in WSL over the C: staging. Bash vars kept literal; $w/$SetTs injected.
$body = 'S=~/strateloq-dr-validate/scripts/dr/dr_usb_verify.sh; [ -f "$S" ] || S=$(find ~ -maxdepth 6 -type f -path "*scripts/dr/dr_usb_verify.sh" 2>/dev/null | head -1); [ -f "$S" ] || { echo "ABORT: dr_usb_verify.sh not found under your WSL home"; exit 2; }; ( cd "$(dirname "$S")/../.." && git pull --ff-only >/dev/null 2>&1 || true ); DR_VERIFY_ONLY=1 DR_USB=__W__ DR_SET_TS=__TS__ bash "$S"'
$body = $body.Replace('__W__', ("'" + $w + "'")).Replace('__TS__', ("'" + $SetTs + "'"))

Write-Host '== run WSL verifier (reads /mnt/c staging; decrypts via the existing GPG-agent; one hidden prompt only if the cache is cold) =='
& wsl.exe -e bash -lc $body
$rc = $LASTEXITCODE

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue   # drop the encrypted staging copy
if($rc -ne 0){ Die ('verifier exit ' + $rc + ' - see ~/strateloq-usb-verify-report-*.md in your WSL home') }
Write-Host 'OFFLINE USB VERIFICATION: PASS - USB holds a complete, independently recoverable offline set. Report: ~/strateloq-usb-verify-report-*.md (WSL home).' -ForegroundColor Green
