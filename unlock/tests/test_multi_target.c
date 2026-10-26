/* Multi-target table test (branch local-rig-multitarget; NOT upstream).
   Proves the ported per-card pins match each card by its OWN identity and no
   card is accepted under another card's identity. Compile with -DGU_MULTI_TARGET.
   The rig has three distinct identities: GPU0/GPU3 share the ZOTAC subsystem
   14541B4C but differ in bus AND VBIOS; GPU1/GPU2 are MSI 38821462. */
#include "../checks.h"
#include <stdio.h>
#include <string.h>

static unsigned Checks, Failures;

static void Check(int Pass, const char *Name) {
  ++Checks;
  if (!Pass) { ++Failures; fprintf(stderr, "FAIL %s\n", Name); }
}

/* Passing config fixture: same shape as test_machine_local.c Basic(), with the
   subsystem supplied so one fixture serves every card. */
static void Basic(UINT32 C[64], UINT32 Subsystem) {
  memset(C, 0, 256);
  C[0] = GU_BOARD_ID;
  C[1] = 0x00100002;            /* command: memory on, BME off */
  C[2] = 0x030000a1;            /* class display, rev A1 (verified on all four cards) */
  C[3] = 0x00800000;            /* header type device, status cap-list bit */
  C[0x2c / 4] = Subsystem;
  C[0x34 / 4] = 0x40;
  C[0x40 / 4] = 0x00034801;     /* PM cap, next 0x48, D0 */
  C[0x48 / 4] = 0x00020010;     /* PCIe cap v2, end of chain, FLR-capable */
  C[0x4c / 4] = 0x10000000;     /* Device Cap bit28 FLR */
}

int main(void) {
  UINT32 C[64];
  GU_CAPS Caps;
  UINTN I, J;
  char Name[160];
#ifdef GU_MULTI_TARGET
  printf("multi_target: targets=%u max=%u\n", (unsigned)GuTargetCount, (unsigned)GU_TARGET_MAX);
  Check(GuTargetCount == 4, "table lists four cards");
  Check(GuTargetTableValid(), "table identity is well formed and unique");

  /* Every card is matched by its own BDF+subsystem and by nothing else. */
  for (I = 0; I < GuTargetCount; ++I) {
    Check(GuTargetSelect(I), "select in range");
    Check(GuTargetIndex() == I, "selection index follows");
    Check(GuTargetCurrent() == &GuTargets[I], "current target follows selection");
    Check(GU_TARGET_BUS == GuTargets[I].Bus, "per-card bus macro");
    Check(GU_BOARD_SUBSYSTEM == GuTargets[I].Subsystem, "per-card subsystem macro");
    for (J = 0; J < GuTargetCount; ++J) {
      const GU_TARGET *T = &GuTargets[J];
      snprintf(Name, sizeof(Name), "%s accepts %s identity", GuTargets[I].Name, T->Name);
      Basic(C, T->Subsystem);
      Check(!!GuCheckConfig(C, T->Segment, T->Bus, T->Device, T->Function, &Caps) == (I == J), Name);
      if (I != J) {
        snprintf(Name, sizeof(Name), "%s rejects %s BDF with its own subsystem",
          GuTargets[I].Name, T->Name);
        Basic(C, GuTargets[I].Subsystem);
        Check(!GuCheckConfig(C, T->Segment, T->Bus, T->Device, T->Function, &Caps), Name);
      }
    }
  }

  /* Out-of-range selection must be refused, not clamped. */
  Check(!GuTargetSelect(GuTargetCount), "select rejects index == count");
  Check(!GuTargetSelect(GU_TARGET_MAX), "select rejects index beyond max");

  /* Pin state is derived, never asserted from a name: a card is pinned exactly when it
     carries all three per-card values. Hardcoding "only GPU3 is pinned" made this test a
     snapshot of one build's pins, which breaks the moment the probe fills in another card -
     and says nothing about whether the derivation is right. */
  for (I = 0; I < GuTargetCount; ++I) {
    const GU_TARGET *T = &GuTargets[I];
    BOOLEAN Expect = (T->PromSha256 && T->PromSha256[0] && T->ConfigC8 != 0 && T->Subsystem != 0)
                       ? TRUE : FALSE;
    snprintf(Name, sizeof(Name), "%s pinned=%u matches its own pin fields", T->Name,
      (unsigned)Expect);
    Check(GuTargetPinned(T) == Expect, Name);
  }
  Check(GuTargetPinned(NULL) == FALSE, "null target is not pinned");
  {
    /* A card missing any single field must not count as pinned. */
    GU_TARGET T;
    memset(&T, 0, sizeof(T));
    T.Name = "X"; T.Bus = 0x42; T.Subsystem = 0x11112222U; T.ConfigC8 = 0x00050011U;
    T.PromSha256 = "";
    Check(!GuTargetPinned(&T), "empty PROM pin is not pinned");
    T.PromSha256 = "aa";
    Check(GuTargetPinned(&T), "all three fields present is pinned");
    T.ConfigC8 = 0;
    Check(!GuTargetPinned(&T), "zero c8 pin is not pinned");
    T.ConfigC8 = 0x00050011U; T.Subsystem = 0;
    Check(!GuTargetPinned(&T), "zero subsystem is not pinned");
  }

  /* config[0xc8]: a pinned card must match exactly; an unpinned card is only
     observable where the build cannot arm anyway. GPU3 is located by name, never by
     index - the row order is execution order and is expected to change. */
  {
    UINTN G3 = GuTargetCount;
    for (I = 0; I < GuTargetCount; ++I)
      if (strcmp(GuTargets[I].Name, "GPU3") == 0) G3 = I;
    Check(G3 < GuTargetCount, "GPU3 row present");
    if (G3 < GuTargetCount) {
      Check(GuTargetSelect(G3) && GuTargetIndex() == G3, "GPU3 selected by name");
      Check(GuTargets[G3].ConfigC8 == 0x00050011U, "GPU3 c8 pin is the measured value");
      Check(GuTargetPinned(&GuTargets[G3]), "GPU3 is fully pinned");
    }
  }
  Check(GU_CONFIG_C8_OK(0x00050011U), "pinned c8 accepted");
  Check(!GU_CONFIG_C8_OK(0x00050010U), "pinned c8 mismatch rejected");
  Check(!GU_CONFIG_C8_OK(0U), "pinned c8 zero rejected");
  for (I = 0; I < GuTargetCount; ++I) {
    if (GuTargets[I].ConfigC8 != 0) continue;
    GuTargetSelect(I);
#if GU_PREFLIGHT_ONLY
    snprintf(Name, sizeof(Name), "%s unpinned c8 observable in preflight only", GuTargets[I].Name);
    Check(GU_CONFIG_C8_OK(0x12345678U), Name);
#else
    snprintf(Name, sizeof(Name), "%s unpinned c8 fails closed when arming", GuTargets[I].Name);
    Check(!GU_CONFIG_C8_OK(0x12345678U), Name);
    snprintf(Name, sizeof(Name), "%s unpinned c8 zero fails closed when arming", GuTargets[I].Name);
    Check(!GU_CONFIG_C8_OK(0U), Name);
#endif
  }

  /* Negative tables: malformed identity must never validate. */
  {
    GU_TARGET T[GU_TARGET_MAX];
    memset(T, 0, sizeof(T));
    T[0].Name = "A"; T[0].Bus = 0x41; T[0].Subsystem = 1; T[0].UnlockAllowed = TRUE;
    Check(GuTargetTableCheck(T, 1), "single well-formed row accepted");
    T[1] = T[0];
    Check(!GuTargetTableCheck(T, 2), "duplicate BDF rejected");
    T[1].Name = "B"; T[1].Bus = 0x42;
    Check(GuTargetTableCheck(T, 2), "distinct BDF accepted");
    T[1].Bus = 0x100;
    Check(!GuTargetTableCheck(T, 2), "bus beyond 8 bits rejected");
    T[1].Bus = 0x42; T[1].Device = 0x20;
    Check(!GuTargetTableCheck(T, 2), "device beyond 5 bits rejected");
    T[1].Device = 0; T[1].Function = 8;
    Check(!GuTargetTableCheck(T, 2), "function beyond 3 bits rejected");
    T[1].Function = 0; T[1].Segment = 1;
    Check(!GuTargetTableCheck(T, 2), "nonzero segment rejected");
    T[1].Segment = 0; T[1].Subsystem = 0;
    Check(!GuTargetTableCheck(T, 2), "zero subsystem rejected");
    T[1].Subsystem = 1; T[1].Name = "";
    Check(!GuTargetTableCheck(T, 2), "empty name rejected");
    T[1].Name = NULL;
    Check(!GuTargetTableCheck(T, 2), "null name rejected");
    T[1].Name = "B"; T[0].UnlockAllowed = FALSE; T[1].UnlockAllowed = FALSE;
    Check(!GuTargetTableCheck(T, 2), "no unlockable row rejected");
    T[0].UnlockAllowed = TRUE;
    Check(!GuTargetTableCheck(T, 0), "empty table rejected");
    Check(!GuTargetTableCheck(T, GU_TARGET_MAX + 1u), "oversized table rejected");
    Check(!GuTargetTableCheck(NULL, 1), "null table rejected");
    /* The display exception is policed by the table itself: exactly one card may
       own a GOP on its own BDF, and it must be a card that can be unlocked.
       Without this, two rows could each blank the console. */
    T[0].DisplayMaySitOnTargetGop = TRUE;
    Check(GuTargetTableCheck(T, 2), "one display-permitted unlockable row accepted");
    T[1].DisplayMaySitOnTargetGop = TRUE;
    Check(!GuTargetTableCheck(T, 2), "two display-permitted rows rejected");
    T[1].DisplayMaySitOnTargetGop = FALSE;
    T[1].DisplayMaySitOnTargetGop = TRUE; T[1].UnlockAllowed = FALSE;
    Check(!GuTargetTableCheck(T, 2), "display permission on a read-only row rejected");
    T[1].DisplayMaySitOnTargetGop = FALSE; T[0].DisplayMaySitOnTargetGop = TRUE;
    T[0].UnlockAllowed = FALSE;
    Check(!GuTargetTableCheck(T, 2), "display permission without any unlockable row rejected");
    T[0].UnlockAllowed = TRUE;
    T[0].DisplayMaySitOnTargetGop = FALSE;
    Check(GuTargetTableCheck(T, 2), "removing the permission is accepted again");
  }
  /* The rig table: four cards, four of them unlockable, and exactly one row is the
     display exception. This is the shape the four-card port was verified against. */
  {
    UINTN Eligible = 0, Permitted = 0, G0 = GuTargetCount;
    for (I = 0; I < GuTargetCount; ++I) {
      if (GuTargets[I].UnlockAllowed) ++Eligible;
      if (GuTargets[I].DisplayMaySitOnTargetGop) ++Permitted;
      if (strcmp(GuTargets[I].Name, "GPU0") == 0) G0 = I;
    }
    Check(GuTargetCount == 4, "four cards are pinned");
    Check(Eligible == 4, "all four cards are unlockable");
    Check(Permitted == 1, "exactly one card owns the display exception");
    Check(G0 < GuTargetCount, "GPU0 row present");
    if (G0 < GuTargetCount) {
      Check(GuTargets[G0].UnlockAllowed, "GPU0 is unlockable in the four-card port");
      Check(GuTargets[G0].DisplayMaySitOnTargetGop, "GPU0 carries the display exception");
      Check(G0 == GuTargetCount - 1, "GPU0 executes last so the console survives the first cards");
      Check(GuTargetPinned(&GuTargets[G0]), "GPU0 is still fully pinned");
    }
    for (I = 0; I < GuTargetCount; ++I) {
      if (strcmp(GuTargets[I].Name, "GPU0") == 0) continue;
      snprintf(Name, sizeof(Name), "%s is not the display exception", GuTargets[I].Name);
      Check(!GuTargets[I].DisplayMaySitOnTargetGop, Name);
    }
  }
#else
  printf("multi_target test requires -DGU_MULTI_TARGET\n");
  (void)C; (void)Caps; (void)I; (void)J; (void)Name;
  return 2;
#endif
  if (Failures) { fprintf(stderr, "%u/%u failed\n", Failures, Checks); return 1; }
  printf("PASS %u multi-target selection checks\n", Checks);
  return 0;
}
