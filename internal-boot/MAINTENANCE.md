# Maintenance window: shortest safe path

Everything below the line "already done" runs in the maintenance window. Nothing here has
been executed against this machine yet: the only writes ever made were into
`internal-boot\build\local-stage\` and `%TEMP%`.

## Already done and verified (no hardware touched)

- `unlock\run-local-tests.ps1` — ALL RUNNABLE GROUPS PASSED (includes the 82-check
  multi-target arming suite and the GPU0-disallowed audit).
- `internal-boot\Test.ps1` — ALL INTERNAL-BOOT SOFTWARE TESTS PASSED: host tests, 24
  installer-policy checks, 7 read-only plan checks, source audit, and the child suite above.
- `internal-boot\Build.ps1` — four artifacts, bit-identical across rebuilds, PE verified.
- `Install.ps1 -Check` — only blocker is the placeholder ESP GUIDs.
- `Install.ps1 -LocalStage` — the exact ESP file tree, hashes verified, no disk written.

## Step 0 — the dedicated ESP (DONE: option A was created and staged)

Option A was executed on 2026-10-25 after the operator chose it. The dedicated ESP now

- is **disk 4 partition 2**, GUID `{7c5be0d5-fa43-46bb-932b-940e31f725ed}`, GPT type
  `{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`, 1.50 GiB, FAT32 label `GPUUNLOCK`, mounted `S:`;
- occupies the free tail at offset 996,928,389,120 that the `tigo SSD 1TB` already had, so
  **nothing was resized, moved or deleted**; disk 4 partition 1 (the Linux filesystem at
  offset 1,048,576) is byte-for-byte unchanged;
- holds the nine staged files, hashes verified on the volume itself.

`Configure.ps1` was pinned against it (`boot\platform-config.h`, `local-config.json`,
`Placeholder=false`), `Build.ps1` rebuilt all four images with those GUIDs baked in, and
`Install.ps1 -Check` reports `READY: every prerequisite passed. Nothing was written.`
No BCD or boot-order change has been made: `bcdedit /enum all` is unchanged.

Rollback if the ESP is ever unwanted: delete `EFI\WindowsGPUUnlock\` and
`RTX3090-UNLOCK\` on `S:`, then `Remove-Partition -DiskNumber 4 -PartitionNumber 2`; the
space returns to exactly the state it was in before.

The alternatives, kept for reference if a differently placed ESP is ever preferred:

**A. Disk 4, in space that is already free (what was used).** `tigo SSD 1TB`, SATA SSD, GPT,
931.5 GB with **3.05 GB unallocated at the end of the disk**. Its only partition is a Linux
filesystem (`0fc63daf-8483-4772-8e79-3d69d8477de4`) that Windows cannot even mount; creating
a partition in the trailing free extent moves nothing, shrinks nothing and touches nothing:

```powershell
New-Partition -DiskNumber 4 -Size 1.5GB -DriveLetter S `
  -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' |
  Format-Volume -FileSystem FAT32 -NewFileSystemLabel GPUUNLOCK -Confirm:$false
Get-Partition -DiskNumber 4 | Format-Table PartitionNumber,DriveLetter,Size,GptType
```
Rollback: `Remove-Partition -DiskNumber 4 -PartitionNumber <new>` — the space returns to
exactly the state it is in now.

**B. Disk 7, by shrinking `D:`.** `KINGBANK KP230 PRO`, NVMe SSD, single partition with
720.73–953.87 GB supported sizes, so 1.5 GiB can be given up and the new partition placed in
the freed tail. Costs one resize of a live data volume:

```powershell
$d=Get-Partition -DriveLetter D
Resize-Partition -DriveLetter D -Size ($d.Size - 1.5GB)
New-Partition -DiskNumber 7 -UseMaximumSize -DriveLetter S `
  -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' |
  Format-Volume -FileSystem FAT32 -NewFileSystemLabel GPUUNLOCK -Confirm:$false
```
Rollback: `Remove-Partition`, then `Resize-Partition -DriveLetter D` back to the original
size. The shrink itself never writes into the freed region.

**C. Reuse the existing 1.05 GiB FAT32 ESP on disk 5 partition 1**
(`{d0dec9de-7da0-4902-9e33-bcc0259bd48f}`, 1.04 GB free, not `IsSystem`). No partition
change at all; needs only a temporary letter:

```powershell
Add-PartitionAccessPath -DiskNumber 5 -PartitionNumber 1 -AccessPath 'S:\'
```
Cost: our files land in the ESP of an existing Linux installation. Nothing of that
installation is modified or deleted, but the partition is shared.

The mechanical disks (`ST2000DM005`, `ST3000VX000`, `WD40PURX`, `WD1002FAEX`) have no free
extent at all and would each need a resize; none of them is a candidate.

## Blocking item for Gate D: Strata does not start by itself

Verified read-only on 2026-10-25. Gate D asks for "Strata restored by the existing production
launcher" after an unattended boot, and that launcher is not wired to start anything:

- `Strata-Nofill-Cutover` (the task that runs
  `strata0441-nofill-backport\swap\sup_task.ps1`) has **no triggers**. Its own description
  says "on demand, no triggers, interactive user".
- `Strata-Parking-Restore` is **Disabled**.
- No Run-key and no Startup-folder entry for Strata exists (only `WavesLocalServer.lnk`).

So after a cold boot Windows comes up with no Strata process and nothing listening on 18144.
That is a production state, not a defect of this port, and fixing it means adding a trigger
that writes `{"action":"restore"}` into `swap\results\sup_request.json` and then runs the
task — a change to the production launcher that needs its own approval. Until then Gate D can
be judged on "three cards unlocked, driver healthy, Windows booted without a reset" and Strata
must be restored by hand with the documented supervisor:

```powershell
# after the boot, from a normal shell (the supervisor must run under Task Scheduler;
# a restore launched from a background job is cancelled with its children)
schtasks /run /tn 'Strata-Nofill-Cutover'   # only if it is given a trigger or run manually
```

Two further facts the window will need: the production binary
`strata-256k-parking\engine-nofill\strata.exe` matches its recorded hash
`1EF387260972F579AE42C6D7D3650872FBF2B607D53DB5A2157EDA1D5C731A4B`, but
`configs\PROD_0441_IQ4XS_256K_PARKING.json` has **drifted** from the cutover record (expected
`D5A7E5A9…4265E`, actual `D6E5D66E…AF04`), and port 18144 has no listener right now. Do not
treat "Strata restored" as a pure reboot test until that config difference is explained.

## Step 1 — pin, build, prove (still no boot configuration change)

**Already done** against the real ESP on 2026-10-25: `Configure.ps1` pinned
`S:` / `{7c5be0d5-fa43-46bb-932b-940e31f725ed}` / `{ade68b7e-ced7-408a-b149-027482c08207}`,
`Build.ps1` produced the installable set below, and `-Check` is READY. The commands are kept
here for a rebuild (a BIOS update or a new ESP invalidates the pin):

```powershell
cd D:\AI\dsh-local\gpu-unlock-audit\Windows-GPU-UNLOCK\internal-boot
.\Configure.ps1 -UnlockDriveLetter S -WindowsEspGuid '{ade68b7e-ced7-408a-b149-027482c08207}'
.\Build.ps1 -Clang  ..\..\tools\clang+llvm-23.1.4-x86_64-pc-windows-msvc\bin\clang.exe `
             -LldLink ..\..\tools\clang+llvm-23.1.4-x86_64-pc-windows-msvc\bin\lld-link.exe `
             -Python  C:\Users\micasa\AppData\Local\Programs\Python\Python314\python.exe
.\Install.ps1 -Check
.\Install.ps1 -Plan
```

Gate A/B exit criterion: `-Check` prints "Ready to install" with the real GUIDs, no
`BLOCKED` section, and the four artifact hashes match `build\build-report.json`.

### Step 1b — rehearse the whole boot-configuration change, still without touching it

```powershell
cd D:\AI\dsh-local\gpu-unlock-audit\Windows-GPU-UNLOCK\internal-boot
.\install\rehearse-bcd.ps1
```

This exports the live store to a scratch hive under `%TEMP%` and runs the entire sequence
against the copy with real `bcdedit`: `/copy {bootmgr}`, attribute exactly one new entry,
device → `partition=S:`, path → `MANUAL.EFI`, push it behind Windows, promote it (`AUTO.EFI`,
description, `timeout 5`), then restore Windows first, then delete the entry again. It also
injects three faults (an order without the Windows fallback, a write to a
non-existent identifier, two simultaneous copies) and finally re-exports the live store and
compares it byte for byte. Expected tail:

```
PASS boot entry rehearsal: registration, promotion, fault injection and recovery on a
scratch hive (33 offline calls, 2 live reads, all read-only)
```

Only `/store` calls write, every one of them to the temp hive; the two live calls are
`/enum`. `-Check` afterwards must still print `boot menu order {current}` / `timeout 30s`.

## Step 2 — stage onto the dedicated ESP only

```powershell
.\Install.ps1 -Assets D:\AI\dsh-local\gpu-unlock-audit\usb-staging\RTX3090-UNLOCK\ASSETS
```
**Already done**: `Staged 9 files into S:\ (dedicated ESP {7c5be0d5-…})` /
`Files staged only. Boot order unchanged.`, BCD verified unchanged. Re-running it is safe
(it refuses to overwrite a different file) — do it again if the images are rebuilt.

`-Check` now also compares every staged file against the build and the asset manifest, so a
rebuilt image that was not re-staged is caught here instead of at Gate C:

```
  staged on the ESP    9 of 9 files match the build
```

Anything less than `9 of 9` appears under `BLOCKED` as `Not staged on the dedicated ESP: …`
or `Staged file is older than the build: …`; re-run the staging command above and check again.

## Step 3 — Gate C: register the manual entry and test it by hand

```powershell
.\Install.ps1 -RegisterManual      # backs up BCD, copies {bootmgr}, adds the copy behind Windows
```
This does **not** touch `default` or `timeout`: after it, an unattended boot is exactly what it
was before. `-Check` should still print `boot menu default {469011d3-…}` (the Windows loader).

One side effect worth knowing before you run it: `bcdedit /copy {bootmgr}` also makes the copy a
**firmware** boot option, so `{fwbootmgr}` gains a fifth identifier and the firmware boot menu
will list "Windows GPU UNLOCK Manual" as well. `{bootmgr}` still comes first there, so an
unattended power-on is unaffected, and `bcdedit /delete <entry> /f` removes both the BCD entry
and the firmware option — that is what `-RestoreWindowsFirst` and the rollback below rely on.

Then a real power cycle — **not** `shutdown /r`:

```powershell
shutdown /s /t 0        # or switch the machine off at the PSU and back on
```

A warm restart can follow a firmware/Fast-Startup path that never presents the boot menu the way
a cold power-on does, and the unlock is volatile anyway, so Gate C has to rehearse the exact
cold path Gate D depends on. At the Windows menu pick **Windows GPU UNLOCK Manual**. Expected
console sequence: the wrapper banner, `internal-handoff-v1`, the child banner, the 3-second auto
cancel window, three cards unlocked, `HANDOFF.ST` accepted, then bootmgfw starts and Windows
comes up without a reset. Then confirm in Windows: four RTX nodes, driver 617.42, no Code 43,
and (`Get-Partition`/`nvidia-smi` as usual) that Strata's state is whatever §"Blocking item for
Gate D" says it is.

If anything fails: the wrapper stops and prints the reason; power-cycle, choose the first
menu entry (Windows), then run `.\Install.ps1 -RestoreWindowsFirst`.

## Step 4 — Gate D/E: arm automatic boot, then two cold boots

```powershell
.\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
.\Install.ps1 -Check      # must say: automatic armed yes, boot menu default <the unlock entry>
```
This sets `default` to the unlock entry, puts it first in the menu, sets the menu timeout to 5 s
and turns Fast Startup off. All four are required and are verified read-back; if any of them
fails the whole promotion is rolled back. **`default` is the field that decides what an
untouched power-on starts** — menu position alone does not, which is exactly the defect this
step exists to avoid.

Then: full power-off → power-on with no keyboard, and repeat once more for repeatability.
Two independent human escape hatches on every boot: press a key inside the 5-second Windows menu
and pick the Windows entry, or let the unlock image start and press Esc inside its own 3-second
window (it then starts Windows without unlocking anything).


## Rollback, in one command each

| state | command |
| --- | --- |
| automatic armed | `.\Install.ps1 -RestoreWindowsFirst` (restores the boot default, Windows first, manual entry kept) |
| manual entry unwanted | `bcdedit /delete <EntryId> /f` after `-RestoreWindowsFirst` |
| ESP files unwanted | delete `EFI\WindowsGPUUnlock\` and `RTX3090-UNLOCK\` on `S:` |
| partition A created | `Remove-Partition -DiskNumber N -PartitionNumber M`, then `Resize-Partition` back |
| letter B added | `Remove-PartitionAccessPath -DiskNumber 5 -PartitionNumber 1 -AccessPath 'S:\'` |

`%ProgramData%\WindowsGPUUnlock\Backups\<stamp>\` holds `bcd-export`,
`enum-before.txt`, `bootmgr-before.txt`, `firmware-before.txt`,
`partitions-before.txt`, and `recovery-plan.json`. `bcdedit /import` restores the whole
store if it ever came to that.
