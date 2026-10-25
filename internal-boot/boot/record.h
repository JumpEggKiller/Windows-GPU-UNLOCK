/* Windows GPU UNLOCK internal boot: the end-of-batch record the unlock child
   leaves behind, and the rule that decides whether the wrapper may start Windows.
   Deliberately free of firmware types beyond UINTN so the host tests can prove
   every rejection path. GPL-2.0-only. */
#pragma once
#include <Uefi.h>

/* "GUH1 " + 16 hex + four decimal fields + "\n" = 34 bytes for the pinned rig. */
#define GU_HANDOFF_MAGIC "GUH1 "
#define GU_HANDOFF_MAX 96

typedef struct {
  UINT64 Status;
  UINT32 Eligible,Unlocked,Retained,Clean;
} GU_HANDOFF_RECORD;

/* Parses exactly what the child writes and nothing else: fixed-width lower-case
   hex, single-space separators, unpadded decimal fields, one trailing newline.
   Returns FALSE for any deviation, including a torn or truncated file. */
static inline BOOLEAN GuHandoffParse(const char *Text,UINTN Length,GU_HANDOFF_RECORD *Out) {
  if(!Text || !Out || Length<5+16+4*2+1 || Length>GU_HANDOFF_MAX)return FALSE;
  UINTN at=0;
  for(UINTN i=0;i<5;i++)if(Text[at++]!=GU_HANDOFF_MAGIC[i])return FALSE;
  UINT64 status=0;
  for(UINTN i=0;i<16;i++) {
    char c=Text[at++];unsigned digit;
    if(c>='0' && c<='9')digit=(unsigned)(c-'0');
    else if(c>='a' && c<='f')digit=(unsigned)(c-'a'+10);
    else return FALSE;
    status=(status<<4)|digit;
  }
  UINT32 field[4];
  for(UINTN f=0;f<4;f++) {
    if(at>=Length || Text[at++]!=' ')return FALSE;
    if(at>=Length)return FALSE;
    UINT32 value=0;UINTN digits=0;
    while(at<Length && Text[at]>='0' && Text[at]<='9') {
      UINT32 digit=(UINT32)(Text[at]-'0');
      if(value>(0xffffffffU-digit)/10U)return FALSE;
      value=value*10+digit;digits++;at++;
    }
    if(!digits)return FALSE;
    if(digits>1 && Text[at-digits]=='0')return FALSE;
    field[f]=value;
  }
  if(at+1!=Length || Text[at]!='\n')return FALSE;
  Out->Status=status;
  Out->Eligible=field[0];Out->Unlocked=field[1];Out->Retained=field[2];Out->Clean=field[3];
  return TRUE;
}

/* The only acceptable verdict. Expected is the number of cards the build's own
   target table allows, so a run that unlocked "everything it found" on a rig that
   lost a card is still refused. */
static inline BOOLEAN GuHandoffAccept(const GU_HANDOFF_RECORD *Record,UINT32 Expected) {
  if(!Record || !Expected)return FALSE;
  return Record->Status==EFI_SUCCESS &&
    Record->Eligible==Expected &&
    Record->Unlocked==Record->Eligible &&
    Record->Retained==Record->Unlocked &&
    Record->Clean==Record->Unlocked;
}
