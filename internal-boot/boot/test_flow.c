/* Fault injection for the internal-boot handoff state machine: every stage's
   non-success status must stop the sequence before the next mutation, and a
   successful Windows transfer must never look like a normal return. */
#include "flow.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int prepares,selects,records,unlocks,windows;
static EFI_STATUS prepareStatus,selectStatus,unlockStatus,windowsStatus;
static int recordFailAt;
static BOOLEAN skipChosen;
static char events[8][40];
static int eventCount;

static EFI_STATUS doPrepare(VOID *Context) {
  (void)Context;prepares++;return prepareStatus;
}
static EFI_STATUS doSelect(VOID *Context,BOOLEAN *SkipUnlock) {
  (void)Context;selects++;*SkipUnlock=skipChosen;return selectStatus;
}
static EFI_STATUS doRecord(VOID *Context,const char *Event,EFI_STATUS Status) {
  (void)Context;(void)Status;records++;
  if(records==recordFailAt)return EFI_DEVICE_ERROR;
  if(eventCount<8) {
    strncpy(events[eventCount],Event,sizeof(events[0])-1);
    events[eventCount][sizeof(events[0])-1]=0;
    eventCount++;
  }
  return EFI_SUCCESS;
}
static EFI_STATUS doUnlock(VOID *Context) {
  (void)Context;unlocks++;return unlockStatus;
}
static EFI_STATUS doWindows(VOID *Context) {
  (void)Context;windows++;return windowsStatus;
}

static GU_HANDOFF_OPS Ops;

static void Reset(void) {
  prepares=selects=records=unlocks=windows=0;
  prepareStatus=selectStatus=unlockStatus=windowsStatus=EFI_SUCCESS;
  recordFailAt=0;skipChosen=FALSE;eventCount=0;
  memset(events,0,sizeof(events));
  Ops.Context=NULL;
  Ops.Prepare=doPrepare;Ops.Select=doSelect;Ops.Record=doRecord;Ops.Unlock=doUnlock;Ops.Windows=doWindows;
}

int main(void) {
  /* A complete run: prepare, unlock, then the Windows transfer. Coming back at all
     means the transfer did not happen, so ABORTED is the documented outcome. */
  Reset();
  assert(GuHandoffFlow(&Ops)==EFI_ABORTED);
  assert(prepares==1 && selects==1 && unlocks==1 && windows==1 && records==5);
  assert(eventCount==5);
  assert(!strcmp(events[0],"windows-preloaded"));
  assert(!strcmp(events[1],"unlock-start"));
  assert(!strcmp(events[2],"unlock-return"));
  assert(!strcmp(events[3],"windows-start"));
  assert(!strcmp(events[4],"windows-return-unexpected"));

  /* Esc: Windows only, and no unlock at all. */
  Reset();skipChosen=TRUE;
  assert(GuHandoffFlow(&Ops)==EFI_ABORTED);
  assert(selects==1 && unlocks==0 && windows==1 && records==4);
  assert(!strcmp(events[1],"skip-unlock"));

  /* Prepare failures stop before the cancel window is even offered. */
  EFI_STATUS prepareFaults[]={EFI_NOT_FOUND,EFI_SECURITY_VIOLATION,EFI_ABORTED,
    EFI_DEVICE_ERROR,EFI_COMPROMISED_DATA,EFI_WARN_UNKNOWN_GLYPH};
  for(UINTN i=0;i<sizeof(prepareFaults)/sizeof(prepareFaults[0]);i++) {
    Reset();prepareStatus=prepareFaults[i];
    assert(GuHandoffFlow(&Ops)==prepareFaults[i]);
    assert(prepares==1 && selects==0 && unlocks==0 && windows==0 && records==0);
  }

  /* Select failures: no unlock, no Windows. */
  EFI_STATUS selectFaults[]={EFI_DEVICE_ERROR,EFI_TIMEOUT,EFI_UNSUPPORTED,EFI_WARN_UNKNOWN_GLYPH};
  for(UINTN i=0;i<sizeof(selectFaults)/sizeof(selectFaults[0]);i++) {
    Reset();selectStatus=selectFaults[i];
    assert(GuHandoffFlow(&Ops)==selectFaults[i]);
    assert(prepares==1 && selects==1 && unlocks==0 && windows==0 && records==1);
  }

  /* Unlock failures: recorded, then returned. Windows is never started. */
  EFI_STATUS unlockFaults[]={EFI_ABORTED,EFI_TIMEOUT,EFI_DEVICE_ERROR,EFI_SECURITY_VIOLATION,
    EFI_WARN_UNKNOWN_GLYPH};
  for(UINTN i=0;i<sizeof(unlockFaults)/sizeof(unlockFaults[0]);i++) {
    Reset();unlockStatus=unlockFaults[i];
    assert(GuHandoffFlow(&Ops)==unlockFaults[i]);
    assert(prepares==1 && selects==1 && unlocks==1 && windows==0 && records==3);
    assert(!strcmp(events[2],"unlock-return"));
  }

  /* A log that cannot be written blocks the following mutation: the record is the
     only durable evidence the next boot can be trusted to leave behind. */
  Reset();recordFailAt=1;
  assert(GuHandoffFlow(&Ops)==EFI_DEVICE_ERROR);
  assert(selects==0 && unlocks==0 && windows==0);
  Reset();recordFailAt=2;
  assert(GuHandoffFlow(&Ops)==EFI_DEVICE_ERROR);
  assert(selects==1 && unlocks==0 && windows==0);
  Reset();recordFailAt=3;
  assert(GuHandoffFlow(&Ops)==EFI_DEVICE_ERROR);
  assert(unlocks==1 && windows==0);
  Reset();recordFailAt=4;
  assert(GuHandoffFlow(&Ops)==EFI_DEVICE_ERROR);
  assert(unlocks==1 && windows==0);

  /* The unlock outcome outranks the log failure that tried to record it. */
  Reset();unlockStatus=EFI_TIMEOUT;recordFailAt=3;
  assert(GuHandoffFlow(&Ops)==EFI_TIMEOUT);
  assert(unlocks==1 && windows==0);

  /* Windows failing to transfer is surfaced, not retried and not hidden. */
  Reset();windowsStatus=EFI_DEVICE_ERROR;
  assert(GuHandoffFlow(&Ops)==EFI_DEVICE_ERROR);
  assert(unlocks==1 && windows==1 && records==5);

  /* Windows returned success and the final log write failed: that is a failure,
     because the handoff cannot be distinguished from a fall-through. */
  Reset();recordFailAt=5;
  assert(GuHandoffFlow(&Ops)==EFI_DEVICE_ERROR);
  assert(windows==1);

  /* An incomplete ops table is rejected before anything runs. */
  Reset();Ops.Windows=NULL;
  assert(GuHandoffFlow(&Ops)==EFI_INVALID_PARAMETER);
  assert(prepares==0 && records==0);
  Reset();Ops.Prepare=NULL;
  assert(GuHandoffFlow(&Ops)==EFI_INVALID_PARAMETER);
  Reset();
  assert(GuHandoffFlow(NULL)==EFI_INVALID_PARAMETER);
  assert(prepares==0);

  puts("internal-boot handoff flow fault injection: PASS");
  return 0;
}
