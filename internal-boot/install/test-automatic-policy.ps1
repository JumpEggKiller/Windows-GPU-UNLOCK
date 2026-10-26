# Host tests for the installer's boot-entry bookkeeping. Everything here runs against
# synthetic bcdedit text and stub actions: no BCD store, no partition and no image is
# touched, so this is safe to run at any time.
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'automatic-policy.ps1')

$script:passed=0
$script:failed=0

function Check([string]$Title,[scriptblock]$Body) {
  try {
    & $Body
    $script:passed++
    Write-Host ('PASS ' + $Title)
  } catch {
    $script:failed++
    Write-Host ('FAIL {0}: {1}' -f $Title,$_.Exception.Message)
  }
}

function Fail([string]$Message){throw $Message}

function Expect([scriptblock]$Body,[string]$Fragment) {
  try { & $Body } catch {
    if($_.Exception.Message -notlike ('*'+$Fragment+'*')) {
      Fail ("threw '{0}', expected '{1}'" -f $_.Exception.Message,$Fragment)
    }
    return
  }
  Fail ("expected a failure containing '{0}', but the call succeeded" -f $Fragment)
}

# A block shaped like real `bcdedit /enum` output. {bootmgr} is the source every copy
# must be attributed to, so its device and path are the Windows Boot Manager's own.
function New-Entry([string]$Identifier,[string]$Description,[string]$Device,[string]$Path) {
  return (@(
    'Windows Boot Manager','--------------------'
    ('identifier              ' + $Identifier)
    ('device                  ' + $Device)
    ('path                    ' + $Path)
    ('description             ' + $Description)
    'locale                  en-US'
    ''
  ) -join "`r`n")
}

$bootmgrDevice='partition=\Device\HarddiskVolume1'
$bootmgrPath='\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI'
$newId='{1a2b3c4d-0000-1111-2222-333344445555}'
$otherId='{9f8e7d6c-0000-1111-2222-333344445555}'
$name='Windows GPU UNLOCK Manual'
$before=New-Entry '{bootmgr}' 'Windows Boot Manager' $bootmgrDevice $bootmgrPath
$copied=$before + (New-Entry $newId $name $bootmgrDevice $bootmgrPath)

Write-Host 'automatic-policy: boot entry attribution'
Check 'one new copy with the expected name is attributed' {
  $id=Resolve-NewBootCopy -BeforeText $before -AfterText $copied -Name $name
  if($id -ne $newId){Fail ("resolved '{0}', expected '{1}'" -f $id,$newId)}
}
Check 'two new copies are refused' {
  $two=$copied + (New-Entry $otherId $name $bootmgrDevice $bootmgrPath)
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $two -Name $name } 'Cannot attribute one new boot copy'
}
Check 'no new copy at all is refused' {
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $before -Name $name } 'Cannot attribute one new boot copy'
}
Check 'a different description is refused' {
  $wrong=$before + (New-Entry $newId 'Windows GPU UNLOCK Auto' $bootmgrDevice $bootmgrPath)
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $wrong -Name $name } 'New entry description differs'
}
Check 'a copy whose device was already changed is refused' {
  $wrong=$before + (New-Entry $newId $name 'partition=U:' $bootmgrPath)
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $wrong -Name $name } 'not the expected boot-manager copy'
}
Check 'a copy whose path was already changed is refused' {
  $wrong=$before + (New-Entry $newId $name $bootmgrDevice '\EFI\WindowsGPUUnlock\MANUAL.EFI')
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $wrong -Name $name } 'not the expected boot-manager copy'
}
Check 'a missing copy source is refused' {
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $copied -Name $name -SourceIdentifier '{deadbeef-0000-1111-2222-333344445555}' } 'missing from the enumeration'
}
Check 'an unrelated new entry is never mistaken for the copy' {
  $noise=$before + (New-Entry $newId 'Something Else' 'partition=C:' '\EFI\Microsoft\Boot\bootmgfw.efi')
  Expect { Resolve-NewBootCopy -BeforeText $before -AfterText $noise -Name $name } 'New entry description differs'
}

Write-Host 'automatic-policy: firmware order'
# Captured verbatim from this machine so the parser sees the real layout, including the
# named {bootmgr} identifier that is not a GUID.
$firmware=@(
  'Firmware Boot Manager','---------------------','identifier              {fwbootmgr}'
  'displayorder            {bootmgr}'
  '                        {389ada0e-ce4b-11f1-b410-806e6f6e6963}'
  '                        {469011d0-a872-11f1-bb02-ea6b3138fbbe}'
  'timeout                 1'
) -join "`r`n"
Check 'the real firmware order keeps {bootmgr} first' {
  $order=Get-BootOrder $firmware
  if($order.Count -ne 3){Fail ("parsed {0} identifiers, expected 3" -f $order.Count)}
  if($order[0] -ne '{bootmgr}'){Fail ("first identifier is '{0}'" -f $order[0])}
  if($order[1] -ne '{389ada0e-ce4b-11f1-b410-806e6f6e6963}'){Fail 'the second identifier was not preserved'}
}
Check 'a repeated identifier is refused' {
  $bad=@(
    'identifier              {fwbootmgr}'
    'displayorder            {bootmgr}'
    '                        {389ada0e-ce4b-11f1-b410-806e6f6e6963}'
    '                        {bootmgr}'
    'timeout                 1'
  ) -join "`r`n"
  Expect { Get-BootOrder $bad } 'repeats an identifier'
}
Check 'a missing displayorder is refused' {
  Expect { Get-BootOrder 'Firmware Boot Manager' } 'no displayorder'
}
Check 'an empty displayorder is refused' {
  Expect { Get-BootOrder "identifier              {fwbootmgr}`r`ndisplayorder            `r`ntimeout 1" } 'displayorder'
}

Write-Host 'automatic-policy: windows boot menu order'
# The unlock entry is an application entry inside the Windows Boot Manager's own menu, so
# the order that matters is the one in the {bootmgr} block, and it must keep Windows.
$windowsMenu=@(
  'Windows Boot Manager','--------------------','identifier              {bootmgr}'
  ('device                  ' + $bootmgrDevice)
  ('path                    ' + $bootmgrPath)
  'default                 {current}'
  'displayorder            {current}'
  'toolsdisplayorder       {memdiag}'
  'timeout                 30'
) -join "`r`n"
Check 'the real windows menu order is parsed' {
  $order=Get-BootOrder $windowsMenu
  if($order.Count -ne 1){Fail ("parsed {0} identifiers, expected 1" -f $order.Count)}
  if($order[0] -ne '{current}'){Fail ("first identifier is '{0}'" -f $order[0])}
}
Check 'a menu order without the Windows fallback is refused' {
  Expect { Assert-OrderKeepsWindows @($newId) } 'without {current}'
}
Check 'a menu order that keeps Windows passes the guard' {
  # The guard is exercised through Assert-OrderKeepsWindows, never through Set-BootOrder:
  # Set-BootOrder writes this machine's real firmware state and a test must not do that.
  $order=@($newId,'{current}')
  Assert-OrderKeepsWindows $order
  if($order.Count -ne 2){Fail 'the guard changed the order it was given'}
}
Check 'an unreasonable boot timeout is refused before bcdedit runs' {
  Expect { Set-BootTimeout -Seconds -1 } 'unreasonable boot timeout'
  Expect { Set-BootTimeout -Seconds 3601 } 'unreasonable boot timeout'
}
Check 'the boot menu timeout is read' {
  if((Get-BootTimeout $windowsMenu) -ne 30){Fail 'did not read 30'}
  if((Get-BootTimeout "identifier  {bootmgr}`r`ntimeout                 0") -ne 0){Fail 'did not read 0'}
  if($null -ne (Get-BootTimeout "identifier  {bootmgr}`r`ndisplayorder            {current}")){Fail 'invented a timeout'}
}

# --- the boot default decides what an unattended power-on actually starts ----

# A verbose enumeration, the only form that prints raw identifiers instead of the
# {current}/{default} aliases.
$windowsLoader='{469011d3-a872-11f1-bb02-ea6b3138fbbe}'
$windowsMenuVerbose=@(
  'Windows Boot Manager'
  '--------------------'
  'identifier              {9dea862c-5cdd-4e70-acc1-f32b344d4795}'
  ('device                  ' + $bootmgrDevice)
  ('path                    ' + $bootmgrPath)
  ('default                 ' + $windowsLoader)
  ('displayorder            ' + $windowsLoader)
  'toolsdisplayorder       {memdiag}'
  'timeout                 30'
) -join "`r`n"

Check 'the boot default is read as a concrete identifier' {
  $default=Get-BootDefault $windowsMenuVerbose
  if($default -ne $windowsLoader){Fail ("read default '{0}'" -f $default)}
}
Check 'a boot manager without a default is refused' {
  Expect { Get-BootDefault "identifier  {bootmgr}`r`ndisplayorder            {current}" } 'reports no default entry'
}
Check 'a default that is not in the store is refused before bcdedit runs' {
  # bcdedit itself accepts a default that does not exist, so this guard is the only thing
  # standing between a typo and a boot configuration that points at nothing.
  Expect { Set-BootDefault -Identifier '{11111111-2222-3333-4444-555555555555}' -KnownIdentifiers @($windowsLoader) } 'not in the store'
}
Check 'a default that is not a concrete identifier is refused' {
  Expect { Set-BootDefault -Identifier '{bootmgr}' -KnownIdentifiers @('{bootmgr}') } 'not a concrete entry identifier'
  Expect { Set-BootDefault -Identifier '{current}' -KnownIdentifiers @('{current}') } 'not a concrete entry identifier'
}
Check 'automatic boot is armed only when all four conditions agree' {
  $armed=Get-AutomaticArmed -Entry $newId -Default $newId -Order @($newId,'{current}') -Timeout 5 -Hiberboot 0 -ExpectedTimeout 5
  if(-not $armed.Armed){Fail ('not armed: ' + ($armed.Reasons -join '; '))}
}
Check 'being first in the menu is not enough to be armed' {
  # The defect this whole section exists for: the unlock entry is first in the menu, the
  # timeout is short and Fast Startup is off, yet an unattended power-on still starts Windows
  # because the default entry never changed.
  $armed=Get-AutomaticArmed -Entry $newId -Default $windowsLoader -Order @($newId,'{current}') -Timeout 5 -Hiberboot 0 -ExpectedTimeout 5
  if($armed.Armed){Fail 'called the machine armed while the default entry is still Windows'}
  if(($armed.Reasons -join '; ') -notmatch 'boot default'){Fail 'the reason does not name the default entry'}
}
Check 'a long menu timeout is not armed' {
  $armed=Get-AutomaticArmed -Entry $newId -Default $newId -Order @($newId,'{current}') -Timeout 30 -Hiberboot 0 -ExpectedTimeout 5
  if($armed.Armed){Fail 'called the machine armed with a 30s timeout'}
}
Check 'a missing menu timeout is not armed' {
  $armed=Get-AutomaticArmed -Entry $newId -Default $newId -Order @($newId,'{current}') -Timeout $null -Hiberboot 0 -ExpectedTimeout 5
  if($armed.Armed){Fail 'called the machine armed with no timeout'}
}
Check 'Fast Startup still enabled is not armed' {
  $armed=Get-AutomaticArmed -Entry $newId -Default $newId -Order @($newId,'{current}') -Timeout 5 -Hiberboot 1 -ExpectedTimeout 5
  if($armed.Armed){Fail 'called the machine armed with Fast Startup on'}
}
Check 'the unlock entry behind Windows is not armed either' {
  $armed=Get-AutomaticArmed -Entry $newId -Default $newId -Order @('{current}',$newId) -Timeout 5 -Hiberboot 0 -ExpectedTimeout 5
  if($armed.Armed){Fail 'called the machine armed while the unlock entry is second in the menu'}
}

Write-Host 'automatic-policy: recovery and transition'
function New-Action([string]$Name,[scriptblock]$Run){return [pscustomobject]@{Name=$Name;Run=$Run}}

Check 'every recovery action runs even after one fails' {
  $log=New-Object System.Collections.ArrayList
  $actions=@(
    (New-Action 'first' {[void]$log.Add('first')})
    (New-Action 'broken' {throw 'broken action'})
    (New-Action 'third' {[void]$log.Add('third')})
  )
  Expect { Invoke-RecoveryActions -Actions $actions } 'Recovery incomplete'
  if(($log -join ',') -ne 'first,third'){Fail ('ran {0}' -f ($log -join ','))}
}
Check 'a clean recovery run reports no failures' {
  $log=New-Object System.Collections.ArrayList
  Invoke-RecoveryActions -Actions @((New-Action 'only' {[void]$log.Add('only')}))
  if(($log -join ',') -ne 'only'){Fail 'the action did not run'}
}
Check 'a transition that verifies runs no rollback' {
  $log=New-Object System.Collections.ArrayList
  $steps=@((New-Action 'step' {[void]$log.Add('step')}))
  $rollback=@((New-Action 'undo' {[void]$log.Add('undo')}))
  Invoke-AutomaticTransition -Steps $steps -Verify {[void]$log.Add('verify')} -Rollback $rollback
  if(($log -join ',') -ne 'step,verify'){Fail ('ran {0}' -f ($log -join ','))}
}
Check 'a failed verification rolls back and rethrows the original error' {
  $log=New-Object System.Collections.ArrayList
  $steps=@((New-Action 'step' {[void]$log.Add('step')}))
  $rollback=@((New-Action 'undo' {[void]$log.Add('undo')}))
  Expect { Invoke-AutomaticTransition -Steps $steps -Verify {throw 'verify says no'} -Rollback $rollback } 'verify says no'
  if(($log -join ',') -ne 'step,undo'){Fail ('ran {0}' -f ($log -join ','))}
}
Check 'a failing step rolls back and rethrows that error' {
  $log=New-Object System.Collections.ArrayList
  $steps=@((New-Action 'broken' {throw 'step says no'}))
  $rollback=@((New-Action 'undo' {[void]$log.Add('undo')}))
  Expect { Invoke-AutomaticTransition -Steps $steps -Verify {[void]$log.Add('verify')} -Rollback $rollback } 'step says no'
  if(($log -join ',') -ne 'undo'){Fail ('ran {0}' -f ($log -join ','))}
}
Check 'a rollback that also fails still rethrows the original error' {
  $steps=@((New-Action 'broken' {throw 'step says no'}))
  $rollback=@((New-Action 'undo' {throw 'undo says no'}))
  Expect { Invoke-AutomaticTransition -Steps $steps -Verify {{ }} -Rollback $rollback } 'step says no'
}
Check 'an entry field is read back without its identifier line' {
  $path=Get-BootEntryField $copied $newId 'path'
  if($path -ne $bootmgrPath){Fail ("read '{0}'" -f $path)}
  $device=Get-BootEntryField $copied $newId 'device'
  if($device -ne $bootmgrDevice){Fail ("read '{0}'" -f $device)}
  if($null -ne (Get-BootEntryBlock $copied '{deadbeef-0000-1111-2222-333344445555}')){Fail 'a missing entry was found'}
}

# --- which enumeration a caller may attribute a new entry from -----------------
# A bare "bcdedit /enum" prints {bootmgr} and {current} instead of the identifiers they
# stand for, and it does not list a freshly copied boot-manager entry at all. A before /
# after diff over that output is empty on every real store, so registration could never be
# attributed. This is the regression that only the live store exposed.
Check 'a plain enumeration yields no identifiers to attribute from' {
  # What a real store does: "bcdedit /enum" prints {bootmgr} and {current} and never lists
  # the entry that /copy just created, so the before and after text are identical and a
  # correct registration cannot be attributed. This is exactly what the live store did.
  $plain=@(
    'Windows Boot Manager'
    '--------------------'
    'identifier              {bootmgr}'
    ('device                  ' + $bootmgrDevice)
    ('path                    ' + $bootmgrPath)
    'default                 {current}'
    'displayorder            {current}'
    'timeout                 30'
    ''
    'Windows Boot Loader'
    '-------------------'
    'identifier              {current}'
    'device                  partition=C:'
    'path                    \Windows\system32\winload.efi'
  ) -join "`r`n"
  Expect { Resolve-NewBootCopy -BeforeText $plain -AfterText $plain -Name $name } 'Cannot attribute one new boot copy'
}
Check 'a verbose enumeration breaks attribution because the boot manager loses its alias' {
  # "bcdedit /enum all /v" is what the backup wants, but it renders the boot manager as
  # {9dea862c-...}, so the default -SourceIdentifier '{bootmgr}' cannot be found and a
  # perfectly good copy looks unattributable. The installer therefore compares /enum all
  # (non-verbose), which keeps the aliases and still lists every copied entry by GUID.
  $before=@($windowsMenuVerbose) -join "`r`n"
  $after=$before + "`r`n" + (New-Entry $newId $name $bootmgrDevice $bootmgrPath)
  $ids=@(Get-BootIdentifiers $before)
  if($ids -notcontains '{9dea862c-5cdd-4e70-acc1-f32b344d4795}'){Fail 'the verbose read lost the boot manager identifier'}
  Expect { [void](Resolve-NewBootCopy -BeforeText $before -AfterText $after -Name $name) } 'is missing from the enumeration'
}

# The firmware order is what decides an unattended power-on now that the Windows boot
# manager refuses the image (0xC000007B, then 0xC0000221, then 0xC0000428 on this machine).
# These are guard checks on a pure function: no boot store is written.
Check 'an empty firmware order is refused' {
  Expect { Assert-FirmwareOrderKeepsWindows -Identifiers @() } 'empty firmware order'
}
Check 'a firmware order without the Windows boot manager is refused' {
  Expect { Assert-FirmwareOrderKeepsWindows -Identifiers @($newId) } 'without the Windows boot manager'
  Expect { Assert-FirmwareOrderKeepsWindows -Identifiers @($newId,'{389ada0e-ce4b-11f1-b410-806e6f6e6963}') } 'without the Windows boot manager'
}
Check 'the real firmware order passes the guard once the unlock image is moved in front' {
  $real=@(
    '{bootmgr}',
    '{389ada0e-ce4b-11f1-b410-806e6f6e6963}',
    '{469011d0-a872-11f1-bb02-ea6b3138fbbe}',
    '{b8f7edf7-ceaf-11f1-b411-806e6f6e6963}'
  )
  $moved=@($newId) + $real
  try { Assert-FirmwareOrderKeepsWindows -Identifiers $moved }
  catch { Fail ('the guard refused a legal firmware order: ' + $_.Exception.Message) }
  if($moved.Count -ne ($real.Count + 1)){Fail 'the promoted firmware order lost an entry'}
  if($moved[0] -ne $newId){Fail 'the promoted firmware order does not start with the unlock image'}
  if($moved -notcontains '{bootmgr}'){Fail 'the promoted firmware order dropped the Windows boot manager'}
}
Check 'the firmware order parser keeps positions and lowercases identifiers' {
  $text=@(
    'Firmware Boot Manager'
    '--------------------'
    'identifier              {fwbootmgr}'
    'displayorder            {93DC5615-D0F2-11F1-B41F-18C04D0C6177}'
    '                        {bootmgr}'
    '                        {389ada0e-ce4b-11f1-b410-806e6f6e6963}'
    'timeout                 2'
  ) -join "`r`n"
  $order=Get-BootOrder $text   # do not wrap in @(): it returns a non-enumerated array
  if($order.Count -ne 3){Fail ("expected 3 firmware entries, got {0}" -f $order.Count)}
  if($order[0] -ne '{93dc5615-d0f2-11f1-b41f-18c04d0c6177}'){Fail ("position 0 is {0}" -f $order[0])}
  if($order[1] -ne '{bootmgr}'){Fail ("position 1 is {0}" -f $order[1])}
}

Write-Host ''
if($script:failed -gt 0) {
  Write-Host ("FAILED {0} of {1} automatic-policy checks" -f $script:failed,($script:passed+$script:failed))
  exit 1
}
Write-Host ("PASS {0} automatic-policy checks" -f $script:passed)
exit 0


