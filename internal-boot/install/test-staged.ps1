# Fault injection for the readiness check's staged-set comparison: what is already on the
# volume is compared against the build outputs and the asset manifest, and every difference
# must be reported rather than passed. The real tree is never touched: this builds a scratch
# tree with tiny stand-in files, so the tests stay fast and cannot damage the ESP.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'staged-set.ps1')

$failures = 0

function Fail([string]$Message) {
  Write-Host ('FAIL ' + $Message)
  $script:failures++
}

function Check([string]$Title, [scriptblock]$Body) {
  try { $Body.Invoke() | Out-Null }
  catch { Fail ("{0}: {1}" -f $Title, $_.Exception.Message); return }
  Write-Host ('PASS ' + $Title)
}

function Need([string]$Text, [string]$Needle, [string]$Title) {
  if ($Text -notlike ('*' + $Needle + '*')) { Fail ("{0}: expected '{1}'" -f $Title, $Needle) }
}

$scratch = Join-Path $env:TEMP ('staged-set-' + [guid]::NewGuid().ToString('N'))

# Four stand-in artifacts plus five stand-in assets, laid out exactly like the real ESP.
$files = @(
  [pscustomobject]@{ Role = 'unlock-child'; Relative = 'EFI\WindowsGPUUnlock\UNLOCK.EFI'; Sha256 = '' }
  [pscustomobject]@{ Role = 'unlock-child-auto'; Relative = 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI'; Sha256 = '' }
  [pscustomobject]@{ Role = 'manual-handoff'; Relative = 'EFI\WindowsGPUUnlock\MANUAL.EFI'; Sha256 = '' }
  [pscustomobject]@{ Role = 'automatic-handoff'; Relative = 'EFI\WindowsGPUUnlock\AUTO.EFI'; Sha256 = '' }
)
$assets = @(
  'booter_load_ga102.bin', 'v67-ga102-610.43.03.bin', 'gsp_ga10x.bin',
  'gsp_boot_ga102.bin', 'gsp_boot_desc_ga102.bin'
) | ForEach-Object { [pscustomobject]@{ Name = $_; Sha256 = '' } }

function New-StagedTree {
  foreach ($file in $files) {
    $path = Join-Path $scratch $file.Relative
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value ('payload for ' + $file.Role) -NoNewline
    $file.Sha256 = Get-Sha256 $path
  }
  foreach ($asset in $assets) {
    $path = Join-Path $scratch ('RTX3090-UNLOCK\ASSETS\' + $asset.Name)
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value ('asset ' + $asset.Name) -NoNewline
    $asset.Sha256 = Get-Sha256 $path
  }
}

Write-Host 'staged set: what is already on the volume'
Write-Host ''

try {
  New-Item -ItemType Directory -Force $scratch | Out-Null
  New-StagedTree

  Check 'a complete matching tree reports every file and no problem' {
    $status = Get-StagedStatus -Root $scratch -Files $files -AssetSpec $assets
    if ($status.Total -ne 9) { throw ("total was {0}, expected 9" -f $status.Total) }
    if ($status.Ok -ne 9) { throw ("ok was {0}, expected 9" -f $status.Ok) }
    if ($status.Problems.Count -ne 0) { throw ('unexpected problems: ' + ($status.Problems -join '; ')) }
  }

  Check 'a file that was never staged is reported missing' {
    Remove-Item -LiteralPath (Join-Path $scratch 'EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI')
    $status = Get-StagedStatus -Root $scratch -Files $files -AssetSpec $assets
    if ($status.Ok -ne 8) { throw ("ok was {0}, expected 8" -f $status.Ok) }
    if ($status.Problems.Count -ne 1) { throw ("problems was {0}, expected 1" -f $status.Problems.Count) }
    Need ($status.Problems[0]) 'Not staged on the dedicated ESP: EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI' 'missing file'
  }

  Check 'a file older than the build is reported stale, not accepted' {
    $path = Join-Path $scratch 'EFI\WindowsGPUUnlock\MANUAL.EFI'
    Set-Content -LiteralPath $path -Value 'an older image' -NoNewline
    $status = Get-StagedStatus -Root $scratch -Files $files -AssetSpec $assets
    if ($status.Ok -ne 7) { throw ("ok was {0}, expected 7" -f $status.Ok) }
    $stale = @($status.Problems | Where-Object { $_ -like '*Staged file is older than the build: EFI\WindowsGPUUnlock\MANUAL.EFI*' })
    if ($stale.Count -ne 1) { throw ('no stale report: ' + ($status.Problems -join '; ')) }
  }

  Check 'a staged asset older than the manifest is reported stale' {
    $path = Join-Path $scratch 'RTX3090-UNLOCK\ASSETS\gsp_ga10x.bin'
    Set-Content -LiteralPath $path -Value 'an older asset' -NoNewline
    $status = Get-StagedStatus -Root $scratch -Files $files -AssetSpec $assets
    $stale = @($status.Problems | Where-Object { $_ -like '*Staged asset is older than the manifest: gsp_ga10x.bin*' })
    if ($stale.Count -ne 1) { throw ('no stale asset report: ' + ($status.Problems -join '; ')) }
  }

  Check 'an empty volume reports all nine missing instead of failing open' {
    $empty = Join-Path $scratch 'empty'
    New-Item -ItemType Directory -Force $empty | Out-Null
    $status = Get-StagedStatus -Root $empty -Files $files -AssetSpec $assets
    if ($status.Ok -ne 0) { throw ("ok was {0}, expected 0" -f $status.Ok) }
    if ($status.Problems.Count -ne 9) { throw ("problems was {0}, expected 9" -f $status.Problems.Count) }
  }

  Check 'no files and no assets is a clean empty comparison' {
    $status = Get-StagedStatus -Root $scratch
    if ($status.Total -ne 0) { throw ("total was {0}, expected 0" -f $status.Total) }
    if ($status.Problems.Count -ne 0) { throw 'an empty comparison must not invent problems' }
  }

  Check 'the check never writes to the volume it inspects' {
    $before = @(Get-ChildItem -LiteralPath $scratch -Recurse -File | ForEach-Object { $_.FullName + ':' + $_.LastWriteTimeUtc.Ticks })
    $status = Get-StagedStatus -Root $scratch -Files $files -AssetSpec $assets | Out-Null
    $after = @(Get-ChildItem -LiteralPath $scratch -Recurse -File | ForEach-Object { $_.FullName + ':' + $_.LastWriteTimeUtc.Ticks })
    if (($before -join '|') -ne ($after -join '|')) { throw 'the inspection changed the tree' }
  }

  Write-Host ''
  if ($failures -gt 0) {
    Write-Host ("staged set: {0} failure(s)" -f $failures)
    $script:code = 1
  } else {
    Write-Host 'PASS staged set: a stale or missing file on the ESP is always reported before Gate C'
    $script:code = 0
  }
} finally {
  if (Test-Path -LiteralPath $scratch) { Remove-Item -Recurse -Force -LiteralPath $scratch }
}
exit $script:code
