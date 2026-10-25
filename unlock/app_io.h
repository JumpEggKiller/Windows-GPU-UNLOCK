#pragma once
#include "port.h"
EFI_STATUS GuIoOpen(EFI_HANDLE Image,EFI_SYSTEM_TABLE *Table);
EFI_STATUS GuIoClose(VOID);
EFI_STATUS GuLoadAssets(VOID);
VOID GuReleaseAssets(VOID);
BOOLEAN GuLogReady(VOID);
BOOLEAN GuConsoleFault(VOID);
UINTN GuLogDefects(VOID);
VOID GuConsole(const char *Text);
#if defined(GU_INTERNAL_BOOT)
/* Durable end-of-batch record read by the parent handoff wrapper. */
EFI_STATUS GuWriteHandoff(UINT64 Status,UINT32 Eligible,UINT32 Unlocked,UINT32 Retained,UINT32 Clean);
#endif
