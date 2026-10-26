# Change proposal: register the unlock image in the Windows boot menu

This is the change Gate B has to approve before the maintenance window. Everything below was
derived from the current machine state, read only. **Nothing in this document has been applied
to the live boot configuration.**

- Branch: `local-rig-internal-boot`
- Software evidence: `internal-boot\Test.ps1` → `ALL INTERNAL-BOOT SOFTWARE TESTS PASSED`
- Staged set on the dedicated ESP: `9 of 9 files match the build`
- Live store after every test run: unchanged (`bcdedit /enum all` byte-identical)

**Revision note (this version).** An earlier draft of moment 2 changed only `displayorder` and
`timeout`. Since `{bootmgr} default` was (and still is) `{current}`, an unattended power-on
would have waited out the 5 s menu and then booted **Windows**, silently skipping the unlock.
Automatic mode now also sets `default {entry}` and happens; the readback includes the default,
and "armed" is defined as four fields at once (§2). Nothing about the live boot configuration
has been changed by this revision.

**Revision note (image shape, after the first Gate C attempt).** Moment 1 has now been applied
once: entry `{93dc5615-d0f2-11f1-b41f-18c04d0c6177}` is registered, Windows is still first and
still the default. The first cold boot reached that entry and the boot manager itself refused the
file with `状态: 0xc000007b` on `\EFI\Windows GPUUnlock\MANUAL.EFI`, before any of our code ran
(no log file was created at all). Cause: the wrapper was linked as a plain EFI application
(subsystem 10, image base 0, ASLR/NX placement flags). The one image this boot manager does start
through a BCD entry on this machine, `memtest.efi`, is `IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION`
(16) at image base `0x140000000` with no placement flags. The wrappers are now linked and patched
to exactly that shape (`boot\boot-application.py`), while the unlock children stay subsystem 10
because firmware and our own `LoadImage` start them. Re-staged and verified `9 of 9`; the four
image hashes in §1 are superseded by the values below.

## 1. What exists right now (captured, read only)

```
{ bootmgr }
  device          partition=\Device\HarddiskVolume1
  path            \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
  description     Windows Boot Manager
  locale          zh-CN
  default         {current}          (= {469011d3-a872-11f1-bb02-ea6b3138fbbe}, the Windows loader)
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
| `MANUAL.EFI` manual wrapper | 10752 | `ab677646e51b913b097646516bfa447bde21026e4b8e793ae4c0edb9cd173564` |
| `AUTO.EFI` automatic wrapper | 10752 | `2123fe12f6285a94f61ebc7c54985de6410d1aff9ac23c54bee1f06961b81e1a` |

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
unchanged and still boots Windows first after 30 s — neither the timeout nor the **default
entry** is touched in this step, so an unattended boot is bit-for-bit what it was before.

One correction established by running it: `/copy {bootmgr}` also registers the copy as a
**firmware** boot option, so `{fwbootmgr}` gains a fifth identifier (last, behind `{bootmgr}`),
and the firmware boot menu lists "Windows GPU UNLOCK Manual" too. `{bootmgr}` stays first, so
unattended behaviour is unchanged, and `bcdedit /delete <entry> /f` removes the BCD entry *and*
its firmware option in one step — measured, not assumed.

Before writing, the installer refuses to continue unless: it is elevated, Secure Boot is off,
`C:` is fully decrypted, the firmware default is still `{bootmgr}`, the Windows menu still has
a Windows fallback, the dedicated ESP still matches its recorded GUID/offset/size/FAT32, the
mount letter is still `S:`, all four images match their build manifests, all five assets match
`unlock\assets.json`, and no `install\state.json` exists yet. It first writes
`%ProgramData%\WindowsGPUUnlock\Backups\<stamp>\` with a full `bcdedit /export`, `enum-before.txt`,
`bootmgr-before.txt` (verbose, so the real default identifier is in it), `firmware-before.txt`
and the partition map.

### Moment 2 — Gate D, arm automatic boot (only after Gate C passed by hand)

```powershell
.\Install.ps1 -EnableAutomaticBoot -ConfirmedManualSuccess
```

Writes this and nothing else:

```
bcdedit /set {entry} path \EFI\WindowsGPUUnlock\AUTO.EFI
bcdedit /set {entry} description "Windows GPU UNLOCK Auto"
bcdedit /set {bootmgr} displayorder {entry} {current}
bcdedit /set {bootmgr} default {entry}     <- this is what actually starts the unlock
bcdedit /set {bootmgr} timeout 5
HiberbootEnabled = 0                       (saved value: 1)
```

**Why the default line is the important one.** `displayorder` only orders the *menu*.
What the boot manager starts on its own is its **default** entry, and until this fix the
default was `{current}` (Windows). With a 5 s timeout and the unlock entry merely first in the
menu, an untouched power-on waited 5 s and then booted **Windows**, skipping the unlock
entirely — the bug this revision fixes. Automatic boot is therefore now defined as *four things
at once*:

| condition | required value |
|---|---|
| `{bootmgr}` `default` | the unlock `{entry}` |
| `{bootmgr}` `displayorder` first | the unlock `{entry}` |
| `{bootmgr}` `timeout` | `5` |
| `HiberbootEnabled` (Fast Startup) | `0` |

`Get-AutomaticArmed` is the single predicate that checks all four, and it is used by the
promotion verification, by `-Check`, and by the host tests — including a regression that proves
"entry first in the menu, default still Windows" reports **not armed**. `-Check` prints both
`boot menu order` and `boot menu default`, so a review can see the two are different things.
The promotion refuses to finish (and rolls everything back) if any of the four is wrong, and
`{bootmgr}` itself is never accepted as the default: `Set-BootDefault` only takes a concrete
entry identifier that already exists in the store, and reads the value back to prove it stuck.

Legality was not assumed. On a scratch copy of the store, `bcdedit /store <hive> /set {bootmgr}
default <copied-entry>` succeeded and `/enum {bootmgr} /v` read the copy back, so a
`{bootmgr}`-copied application entry **can** be the default; `install\rehearse-bcd.ps1` repeats
that proof on every run. The same probe also showed bcdedit accepts a default that does *not*
exist, which is why the policy validates the identifier itself instead of trusting bcdedit.

Effect: the machine cold-boots into the unlock image after a 5-second menu window, runs the
three-card transaction, starts `bootmgfw.efi` **without a reset**, and Windows comes up. If
nobody touches the keyboard nothing is required. If a human wants Windows instead, press any
key during the window and choose the Windows entry, or simply **wait 5 s and then press Esc at
the unlock image's own cancel window** (the child waits 3 s for Esc before doing anything, and
the wrapper waits 5 s before starting Windows) — the image then starts Windows without
unlocking. Two independent human escape hatches, no tooling.

The 5 s timeout is deliberate and is **not** allowed to be 0: `{current}` stays in the order, so
there is always a local, no-tooling way to boot Windows. `Set-BootTimeout` refuses 0 and
anything above 3600, and reads the value back to prove it stuck.

## 3. What is NOT changed

- The Windows ESP (`{ade68b7e-…}`, disk 6 partition 1) — not written to, not mounted for write.
- `C:`, the Recovery partition, the reserved partition, the firmware `{fwbootmgr}` order.
- Secure Boot, BitLocker, Fast Startup is *temporarily* set to 0 in moment 2 and restored by the
  recovery command (`-RestoreWindowsFirst`), nothing else.
- Strata: no file, task or config touched. See §7.
- No VBIOS flash. GPU0 (`01:00.0`, the display adapter) is the fourth unlocked card on the
  owner's instruction, and the display rule changed in exactly one place: `DisplayCheck` still
  refuses any GOP sitting on a target BDF, except for the single row that pins
  `DisplayMaySitOnTargetGop` — and even then it requires a second physical GOP (the ASPEED BMC)
  to survive, so a rig whose only display path is the target card is still refused, and
  `GuTargetTableCheck` refuses a second such row. GPU0 runs last in the batch; disconnecting its
  firmware driver may blank the UEFI console for the rest of that boot, the file log on `S:` is
  unaffected, and Windows re-initialises the card. Detail: `internal-boot/README.md` and the
  comment above `GU_CARD_TABLE`.

## 4. Rollback, three levels

1. **No tooling at all** — power-cycle, let the Windows menu appear, press Esc (or wait 5 s) and
   pick the first entry: Windows. The unlock entry stays behind it.
2. **One command, any state:**
   ```powershell
   .\Install.ps1 -RestoreWindowsFirst
   ```
   Restores the **boot default** first (from `BootDefaultBefore`, else from the verbose
   `bootmgr-before.txt` backup, else leaves the current one only if it is not the unlock entry),
   then `displayorder` so `{current}` is first, the saved menu timeout (30 s) and the saved Fast
   Startup value (1), re-points the created entry back at `MANUAL.EFI`, and verifies both
   `order[0] is {current}` and **`the unlock entry is not the boot default`** — otherwise it
   fails loudly. It deletes nothing and needs no working EFI image.
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
  the expected 4 — i.e. four cards unlocked **and** still unlocked **and** clean after the batch.
  A card that dropped out is refused here even if the child returned success.
- The record is deleted at child start, so an earlier boot's clean record can never authorize
  this one.
- Automatic mode has a 3 s Esc window and a 5 s menu window; a missing keyboard degrades to
  "cancel unavailable, continue" and is logged — an unattended boot must not depend on input.

## 6. Acceptance sequence (maintenance window)

| gate | action | pass criterion |
|---|---|---|
| B | review this document, `-Check`, `-Plan`, `install\rehearse-bcd.ps1` | reviewer accepts; `-Check` READY; rehearsal 18/18; all four commands PASS |
| C | moment 1, then a **full shutdown and power-on** (not a restart), wait for the Windows boot menu and pick **Windows GPU UNLOCK Manual** by hand | console: `internal-handoff-v1`, four cards `unlocked=1 retained=1 clean=1`, `FINAL(multi) status=0`, Windows **without reset**; then `nvidia-smi` 4 cards `OK`, driver 617.42, no code 43 |
| D | moment 2, one real cold boot, hands off | menu 5 s → auto unlock → Windows; same three-card evidence; `S:\RTX3090-UNLOCK\BOOTnn.TXT` exists; `-Check` says `automatic armed yes` |
| E | second cold boot | identical; plus unplug the keyboard and USB and confirm it still boots; then `-RestoreWindowsFirst` and confirm `boot menu default` is the Windows loader again and Windows-first works |

**Gate C uses a real power cycle, not `shutdown /r`.** A restart can carry a Fast Startup /
firmware warm-boot path that never re-runs the firmware boot manager the way a cold power-on
does, and the unlock is volatile anyway: only a full power-off + power-on reproduces the path
that Gate D will depend on. So: shut down completely, switch off at the PSU if convenient, wait,
power on, then pick the entry by hand.

## 7. Known blocker for Gate D (not a code defect)

Strata **does not start by itself** after an unattended boot: task `Strata-Nofill-Cutover` has no
triggers, `Strata-Parking-Restore` is disabled, and there is no Run-key or Startup entry. Also
`strata-256k-parking\configs\PROD_0441_IQ4XS_256K_PARKING.json` no longer matches the hash in the
cutover record (`D6E5D66E…` vs `D5A7E5A9…`), although `engine-nofill\strata.exe` still matches
(`1EF38726…`), and nothing is listening on port 18144 right now (an engine 0.1.50 A/B instance is
running instead).

Gate D as scoped for this round is therefore judged on: **four cards unlocked, driver healthy,
Windows booted without a reset.** Bringing Strata back automatically needs a separate, approved
production change (add a trigger that writes `{"action":"restore"}` for `sup_task.ps1`).

## 8. Evidence index

| what | where |
|---|---|
| software suite (6 sections) | `internal-boot\Test.ps1` |
| wrapper host tests (device path, flow, record) | `internal-boot\boot\test_*.c` via `boot\run-tests.ps1` |
| installer policy, 34 checks | `internal-boot\install\test-automatic-policy.ps1` |
| plan is read-only, 8 checks | `internal-boot\install\test-plan.ps1` |
| whole change on a scratch hive, 18 checks | `internal-boot\install\rehearse-bcd.ps1` |
| staged set fault injection, 7 checks | `internal-boot\install\test-staged.ps1` |
| source audit | `internal-boot\boot\audit.ps1` |
| build report + hashes | `internal-boot\build\build-report.json` |
| operator runbook | `internal-boot\MAINTENANCE.md` |
| design and differences from upstream | `internal-boot\README.md` |
