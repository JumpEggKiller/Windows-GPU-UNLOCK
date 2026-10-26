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

Section 'internal-boot host tests: installer plan is read-only'
try {
  & (Join-Path $here 'install\test-plan.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('installer plan') }
} catch {
  Write-Host ('FAIL installer plan: {0}' -f $_.Exception.Message)
  [void]$failed.Add('installer plan')
}

Section 'internal-boot host tests: whole change rehearsed on a scratch boot store'
try {
  & (Join-Path $here 'install\rehearse-bcd.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('boot store rehearsal') }
} catch {
  Write-Host ('FAIL boot store rehearsal: {0}' -f $_.Exception.Message)
  [void]$failed.Add('boot store rehearsal')
}

Section 'internal-boot host tests: what is already staged on the ESP'
try {
  & (Join-Path $here 'install\test-staged.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('staged set') }
} catch {
  Write-Host ('FAIL staged set: {0}' -f $_.Exception.Message)
  [void]$failed.Add('staged set')
}

Section 'pin generation: a partial or unsupported card table is refused'
try {
  & (Join-Path $here '..\unlock\test-pins-from-report.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('pin generation') }
} catch {
  Write-Host ('FAIL pin generation: {0}' -f $_.Exception.Message)
  [void]$failed.Add('pin generation')
}

Section 'internal-boot source audit'
try {
  & (Join-Path $here 'boot\audit.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('source audit') }
} catch {
  Write-Host ('FAIL source audit: {0}' -f $_.Exception.Message)
  [void]$failed.Add('source audit')
}

# A bilingual script saved without a UTF-8 BOM is read as ANSI by Windows PowerShell 5.1,
# which turns every Chinese literal into mojibake and can break the parser outright. That is
# invisible in an editor and fatal for a stranger running the script, so it is checked.
Section 'script encoding: bilingual scripts stay readable by Windows PowerShell 5.1'
try {
  & (Join-Path $here 'install\test-encoding.ps1')
  if ($LASTEXITCODE -ne 0) { [void]$failed.Add('script encoding') }
} catch {
  Write-Host ('FAIL script encoding: {0}' -f $_.Exception.Message)
  [void]$failed.Add('script encoding')
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

