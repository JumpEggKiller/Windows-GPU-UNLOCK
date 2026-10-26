# Builds every EFI this experiment needs, in the only order that keeps the pairing
# honest:
#   1. the unlock child that a human authorizes with one U      (manual)
#   2. the unlock child that needs no key at all                (automatic)
#   3. the handoff wrapper paired with (1), hash-baked
#   4. the handoff wrapper paired with (2), hash-baked
# Each wrapper refuses to run any image whose length or SHA-256 differs from the one
# recorded here, so a mismatched set stops instead of unlocking with the wrong child.
param(
 [string]$Clang='clang',
 [string]$LldLink='lld-link',
 [string]$Python='python',
 [int]$ExpectedUnlocked=4,
 # The stock profile names the VBIOS/GFW family the unlock expects. It is a property of
 # the cards, not of the board, so it is a parameter: a different family needs its own
 # profile, and the unlock refuses to run when the card on the bench does not match.
 [ValidateSet('original03100062','observed03000062','entryLatchedSs1Preserve','entryLatchedSs1Full')]
 [string]$StockProfile='entryLatchedSs1Full'
)
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $repo=Split-Path -Parent $PSScriptRoot
 $configured=Join-Path $PSScriptRoot 'boot\platform-config.h'
 if(!(Test-Path -LiteralPath $configured)){throw 'boot/platform-config.h is missing: run Configure.ps1 first'}
 $config=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'local-config.json') | ConvertFrom-Json
 "Config: placeholder=$($config.Placeholder); unlock ESP=$($config.UnlockPartitionGuid); letter='$($config.UnlockDriveLetter)'"
 if($config.Placeholder){'WARNING: placeholder GUIDs in this build; it cannot be installed and it cannot find a partition.'}

 $childDir=Join-Path $repo 'unlock\build\multi\experimental\entryLatchedSs1Full\internal'
 $childManual=Join-Path $childDir 'RTX3090-MULTI-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI'
 $childAuto=Join-Path $childDir 'automatic\RTX3090-MULTI-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO.EFI'
 $childArgs=@{Clang=$Clang;LldLink=$LldLink;Python=$Python;MultiTarget=$true;ExperimentalUnlock=$true
  StockProfile=$StockProfile;InternalBoot=$true}

 $unlockBuild=Join-Path $repo 'unlock\build.ps1'
 & $unlockBuild @childArgs
 if($LASTEXITCODE -ne 0){throw 'Manual internal unlock child build failed'}
 & $unlockBuild @childArgs -AutomaticBoot
 if($LASTEXITCODE -ne 0){throw 'Automatic internal unlock child build failed'}

 $children=@(
  @{Path=$childManual;Mode='manual-internal-exact-card-multi-unlock';CanArm=$true},
  @{Path=$childAuto;Mode='automatic-internal-exact-card-multi-unlock';CanArm=$false}
 )
 foreach($child in $children) {
  if(!(Test-Path -LiteralPath $child.Path)){throw "Missing child EFI: $($child.Path)"}
  $manifest=Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $child.Path) 'build-manifest.json') | ConvertFrom-Json
  if($manifest.Mode -ne $child.Mode){throw ('Child {0} reports mode {1}, expected {2}' -f $child.Path,$manifest.Mode,$child.Mode)}
  if([bool]$manifest.CanArm -ne [bool]$child.CanArm){throw ('Child {0} reports CanArm {1}' -f $child.Path,$manifest.CanArm)}
  if([int]$manifest.EligibleExpected -ne $ExpectedUnlocked) {
   throw ('Child {0} expects {1} eligible cards, not {2}' -f $child.Path,$manifest.EligibleExpected,$ExpectedUnlocked)
  }
  $actual=(Get-FileHash -LiteralPath $child.Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actual -ne $manifest.EfiSha256.ToLowerInvariant()){throw ('Child {0} does not match its own manifest' -f $child.Path)}
  "Child OK: $([System.IO.Path]::GetFileName($child.Path)) $actual"
 }

 $wrapper=Join-Path $PSScriptRoot 'boot\build.ps1'
 & $wrapper -Clang $Clang -LldLink $LldLink -Python $Python -Child $childManual -ExpectedUnlocked $ExpectedUnlocked
 if($LASTEXITCODE -ne 0){throw 'Manual handoff wrapper build failed'}
 & $wrapper -Clang $Clang -LldLink $LldLink -Python $Python -Child $childAuto -ExpectedUnlocked $ExpectedUnlocked -Automatic
 if($LASTEXITCODE -ne 0){throw 'Automatic handoff wrapper build failed'}

 $reportDir=Join-Path $PSScriptRoot 'build'
 New-Item -ItemType Directory -Path $reportDir -Force|Out-Null
 $artifacts=@(
  @{Role='manual-unlock-child';Path=$childManual}
  @{Role='automatic-unlock-child';Path=$childAuto}
  @{Role='manual-handoff-wrapper';Path=(Join-Path $PSScriptRoot 'boot\build\manual\HANDOFF.EFI')}
  @{Role='automatic-handoff-wrapper';Path=(Join-Path $PSScriptRoot 'boot\build\automatic\AUTO.EFI')}
 ) | ForEach-Object {
  if(!(Test-Path -LiteralPath $_.Path)){throw "Missing artifact: $($_.Path)"}
  $item=Get-Item -LiteralPath $_.Path
  [pscustomobject][ordered]@{Role=$_.Role;File=$item.Name;Bytes=$item.Length
   Sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
 [ordered]@{
  BuiltUtc=[DateTime]::UtcNow.ToString('o')
  Placeholder=[bool]$config.Placeholder
  ExpectedUnlocked=$ExpectedUnlocked
  StockProfile=$StockProfile
  BoardMeasured=$config.BoardMeasured
  UnlockPartitionGuid=$config.UnlockPartitionGuid
  WindowsPartitionGuid=$config.WindowsPartitionGuid
  Artifacts=$artifacts
 } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reportDir 'build-report.json') -Encoding UTF8
 ''
 'Artifacts:'
 $artifacts | Format-Table Role,File,Bytes,Sha256 -AutoSize | Out-String -Width 200
} finally {Pop-Location}
