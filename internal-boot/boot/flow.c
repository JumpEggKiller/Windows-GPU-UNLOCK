/* Windows GPU UNLOCK internal boot: the direct-handoff state machine.
   GPL-2.0-only. */
#include "flow.h"

/* Strict on purpose: a status that is neither success nor an error (a UEFI
   warning) is still not proof that the stage did its job, so it stops the
   handoff exactly like an error would. The unlock child applies the same rule
   under automatic boot. */
#define GU_FLOW_STEP(Call) do {status=(Call);if(status!=EFI_SUCCESS)return status;} while(0)

EFI_STATUS GuHandoffFlow(const GU_HANDOFF_OPS *Ops) {
  if(!Ops || !Ops->Prepare || !Ops->Select || !Ops->Record || !Ops->Unlock || !Ops->Windows)
    return EFI_INVALID_PARAMETER;
  EFI_STATUS status=EFI_SUCCESS;
  BOOLEAN skip=FALSE;

  GU_FLOW_STEP(Ops->Prepare(Ops->Context));
  GU_FLOW_STEP(Ops->Record(Ops->Context,"windows-preloaded",EFI_SUCCESS));
  GU_FLOW_STEP(Ops->Select(Ops->Context,&skip));
  GU_FLOW_STEP(Ops->Record(Ops->Context,skip?"skip-unlock":"unlock-start",EFI_SUCCESS));
  if(!skip) {
    status=Ops->Unlock(Ops->Context);
    /* The unlock status is the outcome that matters; a log failure while
       recording it must not mask a hardware failure. */
    EFI_STATUS logged=Ops->Record(Ops->Context,"unlock-return",status);
    if(status!=EFI_SUCCESS)return status;
    if(logged!=EFI_SUCCESS)return logged;
  }
  GU_FLOW_STEP(Ops->Record(Ops->Context,"windows-start",EFI_SUCCESS));
  status=Ops->Windows(Ops->Context);
  EFI_STATUS logged=Ops->Record(Ops->Context,"windows-return-unexpected",status);
  if(status!=EFI_SUCCESS)return status;
  return logged!=EFI_SUCCESS?logged:EFI_ABORTED;
}
