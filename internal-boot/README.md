# internal-boot: unattended three-card unlock, then Windows, in one boot

This tree turns the proven multi-target unlock child into a bootable handoff: firmware
starts one small EFI application from a dedicated ESP, that application verifies and
runs the unlock child in the same boot, proves from a durable record that every card
unlocked and kept its state, and only then starts the Windows Boot Manager directly.
No reset, no USB stick, no keyboard authorization.

It is an adaptation of the upstream `internal-boot` work in
<https://github.com/impacifist/Windows-GPU-UNLOCK> to this specific machine.

## What is different from upstream

| upstream | this tree | why |
| --- | --- | --- |
| one RTX 3090 at `01:00.0` | three cards: `41:00.0`, `81:00.0`, `C1:00.0`, plus `01:00.0` held back | the rig has four GM102 cards and only three may be unlocked |
| AMD iGPU owns the console | ASPEED BMC GOP + the card at `01:00.0` own the console | there is no AMD iGPU on this board, so the upstream GOP-release stage would blank the operator console |
| `full-release.c` detaches the RTX display driver and restores decode bits | not ported at all | the console lives on the card that must stay untouched; per-card driver release already happens inside the transaction |
| profile pin: ASUS TUF B650M, BIOS 3057 | profile pin: GIGABYTE MZ32-AR0-00, BIOS `M31` | `Configure.ps1` refuses any other board |
| one `U` keypress authorizes one card | no keypress; an automatic batch authorization with a 3 second Esc cancel window | unattended boot, and a missing keyboard must not block it |
| unlock success is the child's return code | unlock success is a `HANDOFF.ST` record that the wrapper parses and cross-checks | a return code is not evidence that the cards are still unlocked at the end of the batch |
| unlock child must run from USB | unlock child may run from an internal ESP, and in automatic mode only from the configured internal ESP | the whole point is to boot from disk |

`GU0` (`01:00.0`) keeps `UnlockAllowed = FALSE`. Nothing in this tree relaxes that, and
`DisplayCheck` still refuses any GOP that sits on a target BDF, which is the check that
protects the card that drives the screen.

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

## Prerequisites

- a **separate** FAT32 ESP of at least 1 GiB, not the Windows ESP, mountable as a letter
- Secure Boot off
- `C:` fully decrypted with BitLocker protection off (the installer never changes this)
- the firmware boot order still has `{bootmgr}` first before anything is registered
- `..\deps\edk2` present, LLVM/clang + lld-link on hand, Python 3

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

# 4. inspect the exact file tree before installing it anywhere
.\Install.ps1 -LocalStage D:\stage -Assets <dir with the five firmware assets>

# 5. stage onto the dedicated ESP only; boot order stays exactly as it is
.\Install.ps1 -Assets <dir>

# 6. register the manual entry; Windows stays first and default
.\Install.ps1 -RegisterManual

# 7. only after the manual boot succeeded on real hardware
.\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
```

`-Development` writes placeholder GUIDs so the build pipeline can be exercised without a
real ESP. A build made that way announces itself on the console and `-Check` blocks it.

## Recovery

```powershell
.\Install.ps1 -RestoreWindowsFirst
```

Restores `{bootmgr}` to the front of the firmware order and the saved Fast Startup value,
and re-points the created entry at the manual image. It needs no working EFI image and no
matching entry name, and deletes nothing. The installer also writes
`recovery-plan.json` next to every BCD backup in
`%ProgramData%\WindowsGPUUnlock\Backups\<timestamp>\`, together with the firmware order,
the full BCD export and the partition map from before the change.

If a boot fails, the wrapper stops and prints what to do; it never retries, never resets
and never forces Windows. Power-cycle and pick Windows from the firmware boot menu, then
run `-RestoreWindowsFirst`.

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
end-of-batch record policy), the installer's boot-policy tests against recorded
`bcdedit` output, and the unlock child's own suite.

## Status

Software side complete: both layers build reproducibly, every host suite passes, and the
installer's readiness check passes every prerequisite it can see without a real
configured ESP. **Hardware-unverified**: no build from this tree has been booted on the
rig yet, the automatic path has never been started by real firmware, and
`platform-config.h` currently holds placeholder GUIDs. Physical acceptance (manual
selection, then one cold boot, then a second cold boot) is the remaining step.
