# Host test for unlock\pins-from-report.ps1.
#
# The generator's whole value is that it refuses to produce a half-pinned table, so
# that is what this checks. It never writes targets_local.h: every case points the
# output at a temporary file and the script is expected to fail before writing.
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$generator = Join-Path (Split-Path -Parent $here) 'unlock\pins-from-report.ps1'
if (-not (Test-Path -LiteralPath $generator)) { throw ("generator not found: " + $generator) }

$script:failures = New-Object System.Collections.ArrayList
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pins-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp -Force)

function Check([string]$Title, [scriptblock]$Body) {
  try {
    & $Body
    Write-Host ('PASS {0}' -f $Title)
  } catch {
    Write-Host ('FAIL {0}: {1}' -f $Title, $_.Exception.Message)
    [void]$script:failures.Add($Title)
  }
}

function Expect-Failure([scriptblock]$Body, [string]$Fragment) {
  $threw = $false
  $message = ''
  try { & $Body } catch { $threw = $true; $message = $_.Exception.Message }
  if (-not $threw) { throw 'expected the generator to refuse, but it succeeded' }
  if ($message -notlike ('*' + $Fragment + '*')) { throw ("refused with the wrong reason: " + $message) }
}

try {
  # A report with no target blocks at all: the inventory still has cards, so the
  # generator must refuse rather than emit a table that pins nothing.
  $empty = Join-Path $temp 'empty-report.txt'
  Set-Content -LiteralPath $empty -Value @('nothing here', 'target-free') -Encoding ascii
  $out = Join-Path $temp 'from-empty.h'
  Check 'a report without a card block is refused' {
    Expect-Failure { & $generator -ProbeReport $empty -OutFile $out } 'refusing to write a partial pin table'
    if (Test-Path -LiteralPath $out) { throw 'the generator wrote a header despite refusing' }
  }

  Check 'a report without a card block names the missing address' {
    Expect-Failure { & $generator -ProbeReport $empty -OutFile $out } 'no probe block for'
  }

  # A card family the profile does not cover must stop the run, not be normalised away.
  Check 'an unsupported device family is refused before any write' {
    Expect-Failure { & $generator -Inventory -AllowDevice 0x2684 -OutFile (Join-Path $temp 'family.h') } 'needs its own stock profile'
  }

  # A missing report file is an error, not an empty result.
  Check 'a missing probe report is refused' {
    Expect-Failure { & $generator -ProbeReport (Join-Path $temp 'does-not-exist.txt') -OutFile $out } 'report not found'
  }

  # A malformed PCI address must be rejected rather than keyed weirdly.
  Check 'a malformed PCI address is refused' {
    $bad = Join-Path $temp 'bad-bdf.txt'
    Set-Content -LiteralPath $bad -Value @(
      'target[0] identity=0:zz:0.0 subsystem=0x14541b4c c8_pin=0x50011 prom_pin=absent allowed=1 note=-',
      'PROM sha256 (log-only, unverified): ' + ('a' * 64)
    ) -Encoding ascii
    Expect-Failure { & $generator -ProbeReport $bad -OutFile (Join-Path $temp 'bad.h') } 'cannot read a target identity line'
  }
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count -gt 0) {
  Write-Host ('FAILED: {0}' -f ($script:failures -join ', '))
  exit 1
}
Write-Host 'PASS pin generation: a partial or unsupported table is refused, never written'
exit 0
