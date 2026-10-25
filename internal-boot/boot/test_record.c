/* Every way the end-of-batch record can fail to authorize a Windows transfer.
   The record is the wrapper's only independent evidence that all three cards were
   unlocked and still read unlocked at the end of the batch, so each field, each
   separator and each width is proven here rather than trusted. */
#include "record.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* The exact bytes the child writes for the pinned three-card rig. */
#define ACCEPT "GUH1 0000000000000000 3 3 3 3\n"

static BOOLEAN Parse(const char *Text) {
  GU_HANDOFF_RECORD record;
  return GuHandoffParse(Text,strlen(Text),&record);
}
static BOOLEAN ParseInto(const char *Text,GU_HANDOFF_RECORD *Out) {
  return GuHandoffParse(Text,strlen(Text),Out);
}

int main(void) {
  GU_HANDOFF_RECORD record;

  /* "GUH1 " + 16 + four " N" fields + newline. */
  assert(strlen(ACCEPT)==30);
  assert(GuHandoffParse(ACCEPT,30,&record));
  assert(record.Status==0 && record.Eligible==3 && record.Unlocked==3 &&
    record.Retained==3 && record.Clean==3);
  assert(GuHandoffAccept(&record,3));
  /* A rig expected to unlock a different number of cards is refused either way. */
  assert(!GuHandoffAccept(&record,4));
  assert(!GuHandoffAccept(&record,2));
  assert(!GuHandoffAccept(&record,0));
  assert(!GuHandoffAccept(NULL,3));

  /* Length is authoritative and never inferred: a valid prefix is not enough, and
     a torn or padded file is not a record. */
  assert(!GuHandoffParse(ACCEPT,29,&record));
  assert(!GuHandoffParse(ACCEPT,31,&record));
  assert(!GuHandoffParse(ACCEPT,0,&record));
  assert(!GuHandoffParse(ACCEPT,GU_HANDOFF_MAX+1,&record));
  assert(!GuHandoffParse(NULL,30,&record));
  assert(!GuHandoffParse(ACCEPT,30,NULL));
  char padded[GU_HANDOFF_MAX];
  memset(padded,'A',sizeof(padded));
  memcpy(padded,ACCEPT,30);
  assert(!GuHandoffParse(padded,sizeof(padded),&record));

  /* Magic, hex digits and separators are exact. */
  assert(!Parse("GUH2 0000000000000000 3 3 3 3\n"));
  assert(!Parse("guh1 0000000000000000 3 3 3 3\n"));
  assert(!Parse("GUH1 000000000000000A 3 3 3 3\n"));
  assert(!Parse("GUH1 000000000000000 3 3 3 3\n"));
  assert(!Parse("GUH1 000000000000000g 3 3 3 3\n"));
  assert(!Parse("GUH1 00000000000000003 3 3 3\n"));
  assert(!Parse("GUH1 0000000000000000 3 3 3 3"));
  assert(!Parse("GUH1 0000000000000000 3 3 3 3\nx"));
  assert(!Parse("GUH1 0000000000000000 3 3 3 3 \n"));

  /* Decimal fields: no leading zero, no empty field, no overflow. */
  assert(!Parse("GUH1 0000000000000000 03 3 3 3\n"));
  assert(!Parse("GUH1 0000000000000000  3 3 3\n"));
  assert(!Parse("GUH1 0000000000000000 4294967296 3 3 3\n"));
  assert(!Parse("GUH1 0000000000000000 999999999999 3 3 3\n"));
  /* Multi-digit fields are ordinary; zero is a legal single digit. */
  assert(ParseInto("GUH1 0000000000000000 12 12 12 12\n",&record));
  assert(record.Eligible==12 && record.Unlocked==12 && record.Clean==12);
  assert(GuHandoffAccept(&record,12));
  assert(ParseInto("GUH1 0000000000000000 0 0 0 0\n",&record));
  assert(record.Eligible==0);
  assert(!GuHandoffAccept(&record,0));
  assert(ParseInto("GUH1 0000000000000000 3 0 0 0\n",&record));
  assert(record.Unlocked==0);

  /* Verdict: success is exactly zero, and every count must agree with the expected
     number of allowed cards and with the count before it. */
  assert(ParseInto("GUH1 0000000000000001 3 3 3 3\n",&record));
  assert(record.Status==1 && !GuHandoffAccept(&record,3));
  assert(ParseInto("GUH1 8000000000000003 3 3 3 3\n",&record));
  assert(record.Status==0x8000000000000003ULL && !GuHandoffAccept(&record,3));
  assert(ParseInto("GUH1 ffffffffffffffff 3 3 3 3\n",&record));
  assert(record.Status==0xffffffffffffffffULL && !GuHandoffAccept(&record,3));
  assert(ParseInto("GUH1 0000000000000000 3 2 2 2\n",&record));
  assert(record.Unlocked==2 && !GuHandoffAccept(&record,3));
  assert(ParseInto("GUH1 0000000000000000 3 3 2 2\n",&record));
  assert(record.Retained==2 && !GuHandoffAccept(&record,3));
  assert(ParseInto("GUH1 0000000000000000 3 3 3 2\n",&record));
  assert(record.Clean==2 && !GuHandoffAccept(&record,3));
  /* More unlocked than allowed is as suspicious as fewer: the table is the truth. */
  assert(ParseInto("GUH1 0000000000000000 3 4 4 4\n",&record));
  assert(!GuHandoffAccept(&record,3));
  assert(ParseInto("GUH1 0000000000000000 4 4 4 4\n",&record));
  assert(!GuHandoffAccept(&record,3) && GuHandoffAccept(&record,4));

  puts("internal-boot end-of-batch record policy: PASS");
  return 0;
}
