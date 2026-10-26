<#
.SYNOPSIS
  Generate unlock/targets_local.h for THIS machine, from a Windows GPU inventory
  and from a read-only probe report.

.DESCRIPTION
  The unlock build is pinned to exact card identities: BDF, subsystem, config[0xc8]
  and the 1 MiB PROM SHA-256 of each card. Two of those can be read from Windows
  (BDF, subsystem); the PROM hash can only be measured by the EFI probe, because
  it needs the card's BAR0 window.

  So adopting this project on a new machine is two builds:

    1. -Inventory            writes a PROBE header: real BDF + subsystem, the
                             standard config[0xc8], and an EMPTY PROM pin. An
                             empty pin makes the EFI log the measured hash
                             ("PROM sha256 (log-only, unverified)") instead of
                             gating on it.
    2. -ProbeReport <files>  reads those lines back and writes the FINAL header
                             with the measured PROM hash per card.

  Card count is detected, not declared: the inventory is whatever nvidia-smi
  reports, and the final header must find one PROM hash per card or it refuses.
  The display adapter (the card whose GOP the console is on) is always placed
  LAST, because releasing its firmware driver can blank the console for the rest
  of the batch.

.PARAMETER Inventory
  Derive the card list from nvidia-smi and write a probe header.

.PARAMETER ProbeReport
  One or more probe reports (S:\RTX3090-UNLOCK\RUNnn\REPORT.TXT). Every card in
  the inventory must have exactly one measured PROM hash.

.PARAMETER OutFile
  Destination, default unlock\targets_local.h

.PARAMETER DisplayBdf
  Force which card is the display adapter. Default: the card nvidia-smi reports
  display_active=Enabled. Recorded policy, not a measurement.

.PARAMETER AllowDevice
  PCI device ids that may be unlocked. Default 0x2204 (RTX 3090). Anything else
  is refused, because a different VBIOS/GFW family needs its own stock profile.

.EXAMPLE
  # step 1: probe header
  .\pins-from-report.ps1 -Inventory -OutFile ..\unlock\targets_local.probe.h

.EXAMPLE
  # step 2: final header from what the probe logged
  .\pins-from-report.ps1 -ProbeReport 'S:\RTX3090-UNLOCK\RUN00\REPORT.TXT'
#>
[CmdletBinding(DefaultParameterSetName = 'Inventory')]
param(
  [Parameter(ParameterSetName = 'Inventory')]
  [switch]$Inventory,

  [Parameter(ParameterSetName = 'Final', Mandatory = $true)]
  [string[]]$ProbeReport,

  [string]$OutFile,
  [string]$DisplayBdf,
  [int[]]$AllowDevice = @(0x2204)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# [System.IO.File] and New-Item resolve against the PROCESS directory, which is not
# the PowerShell location; make the destination absolute once, up front. Note that
# Join-Path in Windows PowerShell 5.1 concatenates even when the child is rooted, so
# the rooted check has to come first or "C:\..." becomes "<cwd>\C:\...".
if ($OutFile) {
  if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).Path $OutFile }
  $OutFile = [System.IO.Path]::GetFullPath($OutFile)
}

function Fail([string]$Message) { throw ("pins-from-report: " + $Message) }

# "00000000:41:00.0" -> segment 0, bus 0x41, device 0, function 0
# Fields are %x-formatted in the EFI log ("0:c1:0.0") and zero padded in nvidia-smi
# output ("00000000:41:00.0"), so accept both widths and normalise through Format-Bdf.
function ConvertFrom-Bdf([string]$Text) {
  if ($Text -notmatch '^(?<seg>[0-9A-Fa-f]{1,8}):(?<bus>[0-9A-Fa-f]{1,2}):(?<dev>[0-9A-Fa-f]{1,2})\.(?<fun>[0-7])$') {
    Fail ("'{0}' is not a PCI address in seg:bus:dev.fun form" -f $Text)
  }
  [pscustomobject]@{
    Segment  = [Convert]::ToInt32($Matches['seg'], 16)
    Bus      = [Convert]::ToInt32($Matches['bus'], 16)
    Device   = [Convert]::ToInt32($Matches['dev'], 16)
    Function = [Convert]::ToInt32($Matches['fun'], 16)
  }
}

function Format-Bdf($Card) {
  '{0:x}:{1:x2}:{2:x2}.{3:x1}' -f $Card.Segment, $Card.Bus, $Card.Device, $Card.Function
}

function Get-GpuInventory {
  $raw = & nvidia-smi --query-gpu=index,pci.bus_id,pci.device_id,pci.sub_device_id,name,display_active --format=csv,noheader 2>&1
  if ($LASTEXITCODE -ne 0) { Fail ("nvidia-smi failed: " + ($raw | Out-String).Trim()) }
  $cards = @()
  foreach ($line in @($raw)) {
    if (-not $line -or $line -notmatch ',') { continue }
    $f = $line -split ','
    if ($f.Count -lt 6) { Fail ("unexpected nvidia-smi row: " + $line) }
    $bdf = ConvertFrom-Bdf ($f[1].Trim())
    $deviceWord = [Convert]::ToInt32(($f[2].Trim() -replace '^0x', ''), 16)
    # nvidia-smi reports device<<16 | vendor, so "0x220410DE" is device 0x2204, vendor 0x10de
    $device = ($deviceWord -shr 16) -band 0xffff
    $vendor = $deviceWord -band 0xffff
    if ($vendor -ne 0x10de) { Fail ("{0} reports vendor 0x{1:x4}; only NVIDIA cards can use this profile" -f $f[4].Trim(), $vendor) }
    $subsystem = [Convert]::ToInt32(($f[3].Trim() -replace '^0x', ''), 16)
    if ($AllowDevice -notcontains $device) {
      Fail ("{0} is device {1:x4}; this profile only unlocks {2}. A different VBIOS/GFW family needs its own stock profile - do not force it." -f `
          $f[4].Trim(), $device, (($AllowDevice | ForEach-Object { '0x{0:x4}' -f $_ }) -join ','))
    }
    $cards += [pscustomobject]@{
      Index       = [int]$f[0].Trim()
      Segment     = $bdf.Segment
      Bus         = $bdf.Bus
      Device      = $bdf.Device
      Function    = $bdf.Function
      Subsystem   = $subsystem
      ConfigC8    = [int]0x00050011
      Prom        = ''
      Name        = $f[4].Trim()
      Display     = ($f[5].Trim() -eq 'Enabled')
    }
  }
  if (-not $cards) { Fail 'nvidia-smi reported no GPUs' }
  $dup = $cards | Group-Object { Format-Bdf $_ } | Where-Object { $_.Count -gt 1 }
  if ($dup) { Fail ("the inventory repeats a PCI address: " + ($dup.Name -join ', ')) }
  $cards
}

# Parse what the probe build logged. Sequential, because the app probes one card
# at a time: a PROM hash belongs to the most recent target block above it.
function Get-ProbeFacts([string[]]$Paths) {
  $facts = [ordered]@{}
  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) { Fail ("report not found: " + $path) }
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $path)) {
      if ($line -match '^target\[(?<i>\d+)\] identity=(?<rest>.*)$') {
        $rest = $Matches['rest']
        # a line we cannot read is a report we cannot trust; refuse instead of skipping it
        if ($rest -notmatch '^(?<bdf>[0-9A-Fa-f]{1,8}:[0-9A-Fa-f]{1,2}:[0-9A-Fa-f]{1,2}\.[0-7]) subsystem=(?<sub>0x[0-9A-Fa-f]+)') {
          Fail ('cannot read a target identity line: ' + $line)
        }
        $subsystem = [Convert]::ToInt32($Matches['sub'], 16)
        # normalise to the same canonical form the inventory uses
        $current = Format-Bdf (ConvertFrom-Bdf $Matches['bdf'])
        if (-not $facts.Contains($current)) {
          $facts[$current] = [pscustomobject]@{ Bdf = $current; Subsystem = $subsystem; Prom = ''; C8 = $null; Device = $null }
        }
        continue
      }
      if ($null -eq $current) { continue }
      if ($line -match '^config\[00\]=(?<dev>[0-9A-Fa-f]{8}) ') {
        $facts[$current].Device = [Convert]::ToInt32($Matches['dev'].Substring(4, 4), 16)
      }
      elseif ($line -match '^config\[20\]=[0-9A-Fa-f]{8} [0-9A-Fa-f]{8} [0-9A-Fa-f]{8} (?<sub>[0-9A-Fa-f]{8})') {
        $facts[$current].Subsystem = [Convert]::ToInt32($Matches['sub'], 16)
      }
      elseif ($line -match '^config\[c0\]=[0-9A-Fa-f]{8} [0-9A-Fa-f]{8} (?<c8>[0-9A-Fa-f]{8})') {
        $facts[$current].C8 = [Convert]::ToInt32($Matches['c8'], 16)
      }
      elseif ($line -match '^PROM sha256 \(log-only, unverified\): (?<h>[0-9A-Fa-f]{64})') {
        $facts[$current].Prom = $Matches['h'].ToLowerInvariant()
      }
    }
  }
  $facts
}

function New-CardRow($Card, [string]$Prom, [string]$Name, [bool]$MaySit, [bool]$Last) {
  $promText = if ($Prom) { '"' + $Prom + '"' } else { '""' }
  $mayText = if ($MaySit) { 'TRUE' } else { 'FALSE' }
  $line1 = ('  GU_CARD("{0}", {1}, 0x{2:X2}, {3}, {4}, 0x{5:X8}U, 0x{6:X8}U,' -f `
      $Name, $Card.Segment, $Card.Bus, $Card.Device, $Card.Function, $Card.Subsystem, $Card.ConfigC8)
  $line2 = ('          {0}, TRUE, {1})' -f $promText, $mayText)
  $row = $line1.PadRight(100) + " \`n" + $line2
  if (-not $Last) { $row = $row.PadRight($row.Length + 4) + ' \' }
  return $row
}

function Write-Header($Rows, [string]$Mode, [string]$OutFile) {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
  # one macro row per entry: join explicitly, because a here-string interpolates an
  # array with spaces and would put every GU_CARD on the same physical line
  $table = ($Rows -join "`n")
  $body = @"
/* targets_local.h - GENERATED by unlock/pins-from-report.ps1 ($Mode) at $stamp.

   Every value below is measured on this machine, not copied from another one:
     - BDF and subsystem come from nvidia-smi.
     - config[0xc8] and the PROM SHA-256 come from the read-only EFI probe.
   A card whose PROM pin is empty ("") is NOT unlockable - the app logs the measured
   hash instead of gating on it, which is exactly what the probe build needs.

   ROW ORDER IS EXECUTION ORDER. The display adapter is always last: releasing its
   firmware driver can blank the UEFI console for the rest of the batch, and every
   other card must have finished writing its log before that can happen.

   display_may_sit_on_target_gop is granted to the display adapter only. DisplayCheck
   still refuses a GOP on any other card's BDF, and still refuses the display adapter
   unless a second physical GOP survives, so "unlock the only display path" stays
   impossible by construction. */
#pragma once

#ifndef GU_BAR0_BASE
#define GU_BAR0_BASE 0ULL
#endif
#ifndef GU_DISPLAY_LOG_ONLY
#define GU_DISPLAY_LOG_ONLY 1
#endif

#define GU_CARD_TABLE(GU_CARD)                                                                     \
$table
"@
  if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($OutFile, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Wrote {0} ({1} cards, {2})" -f $OutFile, $Rows.Count, $Mode)
  }
  $body
}

# ---- inventory (probe header) -------------------------------------------------
$cards = Get-GpuInventory
if ($DisplayBdf) {
  $want = (ConvertFrom-Bdf $DisplayBdf)
  foreach ($c in $cards) {
    $c.Display = ($c.Segment -eq $want.Segment -and $c.Bus -eq $want.Bus -and $c.Device -eq $want.Device -and $c.Function -eq $want.Function)
  }
  if (-not ($cards | Where-Object { $_.Display })) { Fail ("-DisplayBdf {0} is not in the inventory" -f $DisplayBdf) }
}
if (@($cards | Where-Object { $_.Display }).Count -eq 0) {
  Write-Warning 'nvidia-smi reports no display-active card; the last card in BDF order will be treated as the display adapter. Set -DisplayBdf to override.'
  ($cards | Sort-Object -Property Bus, Device, Function)[-1].Display = $true
}

$ordered = @($cards | Sort-Object -Property @{ Expression = { $_.Display } }, Bus, Device, Function)
$names = @{}
for ($i = 0; $i -lt $ordered.Count; $i++) {
  # name the rows GPU0..GPUn in board order (not nvidia-smi order) so the log reads
  # the same way as the PCIe slot numbers a human uses
  $names[(Format-Bdf $ordered[$i])] = 'GPU' + $i
}

if ($PSCmdlet.ParameterSetName -eq 'Inventory') {
  $rows = @()
  for ($i = 0; $i -lt $ordered.Count; $i++) {
    $c = $ordered[$i]
    $rows += (New-CardRow $c '' $names[(Format-Bdf $c)] ([bool]$c.Display) ($i -eq $ordered.Count - 1))
  }
  $text = Write-Header $rows 'probe' $OutFile
  if (-not $OutFile) { $text }
  Write-Host ''
  Write-Host 'Next: build the probe, boot it from the ESP, then run this script again with'
  Write-Host '      -ProbeReport S:\RTX3090-UNLOCK\RUN00\REPORT.TXT'
  Write-Host ("Cards detected: {0}" -f (($ordered | ForEach-Object { '{0}={1}{2}' -f $names[(Format-Bdf $_)], (Format-Bdf $_), $(if ($_.Display) { ' (display)' } else { '' }) }) -join ', '))
  return
}

# ---- final header -------------------------------------------------------------
$facts = Get-ProbeFacts $ProbeReport
$rows = @()
$problems = @()
for ($i = 0; $i -lt $ordered.Count; $i++) {
  $c = $ordered[$i]
  $bdf = Format-Bdf $c
  if (-not $facts.Contains($bdf)) {
    $problems += ("no probe block for {0} in the report; did the probe build list this card?" -f $bdf)
    continue
  }
  $fact = $facts[$bdf]
  if (-not $fact.Prom) { $problems += ("no measured PROM hash for {0}; the probe must run with an empty PROM pin" -f $bdf) }
  if ($fact.Prom -and $fact.Prom -notmatch '^[0-9a-f]{64}$') { $problems += ("PROM hash for {0} is not 64 hex digits: {1}" -f $bdf, $fact.Prom) }
  $c.Subsystem = $fact.Subsystem
  if ($null -ne $fact.C8 -and $fact.C8 -ne 0) { $c.ConfigC8 = $fact.C8 }
  $rows += (New-CardRow $c $fact.Prom $names[$bdf] ([bool]$c.Display) ($i -eq $ordered.Count - 1))
  Write-Host ("{0} {1} subsystem=0x{2:x8} c8=0x{3:x8} prom={4}{5}" -f $names[$bdf], $bdf, $c.Subsystem, $c.ConfigC8, $(if ($fact.Prom) { $fact.Prom } else { '<missing>' }), $(if ($c.Display) { ' display' } else { '' }))
}
if ($problems.Count) { Fail ("refusing to write a partial pin table:`n  - " + ($problems -join "`n  - ")) }

$text = Write-Header $rows 'final' $OutFile
if (-not $OutFile) { $text }
Write-Host ''
Write-Host ("Pinned {0} card(s). Build next: .\build.ps1 -MultiTarget -ExperimentalUnlock -StockProfile entryLatchedSs1Full -InternalBoot" -f $rows.Count)
