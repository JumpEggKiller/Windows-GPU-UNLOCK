# internal-boot: unattended three-card unlock, then Windows, in one boot

This tree turns the proven multi-target unlock child into a bootable handoff: firmware
starts one small EFI application from a dedicated ESP, that application verifies and
runs the unlock child in the same boot, proves from a durable record that every card
unlocked and kept its state, and only then starts the Windows Boot Manager directly.
No reset, no USB stick, no keyboard authorization.

It is an adaptation of the upstream `internal-boot` work in
<https://github.com/impacifist/Windows-GPU-UNLOCK> to this specific machine.

**Running this on a different machine: see [ADOPT-RIG.md](ADOPT-RIG.md).** It is the
agent-facing procedure for a fresh rig: inventory, one read-only probe boot, pin
generation (`unlock\pins-from-report.ps1`), build, stage, manual test, then the
firmware boot order. It also states the three limits (card family, per-machine PROM
pin, display card) and every value that still has to be regenerated per machine.

## What is different from upstream

| upstream | this tree | why |
| --- | --- | --- |
| one RTX 3090 at `01:00.0` | four cards: `41:00.0`, `81:00.0`, `C1:00.0`, and `01:00.0` last | the rig has four GM102 cards and all four are unlocked; the display adapter carries an explicit, gated exception |
| AMD iGPU owns the console | ASPEED BMC GOP + the card at `01:00.0` own the console | there is no AMD iGPU on this board, so the upstream GOP-release stage would blank the operator console |
| `full-release.c` detaches the RTX display driver and restores decode bits | not ported at all | the console lives on the card that must stay untouched; per-card driver release already happens inside the transaction |
| profile pin: ASUS TUF B650M, BIOS 3057 | profile pin: GIGABYTE MZ32-AR0-00, BIOS `M31` | `Configure.ps1` refuses any other board |
| one `U` keypress authorizes one card | no keypress; an automatic batch authorization with a 3 second Esc cancel window | unattended boot, and a missing keyboard must not block it |
| unlock success is the child's return code | unlock success is a `HANDOFF.ST` record that the wrapper parses and cross-checks | a return code is not evidence that the cards are still unlocked at the end of the batch |
| unlock child must run from USB | unlock child may run from an internal ESP, and in automatic mode only from the configured internal ESP | the whole point is to boot from disk |

`GPU0` (`01:00.0`) is the display adapter and the only card allowed to own a GOP of its own.
That is not a blanket relaxation: its row is the single row carrying
`DisplayMaySitOnTargetGop`, `GuTargetTableCheck` refuses a second such row, and `DisplayCheck`
still refuses any GOP sitting on a target BDF for every other card and still refuses GPU0
unless a second physical GOP (the ASPEED one) survives - so "unlock the only display path on
this machine" stays impossible. GPU0 also runs last, so the console can never take an earlier
card's log with it: every step is in the file log, which does not depend on the console.

## The two EFI layers

```
firmware boot entry
  └─ AUTO.EFI or MANUAL.EFI            wrapper: device-path policy, log, handoff flow
       ├─ verifies hash of  ─────────── UNLOCK.EFI / UNLOCK-AUTO.EFI   child: the unlock
       ├─ StartImage(child)             transaction, per-card gates, per-card retention
       ├─ reads HANDOFF.ST              durable end-of-batch record written by the child
       └─ StartImage(bootmgfw.efi)      Windows Boot Manager, no reset, no IO in between
```

The wrapper never re-opens the child between hashing it and calling `StartImage`, so the
bytes that were verified are the bytes that execute. `bootmgfw.efi` is loaded by device
path from the Windows ESP; that filesystem is never mounted by this code.

The record is one line, `GUH1 <16 hex status> <eligible> <unlocked> <retained> <clean>`,
written by the child into `\RTX3090-UNLOCK\HANDOFF.ST` on the dedicated ESP. The child
deletes any previous record when it starts a run, so a stale success cannot authorize a
later boot. The wrapper starts Windows only if the record parses, the status is zero,
`eligible` equals the compiled-in expected card count, and `unlocked == retained ==
clean == eligible`. A rig that lost a card and unlocked only what it found is refused.

### The wrapper is a Windows *boot application*, not an EFI application

The arrow at the top of that diagram is drawn by the Windows boot manager, not by firmware:
firmware starts `bootmgfw.efi`, and bootmgfw reads the BCD entry and starts the wrapper. Its
PE loader is stricter than the firmware's. A plain EFI application (subsystem 10, image base
0, ASLR/NX placement flags) is rejected with `0xC000007B` before a single instruction runs,
which is what the first Gate C attempt produced on `\EFI\Windows GPUUnlock\MANUAL.EFI`.

The reference the build now copies is `memtest.efi`, the one image on this machine that the
boot manager does start from a BCD entry: `IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION` (16),
image base `0x140000000`, `DllCharacteristics` zero. `boot\build.ps1` links the wrapper at
that base with no placement flags and `boot\boot-application.py` writes the subsystem value,
because lld-link has no name for 16; `unlock\verify_pe.py --boot-application` then enforces
the shape on the built file, and `boot\run-tests.ps1` proves both directions (a wrapper
passes, the subsystem 10 child fails).

Only the wrappers change. The child stays a normal EFI application because firmware and the
wrapper's own `LoadImage` start it, and firmware ignores the subsystem value — so the same
`MANUAL.EFI` still loads if it ever has to be started from a USB firmware entry instead.

## Prerequisites

- a **separate** FAT32 ESP of at least 1 GiB, not the Windows ESP, mountable as a letter
- Secure Boot off
- `C:` fully decrypted with BitLocker protection off (the installer never changes this)
- the firmware order still has `{bootmgr}` first, and the Windows Boot Manager menu keeps
  `{current}` with a non-zero timeout, before anything is registered
- `..\deps\edk2` present, LLVM/clang + lld-link on hand, Python 3

## Where the entry goes

The unlock image becomes an **application entry inside the Windows Boot Manager's own
menu** — the same mechanism `{memdiag}` uses: `bcdedit /copy {bootmgr}`, then
`device partition=<dedicated ESP>:` and `path \EFI\WindowsGPUUnlock\MANUAL.EFI`.

This is deliberate. `bcdedit /set {fwbootmgr} displayorder …` can only reorder NVRAM
entries the firmware itself created; Windows has no supported way to create a firmware
entry for a file on an arbitrary partition. The Windows menu route needs no NVRAM write,
is reversed by ordinary `bcdedit` commands, and — because `{current}` stays in the order
and the timeout is set to five seconds for automatic boot — leaves a local window in which
a person can still choose Windows without any tooling. The firmware order is only
*checked*: if `{bootmgr}` is not first, the Windows menu is never reached and the
installer refuses to arm. A zero timeout is refused for the same reason.

### Automatic boot is the firmware's order, not a Windows menu row

Three cold boots established the limit of the other route: the Windows boot manager refuses an
image built here with `0xC000007B` (plain EFI application), then `0xC0000221` (subsystem 16
without a checksum), then `0xC0000428` (`数字签名`/untrusted signature). The same bytes run
without complaint when the **firmware** loads them, which is how the first successful run
(Gate C, four cards, `HANDOFF.ST` = `GUH1 0000000000000000 4 4 4 4`) happened.

So the unattended trigger is the firmware order:

```
bcdedit /set {entry} path \EFI\WindowsGPUUnlock\AUTO.EFI
bcdedit /set {entry} description "Windows GPU UNLOCK Auto"
bcdedit /set {fwbootmgr} displayorder {entry} {bootmgr} <the rest, unchanged>
```

`Set-FirmwareOrder` refuses an order that does not list `{bootmgr}` (`the machine could then not
start Windows at all`) and reads every position back, because a silently truncated order is the
one failure that costs the machine. Nothing else is touched: the Windows menu's own
`default`/`displayorder`/`timeout` stay as they are, because the firmware decides before any
Windows code runs. `-EnableFirmwareBoot` is therefore the automatic step on this machine, and
`-EnableAutomaticBoot` is kept only as a documented dead end with `Get-AutomaticArmed` still
proving that menu position alone is never enough.

### The `default` entry, and why it is not what runs here

`displayorder` orders the Windows menu; what an untouched power-on starts after the timeout is
that manager's **`default`**. `-EnableAutomaticBoot` writes exactly that,
`bcdedit /set {bootmgr} default {entry}` plus `displayorder {entry} {current}`, `timeout 5` and
`HiberbootEnabled = 0`, and `Get-AutomaticArmed` (in `install\automatic-policy.ps1`) is the only
place that decides "armed" — it returns the reasons when it is not, so neither the promotion nor
`-Check` can conclude "armed" from menu position alone, and there is a regression test for that
mistake. This path is unusable on this rig only because the boot manager cannot load the image.

The 5 s menu timeout is what makes both halves possible where the menu does apply: long enough
for a person to press a key and pick Windows, short enough that an unattended power-on is not
waiting. A second, independent escape hatch exists inside the image itself: the wrapper waits
5 s for Esc before starting the child, and the child waits 3 s for Esc before touching any card.
Esc at either point starts Windows without unlocking anything.

## Install sequence

Every command is read-only until `-RegisterManual`. Nothing reboots, ever.

```powershell
# 0. inventory the disks (writes nothing)
.\Configure.ps1 -List

# 1. pin the two partitions into boot\platform-config.h
.\Configure.ps1 -UnlockDriveLetter S -WindowsEspGuid '{ade68b7e-ced7-408a-b149-027482c08207}'

# 2. build both layers; the child hash is baked into each wrapper
.\Build.ps1 -Clang <clang.exe> -LldLink <lld-link.exe> -Python <python.exe>

# 3. prove the whole thing is safe to install (writes nothing)
.\Install.ps1 -Check

# 3b. read the entire boot-configuration change before approving it (writes nothing)
.\Install.ps1 -Plan

# 4. inspect the exact file tree before installing it anywhere
.\Install.ps1 -LocalStage D:\stage -Assets <dir with the five firmware assets>

# 5. stage onto the dedicated ESP only; boot order stays exactly as it is
.\Install.ps1 -Assets <dir>

# 6. register the manual entry; Windows stays first and stays the default
.\Install.ps1 -RegisterManual

# 7. only after the manual boot succeeded on real hardware; this also moves the boot default
.\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
```

`-Development` writes placeholder GUIDs so the build pipeline can be exercised without a
real ESP. A build made that way announces itself on the console and `-Check` blocks it.

`-Plan` prints every command the later steps would run, with the values this machine would
use, and touches nothing at all: `install\test-plan.ps1` compares the BCD store and the
partition table before and after to prove it. It exists so the change can be reviewed without
running any of it.

`install\rehearse-bcd.ps1` goes one step further: it exports the live store into a scratch
hive under `%TEMP%` and runs the *whole* change against that copy with real `bcdedit` —
copy, attribute, point at the ESP, place behind Windows, promote, restore, delete — including
three injected faults, then re-exports the live store and proves it is byte-identical. The
commands are therefore proven, not just printed, and the live boot configuration is still
untouched.

## Recovery

```powershell
.\Install.ps1 -RestoreWindowsFirst
```

Restores the boot **default** first (from the saved `BootDefaultBefore`, else from the verbose
`bootmgr-before.txt` backup, else keeps the current one only if it is not the unlock entry),
then the Windows Boot Manager menu to `{current}` first (the created entry is kept behind it so
the manual test entry survives), the saved menu timeout and Fast Startup value, and re-points
the created entry at the manual image. It then verifies that Windows is first **and that the
unlock entry is not the default**, and fails loudly if either is wrong. It needs no working EFI
image and no matching entry name, and deletes nothing. The installer also writes
`recovery-plan.json` next to every BCD backup in
`%ProgramData%\WindowsGPUUnlock\Backups\<timestamp>\`, together with `enum-before.txt`,
`bootmgr-before.txt`, `firmware-before.txt`, the full BCD export and the partition map from
before the change.

Five-second path with no tooling at all: power-cycle, let the Windows menu appear, press a key
and choose the Windows entry — or let the unlock image start and press Esc inside its own
3-second cancel window, which starts Windows without unlocking. Both the menu and the firmware
order keep Windows available on purpose.

If a boot fails, the wrapper stops and prints what to do; it never retries, never resets
and never forces Windows. Power-cycle and pick Windows from the boot menu, then run
`-RestoreWindowsFirst` to put the menu back the way it was.

## Logs (dedicated ESP)

| path | written by |
| --- | --- |
| `\RTX3090-UNLOCK\BOOTnn.TXT` | automatic wrapper, one file per boot |
| `\RTX3090-UNLOCK\FULLnn.TXT` | manual wrapper |
| `\RTX3090-UNLOCK\AUTO000000\` | automatic child run directory |
| `\RTX3090-UNLOCK\RUNnn\` | manual child run directory |
| `\RTX3090-UNLOCK\HANDOFF.ST` | the end-of-batch record between the two layers |
| `\RTX3090-UNLOCK\ASSETS\` | the five firmware assets, hash-checked at install |

A console fault can no longer kill a log: the wrapper treats console output as best
effort and the file log as authoritative.

## Tests

```powershell
.\Test.ps1 -Clang <clang.exe>
```

Runs the wrapper's host tests (device-path policy, handoff flow fault injection,
end-of-batch record policy), the PE shape checks on the images that are actually staged
(a wrapper must be a boot application, the child must not be), the installer's boot-policy
tests against recorded `bcdedit` output (including the "first in the menu is not armed"
regression), the installer plan test, the boot-store rehearsal, the staged-set check, the
source audit, and the unlock child's own suite.

## Status

Software side complete: both layers build reproducibly, every host suite passes, the
installed set was pinned to the real dedicated ESP (`S:`, `{7c5be0d5-…}`) and staged onto it,
and `-Check` reports READY with no blocked prerequisite.

One real boot has been attempted. It proved the route — the Windows boot manager resolved the
entry to `S:\EFI\WindowsGPUUnlock\MANUAL.EFI` — and it failed there with `0xC000007B`, before
any of this code ran, because the wrapper was still a plain EFI application. The wrappers are
now linked as boot applications (see above) and re-staged; that shape has **not** been
confirmed on real firmware yet. Physical acceptance (manual selection, then one cold boot,
then a second cold boot) remains the last step.
