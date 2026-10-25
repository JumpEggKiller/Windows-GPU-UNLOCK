/* Windows GPU UNLOCK internal boot: device-path policy shared by the handoff
   wrapper and by the unlock child when it is built for the internal ESP.
   Ported from the upstream internal-boot experiment. GPL-2.0-only. */
#pragma once
#include <Uefi.h>
#include <Protocol/DevicePath.h>

#if defined(GU_HOST_TEST)
/* Host tests must compile without a configured rig. A real build is not allowed
   to take this path: platform-config.h is written by Configure.ps1 from the actual
   dedicated ESP, and the build manifest records its hash. */
#define GU_INTERNAL_PARTITION_INITIALIZER {0x47553001,0x494e,0x5445,{0x8a,0x11,0x00,0x00,0x00,0x00,0x00,0x01}}
#define GU_WINDOWS_PARTITION_INITIALIZER {0x47553002,0x494e,0x5445,{0x8a,0x11,0x00,0x00,0x00,0x00,0x00,0x02}}
#else
#include "platform-config.h" /* Generated locally by Configure.ps1. */
#endif

static const EFI_GUID GuInternalPartition = GU_INTERNAL_PARTITION_INITIALIZER;
static const EFI_GUID GuWindowsPartition = GU_WINDOWS_PARTITION_INITIALIZER;

static inline BOOLEAN GuGuidEqual(const VOID *Left,const VOID *Right) {
  const UINT8 *a=Left,*b=Right;
  for(UINTN i=0;i<16;i++)if(a[i]!=b[i])return FALSE;
  return TRUE;
}

/* Firmware-provided paths only. Reject multi-instance, malformed and repeated HD
   nodes, so a path can never be attributed to the wrong partition. */
static inline BOOLEAN GuInspectPath(const EFI_DEVICE_PATH_PROTOCOL *Path,const EFI_GUID *Guid,
                                    UINTN *Bytes,BOOLEAN *Usb,BOOLEAN *Partition) {
  UINTN total=0,hd=0;BOOLEAN usb=FALSE,match=FALSE;
  if(!Path)return FALSE;
  for(UINTN nodes=0;nodes<64 && total+4<=4096;nodes++) {
    UINTN n=Path->Length[0]+((UINTN)Path->Length[1]<<8);
    if(n<4 || n>4096-total)return FALSE;
    if(Path->Type==END_DEVICE_PATH_TYPE) {
      if(n!=4 || Path->SubType!=END_ENTIRE_DEVICE_PATH_SUBTYPE)return FALSE;
      if(Bytes)*Bytes=total+4;if(Usb)*Usb=usb;if(Partition)*Partition=match;
      return TRUE;
    }
    if(Path->Type==MESSAGING_DEVICE_PATH && Path->SubType==MSG_USB_DP && n==sizeof(USB_DEVICE_PATH))usb=TRUE;
    if(Path->Type==MEDIA_DEVICE_PATH && Path->SubType==MEDIA_HARDDRIVE_DP) {
      if(n!=sizeof(HARDDRIVE_DEVICE_PATH) || ++hd!=1)return FALSE;
      const HARDDRIVE_DEVICE_PATH *drive=(const VOID *)Path;
      /* MBRType 2 = GPT, SignatureType 2 = the signature is a partition GUID. */
      if(Guid && drive->MBRType==2 && drive->SignatureType==2 && drive->PartitionSize &&
         GuGuidEqual(drive->Signature,Guid))match=TRUE;
    }
    total+=n;Path=(const VOID *)((const UINT8 *)Path+n);
  }
  return FALSE;
}

static inline BOOLEAN GuPathIsPartition(const EFI_DEVICE_PATH_PROTOCOL *Path,const EFI_GUID *Guid) {
  BOOLEAN match=FALSE;
  return GuInspectPath(Path,Guid,NULL,NULL,&match) && match;
}

/* The dedicated ESP is the only internal media this experiment ever accepts. */
static inline BOOLEAN GuAllowedMediaPath(const EFI_DEVICE_PATH_PROTOCOL *Path,BOOLEAN InternalAllowed) {
  BOOLEAN usb=FALSE,partition=FALSE;
  return GuInspectPath(Path,&GuInternalPartition,NULL,&usb,&partition) && (usb || (InternalAllowed && partition));
}
