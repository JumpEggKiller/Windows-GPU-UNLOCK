# Installs the internal-boot experiment onto a SEPARATE ESP and, only when asked,
# registers and promotes boot entries. It never touches the Windows ESP, never
# deletes a partition, never changes encryption, and never reboots.
#
#   .\Install.ps1 -Check                        readiness report; writes nothing
#   .\Install.ps1 -Plan                         the exact commands each action would run; writes nothing
#   .\Install.ps1 -LocalStage <dir>             stage the exact file tree into a folder
#   .\Install.ps1 -Assets <dir>                 stage onto the dedicated ESP only
#   .\Install.ps1 -Assets <dir> -RegisterManual  add the Manual entry, Windows stays first
#   .\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
#                                               make the Automatic entry boot first
#   .\Install.ps1 -RestoreWindowsFirst          put {bootmgr} back first; deletes nothing
param(
  [string]$Assets,
  [switch]$RegisterManual,
  [switch]$EnableAutomaticBoot,
  [switch]$ConfirmedManualSuccess,
  [switch]$RestoreWindowsFirst,
  [switch]$Check,
  [switch]$Plan,
  [string]$LocalStage
)
$ErrorActionPreference='Stop'
$espType='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$hiberKey='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
# One constant, so the printed plan and the command that runs cannot drift apart.
$automaticTimeout=5
$root=$PSScriptRoot
$repo=Split-Path -Parent $root
$stateFile=Join-Path $root 'install\state.json'
$configFile=Join-Path $root 'local-config.json'
. (Join-Path $root 'install\automatic-policy.ps1')
. (Join-Path $root 'install\staged-set.ps1')

function Fail([string]$Message){throw $Message}

function Invoke-Bcd {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $output=& bcdedit @Arguments 2>&1
  $code=$LASTEXITCODE
  $text=($output|Out-String)
  if($code -ne 0){throw ("bcdedit {0} failed (exit {1}): {2}" -f ($Arguments -join ' '),$code,$text.Trim())}
  return $text
}

# Get-BootOrder and Set-BootOrder live in install/automatic-policy.ps1, which
# is dot-sourced above, so the order rules are shared with their host tests.

function Test-IsAdmin {
  return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Hiberboot {
  $key=Get-ItemProperty -LiteralPath $hiberKey -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue
  if($null -eq $key){return $null}
  return [int]$key.HiberbootEnabled
}

function Set-Hiberboot {
  param([Parameter(Mandatory)][int]$Value)
  [void](New-ItemProperty -LiteralPath $hiberKey -Name 'HiberbootEnabled' -Value $Value -PropertyType DWord -Force)
  if((Get-Hiberboot) -ne $Value){throw ("Hiberboot restoration failed: asked for {0}, read back {1}" -f $Value,(Get-Hiberboot))}
}

# --- partitions and volumes -------------------------------------------------

function Get-EspPartitions {
  return @(Get-Partition|Where-Object {
    $_.GptType -and ([string]$_.GptType).ToLowerInvariant() -eq $espType
  })
}

# MSFT_Partition.Guid already carries its braces; normalise instead of wrapping again.
function Format-PartitionGuid([string]$Text) {
  $bare=([string]$Text).Trim().Trim('{','}')
  return ('{' + $bare.ToLowerInvariant() + '}')
}

function Get-VolumeOf($Partition) {
  $volume=$Partition|Get-Volume -ErrorAction SilentlyContinue
  if($null -eq $volume){throw ("Partition {0} on disk {1} has no volume" -f $Partition.PartitionNumber,$Partition.DiskNumber)}
  return $volume
}

function Resolve-ConfiguredPartitions {
  if(!(Test-Path -LiteralPath $configFile)){Fail 'local-config.json is missing: run Configure.ps1 first'}
  $config=Get-Content -Raw -LiteralPath $configFile|ConvertFrom-Json
  if($config.Placeholder){Fail 'These GUIDs are placeholder values; run Configure.ps1 against the real ESP first'}

  $esps=Get-EspPartitions
  $windows=@($esps|Where-Object {$_.IsSystem})
  if($windows.Count -ne 1){Fail ("Expected exactly one system ESP, found {0}" -f $windows.Count)}
  $windows=$windows[0]
  $windowsVolume=Get-VolumeOf $windows
  # A dedicated ESP normally has no drive letter at all; only a letter that hijacks the
  # system drive is worth a warning.
  if($windowsVolume.DriveLetter -and ((([string]$windowsVolume.DriveLetter)+':') -ne $env:SystemDrive)){
    Write-Warning ("The system ESP is mounted as {0}: the Windows boot files live there" -f $windowsVolume.DriveLetter)
  }
  $windowsGuid=Format-PartitionGuid $windows.Guid
  if($windowsGuid -ne ([string]$config.WindowsPartitionGuid).ToLowerInvariant()){
    Fail ("The configured Windows ESP {0} is not the system ESP {1}" -f $config.WindowsPartitionGuid,$windowsGuid)
  }

  $wanted=[uint64]$config.UnlockOffset
  $unlock=@(Get-Partition -DiskNumber ([int]$config.UnlockDiskNumber)|Where-Object {
    ([uint64]$_.Offset -eq $wanted) -and ([uint64]$_.Size -eq [uint64]$config.UnlockSize)
  })
  if($unlock.Count -ne 1){Fail ("The configured unlock ESP is no longer at offset {0} on disk {1}" -f $config.UnlockOffset,$config.UnlockDiskNumber)}
  $unlock=$unlock[0]
  $unlockGuid=Format-PartitionGuid $unlock.Guid
  if($unlockGuid -ne ([string]$config.UnlockPartitionGuid).ToLowerInvariant()){
    Fail ("The partition at the configured offset has GUID {0}, not {1}: the disk changed" -f $unlockGuid,$config.UnlockPartitionGuid)
  }
  if([string]$unlock.GptType -and (([string]$unlock.GptType).ToLowerInvariant() -ne $espType)){Fail 'The unlock partition is not an EFI system partition'}
  if($unlock.IsSystem){Fail 'The unlock partition is the system partition; an independent ESP is required'}
  if($unlockGuid -eq $windowsGuid){Fail 'The unlock partition and the Windows ESP are the same partition'}
  $unlockVolume=Get-VolumeOf $unlock
  if(([string]$unlockVolume.FileSystem) -ne 'FAT32'){Fail ("The unlock ESP is {0}, not FAT32" -f $unlockVolume.FileSystem)}
  $letter=[string]$config.UnlockDriveLetter
  if($letter.Length -ne 1){Fail 'local-config.json has no usable unlock drive letter'}
  if(([string]$unlockVolume.DriveLetter).ToUpperInvariant() -ne $letter.ToUpperInvariant()){
    Fail ("The unlock ESP is mounted as '{0}', but the build is pinned to '{1}'. Assign {1} and rebuild: a boot entry must name the partition the image was built for" -f $unlockVolume.DriveLetter,$letter)
  }
  if([uint64]$unlockVolume.SizeRemaining -lt [uint64]$StagedBytes){Fail 'The unlock ESP does not have room for the staged files'}
  return [pscustomobject]@{
    Config=$config; Windows=$windows; WindowsVolume=$windowsVolume; WindowsGuid=$windowsGuid
    Unlock=$unlock; UnlockVolume=$unlockVolume; UnlockGuid=$unlockGuid; Letter=$letter.ToUpperInvariant()
  }
}

function Assert-PlatformSafe {
  $secure=$false
  try{$secure=[bool](Confirm-SecureBootUEFI)}catch{$secure=$false}
  if($secure){Fail 'Secure Boot is on: this unsigned EFI application cannot run and must not be installed'}
  try {
    $bl=Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if($bl.VolumeStatus -ne 'FullyDecrypted' -or $bl.ProtectionStatus -ne 'Off'){
      Fail ("This installer requires {0} fully decrypted with protection off; it never changes encryption. Status {1}/{2}" -f $env:SystemDrive,$bl.VolumeStatus,$bl.ProtectionStatus)
    }
  } catch [System.Management.Automation.CommandNotFoundException] {
    Write-Warning 'BitLocker cmdlets are unavailable; verify manually that the system volume is unencrypted'
  }
}

# --- artifacts --------------------------------------------------------------

function Get-Artifacts {
  $childDir=Join-Path $repo 'unlock\build\multi\experimental\entryLatchedSs1Full\internal'
  return @(
    [pscustomobject]@{Role='unlock-child'
      Source=(Join-Path $childDir 'RTX3090-MULTI-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL.EFI')
      Manifest=(Join-Path $childDir 'build-manifest.json')
      Relative='EFI\WindowsGPUUnlock\UNLOCK.EFI'}
    [pscustomobject]@{Role='unlock-child-auto'
      Source=(Join-Path $childDir 'automatic\RTX3090-MULTI-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO.EFI')
      Manifest=(Join-Path $childDir 'automatic\build-manifest.json')
      Relative='EFI\WindowsGPUUnlock\UNLOCK-AUTO.EFI'}
    [pscustomobject]@{Role='manual-handoff'
      Source=(Join-Path $root 'boot\build\manual\HANDOFF.EFI')
      Manifest=(Join-Path $root 'boot\build\manual\manifest.json')
      Relative='EFI\WindowsGPUUnlock\MANUAL.EFI'}
    [pscustomobject]@{Role='automatic-handoff'
      Source=(Join-Path $root 'boot\build\automatic\AUTO.EFI')
      Manifest=(Join-Path $root 'boot\build\automatic\manifest.json')
      Relative='EFI\WindowsGPUUnlock\AUTO.EFI'}
  )
}

function Assert-Artifacts {
  $checked=@()
  foreach($artifact in (Get-Artifacts)) {
    if(!(Test-Path -LiteralPath $artifact.Source)){Fail ("Missing build output: {0}" -f $artifact.Source)}
    if(!(Test-Path -LiteralPath $artifact.Manifest)){Fail ("Missing manifest: {0}" -f $artifact.Manifest)}
    $manifest=Get-Content -Raw -LiteralPath $artifact.Manifest|ConvertFrom-Json
    $actual=Get-Sha256 $artifact.Source
    if($actual -ne ([string]$manifest.EfiSha256).ToLowerInvariant()){
      Fail ("{0} does not match its manifest: file {1}, manifest {2}. Rebuild; a stale image must not be installed" -f $artifact.Role,$actual,$manifest.EfiSha256)
    }
    $checked+=[pscustomobject]@{Role=$artifact.Role;Source=$artifact.Source;Relative=$artifact.Relative
      Sha256=$actual;Bytes=(Get-Item -LiteralPath $artifact.Source).Length;Manifest=$manifest}
  }
  return $checked
}

function Get-AssetPlan {
  param([string]$Directory)
  if([string]::IsNullOrWhiteSpace($Directory)){Fail '-Assets is required: the unlock child needs the five firmware assets'}
  if(!(Test-Path -LiteralPath $Directory)){Fail ("Assets directory not found: {0}" -f $Directory)}
  $spec=Get-Content -Raw -LiteralPath (Join-Path $repo 'unlock\assets.json')|ConvertFrom-Json
  $plan=@()
  foreach($entry in $spec) {
    $path=Join-Path $Directory $entry.Name
    if(!(Test-Path -LiteralPath $path)){Fail ("Missing asset: {0}" -f $path)}
    $actual=Get-Sha256 $path
    if($actual -ne ([string]$entry.Sha256).ToLowerInvariant()){
      Fail ("Asset {0} is {1}, expected {2}" -f $entry.Name,$actual,$entry.Sha256)
    }
    $plan+=[pscustomobject]@{Name=$entry.Name;Source=$path;Relative=('RTX3090-UNLOCK\ASSETS\'+$entry.Name);Sha256=$actual
      Bytes=(Get-Item -LiteralPath $path).Length}
  }
  if($plan.Count -ne $spec.Count){Fail 'The asset list is incomplete'}
  return $plan
}

# --- staging ----------------------------------------------------------------

function Write-StagedFile {
  param([string]$Source,[string]$Destination,[string]$Relative,[string]$Sha256)
  if(Test-Path -LiteralPath $Destination) {
    $existing=Get-Sha256 $Destination
    if($existing -eq $Sha256){return 'unchanged'}
    Fail ("Refusing to overwrite different file: {0} (on disk {1}, staged {2})" -f $Destination,$existing,$Sha256)
  }
  $parent=Split-Path -Parent $Destination
  if(!(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  $actual=Get-Sha256 $Destination
  if($actual -ne $Sha256){Fail ("Copied file does not match after writing: {0}" -f $Destination)}
  return 'written'
}

function Invoke-Stage {
  param([string]$RootDirectory,[object[]]$Files,[string]$Label)
  $results=@()
  foreach($file in $Files) {
    $destination=Join-Path $RootDirectory $file.Relative
    $outcome=Write-StagedFile -Source $file.Source -Destination $destination -Relative $file.Relative -Sha256 $file.Sha256
    $results+=[pscustomobject]@{Relative=$file.Relative;Bytes=$file.Bytes;Sha256=$file.Sha256;Outcome=$outcome}
  }
  Write-Host ("Staged {0} files into {1} ({2})" -f $results.Count,$RootDirectory,$Label)
  return $results
}

# --- boot entries -----------------------------------------------------------

function New-BootBackup {
  $programData=Join-Path $env:ProgramData 'WindowsGPUUnlock\Backups'
  $stamp=(Get-Date).ToString('yyyyMMdd-HHmmssfff')
  $target=Join-Path $programData $stamp
  New-Item -ItemType Directory -Path $target -Force|Out-Null
  [void](Invoke-Bcd @('/export',(Join-Path $target 'bcd-export')))
  (Invoke-Bcd @('/enum'))|Set-Content -LiteralPath (Join-Path $target 'enum-before.txt') -Encoding UTF8
  # /v so the backup holds raw identifiers rather than the {current}/{default} aliases: the
  # default entry recorded here is what recovery has to put back.
  (Invoke-Bcd @('/enum','{bootmgr}','/v'))|Set-Content -LiteralPath (Join-Path $target 'bootmgr-before.txt') -Encoding UTF8
  (Invoke-Bcd @('/enum','{fwbootmgr}'))|Set-Content -LiteralPath (Join-Path $target 'firmware-before.txt') -Encoding UTF8
  (Get-Partition|Format-Table -AutoSize|Out-String -Width 200)|Set-Content -LiteralPath (Join-Path $target 'partitions-before.txt') -Encoding UTF8
  Write-Host ("BCD and partition state backed up to {0}" -f $target)
  return $target
}

function Assert-ManualEntryUsable {
  param([string]$Text,[string]$Identifier,[string]$DriveLetter)
  $path=Get-BootEntryField $Text $Identifier 'path'
  if($path -ne '\EFI\WindowsGPUUnlock\MANUAL.EFI'){
    Fail ("Entry {0} points at '{1}', not the manual handoff" -f $Identifier,$path)
  }
  $device=Get-BootEntryField $Text $Identifier 'device'
  $expected=('partition=' + $DriveLetter + ':')
  if($device -ne $expected){Fail ("Entry {0} reads the device '{1}', expected '{2}'" -f $Identifier,$device,$expected)}
}

function Invoke-RegisterManual {
  param($Targets,[object[]]$Files)
  if(Test-Path -LiteralPath $stateFile){Fail 'An install state already exists; use its recovery procedure (-RestoreWindowsFirst) before registering again'}
  $before=Invoke-Bcd @('/enum')
  # Two orders matter and they are different things. The firmware order decides whether
  # {bootmgr} runs at all; the Windows Boot Manager's own order decides what it starts.
  # The new entry lives in the second one, so both are read, checked and backed up.
  $firmware=Get-BootOrder (Invoke-Bcd @('/enum','{fwbootmgr}'))
  if($firmware[0] -ne '{bootmgr}'){
    Fail ("Firmware default is {0}, not {{bootmgr}}: this install would never run. Restore Windows-first boot first" -f $firmware[0])
  }
  $orderBefore=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
  if(($orderBefore -notcontains '{current}') -and ($orderBefore -notcontains '{default}')){
    Fail 'The Windows Boot Manager displayorder has no Windows fallback; refusing to add an entry beside nothing'
  }
  if($before -match '(?mi)^\s*bootsequence\s'){
    Fail 'The Windows Boot Manager has a bootsequence override; clear it first so the sequence is honest'
  }

  $hiberBefore=Get-Hiberboot
  $timeoutBefore=Get-BootTimeout (Invoke-Bcd @('/enum','{bootmgr}'))
  # What an unattended boot would start today. Manual registration must not change it, but it
  # is recorded here because automatic promotion and every recovery path need it back.
  $defaultBefore=Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))
  $backup=New-BootBackup
  $description='Windows GPU UNLOCK Manual'
  [void](Invoke-Bcd @('/copy','{bootmgr}','/d',$description))
  $afterCopy=Invoke-Bcd @('/enum')
  $entry=Resolve-NewBootCopy -BeforeText $before -AfterText $afterCopy -Name $description

  $steps=@(
    [pscustomobject]@{Name=('entry device -> {0}:' -f $Targets.Letter);Run={[void](Invoke-Bcd @('/set',$entry,'device',('partition=' + $Targets.Letter + ':')))}}
    [pscustomobject]@{Name='entry path -> manual handoff';Run={[void](Invoke-Bcd @('/set',$entry,'path','\EFI\WindowsGPUUnlock\MANUAL.EFI'))}}
    [pscustomobject]@{Name='displayorder append';Run={Set-BootOrder (@($orderBefore) + $entry)}}
  )
  $verify={
    $text=Invoke-Bcd @('/enum')
    Assert-ManualEntryUsable -Text $text -Identifier $entry -DriveLetter $Targets.Letter
    $order=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
    if($order[0] -ne $orderBefore[0]){Fail ("Verification failed: the first menu entry changed from {0} to {1}" -f $orderBefore[0],$order[0])}
    if($order -notcontains $entry){Fail 'Verification failed: the new entry is not in the Windows Boot Manager displayorder'}
    if((Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))) -ne $defaultBefore){
      Fail 'Verification failed: registering an entry changed the boot default'
    }
    if((Get-BootOrder (Invoke-Bcd @('/enum','{fwbootmgr}')))[0] -ne '{bootmgr}'){
      Fail 'Verification failed: {bootmgr} is no longer the firmware default'
    }
  }
  $rollback=@(
    [pscustomobject]@{Name='restore displayorder';Run={Set-BootOrder $orderBefore}}
    [pscustomobject]@{Name='delete the new entry';Run={[void](Invoke-Bcd @('/delete',$entry,'/f'))}}
  )
  Invoke-AutomaticTransition -Steps $steps -Verify $verify -Rollback $rollback

  $state=[ordered]@{
    Mode='registered-manual'
    HardwareTested=$false
    EntryId=$entry
    EntryDescription=$description
    BackupRoot=$backup
    BootOrderBefore=$orderBefore
    BootTimeoutBefore=$timeoutBefore
    BootDefaultBefore=$defaultBefore
    HiberbootBefore=$hiberBefore
    UnlockDriveLetter=$Targets.Letter
    UnlockPartitionGuid=$Targets.UnlockGuid
    WindowsPartitionGuid=$Targets.WindowsGuid
    RegisteredUtc=[DateTime]::UtcNow.ToString('o')
    StagedFiles=@($Files|ForEach-Object {[ordered]@{Relative=$_.Relative;Sha256=$_.Sha256;Bytes=$_.Bytes}})
  }
  $state|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $stateFile -Encoding UTF8
  Write-Host ('Registered {0} as "{1}".' -f $entry,$description)
  Write-Host 'Windows is still the first boot menu entry: restart and pick the unlock entry by hand to test it.'
}

function Invoke-EnableAutomatic {
  param($Targets)
  if(!$ConfirmedManualSuccess){
    Fail 'Test the manual unlock, the direct Windows entry and Tensor performance first; then pass -ConfirmedManualSuccess'
  }
  if(!(Test-Path -LiteralPath $stateFile)){Fail 'No install state: register the manual entry first'}
  $state=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json
  $entry=([string]$state.EntryId).ToLowerInvariant()
  if($entry -notmatch '^\{[0-9a-f-]{36}\}$'){Fail 'The saved entry identifier is malformed'}
  if($state.Mode -ne 'registered-manual'){Fail ("Install state is {0}; promotion has already happened or recovery is required" -f $state.Mode)}

  $text=Invoke-Bcd @('/enum')
  if($null -eq (Get-BootEntryBlock $text $entry)){Fail 'The registered entry no longer exists'}
  Assert-ManualEntryUsable -Text $text -Identifier $entry -DriveLetter $Targets.Letter
  $orderBefore=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
  if($orderBefore -notcontains $entry){Fail 'The registered entry is not in the Windows Boot Manager displayorder'}
  if((Get-BootOrder (Invoke-Bcd @('/enum','{fwbootmgr}')))[0] -ne '{bootmgr}'){
    Fail 'The firmware default is no longer {bootmgr}: arming the Windows menu would never be reached'
  }

  $descriptionBefore=Get-BootEntryField $text $entry 'description'
  $hiberBefore=Get-Hiberboot
  # Every identifier that really exists, so the default writer cannot be handed a dangling one.
  # bcdedit itself accepts a non-existent identifier as a default, so this list is the guard.
  $knownIds=Get-BootIdentifiers (Invoke-Bcd @('/enum','all'))
  $defaultBefore=Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))
  if($state.PSObject.Properties['BootDefaultBefore'] -and $state.BootDefaultBefore){
    $defaultBefore=[string]$state.BootDefaultBefore
  }
  # Long enough that a person can still choose Windows, short enough that an unattended
  # power-on is not waiting on a menu. Zero would remove the only local way back.
  $automaticTimeout=$script:automaticTimeout
  $planPath=Join-Path $state.BackupRoot 'recovery-plan.json'
  [ordered]@{
    CreatedUtc=[DateTime]::UtcNow.ToString('o')
    EntryId=$entry
    BootOrderBefore=$orderBefore
    BootTimeoutBefore=$state.BootTimeoutBefore
    BootTimeoutAutomatic=$automaticTimeout
    BootDefaultBefore=$defaultBefore
    BootDefaultAutomatic=$entry
    HiberbootBefore=$hiberBefore
    RestoreCommand='.\Install.ps1 -RestoreWindowsFirst'
    ManualEntryPath='\EFI\WindowsGPUUnlock\MANUAL.EFI'
    AutomaticEntryPath='\EFI\WindowsGPUUnlock\AUTO.EFI'
    Recovery='Restart, wait for the Windows boot menu, and choose the entry that is not "Windows GPU UNLOCK Auto". Or run the restore command from Windows.'
  }|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $planPath -Encoding UTF8

  $steps=@(
    [pscustomobject]@{Name='entry path -> automatic handoff';Run={[void](Invoke-Bcd @('/set',$entry,'path','\EFI\WindowsGPUUnlock\AUTO.EFI'))}}
    [pscustomobject]@{Name='entry description -> automatic';Run={[void](Invoke-Bcd @('/set',$entry,'description','Windows GPU UNLOCK Auto'))}}
    [pscustomobject]@{Name='disable Fast Startup';Run={Set-Hiberboot -Value 0}}
    [pscustomobject]@{Name='automatic entry first';Run={Set-BootOrder (@($entry) + @($orderBefore|Where-Object {$_ -ne $entry}))}}
    [pscustomobject]@{Name='boot default -> automatic entry';Run={Set-BootDefault -Identifier $entry -KnownIdentifiers $knownIds}}
    [pscustomobject]@{Name=('boot menu timeout -> {0}s' -f $automaticTimeout);Run={Set-BootTimeout -Seconds $automaticTimeout}}
  )
  $verify={
    $text=Invoke-Bcd @('/enum')
    $path=Get-BootEntryField $text $entry 'path'
    if($path -ne '\EFI\WindowsGPUUnlock\AUTO.EFI'){Fail ("Verification failed: entry path is '{0}'" -f $path)}
    $description=Get-BootEntryField $text $entry 'description'
    if($description -ne 'Windows GPU UNLOCK Auto'){Fail ("Verification failed: entry description is '{0}'" -f $description)}
    $orderAliases=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
    # A plain enumeration prints {current}/{default} instead of the identifiers they stand for,
    # so once an entry becomes the default the first position reads as "{default}" and would
    # never match our identifier. Positions are therefore compared from a verbose read.
    $order=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}','/v'))
    if(($orderAliases -notcontains '{current}') -and ($orderAliases -notcontains '{default}')){
      Fail 'Verification failed: the Windows fallback was dropped from the displayorder'
    }
    if((Get-BootOrder (Invoke-Bcd @('/enum','{fwbootmgr}')))[0] -ne '{bootmgr}'){
      Fail 'Verification failed: {bootmgr} is no longer the firmware default'
    }
    # Being first in the menu is not the same as being started: the default entry is what an
    # unattended power-on runs once the timeout expires. All of it is checked in one place so
    # no caller can look at the order alone and call the machine armed.
    $armed=Get-AutomaticArmed -Entry $entry `
      -Default (Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))) `
      -Order $order `
      -Timeout (Get-BootTimeout (Invoke-Bcd @('/enum','{bootmgr}'))) `
      -Hiberboot (Get-Hiberboot) `
      -ExpectedTimeout $automaticTimeout
    if(-not $armed.Armed){
      Fail ('Verification failed: automatic boot is not armed: ' + ($armed.Reasons -join '; '))
    }
  }
  $rollback=@(
    [pscustomobject]@{Name='restore entry path';Run={[void](Invoke-Bcd @('/set',$entry,'path','\EFI\WindowsGPUUnlock\MANUAL.EFI'))}}
    [pscustomobject]@{Name='restore entry description';Run={[void](Invoke-Bcd @('/set',$entry,'description',$descriptionBefore))}}
    [pscustomobject]@{Name='restore Fast Startup';Run={if($null -ne $hiberBefore){Set-Hiberboot -Value ([int]$hiberBefore)}}}
    [pscustomobject]@{Name='restore boot order';Run={Set-BootOrder $orderBefore}}
    [pscustomobject]@{Name='restore boot default';Run={Set-BootDefault -Identifier $defaultBefore -KnownIdentifiers (Get-BootIdentifiers (Invoke-Bcd @('/enum','all')))}}
    [pscustomobject]@{Name='restore boot timeout';Run={if($null -ne $state.BootTimeoutBefore){Set-BootTimeout -Seconds ([int]$state.BootTimeoutBefore)}}}
  )
  Invoke-AutomaticTransition -Steps $steps -Verify $verify -Rollback $rollback

  $state.Mode='promoted-automatic'
  $state|Add-Member -NotePropertyName BootDefaultBefore -NotePropertyValue $defaultBefore -Force
  $state|Add-Member -NotePropertyName BootDefaultAutomatic -NotePropertyValue $entry -Force
  $state|Add-Member -NotePropertyName PromotedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
  $state|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $stateFile -Encoding UTF8
  Write-Host 'Automatic boot is armed. The next power-on unlocks and hands off to Windows with no key.'
  Write-Host ('Recovery: .\Install.ps1 -RestoreWindowsFirst   (plan: {0})' -f $planPath)
}

function Invoke-RestoreWindowsFirst {
  if(!(Test-Path -LiteralPath $stateFile)){
    if((Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}')))[0] -eq '{current}'){
      Write-Host 'No install state and Windows is already the first boot entry. Nothing to do.';return
    }
    Fail 'No install state, but Windows is not the first boot entry. Use the boot menu or the firmware menu to start Windows, then restore the order by hand'
  }
  $state=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json
  $entry=([string]$state.EntryId).ToLowerInvariant()
  $orderNow=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
  # Windows first, everything else (including the unlock entry) kept behind it so the
  # manual test entry stays available and nothing is silently deleted.
  $desired=@('{current}') + @($orderNow|Where-Object {$_ -ne '{current}'})
  # The default entry is what an unattended power-on actually starts, so recovery has to put
  # the original one back even if the menu order already looks right.
  $defaultTarget=$null
  if($state.PSObject.Properties['BootDefaultBefore'] -and $state.BootDefaultBefore){$defaultTarget=[string]$state.BootDefaultBefore}
  if(-not $defaultTarget -and $state.BackupRoot){
    $saved=Join-Path ([string]$state.BackupRoot) 'bootmgr-before.txt'
    if(Test-Path -LiteralPath $saved){$defaultTarget=Get-BootDefault (Get-Content -Raw -LiteralPath $saved)}
  }
  $defaultNow=Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))
  if(-not $defaultTarget){
    if($defaultNow -eq $entry){
      Fail 'Refusing to finish: the unlock entry is still the boot default and no original default was recorded'
    }
    $defaultTarget=$defaultNow
  }
  $actions=@(
    [pscustomobject]@{Name='restore boot default'
      Run={
        if($defaultTarget -ne (Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v')))){
          Set-BootDefault -Identifier $defaultTarget -KnownIdentifiers (Get-BootIdentifiers (Invoke-Bcd @('/enum','all')))
        }
      }}
    [pscustomobject]@{Name='Windows first';Run={Set-BootOrder $desired}}
    [pscustomobject]@{Name='restore Fast Startup'
      Run={if($null -ne $state.HiberbootBefore){Set-Hiberboot -Value ([int]$state.HiberbootBefore)}}}
    [pscustomobject]@{Name='restore boot timeout'
      Run={if($null -ne $state.BootTimeoutBefore){Set-BootTimeout -Seconds ([int]$state.BootTimeoutBefore)}}}
    [pscustomobject]@{Name='re-point the saved entry at the manual handoff'
      Run={
        if($entry -match '^\{[0-9a-f-]{36}\}$'){
          $text=Invoke-Bcd @('/enum')
          if($null -ne (Get-BootEntryBlock $text $entry)){
            [void](Invoke-Bcd @('/set',$entry,'path','\EFI\WindowsGPUUnlock\MANUAL.EFI'))
            [void](Invoke-Bcd @('/set',$entry,'description','Windows GPU UNLOCK Manual'))
          }
        }
      }}
  )
  try {
    Invoke-RecoveryActions -Actions $actions
  } catch {
    Write-Warning $_.Exception.Message
    Write-Warning 'Windows-first recovery is independent of the saved entry: check the first boot menu entry.'
  }
  $order=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
  if($order[0] -ne '{current}'){Fail ("Verification failed: the first boot entry is {0}, not {{current}}" -f $order[0])}
  if((Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))) -eq $entry){
    Fail 'Verification failed: the unlock entry is still the boot default'
  }
  $state.Mode='restored-windows-first'
  $state|Add-Member -NotePropertyName RestoredUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
  $state|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $stateFile -Encoding UTF8
  Write-Host 'Windows first restored. Files on the dedicated ESP were left in place and nothing was rebooted.'
}

# --- readiness --------------------------------------------------------------

function Invoke-Readiness {
  param([object[]]$Files)
  $problems=@()
  $notes=@()
  if(!(Test-IsAdmin)){$problems+='Not elevated: bcdedit cannot read or write the boot configuration'}
  try { Get-EspPartitions|Out-Null } catch {$problems+=('Cannot enumerate partitions: ' + $_.Exception.Message)}
  foreach($file in $Files) {
    $notes+=('{0,-22} {1,9} bytes  {2}' -f $file.Role,$file.Bytes,$file.Sha256)
  }
  $targets=$null
  try {
    $targets=Resolve-ConfiguredPartitions
    $notes+=('unlock ESP           disk {0} part {1}  {2:N2} GiB free  letter {3}:' -f $targets.Unlock.DiskNumber,$targets.Unlock.PartitionNumber,($targets.UnlockVolume.SizeRemaining/1GB),$targets.Letter)
    $notes+=('windows ESP          disk {0} part {1}  GUID {2}' -f $targets.Windows.DiskNumber,$targets.Windows.PartitionNumber,$targets.WindowsGuid)
  } catch {$problems+=$_.Exception.Message}
  try { Assert-PlatformSafe; $notes+='Secure Boot off, system volume unencrypted' } catch {$problems+=$_.Exception.Message}
  if($null -ne $targets) {
    $bootmgfw=Join-Path $targets.WindowsVolume.Path 'EFI\Microsoft\Boot\bootmgfw.efi'
    if(Test-Path -LiteralPath $bootmgfw){$notes+=('bootmgfw.efi         present on the Windows ESP')}
    else {$problems+=('bootmgfw.efi is missing at {0}: the handoff would have nothing to start' -f $bootmgfw)}
    $foreign=Join-Path $targets.WindowsVolume.Path 'EFI\WindowsGPUUnlock'
    if(Test-Path -LiteralPath $foreign){$problems+=('The Windows ESP already contains EFI\WindowsGPUUnlock at {0}; this experiment must stay on the dedicated ESP' -f $foreign)}
    # What is already on the ESP must match what would be built now. A stale stage would make
    # Gate C boot an older image while every build-side hash still looked correct.
    $assetSpec=@()
    try {
      $assetSpec=Get-Content -Raw -LiteralPath (Join-Path $repo 'unlock\assets.json')|ConvertFrom-Json
    } catch {$problems+=('Cannot read the asset manifest: ' + $_.Exception.Message)}
    $staged=Get-StagedStatus -Root $targets.UnlockVolume.Path -Files $Files -AssetSpec @($assetSpec)
    foreach($problem in $staged.Problems){$problems+=$problem}
    $notes+=('staged on the ESP    {0} of {1} files match the build' -f $staged.Ok,$staged.Total)
  }
  if(Test-IsAdmin) {
    try {
      $firmware=Get-BootOrder (Invoke-Bcd @('/enum','{fwbootmgr}'))
      $notes+=('firmware default     {0}' -f $firmware[0])
      if($firmware[0] -ne '{bootmgr}' -and !(Test-Path -LiteralPath $stateFile)){
        $problems+=('Firmware default is {0} with no install state; the unlock entry would never be reached' -f $firmware[0])
      }
      $windows=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}'))
      $timeout=Get-BootTimeout (Invoke-Bcd @('/enum','{bootmgr}'))
      $default=Get-BootDefault (Invoke-Bcd @('/enum','{bootmgr}','/v'))
      $notes+=('boot menu order      {0}' -f ($windows -join ' '))
      $notes+=('boot menu timeout    {0}s' -f $timeout)
      $notes+=('boot menu default    {0}' -f $default)
      if(($windows -notcontains '{current}') -and ($windows -notcontains '{default}')){
        $problems+='The Windows Boot Manager displayorder has no Windows fallback'
      }
      if($null -ne $timeout -and $timeout -eq 0){
        $problems+='The boot menu timeout is 0: there would be no way to pick Windows instead of the unlock'
      }
      # Once promoted, "armed" is a property of four things at once, never of menu position.
      # The order is read verbosely because the default entry otherwise prints as {default}.
      if(Test-Path -LiteralPath $stateFile){
        $stateForArm=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json
        if($stateForArm.Mode -eq 'promoted-automatic'){
          $orderRaw=Get-BootOrder (Invoke-Bcd @('/enum','{bootmgr}','/v'))
          $armed=Get-AutomaticArmed -Entry ([string]$stateForArm.EntryId) -Default $default -Order $orderRaw `
            -Timeout $timeout -Hiberboot (Get-Hiberboot) -ExpectedTimeout $script:automaticTimeout
          if($armed.Armed){$notes+='automatic armed      yes (default, first entry, timeout and Fast Startup all match)'}
          else {$problems+=('Automatic boot is registered but not armed: ' + ($armed.Reasons -join '; '))}
        }
      }
    } catch {$problems+=('Cannot read the boot order: ' + $_.Exception.Message)}
    try {
      if(Test-Path -LiteralPath $stateFile){
        $state=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json
        $notes+=('install state        {0} entry {1}' -f $state.Mode,$state.EntryId)
      } else {$notes+=('install state        absent (nothing registered yet)')}
    } catch {$problems+=('Cannot read install state: ' + $_.Exception.Message)}
  }
  Write-Host ''
  Write-Host 'Readiness notes:'
  $notes|ForEach-Object {Write-Host ('  '+$_)}
  Write-Host ''
  if($problems.Count -gt 0) {
    Write-Host 'BLOCKED:'
    $problems|ForEach-Object {Write-Host ('  - '+$_)}
    return 1
  }
  Write-Host 'READY: every prerequisite passed. Nothing was written.'
  return 0
}

# Prints the exact commands each action would run, with the values this machine would use.
# It exists so Gate B can be reviewed from one screen: nothing here reads boot state and
# nothing here writes anything.
function Write-InstallPlan {
  $config=$null
  if(Test-Path -LiteralPath $configFile) {
    try { $config=Get-Content -Raw -LiteralPath $configFile|ConvertFrom-Json } catch { $config=$null }
  }
  $letter='<unresolved>'
  $unlockGuid='<unresolved>'
  $windowsGuid='<unresolved>'
  $placeholder=$true
  if($config) {
    $placeholder=[bool]$config.Placeholder
    if($config.UnlockDriveLetter){$letter=[string]$config.UnlockDriveLetter}
    if($config.UnlockPartitionGuid){$unlockGuid=[string]$config.UnlockPartitionGuid}
    if($config.WindowsPartitionGuid){$windowsGuid=[string]$config.WindowsPartitionGuid}
  }
  'PLAN ONLY: the commands below were printed, not executed.'
  ''
  'configuration'
  ('  unlock ESP          {0}  (partition={1}:)' -f $unlockGuid,$letter)
  ('  Windows ESP         {0}' -f $windowsGuid)
  ('  placeholder         {0}' -f $placeholder)
  ('  boot menu timeout   {0}s for automatic boot' -f $automaticTimeout)
  ''
  'stage (no action, or before any of the below)'
  ('  copy -> {0}:\EFI\WindowsGPUUnlock\{{UNLOCK.EFI,UNLOCK-AUTO.EFI,MANUAL.EFI,AUTO.EFI}}' -f $letter)
  ('  copy -> {0}:\RTX3090-UNLOCK\ASSETS\{{five firmware assets}}' -f $letter)
  '  bcdedit /enum {bootmgr}   (must still show displayorder {current} afterwards)'
  ''
  '-RegisterManual'
  '  backup: bcdedit /export "%ProgramData%\WindowsGPUUnlock\Backups\<stamp>\bcd-export"'
  '          bcdedit /enum > enum-before.txt; bcdedit /enum {bootmgr} /v > bootmgr-before.txt'
  '          bcdedit /enum {fwbootmgr} > firmware-before.txt; Get-Partition > partitions-before.txt'
  '  guard:  firmware displayorder[0] must be {bootmgr}; {bootmgr} order must contain {current}'
  '          install\state.json must not exist; {bootmgr} must have no bootsequence'
  '  bcdedit /copy {bootmgr} /d "Windows GPU UNLOCK Manual"'
  '  bcdedit /set <new> device partition=<letter>:'
  '  bcdedit /set <new> path \EFI\WindowsGPUUnlock\MANUAL.EFI'
  '  bcdedit /set {bootmgr} displayorder {current} <new>'
  '  (the boot default is left alone here: Windows still starts if the menu is ignored)'
  '  verify: <new> has that device/path/description, order[0] is still {current}, default unchanged'
  '  rollback: bcdedit /set {bootmgr} displayorder <order before>'
  '            then the copied entry is removed: /delete <new> /f'
  ''
  '-EnableAutomaticBoot -ConfirmedManualSuccess'
  '  guard:  state Mode=registered-manual; entry still on partition=<letter>: with the manual path'
  '          firmware displayorder[0] is still {bootmgr}'
  '  bcdedit /set <entry> path \EFI\WindowsGPUUnlock\AUTO.EFI'
  '  bcdedit /set <entry> description "Windows GPU UNLOCK Auto"'
  '  bcdedit /set {bootmgr} displayorder <entry> {current}'
  '  bcdedit /set {bootmgr} default <entry>'
  ('  bcdedit /set {{bootmgr}} timeout {0}' -f $automaticTimeout)
  '  reg add <hiberKey> /v HiberbootEnabled /t REG_DWORD /d 0 /f'
  '  verify: path, description, order[0]=<entry>, {current} still present, default=<entry>,'
  '          timeout, Hiberboot=0 -- all of them together, because the default entry is what'
  '          an unattended power-on starts and the menu position alone proves nothing'
  '  rollback: path -> MANUAL.EFI, description -> Manual, order -> previous, default -> previous,'
  '            timeout -> previous, HiberbootEnabled -> previous'
  ''
  '-RestoreWindowsFirst'
  '  restore the boot default (BootDefaultBefore, else bootmgr-before.txt, else current)'
  '  set {bootmgr} displayorder to {current} + everything current, unlock entry kept behind it'
  '  restore BootTimeoutBefore; restore HiberbootBefore'
  '  re-point the saved entry at MANUAL.EFI (description Windows GPU UNLOCK Manual)'
  '  verify order[0] is {current} and the unlock entry is not the default; nothing is deleted'
  ''
  'If the ESP GUIDs above are placeholders the plan is still printable, but the installer'
  'refuses to run: run Configure.ps1 against the real ESP first.'
}

# --- main -------------------------------------------------------------------

$mode=@()
if($Check){$mode+='check'}
if($LocalStage){$mode+='localstage'}
if($RegisterManual){$mode+='register'}
if($EnableAutomaticBoot){$mode+='promote'}
if($RestoreWindowsFirst){$mode+='restore'}
if($mode.Count -gt 1){Fail ('Choose one action, not: ' + ($mode -join ', '))}

# -Plan is deliberately the first thing main does: it reads the configuration file and
# prints, so no artifact check, no partition resolution and no write can happen first.
if($Plan){Write-InstallPlan;return}

$script:StagedBytes=0
if($mode.Count -eq 0 -or $mode -contains 'check' -or $mode -contains 'localstage') {
  # read-only modes still need the size arithmetic and the artifact inventory
  if($mode -contains 'check' -or $mode -contains 'localstage') {
    $artifacts=Assert-Artifacts
    $script:StagedBytes=($artifacts|Measure-Object -Property Bytes -Sum).Sum
  }
}

if($mode -contains 'restore') { Invoke-RestoreWindowsFirst; return }

if($mode -contains 'check') {
  $exitCode=Invoke-Readiness -Files $artifacts
  exit $exitCode
}

$artifacts=Assert-Artifacts
$assetPlan=Get-AssetPlan $Assets
$allFiles=@($artifacts) + @($assetPlan)
$script:StagedBytes=($allFiles|Measure-Object -Property Bytes -Sum).Sum

if($mode -contains 'localstage') {
  $destination=[System.IO.Path]::GetFullPath($LocalStage)
  if(Test-Path -LiteralPath $destination) {
    $existing=(Get-ChildItem -LiteralPath $destination -Recurse -File -ErrorAction SilentlyContinue)
    if($existing){Fail ("Local staging directory is not empty: {0}" -f $destination)}
  }
  $files=Invoke-Stage -RootDirectory $destination -Files $allFiles -Label 'local mirror'
  ''
  'Local staging tree:'
  $files|Format-Table -AutoSize|Out-String -Width 200
  'Nothing was written to any disk or partition. To install, run the same command without -LocalStage.'
  return
}

$targets=Resolve-ConfiguredPartitions
Assert-PlatformSafe
$rootPath=($targets.Letter + ':\')
$files=Invoke-Stage -RootDirectory $rootPath -Files $allFiles -Label ('dedicated ESP ' + $targets.UnlockGuid)
if($mode.Count -eq 0) {
  Write-Host 'Files staged only. Boot order unchanged.'
  return
}
if($mode -contains 'register'){Invoke-RegisterManual -Targets $targets -Files $files;return}
if($mode -contains 'promote'){Invoke-EnableAutomatic -Targets $targets;return}



