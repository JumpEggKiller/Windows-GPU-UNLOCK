# A Windows PowerShell 5.1 script that contains non-ASCII characters is decoded as ANSI unless it
# starts with a UTF-8 byte order mark, so every Chinese literal becomes mojibake and can even break
# the parser. That failure is silent in an editor and loud only when a stranger runs the script.
# This checks the whole tree instead: any .ps1 holding non-ASCII bytes must carry the mark.
param([string]$Repository = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$failures = 0
function Fail([string]$Message) { Write-Host ('FAIL ' + $Message); $script:failures++ }
function Check([string]$Title, [scriptblock]$Body) {
  try { & $Body; Write-Host ('PASS ' + $Title) } catch { Fail ($Title + ': ' + $_.Exception.Message) }
}

function Test-File([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $nonAscii = $false
  foreach ($b in $bytes) { if ($b -gt 0x7F) { $nonAscii = $true; break } }
  return [pscustomobject]@{ HasBom = $hasBom; NonAscii = $nonAscii }
}

Check 'every non-ASCII PowerShell script in the tree carries a UTF-8 byte order mark' {
  $scripts = @(Get-ChildItem -LiteralPath $Repository -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notmatch '\\deps\\' -and $_.FullName -notmatch '\\tools\\clang' })
  if ($scripts.Count -lt 10) { throw ('only found ' + $scripts.Count + ' scripts; the scan is not looking at the tree') }
  $missing = @()
  foreach ($s in $scripts) {
    $state = Test-File $s.FullName
    if ($state.NonAscii -and -not $state.HasBom) { $missing += $s.FullName.Substring($Repository.Length).TrimStart('\') }
  }
  if ($missing.Count -gt 0) {
    throw ('non-ASCII but no BOM (Windows PowerShell 5.1 will read them as ANSI): ' + ($missing -join ', '))
  }
}

Check 'a genuinely non-ASCII script without a mark is detected, so the check cannot pass by accident' {
  $probe = Join-Path $env:TEMP ('bom-probe-' + [guid]::NewGuid().ToString('n') + '.ps1')
  # Built from code points so this file itself stays pure ASCII and never needs the mark it checks for.
  $body = "Write-Host 'kaishi'  # " + [string][char]0x5F00 + [string][char]0x59CB
  try {
    [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding($false)))
    $state = Test-File $probe
    if (-not $state.NonAscii) { throw 'the probe file was not seen as non-ASCII' }
    if ($state.HasBom) { throw 'the probe file was written with a BOM, so the case proves nothing' }
    [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding($true)))
    if (-not (Test-File $probe).HasBom) { throw 'the rewrite did not add a BOM' }
  } finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
}

if ($failures -gt 0) { Write-Host ('FAILED: ' + $failures + ' encoding checks'); exit 1 }
Write-Host 'PASS script encoding: every bilingual script is readable by Windows PowerShell 5.1'
exit 0
