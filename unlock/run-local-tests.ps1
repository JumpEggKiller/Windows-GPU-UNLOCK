$ErrorActionPreference='Stop'
$llvm='D:\AI\dsh-local\gpu-unlock-audit\tools\clang+llvm-23.1.4-x86_64-pc-windows-msvc\bin'
$Clang="$llvm\clang.exe"
Set-Location D:\AI\dsh-local\gpu-unlock-audit\Windows-GPU-UNLOCK\unlock
$out='build/tests-local'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$flags=@('-std=c11','-O1','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-unused-function','-D_CRT_SECURE_NO_WARNINGS','-Icompat','-I../deps/edk2/MdePkg/Include','-I../deps/edk2/MdePkg/Include/X64')
$core=@('port.c','compat.c','vendor/unlock_610.c','vendor/prep_610.c','vendor/layout_610.c','vendor/vbios_610.c','vendor/gfw_eval.c')
$defs=@('-D__KERNEL__','-DGU_UEFI_PORT','-DGU_TARGET_PCI_ID=0x220410deU')
& $Clang @flags -fno-builtin -Dmemcpy=GuTestMemcpy -Dmemset=GuTestMemset -Dmemchr=GuTestMemchr -Dmemcmp=GuTestMemcmp -Dstrcmp=GuTestStrcmp -Dstrlen=GuTestStrlen -c runtime.c -o "$out/runtime-host.obj"
if($LASTEXITCODE -ne 0){throw 'Runtime host compile failed'}
function RunTest([string]$Name,[string[]]$Defines,[string[]]$Sources,[string[]]$Args) {
  $exe="$out/$Name-tests.exe"
  & $Clang @flags @Defines @Sources -o $exe
  if($LASTEXITCODE -ne 0){throw "Compile failed: $Name"}
  & "./$exe" @Args
  if($LASTEXITCODE -ne 0){throw "Test failed: $Name (exit $LASTEXITCODE)"}
  Write-Output "OK $Name"
}
& python tests/test_stock_selection.py $Clang
if($LASTEXITCODE -ne 0){throw 'Stock selection negative tests failed'}
Write-Output 'OK stock-selection'
RunTest 'port' @('-DGU_HOST_WRITE_TEST') @('tests/test_port.c','port.c') @()
RunTest 'write-lock' @() @('tests/test_preflight_lock.c','port.c') @()
RunTest 'master-attributes' ($defs+@('-DGU_HOST_WRITE_TEST')) (@('tests/test_master_attributes.c')+$core) @()
RunTest 'runtime' @('-fno-builtin') (@('tests/test_runtime.c','format.c',"$out/runtime-host.obj")) @()
foreach($profile in @('original03100062','observed03000062','entryLatchedSs1Preserve','entryLatchedSs1Full')) {
  $pd=switch($profile){'original03100062'{'-DGU_STOCK_PROFILE_ORIGINAL_03100062'} 'observed03000062'{'-DGU_STOCK_PROFILE_OBSERVED_03000062'} 'entryLatchedSs1Preserve'{'-DGU_ENTRY_LATCHED_SS1_PRESERVE'} 'entryLatchedSs1Full'{'-DGU_ENTRY_LATCHED_SS1_FULL'}}
  RunTest "profile-lock-$profile" @('-DGU_EXPERIMENTAL_3090',$pd) @('tests/test_profile_lock.c','port.c') @()
}
RunTest 'machine-local' @('-DGU_MACHINE_LOCAL') @('tests/test_machine_local.c','checks.c') @()
RunTest 'multi-target' @('-DGU_MULTI_TARGET') @('tests/test_multi_target.c','checks.c','targets.c') @()
RunTest 'multi-target-arming' @('-DGU_MULTI_TARGET','-DGU_EXPERIMENTAL_3090','-DGU_ENTRY_LATCHED_SS1_FULL') @('tests/test_multi_target.c','checks.c','targets.c') @()

# Guard audit: every place that must resolve identity per card has to be inside the
# multi-target configuration. RUN04 lost a whole probe run because one such guard
# (FindTarget's BDF filter) was still machine-local only, so the build matched all four
# cards and refused every one. Preprocess the real source and assert the expansions are
# present instead of trusting that all #ifdefs were widened by hand.
$ppArgs=@('-std=c11','-E','-Icompat','-I../deps/edk2/MdePkg/Include','-I../deps/edk2/MdePkg/Include/X64','-D__KERNEL__','-DGU_UEFI_PORT','-DGU_TARGET_PCI_ID=0x220410deU','-DGU_MULTI_TARGET','-DGU_EXPERIMENTAL_3090','-DGU_ENTRY_LATCHED_SS1_FULL')
$pp = (& $Clang @ppArgs app.c checks.c port.c) -join "`n"
if($LASTEXITCODE -ne 0){throw 'Preprocess failed for the multi-target guard audit'}
$guardNeedles=@(
  @('if\s*\(\s*s\s*!=\s*\(?\s*GuTargetCurrent\(\)->Segment','FindTarget BDF filter (phase A must select exactly one card)'),
  @('if\s*\(\s*s\s*!=\s*\(?\s*GuTargetCurrent\(\)->Segment\)?\s*\|\|\s*b\s*!=\s*\(?\s*GuTargetCurrent\(\)->Bus','FindTarget compares bus as well as segment'),
  @('GuTargetCurrent\(\)->Subsystem','per-card subsystem in checks.c / GuTargetConfig / GuSavePci'),
  @('GuTargetCurrent\(\)->PromSha256','per-card PROM pin in PromCheck'),
  @('GuTargetCurrent\(\)->ConfigC8','per-card config[0xc8] pin in ConfigCheck'),
  @('GOP\[%u\] sits on target BDF','DisplayCheck per-card GOP refusal'),
  @('PHASE A PREFLIGHT','multi-target phase A present')
)
foreach($needle in $guardNeedles){
  if($pp -notmatch $needle[0]){throw "Guard audit failed: $($needle[1]) is not compiled into the multi-target build"}
}

# The profile header must actually be reached. RUN05 read every card's config space and then
# refused all four at the BAR0 pin, because targets.h never included targets_local.h: the
# rig-level values (GU_BAR0_BASE 0ULL, GU_DISPLAY_LOG_ONLY 1) were defined only in targets.c
# and every other translation unit silently kept port.h's defaults.
$macroArgs=@('-std=c11','-E','-dM','-Icompat','-I../deps/edk2/MdePkg/Include','-I../deps/edk2/MdePkg/Include/X64','-D__KERNEL__','-DGU_UEFI_PORT','-DGU_TARGET_PCI_ID=0x220410deU','-DGU_MULTI_TARGET')
$dm = (& $Clang @macroArgs app.c) -join "`n"
if($LASTEXITCODE -ne 0){throw 'Preprocess (-dM) failed for the multi-target profile audit'}
$macroNeedles=@(
  @('(?m)^#define GU_BAR0_BASE 0ULL\r?$','GU_BAR0_BASE must be the rig value 0ULL (firmware-assigned BAR0)'),
  @('(?m)^#define GU_DISPLAY_LOG_ONLY 1\r?$','GU_DISPLAY_LOG_ONLY must be 1 (ASPEED console, no AMD iGPU)'),
  @('(?m)^#define GU_PREFLIGHT_ONLY 1\r?$','the read-only build must keep GU_PREFLIGHT_ONLY 1'),
  @('(?m)^#define GU_MULTI_TARGET 1\r?$','GU_MULTI_TARGET must be defined')
)
foreach($needle in $macroNeedles){
  if($dm -notmatch $needle[0]){throw "Profile audit failed: $($needle[1])"}
}

# GuFormatV implements width for integers only and rejects a '-' flag outright. A rejected
# format used to set a log fault, so one bad string silenced the rest of the audit log
# (RUN04 and RUN05 both lost their status table that way). Fail the build instead.
# Comments are blanked first, with newlines preserved so line numbers stay meaningful: the
# sources legitimately *describe* this defect in prose.
$fmtProblems = @()
$fmtFiles = @(Get-ChildItem -Path . -Filter *.c) + @(Get-ChildItem -Path . -Filter *.h)
if(Test-Path 'vendor'){
  $fmtFiles += @(Get-ChildItem -Path 'vendor' -Filter *.c) + @(Get-ChildItem -Path 'vendor' -Filter *.h)
}
foreach($file in $fmtFiles){
  $raw = Get-Content -Raw -LiteralPath $file.FullName
  $blank = [regex]::Replace($raw, '/\*.*?\*/', { param($m) ("`n" * (($m.Value.ToCharArray() | Where-Object { $_ -eq "`n" }).Count)) }, 'Singleline')
  $lines = $blank -split "`n"
  for($i=0; $i -lt $lines.Count; $i++){
    $line = $lines[$i]
    $cut = $line.IndexOf('//')
    if($cut -ge 0){ $line = $line.Substring(0,$cut) }
    if($line -match '%-|%[0-9]+s'){ $fmtProblems += "  $($file.Name):$($i+1): $($line.Trim())" }
  }
}
if($fmtProblems.Count -gt 0){
  throw ("Format audit failed: GuFormatV cannot render these (no width on %s, no '-' flag):`n" + ($fmtProblems -join "`n"))
}
Write-Output 'OK multi-guard-audit'
Write-Output 'OK multi-profile-audit'
Write-Output 'OK format-audit'
& python tests/test_pe.py 'build/RTX3090-PREFLIGHT.EFI' 'build/RTX3090-PREFLIGHT.map'
if($LASTEXITCODE -ne 0){throw 'PE tests failed (default)'}
Write-Output 'OK pe-default'
& python tests/test_pe.py 'build/local/RTX3090-PREFLIGHT-LOCAL.EFI' 'build/local/RTX3090-PREFLIGHT-LOCAL.map'
if($LASTEXITCODE -ne 0){throw 'PE tests failed (machine-local)'}
Write-Output 'OK pe-machine-local'
& python tests/test_pe.py 'build/multi/preflight/RTX3090-MULTI-PREFLIGHT.EFI' 'build/multi/preflight/RTX3090-MULTI-PREFLIGHT.map'
if($LASTEXITCODE -ne 0){throw 'PE tests failed (multi-target)'}
Write-Output 'OK pe-multi'
Write-Output 'ALL RUNNABLE GROUPS PASSED'
