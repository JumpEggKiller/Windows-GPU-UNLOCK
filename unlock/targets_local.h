/* Machine-local multi-target pins (branch local-rig-multitarget; NOT upstream).
   Only compiled with -DGU_MULTI_TARGET.

   Every value below belongs to exactly one physical card. The subsystem IDs are
   measured from this rig (nvidia-smi + Win32_PnPEntity); the config[0xc8] and
   1 MiB PROM SHA-256 values are measured by THIS project's read-only probe run
   and must never be copied between cards, even when two cards share a VBIOS
   string: GPU0 and GPU3 both report VBIOS family 94.02.x from ZOTAC and share
   subsystem 14541B4C, yet their VBIOS builds differ (94.02.26.c0.35 vs
   94.02.59.00.4e), so their PROM images differ.

   An empty PROM pin ("") or a 0 config[0xc8] means "not measured yet". A target
   in that state can be probed but CANNOT be armed: PromCheck leaves
   prom_verified FALSE (ColdCheck then refuses) and, for c8, the log-only pin is
   only permitted in a preflight-only build (port.h #error enforces that).

   Field order: Name, segment, bus, device, function, subsystem, config_c8,
   prom_sha256, unlock_allowed, display_may_sit_on_target_gop. Table order is
   execution order; the console GOP card (GPU0) is last on purpose. */
#pragma once

/* Rig-level facts, NOT card identity: identical in machine_local.h and
   inherited by every card here, because they describe this one machine.
     - BAR0 base is firmware-assigned, so it stays log-only; the 16 MiB LENGTH
        is still pinned by BarCheck because PromCheck reads BAR0+0x300000.
     - There is no AMD iGPU on this board: the console comes from the ASPEED
        BMC, so two physical GOPs exist (ASPEED + one RTX). The display gate is
        therefore log-only exactly as in the verified single-card build.
     - DisplayCheck still refuses any GOP that sits on the target BDF, for every
        card but one. The single exception is the last field of the GPU0 row:
        it says "this card may be unlocked even though it owns a GOP", and the
        gate only honours it while at least one OTHER physical GOP (the ASPEED
        one) is still usable. The refusal itself is never deleted - see app.c. */
#ifndef GU_BAR0_BASE
#define GU_BAR0_BASE 0ULL
#endif
#ifndef GU_DISPLAY_LOG_ONLY
#define GU_DISPLAY_LOG_ONLY 1
#endif

/* Measured on this rig (all four: 10DE:2204, class 0300 rev A1):
     GPU0 0000:01:00.0 sub 14541B4C (ZOTAC) vbios 94.02.26.c0.35 display_active=Enabled
     GPU1 0000:41:00.0 sub 38821462 (MSI)   vbios 94.02.26.88.07 display_active=Disabled
     GPU2 0000:81:00.0 sub 38821462 (MSI)   vbios 94.02.26.88.07 display_active=Disabled
     GPU3 0000:C1:00.0 sub 14541B4C (ZOTAC) vbios 94.02.59.00.4e display_active=Disabled

   config[0xc8] measured by the read-only probe on all four cards (RUN05): 0x00050011
   on every one. It is a shared platform value here, not a per-card discriminator, so it
   stays pinned per card anyway - a card that changes it must fail its own gate.
   BAR0 is firmware-assigned per card and is NOT pinned: 0x92000000 / 0xf2000000 /
   0x9b000000 / 0xf8000000 for GPU1 / GPU2 / GPU3 / GPU0 in that same run.

   PROM digests measured per card by the read-only probe (RUN06), each 1 MiB read from
   that card's own BAR0+0x300000. GPU1 and GPU2 carry the SAME digest: they carry the same
   VBIOS (94.02.26.88.07) and the same subsystem, so their ROM images really are identical.
   That is a measurement, not a copy between cards - what distinguishes them is the BDF,
   which is pinned separately. GPU3's pre-existing pin reproduced exactly ("live PROM hash
   matched=1" with no digest printed), which is an independent confirmation of the prose
   that a cold boot always yields the same ROM.

   UnlockAllowed is policy, not a measurement. All four rows are now TRUE: the owner asked
   for a four-card unlock after the three-card path was verified end to end (RUN01: three
   unlocked, retained and clean, Windows up 6 s later, driver 617.42, no code 43). GPU0 is
   the display adapter - it owns the GOP at 0000:01:00.0 - so it is the one row that also
   sets display_may_sit_on_target_gop. What that buys and what it costs:
     - DisplayCheck still refuses any GOP on the target BDF for every card that does not
       carry that flag, and it still refuses GPU0 unless a second physical GOP survives,
       so "unlock the only display path on this machine" stays impossible by construction.
     - Disconnecting GPU0's firmware driver (the driver release step) can blank the UEFI
       console for the rest of the batch. That is why GPU0 is LAST: the first three cards
       finish and log before the console can disappear, and every step is written to the
       file log, which does not depend on the console. The Windows driver re-initialises
       the card after the handoff, so the desktop still comes up.
     - RUN06 recorded the exact refusal this flag relaxes: "GOP[1] sits on target BDF -
       refuse", valid=0. If GPU0 ever stops being the GOP owner on this board, the flag
       becomes inert rather than dangerous.

   ROW ORDER IS EXECUTION ORDER. GPU3 first because it is the one card whose unlocked result
   is already verified, so the batch machinery is exercised on a known outcome before it
   touches a card whose outcome is unknown; then the two production cards; GPU0 last because
   it owns the console GOP and must not be able to take the earlier cards' log with it. */
#define GU_CARD_TABLE(GU_CARD)                                                                     \
  GU_CARD("GPU3", 0, 0xC1, 0, 0, 0x14541B4CU, 0x00050011U,                                        \
          "e23caae3312afa69407c7cc79538875d5cf36e78065ce4c0d615a61bffa7e5bb", TRUE, FALSE)         \
  GU_CARD("GPU1", 0, 0x41, 0, 0, 0x38821462U, 0x00050011U,                                        \
          "d96a2b5eae93db1a2ad4d6b11f7653032b2124e45f96814e573877544620b514", TRUE, FALSE)         \
  GU_CARD("GPU2", 0, 0x81, 0, 0, 0x38821462U, 0x00050011U,                                        \
          "d96a2b5eae93db1a2ad4d6b11f7653032b2124e45f96814e573877544620b514", TRUE, FALSE)         \
  GU_CARD("GPU0", 0, 0x01, 0, 0, 0x14541B4CU, 0x00050011U,                                        \
          "6e6deb3c5f07d0f9f4534a3e1536aac8ddfa34f37d0d16f9528d0f2c31f0ad04", TRUE, TRUE)
