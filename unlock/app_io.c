/* Modified 2026-10-19/20 for Windows GPU UNLOCK; changes documented in CHANGES.md. */ #include "app_io.h"
#include "compat/compat.h"
#include "format.h"
#include "sha256.h"
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Guid/FileInfo.h>
#if defined(GU_INTERNAL_BOOT)
/* Shared device-path policy. The internal build must accept the dedicated ESP
   under the same strict node checks the USB path uses. */
#include "../internal-boot/boot/media.h"
#endif
static EFI_GUID LoadedGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID,PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID,
  FsGuid=EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID,InfoGuid=EFI_FILE_INFO_ID;
static EFI_SYSTEM_TABLE *Table;
static EFI_FILE_PROTOCOL *Root,*Parent,*Run,*Report;
static BOOLEAN LogFault,ConsoleFault;
static UINTN LogDefects;
typedef struct {const char *name;CHAR16 *file;UINTN size;const char *hash;} ASSET_SPEC;
static const ASSET_SPEC Specs[]={
 {"gpu-unlock/610.43.03/booter_load_ga102.bin",L"ASSETS\\booter_load_ga102.bin",61256,"056cbc064a888f80717726c54d7f64fcd68044d123870c95a74f37f4975dcaa4"},
 {"gpu-unlock/610.43.03/v67-ga102-610.43.03.bin",L"ASSETS\\v67-ga102-610.43.03.bin",64000,"2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197"},
 {"gpu-unlock/610.43.03/gsp_ga10x.bin",L"ASSETS\\gsp_ga10x.bin",84277400,"572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a"},
 {"gpu-unlock/610.43.03/gsp_boot_ga102.bin",L"ASSETS\\gsp_boot_ga102.bin",24576,"3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768"},
 {"gpu-unlock/610.43.03/gsp_boot_desc_ga102.bin",L"ASSETS\\gsp_boot_desc_ga102.bin",84,"cc5a3fc1f4c47f2fe107b1b68f0176d8a448e6dec84b575e5560ccef5262bf15"}
};
static VOID LogError(VOID){LogFault=TRUE;if(Gu.armed)Gu.fault=TRUE;}
/* A console failure is not a log failure. The USB report is the audit artifact; the
   screen is a convenience. A dead console must not take the write path down with it.
   The armed-transaction containment still trips, because a card must not be left armed
   when nothing can be reported. */
static VOID ConsoleError(VOID){ConsoleFault=TRUE;if(Gu.armed)Gu.fault=TRUE;}
VOID GuConsole(const char *Text) {
  if(!Table || !Table->ConOut || !Table->ConOut->OutputString){ConsoleError();return;}
  while(*Text) {
    CHAR16 line[128];UINTN n=0;
    while(*Text && n<126){if(*Text=='\n')line[n++]='\r';line[n++]=(UINT8)*Text++;}
    line[n]=0;if(EFI_ERROR(Table->ConOut->OutputString(Table->ConOut,line))){ConsoleError();return;}
  }
}
BOOLEAN GuConsoleFault(VOID){return ConsoleFault;}
UINTN GuLogDefects(VOID){return LogDefects;}
VOID GuLogText(const char *Text) {
  GuConsole(Text);
  if(!Report || LogFault){LogError();return;}
  UINTN expected=strlen(Text),written=expected;
  EFI_STATUS status=Report->Write(Report,&written,(VOID *)Text);
  if(EFI_ERROR(status) || written!=expected || EFI_ERROR(Report->Flush(Report)))LogError();
}
/* The custom formatter refuses conversions it does not implement and reports SIZE_MAX.
   Turning that into LogError() is wrong: a single bad format string would silence every
   later line, i.e. the audit log dies of a typo. RUN04 and RUN05 both lost their per-card
   status table and their FINAL line exactly that way (the offender was "%-4s"; width is
   implemented for integers only). Record the defect, keep writing, and count it so the
   FINAL line can declare it. */
VOID GuLog(const char *Format,...) {
  char text[1024];va_list args;
  if(!Format){LogDefects++;GuConsole("Log format is null.\n");return;}
  va_start(args,Format);
  size_t n=GuFormatV(text,sizeof(text),Format,args);va_end(args);
  if(n==SIZE_MAX) {
    LogDefects++;
    GuLogText("LOG DEFECT: format string rejected by GuFormatV; raw format follows.\n");
    GuLogText(Format);
    GuLogText("\n");
    return;
  }
  if(n>=sizeof(text)) {
    LogDefects++;
    GuLogText(text);
    GuLogText(" [line truncated]\n");
    return;
  }
  GuLogText(text);
}
BOOLEAN GuLogReady(VOID){return Report && !LogFault;}
/* Where this image may run from. The USB build keeps its original rule verbatim;
   the internal build additionally accepts the dedicated ESP, and the automatic
   child accepts *only* that partition - an automatic boot that found itself on a
   USB stick would be running from media the installer never verified. */
static BOOLEAN UsbPath(EFI_HANDLE Handle) {
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  if(EFI_ERROR(Table->BootServices->HandleProtocol(Handle,&PathGuid,(VOID **)&path)) || !path)return FALSE;
#if defined(GU_AUTOMATIC_BOOT)
  return GuPathIsPartition(path,&GuInternalPartition);
#elif defined(GU_INTERNAL_BOOT)
  return GuAllowedMediaPath(path,TRUE);
#else
  UINTN total=0;BOOLEAN usb=FALSE;
  for(UINTN nodes=0;nodes<64 && total+4<=4096;nodes++) {
    UINTN n=path->Length[0]+((UINTN)path->Length[1]<<8);
    if(n<4 || n>4096-total)return FALSE;
    if(path->Type==MESSAGING_DEVICE_PATH && path->SubType==MSG_USB_DP && n==sizeof(USB_DEVICE_PATH))usb=TRUE;
    if(path->Type==END_DEVICE_PATH_TYPE)return usb && n==4 && path->SubType==END_ENTIRE_DEVICE_PATH_SUBTYPE;
    total+=n;path=(VOID *)((UINT8 *)path+n);
  }
  return FALSE;
#endif
}
static EFI_STATUS Metadata(EFI_FILE_PROTOCOL *File,BOOLEAN Directory,UINTN Expected) {
  union {EFI_FILE_INFO info;UINT8 bytes[512];} data;UINTN n=sizeof(data);
  EFI_STATUS status=File->GetInfo(File,&InfoGuid,&n,&data);
  if(EFI_ERROR(status))return status;
  if(n<SIZE_OF_EFI_FILE_INFO || n>sizeof(data) || data.info.Size>n || data.info.Size<SIZE_OF_EFI_FILE_INFO ||
    !!(data.info.Attribute&EFI_FILE_DIRECTORY)!=!!Directory ||
    (!Directory && data.info.FileSize!=Expected))return EFI_COMPROMISED_DATA;
  return EFI_SUCCESS;
}
EFI_STATUS GuIoOpen(EFI_HANDLE Image,EFI_SYSTEM_TABLE *St) {
  Table=St;Root=Parent=Run=Report=NULL;LogFault=FALSE;memset(GuAssets,0,sizeof(GuAssets));
  EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs=NULL;
  EFI_STATUS status=Table->BootServices->HandleProtocol(Image,&LoadedGuid,(VOID **)&loaded);
  if(EFI_ERROR(status) || !loaded || !UsbPath(loaded->DeviceHandle))return EFI_UNSUPPORTED;
  status=Table->BootServices->HandleProtocol(loaded->DeviceHandle,&FsGuid,(VOID **)&fs);
  if(EFI_ERROR(status) || !fs)return EFI_UNSUPPORTED;
  status=fs->OpenVolume(fs,&Root);if(EFI_ERROR(status) || !Root)return EFI_DEVICE_ERROR;
#if defined(GU_EXPERIMENTAL_3090)
  status=Root->Open(Root,&Parent,L"\\RTX3090-UNLOCK",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0);
#else
  status=Root->Open(Root,&Parent,L"\\RTX3090-PREFLIGHT",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0);
#endif
  if(EFI_ERROR(status) || !Parent)return EFI_NOT_FOUND;
  status=Metadata(Parent,TRUE,0);if(EFI_ERROR(status))return status;
#if defined(GU_INTERNAL_BOOT)
  /* A clean record left by an earlier boot must never authorize this one, so it is
     removed before the first hardware gate runs. Anything but "was not there" is a
     real failure: an undeletable stale record means the volume is not writable. */
  {EFI_FILE_PROTOCOL *stale=NULL;
   EFI_STATUS old=Parent->Open(Parent,&stale,L"HANDOFF.ST",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0);
   if(!EFI_ERROR(old)) {
     if(!stale)return EFI_DEVICE_ERROR;
     old=stale->Delete(stale);
     if(EFI_ERROR(old))return old;
   } else if(old!=EFI_NOT_FOUND)return old;}
#endif
#if defined(GU_AUTOMATIC_BOOT)
  /* Automatic boots number their runs differently: the parent wrapper already owns
     AUTO000000-style names for its own log, so the run directories get a six-digit
     name that cannot collide with them or with the manual RUNnn series. */
  const UINTN slots=1000000;
#else
  const UINTN slots=100;
#endif
  for(UINTN slot=0;slot<slots;slot++) {
#if defined(GU_AUTOMATIC_BOOT)
    CHAR16 name[]=L"AUTO000000";UINTN number=slot;
    for(UINTN digit=0;digit<6;digit++){name[9-digit]=(CHAR16)('0'+number%10);number/=10;}
#else
    CHAR16 name[]=L"RUN00";name[3]=(CHAR16)('0'+slot/10);name[4]=(CHAR16)('0'+slot%10);
#endif
    EFI_FILE_PROTOCOL *existing=NULL;
    status=Parent->Open(Parent,&existing,name,EFI_FILE_MODE_READ,0);
    if(!EFI_ERROR(status)) {
      if(!existing || EFI_ERROR(existing->Close(existing)))return EFI_DEVICE_ERROR;continue;
    }
    if(status!=EFI_NOT_FOUND)return status;
    status=Parent->Open(Parent,&Run,name,EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,EFI_FILE_DIRECTORY);
    if(EFI_ERROR(status) || !Run)return EFI_DEVICE_ERROR;
    status=Metadata(Run,TRUE,0);if(EFI_ERROR(status))return status;
    status=Run->Open(Run,&existing,L"REPORT.TXT",EFI_FILE_MODE_READ,0);
    if(!EFI_ERROR(status)){if(existing)existing->Close(existing);return EFI_ALREADY_STARTED;}
    if(status!=EFI_NOT_FOUND)return status;
    status=Run->Open(Run,&Report,L"REPORT.TXT",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,0);
    if(EFI_ERROR(status) || !Report)return EFI_DEVICE_ERROR;
#if defined(GU_AUTOMATIC_BOOT)
    GuLog("RTX3090 MULTI AUTOMATIC INTERNAL UNLOCK\nAUTO%06u\nEsc cancels; exact per-card gates and one transaction per card only.\n",(unsigned)slot);
#elif defined(GU_EXPERIMENTAL_3090)
    GuLog("RTX3090 AMD EXPERIMENTAL MANUAL UNLOCK\nRUN%02u\nManual U starts one hardware transaction; Esc or timeout cancels. Hardware success unverified.\n",(unsigned)slot);
#else
    GuLog("RTX3090 AMD read-only cold-state preflight\nRUN%02u\nCannot arm: GPU writes, DMA, reset and driver release are blocked.\n",(unsigned)slot);
#endif
    return GuLogReady()?EFI_SUCCESS:EFI_DEVICE_ERROR;
  }
  return EFI_VOLUME_FULL;
}
#if defined(GU_INTERNAL_BOOT)
/* ---- end-of-batch hand-off record ------------------------------------------
   The parent wrapper refuses to start Windows unless this record proves the batch
   finished clean, so it is written exactly once, last, after the retention pass.
   The layout is fixed-width on purpose: the reader rejects a short or torn record
   by length alone and never has to interpret a partial line. */
static UINTN PutDecimal(char *out,UINT32 value) {
  char digits[10];UINTN n=0;
  do {digits[n++]=(char)('0'+(value%10));value/=10;} while(value);
  for(UINTN i=0;i<n;i++)out[i]=digits[n-1-i];
  return n;
}
EFI_STATUS GuWriteHandoff(UINT64 Status,UINT32 Eligible,UINT32 Unlocked,UINT32 Retained,UINT32 Clean) {
  if(!Parent)return EFI_NOT_READY;
  static const char Head[]="GUH1 ",Hex[]="0123456789abcdef";
  char text[96];UINTN n=0;
  for(UINTN i=0;Head[i];i++)text[n++]=Head[i];
  for(UINTN i=0;i<16;i++)text[n++]=Hex[(unsigned)((Status>>((15-i)*4))&0xf)];
  const UINT32 fields[4]={Eligible,Unlocked,Retained,Clean};
  for(UINTN f=0;f<4;f++){text[n++]=' ';n+=PutDecimal(text+n,fields[f]);}
  text[n++]='\n';
  EFI_FILE_PROTOCOL *file=NULL;
  EFI_STATUS status=Parent->Open(Parent,&file,L"HANDOFF.ST",EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,0);
  if(EFI_ERROR(status) || !file)return EFI_DEVICE_ERROR;
  UINTN wrote=n;
  status=file->Write(file,&wrote,text);
  if(!EFI_ERROR(status) && wrote!=n)status=EFI_DEVICE_ERROR;
  EFI_STATUS flushed=file->Flush(file);
  if(!EFI_ERROR(status))status=flushed;
  EFI_STATUS closed=file->Close(file);
  if(!EFI_ERROR(status))status=closed;
  return status;
}
#endif
EFI_STATUS GuLoadAssets(VOID) {
  for(UINTN i=0;i<5;i++) {
    EFI_FILE_PROTOCOL *file=NULL;const ASSET_SPEC *spec=&Specs[i];
    EFI_STATUS status=Parent->Open(Parent,&file,spec->file,EFI_FILE_MODE_READ,0);
    if(EFI_ERROR(status) || !file)return EFI_NOT_FOUND;
    status=Metadata(file,FALSE,spec->size);
    UINT8 *data=NULL;
    if(!EFI_ERROR(status)) {
      data=GuAlloc(spec->size);if(!data)status=EFI_OUT_OF_RESOURCES;
    }
    for(UINTN done=0;!EFI_ERROR(status) && done<spec->size;) {
      UINTN n=spec->size-done;if(n>1048576)n=1048576;UINTN want=n;
      status=file->Read(file,&n,data+done);
      if(!EFI_ERROR(status) && n!=want)status=EFI_END_OF_FILE;done+=n;
    }
    EFI_STATUS closed=file->Close(file);if(!EFI_ERROR(status))status=closed;
    if(!EFI_ERROR(status) && !GuHashMatches(data,spec->size,spec->hash))status=EFI_CRC_ERROR;
    if(EFI_ERROR(status)){GuFree(data);return status;}
    GuAssets[i].name=spec->name;GuAssets[i].firmware.data=data;GuAssets[i].firmware.size=spec->size;
    GuLog("asset verified: %s bytes=%zu sha256=%s\n",spec->name,(size_t)spec->size,spec->hash);
    if(!GuLogReady())return EFI_DEVICE_ERROR;
  }
  return EFI_SUCCESS;
}
VOID GuReleaseAssets(VOID) {
  if(!GuSafeToReturn())return;
  for(UINTN i=0;i<5;i++){GuFree((VOID *)GuAssets[i].firmware.data);memset(&GuAssets[i],0,sizeof(GuAssets[i]));}
}
EFI_STATUS GuIoClose(VOID) {
  EFI_FILE_PROTOCOL **files[]={&Report,&Run,&Parent,&Root};EFI_STATUS result=EFI_SUCCESS;
  if(!GuSafeToReturn())return EFI_ACCESS_DENIED;
  for(UINTN i=0;i<4;i++)if(*files[i]) {
    /* EFI_FILE_PROTOCOL.Close invalidates the handle even on error. */
    EFI_FILE_PROTOCOL *file=*files[i];*files[i]=NULL;
    EFI_STATUS status=file->Close(file);
    if(EFI_ERROR(status) && !EFI_ERROR(result))result=status;
  }
  return result;
}
