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
  $order=Get-FirmwareOrder $firmware
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
  Expect { Get-FirmwareOrder $bad } 'repeats an identifier'
}
Check 'a missing displayorder is refused' {
  Expect { Get-FirmwareOrder 'Firmware Boot Manager' } 'no displayorder'
}
Check 'an empty displayorder is refused' {
  Expect { Get-FirmwareOrder "identifier              {fwbootmgr}`r`ndisplayorder            `r`ntimeout 1" } 'displayorder'
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

Write-Host ''
if($script:failed -gt 0) {
  Write-Host ("FAILED {0} of {1} automatic-policy checks" -f $script:failed,($script:passed+$script:failed))
  exit 1
}
Write-Host ("PASS {0} automatic-policy checks" -f $script:passed)
exit 0

