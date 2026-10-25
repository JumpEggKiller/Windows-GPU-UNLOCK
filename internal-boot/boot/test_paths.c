/* Device-path policy for the dedicated ESP. A path that cannot be attributed to
   exactly one GPT partition must never authorize loading the unlock child, and a
   USB path must never be accepted by the automatic build (app_io.c). */
#include "media.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static UINT8 Buffer[512];
static UINTN At;

static const EFI_GUID Internal=GU_INTERNAL_PARTITION_INITIALIZER;
static const EFI_GUID Windows=GU_WINDOWS_PARTITION_INITIALIZER;

static void Begin(void) {
  memset(Buffer,0,sizeof(Buffer));At=0;
}

static void HardDrive(const UINT8 *Signature,UINT8 Mbr,UINT8 SignatureType,UINT64 Size,UINTN NodeLength) {
  HARDDRIVE_DEVICE_PATH *node=(HARDDRIVE_DEVICE_PATH *)(Buffer+At);
  memset(node,0,sizeof(*node));
  node->Header.Type=MEDIA_DEVICE_PATH;
  node->Header.SubType=MEDIA_HARDDRIVE_DP;
  node->Header.Length[0]=(UINT8)(NodeLength&0xff);
  node->Header.Length[1]=(UINT8)((NodeLength>>8)&0xff);
  node->PartitionNumber=1;
  node->PartitionStart=0;
  node->PartitionSize=Size;
  if(Signature)memcpy(node->Signature,Signature,16);
  node->MBRType=Mbr;
  node->SignatureType=SignatureType;
  At+=NodeLength;
}

static void Gpt(const EFI_GUID *Guid) {
  HardDrive((const UINT8 *)Guid,2,2,0x100000,sizeof(HARDDRIVE_DEVICE_PATH));
}

static void Usb(void) {
  USB_DEVICE_PATH *node=(USB_DEVICE_PATH *)(Buffer+At);
  memset(node,0,sizeof(*node));
  node->Header.Type=MESSAGING_DEVICE_PATH;
  node->Header.SubType=MSG_USB_DP;
  node->Header.Length[0]=(UINT8)sizeof(USB_DEVICE_PATH);
  node->Header.Length[1]=0;
  node->ParentPortNumber=1;
  At+=sizeof(USB_DEVICE_PATH);
}

static void End(UINT8 SubType) {
  Buffer[At]=END_DEVICE_PATH_TYPE;
  Buffer[At+1]=SubType;
  Buffer[At+2]=4;
  Buffer[At+3]=0;
  At+=4;
}

static BOOLEAN Inspect(UINTN *Bytes,BOOLEAN *UsbSeen) {
  return GuInspectPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,NULL,Bytes,UsbSeen,NULL);
}

int main(void) {
  UINTN bytes=0;
  BOOLEAN usb=FALSE,partition=FALSE;

  /* The dedicated ESP: one GPT hard-drive node carrying its partition GUID. */
  Begin();Gpt(&Internal);End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(GuInspectPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal,&bytes,&usb,&partition));
  assert(bytes==At && !usb && partition);
  assert(GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));
  assert(!GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Windows));
  assert(GuAllowedMediaPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,TRUE));
  /* A manual build still refuses internal media unless it was asked for, and the
     automatic build never accepts a USB path at all. */
  assert(!GuAllowedMediaPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,FALSE));

  /* A GUID is only an identity when it is a GPT partition signature. */
  Begin();
  HardDrive((const UINT8 *)&Internal,2,1,0x100000,sizeof(HARDDRIVE_DEVICE_PATH));
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(Inspect(NULL,NULL) && !GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));
  Begin();
  HardDrive((const UINT8 *)&Internal,1,2,0x100000,sizeof(HARDDRIVE_DEVICE_PATH));
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));
  Begin();
  HardDrive((const UINT8 *)&Internal,2,2,0,sizeof(HARDDRIVE_DEVICE_PATH));
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));

  /* Malformed nodes are rejected outright, not skipped over. */
  Begin();
  HardDrive((const UINT8 *)&Internal,2,2,0x100000,sizeof(HARDDRIVE_DEVICE_PATH)-1);
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!Inspect(NULL,NULL));
  Begin();
  HardDrive((const UINT8 *)&Internal,2,2,0x100000,sizeof(HARDDRIVE_DEVICE_PATH)+1);
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!Inspect(NULL,NULL));
  Begin();
  Buffer[At]=MEDIA_DEVICE_PATH;Buffer[At+1]=MEDIA_HARDDRIVE_DP;Buffer[At+2]=0;Buffer[At+3]=0;
  At+=4;End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!Inspect(NULL,NULL));
  /* Two hard-drive nodes cannot be attributed to one partition, even if equal. */
  Begin();Gpt(&Internal);Gpt(&Internal);End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!Inspect(NULL,NULL));
  assert(!GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));

  /* The terminator itself is checked. */
  Begin();Gpt(&Internal);End(END_INSTANCE_DEVICE_PATH_SUBTYPE);
  assert(!Inspect(NULL,NULL));
  Begin();End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(Inspect(&bytes,&usb)); 
  assert(bytes==4 && !usb && !GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));

  /* The USB path the manual build used to rely on. */
  Begin();Usb();End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(GuInspectPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal,NULL,&usb,&partition));
  assert(usb && !partition);
  assert(GuAllowedMediaPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,FALSE));
  assert(GuAllowedMediaPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,TRUE));
  assert(!GuPathIsPartition((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,&Internal));

  /* USB then the ESP is still the ESP; a wrong-endian signature is not. */
  Begin();Usb();Gpt(&Internal);End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(GuAllowedMediaPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,FALSE));
  UINT8 flipped[16];
  memcpy(flipped,(const UINT8 *)&Internal,16);
  flipped[0]^=0xff;
  Begin();
  HardDrive(flipped,2,2,0x100000,sizeof(HARDDRIVE_DEVICE_PATH));
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!GuAllowedMediaPath((const EFI_DEVICE_PATH_PROTOCOL *)Buffer,TRUE));

  /* Nothing to look at. */
  assert(!GuInspectPath(NULL,NULL,NULL,NULL,NULL));

  /* The walk is bounded: 63 nodes plus the terminator still resolves, 64 nodes
     exhausts the budget before the terminator is seen. */
  Begin();
  for(UINTN i=0;i<63;i++)Usb();
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(Inspect(&bytes,&usb) && usb);
  Begin();
  for(UINTN i=0;i<64;i++)Usb();
  End(END_ENTIRE_DEVICE_PATH_SUBTYPE);
  assert(!Inspect(NULL,NULL));

  puts("internal-boot device-path policy: PASS");
  return 0;
}
