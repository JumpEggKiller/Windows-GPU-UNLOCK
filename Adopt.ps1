#requires -Version 5.1
<#
.SYNOPSIS
  One entry point for adopting the unlock on THIS machine: nine steps, of which the
  script does seven and you do two (boot the probe stick, cold boot once by hand).

.DESCRIPTION
  Every step is resumable. The script keeps its place in adopt-state.json, never
  reboots, never writes a boot entry without -Yes, and refuses to skip a step.

      .\Adopt.ps1                 show where you are and what to do next (EN + 中文)
      .\Adopt.ps1 -Next           do the next step that the script can do itself
      .\Adopt.ps1 -All            keep doing safe steps until one needs you
      .\Adopt.ps1 -Next -Yes      also allow the two steps that change boot config
      .\Adopt.ps1 -Restore        put Windows back first, delete nothing
      .\Adopt.ps1 -SelfTest       prove the decision logic without touching hardware

  The two steps a script cannot do:
    * step 2 - boot the probe stick once (read-only; it unlocks nothing)
    * step 7 - cold shutdown, power on, pick the unlock entry from the firmware menu

.PARAMETER Next
  Perform the next automatable step, then stop.

.PARAMETER All
  Perform safe steps in a loop until a step needs a human, then print the instruction.

.PARAMETER Status
  Print the current step (same as running with no arguments).

.PARAMETER Restore
  Restore Windows-first boot. Deletes nothing, reboots nothing.

.PARAMETER SelfTest
  Run the pure-logic checks (state, record parsing, step ordering). No disk or BCD writes.

.PARAMETER Yes
  Allow the two steps that write boot configuration: -RegisterManual and
  -EnableFirmwareBoot. Pass this only after the human agreed.

.PARAMETER Assets
  Folder holding the five firmware assets named in unlock\assets.json. Remembered in
  the state file after the first time.

.PARAMETER UnlockDriveLetter
  Letter of the dedicated ESP (>= 1 GiB, FAT32, NOT the Windows ESP). Remembered.

.PARAMETER WindowsEspGuid
  GUID of the Windows (IsSystem) ESP. Detected automatically when omitted.

.PARAMETER ProbeReport
  Path to the probe report if it cannot be found on the probe stick automatically.

.PARAMETER ProbeDrive
  Letter of the stick the probe was written to (default: the single removable FAT32
  volume present).

.EXAMPLE
  .\Adopt.ps1 -Next
.EXAMPLE
  .\Adopt.ps1 -Assets 'D:\nvidia-assets' -UnlockDriveLetter S -Next -All
#>
[CmdletBinding()]
param(
  [switch]$Next,
  [switch]$All,
  [switch]$Status,
  [switch]$Restore,
  [switch]$SelfTest,
  [switch]$Yes,
  [string]$Assets,
  [string]$UnlockDriveLetter,
  [string]$WindowsEspGuid,
  [string]$ProbeReport,
  [string]$ProbeDrive,
  [string]$Clang,
  [string]$LldLink,
  [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$stateFile = Join-Path $repo 'adopt-state.json'
$builtin = Join-Path $repo 'internal-boot'
$unlock = Join-Path $repo 'unlock'

# ---------------------------------------------------------------- step catalogue
# Order matters: each step may only run when the previous one finished.
$STEP_ORDER = @(
  'check',        # 1 read-only environment gate
  'probe-build',  # 2 build the read-only probe and put it on a stick  (then: boot it)
  'pins',         # 3 turn the probe report into the final card table
  'configure',    # 4 pin the ESP identity for this machine
  'build',        # 5 build the four images
  'stage',        # 6 copy them plus the assets onto the dedicated ESP
  'register',     # 7 register the boot entry                       (needs -Yes)
  'manual',       # 8 one cold boot by hand, then verify from disk  (then: verify)
  'arm',          # 9 firmware tries the unlock image first         (needs -Yes)
  'verify'        # 10 prove the unattended boot actually unlocked
)

$WHAT = @{
  'check'       = @('read-only environment gate', '只读环境检查')
  'probe-build' = @('build the read-only probe and copy it to a USB stick', '构建只读探针并写入U盘')
  'pins'        = @('generate this machine''s card table from the probe report', '用探针报告生成本机卡表')
  'configure'   = @('pin the dedicated ESP identity for this machine', '登记本机专用ESP身份')
  'build'       = @('build four images (two children, two wrappers)', '构建四个镜像')
  'stage'       = @('copy images and firmware assets onto the ESP', '把镜像和固件资产写入ESP')
  'register'    = @('register the boot entry (boot order stays Windows-first)', '注册启动项（启动顺序仍Windows优先）')
  'manual'      = @('one manual cold boot; verify the result from the ESP', '一次手动冷启动并从ESP核对结果')
  'arm'         = @('let the firmware try the unlock image before Windows', '让固件先跑解锁镜像再进Windows')
  'verify'      = @('prove the unattended boot unlocked every card', '验证无人值守启动确实解锁了每张卡')
}

function Say([string]$En, [string]$Zh = '') {
  Write-Host ('  ' + $En)
  if ($Zh) { Write-Host ('  ' + $Zh) }
}

function Step-Number([string]$Name) {
  $i = [array]::IndexOf($STEP_ORDER, $Name)
  if ($i -lt 0) { return '?' }
  ($i + 1).ToString() + '/' + $STEP_ORDER.Count
}

# The stage a machine is really in, read from what the installer and the ESP already prove.
# Used only when adopt-state.json is absent, so an already-adopted machine is never reported
# as untouched. Never writes.
function Get-DerivedStage {
  $result = [pscustomobject]@{ Step = ''; Count = 0; EntryId = ''; ManualVerified = $false; Armed = $false; UnlockDriveLetter = '' }
  $configPath = Join-Path $repo 'internal-boot\local-config.json'
  $installPath = Join-Path $repo 'internal-boot\install\state.json'
  $letter = ''
  # The pinned card count is what the unlock acts on, so it is what a record is judged against.
  $tablePath = Join-Path $repo 'unlock\targets_local.h'
  if (Test-Path -LiteralPath $tablePath) {
    $result.Count = @(Select-String -LiteralPath $tablePath -Pattern 'GU_CARD\(' -AllMatches).Count
  }
  if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $letter = [string]$config.UnlockDriveLetter
    $result.UnlockDriveLetter = $letter
    $result.Step = 'build'
  }
  if (Test-Path -LiteralPath $installPath) {
    $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
    $result.EntryId = [string]$install.EntryId
    if ($install.Mode -eq 'firmware-first') {
      $result.Armed = $true
      $result.ManualVerified = $true
      $result.Step = 'verify'
    } elseif ($install.EntryId) {
      $result.Step = 'manual'
    }
    if ($letter -and -not $result.ManualVerified) {
      $root = $letter.TrimEnd(':') + ':\RTX3090-UNLOCK'
      if (Test-Path -LiteralPath $root) {
        if (@(Get-ChildItem -LiteralPath $root -Filter 'FULL*.TXT' -File -ErrorAction SilentlyContinue).Count -gt 0) {
          $result.ManualVerified = $true
          $result.Step = 'arm'
        }
      }
    }
  }
  if (-not $result.Step) { $result.Step = 'check' }
  return $result
}

function Read-State {
  if (-not (Test-Path -LiteralPath $stateFile)) {
    $fresh = [pscustomobject]@{ Step = 'check'; Cards = @(); Count = 0; Assets = ''; UnlockDriveLetter = ''; WindowsEspGuid = '';
      ProbeReport = ''; ProbeDrive = ''; EntryId = ''; ManualVerified = $false; Armed = $false; History = @(); UpdatedUtc = '' }
    # A machine that is already set up must not be reported as untouched: the evidence on disk
    # decides the stage, not the absence of this file. Nothing is written by reading.
    if ($script:Derived) {
      $fresh.Step = $script:Derived.Step
      $fresh.Count = [int]$script:Derived.Count
      $fresh.EntryId = [string]$script:Derived.EntryId
      $fresh.ManualVerified = [bool]$script:Derived.ManualVerified
      $fresh.Armed = [bool]$script:Derived.Armed
      $fresh.UnlockDriveLetter = [string]$script:Derived.UnlockDriveLetter
    }
    return $fresh
  }
  $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
  foreach ($k in 'Cards', 'History') { if ($null -eq $s.$k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue @() -Force } }
  return $s
}

function Write-State($State) {
  $State.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
  $json = $State | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText($stateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Advance($State, [string]$Step, [string]$Note) {
  $State.Step = $Step
  $State.History = @($State.History) + @([pscustomobject]@{ Utc = [DateTime]::UtcNow.ToString('o'); Step = $Step; Note = $Note })
  Write-State $State
  Say ("step done: " + $Step) ("步骤完成：" + $Step)
}

function Get-ToolPath([string]$Explicit, [string]$Name) {
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath $Explicit)) { throw ("$Name not found: " + $Explicit) }
    return $Explicit
  }
  $local = Join-Path $repo ("tools\clang+llvm-23.1.4-x86_64-pc-windows-msvc\bin\" + $Name)
  if (Test-Path -LiteralPath $local) { return $local }
  return $Name   # hope it is on PATH
}

function Invoke-Step([string]$Script, [string[]]$Arguments, [string]$Label) {
  Write-Host ('  > ' + $Label)
  & $Script @Arguments
  if ($LASTEXITCODE -ne 0) { throw ("$Label failed (exit $LASTEXITCODE)") }
}

# ---------------------------------------------------------------- inventory facts
function Get-GpuInventory {
  $raw = & nvidia-smi --query-gpu=index,pci.bus_id,pci.device_id,pci.sub_device_id,name,display_active --format=csv,noheader 2>&1
  if ($LASTEXITCODE -ne 0) { throw ('nvidia-smi failed: ' + ($raw | Out-String).Trim()) }
  $cards = @()
  foreach ($line in @($raw)) {
    if (-not $line -or $line -notmatch ',') { continue }
    $f = $line -split ','
    if ($f.Count -lt 6) { continue }
    $idw = [Convert]::ToInt32(($f[2].Trim() -replace '^0x', ''), 16)
    $cards += [pscustomobject]@{
      Index = [int]$f[0].Trim(); Bdf = $f[1].Trim().ToLowerInvariant()
      Device = ($idw -shr 16) -band 0xffff; Vendor = $idw -band 0xffff
      Subsystem = $f[3].Trim().ToLowerInvariant(); Name = $f[4].Trim()
      Display = ($f[5].Trim() -eq 'Enabled')
    }
  }
  if (-not $cards) { throw 'nvidia-smi reported no GPUs' }
  return $cards
}

function Get-RemovableFat32 {
  @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
      $_.DriveType -eq 'Removable' -and $_.FileSystem -eq 'FAT32' -and $_.DriveLetter
    } | Sort-Object DriveLetter)
}

function Get-SystemEspGuid {
  $esp = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object {
      $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and $_.IsSystem
    })
  if ($esp.Count -ne 1) { throw ("expected exactly one IsSystem ESP, found {0}" -f $esp.Count) }
  return ('{' + ([string]$esp[0].Guid).Trim('{', '}').ToLowerInvariant() + '}')
}

function Get-VolumePath([string]$Letter) {
  $v = Get-Volume -DriveLetter ($Letter.TrimEnd(':')) -ErrorAction SilentlyContinue
  if (-not $v) { throw ("volume " + $Letter + " not found") }
  return ($Letter.TrimEnd(':') + ':\')
}

# Parse the durable end-of-batch record. Pure: same rules as boot/record.h.
function Read-HandoffRecord([string]$Text) {
  if ($null -eq $Text) { return $null }
  $t = ($Text -replace "`r", '').TrimEnd("`n")
  if ($t -notmatch '^GUH1 ([0-9a-f]{16}) (\d{1,10}) (\d{1,10}) (\d{1,10}) (\d{1,10})$') { return $null }
  if ($t -ne $t.ToLowerInvariant()) { $t = $t.ToLowerInvariant() }
  $m = [regex]::Match($t, '^GUH1 ([0-9a-f]{16}) (\d{1,10}) (\d{1,10}) (\d{1,10}) (\d{1,10})$')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{
    Status = [uint64]::Parse($m.Groups[1].Value, [Globalization.NumberStyles]::HexNumber)
    Eligible = [uint32]$m.Groups[2].Value; Unlocked = [uint32]$m.Groups[3].Value
    Retained = [uint32]$m.Groups[4].Value; Clean = [uint32]$m.Groups[5].Value
    Raw = $m.Value
  }
}

function Test-HandoffClean($Record, [int]$Expected) {
  if ($null -eq $Record) { return 'no end-of-batch record on the ESP (HANDOFF.ST missing or unreadable)' }
  if ($Record.Status -ne 0) { return ("the record says the batch failed: status=0x{0:x16}" -f $Record.Status) }
  if ($Record.Eligible -ne $Expected) { return ("the record covers {0} cards, this machine has {1}" -f $Record.Eligible, $Expected) }
  if ($Record.Unlocked -ne $Record.Eligible) { return ("{0} of {1} cards unlocked" -f $Record.Unlocked, $Record.Eligible) }
  if ($Record.Retained -ne $Record.Unlocked) { return ("{0} of {1} unlocked cards kept their state" -f $Record.Retained, $Record.Unlocked) }
  if ($Record.Clean -ne $Record.Retained) { return ("{0} of {1} cards read back clean" -f $Record.Clean, $Record.Retained) }
  return ''
}

# ---------------------------------------------------------------- the steps
function Step-Check($State) {
  Say 'Read-only checks. Nothing is written here.' '只读检查，这一步不写任何东西。'
  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'run this from an elevated PowerShell (Administrator)'
  }
  $cards = Get-GpuInventory
  foreach ($c in $cards) {
    if ($c.Vendor -ne 0x10de) { throw ("{0} is not an NVIDIA card" -f $c.Name) }
    if ($c.Device -ne 0x2204) {
      throw ("{0} is device 0x{1:x4}; this profile only covers RTX 3090 (0x2204). Stop here - a different VBIOS/GFW family needs its own profile." -f $c.Name, $c.Device)
    }
  }
  if ($cards.Count -gt 4) { throw ("{0} cards found; this build pins at most 4" -f $cards.Count) }
  if ($cards.Count -ne @($cards | ForEach-Object { $_.Bdf } | Sort-Object -Unique).Count) { throw 'two cards report the same PCI address' }
  try { if (Confirm-SecureBootUEFI) { throw 'Secure Boot is ON. Turn it off in the firmware setup first.' } } catch [System.PlatformNotSupportedException] { }
  $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
  if ($bl -and ($bl.VolumeStatus -ne 'FullyDecrypted' -or $bl.ProtectionStatus -ne 'Off')) {
    throw ("C: is {0} / protection {1}; decrypt it and suspend protection first" -f $bl.VolumeStatus, $bl.ProtectionStatus)
  }
  $board = (Get-CimInstance Win32_BaseBoard).Product
  $bios = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
  Say ("cards: {0}  ({1})" -f $cards.Count, (($cards | ForEach-Object { $_.Bdf + $(if ($_.Display) { '*' } else { '' }) }) -join ' ')) `
      ("显卡：{0} 张（* 为显示卡）" -f $cards.Count)
  Say ("board {0} / BIOS {1} - the installer must be told to accept it: edit `$profile in internal-boot\Configure.ps1 if this is your first run" -f $board, $bios) `
      ("主板 {0} / BIOS {1} —— 首次运行需要在 internal-boot\Configure.ps1 的 `$profile 里写入这两个值" -f $board, $bios)
  $State.Cards = @($cards | ForEach-Object { [pscustomobject]@{ Bdf = $_.Bdf; Subsystem = $_.Subsystem; Display = $_.Display } })
  $State.Count = $cards.Count
  Advance $State 'probe-build' ('{0} cards, board {1} BIOS {2}' -f $cards.Count, $board, $bios)
}

function Step-ProbeBuild($State) {
  Say 'Generating the probe card table (PROM pins stay empty on purpose).' '生成探针卡表（PROM 引脚故意留空）。'
  $backup = Join-Path $repo 'unlock\targets_local.h.before-adopt'
  if ((Test-Path -LiteralPath (Join-Path $unlock 'targets_local.h')) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath (Join-Path $unlock 'targets_local.h') -Destination $backup -Force
    Say ("original card table saved as {0}" -f $backup) ("原卡表已备份为 {0}" -f $backup)
  }
  Invoke-Step (Join-Path $unlock 'pins-from-report.ps1') @('-Inventory', '-OutFile', (Join-Path $unlock 'targets_local.h')) 'generate probe table'
  $clang = Get-ToolPath $Clang 'clang.exe'
  $lld = Get-ToolPath $LldLink 'lld-link.exe'
  Invoke-Step (Join-Path $unlock 'build.ps1') @('-Clang', $clang, '-LldLink', $lld, '-Python', $Python) 'build read-only preflight EFI'
  $efi = Join-Path $unlock 'build\RTX3090-PREFLIGHT.EFI'
  if (-not (Test-Path -LiteralPath $efi)) { throw ("build did not produce " + $efi) }

  $sticks = Get-RemovableFat32
  if ($ProbeDrive) { $sticks = @([pscustomobject]@{ DriveLetter = $ProbeDrive.TrimEnd(':') }) }
  if ($sticks.Count -eq 1) {
    $root = $sticks[0].DriveLetter + ':\'
    $dir = Join-Path $root 'EFI\BOOT'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    Copy-Item -LiteralPath $efi -Destination (Join-Path $dir 'BOOTX64.EFI') -Force
    $State.ProbeDrive = $sticks[0].DriveLetter
    Say ("probe written to {0}EFI\BOOT\BOOTX64.EFI" -f $root) ("探针已写入 {0}EFI\BOOT\BOOTX64.EFI" -f $root)
  } else {
    Say ("no single removable FAT32 stick found; copy this file yourself to <stick>\EFI\BOOT\BOOTX64.EFI :" ) '没找到唯一的FAT32移动盘；请手动把下面这个文件复制成 <U盘>\EFI\BOOT\BOOTX64.EFI'
    Say ("  " + $efi)
    Say 'or pass -ProbeDrive E' '或用 -ProbeDrive E 指定盘符'
  }
  Advance $State 'pins' 'probe built; PHYSICAL: boot the stick once, then run -Next'
  Say '' ''
  Say 'NEXT (human): boot the stick from the firmware boot menu, wait for it to return to firmware, then boot Windows normally and run:  .\Adopt.ps1 -Next' `
      '下一步（需要人）：在固件启动菜单里选U盘，等它自己退回固件，然后正常进Windows并运行： .\Adopt.ps1 -Next'
}

function Step-Pins($State) {
  $report = $ProbeReport
  if (-not $report) {
    $roots = @()
    if ($State.ProbeDrive) { $roots += ($State.ProbeDrive + ':\RTX3090-UNLOCK') }
    foreach ($s in (Get-RemovableFat32)) { $roots += ($s.DriveLetter + ':\RTX3090-UNLOCK') }
    $cand = @()
    foreach ($r in ($roots | Sort-Object -Unique)) {
      $cand += @(Get-ChildItem -Path (Join-Path $r 'RUN*\REPORT.TXT') -ErrorAction SilentlyContinue)
    }
    if ($cand.Count -eq 0) { throw 'no probe report found on any stick; pass -ProbeReport <path>' }
    $report = ($cand | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
  }
  Say ("probe report: " + $report) '探针报告：'
  Invoke-Step (Join-Path $unlock 'pins-from-report.ps1') @('-ProbeReport', $report, '-OutFile', (Join-Path $unlock 'targets_local.h')) 'generate final card table from the probe'
  $State.ProbeReport = $report
  Advance $State 'configure' 'final card table generated'
}

function Step-Configure($State) {
  $letter = if ($UnlockDriveLetter) { $UnlockDriveLetter } else { $State.UnlockDriveLetter }
  if (-not $letter) {
    $cands = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object {
        $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and -not $_.IsSystem -and $_.Size -ge 1GB
      })
    $withLetter = @($cands | Where-Object { $_.DriveLetter })
    if ($cands.Count -eq 1 -and $withLetter.Count -eq 1) { $letter = [string]$withLetter[0].DriveLetter }
    else {
      Say 'A dedicated ESP is required: >= 1 GiB, FAT32, NOT the Windows ESP.' '需要一个专用 ESP：至少 1 GiB、FAT32、且不是 Windows 的 ESP。'
      Say 'Existing candidates:' '现有候选分区：'
      foreach ($c in $cands) { Say ("  disk {0} part {1}  {2:N1} GiB  letter={3}  guid={4}" -f $c.DiskNumber, $c.PartitionNumber, ($c.Size / 1GB), ($(if ($c.DriveLetter) { $c.DriveLetter } else { '<none>' })), $c.Guid) }
      Say 'Create one (Disk Management or diskpart), assign a letter, then re-run with -UnlockDriveLetter <letter>.' '请先创建并分配盘符，然后用 -UnlockDriveLetter <盘符> 重跑。'
      throw 'no dedicated ESP with a drive letter'
    }
  }
  $guid = if ($WindowsEspGuid) { $WindowsEspGuid } else { Get-SystemEspGuid }
  $volume = Get-VolumePath $letter
  $size = (Get-Volume -DriveLetter ($letter.TrimEnd(':'))).SizeRemaining
  if ($size -lt 200MB) { throw ("{0} has only {1:N0} MB free; the images need ~90 MB plus the assets" -f $volume, ($size / 1MB)) }
  Invoke-Step (Join-Path $builtin 'Configure.ps1') @('-UnlockDriveLetter', $letter.TrimEnd(':'), '-WindowsEspGuid', $guid) 'pin the ESP identity'
  $State.UnlockDriveLetter = $letter.TrimEnd(':')
  $State.WindowsEspGuid = $guid
  Advance $State 'build' ('ESP {0} -> {1}' -f $State.UnlockDriveLetter, $guid)
}

function Step-Build($State) {
  $clang = Get-ToolPath $Clang 'clang.exe'
  $lld = Get-ToolPath $LldLink 'lld-link.exe'
  Invoke-Step (Join-Path $builtin 'Build.ps1') @('-Clang', $clang, '-LldLink', $lld, '-Python', $Python, '-ExpectedUnlocked', [string]$State.Count) 'build four images'
  Advance $State 'stage' 'four images built and verified'
}

function Step-Stage($State) {
  $assets = if ($Assets) { $Assets } elseif ($State.Assets) { $State.Assets } else { Join-Path $repo 'assets' }
  if (-not (Test-Path -LiteralPath $assets)) {
    Say 'The five firmware assets are not in this repository, and they are not downloadable from it.' '五个固件资产不在仓库里，也不能从这个仓库下载。'
    Say 'They are generated once, on Linux or WSL, from the pinned upstream source:' '它们要在 Linux 或 WSL 上，从上游固定提交生成一次：'
    Say '  git clone https://github.com/Zagitta/gpu-unlock.git' '  git clone https://github.com/Zagitta/gpu-unlock.git'
    Say '  git -C gpu-unlock checkout --detach 0ebdb1c6308b6a2072be5bf04513472942541956' '  git -C gpu-unlock checkout --detach 0ebdb1c6308b6a2072be5bf04513472942541956'
    Say '  cd gpu-unlock && make inputs firmware PYTHON=python3.14 INPUTS="$PWD/inputs" ASSETS="$PWD/assets"' '  cd gpu-unlock && make inputs firmware PYTHON=python3.14 INPUTS="$PWD/inputs" ASSETS="$PWD/assets"'
    Say 'Then copy the five .bin files from that assets folder here, or pass -Assets <dir>.' '然后把该 assets 目录里的五个 .bin 复制过来，或用 -Assets <dir> 指定。'
    Say 'unlock\assets.json holds the exact names, sizes and SHA-256; a mismatch is refused.' 'unlock\assets.json 里有确切的名字、大小和 SHA-256；不一致会被拒绝。'
    throw ("assets folder not found: " + $assets + " (pass -Assets <dir>)")
  }
  Invoke-Step (Join-Path $builtin 'Install.ps1') @('-Assets', $assets) 'stage images and assets onto the ESP'
  $State.Assets = $assets
  Advance $State 'register' 'staged; boot configuration still untouched'
}

function Step-Register($State) {
  if (-not $Yes) {
    Say 'This step writes a boot entry (a copy of the Windows boot manager). It changes no order and no default.' '这一步会写一个启动项（Windows 启动管理器的副本），不改顺序、不改默认项。'
    Say ('Run: .\Adopt.ps1 -Next -Yes    (after the human agreed)' ) '确认后运行： .\Adopt.ps1 -Next -Yes'
    return $false
  }
  $assets = if ($State.Assets) { $State.Assets } else { $Assets }
  Invoke-Step (Join-Path $builtin 'Install.ps1') @('-RegisterManual', '-Assets', $assets) 'register the boot entry'
  $st = Get-Content -LiteralPath (Join-Path $builtin 'install\state.json') -Raw | ConvertFrom-Json
  $State.EntryId = $st.EntryId
  Advance $State 'manual' ('entry ' + $st.EntryId)
  Say '' ''
  Say ("NEXT (human): one-shot firmware boot of the unlock entry, then a cold boot:" ) '下一步（需要人）：一次性固件引导到解锁项，再冷启动：'
  Say ("  bcdedit /set {fwbootmgr} bootsequence " + $st.EntryId)
  Say '  full shutdown (not restart), power on, pick nothing - it boots the entry by itself' '  完全关机（不是重启），再开机，不要按键——它会自动进解锁项'
  Say '  expect a short banner, then Windows. Then run: .\Adopt.ps1 -Next' '  期待出现一行横幅后进入Windows，然后运行： .\Adopt.ps1 -Next'
  return $true
}

function Step-Manual($State) {
  if (-not $State.UnlockDriveLetter) { throw 'no ESP letter in the state; re-run the configure step' }
  $root = $State.UnlockDriveLetter + ':\RTX3090-UNLOCK'
  $full = @(Get-ChildItem -Path (Join-Path $root 'FULL*.TXT') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
  if ($full.Count -eq 0) {
    Say 'No manual-run log on the ESP: the image has not run yet.' 'ESP 上没有手动运行日志：镜像还没跑过。'
    Say ('Do this now: bcdedit /set {fwbootmgr} bootsequence ' + $State.EntryId + '  then full shutdown and power on') '现在执行：上面的 bootsequence 命令，然后完全关机再开机'
    return $false
  }
  $rec = Read-HandoffRecord ((Get-Content -LiteralPath (Join-Path $root 'HANDOFF.ST') -Raw -ErrorAction SilentlyContinue))
  $problem = Test-HandoffClean $rec $State.Count
  if ($problem) {
    Say ("the manual boot did not pass: " + $problem) '手动这次没有通过：'
    Say ('read ' + $full[-1].FullName + ' and ' + (Join-Path $root 'RUN00\REPORT.TXT')) '请读上面两个文件（FULL 日志和 RUN 报告）'
    Say 'recover with: .\Adopt.ps1 -Restore' '恢复命令： .\Adopt.ps1 -Restore'
    return $false
  }
  Say ("manual boot passed: record " + $rec.Raw) '手动这次通过：留痕 ' 
  $State.ManualVerified = $true
  Advance $State 'arm' ('manual record ' + $rec.Raw)
  return $true
}

function Step-Arm($State) {
  if (-not $State.ManualVerified) { throw 'refusing to arm before a manual boot has been verified' }
  if (-not $Yes) {
    Say 'This step rewrites the firmware boot order so the unlock image runs before Windows.' '这一步会改固件启动顺序，让解锁镜像先于Windows运行。'
    Say 'It keeps Windows reachable behind it, and -Restore undoes it.' 'Windows 仍在其后可选，-Restore 可还原。'
    Say 'Run: .\Adopt.ps1 -Next -Yes' '确认后运行： .\Adopt.ps1 -Next -Yes'
    return $false
  }
  $assets = if ($State.Assets) { $State.Assets } else { $Assets }
  Invoke-Step (Join-Path $builtin 'Install.ps1') @('-EnableFirmwareBoot', '-ConfirmedManualSuccess', '-Assets', $assets) 'arm the firmware order'
  $State.Armed = $true
  Advance $State 'verify' 'firmware order armed'
  Say '' ''
  Say 'NEXT (human): full shutdown, power on, let it boot unattended, then run .\Adopt.ps1 -Next' '下一步（需要人）：完全关机→开机→不干预，然后运行 .\Adopt.ps1 -Next'
  return $true
}

function Step-Verify($State) {
  $root = $State.UnlockDriveLetter + ':\RTX3090-UNLOCK'
  $auto = @(Get-ChildItem -Path (Join-Path $root 'AUTO00*\REPORT.TXT') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
  if ($auto.Count -eq 0) {
    Say 'No automatic run log yet.' '还没有自动运行日志。'
    Say 'Do a full shutdown + power on, wait for Windows, then run: .\Adopt.ps1 -Next' '完全关机再开机，等进入Windows后运行： .\Adopt.ps1 -Next'
    return $false
  }
  $tail = Get-Content -LiteralPath $auto[-1].FullName | Select-String -Pattern '^batch summary|^FINAL\(multi\)' | ForEach-Object { $_.Line.Trim() }
  $rec = Read-HandoffRecord ((Get-Content -LiteralPath (Join-Path $root 'HANDOFF.ST') -Raw -ErrorAction SilentlyContinue))
  $problem = Test-HandoffClean $rec $State.Count
  if ($problem) {
    Say ("the unattended boot did not pass: " + $problem) '无人值守这次没有通过：'
    Say ('report: ' + $auto[-1].FullName) '报告：'
    Say 'recover with: .\Adopt.ps1 -Restore' '恢复命令： .\Adopt.ps1 -Restore'
    return $false
  }
  Say 'DONE. Every cold boot now: unlock all cards, prove it, then start Windows.' '完成。从现在起每次冷启动：解锁所有卡→留痕→进Windows。'
  Say ("record " + $rec.Raw) ('留痕：' + $rec.Raw)
  foreach ($l in $tail) { Say ('  ' + $l) }
  Say '' ''
  Say 'If Windows ever must start instead: press a key at the firmware boot menu and pick Windows Boot Manager.' '若需改为启动Windows：在固件启动菜单按键，选 Windows Boot Manager。'
  Say 'From Windows: .\Adopt.ps1 -Restore' '在Windows里也可以： .\Adopt.ps1 -Restore'
  Advance $State 'verify' ('verified ' + $rec.Raw)
  return $true
}

# ---------------------------------------------------------------- driver
function Show-Status($State) {
  $step = $State.Step
  Write-Host ''
  Write-Host ('  ADOPT STATE / 当前阶段: {0} ({1})' -f (Step-Number $step), $step)
  Write-Host ('  {0}' -f $WHAT[$step][0])
  Write-Host ('  {0}' -f $WHAT[$step][1])
  Write-Host ''
  Say ("cards {0}; ESP {1}; entry {2}; manual {3}; armed {4}" -f $State.Count, $(if ($State.UnlockDriveLetter) { $State.UnlockDriveLetter + ':' } else { '-' }), $(if ($State.EntryId) { $State.EntryId } else { '-' }), $State.ManualVerified, $State.Armed) `
      ("卡 {0} 张；ESP {1}；启动项 {2}；手动已验证 {3}；已固化 {4}" -f $State.Count, $(if ($State.UnlockDriveLetter) { $State.UnlockDriveLetter + ':' } else { '-' }), $(if ($State.EntryId) { $State.EntryId } else { '-' }), $State.ManualVerified, $State.Armed)
  $idx = [array]::IndexOf($STEP_ORDER, $step)
  Write-Host ''
  for ($i = 0; $i -lt $STEP_ORDER.Count; $i++) {
    $mark = if ($i -lt $idx) { 'done ' } elseif ($i -eq $idx) { ' ->  ' } else { '     ' }
    Write-Host ('  {0}{1,2}. {2,-12} {3}' -f $mark, ($i + 1), $STEP_ORDER[$i], $WHAT[$STEP_ORDER[$i]][0])
  }
  Write-Host ''
  Say 'Next: .\Adopt.ps1 -Next' '下一步： .\Adopt.ps1 -Next'
}

function Invoke-OneStep($State) {
  switch ($State.Step) {
    'check'       { Step-Check $State; return $true }
    'probe-build' { Step-ProbeBuild $State; return $false }   # needs a physical USB boot
    'pins'        { Step-Pins $State; return $true }
    'configure'   { Step-Configure $State; return $true }
    'build'       { Step-Build $State; return $true }
    'stage'       { Step-Stage $State; return $true }
    'register'    { return (Step-Register $State) }
    'manual'      { return (Step-Manual $State) }
    'arm'         { return (Step-Arm $State) }
    'verify'      { return (Step-Verify $State) }
    default       { throw ("unknown step '" + $State.Step + "' in " + $stateFile) }
  }
}

# ---------------------------------------------------------------- self test
function Invoke-SelfTest {
  $bad = 0
  function T([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host ('PASS ' + $Name) } catch { Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message); $script:bad++ }
  }
  T 'a clean record is accepted' {
    $r = Read-HandoffRecord "GUH1 0000000000000000 4 4 4 4`n"
    if ((Test-HandoffClean $r 4) -ne '') { throw 'expected clean' }
  }
  T 'a failed status is refused' {
    $r = Read-HandoffRecord 'GUH1 800000000000000f 4 4 4 0'
    if ((Test-HandoffClean $r 4) -eq '') { throw 'expected refusal' }
  }
  T 'a partial batch is refused' {
    $r = Read-HandoffRecord 'GUH1 0000000000000000 4 3 3 3'
    if ((Test-HandoffClean $r 4) -eq '') { throw 'expected refusal' }
  }
  T 'a card count mismatch is refused' {
    $r = Read-HandoffRecord 'GUH1 0000000000000000 3 3 3 3'
    $three = Test-HandoffClean $r 3
    if ($three -ne '') { throw ('expected clean for 3, got: ' + $three) }
    if ((Test-HandoffClean $r 4) -eq '') { throw 'expected refusal for 4' }
  }
  T 'garbage is refused, not guessed' {
    foreach ($t in @('', 'GUH1', 'GUH2 0000000000000000 4 4 4 4', 'GUH1 0000000000000000 4 4 4', 'guh1 0000000000000000 4 4 4 4')) {
      if ($null -ne (Read-HandoffRecord $t)) { throw ('accepted garbage: ' + $t) }
    }
  }
  T 'the step order is the one the state machine walks' {
    if ($STEP_ORDER.Count -ne 10) { throw 'unexpected step count' }
    if ($STEP_ORDER[0] -ne 'check' -or $STEP_ORDER[-1] -ne 'verify') { throw 'unexpected endpoints' }
  }
  T 'every step has a bilingual description' {
    foreach ($s in $STEP_ORDER) { if (-not $WHAT.ContainsKey($s)) { throw ('missing description for ' + $s) } }
  }
  if ($script:bad -gt 0) { Exit 1 }
  Write-Host 'PASS adopt decision logic: the state machine, the record parser and every refusal'
  Exit 0
}

# ---------------------------------------------------------------- main
if ($SelfTest) { Invoke-SelfTest; return }

$script:Derived = Get-DerivedStage
$state = Read-State
if ($Assets) { $state.Assets = $Assets }
if ($UnlockDriveLetter) { $state.UnlockDriveLetter = $UnlockDriveLetter.TrimEnd(':') }

if ($Restore) {
  Say 'Restoring Windows-first boot. Nothing is deleted and nothing reboots.' '恢复 Windows 优先启动，不删除任何东西、不重启。'
  Invoke-Step (Join-Path $builtin 'Install.ps1') @('-RestoreWindowsFirst') 'restore Windows-first boot'
  $state.Armed = $false
  Write-State $state
  Say 'Windows is first again. The unlock entry and its files are kept.' 'Windows 已回到第一位，解锁启动项和文件都保留。'
  exit 0
}

if (-not $Next -and -not $All) { Show-Status $state; exit 0 }

$guard = 0
$stepped = $false
$keepGoing = $true
while ($true) {
  $guard++
  if ($guard -gt 20) { throw 'step loop did not converge' }
  $before = $state.Step
  $state = Read-State                 # re-read: a step may have written it
  if ($state.Step -eq 'verify' -and (Test-Path -LiteralPath $stateFile)) {
    $done = ($state.History | Where-Object { $_.Note -like 'verified *' })
    if ($done) { Say 'already verified; nothing to do' '已经验证过，无需操作'; exit 0 }
  }
  Write-Host ''
  Write-Host ('  STEP {0}  {1}' -f (Step-Number $state.Step), $state.Step)
  $keepGoing = Invoke-OneStep $state
  $stepped = $true
  if (-not $All) { break }
  if (-not $keepGoing) { break }
  if ($state.Step -eq $before) { break }
}
Show-Status (Read-State)
# A step that reported failure must be visible to whatever is driving this, not just to a human
# reading the screen: a wrapper that always exits 0 teaches an agent to ignore failures.
if ($stepped -and -not $keepGoing) { exit 1 }
exit 0
