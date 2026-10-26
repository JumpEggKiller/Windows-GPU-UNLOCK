# Modified 2026-10-19/20 for Windows GPU UNLOCK; changes documented in CHANGES.md.
param(
 [string]$Clang='clang',
 [string]$LldLink='lld-link',
 [string]$Python='python',
 [switch]$ExperimentalUnlock,
 [switch]$MachineLocal,
 [switch]$MultiTarget,
 [switch]$InternalBoot,
 [switch]$AutomaticBoot,
 [ValidateSet('original03100062','observed03000062','entryLatchedSs1Preserve','entryLatchedSs1Full')][string]$StockProfile
)
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 if(!(Test-Path -LiteralPath $PSScriptRoot)){throw 'Missing output parent'}
 if($ExperimentalUnlock -and !$PSBoundParameters.ContainsKey('StockProfile')){throw '-StockProfile is required with -ExperimentalUnlock'}
 if(!$ExperimentalUnlock -and $PSBoundParameters.ContainsKey('StockProfile')){throw '-StockProfile is only valid with -ExperimentalUnlock'}
 if($MultiTarget -and $MachineLocal){throw '-MultiTarget and -MachineLocal are mutually exclusive machine profiles'}
 # The unattended child runs on a rig whose console GOP belongs to a card the table
 # excludes, so it is only ever valid on the measured multi-target profile. app.c
 # repeats this as a compile-time #error; refusing here keeps the manifest honest.
 if($InternalBoot -and (!$ExperimentalUnlock -or $StockProfile -ne 'entryLatchedSs1Full')){throw '-InternalBoot requires -ExperimentalUnlock -StockProfile entryLatchedSs1Full'}
 if($AutomaticBoot -and (!$InternalBoot -or !$MultiTarget)){throw '-AutomaticBoot requires -MultiTarget -InternalBoot'}
 $out=if($MultiTarget){"build/multi/"+$(if($ExperimentalUnlock){"experimental/$StockProfile"}else{'preflight'})}elseif($ExperimentalUnlock){"build/experimental/$StockProfile"}elseif($MachineLocal){'build/local'}else{'build'}
 $name=if($MultiTarget){"RTX3090-MULTI-"+$(if($ExperimentalUnlock){"EXPERIMENTAL-$StockProfile"}else{'PREFLIGHT'})}elseif($ExperimentalUnlock){"RTX3090-EXPERIMENTAL-$StockProfile"}elseif($MachineLocal){'RTX3090-PREFLIGHT-LOCAL'}else{'RTX3090-PREFLIGHT'}
 if($InternalBoot){$out+='/internal';$name+='-INTERNAL'}
 if($AutomaticBoot){$out+='/automatic';$name+='-AUTO'}
 $defines=@()
 if($MachineLocal){$defines+= '-DGU_MACHINE_LOCAL'}
 if($MultiTarget){$defines+= '-DGU_MULTI_TARGET'}
 if($InternalBoot){$defines+= '-DGU_INTERNAL_BOOT'}
 if($AutomaticBoot){$defines+= '-DGU_AUTOMATIC_BOOT'}
  if($ExperimentalUnlock){$defines+= '-DGU_EXPERIMENTAL_3090';$defines+=$(switch($StockProfile){'original03100062'{'-DGU_STOCK_PROFILE_ORIGINAL_03100062'} 'observed03000062'{'-DGU_STOCK_PROFILE_OBSERVED_03000062'} 'entryLatchedSs1Preserve'{'-DGU_ENTRY_LATCHED_SS1_PRESERVE'} 'entryLatchedSs1Full'{'-DGU_ENTRY_LATCHED_SS1_FULL'}})}
 New-Item -ItemType Directory -Path $out -Force | Out-Null
 # PromSha256 records the runtime PROM pin baked into THIS build (consumed by
 # PromCheck via GU_PROM_SHA256_LOCAL). Single source of truth for machine-local
 # builds is machine_local.h; parse it so the manifest cannot drift from the binary.
 $promPin='8ea297373e9e5d3600ff41ad9fae88f2d14c98c017d100669f7333981da673b4'
 if($MachineLocal){
  $m=Select-String -LiteralPath 'machine_local.h' -Pattern '#define\s+GU_PROM_SHA256_LOCAL\s+"([0-9a-f]{64})"'
  $promPin=if($m){$m.Matches[0].Groups[1].Value}else{'log-only (unpinned in machine_local.h)'}
 }
 if($MultiTarget){$promPin='per-card (targets_local.h; see Targets below)'}
 $sources=@('app','app_io','ownership','format','runtime','sha256','checks','port','compat',
  'vendor/unlock_610','vendor/prep_610','vendor/layout_610','vendor/vbios_610','vendor/gfw_eval')
 if($MultiTarget){$sources+= 'targets'}
 # Per-card table for the manifest. targets_local.h wraps a long GU_CARD row across
 # continuation lines, so the file is joined before matching: a line-oriented match
 # silently drops any row carrying a 64-char PROM pin, which makes the manifest
 # under-report the targets actually baked into the binary.
 $targetRows=@()
 if($MultiTarget){
  $joined=(Get-Content -Raw -LiteralPath 'targets_local.h') -replace '\\\r?\n',' '
  $pattern='GU_CARD\(\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(0x[0-9A-Fa-f]+)U?\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(0x[0-9A-Fa-f]+)U?\s*,\s*(0x[0-9A-Fa-f]+)U?\s*,\s*"([0-9a-f]*)"\s*,\s*(TRUE|FALSE)\s*,\s*(TRUE|FALSE)\s*\)'
  foreach($m in [regex]::Matches($joined,$pattern)){
   # Normalise the hex fields so the manifest reads the way the source does. Keeping the raw
   # '0x41' text next to integer Device/Function made every consumer print '0x0x41'.
   $busHex='0x{0:X2}' -f [Convert]::ToInt32($m.Groups[3].Value.Substring(2),16)
   $subHex='0x{0:X8}' -f [Convert]::ToInt32($m.Groups[6].Value.Substring(2),16)
   $c8Hex ='0x{0:X8}' -f [Convert]::ToInt32($m.Groups[7].Value.Substring(2),16)
   $targetRows+=[ordered]@{Name=$m.Groups[1].Value;Segment=[int]$m.Groups[2].Value;
    Bus=$busHex;Device=[int]$m.Groups[4].Value;Function=[int]$m.Groups[5].Value;
    Subsystem=$subHex;ConfigC8=$c8Hex;
    PromSha256=$(if($m.Groups[8].Value){$m.Groups[8].Value}else{'<unpinned: probe only>'});
    UnlockAllowed=($m.Groups[9].Value -eq 'TRUE');
    DisplayMaySitOnTargetGop=($m.Groups[10].Value -eq 'TRUE')}
  }
  if($targetRows.Count -eq 0){throw 'targets_local.h defines no parsable GU_CARD rows'}
  $declared=([regex]::Matches($joined,'GU_CARD\(')).Count
  if($targetRows.Count -ne $declared){
   throw ('targets_local.h: parsed {0} of {1} GU_CARD rows' -f $targetRows.Count,$declared)
  }
 }
 $objects=@()
 foreach($source in $sources) {
  $object="$out/"+($source -replace '/','_')+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -Wno-unused-parameter -D__KERNEL__ -DGU_UEFI_PORT -DGU_TARGET_PCI_ID=0x220410deU @defines -I compat -I ../deps/edk2/MdePkg/Include -I ../deps/edk2/MdePkg/Include/X64 -c "$source.c" -o $object
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$object
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf "/map:$out/$name.map" "/out:$out/$name.EFI" @objects
 if($LASTEXITCODE -ne 0){throw 'EFI link failed'}
 & $Python verify_pe.py "$out/$name.EFI" "$out/$name.map" --output "$out/pe-verification.json"
 if($LASTEXITCODE -ne 0){throw 'PE verification failed'}
 [ordered]@{BuiltUtc=[DateTime]::UtcNow.ToString('o');TargetPci='220410de';Subsystem=$(if($MachineLocal){'14541b4c (machine_local)'}else{'145410de'});
  Mode=$(if($AutomaticBoot){'automatic-internal-exact-card-multi-unlock'}elseif($InternalBoot){'manual-internal-exact-card-multi-unlock'}elseif($ExperimentalUnlock){'experimental-exact-card-manual-unlock'}else{'diagnostic-preflight-only'});
  CanArm=$(if($AutomaticBoot){$false}else{[bool]$ExperimentalUnlock});Defines=$defines;ManualConfirmation=$(if($AutomaticBoot){'none; Esc within 3 seconds cancels the batch'}elseif($InternalBoot){'U once; Esc or 5-minute timeout cancels'}else{'U once; Esc or 30-second timeout cancels'});
  StockProfile=$(if($ExperimentalUnlock){$StockProfile}else{$null});ColdChipExpected='0xb72000a1';ColdSS0Expected=$(if($StockProfile -like 'entryLatchedSs1*'){'first fully validated cold entry; immutable'}elseif($ExperimentalUnlock){if($StockProfile -eq 'original03100062'){'0x03100062'}else{'0x03000062'}}else{'unknown'});ColdSS1Expected=$(if($StockProfile -like 'entryLatchedSs1*'){'first fully validated cold entry <= 0xf; immutable'}else{'0x6'});
  SS0Target='0x88888888';SS1Target=$(if($StockProfile -eq 'entryLatchedSs1Preserve'){'preserve entry; no SS1 writes'}elseif($StockProfile -eq 'entryLatchedSs1Full'){'0x8; one guarded write'}elseif($ExperimentalUnlock){'0x8'}else{'no writes'});
  OriginalBaselineCapture='G:/RTX3090-PREFLIGHT/RUN00/REPORT.TXT';
  StockProfileSource=$(if($StockProfile -like 'entryLatchedSs1*'){'Explicit immutable validated entry latch; no fixed stock selector assumption'}elseif($StockProfile -eq 'observed03000062'){'Explicit observed03000062 experiment selection; original baseline capture does not evidence this SS0'}elseif($ExperimentalUnlock){'OriginalBaselineCapture'}else{'preflight has no selected stock profile'});
  PromSha256=$promPin;
  Targets=$(if($MultiTarget){$targetRows}else{$null});
  TargetCount=$(if($MultiTarget){$targetRows.Count}else{$null});
  EligibleExpected=$(if($MultiTarget){($targetRows | Where-Object {$_.UnlockAllowed}).Count}else{$null});
  DisplayException=$(if($MultiTarget){($targetRows | Where-Object {$_.DisplayMaySitOnTargetGop} | ForEach-Object {$_.Name}) -join ','}else{$null});
  DeviceMemorySize='0x6000';HardwareTested=$false;
  EfiSha256=(Get-FileHash -LiteralPath "$out/$name.EFI" -Algorithm SHA256).Hash;
  Headers=@(Get-ChildItem -LiteralPath . -Recurse -File -Filter '*.h' | Where-Object {$_.FullName -notlike '*\build\*'} | Sort-Object FullName | ForEach-Object {[ordered]@{Path=$_.FullName.Substring($PSScriptRoot.Length+1);Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}});
  Sources=@($sources | ForEach-Object {[ordered]@{Path="$_.c";Sha256=(Get-FileHash -LiteralPath "$_.c" -Algorithm SHA256).Hash}})
  } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath "$out/build-manifest.json"
 "Built $name.EFI; ExperimentalUnlock=$([bool]$ExperimentalUnlock); hardware untested."
} finally {Pop-Location}
