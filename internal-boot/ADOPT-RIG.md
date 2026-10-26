# Adopting this on your own machine

This document is written for an **agent** (or a careful human) who has a Windows
machine with one or more NVIDIA 30-series cards and wants the same end state this
repository's `local-rig-internal-boot` branch reaches on its author's machine:

```
power on
  -> firmware starts EFI\WindowsGPUUnlock\AUTO.EFI from a dedicated ESP
  -> it detects and verifies every pinned card, unlocks them, proves the result
     with a durable end-of-batch record
  -> it starts the Windows boot manager directly (no reset)
  -> Windows boots normally, driver initialises the cards
```

Nothing here flashes a VBIOS. The unlock is re-applied on every cold boot and is
destroyed by power loss, exactly like the upstream project's behaviour.

**Read the three limits before you start.** They are not negotiable and they are
the reason this cannot be a single downloadable installer:

1. **Card family.** The stock profile shipped here is `entryLatchedSs1Full`,
   measured on RTX 3090 (device `0x2204`, VBIOS `94.02.*`, GFW `0x8b8f`). A card
   with a different VBIOS/GFW family will be *refused* by the cold-state gate, not
   damaged. Supporting another family is research work (a new profile), not a
   configuration change.
2. **Identity is per machine.** The unlock gates on each card's PCI address,
   subsystem id, `config[0xc8]` and a 1 MiB PROM SHA-256. The last one can only be
   read from the card itself, so every machine needs one read-only probe boot
   before it can build its unlock image.
3. **The display card is special.** If one of the unlocked cards is the card your
   console is on, releasing its firmware driver can blank the UEFI console. This
   build survives that (it logs to disk, not the screen) and puts that card last,
   but you should expect a dark screen for a few seconds and you must not power
   off during that window.

---

## Phase 0 - inventory (read-only, Windows)

Run these in an elevated PowerShell. They change nothing.

```powershell
# PCI address, device id, subsystem id, which card drives the display
nvidia-smi --query-gpu=index,pci.bus_id,pci.device_id,pci.sub_device_id,name,display_active `
           --format=csv,noheader

# the exact card count this build will pin
(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' }).Count
```

Record: the number of cards, each `seg:bus:dev.fun`, each subsystem id, and which
one reports `display_active=Enabled`.

**Stop if** any card's `pci.device_id` is not `0x220410DE` (RTX 3090). The profile
is pinned to that VBIOS/GFW family.

Also confirm, because the installer enforces it:

```powershell
Confirm-SecureBootUEFI                                   # must be False
(Get-BitLockerVolume -MountPoint 'C:').VolumeStatus       # must be FullyDecrypted
(Get-CimInstance Win32_BaseBoard).Product                 # record it
(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion            # record it
```

---

## Phase 1 - probe build, booted from USB

The probe is the **preflight** build: read-only, no unlock code, no write to any
GPU. It scans the cards listed in `unlock\targets_local.h` and logs what it sees.
Because the table is empty of PROM pins at this stage, it logs each card's
measured hash instead of gating on it.

```powershell
# 1. generate a probe table for THIS machine (empty PROM pins)
.\unlock\pins-from-report.ps1 -Inventory -OutFile .\unlock\targets_local.h

# 2. build the preflight EFI (read-only)
.\unlock\build.ps1 -Clang  <path>\clang.exe `
                   -LldLink <path>\lld-link.exe
#    -> unlock\build\RTX3090-PREFLIGHT.EFI

# 3. put it on a FAT32 USB stick as the removable-media default path
#    (the repository ships tools\prepare_usb.py for exactly this)
```

Boot the stick from the firmware boot menu. It writes
`<usb>\RTX3090-UNLOCK\RUNnn\REPORT.TXT` and returns to firmware; nothing is
unlocked and nothing on the machine is modified.

**Stop if** the report does not contain one block per card. A card that is missing
from the report is a card that will never be unlocked.

---

## Phase 2 - final pins and images

```powershell
# generate the final table from what the probe measured
.\unlock\pins-from-report.ps1 -ProbeReport E:\RTX3090-UNLOCK\RUN00\REPORT.TXT `
                              -OutFile .\unlock\targets_local.h
```

The script refuses to write a partial table: every card from the inventory must
have exactly one PROM hash. It also puts the display card **last** in execution
order and grants only that row the display exception.

Then configure the ESP identity and build all four images:

```powershell
# S: = your dedicated ESP (>= 1 GiB, FAT32, NOT the Windows ESP)
.\internal-boot\Configure.ps1 -UnlockDriveLetter S `
                             -WindowsEspGuid '{<guid of the IsSystem ESP>}'

.\internal-boot\Build.ps1 -Clang  <path>\clang.exe `
                          -LldLink <path>\lld-link.exe `
                          -ExpectedUnlocked <card count>
```

`Build.ps1` builds, in order: manual child, automatic child, manual wrapper,
automatic wrapper, and verifies each child's manifest (mode, arming policy,
expected card count, image hash) before it bakes the hash into the wrapper.

`Configure.ps1` refuses to run unless the board and BIOS match the values in its
profile. **On your machine you must edit that profile** - it is the one deliberate
anti-accident pin in the installer (see "What is still rig-specific" below).

---

## Phase 3 - install, then one manual test

```powershell
# stage only: writes files to S:, changes no boot configuration
.\internal-boot\Install.ps1 -LocalStage .\internal-boot\build\local-stage   # dry run into a folder
.\internal-boot\Install.ps1 -Assets <dir with the five firmware assets>

# register the boot entry (still: Windows first, Windows default)
.\internal-boot\Install.ps1 -RegisterManual -Assets <same dir>

# readiness, read-only
.\internal-boot\Install.ps1 -Check
```

`-RegisterManual` copies the Windows boot manager entry and points the copy at
`\EFI\WindowsGPUUnlock\MANUAL.EFI` on your ESP. It does **not** change the boot
order or the default. It also creates a firmware-visible boot option, which is
what Phase 4 uses.

Test it **once, by hand**, with a one-shot firmware boot sequence (it clears
itself, so a failure cannot loop):

```powershell
bcdedit /set {fwbootmgr} bootsequence {<EntryId from install\state.json>}
# then: full shutdown and power on - NOT a restart
```

Expected: a short console banner `Windows GPU UNLOCK internal MANUAL handoff.`,
then Windows. The truth is on the disk, not the screen:

```
S:\RTX3090-UNLOCK\FULL00.TXT      entry / internal-handoff-v1 / windows-preloaded /
                                 unlock-start / unlock-return / windows-start /
                                 handoff-record   (all status=0)
S:\RTX3090-UNLOCK\HANDOFF.ST      GUH1 0000000000000000 <n> <n> <n> <n>
S:\RTX3090-UNLOCK\RUN00\REPORT.TXT  status[k] ... unlocked=1 retained=1 clean=1
```

**Stop if** `HANDOFF.ST` is missing or any count differs from your card count.
The wrapper will have printed `HANDOFF STOPPED.` and refused to start Windows -
by design. Recover with `-RestoreWindowsFirst` and read the report.

---

## Phase 4 - automatic

```powershell
.\internal-boot\Install.ps1 -EnableFirmwareBoot -ConfirmedManualSuccess -Assets <same dir>
```

Three changes, all verified by reading them back: the entry's path becomes
`AUTO.EFI`, its description becomes `Windows GPU UNLOCK Auto`, and the **firmware
display order** is rewritten so that entry is tried before the Windows boot
manager. The Windows menu order, its default entry and its timeout are untouched -
`{current}` stays first there, so a human can still pick Windows from the menu.

Why the firmware order and not the Windows menu: the Windows boot manager only
starts images that carry a signature it trusts. It answered `0xC000007B`,
`0xC0000221` and finally `0xC0000428` (invalid image hash) to the same bytes the
firmware loads without complaint. `-EnableAutomaticBoot` (Windows-menu based) is
kept in the tree as a documented dead end.

Then verify the end state:

```powershell
.\internal-boot\Install.ps1 -Check      # expects: firmware starts {entry} first
# full shutdown, power on, wait
Get-Content S:\RTX3090-UNLOCK\BOOT00.TXT
Get-Content S:\RTX3090-UNLOCK\AUTO000000\REPORT.TXT -Tail 8
```

Do it twice. The second boot is the repeatability gate: the reports should differ
only in per-boot entropy (cold selectors, addresses, timings), never in the
`status[...]` lines, `batch summary` or `FINAL(multi)`.

---

## Recovery, in ascending order of effort

| Situation | Do this |
|---|---|
| Machine is sitting at `HANDOFF STOPPED.` | Power off with the button. Nothing was unlocked past the failure; the batch never returns success on a partial result. |
| Windows must boot but you have no tooling | Power on, open the firmware boot menu (F8/F11/Del at POST), pick `Windows Boot Manager`. The firmware order keeps it as the second entry forever. |
| You are in Windows and want it back | `.\internal-boot\Install.ps1 -RestoreWindowsFirst` - restores firmware order, Windows menu order, timeout and Fast Startup, and re-points the entry at `MANUAL.EFI`. It deletes nothing and does not reboot. |
| You want the whole thing gone | `-RestoreWindowsFirst`, then `bcdedit /delete {<EntryId>}` and delete `S:\EFI\WindowsGPUUnlock` and `S:\RTX3090-UNLOCK`. |

Each `-RegisterManual` / `-EnableFirmwareBoot` writes a timestamped backup under
`C:\ProgramData\WindowsGPUUnlock\Backups\` (`bcd-export`, `enum-before.txt`,
`bootmgr-before.txt`, `firmware-before.txt`, `partitions-before.txt`) plus, at
promotion, a `recovery-plan.json`.

---

## What is still rig-specific (and what your agent must regenerate)

| Item | Where | How it is handled on a new machine |
|---|---|---|
| Card list, BDF, subsystem, PROM hash, display card | `unlock\targets_local.h` | **Generated** by `unlock\pins-from-report.ps1` (Phase 1 + 2). Card count is detected, not declared. |
| Board / BIOS pin | `internal-boot\Configure.ps1` (`$profile`) | **You must edit it** to your own `Win32_BaseBoard.Product` and `Win32_BIOS.SMBIOSBIOSVersion`. It exists so a build cannot silently run on the wrong machine. |
| Dedicated ESP guid | `internal-boot\boot\platform-config.h`, written by `Configure.ps1` | Generated per machine. `Configure.ps1` validates it against the real partition table. |
| Expected card count | `internal-boot\Build.ps1 -ExpectedUnlocked` | Pass your Phase 0 count. The manifest check refuses a mismatch. |
| VBIOS / GFW stock profile | `unlock\vendor\`, `-StockProfile` | **Not generalisable.** `entryLatchedSs1Full` is the only family measured here. Another family needs its own profile and its own hardware test. |
| Console assumption | `unlock\targets_local.h` header, `GU_DISPLAY_LOG_ONLY` | Handled by the display exception + "display card last"; the firmware console GOP may be an ASPEED BMC (as here) or the card itself. |

---

## Rules an agent must not break

1. Never write the boot configuration before `-Check` is `READY`.
2. Never skip the manual test (`-RegisterManual` + one manual boot) before
   `-EnableFirmwareBoot`. The flag is literally named `-ConfirmedManualSuccess`
   because it must not be passed on a promise.
3. Never make a failed boot retry, reset or force Windows. Fail-stop is the safety
   property; a loop is how a machine becomes unbootable.
4. Never delete the original Windows ESP contents, the Windows boot manager or the
   recovery partition. Everything this project writes lives under
   `EFI\WindowsGPUUnlock\` and `RTX3090-UNLOCK\` on a dedicated ESP.
5. Never flash a VBIOS, and never remove the cold-state, PROM, BAR, ownership or
   display gates to "make it work".
6. Verify with disk evidence (`HANDOFF.ST`, `REPORT.TXT`), never with the console
   or the absence of an error screen.

---

## 中文速览

给中文读者的最短版本（细节以上面英文为准）：

1. 这不是一个可以"下载即用"的单文件。解锁要按照每台机器的真实身份放行：
   PCI 地址、subsystem、`config[0xc8]`、以及每张卡 1 MiB PROM 的 SHA-256。
   最后一项只能在卡上读，所以每台机器必须先用**只读探针**开机一次。
2. 三步走：`pins-from-report.ps1 -Inventory` 生成探针表 → U 盘启动探针 →
   `pins-from-report.ps1 -ProbeReport` 生成正式表 → `Build.ps1` 出四个 EFI。
3. 只支持 RTX 3090（`0x2204`，VBIOS `94.02.*`，GFW `0x8b8f`）这一族；
   别的型号会被冷状态闸门拒绝（拒绝，不是损坏），要支持得单独做 profile。
4. 自动启动的开关是**固件启动顺序**，不是 Windows 菜单：Windows 启动管理器会
   用 `0xC0000428`（数字签名）拒绝我们自己的镜像，而固件能直接加载同样的字节。
5. 验收看磁盘上的证据（`HANDOFF.ST`、`REPORT.TXT`），不看屏幕；屏幕在释放
   显示卡固件驱动时可能黑几秒，属正常。
6. 恢复顺序：`HANDOFF STOPPED.` → 按电源关机 → POST 菜单选 `Windows Boot Manager`
   → 进系统后 `Install.ps1 -RestoreWindowsFirst`。
