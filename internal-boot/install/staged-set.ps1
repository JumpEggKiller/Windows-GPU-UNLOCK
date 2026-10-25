# Staged-set bookkeeping: what is already on a volume, compared with what would be installed.
# Kept in its own file so Install.ps1 and the host test read the same code: the test points it
# at a scratch tree, the installer at the dedicated ESP.

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Compares the staged tree against the build outputs and the asset manifest. Pure read; every
# difference is returned as a sentence rather than thrown, so the caller can report them all.
function Get-StagedStatus {
  param(
    [Parameter(Mandatory)][string]$Root,
    [object[]]$Files = @(),
    [object[]]$AssetSpec = @()
  )
  $ok=0
  $total=0
  $problems=@()
  foreach($file in $Files) {
    $total++
    $path=Join-Path $Root $file.Relative
    if(!(Test-Path -LiteralPath $path)){$problems+=('Not staged on the dedicated ESP: {0}' -f $file.Relative)}
    elseif((Get-Sha256 $path) -ne ([string]$file.Sha256).ToLowerInvariant()){$problems+=('Staged file is older than the build: {0}' -f $file.Relative)}
    else {$ok++}
  }
  foreach($entry in $AssetSpec) {
    $total++
    $path=Join-Path $Root ('RTX3090-UNLOCK\ASSETS\'+$entry.Name)
    if(!(Test-Path -LiteralPath $path)){$problems+=('Asset not staged: {0}' -f $entry.Name)}
    elseif((Get-Sha256 $path) -ne ([string]$entry.Sha256).ToLowerInvariant()){$problems+=('Staged asset is older than the manifest: {0}' -f $entry.Name)}
    else {$ok++}
  }
  return [pscustomobject]@{Ok=$ok;Total=$total;Problems=$problems}
}
