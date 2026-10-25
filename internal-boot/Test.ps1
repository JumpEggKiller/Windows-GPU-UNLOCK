[CmdletBinding()]
param(
  [string]$Clang = 'clang',
  [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
# Deliberately no Set-StrictMode: it would be inherited by the child suites invoked
# below, and the unlock suite is written for the default mode (strict mode makes one of
# its textual audit helpers throw on a null match). Each suite is judged by its exit
# code, which is what this wrapper checks.

$here = $PSScriptRoot
$failed = New-Object System.Collections.ArrayList

function Section([string]$Title) {
  Write-Host ''
  Write-Host ('=== {0} ===' -f $Title)
}

Section 'internal-boot host tests: device paths, flow, end-of-batch record'
try {
  & (Join-Path $here 'boot\run-tests.ps1') -Clang $Clang
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('boot host tests') }
} catch {
  Write-Host ('FAIL boot host tests: {0}' -f $_.Exception.Message)
  [void]$failed.Add('boot host tests')
}

Section 'internal-boot host tests: installer boot policy'
try {
  & (Join-Path $here 'install\test-automatic-policy.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('installer boot policy') }
} catch {
  Write-Host ('FAIL installer boot policy: {0}' -f $_.Exception.Message)
  [void]$failed.Add('installer boot policy')
}

Section 'internal-boot source audit'
try {
  & (Join-Path $here 'boot\audit.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('source audit') }
} catch {
  Write-Host ('FAIL source audit: {0}' -f $_.Exception.Message)
  [void]$failed.Add('source audit')
}

# The unlock child's own suite is the proven multi-target one; run it too so a change
# here cannot silently break the transaction it drives.
Section 'unlock child: local test suite'
try {
  & (Join-Path $here '..\unlock\run-local-tests.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('unlock local tests') }
} catch {
  Write-Host ('FAIL unlock local tests: {0}' -f $_.Exception.Message)
  [void]$failed.Add('unlock local tests')
}

Write-Host ''
if ($failed.Count -gt 0) {
  Write-Host ('FAILED GROUPS: {0}' -f ($failed -join ', '))
  exit 1
}
Write-Host 'ALL INTERNAL-BOOT SOFTWARE TESTS PASSED'
exit 0
