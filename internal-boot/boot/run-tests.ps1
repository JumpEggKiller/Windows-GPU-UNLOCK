# Host tests for the internal-boot handoff wrapper. They run without a rig: the
# device-path policy uses GU_HOST_TEST placeholders, and the file/PCI/console layer
# is deliberately not emulated here (it is covered by the source audit and by the
# maintenance-window gate instead of by a mock that could drift from the firmware).
param([string]$Clang='clang')
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
 'ALL INTERNAL-BOOT HOST TESTS PASSED'
} finally {Pop-Location}
