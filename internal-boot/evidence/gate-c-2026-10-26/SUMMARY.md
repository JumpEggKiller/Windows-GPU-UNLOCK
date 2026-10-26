# Gate C acceptance — 2026-10-26 21:46 UTC+8

Manual selection of the internal EFI, four cards unlocked, Windows entered without a reset.

## What was booted

| item | value |
|---|---|
| firmware boot option | `Boot0004` "Windows GPU UNLOCK Manual" (one-shot `BootNext`, since consumed) |
| image | `S:\EFI\WindowsGPUUnlock\MANUAL.EFI` 10752 B `165e064a…7894f` |
| child | `S:\EFI\WindowsGPUUnlock\UNLOCK.EFI` 74752 B `7d93deb7…95f4e` |
| ESP | disk 4 partition 2 `{7c5be0d5-fa43-46bb-932b-940e31f725ed}` |
| firmware default | `{bootmgr}` (unchanged), Windows Boot Manager untouched |

## Handoff record (`FULL01.TXT`)

```
entry status=0x0
internal-handoff-v1 status=0x0
windows-preloaded status=0x0
unlock-start status=0x0
unlock-return status=0x0
windows-start status=0x0
handoff-record status=0x0
```

`windows-start` and `handoff-record` both succeed, so `bootmgfw.efi` was started directly
from the wrapper. There is no reset, no retry and no fallback to the firmware boot order.
`handoff-return-unexpected` and `handoff-stopped` are absent: the transfer never came back.

## End-of-batch record (`HANDOFF.ST`)

```
GUH1 0000000000000000 4 4 4 4
```

Status 0, eligible 4, unlocked 4, retained 4, clean 4 — the wrapper only accepts this
shape, and it is deleted at the start of every run so a stale success cannot authorize a
later boot.

## Card table (`RUN01\REPORT.TXT`)

```
status[0] name=GPU3 bdf=0:c1:0.0 pinned=1 eligible=1 released=1 unlocked=1 retained=1 clean=1 result=0 note=clean
status[1] name=GPU1 bdf=0:41:0.0 pinned=1 eligible=1 released=1 unlocked=1 retained=1 clean=1 result=0 note=clean
status[2] name=GPU2 bdf=0:81:0.0 pinned=1 eligible=1 released=1 unlocked=1 retained=1 clean=1 result=0 note=clean
status[3] name=GPU0 bdf=0:1:0.0 pinned=1 eligible=1 released=1 unlocked=1 retained=1 clean=1 result=0 note=clean
batch summary: eligible=4 attempted=4 unlocked=4 retained=4 of 4 targets
FINAL(multi) status=0 stage=transaction targets=4 console_fault=0 log_defects=0
```

## The display card

GPU0 is the card that owns the console GOP. Its transaction shows the path that the
previous attempt could not take:

```
ownership: records=9 exclusive=0 status=0x800000000000000f
ownership: records=9 exclusive=0 status=0
release: child 0x7db96d98 accepted by the display pin at record 5
release: child 0x7dcc5c18 accepted by the display pin at record 6
driver release: status=0 refresh=0 same_pci=1
ownership: records=4 exclusive=1 status=0
```

The exclusive claim is refused first, the release finds the graphics driver plus the two
child controllers it owns, the pin lets those children through, the driver stops, and the
exclusive claim then succeeds. `GOP result: valid=1 amd_physical=1 elsewhere=1 on_target=0`
afterwards shows GPU0's own GOP gone with the ASPEED GOP still present, which is the
condition the pin demands.

## Windows

- Booted 2026-10-26 21:46:48, four seconds after the handoff wrote `windows-start`.
- `Kernel-Power` 41 and `BugCheck` 1001 absent for the whole window: no reset occurred.
- Four cards present, driver 617.42, 24576 MiB each (`nvidia-smi.csv`).
- `BootNext` consumed by the firmware; `BootOrder` unchanged at
  `Boot0000 Boot0002 Boot0004 Boot0001 Boot0003`.
- Windows store unchanged: `default {469011d3-…}`, `displayorder {469011d3-…}`,
  `timeout 30`, the manual entry `{93dc5615-…}` still registered in the menu.

## Not covered here

Automatic boot (`default` moved to the unlock entry, 5 s timeout, Fast Startup off) is a
separate, unrehearsed-on-hardware step: Gate D. Strata still has no autostart trigger, so
"Strata restores itself" remains an open item independent of this pass.
