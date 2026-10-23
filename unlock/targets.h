/* Multi-target card table (branch local-rig-multitarget; NOT upstream).
   GPU-UNLOCK-C1: one UEFI run processes several BDFs, each against its OWN
   device identity and its OWN hard pins. Nothing here may inherit another
   card's values: every field is either measured on that card or left
   deliberately unpinned, in which case the build cannot arm for it.

   Execution order is the table order (index 0 runs first). The order is chosen
   so that the card carrying the UEFI console GOP runs LAST: losing the console
   in the middle of a batch would take the run log with it. */
#pragma once
#include <Uefi.h>

#define GU_TARGET_MAX 4

typedef struct {
  const char *Name;          /* report label, e.g. "GPU1" */
  UINTN Segment, Bus, Device, Function; /* exact BDF; must be unique in table */
  UINT32 Subsystem;          /* config[0x2c], measured per card; never copied */
  UINT32 ConfigC8;           /* config[0xc8], measured per card; 0 = unpinned */
  const char *PromSha256;    /* 1 MiB PROM hash, measured per card; "" = unpinned */
  BOOLEAN UnlockAllowed;     /* FALSE = read-only probe for this card, always */
} GU_TARGET;

extern const GU_TARGET GuTargets[];
extern const UINTN GuTargetCount;

BOOLEAN GuTargetSelect(UINTN Index);
const GU_TARGET *GuTargetCurrent(VOID);
UINTN GuTargetIndex(VOID);
/* TRUE only when subsystem, config[0xc8] and PROM hash are all pinned. */
BOOLEAN GuTargetPinned(const GU_TARGET *Target);
/* Duplicate-BDF / bad-BDF / count guard. Split out so tests can feed
   synthetic tables: a duplicated identity must never validate. */
BOOLEAN GuTargetTableCheck(const GU_TARGET *Table, UINTN Count);
BOOLEAN GuTargetTableValid(VOID);

/* Values consumed by port.h, checks.c, port.c and app.c exactly where the
   single-card build used its compile-time constants. Keeping the same names
   means the audited gate expressions are unchanged: only the source of the
   expected value moves from a #define to the selected card. */
#define GU_TARGET_SEGMENT (GuTargetCurrent()->Segment)
#define GU_TARGET_BUS (GuTargetCurrent()->Bus)
#define GU_TARGET_DEVICE (GuTargetCurrent()->Device)
#define GU_TARGET_FUNCTION (GuTargetCurrent()->Function)
#define GU_BOARD_SUBSYSTEM (GuTargetCurrent()->Subsystem)
#define GU_PROM_SHA256_LOCAL (GuTargetCurrent()->PromSha256)
#define GU_CONFIG_C8_PIN (GuTargetCurrent()->ConfigC8)
