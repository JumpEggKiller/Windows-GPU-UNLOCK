/* Local rig profile — PREFLIGHT PARAMETERIZATION ONLY (branch local-rig-preflight).
   Values verified read-only from Windows on 2026-10-23; see audit report.
   Identity pins below are verified facts about THIS machine:
     GPU3 = ZOTAC GA102, subsystem 1454:1B4C, BDF 0000:C1:00.0 (parent chain
     root-complex 3 -> root port dev 9 -> bus C1; cross-checked via nvidia-smi).
   Log-only knobs are values the upstream build pins to the author's machine
   that cannot be verified from Windows without nvflash; the ported preflight
   logs them instead of gating, and must never be treated as passing checks. */
#pragma once

#define GU_TARGET_BUS 0xC1U
#define GU_TARGET_DEVICE 0U
#define GU_TARGET_FUNCTION 0U

/* Verified from Windows PnP (Win32_PnPEntity): ZOTAC subsystem. */
#define GU_BOARD_SUBSYSTEM 0x14541B4CU

/* 0 = log-only: BAR0 base is firmware-assigned and unknown from Windows.
   BAR0 length stays pinned at the GA102 reference 16 MiB (PromCheck reads
   the PROM window at BAR0+0x300000, which requires it). */
#define GU_BAR0_BASE 0ULL

/* PROM SHA-256 of THIS card (1 MiB at BAR0+0x300000), computed by the
   log-only preflight and stable across three cold boots (RUN01/RUN02/RUN03,
   2026-10-23). Restored as a hard gate. SS0/SS1 stay unpinned: the
   entry-latch profiles latch observed values (SS0 field7 drifted 2->6
   across boots and is overwritten by the unlock write anyway). */
#define GU_PROM_SHA256_LOCAL "e23caae3312afa69407c7cc79538875d5cf36e78065ce4c0d615a61bffa7e5bb"

/* 0 = hard: config[0xc8] and the PCIe-capability bit test verified on this
   card via the preflight config dump (0x00050011; FLR bit set) — restored. */
#define GU_CONFIG_LOG_ONLY_PINS 0

/* 1 = display check logs every GOP path/parent and accepts the physical
   ASPEED BMC GOP (1a03:2000 behind an AST1150 bridge under root complex 3);
   the author's ACPI-HID route and AMD iGPU parent pins do not apply here. */
#define GU_DISPLAY_LOG_ONLY 1
