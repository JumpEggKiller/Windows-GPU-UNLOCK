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

## Step 0 — choose the dedicated ESP (needs a decision before anything else)

The window must begin with a partition decision, because `Configure.ps1` bakes the
partition GUID into the wrapper. No mechanical disk is involved: this machine has SSD space
that needs no resize at all.

**A. Disk 4, in space that is already free (recommended).** `tigo SSD 1TB`, SATA SSD, GPT,
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

## Step 2 — stage onto the dedicated ESP only

```powershell
.\Install.ps1 -Assets D:\AI\dsh-local\gpu-unlock-audit\usb-staging\RTX3090-UNLOCK\ASSETS
```
Ends with `Files staged only. Boot order unchanged.` `bcdedit /enum {bootmgr}` must still
show `displayorder {current}` afterwards.

## Step 3 — Gate C: register the manual entry and test it by hand

```powershell
.\Install.ps1 -RegisterManual      # backs up BCD, copies {bootmgr}, adds the copy behind Windows
Restart-Computer
```
At the Windows menu pick **Windows GPU UNLOCK Manual**. Expected console sequence: the
wrapper banner, `internal-handoff-v1`, the child banner, the 3-second auto cancel window,
three cards unlocked, `HANDOFF.ST` accepted, then bootmgfw starts and Windows comes up
without a reset. Then confirm in Windows: four RTX nodes, driver 617.42, no Code 43, and
the Strata launcher restored.

If anything fails: the wrapper stops and prints the reason; power-cycle, choose the first
menu entry (Windows), then run `.\Install.ps1 -RestoreWindowsFirst`.

## Step 4 — Gate D/E: arm automatic boot, then two cold boots

```powershell
.\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
```
This sets the menu timeout to 5 s, arms `AUTO.EFI` first, and turns Fast Startup off.
Then: full power-off → power-on with no keyboard, and repeat once more for repeatability.
Five-second escape hatch on every boot: press Esc (or wait) and choose Windows.

## Rollback, in one command each

| state | command |
| --- | --- |
| automatic armed | `.\Install.ps1 -RestoreWindowsFirst` (Windows first, manual entry kept) |
| manual entry unwanted | `bcdedit /delete <EntryId> /f` after `-RestoreWindowsFirst` |
| ESP files unwanted | delete `EFI\WindowsGPUUnlock\` and `RTX3090-UNLOCK\` on `S:` |
| partition A created | `Remove-Partition -DiskNumber N -PartitionNumber M`, then `Resize-Partition` back |
| letter B added | `Remove-PartitionAccessPath -DiskNumber 5 -PartitionNumber 1 -AccessPath 'S:\'` |

`%ProgramData%\WindowsGPUUnlock\Backups\<stamp>\` holds `bcd-export`,
`enum-before.txt`, `bootmgr-before.txt`, `firmware-before.txt`,
`partitions-before.txt`, and `recovery-plan.json`. `bcdedit /import` restores the whole
store if it ever came to that.
