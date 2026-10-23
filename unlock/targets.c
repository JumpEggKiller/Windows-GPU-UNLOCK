/* Multi-target card table implementation (branch local-rig-multitarget).
   Compiled only with -DGU_MULTI_TARGET. */
#include "port.h"
#include "targets.h"
#include "targets_local.h"

#define GU_CARD_EXPAND(Name, Seg, Bus, Dev, Fun, Sub, C8, Prom, Allowed) \
  { (Name), (Seg), (Bus), (Dev), (Fun), (Sub), (C8), (Prom), (Allowed) },

const GU_TARGET GuTargets[] = {GU_CARD_TABLE(GU_CARD_EXPAND)};
const UINTN GuTargetCount = sizeof(GuTargets) / sizeof(GuTargets[0]);

static UINTN Selected;

BOOLEAN GuTargetSelect(UINTN Index) {
  if (Index >= GuTargetCount) return FALSE;
  Selected = Index;
  return TRUE;
}

const GU_TARGET *GuTargetCurrent(VOID) {
  return &GuTargets[Selected < GuTargetCount ? Selected : 0];
}

UINTN GuTargetIndex(VOID) {
  return Selected;
}

BOOLEAN GuTargetPinned(const GU_TARGET *Target) {
  if (Target == NULL) return FALSE;
  if (Target->PromSha256 == NULL || Target->PromSha256[0] == '\0') return FALSE;
  if (Target->ConfigC8 == 0) return FALSE;
  if (Target->Subsystem == 0) return FALSE;
  return TRUE;
}

/* Fail closed on a malformed table: a duplicated BDF would make two cards look
   like one identity, which is exactly the mistake this port must not make. */
BOOLEAN GuTargetTableCheck(const GU_TARGET *Table, UINTN Count) {
  BOOLEAN Allowed = FALSE;
  UINTN I, J;
  if (Table == NULL || Count == 0 || Count > GU_TARGET_MAX) return FALSE;
  for (I = 0; I < Count; ++I) {
    const GU_TARGET *A = &Table[I];
    if (A->Name == NULL || A->Name[0] == '\0') return FALSE;
    if (A->Segment != 0 || A->Bus > 0xffU || A->Device > 0x1fU || A->Function > 7U) return FALSE;
    if (A->Subsystem == 0) return FALSE;
    if (A->UnlockAllowed) Allowed = TRUE;
    for (J = I + 1; J < Count; ++J) {
      const GU_TARGET *B = &Table[J];
      if (A->Segment == B->Segment && A->Bus == B->Bus && A->Device == B->Device &&
          A->Function == B->Function)
        return FALSE;
    }
  }
  return Allowed;
}

BOOLEAN GuTargetTableValid(VOID) {
  return GuTargetTableCheck(GuTargets, GuTargetCount);
}
