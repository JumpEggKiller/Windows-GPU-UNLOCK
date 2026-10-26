# Rehearses the exact boot-entry change on an OFFLINE COPY of the boot store.
#
# bcdedit /export writes a standalone hive that bcdedit can then /copy and /set against,
# so the entry shapes and the real command grammar can be proven without touching the live
# store. Every bcdedit call in this file goes through Offline(), which always passes
# /store and refuses to run against anything that is not a temporary .bcd file.
#
# What the copy teaches us: an export canonicalises the {current} alias to {default}. The
# live store prints `displayorder {current}` and accepts {current}; the copy prints
# `{default}` and rejects {current}. Both names address the same object, so this rehearsal
# reads whichever alias the store itself reports and uses that one throughout.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'automatic-policy.ps1')

$failures = New-Object System.Collections.ArrayList
function Fail([string]$Message) {
  [void]$script:failures.Add($Message)
  Write-Host ('FAIL ' + $Message)
}
function Check([string]$Title, [scriptblock]$Body) {
  try { & $Body; Write-Host ('PASS ' + $Title) } catch { Fail ($Title + ': ' + $_.Exception.Message) }
}
function Need([string]$Text, [string]$Needle) {
  if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) { throw ("missing '" + $Needle + "'") }
}

# Values that must survive across Check blocks. A hashtable is used instead of variables
# because each Check body runs in its own scope and plain assignments would not escape it.
$state = @{
  Store         = $null
  NewId         = $null
  EnumBefore    = ''
  EnumAfterCopy = ''
  WindowsAlias  = '{default}'
  LiveReads     = 0
  OfflineCalls  = 0
}

# --- the only place that talks to bcdedit -----------------------------------

function Assert-SandboxedStore([string]$Path) {
  if (-not $Path) { throw 'no store selected' }
  $full = [System.IO.Path]::GetFullPath($Path)
  $temp = [System.IO.Path]::GetFullPath($env:TEMP)
  if (-not $full.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("Refusing to use a store outside {0}: {1}" -f $temp, $full)
  }
  if (-not $full.EndsWith('.bcd', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("Refusing to use a store that is not a .bcd file: {0}" -f $full)
  }
  if ($full -eq [System.IO.Path]::GetFullPath('C:\Windows\Boot\BCD')) { throw 'That is the live store' }
  return $full
}

# Runs bcdedit against the offline store. There is no way to reach the live store here.
function Offline([string[]]$Arguments) {
  $store = Assert-SandboxedStore $state.Store
  $full = @('/store', $store) + $Arguments
  $state.OfflineCalls++
  $text = (& bcdedit @full 2>&1 | Out-String)
  return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $text }
}

# Reads the live store. Only /enum is ever issued this way.
function LiveEnum([string]$Identifier) {
  $state.LiveReads++
  return (& bcdedit @('/enum', $Identifier) 2>&1 | Out-String)
}

$work = Join-Path $env:TEMP ('gu-rehearse-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$storeFile = Assert-SandboxedStore (Join-Path $work 'store.bcd')

Write-Host 'boot entry rehearsal: the whole change, on a copy of the store'

try {
  $liveBefore = LiveEnum 'all'

  Check 'the live store can be exported to a scratch hive' {
    $out = (& bcdedit /export $storeFile 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ('export failed: ' + $out) }
    if (-not (Test-Path -LiteralPath $storeFile)) { throw 'the export produced no file' }
    if ((Get-Item -LiteralPath $storeFile).Length -lt 4096) { throw 'the export is implausibly small' }
  }

  $state.Store = $storeFile
  $state.EnumBefore = (Offline @('/enum','all')).Text
  $state.WindowsAlias = (Get-BootOrder (Offline @('/enum', '{bootmgr}')).Text)[0]
  # The default entry is what an unattended power-on starts. Read it verbosely so this is a raw
  # identifier, not the {current}/{default} alias that a plain enumeration prints.
  $state.DefaultBefore = Get-BootDefault (Offline @('/enum','{bootmgr}','/v')).Text
  # The firmware order is a separate element in the same store; keep its text so the
  # firmware-first rehearsal below can move the unlock entry in front and put it back.
  $state.FirmwareBefore = (Offline @('/enum','{fwbootmgr}')).Text
  Check 'the copy reports a Windows entry to keep in the menu' {
    if (-not $state.WindowsAlias) { throw 'the copy lists no displayorder' }
    # The guard signals refusal by throwing, so success is simply "it returned".
    try { Assert-OrderKeepsWindows @($state.WindowsAlias) | Out-Null }
    catch { throw ('the guard refused the copy order: ' + $_.Exception.Message) }
  }

  # --- registration ---------------------------------------------------------
  $name = 'Windows GPU UNLOCK Manual'

  Check 'the copy names exactly one new entry' {
    $result = Offline @('/copy', '{bootmgr}', '/d', $name)
    if ($result.Exit -ne 0) { throw ('bcdedit /copy failed: ' + $result.Text) }
    $m = [regex]::Match($result.Text, '\{[0-9a-fA-F-]{36}\}')
    if (-not $m.Success) { throw ('no identifier in the output: ' + $result.Text.Trim()) }
    $state.NewId = $m.Value.ToLowerInvariant()
    $state.EnumAfterCopy = (Offline @('/enum','all')).Text
  }

  Check 'the installer policy attributes the real copy to the boot manager' {
    $attributed = Resolve-NewBootCopy -BeforeText $state.EnumBefore -AfterText $state.EnumAfterCopy -Name $name
    if ($attributed -ne $state.NewId) { throw ("policy found {0}, bcdedit created {1}" -f $attributed, $state.NewId) }
  }

  Check 'the copy starts out identical to the boot manager apart from name and id' {
    $shapeSource = Get-BootEntryShape (Get-BootEntryBlock $state.EnumBefore '{bootmgr}')
    $shapeCopy = Get-BootEntryShape (Get-BootEntryBlock $state.EnumAfterCopy $state.NewId)
    if ($shapeSource -ne $shapeCopy) { throw ("shapes differ: '{0}' vs '{1}'" -f $shapeSource, $shapeCopy) }
  }

  # --- point it at our files ------------------------------------------------
  Check 'the entry can be pointed at the manual handoff on the dedicated ESP' {
    foreach ($pair in @(@('device', 'partition=S:'), @('path', '\EFI\WindowsGPUUnlock\MANUAL.EFI'))) {
      $result = Offline @('/set', $state.NewId, $pair[0], $pair[1])
      if ($result.Exit -ne 0) { throw ('/set {0} failed: {1}' -f $pair[0], $result.Text) }
    }
    $text = (Offline @('/enum', $state.NewId)).Text
    Need $text 'partition=S:'
    Need $text '\EFI\WindowsGPUUnlock\MANUAL.EFI'
    Need $text $name
  }

  Check 'the entry can be placed behind Windows in the menu' {
    $result = Offline @('/set', '{bootmgr}', 'displayorder', $state.WindowsAlias, $state.NewId)
    if ($result.Exit -ne 0) { throw ('displayorder failed: ' + $result.Text) }
    $order = Get-BootOrder (Offline @('/enum', '{bootmgr}')).Text
    if (($order -join ',') -ne ($state.WindowsAlias + ',' + $state.NewId)) { throw ('order is ' + ($order -join ',')) }
  }

  # --- the boot default -----------------------------------------------------
  Check 'the copy records which entry an unattended boot starts today' {
    if ($state.DefaultBefore -notmatch '^\{[0-9a-f-]{36}\}$') { throw ('default is not an identifier: ' + $state.DefaultBefore) }
    if ($state.DefaultBefore -eq $state.NewId) { throw 'the copy already starts our entry' }
  }

  Check 'a copied entry can legally become the boot default' {
    # This is the decisive legality question for automatic boot: bcdedit must accept our entry
    # as {bootmgr} default and keep it. It is written with raw bcdedit here because the policy
    # writer Set-BootDefault talks to the live store; this is the copy.
    $result = Offline @('/set', '{bootmgr}', 'default', $state.NewId)
    if ($result.Exit -ne 0) { throw ('bcdedit refused our entry as the default: ' + $result.Text) }
    $readBack = Get-BootDefault (Offline @('/enum','{bootmgr}','/v')).Text
    if ($readBack -ne $state.NewId) { throw ('default did not stick: ' + $readBack) }
  }

  Check 'the policy refuses a default that is not in the store' {
    # bcdedit accepts a default that does not exist, so the policy guard is the only defence.
    try {
      Set-BootDefault -Identifier '{11111111-2222-3333-4444-555555555555}' -KnownIdentifiers @($state.DefaultBefore)
      throw 'the policy accepted a default that is not in the store'
    } catch {
      if ($_.Exception.Message -notmatch 'not in the store') { throw }
    }
  }

  Check 'a short timeout and first place are not enough to be armed' {
    # The exact defect this rehearsal guards against, using the order promotion is about to
    # write: our entry first, a 5 s timeout, Fast Startup off -- and Windows still starting,
    # because the default entry never moved.
    $promotedOrder = @($state.NewId, $state.WindowsAlias)
    $armedButNotDefault = Get-AutomaticArmed -Entry $state.NewId -Default $state.DefaultBefore -Order $promotedOrder -Timeout 5 -Hiberboot 0 -ExpectedTimeout 5
    if ($armedButNotDefault.Armed) { throw 'the machine was called armed while the default entry was still Windows' }
    if (($armedButNotDefault.Reasons -join '; ') -match 'first menu entry|displayorder') {
      throw 'the default was not the reported reason, so the predicate still leans on menu position'
    }
    $armedWithDefault = Get-AutomaticArmed -Entry $state.NewId -Default $state.NewId -Order $promotedOrder -Timeout 5 -Hiberboot 0 -ExpectedTimeout 5
    if (-not $armedWithDefault.Armed) { throw ('not armed even with the default moved: ' + ($armedWithDefault.Reasons -join '; ')) }
    # Put the default back so the promotion check below proves the real write.
    $result = Offline @('/set', '{bootmgr}', 'default', $state.DefaultBefore)
    if ($result.Exit -ne 0) { throw ('could not restore the default: ' + $result.Text) }
  }

  # --- promotion ------------------------------------------------------------
  Check 'promotion puts the entry first and keeps Windows in the menu' {
    foreach ($args in @(
        @('/set', $state.NewId, 'path', '\EFI\WindowsGPUUnlock\AUTO.EFI'),
        @('/set', $state.NewId, 'description', 'Windows GPU UNLOCK Auto'),
        @('/set', '{bootmgr}', 'displayorder', $state.NewId, $state.WindowsAlias),
        @('/set', '{bootmgr}', 'default', $state.NewId),
        @('/set', '{bootmgr}', 'timeout', '5'))) {
      $result = Offline $args
      if ($result.Exit -ne 0) { throw ('{0} failed: {1}' -f ($args -join ' '), $result.Text) }
    }
    # Verbose: once our entry is the default a plain enumeration prints it as {default}, which
    # would never equal the identifier we are looking for.
    $order = Get-BootOrder (Offline @('/enum', '{bootmgr}', '/v')).Text
    if ($order[0] -ne $state.NewId) { throw ('first entry is ' + $order[0]) }
    if ($order -notcontains $state.DefaultBefore) { throw 'Windows fell out of the menu' }
    $timeout = Get-BootTimeout (Offline @('/enum', '{bootmgr}')).Text
    if ($timeout -ne 5) { throw ('timeout is ' + $timeout) }
    $default = Get-BootDefault (Offline @('/enum','{bootmgr}','/v')).Text
    if ($default -ne $state.NewId) { throw ('default is ' + $default) }
    Need (Offline @('/enum', $state.NewId)).Text '\EFI\WindowsGPUUnlock\AUTO.EFI'
    $armed = Get-AutomaticArmed -Entry $state.NewId -Default $default -Order $order -Timeout $timeout -Hiberboot 0 -ExpectedTimeout 5
    if (-not $armed.Armed) { throw ('promotion did not arm: ' + ($armed.Reasons -join '; ')) }
  }

  # --- fault injection ------------------------------------------------------
  Check 'a menu order without the Windows fallback is rejected by the guard' {
    $order = Get-BootOrder (Offline @('/enum', '{bootmgr}')).Text
    $without = @($order | Where-Object { $_ -ne $state.WindowsAlias })
    try { $null = Assert-OrderKeepsWindows $without; throw 'the guard accepted a menu with no Windows entry' }
    catch { if ($_.Exception.Message -notmatch 'without \{current\}') { throw } }
  }

  Check 'writing to an identifier that does not exist fails loudly' {
    $result = Offline @('/set', '{00000000-0000-0000-0000-000000000000}', 'path', '\x.efi')
    if ($result.Exit -eq 0) { throw 'bcdedit accepted a write to a non-existent entry' }
  }

  Check 'a copy that cannot be attributed is refused' {
    # Two new identifiers at once: the policy must refuse to guess which one is ours.
    $decoys = @()
    foreach ($label in @('decoy one', 'decoy two')) {
      $text = (Offline @('/copy', '{bootmgr}', '/d', $label)).Text
      $m = [regex]::Match($text, '\{[0-9a-fA-F-]{36}\}')
      if ($m.Success) { $decoys += $m.Value.ToLowerInvariant() }
    }
    if ($decoys.Count -ne 2) { throw 'could not create two decoy copies' }
    $after = (Offline @('/enum','all')).Text
    try {
      $null = Resolve-NewBootCopy -BeforeText $state.EnumAfterCopy -AfterText $after -Name $name
      throw 'the policy attributed a copy from two candidates'
    } catch {
      if ($_.Exception.Message -notmatch 'Cannot attribute one new boot copy') { throw }
    }
    foreach ($id in $decoys) {
      $result = Offline @('/delete', $id, '/f')
      if ($result.Exit -ne 0) { throw ('could not remove decoy {0}: {1}' -f $id, $result.Text) }
    }
  }

  # --- recovery -------------------------------------------------------------
  Check 'the restore sequence puts Windows first and keeps the unlock entry' {
    $order = Get-BootOrder (Offline @('/enum', '{bootmgr}', '/v')).Text
    # The restore writes the Windows identifier first and keeps everything else behind it.
    $desired = @($state.DefaultBefore) + @($order | Where-Object { $_ -ne $state.DefaultBefore })
    foreach ($args in @(
        (@('/set', '{bootmgr}', 'displayorder') + $desired),
        @('/set', '{bootmgr}', 'default', $state.DefaultBefore),
        @('/set', '{bootmgr}', 'timeout', '30'),
        @('/set', $state.NewId, 'path', '\EFI\WindowsGPUUnlock\MANUAL.EFI'),
        @('/set', $state.NewId, 'description', 'Windows GPU UNLOCK Manual'))) {
      $result = Offline $args
      if ($result.Exit -ne 0) { throw ('{0} failed: {1}' -f ($args -join ' '), $result.Text) }
    }
    $restored = Get-BootOrder (Offline @('/enum', '{bootmgr}', '/v')).Text
    if ($restored[0] -ne $state.DefaultBefore) { throw ('first entry is ' + $restored[0]) }
    if ($restored -notcontains $state.NewId) { throw 'the unlock entry was lost' }
    if ((Get-BootTimeout (Offline @('/enum', '{bootmgr}')).Text) -ne 30) { throw 'timeout did not come back' }
    $default = Get-BootDefault (Offline @('/enum','{bootmgr}','/v')).Text
    if ($default -ne $state.DefaultBefore) { throw ('the default was not restored: ' + $default) }
    if ($default -eq $state.NewId) { throw 'the unlock entry is still what an unattended boot would start' }
    Need (Offline @('/enum', $state.NewId)).Text '\EFI\WindowsGPUUnlock\MANUAL.EFI'
  }

  Check 'the unlock entry can be removed without touching the boot manager' {
    $result = Offline @('/delete', $state.NewId, '/f')
    if ($result.Exit -ne 0) { throw ('/delete failed: ' + $result.Text) }
    $text = (Offline @('/enum','all')).Text
    if ($text.ToLowerInvariant().Contains($state.NewId)) { throw 'the entry is still listed' }
    Need $text '{bootmgr}'
    Need $text $state.WindowsAlias
    $default = Get-BootDefault (Offline @('/enum','{bootmgr}','/v')).Text
    if ($default -ne $state.DefaultBefore) { throw ('deleting the entry moved the default to ' + $default) }
  }

  Check 'the live boot store is untouched' {
    $liveAfter = LiveEnum 'all'
    if ($liveAfter -ne $liveBefore) { throw 'the live store changed while rehearsing' }
  }

  # --- firmware order -------------------------------------------------------
  # The unattended route on this machine is the firmware's own order, because bootmgfw
  # refuses an image built here (0x7B, 0x221, 0x428 on the real machine). The grammar is
  # rehearsed on the scratch store: the firmware order is its own element, its positions
  # are read back, and the unlock entry can be moved in front and put back.
  Check 'the firmware order can put the unlock entry in front of the boot manager' {
    $fwBefore = Get-BootOrder $state.FirmwareBefore
    if ($fwBefore -notcontains '{bootmgr}') { throw 'the real firmware order lost {bootmgr}' }
    $fwDesired = @($state.NewId) + @($fwBefore | Where-Object { $_ -ne $state.NewId })
    $result = Offline (@('/set', '{fwbootmgr}', 'displayorder') + $fwDesired)
    if ($result.Exit -ne 0) { throw ('firmware displayorder failed: ' + $result.Text) }
    $fwNow = Get-BootOrder (Offline @('/enum', '{fwbootmgr}')).Text
    if ($fwNow.Count -ne $fwDesired.Count) { throw ('firmware order has {0} entries, expected {1}' -f $fwNow.Count, $fwDesired.Count) }
    if ($fwNow[0] -ne $state.NewId) { throw ('the firmware starts {0} first' -f $fwNow[0]) }
    if ($fwNow -notcontains '{bootmgr}') { throw 'the firmware order dropped the Windows boot manager' }
    # A guard proof on the same data: an order that starts with the unlock image and then
    # omits {bootmgr} is exactly what the machine must never be left with.
    try {
      Assert-FirmwareOrderKeepsWindows -Identifiers @($state.NewId)
      throw 'the guard accepted a firmware order without the Windows boot manager'
    } catch {
      if ($_.Exception.Message -notmatch 'without the Windows boot manager') { throw }
    }
    Assert-FirmwareOrderKeepsWindows -Identifiers $fwNow
  }

  Check 'the firmware order can be put back to what it was' {
    $result = Offline (@('/set', '{fwbootmgr}', 'displayorder') + (Get-BootOrder $state.FirmwareBefore))
    if ($result.Exit -ne 0) { throw ('restoring the firmware order failed: ' + $result.Text) }
    $fwNow = Get-BootOrder (Offline @('/enum', '{fwbootmgr}')).Text
    $fwBefore = Get-BootOrder $state.FirmwareBefore
    if ($fwNow.Count -ne $fwBefore.Count) { throw 'the firmware order did not come back' }
    for ($i = 0; $i -lt $fwBefore.Count; $i++) {
      if ($fwNow[$i] -ne $fwBefore[$i]) { throw ('firmware position {0} is {1}, was {2}' -f $i, $fwNow[$i], $fwBefore[$i]) }
    }
  }
} finally {
  if (Test-Path -LiteralPath $work) {
    try { Remove-Item -LiteralPath $work -Recurse -Force } catch { Write-Warning ('Could not remove {0}' -f $work) }
  }
}

if ($failures.Count -gt 0) {
  Write-Host ('boot entry rehearsal: {0} failure(s)' -f $failures.Count)
  exit 1
}
Write-Host ('PASS boot entry rehearsal: registration, promotion, fault injection and recovery on a scratch hive ({0} offline calls, {1} live reads, all read-only)' -f $state.OfflineCalls,$state.LiveReads)
exit 0


