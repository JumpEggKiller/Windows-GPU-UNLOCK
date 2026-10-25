# Boot-entry bookkeeping for the installer. Three helpers, each of which is the only
# place a rule lives, so Install.ps1 cannot quietly skip a check.
#
#   1. Resolve-NewBootCopy   attribute exactly ONE new bcdedit entry to a name
#   2. Invoke-RecoveryActions  run every recovery action, then report all failures
#   3. Invoke-AutomaticTransition  do steps, verify, and roll back once on any fault
#
# Nothing here reboots, deletes a partition or touches a file on an ESP.

# Splits `bcdedit /enum` output into blocks, one per boot entry. A block starts at an
# `identifier` line and ends before the next one. Each entry is preceded by a title and
# a `-----` underline; the underline closes the previous block so the next entry's
# title cannot leak into it, which would make two copies of the same entry compare as
# different. Blank lines inside a block are kept because the comparison in
# Resolve-NewBootCopy must see the same text twice.
function Get-BootEntryBlocks([string]$Text) {
  if([string]::IsNullOrWhiteSpace($Text)){throw 'Empty boot enumeration'}
  $blocks=New-Object System.Collections.ArrayList
  $current=$null
  $close={ if($null -ne $current){[void]$blocks.Add($current);$current=$null} }
  foreach($line in ($Text -split "`r?`n")) {
    if($line -match '^\s*identifier\s+(\{[0-9a-zA-Z-]+\})\s*$') {
      & $close
      $current=[ordered]@{Identifier=$Matches[1].ToLowerInvariant();Lines=New-Object System.Collections.ArrayList}
      [void]$current.Lines.Add($line.Trim())
    } elseif($line -match '^-{3,}\s*$') {
      # The underline ends the previous entry's block.
      & $close
    } elseif([string]::IsNullOrWhiteSpace($line)) {
      if($null -ne $current){[void]$current.Lines.Add('')}
    } elseif($line -match '^\w+\s{2,}\S' -or $line -match '^\s{2,}\S') {
      # A field line or a continuation of one.
      if($null -ne $current){[void]$current.Lines.Add($line.TrimEnd())}
    } else {
      # A title such as `Windows Boot Manager` introduces the next entry, so it closes
      # this block instead of being compared as if it were one of this entry's fields.
      & $close
    }
  }
  & $close
  if($blocks.Count -eq 0){throw 'Boot enumeration contains no identifier'}
  return $blocks
}

# Boot identifiers in enumeration order, lower-case.
function Get-BootIdentifiers([string]$Text) {
  return @(Get-BootEntryBlocks $Text | ForEach-Object {$_.Identifier})
}

# The firmware boot order from `bcdedit /enum {fwbootmgr}`. Named identifiers such as
# {bootmgr} are not GUIDs, so match letters too or the entry that must stay first is
# silently dropped from the order.
function Get-FirmwareOrder {
  param([Parameter(Mandatory)][string]$Text)
  if($Text -notmatch '(?ms)^[ \t]*displayorder[ \t]+(.*?)(?=\r?\n\S|\z)'){
    throw 'The firmware boot manager has no displayorder; refusing to guess one'
  }
  $ids=@([regex]::Matches($Matches[1],'\{[0-9a-zA-Z-]+\}')|ForEach-Object {$_.Value.ToLowerInvariant()})
  if($ids.Count -eq 0){throw 'The firmware displayorder lists no identifiers'}
  if(($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'The firmware displayorder repeats an identifier'}
  return $ids
}

# Writes the firmware order, refusing to drop the Windows fallback.
function Set-FirmwareOrder {
  param([Parameter(Mandatory)][string[]]$Identifiers)
  if($Identifiers -notcontains '{bootmgr}'){
    throw 'Refusing to write a displayorder without {bootmgr}: that removes the Windows fallback'
  }
  $output=& bcdedit @(@('/set','{fwbootmgr}','displayorder') + $Identifiers) 2>&1
  if($LASTEXITCODE -ne 0){
    throw ("bcdedit /set {{fwbootmgr}} displayorder failed (exit {0}): {1}" -f $LASTEXITCODE,($output|Out-String).Trim())
  }
}

# The raw block for one identifier, or $null.
function Get-BootEntryBlock([string]$Text,[string]$Identifier) {
  $wanted=$Identifier.ToLowerInvariant()
  foreach($block in (Get-BootEntryBlocks $Text)) {
    if($block.Identifier -eq $wanted){return $block}
  }
  return $null
}

# One field of one entry (`description`, `path`, `device` ...), or $null.
function Get-BootEntryField([string]$Text,[string]$Identifier,[string]$Field) {
  $block=Get-BootEntryBlock $Text $Identifier
  if($null -eq $block){return $null}
  foreach($line in $block.Lines) {
    if($line -match ('^\s*' + [regex]::Escape($Field) + '\s+(.+?)\s*$')){return $Matches[1]}
  }
  return $null
}

# A block with the lines that legitimately differ between two copies of the same
# boot manager entry removed. This is what makes "is this a copy of {bootmgr}?"
# answerable without trusting the new entry's name alone.
function Get-BootEntryShape($Block) {
  $kept=New-Object System.Collections.ArrayList
  foreach($line in $Block.Lines) {
    if($line -match '^\s*(identifier|description)\s'){continue}
    if([string]::IsNullOrWhiteSpace($line)){continue}
    [void]$kept.Add($line)
  }
  return ($kept -join "`n")
}

# Attributes exactly one new boot copy to $Name. Throws unless:
#   * exactly one identifier appeared between the two enumerations
#   * its description is exactly $Name
#   * apart from identifier/description it matches the entry it was copied from
# Call it immediately after `bcdedit /copy` and before pointing the copy at our image:
# the shape comparison is what proves the copy really came from {bootmgr} rather than
# from firmware-written leftovers. The device and path are asserted afterwards, when
# they are supposed to differ.
function Resolve-NewBootCopy {
  param(
    [Parameter(Mandatory)][string]$BeforeText,
    [Parameter(Mandatory)][string]$AfterText,
    [Parameter(Mandatory)][string]$Name,
    [string]$SourceIdentifier='{bootmgr}'
  )
  $before=Get-BootIdentifiers $BeforeText
  $after=Get-BootIdentifiers $AfterText
  $added=@($after | Where-Object {$before -notcontains $_})
  if($added.Count -ne 1) {
    throw ("Cannot attribute one new boot copy; inspect firmware backup. New identifiers: {0}" -f ($added -join ', '))
  }
  $new=$added[0]
  $description=Get-BootEntryField $AfterText $new 'description'
  if($description -ne $Name) {
    throw ("New entry description differs: got '{0}', expected '{1}'" -f $description,$Name)
  }
  $source=Get-BootEntryBlock $AfterText $SourceIdentifier
  if($null -eq $source){throw ("The copy source {0} is missing from the enumeration" -f $SourceIdentifier)}
  $newShape=Get-BootEntryShape (Get-BootEntryBlock $AfterText $new)
  $sourceShape=Get-BootEntryShape $source
  if($newShape -ne $sourceShape) {
    throw 'New entry is not the expected boot-manager copy; its remaining fields differ from the source'
  }
  return $new
}

# An action is either a bare script block or an object with Name/Run fields (hashtable
# or [pscustomobject]); both shapes are used by the installer and by these tests.
function Get-ActionLabel($Action) {
  if($null -eq $Action){return ''}
  $property=$Action.PSObject.Properties['Name']
  if($null -eq $property){return ''}
  return [string]$property.Value
}

function Get-ActionScript($Action) {
  if($Action -is [scriptblock]){return $Action}
  $property=$Action.PSObject.Properties['Run']
  if($null -eq $property){throw 'An action has no Run script block'}
  return $property.Value
}

# Runs every action even when an earlier one fails, then reports all failures at once.
# Recovery must not stop half-way because of one bad step.
function Invoke-RecoveryActions {
  param([Parameter(Mandatory)][object[]]$Actions)
  $failures=New-Object System.Collections.ArrayList
  foreach($action in $Actions) {
    $label=Get-ActionLabel $action
    try {
      & (Get-ActionScript $action)
      if($label){Write-Host ("recovery: {0} ok" -f $label)}
    } catch {
      $message=("{0}{1}" -f $(if($label){"${label}: "}else{''}),$_.Exception.Message)
      [void]$failures.Add($message)
      Write-Warning ("recovery: {0} FAILED: {1}" -f $label,$_.Exception.Message)
    }
  }
  if($failures.Count -gt 0) {
    throw ('Recovery incomplete: ' + ($failures -join ' | '))
  }
}

# The one safe way to change boot state: run steps, verify the result, and if either
# step or verification throws, run the rollback actions once and rethrow the original
# error. Callers must make Verify re-read the real state; a step's return value is
# never treated as proof.
function Invoke-AutomaticTransition {
  param(
    [Parameter(Mandatory)][object[]]$Steps,
    [Parameter(Mandatory)][scriptblock]$Verify,
    [Parameter(Mandatory)][object[]]$Rollback
  )
  try {
    foreach($step in $Steps) {
      & (Get-ActionScript $step)
      $label=Get-ActionLabel $step
      if($label){Write-Host ("transition: {0}" -f $label)}
    }
    & $Verify
  } catch {
    $original=$_
    Write-Warning ("Transition failed: {0}" -f $original.Exception.Message)
    Write-Warning 'Rolling back.'
    try {
      Invoke-RecoveryActions -Actions $Rollback
    } catch {
      Write-Warning ("Rollback also failed: {0}" -f $_.Exception.Message)
      Write-Warning 'Restore Windows-first boot with -RestoreWindowsFirst, or use the firmware boot menu.'
    }
    throw $original
  }
}
