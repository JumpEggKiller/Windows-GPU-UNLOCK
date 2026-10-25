/* Windows GPU UNLOCK internal boot: the direct-handoff state machine.
   GPL-2.0-only. */
#pragma once
#include <Uefi.h>

typedef struct {
  VOID *Context;
  EFI_STATUS (*Prepare)(VOID *Context);
  EFI_STATUS (*Select)(VOID *Context,BOOLEAN *SkipUnlock);
  EFI_STATUS (*Record)(VOID *Context,const char *Event,EFI_STATUS Status);
  EFI_STATUS (*Unlock)(VOID *Context);
  EFI_STATUS (*Windows)(VOID *Context);
} GU_HANDOFF_OPS;

/* Prepare -> Select -> (Unlock) -> Windows.
   Every stage's non-success status is returned unchanged and no later stage runs
   after one fails, so a failed unlock can never reach the Windows transfer by
   accident — including a warning, which is not proof that a stage did its job.
   A successful Windows handoff does not return; if it does, that is reported as
   EFI_ABORTED instead of falling through to the firmware boot order. */
EFI_STATUS GuHandoffFlow(const GU_HANDOFF_OPS *Ops);
