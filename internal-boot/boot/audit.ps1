# Source audit for the internal-boot tree.
#
# These are textual proofs about the shipped sources, not style checks. Each needle is
# something whose absence would mean a safety property was lost: a reset path, a second
# Windows start, a hash check that no longer gates the load, a record check that no
# longer requires every card, a media policy that accepts anything.
#
# Judged by exit code, like the other suites.

param([string]$Repository = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.ArrayList

function Read-Source([string]$Relative) {
  $path = Join-Path $Repository $Relative
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing source: $Relative" }
  return Get-Content -Raw -LiteralPath $path
}

function Need([string]$Name, [string]$Text, [string]$Needle) {
  if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
    [void]$script:failures.Add("${Name}: missing '$Needle'")
  }
}

function Forbid([string]$Name, [string]$Text, [string]$Needle) {
  if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) {
    [void]$script:failures.Add("${Name}: must not contain '$Needle'")
  }
}

function Count([string]$Text, [string]$Needle) {
  $count = 0
  $at = 0
  while (($at = $Text.IndexOf($Needle, $at, [System.StringComparison]::Ordinal)) -ge 0) {
    $count++
    $at += $Needle.Length
  }
  return $count
}

# --- handoff wrapper ---------------------------------------------------------

$handoff = Read-Source 'internal-boot\boot\handoff.c'

# The child's bytes are hashed and then executed from that same buffer.
Need 'handoff.c' $handoff 'GuHashMatches(image,GU_UNLOCK_BYTES,GU_UNLOCK_SHA256)'
Need 'handoff.c' $handoff 'LoadImage(FALSE,Self,path,image,GU_UNLOCK_BYTES,&UnlockImage)'
Need 'handoff.c' $handoff 'loaded->DeviceHandle!=OwnDevice'
Need 'handoff.c' $handoff 'loaded->DeviceHandle!=WindowsDevice'

# Windows starts only after a clean, complete end-of-batch record.
Need 'handoff.c' $handoff 'GuHandoffAccept(&record,(UINT32)GU_EXPECTED_UNLOCKED)'
Need 'handoff.c' $handoff 'UNLOCK DID NOT LEAVE A CLEAN END-OF-BATCH RECORD'
Need 'handoff.c' $handoff 'ClearHandoff'
Need 'handoff.c' $handoff 'GU_RECORD_FILE'

# Exactly two image starts: the child, then Windows. A third would be a second path into
# the unlock or into Windows that the flow does not gate.
$starts = Count $handoff 'StartImage('
if ($starts -ne 2) { [void]$failures.Add("handoff.c: expected exactly 2 StartImage calls, found $starts") }

# A failed boot must stop, never reset, never retry, never fall through to firmware.
Need 'handoff.c' $handoff 'HANDOFF STOPPED. No reset and no automatic retry.'
Need 'handoff.c' $handoff 'SetWatchdogTimer(0,0,0,NULL)'
Need 'handoff.c' $handoff '__asm__ volatile("pause")'
Forbid 'handoff.c' $handoff 'ResetSystem'
Forbid 'handoff.c' $handoff 'EfiResetCold'
Forbid 'handoff.c' $handoff 'EfiResetWarm'

# Windows is reached by device path; its filesystem is never opened.
Need 'handoff.c' $handoff 'GU_BOOTMGR_FILE'
Need 'handoff.c' $handoff 'MEDIA_FILEPATH_DP'
Need 'handoff.c' $handoff 'EFI_STATUS LoadWindows(VOID)'

# Exact-media policy: the internal partition must be the one the image was built for.
Need 'handoff.c' $handoff 'GuInternalPartition'
Need 'handoff.c' $handoff 'GuWindowsPartition'

# --- flow ---------------------------------------------------------------------

$flow = Read-Source 'internal-boot\boot\flow.c'
Need 'flow.c' $flow 'if(status!=EFI_SUCCESS)return status;'
Need 'flow.c' $flow 'unlock-return'
Need 'flow.c' $flow 'windows-preloaded'
Need 'flow.c' $flow 'skip-unlock'
Need 'flow.c' $flow 'windows-return-unexpected'
# A warning is not success: the flow must not use EFI_ERROR as its only test.
Forbid 'flow.c' $flow 'EFI_ERROR('

# --- end-of-batch record ------------------------------------------------------

$record = Read-Source 'internal-boot\boot\record.h'
Need 'record.h' $record 'GU_HANDOFF_MAGIC "GUH1 "'
# Lower-case hex only: an upper-case digit is treated as a different writer.
Need 'record.h' $record "c>='a' && c<='f'"
Need 'record.h' $record 'if(!digits)return FALSE;'
Need 'record.h' $record "if(digits>1 && Text[at-digits]=='0')return FALSE;"
Need 'record.h' $record 'Record->Status==EFI_SUCCESS'
Need 'record.h' $record 'Record->Unlocked==Record->Eligible'
Need 'record.h' $record 'Record->Retained==Record->Unlocked'
Need 'record.h' $record 'Record->Clean==Record->Unlocked'
Need 'record.h' $record '!Expected'

# --- media policy -------------------------------------------------------------

$media = Read-Source 'internal-boot\boot\media.h'
Need 'media.h' $media 'MBRType==2'
Need 'media.h' $media 'SignatureType==2'
Need 'media.h' $media 'PartitionSize'
Need 'media.h' $media 'GuGuidEqual(drive->Signature,Guid)'
Need 'media.h' $media 'END_ENTIRE_DEVICE_PATH_SUBTYPE'
Need 'media.h' $media '(usb || (InternalAllowed && partition))'

# --- unlock child -------------------------------------------------------------

$app = Read-Source 'unlock\app.c'
Need 'app.c' $app 'Automatic boot requires the multi-target experimental internal entryLatchedSs1Full profile'
Need 'app.c' $app 'GuWriteHandoff('
Need 'app.c' $app 'AUTOMATIC BATCH UNLOCK'
Need 'app.c' $app 'no key is required'
# The batch authorization must still be able to abort before any card is touched.
Need 'app.c' $app 'EFI_ABORTED'

$appIo = Read-Source 'unlock\app_io.c'
Need 'app_io.c' $appIo 'return GuPathIsPartition(path,&GuInternalPartition);'
Need 'app_io.c' $appIo 'return GuAllowedMediaPath(path,TRUE);'
Need 'app_io.c' $appIo 'GuWriteHandoff(UINT64 Status'
Need 'app_io.c' $appIo 'HANDOFF.ST'
# The USB-only walk must survive for builds that are neither internal nor automatic.
Need 'app_io.c' $appIo 'MSG_USB_DP'

# The card that drives the console must stay excluded, and the display gate must stay.
$targets = Read-Source 'unlock\targets_local.h'
if ($targets -notmatch 'GU_CARD\(\s*"GPU0"[^)]*?FALSE') {
  [void]$failures.Add('targets_local.h: GPU0 must keep UnlockAllowed FALSE')
}
Need 'targets_local.h' $targets 'GU_DISPLAY_LOG_ONLY 1'
Need 'targets_local.h' $targets 'GU_BAR0_BASE 0ULL'

$guard = Read-Source 'unlock\app.c' + (Read-Source 'unlock\checks.c')
Need 'app.c/checks.c' $guard 'sits on target BDF'

# --- install scripts ----------------------------------------------------------

$install = Read-Source 'internal-boot\Install.ps1'
Need 'Install.ps1' $install 'Refusing to overwrite different file'
Need 'Install.ps1' $install 'RestoreWindowsFirst'
Need 'Install.ps1' $install 'ConfirmedManualSuccess'
Need 'Install.ps1' $install 'recovery-plan.json'
Need 'Install.ps1' $install 'a boot entry must name the partition the image was built for'
Forbid 'Install.ps1' $install 'bcdedit /delete'

$policy = Read-Source 'internal-boot\install\automatic-policy.ps1'
Need 'automatic-policy.ps1' $policy 'that removes the Windows fallback'
Need 'automatic-policy.ps1' $policy 'Cannot attribute one new boot copy'

# --- report -------------------------------------------------------------------

if ($failures.Count -gt 0) {
  foreach ($failure in $failures) { Write-Host ('FAIL ' + $failure) }
  Write-Host ('internal-boot source audit: {0} failure(s)' -f $failures.Count)
  exit 1
}

Write-Host 'internal-boot source audit: PASS'
Write-Host '  handoff: hash-then-execute, one Windows start, stop instead of reset, no second path'
Write-Host '  flow: any non-success stops the handoff'
Write-Host '  record: GUH1, lower-case hex, every card unlocked and retained'
Write-Host '  media: exact partition GUID, GPT, one hard-drive node'
Write-Host '  child: automatic batch authorization, record written, GPU0 still disallowed'
exit 0
