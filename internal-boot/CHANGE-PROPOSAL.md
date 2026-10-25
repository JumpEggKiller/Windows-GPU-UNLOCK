# Change proposal: register the unlock image in the Windows boot menu

This is the change Gate B has to approve before the maintenance window. Everything below was
derived from the current machine state, read only. **Nothing in this document has been applied
to the live boot configuration.**

- Branch: `local-rig-internal-boot`, HEAD `7ce84a2`
- Software evidence: `internal-boot\Test.ps1` → `ALL INTERNAL-BOOT SOFTWARE TESTS PASSED`
- Staged set on the dedicated ESP: `9 of 9 files match the build`
- Live store after every test run: unchanged (`bcdedit /enum all` byte-identical)

## 1. What exists right now (captured, read only)

```
{ bootmgr }
  device          partition=\Device\HarddiskVolume1
  path            \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
  description     Windows Boot Manager
  locale          zh-CN
  default         {current}
  displayorder    {current}
  toolsdisplayorder {memdiag}
  timeout         30

{ fwbootmgr }
  displayorder    {bootmgr} {389ada0e-ce4b-11f1-b410-806e6f6e6963}
                  {469011d0-a872-11f1-bb02-ea6b3138fbbe}
                  {b8f7edf7-ceaf-11f1-b411-806e6f6e6963}
  timeout         2

Fast Startup (HiberbootEnabled)   1
Secure Boot                       off
BitLocker on C:                   FullyDecrypted, protection off
Install state                     none (nothing registered, no backups written yet)
```

Dedicated ESP, created and staged already:

| item | value |
|---|---|
| partition | disk 4 partition 2, `{7c5be0d5-fa43-46bb-932b-940e31f725ed}`, GPT type ESP, FAT32 `GPUUNLOCK` |
| geometry | offset 996,928,389,120, size 1,610,612,736 B (1.50 GiB), letter `S:` |
| contents | `EFI\WindowsGPUUnlock\{UNLOCK.EFI,UNLOCK-AUTO.EFI,MANUAL.EFI,AUTO.EFI}` + `RTX3090-UNLOCK\ASSETS\{5 firmware assets}` |
| untouched | disk 4 partition 1 and **every** partition on disk 6 (Windows ESP, `C:`, Recovery) |

Staged images (all `HardwareTested=false`, all `verify_pe.py` clean):

| role | bytes | sha256 |
|---|---|---|
| `UNLOCK.EFI` manual child | 73728 | `76bf83a2dce4df71f3d5b87c77941342e480fceab02b367ca47d57a73560cb46` |
| `UNLOCK-AUTO.EFI` automatic child | 73728 | `ccc21e4fd46b919c43097cf8fc5fdbe5df9848e1f45f842aa4c5eb2bd8bd9e0c` |
| `MANUAL.EFI` manual wrapper | 9728 | `0c98b4a5ce4c424a1c73dd731c9b591f3d95570a000ddabb9c389cded0a7a759` |
| `AUTO.EFI` automatic wrapper | 10240 | `74a7911c21fd8871691216cb146a1bec44b3ad090888a2351d49bbd9056a6791` |

## 2. The change, in two separate moments

Both are one command each, both are reversible without the ESP or a working EFI image, and
neither one reboots the machine by itself.

### Moment 1 — Gate C, register the manual entry

```powershell
cd D:\AI\dsh-local\gpu-unlock-audit\Windows-GPU-UNLOCK\internal-boot
.\Install.ps1 -RegisterManual
```

Writes this and nothing else:

```
bcdedit /copy {bootmgr} /d "Windows GPU UNLOCK Manual"     -> a new {entry}
bcdedit /set {entry} device partition=S:
bcdedit /set {entry} path \EFI\WindowsGPUUnlock\MANUAL.EFI
bcdedit /set {bootmgr} displayorder {current} {entry}
```

Effect: the Windows menu gains a **second** entry, **behind** Windows. A normal boot is
unchanged and still boots Windows first after 30 s — the timeout is not touched in this step.

Before writing, the installer refuses to continue unless: it is elevated, Secure Boot is off,
`C:` is fully decrypted, the firmware default is still `{bootmgr}`, the Windows menu still has
a Windows fallback, the dedicated ESP still matches its recorded GUID/offset/size/FAT32, the
mount letter is still `S:`, all four images match their build manifests, all five assets match
`unlock\assets.json`, and no `install\state.json` exists yet. It first writes
`%ProgramData%\WindowsGPUUnlock\Backups\<stamp>\` with a full `bcdedit /export`, `enum-before.txt`,
`bootmgr-before.txt`, `firmware-before.txt` and the partition map.

### Moment 2 — Gate D, arm automatic boot (only after Gate C passed by hand)

```powershell
.\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
```

Writes this and nothing else:

```
bcdedit /set {entry} path \EFI\WindowsGPUUnlock\AUTO.EFI
bcdedit /set {entry} description "Windows GPU UNLOCK Auto"
bcdedit /set {bootmgr} displayorder {entry} {current}
bcdedit /set {bootmgr} timeout 5
HiberbootEnabled = 0                       (saved value: 1)
```

Effect: the machine cold-boots into the unlock image after a 5-second menu window, runs the
three-card transaction, starts `bootmgfw.efi` **without a reset**, and Windows comes up. If
nobody touches the keyboard nothing is required; if a human presses Esc or waits, or picks the
first entry, Windows boots untouched.

The 5 s timeout is deliberate and is **not** allowed to be 0: `{current}` stays in the order, so
there is always a local, no-tooling way to boot Windows. `Set-BootTimeout` refuses 0 and
anything above 3600, and reads the value back to prove it stuck.

## 3. What is NOT changed

- The Windows ESP (`{ade68b7e-…}`, disk 6 partition 1) — not written to, not mounted for write.
- `C:`, the Recovery partition, the reserved partition, the firmware `{fwbootmgr}` order.
- Secure Boot, BitLocker, Fast Startup is *temporarily* set to 0 in moment 2 and restored by the
  recovery command (`-RestoreWindowsFirst`), nothing else.
- Strata: no file, task or config touched. See §7.
- No VBIOS flash, no `UnlockAllowed` change: GPU0 stays `FALSE`, and `DisplayCheck` still refuses
  any GOP that sits on a target BDF.

## 4. Rollback, three levels

1. **No tooling at all** — power-cycle, let the Windows menu appear, press Esc (or wait 5 s) and
   pick the first entry: Windows. The unlock entry stays behind it.
2. **One command, any state:**
   ```powershell
   .\Install.ps1 -RestoreWindowsFirst
   ```
   Restores `displayorder` so `{current}` is first, restores the saved menu timeout (30 s) and
   the saved Fast Startup value (1), re-points the created entry back at `MANUAL.EFI`, verifies
   `order[0] is {current}`. It deletes nothing and needs no working EFI image.
3. **Full removal** (only if the experiment is abandoned): `-RestoreWindowsFirst`, then remove the
   created entry (`bcdedit /delete {entry} /f` — recorded in `install\state.json`), then delete
   `S:\EFI\WindowsGPUUnlock` and `S:\RTX3090-UNLOCK`, then optionally
   `Remove-Partition -DiskNumber 4 -PartitionNumber 2`.
   `%ProgramData%\WindowsGPUUnlock\Backups\<stamp>\bcd-export` can restore the boot store exactly.

Every registration/promotion step is wrapped in `Invoke-AutomaticTransition`: if verification
fails, the rollback runs once and the **original** error is rethrown. A failed rollback never
hides the first failure.

## 5. Failure behaviour of the images themselves (fail-stop, never forced)

- Wrapper stops and waits on: wrong partition GUID/path (not the dedicated ESP), the child
  failing its own SHA-256, the wrapper's own image being launched from another device,
  `bootmgfw.efi` missing, `SetWatchdogTimer` failing, or an unclean end-of-batch record.
  It prints `HANDOFF STOPPED. No reset and no automatic retry.` and spins. No second attempt.
- Windows is started only if the child left `\RTX3090-UNLOCK\HANDOFF.ST` reading
  `GUH1 0000000000000000 <eligible> <unlocked> <retained> <clean>` with all four counts equal to
  the expected 3 — i.e. three cards unlocked **and** still unlocked **and** clean after the batch.
  A card that dropped out is refused here even if the child returned success.
- The record is deleted at child start, so an earlier boot's clean record can never authorize
  this one.
- Automatic mode has a 3 s Esc window and a 5 s menu window; a missing keyboard degrades to
  "cancel unavailable, continue" and is logged — an unattended boot must not depend on input.

## 6. Acceptance sequence (maintenance window)

| gate | action | pass criterion |
|---|---|---|
| B | review this document, `-Check`, `-Plan`, `install\rehearse-bcd.ps1` | reviewer accepts; `-Check` READY; rehearsal 14/14 |
| C | moment 1, restart, pick **Windows GPU UNLOCK Manual** by hand | console: `internal-handoff-v1`, three cards `unlocked=1 retained=1 clean=1`, `FINAL(multi) status=0`, Windows **without reset**; then `nvidia-smi` 3 cards `OK`, driver 617.42, no code 43 |
| D | moment 2, one real cold boot, hands off | menu 5 s → auto unlock → Windows; same three-card evidence; `S:\RTX3090-UNLOCK\BOOTnn.TXT` exists |
| E | second cold boot | identical; plus pull the keyboard/USB and confirm it still boots; then `-RestoreWindowsFirst` and confirm Windows-first works |

## 7. Known blocker for Gate D (not a code defect)

Strata **does not start by itself** after an unattended boot: task `Strata-Nofill-Cutover` has no
triggers, `Strata-Parking-Restore` is disabled, and there is no Run-key or Startup entry. Also
`strata-256k-parking\configs\PROD_0441_IQ4XS_256K_PARKING.json` no longer matches the hash in the
cutover record (`D6E5D66E…` vs `D5A7E5A9…`), although `engine-nofill\strata.exe` still matches
(`1EF38726…`), and nothing is listening on port 18144 right now (an engine 0.1.50 A/B instance is
running instead).

Gate D as scoped for this round is therefore judged on: **three cards unlocked, driver healthy,
Windows booted without a reset.** Bringing Strata back automatically needs a separate, approved
production change (add a trigger that writes `{"action":"restore"}` for `sup_task.ps1`).

## 8. Evidence index

| what | where |
|---|---|
| software suite (6 sections) | `internal-boot\Test.ps1` |
| wrapper host tests (device path, flow, record) | `internal-boot\boot\test_*.c` via `boot\run-tests.ps1` |
| installer policy, 24 checks | `internal-boot\install\test-automatic-policy.ps1` |
| plan is read-only, 7 checks | `internal-boot\install\test-plan.ps1` |
| whole change on a scratch hive, 14 checks | `internal-boot\install\rehearse-bcd.ps1` |
| staged set fault injection, 7 checks | `internal-boot\install\test-staged.ps1` |
| source audit | `internal-boot\boot\audit.ps1` |
| build report + hashes | `internal-boot\build\build-report.json` |
| operator runbook | `internal-boot\MAINTENANCE.md` |
| design and differences from upstream | `internal-boot\README.md` |
