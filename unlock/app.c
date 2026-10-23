/* Modified 2026-10-19/20 for Windows GPU UNLOCK; changes documented in CHANGES.md. */ #include "app.h"
#include "app_io.h"
#include "compat/compat.h"
#include "checks.h"
#include "sha256.h"
#include "ownership.h"
#include "vendor/unlock_610.h"
#include "vendor/gfw_eval.h"
#include <Protocol/GraphicsOutput.h>
#include <IndustryStandard/Acpi.h>
#include <Guid/GlobalVariable.h>
static EFI_GUID PciGuid=EFI_PCI_IO_PROTOCOL_GUID,GopGuid=EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID,
  PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID,GlobalGuid=EFI_GLOBAL_VARIABLE;
static EFI_SYSTEM_TABLE *Table;
static UINT32 InitialConfig[64];
static const char *Stage;
static GU_RELEASE_OWNER PendingOwner;
static EFI_STATUS Step(EFI_STATUS Status) {
  GuLog("CHECK stage=%s status=%#llx\n",Stage,(unsigned long long)Status);
  return !GuLogReady() && !EFI_ERROR(Status)?EFI_DEVICE_ERROR:Status;
}
static VOID ConfigLog(const UINT32 *Config) {
  for(UINTN i=0;i<64;i+=4)GuLog("config[%02x]=%08x %08x %08x %08x\n",
    (unsigned)(i*4),Config[i],Config[i+1],Config[i+2],Config[i+3]);
}
static VOID GopInfoLog(UINTN Index,const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info) {
  GuLog("GOP[%u] format=%u size=%ux%u stride=%u\n",(unsigned)Index,
    (unsigned)Info->PixelFormat,Info->HorizontalResolution,Info->VerticalResolution,Info->PixelsPerScanLine);
}
static BOOLEAN ConsoleGopCheck(EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop,UINTN Index,
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Output) {
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode=Gop->Mode;
  if(mode->Info && mode->SizeOfInfo>=sizeof(*mode->Info)) {
    *Output=*mode->Info;GopInfoLog(Index,Output);return Output->PixelFormat==PixelBltOnly;
  }
  /* RUN02's console aggregator leaves SizeOfInfo zero. Never read an unsized
     Info pointer: QueryMode supplies its own sized, callee-allocated buffer.
     The caller restricts this fallback to a pathless, zero-framebuffer GOP. */
  if(mode->SizeOfInfo || !Gop->QueryMode)return FALSE;
  UINT32 number=mode->Mode;UINTN bytes=0;EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info=NULL;
  EFI_STATUS status=Gop->QueryMode(Gop,number,&bytes,&info);
  GuLog("GOP[%u] console QueryMode: status=%#llx mode=%u info_bytes=%zu\n",
    (unsigned)Index,(unsigned long long)status,number,(size_t)bytes);
  BOOLEAN valid=!EFI_ERROR(status) && info && bytes>=sizeof(*info);
  if(valid) {
    *Output=*info;GopInfoLog(Index,Output);
    valid=(info->PixelFormat==PixelBltOnly || info->PixelFormat==PixelRedGreenBlueReserved8BitPerColor ||
      info->PixelFormat==PixelBlueGreenRedReserved8BitPerColor) && Gop->Mode==mode && mode->Mode==number &&
      !mode->FrameBufferBase && !mode->FrameBufferSize;
  }
  if(info) {
    status=Gu.bs->FreePool(info);
    if(EFI_ERROR(status)){GuLog("GOP[%u] query FreePool failed: %#llx\n",(unsigned)Index,(unsigned long long)status);valid=FALSE;}
  }
  return valid;
}
static BOOLEAN AmdGopParent(EFI_DEVICE_PATH_PROTOCOL *Path) {
  EFI_DEVICE_PATH_PROTOCOL *remaining=Path;EFI_HANDLE parent=NULL;
  EFI_PCI_IO_PROTOCOL *pci=NULL;UINT32 id=0,subsystem=0;UINTN s,b,d,f;
  if(!Gu.bs->LocateDevicePath)return FALSE;
  EFI_STATUS status=Gu.bs->LocateDevicePath(&PciGuid,&remaining,&parent);
  if(EFI_ERROR(status) || !parent || (UINT8 *)remaining!=(UINT8 *)Path+24)return FALSE;
  status=Gu.bs->HandleProtocol(parent,&PciGuid,(VOID **)&pci);
  if(EFI_ERROR(status) || !pci || !pci->GetLocation || !pci->Pci.Read)return FALSE;
  status=pci->GetLocation(pci,&s,&b,&d,&f);
  if(EFI_ERROR(status) || s || b!=12 || d || f)return FALSE;
  status=pci->Pci.Read(pci,EfiPciIoWidthUint32,0,1,&id);
  if(!EFI_ERROR(status))status=pci->Pci.Read(pci,EfiPciIoWidthUint32,0x2c,1,&subsystem);
  GuLog("AMD GOP PCI parent: status=%#llx id=%#x subsystem=%#x\n",(unsigned long long)status,id,subsystem);
  return !EFI_ERROR(status) && id==GU_AMD_ID && subsystem==GU_AMD_SUBSYSTEM;
}
static BOOLEAN DisplayCheck(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0,intel=0;BOOLEAN valid=TRUE;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION physical={0},forwarded={0};BOOLEAN forwarding=FALSE;
  EFI_STATUS status=Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles);
  GuLog("GOP enumeration: status=%#llx handles=%zu\n",(unsigned long long)status,(size_t)count);
  if(EFI_ERROR(status) || !handles || !count || count>16){if(handles)GuFree(handles);return FALSE;}
  for(UINTN i=0;i<count;i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *gop=NULL;EFI_DEVICE_PATH_PROTOCOL *path=NULL;
    status=Gu.bs->HandleProtocol(handles[i],&GopGuid,(VOID **)&gop);
    if(EFI_ERROR(status) || !gop || !gop->Mode){
      GuLog("GOP[%u] invalid protocol/mode: status=%#llx\n",(unsigned)i,
        (unsigned long long)status);valid=FALSE;break;
    }
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode=gop->Mode;
    status=Gu.bs->HandleProtocol(handles[i],&PathGuid,(VOID **)&path);
    int route=!EFI_ERROR(status) && path?GuDisplayPath(path,256):0;
    GuLog("GOP[%u] path_status=%#llx route=%d framebuffer=%#llx bytes=%zu mode=%u max_mode=%u info_bytes=%zu console=%u\n",
      (unsigned)i,(unsigned long long)status,route,(unsigned long long)mode->FrameBufferBase,
      (size_t)mode->FrameBufferSize,mode->Mode,mode->MaxMode,(size_t)mode->SizeOfInfo,(unsigned)(handles[i]==Table->ConsoleOutHandle));
#if defined(GU_MACHINE_LOCAL) || defined(GU_MULTI_TARGET)
    /* Machine assertion: no physical GOP may sit on the target BDF; the
       console must never live on the card being unlocked (RUN01-03: the
       target has no GOP; the two observed paths are the display GPU and
       the ASPEED BMC). */
    if(!EFI_ERROR(status) && path) {
      EFI_DEVICE_PATH_PROTOCOL *rem=path;EFI_HANDLE par=NULL;
      if(!EFI_ERROR(Gu.bs->LocateDevicePath(&PciGuid,&rem,&par)) && par) {
        EFI_PCI_IO_PROTOCOL *p=NULL;
        if(!EFI_ERROR(Gu.bs->HandleProtocol(par,&PciGuid,(VOID**)&p)) && p && p->GetLocation) {
          UINTN s2,b2,d2,f2;
          if(!EFI_ERROR(p->GetLocation(p,&s2,&b2,&d2,&f2))) {
#ifdef GU_MULTI_TARGET
            GuLog("GOP[%u] PCI parent BDF=%x:%x:%x.%x\n",(unsigned)i,(unsigned)s2,(unsigned)b2,(unsigned)d2,(unsigned)f2);
#endif
            if(s2==GU_TARGET_SEGMENT && b2==GU_TARGET_BUS &&
               d2==GU_TARGET_DEVICE && f2==GU_TARGET_FUNCTION) {
              GuLog("GOP[%u] sits on target BDF - refuse\n",(unsigned)i);valid=FALSE;break;
            }
          }
        }
      }
    }
#endif
    if((status==EFI_UNSUPPORTED || status==EFI_NOT_FOUND) && !path && !mode->FrameBufferBase &&
       !mode->FrameBufferSize) {
      EFI_GRAPHICS_OUTPUT_MODE_INFORMATION info;
      if(ConsoleGopCheck(gop,i,&info)) {
        if(info.PixelFormat==PixelBltOnly)continue;
        /* EDK2 ConSplitter forwards QueryMode to its sole physical GOP. Accept
           that RGB/BGR result only on the system console, then match it against
            the one validated AMD GOP after enumeration (handle order varies). */
        if(handles[i]==Table->ConsoleOutHandle && !forwarding) {
          forwarded=info;forwarding=TRUE;continue;
        }
      }
      valid=FALSE;break;
    }
    if(!mode->Info || mode->SizeOfInfo<sizeof(*mode->Info)){valid=FALSE;break;}
    GopInfoLog(i,mode->Info);
     if(EFI_ERROR(status) || !path || (!GU_DISPLAY_LOG_ONLY && (route!=1 || !AmdGopParent(path))) || !mode->FrameBufferBase ||
       !mode->FrameBufferSize || mode->Info->PixelFormat>PixelBlueGreenRedReserved8BitPerColor ||
       !mode->Info->HorizontalResolution || !mode->Info->VerticalResolution ||
       mode->Info->PixelsPerScanLine<mode->Info->HorizontalResolution ||
       (UINT64)mode->Info->PixelsPerScanLine*mode->Info->VerticalResolution>mode->FrameBufferSize/4) {
      valid=FALSE;break;
    }
    physical=*mode->Info;intel++;
  }
  if(forwarding) {
    BOOLEAN match=intel==1 && forwarded.Version==physical.Version && forwarded.PixelFormat==physical.PixelFormat &&
      forwarded.HorizontalResolution==physical.HorizontalResolution && forwarded.VerticalResolution==physical.VerticalResolution &&
      forwarded.PixelsPerScanLine==physical.PixelsPerScanLine;
    GuLog("GOP console forwarded AMD match=%u\n",match);valid=valid && (match || GU_DISPLAY_LOG_ONLY);
  }
  GuFree(handles);GuLog("GOP result: valid=%u amd_physical=%zu\n",valid,(size_t)intel);
  return valid && intel>=(GU_DISPLAY_LOG_ONLY?2:1) && (intel==1 || GU_DISPLAY_LOG_ONLY) && GuLogReady();
}
static EFI_STATUS ReadConfig(UINT32 *Config) {
  for(UINTN i=0;i<64;i++)if(EFI_ERROR(GuConfigRead(EfiPciIoWidthUint32,(UINT32)i*4,&Config[i]))) {
    GuLog("PCI config read failed: offset=%#x valid_bytes=%u; snapshot incomplete\n",(unsigned)(i*4),(unsigned)(i*4));
    return EFI_DEVICE_ERROR;
  }
  return EFI_SUCCESS;
}
static EFI_STATUS ConfigCheck(BOOLEAN Save) {
  UINT32 config[64];GU_CAPS caps;UINTN segment,bus,device,function;
  EFI_STATUS status=Gu.pci->GetLocation(Gu.pci,&segment,&bus,&device,&function);
  GuLog("target location: status=%#llx\n",(unsigned long long)status);
  if(EFI_ERROR(status))return status;
  status=ReadConfig(config);if(EFI_ERROR(status))return status;
  BOOLEAN checked=GuCheckConfig(config,segment,bus,device,function,&caps);
  BOOLEAN valid=checked && config[2]==0x030000a1 &&
    GU_CONFIG_C8_OK(config[0xc8/4]) &&
    (!GU_BAR0_BASE || config[0x10/4]==GU_BAR0_BASE) &&
    !(config[(caps.pcie+8)/4]&0x00200000U);
  BOOLEAN same=Save || !memcmp(config,InitialConfig,sizeof(config));
  if(Save || !valid || !same)ConfigLog(config);
  GuLog("target BDF=%zu:%zu:%zu.%zu checks=%u pm=%#x pcie=%#x msi=%#x msix=%#x\n",
    (size_t)segment,(size_t)bus,(size_t)device,(size_t)function,checked,
    (unsigned)caps.pm,(unsigned)caps.pcie,(unsigned)caps.msi,(unsigned)caps.msix);
  if(!valid)return EFI_UNSUPPORTED;
  if(!same)return EFI_NOT_READY;
  if(Save)memcpy(InitialConfig,config,sizeof(config));
  Gu.pm_cap=caps.pm;Gu.pcie_cap=caps.pcie;Gu.pcie_version=caps.pcie_version;Gu.msi_cap=caps.msi;Gu.msix_cap=caps.msix;
  return EFI_SUCCESS;
}
#if !defined(GU_MULTI_TARGET) || defined(GU_EXPERIMENTAL_3090)
static EFI_STATUS RestoreDecode(VOID) {
  UINT32 current[64],normalized[64],after[64];UINTN segment,bus,device,function;
  if(GU_PREFLIGHT_ONLY || !Gu.profile_verified || !Gu.pci || !Gu.owned || !Gu.armed || !Gu.display_ok || Gu.started || Gu.allocations ||
    Gu.dma_count || Gu.fault || Gu.retained)return EFI_ACCESS_DENIED;
  EFI_STATUS status=Gu.pci->GetLocation(Gu.pci,&segment,&bus,&device,&function);
  if(EFI_ERROR(status))return status;
  status=ReadConfig(current);if(EFI_ERROR(status))return status;
  GuLogText("config before decode restore (256 valid bytes):\n");ConfigLog(current);
  if(!GuTargetConfig(current,segment,bus,device,function))return EFI_UNSUPPORTED;
  UINT32 missing=InitialConfig[1]&~current[1]&3U;
  memcpy(normalized,current,sizeof(normalized));normalized[1]|=missing;
  /* Restore only cleared, previously enabled IO/MEM bits. Every other bit,
     including BME, status, BAR, ROM and PM/capability state must be unchanged. */
  if(memcmp(normalized,InitialConfig,sizeof(normalized))) {
    GuLogText("decode restore refused: config differs beyond cleared original IO/MEM bits\n");
    return EFI_UNSUPPORTED;
  }
  if(!missing){GuLogText("decode restore not needed\n");return EFI_SUCCESS;}
  if(!Gu.pci->Attributes)return EFI_UNSUPPORTED;
  UINT64 needed=(missing&1?EFI_PCI_IO_ATTRIBUTE_IO:0)|(missing&2?EFI_PCI_IO_ATTRIBUTE_MEMORY:0);
  UINT64 supported=0,attributes=0;
  status=Gu.pci->Attributes(Gu.pci,EfiPciIoAttributeOperationSupported,0,&supported);
  GuLog("decode supported attributes: status=%#llx mask=%#llx\n",(unsigned long long)status,(unsigned long long)supported);
  if(EFI_ERROR(status))return status;
  if((supported&needed)!=needed)return EFI_UNSUPPORTED;
  status=Gu.pci->Attributes(Gu.pci,EfiPciIoAttributeOperationGet,0,&attributes);
  GuLog("decode current attributes: status=%#llx mask=%#llx\n",(unsigned long long)status,(unsigned long long)attributes);
  if(EFI_ERROR(status))return status;
  GuLog("decode restore intent: saved_command=%#x current_command=%#x missing=%#x attributes=%#llx\n",
    InitialConfig[1]&0xffff,current[1]&0xffff,missing,(unsigned long long)needed);
  if(!GuLogReady() || Gu.fault)return EFI_DEVICE_ERROR;
  /* Never use EFI_PCI_DEVICE_ENABLE: it would also enable bus mastering. */
  EFI_STATUS enabled=Gu.pci->Attributes(Gu.pci,EfiPciIoAttributeOperationEnable,needed,NULL);
  GuLog("decode enable status=%#llx\n",(unsigned long long)enabled);
  if(!GuLogReady() || Gu.fault)return EFI_ERROR(enabled)?enabled:EFI_DEVICE_ERROR;
  /* Even an error may follow a partial hardware effect. Capture it if readable,
     but never turn an API error into success merely because readback matches. */
  status=ReadConfig(after);
  BOOLEAN matched=FALSE;
  if(!EFI_ERROR(status)) {
    GuLogText("config after decode restore (256 valid bytes):\n");ConfigLog(after);
    matched=!memcmp(after,InitialConfig,sizeof(after));GuLog("decode readback matched=%u\n",matched);
  }
  if(EFI_ERROR(enabled))return enabled;
  if(EFI_ERROR(status))return status;
  if(!GuLogReady() || Gu.fault)return EFI_DEVICE_ERROR;
  return matched?EFI_SUCCESS:EFI_COMPROMISED_DATA;
}
#endif /* !GU_MULTI_TARGET || GU_EXPERIMENTAL_3090 (RestoreDecode) */
static EFI_STATUS FindTarget(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0,found=0;
  EFI_STATUS status=Gu.bs->LocateHandleBuffer(ByProtocol,&PciGuid,NULL,&count,&handles);
  GuLog("PCI enumeration: status=%#llx handles=%zu\n",(unsigned long long)status,(size_t)count);
  if(EFI_ERROR(status) || !handles || !count || count>256){if(handles)GuFree(handles);return EFI_NOT_FOUND;}
  for(UINTN i=0;i<count;i++) {
    EFI_PCI_IO_PROTOCOL *pci=NULL;UINT32 id=0;
    status=Gu.bs->HandleProtocol(handles[i],&PciGuid,(VOID **)&pci);
    if(!EFI_ERROR(status) && pci)status=pci->Pci.Read(pci,EfiPciIoWidthUint32,0,1,&id);
    if(EFI_ERROR(status) || !pci){GuLog("PCI scan failed: index=%zu status=%#llx\n",(size_t)i,(unsigned long long)status);status=EFI_DEVICE_ERROR;break;}
    if(id==GU_BOARD_ID) {
#ifdef GU_MACHINE_LOCAL
      /* Four GA102 cards present; select the pinned BDF only. */
      UINTN s,b,d,f;
      if(EFI_ERROR(pci->GetLocation(pci,&s,&b,&d,&f)))continue;
      if(s!=GU_TARGET_SEGMENT || b!=GU_TARGET_BUS || d!=GU_TARGET_DEVICE || f!=GU_TARGET_FUNCTION)continue;
#endif
      found++;Gu.handle=handles[i];Gu.pci=pci;
    }
  }
  GuFree(handles);GuLog("PCI target matches=%zu status=%#llx\n",(size_t)found,(unsigned long long)status);
  if(EFI_ERROR(status) || found!=1)return EFI_UNSUPPORTED;
  return ConfigCheck(TRUE);
}
static EFI_STATUS BarCheck(VOID) {
  EFI_ACPI_ADDRESS_SPACE_DESCRIPTOR *r=NULL;
  EFI_STATUS status=Gu.pci->GetBarAttributes(Gu.pci,0,NULL,(VOID **)&r);
  GuLog("bar0 query: status=%#llx\n",(unsigned long long)status);
  if(!EFI_ERROR(status)) {
    if(r && r->Desc==ACPI_ADDRESS_SPACE_DESCRIPTOR && r->Len==sizeof(*r)-3)
      GuLog("bar0 descriptor: type=%u granularity=%llu min=%#llx max=%#llx length=%#llx translation=%#llx\n",
        (unsigned)r->ResType,(unsigned long long)r->AddrSpaceGranularity,(unsigned long long)r->AddrRangeMin,
        (unsigned long long)r->AddrRangeMax,(unsigned long long)r->AddrLen,(unsigned long long)r->AddrTranslationOffset);
    if(!r || r->Desc!=ACPI_ADDRESS_SPACE_DESCRIPTOR || r->Len!=sizeof(*r)-3 || r->ResType!=0 ||
      (GU_BAR0_BASE && r->AddrRangeMin!=GU_BAR0_BASE) || r->AddrLen!=0x1000000 || r->AddrTranslationOffset ||
      /* UEFI describes an inclusive end; pinned EDK2 PciBusDxe instead returns
         PciBar.Alignment. Both representations describe this exact 16 MiB BAR. */
      (GU_BAR0_BASE && r->AddrRangeMax!=0xf5ffffff && r->AddrRangeMax!=0x00ffffff) ||
      r->AddrSpaceGranularity!=32 || ((UINT8 *)(r+1))[0]!=ACPI_END_TAG_DESCRIPTOR)status=EFI_UNSUPPORTED;
    else {
      UINT8 *raw=(UINT8 *)r,sum=0;
      for(UINTN i=0;i<sizeof(*r)+2;i++)sum=(UINT8)(sum+raw[i]);
      if(raw[sizeof(*r)+1] && sum)status=EFI_COMPROMISED_DATA;
      else {Gu.bar_base=r->AddrRangeMin;Gu.bar_size=r->AddrLen;}
    }
  }
  if(r)GuFree(r);return status;
}
static EFI_STATUS ColdCheck(VOID) {
  Gu.profile_verified=FALSE;
  UINT32 chip=GuRead32(0);
  struct gpu_unlock_gfw_sample s={.config_ok=true,.plm=GuRead32(GU_GFW_PLM_OFFSET),
    .boot=GuRead32(GU_GFW_BOOT_OFFSET),.cpuctl=GuRead32(GU_GFW_CPUCTL_OFFSET)};
  UINT32 hi=GuRead32(0x1fa828),plm=GuRead32(GU_FEAT_PLM_OFFSET),ss0=GuRead32(GU_FEAT_SS0_OFFSET),ss1=GuRead32(GU_FEAT_SS1_OFFSET);
  GuLog("cold state: chip=%#x plm=%#x gfw=%#x/%#x/%#x WPR2_HI=%#x SS0=%#x SS1=%#x\n",
    chip,plm,s.plm,s.boot,s.cpuctl,hi,ss0,ss1);
  UINT32 memory=GuRead32(0x1183a4);
#if !defined(GU_EXPERIMENTAL_3090)
  GuLog("DIAGNOSTIC PREFLIGHT ONLY: chip baseline=UNKNOWN SS0 baseline=UNKNOWN memory=%#x expected=%#x; cannot arm; no GPU writes/reset/DMA/driver release\n",memory,GU_DEVICE_MEMORY_SIZE);
  return Gu.fault?EFI_DEVICE_ERROR:EFI_NOT_READY;
#else
#ifdef GU_ENTRY_LATCHED
  UINT32 entry0=0,entry1=0;BOOLEAN latched=GuGetEntrySelectors(&entry0,&entry1);
  GuLog("cold expected: profile=%s chip=%#x memory=%#x entry_latched=%u SS0=%#x SS1=%#x SS0target=0x88888888 SS1policy=%s entry=%#x target=0x8\n",
    GU_STOCK_PROFILE_NAME,0xb72000a1U,GU_DEVICE_MEMORY_SIZE,latched,entry0,entry1,
#ifdef GU_ENTRY_LATCHED_SS1_PRESERVE
    "preserve",
#else
    "target",
#endif
    entry1);
#else
  GuLog("cold expected: profile=%s chip=%#x memory=%#x SS0=%#x SS1=%#x\n",
    GU_STOCK_PROFILE_NAME,0xb72000a1U,GU_DEVICE_MEMORY_SIZE,GU_STOCK_PROFILE_SS0,6U);
#endif
  GuLog("cold observed: profile=%s chip=%#x memory=%#x SS0=%#x SS1=%#x\n",
    GU_STOCK_PROFILE_NAME,chip,memory,ss0,ss1);
  if(Gu.fault)return EFI_DEVICE_ERROR;
  if(chip!=0xb72000a1 || memory!=GU_DEVICE_MEMORY_SIZE ||
     gpu_unlock_gfw_assess(&s) || s.plm!=0x8b8f || s.boot!=0x3ff || s.cpuctl!=0x10 ||
     hi!=0 || plm!=0xffffff8f || !Gu.prom_verified)
    return EFI_NOT_READY;
#ifdef GU_ENTRY_LATCHED
  if(!GuLatchEntrySelectors(ss0,ss1))return EFI_NOT_READY;
  GuLog("entry selectors: latched_once=1 SS0=%#x SS1=%#x SS0target=0x88888888 SS1policy=%s SS1target=0x8\n",ss0,ss1,
#ifdef GU_ENTRY_LATCHED_SS1_PRESERVE
    "preserve",
#else
    "full",
#endif
    ss1);
  /* Logging is external I/O: a failed log never authorizes this profile. */
  if(!GuLogReady() || Gu.fault)return EFI_DEVICE_ERROR;
#else
  if(ss0!=GU_STOCK_PROFILE_SS0 || ss1!=6)return EFI_NOT_READY;
#endif
  Gu.profile_verified=TRUE;
#ifdef GU_ENTRY_LATCHED
  GuLog("EXPERIMENTAL exact-card profile %s verified; SS0target=0x88888888 SS1policy=%s entry=%#x target=0x8; hardware untested.\n",GU_STOCK_PROFILE_NAME,
#ifdef GU_ENTRY_LATCHED_SS1_PRESERVE
    "preserve",
#else
    "full",
#endif
    ss1);
#else
  GuLog("EXPERIMENTAL exact-card profile %s verified; SS1 target 8 effect remains hardware untested.\n",GU_STOCK_PROFILE_NAME);
#endif
  return EFI_SUCCESS;
#endif
}
static EFI_STATUS PromCheck(VOID) {
  Gu.prom_verified=FALSE;
  Gu.profile_verified=FALSE;
  VOID *prom=GuAlloc(1048576);if(!prom)return EFI_OUT_OF_RESOURCES;
  GuCopyFromIo(prom,(VOID *)(UINTN)(Gu.bar_base+0x300000),1048576);
#if defined(GU_MACHINE_LOCAL) || defined(GU_MULTI_TARGET)
  if(!GU_PROM_SHA256_LOCAL[0]) {
    /* Log-only: collect the live PROM hash; do not gate on the author's card. */
    if(Gu.fault){GuFree(prom);return EFI_DEVICE_ERROR;}
    { UINT8 d[32];char hex[65];static const char hx[]="0123456789abcdef";
      GuSha256(prom,1048576,d);
      for(UINTN i=0;i<32;i++){hex[i*2]=hx[d[i]>>4];hex[i*2+1]=hx[d[i]&15U];}hex[64]=0;
      GuLog("PROM sha256 (log-only, unverified): %s\n",hex);
      GuFree(prom);return EFI_SUCCESS; }
  }
  { BOOLEAN good=!Gu.fault && GuHashMatches(prom,1048576,GU_PROM_SHA256_LOCAL);
    GuFree(prom);Gu.prom_verified=good;GuLog("live PROM hash matched=%u\n",(unsigned)good);return good?EFI_SUCCESS:EFI_CRC_ERROR; }
#else
  BOOLEAN good=!Gu.fault && GuHashMatches(prom,1048576,"8ea297373e9e5d3600ff41ad9fae88f2d14c98c017d100669f7333981da673b4");
  GuFree(prom);Gu.prom_verified=good;GuLog("live PROM hash matched=%u\n",(unsigned)good);return good?EFI_SUCCESS:EFI_CRC_ERROR;
#endif
}
#if !defined(GU_MULTI_TARGET)
static EFI_STATUS Arm(VOID) {
#if !defined(GU_EXPERIMENTAL_3090)
  return EFI_UNSUPPORTED;
#else
  if(!Gu.profile_verified || Gu.fault || !Gu.display_ok)return EFI_ACCESS_DENIED;
  if(!Table->ConIn || !Table->ConIn->Reset || !Table->ConIn->ReadKeyStroke)return EFI_UNSUPPORTED;
  EFI_STATUS status=Table->ConIn->Reset(Table->ConIn,FALSE);if(EFI_ERROR(status))return status;
  GuLog("EXPERIMENTAL MANUAL UNLOCK: profile=%s exact RTX3090 24GB / AMD display / verified PROM and assets.\n",GU_STOCK_PROFILE_NAME);
  if(PendingOwner.agent)GuLogText("U will release the RTX firmware driver, restore verified access settings if needed, then recheck and attempt once.\n");
  GuLogText("Press U to attempt once; Esc or 30-second timeout cancels.\n");
  if(!GuLogReady())return EFI_DEVICE_ERROR;
  for(UINTN i=0;i<300;i++) {
    EFI_INPUT_KEY key;status=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(!EFI_ERROR(status)) {
      if(key.ScanCode==0x17 || key.UnicodeChar==27)return EFI_ABORTED;
      if(key.UnicodeChar=='u' || key.UnicodeChar=='U')return Gu.profile_verified && !Gu.fault?EFI_SUCCESS:EFI_ACCESS_DENIED;
    } else if(status!=EFI_NOT_READY)return status;
    GuStall(100000);
  }
  return EFI_TIMEOUT;
#endif
}
#endif /* !GU_MULTI_TARGET (Arm) */
#if !defined(GU_MULTI_TARGET) || defined(GU_EXPERIMENTAL_3090)
static VOID Halt(VOID) {
  Gu.retained=TRUE;
  GuLogText("STOP: cleanup cannot be proven. Resources remain reserved.\nPOWER OFF using the physical power button; do not continue to Windows.\n");
  /* No ResetSystem, ExitBootServices, retry, protocol close or memory release. */
  for(;;)Gu.bs->Stall(1000000);
}
static VOID LogContainment(VOID) {
  /* Called only after any TPL_NOTIFY containment section has ended. */
  GuLog("BME containment: attribute_status=%#llx hardware_status=%#llx command=%#x cached=%#llx pending=%u\n",
    (unsigned long long)Gu.master_attribute_status,(unsigned long long)Gu.master_hardware_status,
    Gu.master_last_command,(unsigned long long)Gu.master_last_attributes,Gu.master_attributes_pending);
}

static VOID ReleaseHalt(EFI_STATUS Status,BOOLEAN Attempted) {
  /* A failed claim may follow interface removal/replacement during logging.
     Resolve, validate and clear BME without a callback window or stale access. */
  EFI_TPL old=Gu.bs->RaiseTPL(TPL_NOTIFY);
  EFI_STATUS refreshed=GuRefreshTargetPci();
  EFI_STATUS contained=EFI_ERROR(refreshed)?refreshed:GuClearMaster();
  Gu.bs->RestoreTPL(old);
  LogContainment();
  GuLog("FINAL status=%#llx stage=%s attempted=%u driver_release=1 clean=0 containment=%#llx pci_available=%u\n",
    (unsigned long long)Status,Stage,Attempted,(unsigned long long)contained,(unsigned)(Gu.pci!=NULL));
  Halt();
}
#endif /* !GU_MULTI_TARGET || GU_EXPERIMENTAL_3090 (Halt/ReleaseHalt) */
#ifndef GU_MULTI_TARGET
EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image,EFI_SYSTEM_TABLE *St) {
  if(!St || !St->BootServices || !St->RuntimeServices)return EFI_INVALID_PARAMETER;
  Table=St;GuInit(St->BootServices,NULL);Gu.image=Image;Gu.display_check=DisplayCheck;
  memset(&PendingOwner,0,sizeof(PendingOwner));
  Stage="usb-log";EFI_STATUS status=GuIoOpen(Image,St);BOOLEAN attempted=FALSE,release_attempted=FALSE;
  if(EFI_ERROR(status))goto finish;
#if defined(GU_EXPERIMENTAL_3090)
  GuLog("BUILD MODE: EXPERIMENTAL MANUAL UNLOCK; compile-time profile=%s. The shared I/O preflight banner above is superseded: exact-card checks and manual U can authorize one stock transaction.\n",GU_STOCK_PROFILE_NAME);
#endif
  UINT8 secure=0xff;UINTN bytes=1;
  Stage="secure-boot";
  status=St->RuntimeServices->GetVariable(L"SecureBoot",&GlobalGuid,NULL,&bytes,&secure);
  if(EFI_ERROR(status) || bytes!=1 || secure){status=EFI_SECURITY_VIOLATION;goto finish;}
  status=Step(status);if(EFI_ERROR(status))goto finish;
  Stage="watchdog";status=Step(Gu.bs->SetWatchdogTimer(0,0,0,NULL));if(EFI_ERROR(status))goto finish;
  Stage="target";status=Step(FindTarget());if(EFI_ERROR(status))goto finish;
  Stage="display";Gu.display_ok=DisplayCheck();status=Step(Gu.display_ok?EFI_SUCCESS:EFI_UNSUPPORTED);if(EFI_ERROR(status))goto finish;
  /* Read-only validation precedes ownership, asset loading and manual input. */
  Stage="bar0";status=Step(BarCheck());if(EFI_ERROR(status))goto finish;
  Stage="prom";status=Step(PromCheck());if(EFI_ERROR(status))goto finish;
  Stage="diagnostic-cold-state";status=Step(ColdCheck());
#if !defined(GU_EXPERIMENTAL_3090)
  goto finish;
#else
  if(EFI_ERROR(status))goto finish;
#endif
  Stage="ownership";status=GuClaimController();
  if(status==EFI_ACCESS_DENIED) {
    status=GuFindReleaseOwner(St,&PendingOwner,TRUE);
    if(!EFI_ERROR(status))GuLogText("Exclusive ownership deferred until manual U and explicit driver release.\n");
  }
  status=Step(status);if(EFI_ERROR(status))goto finish;
  Stage="config-recheck";status=Step(ConfigCheck(FALSE));if(EFI_ERROR(status))goto finish;
  Stage="bar0";status=Step(BarCheck());if(EFI_ERROR(status))goto finish;
  Stage="prom";status=Step(PromCheck());if(EFI_ERROR(status))goto finish;
  Stage="cold-state";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
  Stage="assets";status=Step(GuLoadAssets());if(EFI_ERROR(status))goto finish;
  Stage="arming";status=Step(Arm());if(EFI_ERROR(status))goto finish;
  Stage="armed-config";status=Step(ConfigCheck(FALSE));if(EFI_ERROR(status))goto finish;
  Stage="armed-display";Gu.display_ok=DisplayCheck();status=Step(Gu.display_ok?EFI_SUCCESS:EFI_UNSUPPORTED);if(EFI_ERROR(status))goto finish;
  Stage="armed-cold-state";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
  if(PendingOwner.agent) {
    GU_RELEASE_OWNER current;
    Stage="owner-recheck";
    GuLogText("Manual U confirmed: release RTX firmware driver once, then revalidate.\n");
    if(!GuLogReady()){status=EFI_DEVICE_ERROR;goto finish;}
    /* Durable intent precedes the last owner snapshot. No file IO between a
       successful final comparison and DisconnectController. */
    status=GuFindReleaseOwner(St,&current,FALSE);
    if(!EFI_ERROR(status) && !GuSameReleaseOwner(&PendingOwner,&current))status=EFI_ABORTED;
    if(EFI_ERROR(status)){status=Step(status);goto finish;}
    EFI_PCI_IO_PROTOCOL *prior=Gu.pci;
    Stage="driver-release";release_attempted=TRUE;Gu.armed=TRUE;Gu.pci=NULL;
    EFI_STATUS released=Gu.bs->DisconnectController(Gu.handle,current.agent,NULL);
    EFI_TPL refresh_tpl=Gu.bs->RaiseTPL(TPL_NOTIFY);
    EFI_STATUS refreshed=GuRefreshTargetPci();
    Gu.bs->RestoreTPL(refresh_tpl);
    GuLog("driver release: status=%#llx refresh=%#llx same_pci=%u\n",
      (unsigned long long)released,(unsigned long long)refreshed,(unsigned)(Gu.pci==prior));
    status=Step(EFI_ERROR(released)?released:EFI_ERROR(refreshed)?refreshed:Gu.pci!=prior?EFI_COMPROMISED_DATA:EFI_SUCCESS);
    if(EFI_ERROR(status))goto finish;
    Stage="ownership-after-release";status=Step(GuClaimController());if(EFI_ERROR(status))goto finish;
    Stage="display-after-release";Gu.display_ok=DisplayCheck();status=Step(Gu.display_ok?EFI_SUCCESS:EFI_UNSUPPORTED);if(EFI_ERROR(status))goto finish;
    Stage="decode-after-release";status=Step(RestoreDecode());if(EFI_ERROR(status))goto finish;
    Stage="config-after-release";status=Step(ConfigCheck(FALSE));if(EFI_ERROR(status))goto finish;
    Stage="bar0-after-release";status=Step(BarCheck());if(EFI_ERROR(status))goto finish;
    Stage="prom-after-release";status=Step(PromCheck());if(EFI_ERROR(status))goto finish;
    Stage="cold-after-release";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
  }
  Stage="final-prom";status=Step(PromCheck());if(EFI_ERROR(status))goto finish;
  Stage="final-cold";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
  if(!Gu.profile_verified || Gu.fault){status=EFI_ACCESS_DENIED;goto finish;}
  GuLogText("ARMED: one transaction is starting. Do not reset or remove the USB.\n");
  if(!GuLogReady()){status=EFI_DEVICE_ERROR;goto finish;}
  Stage="transaction";Gu.armed=TRUE;attempted=TRUE;
  UINT64 mask=0xffffffffULL;
  struct pci_dev device={.dev={.dma_mask=&mask,.coherent_dma_mask=0xffffffffULL},.pm_cap=Gu.pm_cap,.refs=1};
  struct gpu_unlock_610_shared shared={0};
  int result=gpu_unlock_610_load_shared(&device,&shared);
  if(!result)result=gpu_unlock_610_unlock(&device,&shared);
  /* Also covers failures before GuStarted, including BME-enable readback. */
  EFI_STATUS contained=GuClearMaster();
  LogContainment();
  GuLog("transaction result=%d containment=%#llx started=%u quiesced=%u fault=%u retained=%u maps=%u FLR=%u\n",
    result,(unsigned long long)contained,Gu.started,Gu.quiesced,Gu.fault,Gu.retained,Gu.dma_count,Gu.flrs);
  if(EFI_ERROR(contained) || !GuSafeToReturn() || Gu.allocations || (Gu.started && result))Halt();
  gpu_unlock_610_release_shared(&shared);Gu.armed=FALSE;
  status=result?EFI_DEVICE_ERROR:EFI_SUCCESS;
 finish:
  if(release_attempted && (EFI_ERROR(status) || Gu.fault))ReleaseHalt(status,attempted);
  if(attempted && !GuSafeToReturn())Halt();
  Gu.armed=FALSE;
  if(GuLogReady())GuLog("FINAL status=%#llx stage=%s attempted=%u driver_release=%u clean=%u\n",(unsigned long long)status,Stage,attempted,release_attempted,GuSafeToReturn());
  else GuConsole("Preflight or logging failed; no new attempt will start.\n");
  if(!GuLogReady()){status=EFI_DEVICE_ERROR;if(release_attempted)ReleaseHalt(status,attempted);if(Gu.started)Halt();}
  if(attempted && !GuSafeToReturn())Halt();
  EFI_STATUS closed=GuIoClose();
  if(EFI_ERROR(closed)){if(release_attempted)ReleaseHalt(closed,attempted);if(Gu.started)Halt();status=closed;}
  if(Gu.owned) {
    closed=Gu.bs->CloseProtocol(Gu.handle,&PciGuid,Image,NULL);
    if(EFI_ERROR(closed)){if(release_attempted)ReleaseHalt(closed,attempted);if(Gu.started)Halt();status=closed;}else Gu.owned=FALSE;
  }
  GuReleaseAssets();
  if(!EFI_ERROR(status))GuConsole("UEFI transaction completed and cleaned up. Returning to firmware; Windows validation is pending.\n");
  else GuConsole("Attempt cancelled or rejected. Returning without another attempt.\n");
  return status;
}
#endif /* !GU_MULTI_TARGET */

#ifdef GU_MULTI_TARGET
/* ---------------------------------------------------------------------------
   GPU-UNLOCK-C1 multi-target orchestration.

   Phase A walks every configured card through the READ-ONLY preflight so each
   one is judged against its own pins. Phase B re-validates that card from a
   clean Gu state and, only if it still clears every gate, runs its single
   transaction. Nothing here weakens a gate: an unpinned, disallowed or
   gate-failing card is simply never armed.
   --------------------------------------------------------------------------- */
typedef struct {
  EFI_STATUS Probe;      /* phase A read-only outcome */
  BOOLEAN    ProbeRead;  /* the card answered the identity stage at all */
  BOOLEAN    Pinned;     /* every hardware pin present in the table */
  BOOLEAN    Eligible;   /* may be armed in phase B */
  BOOLEAN    Attempted;  /* a transaction was started */
  BOOLEAN    Released;   /* the firmware driver was disconnected */
  BOOLEAN    Unlocked;   /* transaction returned 0 with clean containment */
  BOOLEAN    Retained;   /* unlocked selector state re-read after the batch */
  BOOLEAN    Clean;      /* GuSafeToReturn held at the end of the card */
  int        Result;
  UINT32     Ss0, Ss1;
  const char *Note;
} GU_CARD_RECORD;
static GU_CARD_RECORD Cards[GU_TARGET_MAX];

static void CardBanner(UINTN Index, const char *Phase, const char *Note) {
  const GU_TARGET *T = &GuTargets[Index];
  GuLogText("\n");
  GuLog("===== target[%zu] %s %s =====\n", (size_t)Index, T->Name, Phase);
  GuLog("target[%zu] identity=%x:%x:%x.%x subsystem=%#x c8_pin=%#x prom_pin=%s allowed=%u note=%s\n",
    (size_t)Index, (unsigned)T->Segment, (unsigned)T->Bus, (unsigned)T->Device, (unsigned)T->Function,
    T->Subsystem, T->ConfigC8, (T->PromSha256 && T->PromSha256[0]) ? "set" : "absent",
    (unsigned)T->UnlockAllowed, Note ? Note : "-");
}

/* Fresh Gu for one card. Software state only: no hardware access. */
static void CardReset(EFI_HANDLE Image, UINTN Index) {
  GuInit(Table->BootServices, NULL);
  Gu.image = Image;
  Gu.display_check = DisplayCheck;
  memset(InitialConfig, 0, sizeof(InitialConfig));
  memset(&PendingOwner, 0, sizeof(PendingOwner));
  GuTargetSelect(Index);
}

/* Read-only gates, in the same order the single-card build uses. */
/* Phase A is read-only data collection, so every card must yield its PROM digest and cold state even
   when a later gate refuses it. The display gate is checked LAST for exactly that reason: it is the
   gate that excludes the display-owning card, and if it ran first that card would be reported without
   the very measurements the pin file needs. Eligibility still requires every stage to succeed, so the
   reordering cannot make an unsafe card eligible - it only stops the report from hiding its data. */
static EFI_STATUS CardProbe(UINTN Index) {
  EFI_STATUS s, first = EFI_SUCCESS;
  Stage = "target";     s = Step(FindTarget());   if (EFI_ERROR(s)) return s; /* no handle, no reads */
  Stage = "bar0";       s = Step(BarCheck());     if (EFI_ERROR(s) && !EFI_ERROR(first)) first = s;
  Stage = "prom";       s = Step(PromCheck());    if (EFI_ERROR(s) && !EFI_ERROR(first)) first = s;
  Stage = "cold-state"; s = Step(ColdCheck());    if (EFI_ERROR(s) && !EFI_ERROR(first)) first = s;
  Stage = "display";    Gu.display_ok = DisplayCheck();
  s = Step(Gu.display_ok ? EFI_SUCCESS : EFI_UNSUPPORTED);
  if (EFI_ERROR(s) && !EFI_ERROR(first)) first = s;
  return first;
}

/* One manual confirmation for the whole batch, after every card was probed. */
#if defined(GU_EXPERIMENTAL_3090)
static EFI_STATUS BatchArm(VOID) {
  UINTN eligible = 0;
  for (UINTN i = 0; i < GuTargetCount; i++) if (Cards[i].Eligible) eligible++;
  if (!eligible) return EFI_UNSUPPORTED;
  if (!GuLogReady() || Gu.fault) return EFI_DEVICE_ERROR;
  GuLogText("\nBATCH PLAN\n");
  for (UINTN i = 0; i < GuTargetCount; i++)
    GuLog("batch[%zu] %s %s\n", (size_t)i, GuTargets[i].Name,
      Cards[i].Eligible ? "WILL UNLOCK" : "excluded (gate or pin)");
  GuLog("batch eligible=%zu of %zu; every transaction is confined to its own card.\n",
    (size_t)eligible, (size_t)GuTargetCount);
  GuConsole("Multi-target unlock ready. U to authorize every listed card, Esc to abort.\n");
  if (!GuLogReady()) return EFI_DEVICE_ERROR;
  Stage = "batch-arming";
  EFI_STATUS status = Table->ConIn->Reset(Table->ConIn, FALSE);
  if (EFI_ERROR(status)) return status;
  for (UINTN wait = 0; wait < 3000; wait++) {
    EFI_INPUT_KEY key = {0};
    status = Table->ConIn->ReadKeyStroke(Table->ConIn, &key);
    if (!EFI_ERROR(status)) {
      if (key.UnicodeChar == L'u' || key.UnicodeChar == L'U') return EFI_SUCCESS;
      if (key.ScanCode == 0x17 || key.UnicodeChar == 27) return EFI_ABORTED;
    }
    GuStall(100000); /* 3 s + 5 min window */
  }
  return EFI_TIMEOUT;
}

/* Full phase B for one card. Returns the card status; *Stop ends the batch. */
static EFI_STATUS CardUnlock(EFI_HANDLE Image, UINTN Index, BOOLEAN *Stop) {
  *Stop = FALSE;
  CardReset(Image, Index);
  CardBanner(Index, "PHASE B UNLOCK", NULL);
  EFI_STATUS status;

  Stage = "target";   status = Step(FindTarget());             if (EFI_ERROR(status)) return status;
  Stage = "display";  Gu.display_ok = DisplayCheck();
  status = Step(Gu.display_ok ? EFI_SUCCESS : EFI_UNSUPPORTED); if (EFI_ERROR(status)) return status;
  Stage = "bar0";     status = Step(BarCheck());               if (EFI_ERROR(status)) return status;
  Stage = "prom";     status = Step(PromCheck());              if (EFI_ERROR(status)) return status;
  Stage = "cold-state"; status = Step(ColdCheck());            if (EFI_ERROR(status)) return status;

  Stage = "ownership"; status = GuClaimController();
  if (status == EFI_ACCESS_DENIED) {
    status = GuFindReleaseOwner(Table, &PendingOwner, TRUE);
    if (!EFI_ERROR(status)) GuLogText("Exclusive ownership deferred until the batch release of this card.\n");
  }
  status = Step(status); if (EFI_ERROR(status)) return status;

  Stage = "config-recheck"; status = Step(ConfigCheck(FALSE)); if (EFI_ERROR(status)) return status;
  Stage = "bar0";           status = Step(BarCheck());         if (EFI_ERROR(status)) return status;
  Stage = "prom";           status = Step(PromCheck());        if (EFI_ERROR(status)) return status;
  Stage = "cold-state";     status = Step(ColdCheck());        if (EFI_ERROR(status)) return status;

  if (PendingOwner.agent) {
    GU_RELEASE_OWNER current;
    Stage = "owner-recheck";
    GuLogText("Batch confirmed: release this card's firmware driver once, then revalidate.\n");
    if (!GuLogReady()) return EFI_DEVICE_ERROR;
    status = GuFindReleaseOwner(Table, &current, FALSE);
    if (!EFI_ERROR(status) && !GuSameReleaseOwner(&PendingOwner, &current)) status = EFI_ABORTED;
    if (EFI_ERROR(status)) return Step(status);
    EFI_PCI_IO_PROTOCOL *prior = Gu.pci;
    Stage = "driver-release"; Cards[Index].Released = TRUE; Gu.armed = TRUE; Gu.pci = NULL;
    EFI_STATUS released = Gu.bs->DisconnectController(Gu.handle, current.agent, NULL);
    EFI_TPL tpl = Gu.bs->RaiseTPL(TPL_NOTIFY);
    EFI_STATUS refreshed = GuRefreshTargetPci();
    Gu.bs->RestoreTPL(tpl);
    GuLog("driver release: status=%#llx refresh=%#llx same_pci=%u\n",
      (unsigned long long)released, (unsigned long long)refreshed, (unsigned)(Gu.pci == prior));
    status = Step(EFI_ERROR(released) ? released
          : EFI_ERROR(refreshed) ? refreshed
          : Gu.pci != prior ? EFI_COMPROMISED_DATA : EFI_SUCCESS);
    /* Once the driver is gone this card cannot be handed back half-released. */
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "ownership-after-release"; status = Step(GuClaimController());
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "display-after-release"; Gu.display_ok = DisplayCheck();
    status = Step(Gu.display_ok ? EFI_SUCCESS : EFI_UNSUPPORTED);
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "decode-after-release"; status = Step(RestoreDecode());
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "config-after-release"; status = Step(ConfigCheck(FALSE));
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "bar0-after-release"; status = Step(BarCheck());
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "prom-after-release"; status = Step(PromCheck());
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
    Stage = "cold-after-release"; status = Step(ColdCheck());
    if (EFI_ERROR(status)) { *Stop = TRUE; ReleaseHalt(status, Cards[Index].Attempted); return status; }
  }

  Stage = "final-prom"; status = Step(PromCheck()); if (EFI_ERROR(status)) return status;
  Stage = "final-cold"; status = Step(ColdCheck()); if (EFI_ERROR(status)) return status;
  if (!Gu.profile_verified || Gu.fault) return EFI_ACCESS_DENIED;

  GuLogText("ARMED: this card's transaction is starting. Do not reset or remove the USB.\n");
  if (!GuLogReady()) return EFI_DEVICE_ERROR;
  Stage = "transaction"; Gu.armed = TRUE; Cards[Index].Attempted = TRUE;
  UINT64 mask = 0xffffffffULL;
  struct pci_dev device = {.dev = {.dma_mask = &mask, .coherent_dma_mask = 0xffffffffULL},
                           .pm_cap = Gu.pm_cap, .refs = 1};
  struct gpu_unlock_610_shared shared = {0};
  int result = gpu_unlock_610_load_shared(&device, &shared);
  if (!result) result = gpu_unlock_610_unlock(&device, &shared);
  EFI_STATUS contained = GuClearMaster();
  LogContainment();
  GuLog("transaction result=%d containment=%#llx started=%u quiesced=%u fault=%u retained=%u maps=%u FLR=%u\n",
    result, (unsigned long long)contained, Gu.started, Gu.quiesced, Gu.fault, Gu.retained, Gu.dma_count, Gu.flrs);
  if (EFI_ERROR(contained) || !GuSafeToReturn() || Gu.allocations || (Gu.started && result))
    Halt();
  gpu_unlock_610_release_shared(&shared);
  Gu.armed = FALSE;
  Cards[Index].Result = result;
  Cards[Index].Unlocked = (result == 0);
  Cards[Index].Clean = GuSafeToReturn();
  if (Gu.owned) {
    EFI_STATUS closed = Gu.bs->CloseProtocol(Gu.handle, &PciGuid, Image, NULL);
    if (EFI_ERROR(closed)) { if (Cards[Index].Released) ReleaseHalt(closed, TRUE); }
    else Gu.owned = FALSE;
  }
  return result ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}

/* Post-batch proof that every unlocked card still reports the unlocked
   selector state, in the same boot, with every other card untouched. */
static void CardRetention(EFI_HANDLE Image, UINTN Index) {
  CardReset(Image, Index);
  EFI_STATUS s = FindTarget();
  if (EFI_ERROR(s)) { GuLog("retained[%zu] identity re-read failed status=%#llx\n",
      (size_t)Index, (unsigned long long)s); return; }
  s = BarCheck();
  if (EFI_ERROR(s)) { GuLog("retained[%zu] bar0 re-read failed status=%#llx\n",
      (size_t)Index, (unsigned long long)s); return; }
  UINT32 ss0 = GuRead32(GU_FEAT_SS0_OFFSET), ss1 = GuRead32(GU_FEAT_SS1_OFFSET);
  Cards[Index].Ss0 = ss0; Cards[Index].Ss1 = ss1;
  Cards[Index].Retained = !Gu.fault && ss0 == 0x88888888U && ss1 == 0x8U;
  GuLog("retained[%zu] %s ss0=%#x ss1=%#x fault=%u\n",
    (size_t)Index, Cards[Index].Retained ? "YES" : "NO", ss0, ss1, (unsigned)Gu.fault);
}
#endif /* GU_EXPERIMENTAL_3090 (BatchArm/CardUnlock/CardRetention) */

EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image, EFI_SYSTEM_TABLE *St) {
  if (!St || !St->BootServices || !St->RuntimeServices) return EFI_INVALID_PARAMETER;
  Table = St;
  GuInit(St->BootServices, NULL);
  Gu.image = Image; Gu.display_check = DisplayCheck;
  memset(&PendingOwner, 0, sizeof(PendingOwner));
  memset(InitialConfig, 0, sizeof(InitialConfig));
  memset(Cards, 0, sizeof(Cards));

  Stage = "usb-log"; EFI_STATUS status = GuIoOpen(Image, St);
  if (EFI_ERROR(status)) return status;

  Stage = "target-table";
  if (!GuTargetTableValid()) {
    GuLogText("TARGET TABLE INVALID: duplicate or malformed identity; refusing to run.\n");
    GuIoClose(); return EFI_COMPROMISED_DATA;
  }
  GuLog("multi-target build: targets=%zu max=%u\n", (size_t)GuTargetCount, (unsigned)GU_TARGET_MAX);

  UINT8 secure = 0xff; UINTN bytes = 1;
  Stage = "secure-boot";
  status = St->RuntimeServices->GetVariable(L"SecureBoot", &GlobalGuid, NULL, &bytes, &secure);
  if (EFI_ERROR(status) || bytes != 1 || secure) status = EFI_SECURITY_VIOLATION;
  else status = Step(status);
  if (EFI_ERROR(status)) goto finish;
  Stage = "watchdog"; status = Step(Gu.bs->SetWatchdogTimer(0, 0, 0, NULL));
  if (EFI_ERROR(status)) goto finish;

  /* ---- Phase A: read-only preflight, one card at a time ---- */
  for (UINTN i = 0; i < GuTargetCount; i++) {
    const GU_TARGET *T = &GuTargets[i];
    CardReset(Image, i);
    CardBanner(i, "PHASE A PREFLIGHT", NULL);
    Cards[i].Pinned = GuTargetPinned(T);
    Cards[i].Probe = CardProbe(i);
    Cards[i].ProbeRead = !Gu.fault && GuLogReady();
    /* Only a card that cleared every read-only gate on its own pins may be
       armed. GU_PREFLIGHT_ONLY builds stop inside ColdCheck by construction, so
       their "not ready" is reported as read-only, never as eligible. */
    Cards[i].Note = !Cards[i].ProbeRead ? "unreadable" :
                    !Cards[i].Pinned ? "unpinned" :
                    GU_PREFLIGHT_ONLY ? "read-only" :
                    EFI_ERROR(Cards[i].Probe) ? "gate-failed" :
                    !T->UnlockAllowed ? "disallowed" : "clean";
    Cards[i].Eligible = Cards[i].Pinned && T->UnlockAllowed && Cards[i].ProbeRead &&
                        !EFI_ERROR(Cards[i].Probe) && !GU_PREFLIGHT_ONLY;
    GuLog("phaseA[%zu] %s probe=%#llx pinned=%u allowed=%u eligible=%u note=%s\n",
      (size_t)i, T->Name, (unsigned long long)Cards[i].Probe, (unsigned)Cards[i].Pinned,
      (unsigned)T->UnlockAllowed, (unsigned)Cards[i].Eligible, Cards[i].Note);
    /* A logging failure invalidates every later card, stop collecting. */
    if (!GuLogReady()) break;
  }

#if !defined(GU_EXPERIMENTAL_3090)
  GuLogText("DIAGNOSTIC PREFLIGHT ONLY: every card above was read, none can arm.\n");
  status = EFI_SUCCESS;
  goto report;
#else
  {
    UINTN eligible = 0;
    for (UINTN i = 0; i < GuTargetCount; i++) if (Cards[i].Eligible) eligible++;
    if (!eligible) {
      GuLogText("NO TARGET CLEARED ITS OWN GATES: no transaction will start.\n");
      status = EFI_NOT_READY;
      goto report;
    }

    Stage = "assets"; status = Step(GuLoadAssets());
    if (EFI_ERROR(status)) goto report;
    Stage = "batch-arming"; status = Step(BatchArm());
    if (EFI_ERROR(status)) {
      /* The batch was never authorized: no card is armed. Attribute it to every
         eligible card, not to index 0, so the table never blames the wrong card. */
      for (UINTN i = 0; i < GuTargetCount; i++)
        if (Cards[i].Eligible) Cards[i].Note = "batch not authorized";
      goto report;
    }

    /* ---- Phase B: per-card revalidation, then that card's transaction ---- */
    for (UINTN i = 0; i < GuTargetCount; i++) {
      if (!Cards[i].Eligible) { GuLog("phaseB[%zu] %s skipped note=%s\n", (size_t)i, GuTargets[i].Name, Cards[i].Note); continue; }
      BOOLEAN stop = FALSE;
      EFI_STATUS s = CardUnlock(Image, i, &stop);
      Cards[i].Clean = GuSafeToReturn();
      GuLog("phaseB[%zu] %s unlock=%#llx result=%d clean=%u\n", (size_t)i, GuTargets[i].Name,
        (unsigned long long)s, Cards[i].Result, (unsigned)Cards[i].Clean);
      if (stop) {
        GuLogText("BATCH STOPPED: this card could not be returned cleanly; earlier cards stay as logged.\n");
        status = s;
        goto report;
      }
      /* Distinguish "the transaction ran and failed" from "this card never got
         as far as the transaction": only Attempted proves a transaction began. */
      if (EFI_ERROR(s)) Cards[i].Note = Cards[i].Attempted ? "transaction-failed" : "revalidation-failed";
    }

    /* ---- Retention: every unlocked card must still read as unlocked ---- */
    for (UINTN i = 0; i < GuTargetCount; i++) {
      if (!Cards[i].Unlocked) continue;
      CardRetention(Image, i);
    }
    status = EFI_SUCCESS;
    for (UINTN i = 0; i < GuTargetCount; i++) {
      if (!Cards[i].Eligible) continue;
      if (!Cards[i].Unlocked || !Cards[i].Retained || !Cards[i].Clean) status = EFI_DEVICE_ERROR;
    }
  }
#endif

 report:
#ifndef GU_BATCH_SILENT
  GuLogText("\nFOUR-CARD STATUS TABLE\n");
  for (UINTN i = 0; i < GuTargetCount; i++) {
    const GU_TARGET *T = &GuTargets[i];
    GuLog("status[%zu] name=%-4s bdf=%x:%x:%x.%x pinned=%u eligible=%u released=%u unlocked=%u retained=%u clean=%u result=%d note=%s\n",
      (size_t)i, T->Name, (unsigned)T->Segment, (unsigned)T->Bus, (unsigned)T->Device, (unsigned)T->Function,
      (unsigned)Cards[i].Pinned, (unsigned)Cards[i].Eligible, (unsigned)Cards[i].Released,
      (unsigned)Cards[i].Unlocked, (unsigned)Cards[i].Retained, (unsigned)Cards[i].Clean,
      Cards[i].Result, Cards[i].Note ? Cards[i].Note : "-");
  }
  GuLog("batch summary: unlocked=%u retained=%u of %zu\n",
    (unsigned)(Cards[0].Unlocked + Cards[1].Unlocked + Cards[2].Unlocked + Cards[3].Unlocked),
    (unsigned)(Cards[0].Retained + Cards[1].Retained + Cards[2].Retained + Cards[3].Retained),
    (size_t)GuTargetCount);
#endif

 finish:
  Gu.armed = FALSE;
  if (GuLogReady())
    GuLog("FINAL(multi) status=%#llx stage=%s targets=%zu\n",
      (unsigned long long)status, Stage, (size_t)GuTargetCount);
  if (Gu.owned) { Gu.bs->CloseProtocol(Gu.handle, &PciGuid, Image, NULL); Gu.owned = FALSE; }
  GuReleaseAssets();
  GuIoClose();
  if (!EFI_ERROR(status))
    GuConsole("Multi-target run finished. Read the RUN report on the USB before returning to Windows.\n");
  else
    GuConsole("Multi-target run ended without a full unlock set. Read the RUN report.\n");
  return status;
}
#endif /* GU_MULTI_TARGET */
