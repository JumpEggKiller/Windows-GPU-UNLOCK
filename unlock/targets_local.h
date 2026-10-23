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
   prom_sha256, unlock_allowed. Table order is execution order; the console GOP
   card (GPU0) is last on purpose. */
#pragma once

/* Rig-level facts, NOT card identity: identical in machine_local.h and
   inherited by every card here, because they describe this one machine.
     - BAR0 base is firmware-assigned, so it stays log-only; the 16 MiB LENGTH
       is still pinned by BarCheck because PromCheck reads BAR0+0x300000.
     - There is no AMD iGPU on this board: the console comes from the ASPEED
       BMC, so two physical GOPs exist (ASPEED + one RTX). The display gate is
       therefore log-only exactly as in the verified single-card build. The
       per-card safety property is NOT relaxed: DisplayCheck still refuses any
       GOP that sits on the target BDF (app.c), which is what protects GPU0. */
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
   0x9b000000 / 0xf8000000 for GPU1 / GPU2 / GPU3 / GPU0 in that same run. */
#define GU_CARD_TABLE(GU_CARD)                                                                     \
  GU_CARD("GPU1", 0, 0x41, 0, 0, 0x38821462U, 0x00050011U, "", TRUE)                               \
  GU_CARD("GPU2", 0, 0x81, 0, 0, 0x38821462U, 0x00050011U, "", TRUE)                               \
  GU_CARD("GPU3", 0, 0xC1, 0, 0, 0x14541B4CU, 0x00050011U,                                        \
          "e23caae3312afa69407c7cc79538875d5cf36e78065ce4c0d615a61bffa7e5bb", TRUE)                \
  GU_CARD("GPU0", 0, 0x01, 0, 0, 0x14541B4CU, 0x00050011U, "", TRUE)
