/* Windows GPU UNLOCK internal boot: guarded direct handoff from the dedicated ESP
   to Windows Boot Manager after the measured multi-card unlock.

   Ported from the upstream internal-boot experiment and deliberately restricted to
   the handoff path. Upstream's GOP release machinery assumes an AMD iGPU owns the
   console; this rig has no AMD iGPU (targets_local.h) and its console GOP sits on
   GPU0, which the target table excludes on purpose, so detaching a GOP path here
   would blank the only console. The per-card firmware driver release already runs
   inside the proven transaction in unlock/app.c. GPL-2.0-only. */
#include <Uefi.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/DevicePath.h>
#include <Guid/FileInfo.h>
#include "media.h"
/* One generated header per mode: the manual and the automatic wrapper are paired
   with different children, and a shared header would let a stale build authorize
   the wrong image. */
#if defined(GU_AUTOMATIC_BOOT)
#include "generated-auto.h"
#else
#include "generated-manual.h"
#endif
#include "record.h"
#include "flow.h"
#include "../../unlock/sha256.h"

#if defined(GU_AUTOMATIC_BOOT)
#define GU_CHILD_FILE L"\\EFI\\WindowsGPUUnlock\\UNLOCK-AUTO.EFI"
#define GU_LOG_STEM L"BOOT"
#define GU_MODE_NAME "AUTOMATIC"
#else
#define GU_CHILD_FILE L"\\EFI\\WindowsGPUUnlock\\UNLOCK.EFI"
#define GU_LOG_STEM L"FULL"
#define GU_MODE_NAME "MANUAL"
#endif

#define GU_LOG_ROOT L"\\RTX3090-UNLOCK"
#define GU_RECORD_FILE L"\\RTX3090-UNLOCK\\HANDOFF.ST"
#define GU_BOOTMGR_FILE L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi"

static EFI_GUID LoadedGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID,FsGuid=EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID,
  InfoGuid=EFI_FILE_INFO_ID,PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID;
static EFI_SYSTEM_TABLE *Table;
static EFI_HANDLE Self,OwnDevice,WindowsDevice;
static EFI_LOADED_IMAGE_PROTOCOL *OwnImage;
static EFI_FILE_PROTOCOL *Root,*LogDir,*Log;
static EFI_HANDLE WindowsImage,UnlockImage;
static BOOLEAN Skipped;

static VOID CopyBytes(VOID *To,const VOID *From,UINTN Count) {
  UINT8 *out=To;const UINT8 *in=From;
  for(UINTN i=0;i<Count;i++)out[i]=in[i];
}

/* Console output is a courtesy; it must never decide the handoff. */
static VOID Say(const char *Text) {
  if(!Table || !Table->ConOut || !Table->ConOut->OutputString)return;
  while(Text && *Text) {
    CHAR16 line[128];UINTN n=0;
    while(*Text && n<126) {if(*Text=='\n')line[n++]='\r';line[n++]=(CHAR16)*Text++;}
    line[n]=0;
    if(EFI_ERROR(Table->ConOut->OutputString(Table->ConOut,line)))return;
  }
}

/* The only stop. No reset, no retry, no fall-through to the firmware boot order:
   whatever state the cards are in stays visible on the next power-on. */
static VOID Stop(const char *Why) {
  Say(Why);
  Say("\nHANDOFF STOPPED. No reset and no automatic retry.\n");
  Say("Power off with the power button, then start Windows from the firmware boot menu.\n");
  if(Table && Table->BootServices)Table->BootServices->SetWatchdogTimer(0,0,0,NULL);
  for(;;)__asm__ volatile("pause");
}

static EFI_STATUS RecordEvent(const char *Event,EFI_STATUS Status) {
  if(!Log)return EFI_DEVICE_ERROR;
  static const char Hex[]="0123456789abcdef",Tail[]="status=0x";
  char line[160];UINTN n=0;
  for(UINTN i=0;Event && Event[i] && n<100;i++)line[n++]=Event[i];
  line[n++]=' ';
  for(UINTN i=0;Tail[i];i++)line[n++]=Tail[i];
  for(UINTN i=0;i<16;i++)line[n++]=Hex[(unsigned)(((UINT64)Status>>((15-i)*4))&0xf)];
  line[n++]='\r';line[n++]='\n';
  UINTN wrote=n;
  EFI_STATUS status=Log->Write(Log,&wrote,line);
  if(EFI_ERROR(status) || wrote!=n)return EFI_DEVICE_ERROR;
  return Log->Flush(Log);
}

/* The flow's ops table carries a context the wrapper does not need: the log is a
   file-scope object by design, so no state can be passed in from outside. */
static EFI_STATUS RecordOp(VOID *Context,const char *Event,EFI_STATUS Status) {
  (void)Context;
  return RecordEvent(Event,Status);
}

/* Exactly one match, or the GUID is not usable as an identity. */
static EFI_STATUS FindPartition(const EFI_GUID *Guid,EFI_HANDLE *Out) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  EFI_STATUS status=Table->BootServices->LocateHandleBuffer(ByProtocol,&FsGuid,NULL,&count,&handles);
  if(EFI_ERROR(status) || !handles)return EFI_ERROR(status)?status:EFI_NOT_FOUND;
  EFI_HANDLE found=NULL;UINTN matches=0;
  for(UINTN i=0;i<count;i++) {
    EFI_DEVICE_PATH_PROTOCOL *path=NULL;
    if(EFI_ERROR(Table->BootServices->HandleProtocol(handles[i],&PathGuid,(VOID **)&path)) || !path)continue;
    if(!GuPathIsPartition(path,Guid))continue;
    if(!matches)found=handles[i];
    matches++;
  }
  Table->BootServices->FreePool(handles);
  if(!matches)return EFI_NOT_FOUND;
  /* Two partitions claiming one identity means the identity can no longer pick a
     volume, so nothing may be loaded from it. */
  if(matches>1)return EFI_COMPROMISED_DATA;
  *Out=found;
  return EFI_SUCCESS;
}

/* The device's own path minus its END node, plus a file-path node, plus END:
   bootmgfw is addressed by device path and never through a mounted filesystem. */
static EFI_STATUS FilePath(EFI_HANDLE Device,const CHAR16 *Name,EFI_DEVICE_PATH_PROTOCOL **Out) {
  if(!Device || !Name || !Out)return EFI_INVALID_PARAMETER;
  EFI_DEVICE_PATH_PROTOCOL *base=NULL;UINTN baseBytes=0;
  EFI_STATUS status=Table->BootServices->HandleProtocol(Device,&PathGuid,(VOID **)&base);
  if(EFI_ERROR(status) || !base)return EFI_DEVICE_ERROR;
  if(!GuInspectPath(base,NULL,&baseBytes,NULL,NULL))return EFI_COMPROMISED_DATA;
  UINTN chars=0;while(Name[chars])chars++;
  if(!chars || chars>=256)return EFI_INVALID_PARAMETER;
  UINTN fileBytes=4+(chars+1)*sizeof(CHAR16);
  UINTN bodyBytes=baseBytes-sizeof(EFI_DEVICE_PATH_PROTOCOL);
  UINTN total=bodyBytes+fileBytes+sizeof(EFI_DEVICE_PATH_PROTOCOL);
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  status=Table->BootServices->AllocatePool(EfiLoaderData,total,(VOID **)&path);
  if(EFI_ERROR(status) || !path)return EFI_OUT_OF_RESOURCES;
  UINT8 *cursor=(UINT8 *)path;
  CopyBytes(cursor,base,bodyBytes);cursor+=bodyBytes;
  FILEPATH_DEVICE_PATH *node=(FILEPATH_DEVICE_PATH *)cursor;
  node->Header.Type=MEDIA_DEVICE_PATH;
  node->Header.SubType=MEDIA_FILEPATH_DP;
  node->Header.Length[0]=(UINT8)(fileBytes&0xff);
  node->Header.Length[1]=(UINT8)((fileBytes>>8)&0xff);
  CopyBytes(node->PathName,Name,(chars+1)*sizeof(CHAR16));
  cursor+=fileBytes;
  EFI_DEVICE_PATH_PROTOCOL *end=(EFI_DEVICE_PATH_PROTOCOL *)cursor;
  end->Type=END_DEVICE_PATH_TYPE;
  end->SubType=END_ENTIRE_DEVICE_PATH_SUBTYPE;
  end->Length[0]=4;end->Length[1]=0;
  *Out=path;
  return EFI_SUCCESS;
}

static EFI_STATUS OpenLog(VOID) {
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs=NULL;
  EFI_STATUS status=EFI_UNSUPPORTED;
  if(OwnImage)status=Table->BootServices->HandleProtocol(OwnImage->DeviceHandle,&FsGuid,(VOID **)&fs);
  if(EFI_ERROR(status) || !fs)return EFI_UNSUPPORTED;
  status=fs->OpenVolume(fs,&Root);
  if(EFI_ERROR(status) || !Root)return EFI_DEVICE_ERROR;
  status=Root->Open(Root,&LogDir,GU_LOG_ROOT,EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0);
  if(EFI_ERROR(status) || !LogDir)return EFI_NOT_FOUND;
  const CHAR16 *stem=GU_LOG_STEM;
  for(UINTN slot=0;slot<100;slot++) {
    CHAR16 name[12];
    name[0]=stem[0];name[1]=stem[1];name[2]=stem[2];name[3]=stem[3];
    name[4]=(CHAR16)('0'+slot/10);name[5]=(CHAR16)('0'+slot%10);
    name[6]=L'.';name[7]=L'T';name[8]=L'X';name[9]=L'T';name[10]=0;
    EFI_FILE_PROTOCOL *existing=NULL;
    status=LogDir->Open(LogDir,&existing,name,EFI_FILE_MODE_READ,0);
    if(!EFI_ERROR(status)) {
      if(!existing || EFI_ERROR(existing->Close(existing)))return EFI_DEVICE_ERROR;
      continue;
    }
    if(status!=EFI_NOT_FOUND)return status;
    status=LogDir->Open(LogDir,&Log,name,EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,0);
    if(EFI_ERROR(status) || !Log)return EFI_DEVICE_ERROR;
    return EFI_SUCCESS;
  }
  return EFI_VOLUME_FULL;
}

static VOID CloseLog(VOID) {
  EFI_FILE_PROTOCOL **files[]={&Log,&LogDir,&Root};
  for(UINTN i=0;i<3;i++)if(*files[i]) {
    EFI_FILE_PROTOCOL *file=*files[i];*files[i]=NULL;
    file->Close(file);
  }
}

/* A record from an earlier boot must never authorize this one, so it is removed
   before the child is even loaded. */
static EFI_STATUS ClearHandoff(VOID) {
  if(!Root)return EFI_NOT_READY;
  EFI_FILE_PROTOCOL *file=NULL;
  EFI_STATUS status=Root->Open(Root,&file,GU_RECORD_FILE,EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE,0);
  if(EFI_ERROR(status))return status==EFI_NOT_FOUND?EFI_SUCCESS:status;
  if(!file)return EFI_DEVICE_ERROR;
  /* Delete invalidates the handle even on error; it is not closed again. */
  return file->Delete(file);
}

static EFI_STATUS VerifyHandoff(VOID) {
  if(!Root)return EFI_NOT_READY;
  EFI_FILE_PROTOCOL *file=NULL;
  EFI_STATUS status=Root->Open(Root,&file,GU_RECORD_FILE,EFI_FILE_MODE_READ,0);
  if(EFI_ERROR(status) || !file)return EFI_NOT_FOUND;
  union {EFI_FILE_INFO info;UINT8 bytes[512];} data;UINTN size=sizeof(data);
  status=file->GetInfo(file,&InfoGuid,&size,&data);
  if(!EFI_ERROR(status)) {
    if(size<SIZE_OF_EFI_FILE_INFO || data.info.Size>size ||
       (data.info.Attribute&EFI_FILE_DIRECTORY) ||
       data.info.FileSize<8 || data.info.FileSize>GU_HANDOFF_MAX)status=EFI_COMPROMISED_DATA;
  }
  char text[GU_HANDOFF_MAX+1];UINTN want=0;
  if(!EFI_ERROR(status)) {
    want=(UINTN)data.info.FileSize;
    UINTN got=want;
    status=file->Read(file,&got,text);
    if(!EFI_ERROR(status) && got!=want)status=EFI_END_OF_FILE;
    text[want]=0;
  }
  EFI_STATUS closed=file->Close(file);
  if(!EFI_ERROR(status))status=closed;
  if(EFI_ERROR(status))return status;
  GU_HANDOFF_RECORD record;
  if(!GuHandoffParse(text,want,&record))return EFI_CRC_ERROR;
  if(!GuHandoffAccept(&record,(UINT32)GU_EXPECTED_UNLOCKED))return EFI_SECURITY_VIOLATION;
  return EFI_SUCCESS;
}

static EFI_STATUS LoadUnlock(VOID) {
  if(!Root)return EFI_NOT_READY;
  EFI_FILE_PROTOCOL *file=NULL;
  EFI_STATUS status=Root->Open(Root,&file,GU_CHILD_FILE,EFI_FILE_MODE_READ,0);
  if(EFI_ERROR(status) || !file)return EFI_NOT_FOUND;
  union {EFI_FILE_INFO info;UINT8 bytes[512];} data;UINTN size=sizeof(data);
  status=file->GetInfo(file,&InfoGuid,&size,&data);
  if(!EFI_ERROR(status)) {
    if(size<SIZE_OF_EFI_FILE_INFO || data.info.Size>size ||
       (data.info.Attribute&EFI_FILE_DIRECTORY))status=EFI_COMPROMISED_DATA;
  }
  if(!EFI_ERROR(status) && data.info.FileSize!=GU_UNLOCK_BYTES)status=EFI_BAD_BUFFER_SIZE;
  VOID *image=NULL;
  if(!EFI_ERROR(status)) {
    status=Table->BootServices->AllocatePool(EfiLoaderData,GU_UNLOCK_BYTES,&image);
    if(EFI_ERROR(status) || !image)status=EFI_OUT_OF_RESOURCES;
  }
  if(!EFI_ERROR(status)) {
    UINTN got=GU_UNLOCK_BYTES;
    status=file->Read(file,&got,image);
    if(!EFI_ERROR(status) && got!=GU_UNLOCK_BYTES)status=EFI_END_OF_FILE;
  }
  EFI_STATUS closed=file->Close(file);
  if(!EFI_ERROR(status))status=closed;
  if(!EFI_ERROR(status) && !GuHashMatches(image,GU_UNLOCK_BYTES,GU_UNLOCK_SHA256))status=EFI_CRC_ERROR;
  if(EFI_ERROR(status)) {
    if(image)Table->BootServices->FreePool(image);
    return status;
  }
  /* The verified bytes are the bytes that run: the file is never re-opened between
     the hash check and LoadImage, and the loaded image must belong to this device. */
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  status=FilePath(OwnDevice,GU_CHILD_FILE,&path);
  if(!EFI_ERROR(status)) {
    EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;
    status=Table->BootServices->LoadImage(FALSE,Self,path,image,GU_UNLOCK_BYTES,&UnlockImage);
    if(!EFI_ERROR(status)) {
      status=Table->BootServices->HandleProtocol(UnlockImage,&LoadedGuid,(VOID **)&loaded);
      if(!EFI_ERROR(status) && (!loaded || loaded->DeviceHandle!=OwnDevice))status=EFI_COMPROMISED_DATA;
    }
  }
  if(path)Table->BootServices->FreePool(path);
  /* image stays allocated: the firmware keeps referring to it until UnloadImage. */
  return status;
}

static EFI_STATUS LoadWindows(VOID) {
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  EFI_STATUS status=FilePath(WindowsDevice,GU_BOOTMGR_FILE,&path);
  if(EFI_ERROR(status))return status;
  EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;
  status=Table->BootServices->LoadImage(FALSE,Self,path,NULL,0,&WindowsImage);
  if(!EFI_ERROR(status)) {
    status=Table->BootServices->HandleProtocol(WindowsImage,&LoadedGuid,(VOID **)&loaded);
    if(!EFI_ERROR(status) && (!loaded || loaded->DeviceHandle!=WindowsDevice))status=EFI_COMPROMISED_DATA;
  }
  Table->BootServices->FreePool(path);
  return status;
}

static EFI_STATUS Prepare(VOID *Context) {
  (void)Context;
  EFI_STATUS status=FindPartition(&GuInternalPartition,&OwnDevice);
  if(EFI_ERROR(status))return status;
  if(!OwnImage || OwnDevice!=OwnImage->DeviceHandle)return EFI_COMPROMISED_DATA;
  status=FindPartition(&GuWindowsPartition,&WindowsDevice);
  if(EFI_ERROR(status))return status;
  if(WindowsDevice==OwnDevice)return EFI_COMPROMISED_DATA;
  status=OpenLog();
  if(EFI_ERROR(status))return status;
  status=ClearHandoff();
  if(EFI_ERROR(status))return status;
  RecordEvent("internal-handoff-v1",EFI_SUCCESS);
  status=LoadUnlock();
  if(EFI_ERROR(status))return status;
  return LoadWindows();
}

/* The cancel window. Both modes deliberately keep going when the console input
   protocol is missing or broken: an unattended boot must not depend on a keyboard.
   Losing the window removes the operator's way to cancel, and that is recorded. */
static EFI_STATUS Select(VOID *Context,BOOLEAN *SkipUnlock) {
  (void)Context;
  *SkipUnlock=FALSE;
#if defined(GU_AUTOMATIC_BOOT)
  Say("Windows GPU UNLOCK AUTOMATIC: Esc within 5 seconds starts Windows only.\nNo key is required to continue.\n");
#else
  Say("Windows GPU UNLOCK: press Esc within 5 seconds to start Windows only.\n");
#endif
  if(!Table->ConIn || !Table->ConIn->Reset || !Table->ConIn->ReadKeyStroke || !Table->BootServices->Stall) {
    RecordEvent("cancel-window-unavailable",EFI_UNSUPPORTED);
    return EFI_SUCCESS;
  }
  EFI_STATUS status=Table->ConIn->Reset(Table->ConIn,FALSE);
  if(EFI_ERROR(status)) {
    RecordEvent("cancel-window-reset-failed",status);
    return EFI_SUCCESS;
  }
  for(UINTN wait=0;wait<50;wait++) {
    EFI_INPUT_KEY key={0};
    status=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(!EFI_ERROR(status)) {
      if(key.ScanCode==0x17 || key.UnicodeChar==27) {
        *SkipUnlock=TRUE;Skipped=TRUE;
        return EFI_SUCCESS;
      }
    } else if(status!=EFI_NOT_READY) {
      RecordEvent("cancel-window-input-failed",status);
      return EFI_SUCCESS;
    }
    status=Table->BootServices->Stall(100000);
    if(EFI_ERROR(status)) {
      RecordEvent("cancel-window-stall-failed",status);
      return EFI_SUCCESS;
    }
  }
  return EFI_SUCCESS;
}

static EFI_STATUS Unlock(VOID *Context) {
  (void)Context;
  UINTN exit=0;
  return Table->BootServices->StartImage(UnlockImage,&exit,NULL);
}

static EFI_STATUS Windows(VOID *Context) {
  (void)Context;
  if(Skipped) {
    RecordEvent("windows-chosen-unlock-cancelled",EFI_SUCCESS);
  } else {
    /* Independent of the child's return status: the batch must have left a clean
       end-of-batch record naming every card the target table allows. */
    EFI_STATUS status=VerifyHandoff();
    RecordEvent("handoff-record",status);
    if(EFI_ERROR(status))Stop("UNLOCK DID NOT LEAVE A CLEAN END-OF-BATCH RECORD.\nWindows was not started.");
  }
  /* No file or console work between here and StartImage. */
  CloseLog();
  return Table->BootServices->StartImage(WindowsImage,NULL,NULL);
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image,EFI_SYSTEM_TABLE *St) {
  if(!St || !St->BootServices)return EFI_INVALID_PARAMETER;
  Table=St;
  if(EFI_ERROR(St->BootServices->SetWatchdogTimer(0,0,0,NULL)))return EFI_DEVICE_ERROR;
  EFI_LOADED_IMAGE_PROTOCOL *loaded=NULL;
  if(EFI_ERROR(St->BootServices->HandleProtocol(Image,&LoadedGuid,(VOID **)&loaded)) || !loaded)
    return EFI_INVALID_PARAMETER;
  Self=Image;OwnImage=loaded;
  GU_HANDOFF_OPS ops={NULL,Prepare,Select,RecordOp,Unlock,Windows};
  Say("Windows GPU UNLOCK internal " GU_MODE_NAME " handoff.\n");
#if defined(GU_CONFIG_PLACEHOLDER) && GU_CONFIG_PLACEHOLDER
  Say("CONFIG PLACEHOLDER: this build was not configured against a real ESP.\n");
#endif
  EFI_STATUS status=GuHandoffFlow(&ops);
  RecordEvent("handoff-stopped",status);
  Stop("The handoff did not reach Windows.");
  /* Unreachable: Stop() never returns and the firmware boot order is never used. */
  return EFI_ABORTED;
}
