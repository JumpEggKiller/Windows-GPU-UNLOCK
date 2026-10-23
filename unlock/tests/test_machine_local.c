/* Machine-local selection test (branch local-rig-preflight; NOT upstream).
   Proves the ported pins accept ONLY GPU3 (0000:C1:00.0, subsystem 14541B4C)
   and reject GPU0 (same subsystem, bus 01), GPU1 (41), GPU2 (81) and the
   author's pinned subsystem. Compile with -DGU_MACHINE_LOCAL. */
#include "../checks.h"
#include <stdio.h>
#include <string.h>

static unsigned Checks, Failures;

static void Check(int Pass, const char *Name) {
  ++Checks;
  if (!Pass) { ++Failures; fprintf(stderr, "FAIL %s\n", Name); }
}

/* Passing config fixture: same shape as test_checks.c Basic() (author-verified
   for GuCheckConfig) with the machine-local subsystem supplied by the define. */
static void Basic(UINT32 C[64]) {
  memset(C, 0, 256);
  C[0] = GU_BOARD_ID;
  C[1] = 0x00100002;            /* command: memory on, BME off */
  C[2] = 0x030000a1;            /* class display, rev A1 (verified on all four cards) */
  C[3] = 0x00800000;            /* header type device, status cap-list bit */
  C[0x2c / 4] = GU_BOARD_SUBSYSTEM;
  C[0x34 / 4] = 0x40;
  C[0x40 / 4] = 0x00034801;     /* PM cap, next 0x48, D0 */
  C[0x48 / 4] = 0x00020010;     /* PCIe cap v2, end of chain, FLR-capable */
  C[0x4c / 4] = 0x10000000;     /* Device Cap bit28 FLR */
}

int main(void) {
  UINT32 C[64];
  GU_CAPS Caps;
#ifdef GU_MACHINE_LOCAL
  printf("machine_local: bus=%#x subsys=%#x\n", (unsigned)GU_TARGET_BUS, (unsigned)GU_BOARD_SUBSYSTEM);
  Check(GU_TARGET_BUS == 0xC1U, "target bus is C1");
  Check(GU_BOARD_SUBSYSTEM == 0x14541B4CU, "target subsystem is ZOTAC 14541B4C");
  Check(GU_BAR0_BASE == 0ULL, "BAR0 base is log-only (0)");
  Check(GU_PROM_SHA256_LOCAL[0] == '\0', "PROM hash is log-only (empty)");
  Check(GU_CONFIG_LOG_ONLY_PINS == 1, "config c8/pcie pins are log-only");
  Check(GU_DISPLAY_LOG_ONLY == 1, "display route is log-only");
  Basic(C); Check(GuCheckConfig(C, 0, 0xC1, 0, 0, &Caps), "GPU3 BDF+subsystem accepted");
  Basic(C); Check(!GuCheckConfig(C, 0, 0x01, 0, 0, &Caps), "GPU0 bus rejected (same subsystem, different bus)");
  Basic(C); Check(!GuCheckConfig(C, 0, 0x41, 0, 0, &Caps), "GPU1 bus rejected");
  Basic(C); Check(!GuCheckConfig(C, 0, 0x81, 0, 0, &Caps), "GPU2 bus rejected");
  Basic(C); C[0x2c / 4] = 0x145410de; Check(!GuCheckConfig(C, 0, 0xC1, 0, 0, &Caps), "author subsystem rejected");
  Basic(C); C[0x2c / 4] = 0x38821462; Check(!GuCheckConfig(C, 0, 0xC1, 0, 0, &Caps), "MSI subsystem rejected");
#else
  printf("machine_local test requires -DGU_MACHINE_LOCAL\n"); return 2;
#endif
  if (Failures) { fprintf(stderr, "%u/%u failed\n", Failures, Checks); return 1; }
  printf("PASS %u machine-local selection checks\n", Checks);
  return 0;
}
