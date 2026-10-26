# Host tests for the internal-boot handoff wrapper. They run without a rig: the
# device-path policy uses GU_HOST_TEST placeholders, and the file/PCI/console layer
# is deliberately not emulated here (it is covered by the source audit and by the
# maintenance-window gate instead of by a mock that could drift from the firmware).
param([string]$Clang='clang',[string]$Python='python')
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
 $edk=Join-Path $repo 'deps\edk2\MdePkg\Include'
 if(!(Test-Path -LiteralPath $edk)){throw "Missing EDK2 headers: $edk"}
 New-Item -ItemType Directory -Path 'build/test' -Force|Out-Null
 function Build-And-Run([string]$Name,[string[]]$Extra) {
  & $Clang -std=c11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function -D_CRT_SECURE_NO_WARNINGS -DGU_HOST_TEST -I . -I $edk -I (Join-Path $edk 'X64') @Extra "$Name.c" -o "build/test/$Name.exe"
  if($LASTEXITCODE -ne 0){throw "Compile failed: $Name"}
  & "build/test/$Name.exe"
  if($LASTEXITCODE -ne 0){throw "$Name FAILED"}
  "OK $Name"
 }
 Build-And-Run 'test_flow' @('flow.c')
 Build-And-Run 'test_record' @()
 Build-And-Run 'test_paths' @()
 # The Windows boot manager starts the wrapper from a BCD entry and refuses a plain
 # EFI application (0xC000007B), so the built wrappers must carry the boot
 # application shape. Prove the rule both ways: a wrapper passes it, the subsystem 10
 # child does not. This runs on the images that are actually staged, not on a fixture.
 $verify=Join-Path $repo 'unlock\verify_pe.py'
 function Assert-Pe([string]$Efi,[string]$Map,[switch]$BootApplication,[switch]$MustFail) {
  $arguments=@($verify,$Efi,$Map,'--output',(Join-Path 'build/test' ((Split-Path -Leaf $Efi)+'.json')))
  if($BootApplication){$arguments=@($verify,$Efi,$Map,'--boot-application','--output',(Join-Path 'build/test' ((Split-Path -Leaf $Efi)+'.json')))}
  # A verifier rejection is a non-zero exit with a message on stderr; with the script's
  # Stop preference that stderr would end the whole run, and the rejection is exactly
  # what one of these checks expects.
  $previous=$ErrorActionPreference
  $ErrorActionPreference='Continue'
  $text=& $Python @arguments 2>&1 | Out-String
  $code=$LASTEXITCODE
  $ErrorActionPreference=$previous
  $ok=($code -eq 0)
  if($MustFail -and $ok){throw "expected the verifier to refuse $Efi"}
  if(!$MustFail -and !$ok){throw "the verifier refused $Efi : $text"}
  "OK pe $([IO.Path]::GetFileName($Efi))"
 }
 if(Test-Path -LiteralPath 'build/manual/HANDOFF.EFI'){
  # The wrapper is started by firmware from a Boot#### load option, so it must be a plain
  # EFI application: the boot manager refuses our images outright (0xC0000428, untrusted
  # signature), so the subsystem 16 profile must now be the one that fails.
  Assert-Pe 'build/manual/HANDOFF.EFI' 'build/manual/HANDOFF.map'
  Assert-Pe 'build/manual/HANDOFF.EFI' 'build/manual/HANDOFF.map' -BootApplication -MustFail
 }
 if(Test-Path -LiteralPath 'build/automatic/AUTO.EFI'){
  Assert-Pe 'build/automatic/AUTO.EFI' 'build/automatic/AUTO.map'
 }
 $child='..\..\unlock\build\multi\experimental\entryLatchedSs1Full\internal\RTX3090-MULTI-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI'
 if(Test-Path -LiteralPath $child){
  $childMap=Join-Path (Split-Path -Parent $child) 'RTX3090-MULTI-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.map'
  Assert-Pe $child $childMap -BootApplication -MustFail
  Assert-Pe $child $childMap
 }
 'ALL INTERNAL-BOOT HOST TESTS PASSED'
} finally {Pop-Location}
