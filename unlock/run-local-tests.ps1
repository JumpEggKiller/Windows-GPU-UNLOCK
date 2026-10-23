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
