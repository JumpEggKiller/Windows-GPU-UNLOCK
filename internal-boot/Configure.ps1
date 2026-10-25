# Records the identity of the two ESPs this experiment depends on and writes
# boot/platform-config.h from them. Read-only against the disks: nothing here
# writes a partition table, a filesystem or a boot entry.
#
#   -List          inventory the candidates and exit
#   -Development   write the host-test placeholder GUIDs (build-pipeline only;
#                  Install.ps1 refuses an artifact built this way)
#   (default)      -UnlockDriveLetter <letter> -WindowsEspGuid <guid>
param(
 [string]$UnlockDriveLetter,
 [string]$WindowsEspGuid,
 [switch]$List,
 [switch]$Development
)
$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 $esp='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
 $headerPath=Join-Path $PSScriptRoot 'boot\platform-config.h'
 $configPath=Join-Path $PSScriptRoot 'local-config.json'

 # The hard-drive device path carries the partition GUID as raw bytes, so the C
 # initializer must keep EFI_GUID's field order exactly as the GPT entry stores it.
 function GuidInitializer([string]$Text) {
  if($Text -notmatch '^\{?([0-9a-fA-F]{8})-([0-9a-fA-F]{4})-([0-9a-fA-F]{4})-([0-9a-fA-F]{4})-([0-9a-fA-F]{12})\}?$') {
   throw "Not a GUID: $Text"
  }
  $tail=@()
  for($i=0;$i -lt 4;$i+=2){$tail+=[Convert]::ToByte($Matches[4].Substring($i,2),16)}
  for($i=0;$i -lt 12;$i+=2){$tail+=[Convert]::ToByte($Matches[5].Substring($i,2),16)}
  '{0x{0:x8},0x{1:x4},0x{2:x4},{{{3}}}' -f ([Convert]::ToUInt32($Matches[1],16)),([Convert]::ToUInt16($Matches[2],16)),([Convert]::ToUInt16($Matches[3],16)),(($tail | ForEach-Object {'0x{0:x2}' -f $_}) -join ',')
 }
 function ZeroGuid([string]$Text) { $Text -match '^\{?0{8}-0{4}-0{4}-0{4}-0{12}\}?$' }

 # Must match the value pinned in this rig's measured notes. A BIOS update
 # legitimately invalidates it and requires a deliberate reconfigure.
 function BoardReport {
  $b=Get-CimInstance Win32_BaseBoard; $f=Get-CimInstance Win32_BIOS
  [pscustomobject]@{Product=$b.Product;BoardVersion=$b.Version;Bios=$f.SMBIOSBIOSVersion;BiosVersion=$f.Version}
 }
 $profile=[pscustomobject]@{Product='MZ32-AR0-00';Bios='M31'}

 $raw=@(Get-Partition | Sort-Object DiskNumber,PartitionNumber)
 $partitions=@(foreach($p in $raw) {
   $volume=$null
   try {$volume=$p | Get-Volume -ErrorAction Stop} catch {$volume=$null}
   $usable=($p.GptType -eq $esp) -and (-not $p.IsSystem) -and ($p.Size -ge 1GB) -and
     $volume -and ($volume.FileSystem -eq 'FAT32') -and (-not (ZeroGuid $p.Guid)) -and $p.DriveLetter
   [pscustomobject]@{
    Disk=$p.DiskNumber;Partition=$p.PartitionNumber;Letter=[string]$p.DriveLetter
    SizeGB=[math]::Round($p.Size/1GB,2);GptType=$p.GptType;Guid=[string]$p.Guid
    IsSystem=$p.IsSystem;IsBoot=$p.IsBoot;Offset=$p.Offset
    FileSystem=$(if($volume){$volume.FileSystem}else{$null})
    FreeGB=$(if($volume){[math]::Round($volume.SizeRemaining/1GB,2)}else{$null})
    UsableAsUnlockEsp=[bool]$usable
   }
 })
 $windowsEsp=@($partitions | Where-Object {$_.GptType -eq $esp -and $_.IsSystem})
 $candidates=@($partitions | Where-Object {$_.UsableAsUnlockEsp})

 if($List) {
  'Disks:'
  Get-Disk | ForEach-Object {
   '{0} {1} {2} {3}GB ({4}GB free)' -f $_.Number,$_.FriendlyName,$_.PartitionStyle,[math]::Round($_.Size/1GB,1),[math]::Round($_.SizeRemaining/1GB,2)
  }
  ''
  'ESP-typed partitions:'
  $partitions | Where-Object {$_.GptType -eq $esp} | Format-Table Disk,Partition,Letter,SizeGB,Guid,IsSystem,FileSystem,FreeGB,UsableAsUnlockEsp -AutoSize | Out-String -Width 200
  ''
  'Windows ESP (IsSystem + ESP type) - must be exactly one:'
  $windowsEsp | Format-Table Disk,Partition,Guid,SizeGB,FileSystem -AutoSize | Out-String -Width 200
  ''
  'Usable as the dedicated unlock ESP: ESP type, not IsSystem, >= 1 GiB, FAT32, non-zero GUID, and a drive letter to stage files through.'
  if($candidates){$candidates | Format-Table Disk,Partition,Letter,SizeGB,FreeGB,Guid -AutoSize | Out-String -Width 200}
  else {'NONE. A FAT32 partition of at least 1 GiB has to be created in the maintenance window.'}
  if($windowsEsp.Count -ne 1){'WARNING: {0} partitions claim to be the Windows ESP' -f $windowsEsp.Count}
  return
 }

 if($Development) {
  # Identical to the GU_HOST_TEST placeholders in boot/media.h on purpose: a
  # development build can only ever address a partition that does not exist.
  $internal='{0x47553001,0x494e,0x5445,{0x8a,0x11,0x00,0x00,0x00,0x00,0x00,0x01}}'
  $windows='{0x47553002,0x494e,0x5445,{0x8a,0x11,0x00,0x00,0x00,0x00,0x00,0x02}}'
  $config=[ordered]@{
   Placeholder=$true;UnlockDriveLetter='';UnlockPartitionGuid='{47553001-494e-5445-8a11-000000000001}'
   WindowsPartitionGuid='{47553002-494e-5445-8a11-000000000002}';UnlockDiskNumber=-1
   UnlockDiskUniqueId='placeholder';UnlockOffset=0;UnlockSize=0
   Board=BoardReport;Profile=$profile;ConfiguredUtc=[DateTime]::UtcNow.ToString('o')
  }
 } else {
  if(!$UnlockDriveLetter -or $UnlockDriveLetter -notmatch '^[A-Za-z]$'){throw '-UnlockDriveLetter must be a single drive letter (use -List to choose one)'}
  if(!$WindowsEspGuid){throw '-WindowsEspGuid is required'}
  if($windowsEsp.Count -ne 1){throw ('Expected exactly one Windows ESP, found {0}; run -List' -f $windowsEsp.Count)}
  if(ZeroGuid $windowsEsp[0].Guid){throw 'The Windows ESP has an all-zero partition GUID and cannot be addressed by device path'}
  $unlock=@($candidates | Where-Object {$_.Letter.ToUpper() -eq $UnlockDriveLetter.ToUpper()})
  if($unlock.Count -ne 1) {
   $all=@($partitions | Where-Object {$_.Letter.ToUpper() -eq $UnlockDriveLetter.ToUpper()})
   if(-not $all){throw ('Drive {0}: is not a partition on this machine; run -List' -f $UnlockDriveLetter)}
   $p=$all[0]
   throw ('Drive {0}: is not usable as the dedicated ESP: GptType {1}, IsSystem {2}, {3} GiB, filesystem {4}, GUID {5}. It needs ESP type, IsSystem False, at least 1 GiB, FAT32 and a non-zero GUID.' -f
     $UnlockDriveLetter,$p.GptType,$p.IsSystem,$p.SizeGB,$p.FileSystem,$p.Guid)
  }
  $unlock=$unlock[0]
  if($unlock.Guid -ne [string]$WindowsEspGuid) {
   throw ('-WindowsEspGuid {0} does not match the IsSystem ESP on disk ({1})' -f $WindowsEspGuid,$windowsEsp[0].Guid)
  }
  $board=BoardReport
  if($board.Product -ne $profile.Product -or $board.Bios -ne $profile.Bios) {
   throw ('Board {0} BIOS {1} is not the measured profile {2} BIOS {3}; this build is pinned to one machine' -f
     $board.Product,$board.Bios,$profile.Product,$profile.Bios)
  }
  $disk=Get-Disk -Number $unlock.Disk
  $config=[ordered]@{
   Placeholder=$false;UnlockDriveLetter=$unlock.Letter.ToUpper()
   UnlockPartitionGuid=$unlock.Guid;WindowsPartitionGuid=$windowsEsp[0].Guid
   UnlockDiskNumber=$unlock.Disk;UnlockDiskUniqueId=[string]$disk.UniqueId
   UnlockOffset=$unlock.Offset;UnlockSize=[int64](($unlock.SizeGB)*1GB)
   Board=$board;Profile=$profile;ConfiguredUtc=[DateTime]::UtcNow.ToString('o')
  }
  $internal=GuidInitializer $unlock.Guid
  $windows=GuidInitializer $windowsEsp[0].Guid
 }
 $config.InternalInitializer=$internal
 $config.WindowsInitializer=$windows
 $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
 $header=@"
/* Generated by Configure.ps1. Do not edit: rerun the script instead. */
#pragma once
#define GU_INTERNAL_PARTITION_INITIALIZER $internal
#define GU_WINDOWS_PARTITION_INITIALIZER $windows
#define GU_CONFIG_PLACEHOLDER $([int]$config.Placeholder)
"@
 Set-Content -LiteralPath $headerPath -Value $header -Encoding ASCII
 $config.GeneratedHeaderSha256=(Get-FileHash -LiteralPath $headerPath -Algorithm SHA256).Hash.ToLowerInvariant()
 $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
 if($config.Placeholder){'Configured with PLACEHOLDER GUIDs: build pipeline only, never installable.'}
 else {"Configured unlock ESP {0}: ({1}) and Windows ESP {2}." -f $config.UnlockDriveLetter,$config.UnlockPartitionGuid,$config.WindowsPartitionGuid}
} finally {Pop-Location}
