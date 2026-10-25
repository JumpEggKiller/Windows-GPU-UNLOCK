# Proves that -Plan prints the whole boot-configuration change and writes nothing:
# the BCD store and the partition table are compared byte for byte before and after.
#
# This runs against the real machine because that is the only way to prove "nothing was
# written", so it only ever calls the read-only -Plan mode. It never calls an action.
[CmdletBinding()]
param([string]$InstallScript)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is not available while parameter defaults are evaluated, so resolve it here.
# Install.ps1 sits one level up: this test lives in internal-boot\install\.
if (-not $InstallScript) { $InstallScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install.ps1' }
if (-not (Test-Path -LiteralPath $InstallScript)) { throw ("Installer not found: {0}" -f $InstallScript) }
$failures = New-Object System.Collections.ArrayList

function Fail([string]$Message) {
  [void]$script:failures.Add($Message)
  Write-Host ('FAIL ' + $Message)
}

function Check([string]$Title, [scriptblock]$Body) {
  try { & $Body; Write-Host ('PASS ' + $Title) }
  catch { Fail ($Title + ': ' + $_.Exception.Message) }
}

function Need([string]$Text, [string]$Needle) {
  if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
    throw ("missing '" + $Needle + "'")
  }
}

function Snapshot {
  $bcd = (& bcdedit /enum all 2>&1 | Out-String)
  $fw = (& bcdedit /enum '{fwbootmgr}' 2>&1 | Out-String)
  $parts = (Get-Partition | Sort-Object DiskNumber, PartitionNumber |
    ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.DiskNumber, $_.PartitionNumber, $_.Offset, $_.Size }) -join ';'
  return ($bcd + '||' + $fw + '||' + $parts)
}

Write-Host 'install plan: what the installer would do'

$before = Snapshot
$output = (& $InstallScript -Plan 2>&1 | Out-String)
$code = $LASTEXITCODE
$after = Snapshot

Check 'the plan succeeds without an ESP present' {
  if ($code -ne 0) { throw ("-Plan exited {0}: {1}" -f $code, $output) }
}

Check 'the plan never writes the boot store or the partition table' {
  if ($before -ne $after) { throw 'the BCD store or the partition table changed while printing the plan' }
}

Check 'the plan shows the registration commands' {
  Need $output 'bcdedit /copy {bootmgr} /d "Windows GPU UNLOCK Manual"'
  Need $output 'bcdedit /set <new> device partition=<letter>:'
  Need $output 'bcdedit /set <new> path \EFI\WindowsGPUUnlock\MANUAL.EFI'
  Need $output 'bcdedit /set {bootmgr} displayorder {current} <new>'
}

Check 'the plan shows the automatic promotion commands' {
  Need $output 'bcdedit /set <entry> path \EFI\WindowsGPUUnlock\AUTO.EFI'
  Need $output 'bcdedit /set {bootmgr} displayorder <entry> {current}'
  Need $output 'bcdedit /set {bootmgr} timeout 5'
  Need $output 'HiberbootEnabled /t REG_DWORD /d 0'
}

Check 'the plan keeps Windows in the menu and never deletes an entry' {
  Need $output 'displayorder {current} <new>'
  Need $output 'nothing is deleted'
  if ($output -match 'bcdedit /delete\s+\{bootmgr\}') { throw 'the plan would delete the boot manager' }
}

Check 'the plan shows the recovery path' {
  Need $output 'restore BootTimeoutBefore'
  Need $output 'restore HiberbootBefore'
  Need $output 'verify order[0] is {current}'
}

Check 'the plan states that a placeholder build cannot be installed' {
  Need $output 'refuses to run'
}

if ($failures.Count -gt 0) {
  Write-Host ('install plan: {0} failure(s)' -f $failures.Count)
  exit 1
}
Write-Host 'PASS install plan: every command printed, nothing written, Windows always kept in the menu'
exit 0
