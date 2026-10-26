# Windows GPU UNLOCK — original Korean research log / 原始韩文研究记录

This is the upstream single-machine research log this fork was built on, kept verbatim for
reference (measurements, the manual USB procedure, the ASUS boot-override notes).
The one-command path for a new machine is **[ADOPT.md](ADOPT.md)** — English and 中文.

下面是本 fork 所依据的**原始单机研究记录**，原样保留（测量数据、U 盘手动流程、ASUS Boot Override 记录）。
新机器的“一条命令”流程在 **[ADOPT.md](ADOPT.md)**（英文 + 中文）。

---

RTX 3090의 Windows Tensor 연산 성능 향상을 확인한 UEFI 실험 코드와 재현 가이드입니다. [rough2515-hub/rtx3080-unlock-public](https://github.com/rough2515-hub/rtx3080-unlock-public/tree/a08254d269af30ace9e57237abd3d8e6c261e8f5)의 RTX 3080 포트를 바탕으로 RTX 3090 24GiB / AMD 내장그래픽 환경에 맞췄습니다. 원천 코어는 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956)입니다.

**핵심: 언락 성공 후 재부팅하지 않고 Windows Boot Manager로 이어서 부팅합니다.** ASUS에서 `Save Changes & Reset`을 누르면 다시 초기화될 수 있습니다. 이번 성공 사례는 `Boot Override → Windows Boot Manager`를 사용했습니다.

## 실제 측정 결과

2026-10-20, 동일한 CUDA 12.6 / cuBLAS 12.6 실행 파일로 각각 3회 실행한 중앙값입니다. NVIDIA Windows 드라이버 **617.14를 교체하지 않았습니다**.

| 항목 | 이전 경로 TFLOPS | 리셋 없이 Windows 진입 TFLOPS | 변화 |
|---|---:|---:|---:|
| FP32 pedantic | 24.505702 | 24.890281 | +1.57% |
| FP16 Tensor / FP32 누산 | 70.548081 | 125.907816 | +78.47% |
| BF16 Tensor / FP32 누산 | 70.529545 | 128.699728 | +82.48% |

이전 측정도 UEFI에서 언락 성공을 보고한 뒤의 값입니다. 미적용 콜드부팅 기준을 별도로 통제한 실험은 아닙니다. 사용자가 이전에는 BIOS에서 Reset했고 이번에는 Boot Override로 리셋 없이 진입했다고 확인했습니다. 결과는 부팅 인계 문제가 원인이었다는 가설을 강하게 뒷받침하지만, 다른 모든 원인을 배제하는 실험은 아닙니다. ComfyUI·게임 향상률과 장시간 안정성은 별도 검증이 필요합니다. [측정 원자료와 한계](docs/RESULTS.ko.md).

## 먼저 지원 조건 확인

**현재 실행 코드는 특정 PC에 고정된 실험 포트입니다. 모든 RTX 3090이나 RTX 30 시리즈에서 그대로 실행되는 범용 프로그램이 아닙니다.** 다른 시스템에서는 검사가 거부되는 것이 정상일 수 있습니다. 검사를 삭제하거나 숫자만 자신의 GPU 값으로 바꿔 실행하지 마세요.

검증 환경:

- NVIDIA RTX 3090 24GiB: PCI `10de:2204`, subsystem `10de:1454`, BDF `0000:01:00.0`.
- ASUS TUF GAMING B650M-PLUS WIFI, AMD Ryzen 7 7800X3D.
- AMD 내장그래픽 PCI `1002:164e`, subsystem `1043:8877`. 모니터는 메인보드 출력에 연결.
- Windows 11 Home build 26200, NVIDIA 617.14.
- x64 UEFI, Secure Boot 꺼짐, FAT32 USB.
- 프로필 `entryLatchedSs1Full`: SS0 `0x88888888`, SS1 `0x8`.
- PROM 해시·BAR·GOP 경로 등 추가 고정 조건: [지원 범위](docs/COMPATIBILITY.ko.md).

## 따라 하기

1. [USB 준비 가이드](docs/GUIDE.ko.md)에서 환경과 파일 구성을 확인합니다. 기존 USB 파일을 먼저 백업합니다.
2. 공개된 EFI 또는 [직접 빌드한 EFI](docs/BUILD.ko.md)를 FAT32 USB의 `EFI/BOOT/BOOTX64.EFI`에 둡니다.
3. 별도 준비한 펌웨어 5개를 `RTX3090-UNLOCK/ASSETS/`에 둡니다. [펌웨어 준비](docs/ASSETS.ko.md). 펌웨어는 이 저장소와 릴리스에 포함하지 않습니다.
4. Windows 작업을 저장하고 완전히 종료한 뒤, 모니터를 메인보드에 연결한 상태로 전원을 켭니다.
5. ASUS F8 → UEFI USB → 사전 검사 통과 → **U 한 번**.
6. 성공과 정리 완료를 확인하고 펌웨어로 돌아오면 **F7 → Advanced Mode → Boot → Boot Override → Windows Boot Manager**.
7. **이 사이에 F10 / Save Changes & Reset / 재부팅을 하지 않습니다.**
8. Windows에서 GPU를 사용하는 다른 프로그램을 종료한 상태로 [동일 벤치마크](docs/BENCHMARK.ko.md)를 실행해 비교합니다.

`STOP / POWER OFF` 또는 실패가 나오면 Windows로 이어서 진행하지 말고 전원을 완전히 끈 뒤 로그를 확인합니다. 같은 부팅에서 U를 반복하지 않습니다. Windows 진입까지 내장그래픽 출력을 유지하는 것이 검증된 조건입니다. 진입 후 RTX 출력으로 바꾸는 경우는 미검증입니다.

## 공개 내용과 현재 한계

- `unlock/`, `deps/`: 실제 포트 소스, 헤더, host mock 테스트, 빌드 도구.
- `release/`: 성공 사례 EFI와 해당 소스 연결 해시. 펌웨어는 제외.
- `benchmark/`: 동일 측정 소스와 로컬 CUDA 12.6 준비·빌드·실행 스크립트.
- `evidence/`: 개인정보와 원본 PROM을 제외한 측정 자료·실행 로그 발췌·해시.
- Windows 직접 chainload와 내부 디스크 자동 부팅은 아직 구현하지 않았습니다. 현재 앱은 펌웨어로 반환합니다. 이 사례는 USB로 검증했습니다.
- 이 저장소는 GPU VBIOS 플래싱이나 Windows 드라이버 교체를 안내하지 않습니다. 현재 실험은 사전 부팅 상태를 바꿉니다. 재시작·전원 차단 뒤에는 다시 적용하는 절차를 전제로 합니다.

## 라이선스와 출처

포트·재사용 코어는 **GPL-2.0-only**이며, EDK2 및 별도 고지는 각 라이선스를 따릅니다. [LICENSE](LICENSE), [외부 코드 고지](THIRD_PARTY_NOTICES.md), [변경 기록](CHANGES.md)을 보존하세요. NVIDIA 펌웨어·드라이버·CUDA DLL은 재배포하지 않습니다.
