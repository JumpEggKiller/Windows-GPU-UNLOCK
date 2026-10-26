#ifndef GU_OWNERSHIP_H
#define GU_OWNERSHIP_H
#include "port.h"
#include <Protocol/DriverBinding.h>
#define GU_RELEASE_MAX_CHILDREN 8
typedef struct {
  EFI_HANDLE agent,image;
  VOID *base;
  UINT64 size;
  UINT32 version;
  EFI_DRIVER_BINDING_STOP stop;
  /* Child controllers created below the target. Only a card whose pin allows it
     to own the console may carry any; every other card must have none. */
  EFI_HANDLE children[GU_RELEASE_MAX_CHILDREN];
  UINTN children_count;
} GU_RELEASE_OWNER;
EFI_STATUS GuClaimController(VOID);
EFI_STATUS GuFindReleaseOwner(EFI_SYSTEM_TABLE *Table,GU_RELEASE_OWNER *Owner,BOOLEAN Log);
BOOLEAN GuSameReleaseOwner(const GU_RELEASE_OWNER *A,const GU_RELEASE_OWNER *B);
/* Caller holds TPL_NOTIFY through fresh resolution/validation and any BME clear. */
EFI_STATUS GuRefreshTargetPci(VOID);
#endif
