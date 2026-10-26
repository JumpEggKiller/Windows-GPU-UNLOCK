# Builds one internal-boot handoff wrapper: the manual one (Windows-first recovery
# entry, one U authorizes the batch) or the automatic one (no key required).
# The child EFI that is paired with the wrapper is hashed here and baked into
# generated.h, so the wrapper can refuse any other image.
param(
 [string]$Clang='clang',
 [string]$LldLink='lld-link',
 [string]$Python='python',
 [Parameter(Mandatory=$true)][string]$Child,
 [Parameter(Mandatory=$true)][int]$ExpectedUnlocked,
 [switch]$Automatic
)
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
 $edk=Join-Path $repo 'deps\edk2\MdePkg\Include'
 if(!(Test-Path -LiteralPath $edk)){throw "Missing EDK2 headers: $edk"}
 if(!(Test-Path -LiteralPath $Child)){throw "Missing child EFI: $Child"}
 if($ExpectedUnlocked -lt 1){throw '-ExpectedUnlocked must be at least 1'}
 $childFull=(Resolve-Path -LiteralPath $Child).Path
 $bytes=(Get-Item -LiteralPath $childFull).Length
 $hash=(Get-FileHash -LiteralPath $childFull -Algorithm SHA256).Hash.ToLowerInvariant()
 # The generated header is derived from the child on every build. The wrapper refuses
 # to run an image whose length or hash differs, so neither value may ever be typed
 # by hand. Each mode keeps its own header so the two wrappers cannot cross-pair.
 $generatedName=if($Automatic){'generated-auto.h'}else{'generated-manual.h'}
 $generated=@"
#pragma once
#define GU_UNLOCK_SHA256 "$hash"
#define GU_UNLOCK_BYTES $($bytes)ULL
#define GU_EXPECTED_UNLOCKED $($ExpectedUnlocked)U
"@
 Set-Content -LiteralPath $generatedName -Value $generated -Encoding ASCII
 $out=if($Automatic){'build/automatic'}else{'build/manual'}
 $name=if($Automatic){'AUTO'}else{'HANDOFF'}
 New-Item -ItemType Directory -Path $out -Force|Out-Null
 $defines=@()
 if($Automatic){$defines+='-DGU_AUTOMATIC_BOOT'}
 $sources=@(
  @{Source='handoff.c';Object="$out/handoff.obj"},
  @{Source='flow.c';Object="$out/flow.obj"},
  @{Source='../../unlock/sha256.c';Object="$out/sha256.obj"},
  @{Source='../../efi_runtime.c';Object="$out/efi_runtime.obj"}
 )
 $objects=@()
 foreach($item in $sources) {
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -Wno-unused-parameter -I . -I $edk -I (Join-Path $edk 'X64') @defines -c $item.Source -o $item.Object
  if($LASTEXITCODE -ne 0){throw "Compile failed: $($item.Source)"}
  $objects+=$item.Object
 }
 # The wrapper is not started by firmware: the Windows boot manager starts it from a
 # BCD entry. bootmgr validates the image format first and returns 0xC000007B
 # (STATUS_INVALID_IMAGE_FORMAT) for a plain EFI application, which is how the first
 # Gate C attempt failed. memtest.efi, the one file on this machine that bootmgr does
 # start from a BCD entry, is IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION (16) at a real
 # preferred base with no ASLR/NX placement flags, so the wrapper is linked to that
 # shape: a fixed high base, no placement flags, then the subsystem value written by
 # boot-application.py because lld-link has no name for 16. Firmware ignores the
 # subsystem value, so the same image still loads from a USB firmware entry.
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf "/map:$out/$name.map" "/out:$out/$name.EFI" @objects
 if($LASTEXITCODE -ne 0){throw 'EFI link failed'}
 & $Python (Join-Path $PSScriptRoot 'boot-application.py') "$out/$name.EFI"
 if($LASTEXITCODE -ne 0){throw 'Promoting the image to a boot application failed'}
 & $Python (Join-Path $repo 'unlock\verify_pe.py') "$out/$name.EFI" "$out/$name.map" --output "$out/pe-verification.json"
 if($LASTEXITCODE -ne 0){throw 'PE verification failed'}
 [ordered]@{
  BuiltUtc=[DateTime]::UtcNow.ToString('o')
  Mode=$(if($Automatic){'guarded-automatic-internal-unlock-then-windows'}else{'guarded-internal-handoff-then-windows'})
  Automatic=[bool]$Automatic
  HardwareTested=$false
  ChildPath=$childFull
  ChildSha256=$hash
  ChildBytes=$bytes
  ExpectedUnlocked=$ExpectedUnlocked
  EfiSha256=(Get-FileHash -LiteralPath "$out/$name.EFI" -Algorithm SHA256).Hash.ToLowerInvariant()
  EfiBytes=(Get-Item -LiteralPath "$out/$name.EFI").Length
  GeneratedHeader=$generatedName
  GeneratedHeaderSha256=(Get-FileHash -LiteralPath $generatedName -Algorithm SHA256).Hash.ToLowerInvariant()
  Sources=@(
   @{Path='handoff.c';Sha256=(Get-FileHash -LiteralPath 'handoff.c' -Algorithm SHA256).Hash.ToLowerInvariant()}
   @{Path='flow.c';Sha256=(Get-FileHash -LiteralPath 'flow.c' -Algorithm SHA256).Hash.ToLowerInvariant()}
   @{Path='flow.h';Sha256=(Get-FileHash -LiteralPath 'flow.h' -Algorithm SHA256).Hash.ToLowerInvariant()}
   @{Path='media.h';Sha256=(Get-FileHash -LiteralPath 'media.h' -Algorithm SHA256).Hash.ToLowerInvariant()}
   @{Path='record.h';Sha256=(Get-FileHash -LiteralPath 'record.h' -Algorithm SHA256).Hash.ToLowerInvariant()}
   @{Path='../../unlock/sha256.c';Sha256=(Get-FileHash -LiteralPath '../../unlock/sha256.c' -Algorithm SHA256).Hash.ToLowerInvariant()}
   @{Path='../../efi_runtime.c';Sha256=(Get-FileHash -LiteralPath '../../efi_runtime.c' -Algorithm SHA256).Hash.ToLowerInvariant()}
  )
 } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/manifest.json" -Encoding UTF8
 "Built $name.EFI ($(if($Automatic){'automatic'}else{'manual'}) handoff); child $hash; hardware untested."
} finally {Pop-Location}
