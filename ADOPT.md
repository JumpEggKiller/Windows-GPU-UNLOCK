# Unlock your RTX 3090s — the one-command path

This repository makes a **UEFI application** that unlocks the GPU's stock power/virtualization
limits **before Windows starts**, proves the result, and then boots Windows normally. Nothing is
flashed, no VBIOS is touched, no partition is deleted, and the unlock is applied again on every
boot because it never survives a power cycle by design.

`Adopt.ps1` walks one machine through the whole thing in ten small steps and remembers where it
is. Each run is resumable: run it, do what it asks, run it again.

---

## English

### What only you can do (four things)

1. Have **exactly one spare FAT32 partition or USB stick** that Windows is not using — the images
   and firmware assets are staged there, never on the Windows EFI partition.
2. **Generate the five firmware assets** once, on Linux or WSL, from the pinned upstream source
   (recipe below). They are deliberately not in this repository — they are NVIDIA firmware and
   the licensing is not ours to redistribute.
3. **Boot the probe stick once** so the tool can read your cards' real identity (PCI address,
   subsystem, PROM fingerprint). This is read-only; it unlocks nothing.
4. **Boot once by hand** at the end, to confirm the unlock works before the machine is allowed to
   do it unattended.

Everything else is the command below.

### Generating the firmware assets (once per machine, not per boot)

```sh
git clone https://github.com/Zagitta/gpu-unlock.git
git -C gpu-unlock checkout --detach 0ebdb1c6308b6a2072be5bf04513472942541956
cd gpu-unlock
make inputs firmware PYTHON=python3.14 INPUTS="$PWD/inputs" ASSETS="$PWD/assets"
# copy these five out of ./assets and into this repository's assets/ folder:
#   booter_load_ga102.bin  v67-ga102-610.43.03.bin  gsp_ga10x.bin
#   gsp_boot_ga102.bin     gsp_boot_desc_ga102.bin
```

`unlock/assets.json` holds the exact names, sizes and SHA-256. A file that does not match is
refused at staging time, not discovered at boot time. Python 3.14 is required by the upstream
generator (it reads `.tar.zst`), which is a different Python from the one that builds the images.

### Prerequisites

| requirement | why |
|---|---|
| RTX 3090 (`10de:2204`, VBIOS `94.02.*`) | the only card family with a measured stock profile here; other cards **stop** the flow by design |
| the five firmware assets, generated once under WSL/Linux | see the recipe above; `unlock/assets.json` pins size and SHA-256 |
| Secure Boot **off** | the image is not signed by Microsoft; an unsigned image cannot be booted with it on |
| `C:` BitLocker **fully decrypted**, protection off | the installer refuses to run otherwise, and never changes your encryption settings |
| admin PowerShell | boot configuration and the ESP need it |
| Python 3, clang/lld | only if you build from source; bundled tools are used when present |

### The whole flow

```powershell
git clone https://github.com/JumpEggKiller/Windows-GPU-UNLOCK.git
cd Windows-GPU-UNLOCK

.\Adopt.ps1                 # what stage am I in, and what is next (bilingual)
.\Adopt.ps1 -Next           # run the next step
.\Adopt.ps1 -All            # run every step that needs no human, then stop
```

`-Next` is the honest interface: it runs one step and prints exactly what to do next. Two steps
end with "now reboot and come back", and two steps write boot configuration, which they refuse to
do unless you pass `-Yes` on that call:

```powershell
.\Adopt.ps1 -Next -Yes      # allow this step to change boot configuration
.\Adopt.ps1 -Restore        # put Windows first again, any time, nothing is deleted
```

### The ten steps

| # | step | who does it |
|---|---|---|
| 1 | `check` — cards, Secure Boot, BitLocker, board | automatic |
| 2 | `probe-build` — build the read-only probe, copy it to your stick | automatic |
| 3 | — **boot the stick, then come back** | **you** |
| 4 | `pins` — turn the probe report into this machine's card table | automatic |
| 5 | `configure` — pin the dedicated ESP for this machine | automatic |
| 6 | `build` — build four images (two children, two wrappers) | automatic |
| 7 | `stage` — copy images and firmware assets onto the ESP | automatic |
| 8 | `register` — register the boot entry (`-Yes`) | automatic, one confirmation |
| 9 | — **one manual cold boot, then come back** | **you** |
| 10 | `arm` + `verify` — let the firmware try the image first (`-Yes`) | automatic |

After step 10 every cold boot does this, with nobody at the keyboard:

```
firmware -> our image -> unlock all cards -> prove it -> start Windows Boot Manager -> Windows
```

### What you will see

* While it works: a short banner and a countdown you can cancel with **Esc** (3 s in the wrapper,
  3 s more inside the unlock image). Any key press sends you straight to Windows.
* When it fails: a **stopped** screen, not a reboot loop, and not Windows. That is deliberate —
  a machine that keeps retrying a firmware change is a machine you cannot reason about. Power off,
  then pick Windows from the firmware's own boot menu, or run `.\Adopt.ps1 -Restore` later.
* The proof is a file, not a message: `<esp>:\RTX3090-UNLOCK\HANDOFF.ST` contains
  `GUH1 <status> <eligible> <unlocked> <retained> <clean>`. A clean boot reads
  `GUH1 0000000000000000 4 4 4 4`. The wrapper refuses to start Windows unless that record says
  every card was unlocked and still reads unlocked afterwards.

### When something goes wrong

| symptom | meaning | what to do |
|---|---|---|
| stops with `0xc000007b`, `0xc0000221`, `0xc0000428` | **Windows Boot Manager** tried to load the image and refused it | this is why the firmware order, not the Windows menu, is used; run `-Next` to continue with the firmware route |
| stopped screen with `HANDOFF STOPPED` | the unlock batch was not clean | read `<esp>:\RTX3090-UNLOCK\FULLnn.TXT` and `RUNnn\REPORT.TXT`, then `-Restore` |
| `CHECK stage=display` refused | the card owns the console's display path and no other display adapter is left | keep that card out of the table (the generator already puts the display card last and marks it) |
| `CHECK stage=ownership` refused | a driver owns the card and would not let go | the display card's children are released explicitly; other refusals stop the flow on purpose |
| text on screen with `?` and parser errors | the script was re-saved without a UTF-8 BOM | re-save as **UTF-8 with BOM**; `internal-boot\Test.ps1` checks this for the whole tree |

### Do not do this

* Do not flash a VBIOS. This flow never does, and a flashed card cannot be restored by it.
* Do not disable the display check to make a stubborn card work. The check is the only thing
  standing between you and a machine with no console.
* Do not "try" firmware order entries one by one. Every write is prepared, rehearsed offline and
  verified by reading it back; if a write is not verified, it is rolled back.

---

## 中文

这个仓库做的是一个 **UEFI 应用程序**：在 Windows 启动**之前**解除 3090 的出厂功耗/虚拟化限制，
证明解锁成功，然后正常进入 Windows。不刷 VBIOS，不删分区，不动 Windows 的 EFI 分区；
解锁本身每次开机重做，因为它按设计不跨断电保留。

`Adopt.ps1` 把整台机器的流程拆成十个小步骤并记住进度，随时可中断、可重跑。

### 只有你能做的四件事

1. 准备**一个** Windows 没在用的 **FAT32 分区或 U 盘**——镜像和固件资源放这里，绝不写 Windows 的 EFI 分区。
2. **生成那五个固件资源**（一次即可，在 Linux 或 WSL 里，见上面的命令）。它们刻意不放进仓库：那是 NVIDIA 的固件，授权不允许转发。
3. **用 U 盘启动一次**，让工具读到显卡的真实身份（PCI 地址、子系统、PROM 指纹）。这一步纯读取，不解锁任何东西。
4. 最后**手动冷启动一次**，确认解锁真的能用，之后才允许机器自动执行。

其余都是命令。

### 需要一次性的固件资源

```sh
git clone https://github.com/Zagitta/gpu-unlock.git
git -C gpu-unlock checkout --detach 0ebdb1c6308b6a2072be5bf04513472942541956
cd gpu-unlock
make inputs firmware PYTHON=python3.14 INPUTS="$PWD/inputs" ASSETS="$PWD/assets"
# 把 ./assets 里的五个 .bin 复制到本仓库的 assets/ 目录
```

`unlock/assets.json` 里有确切的名字、大小和 SHA-256。对不上的文件在**写入阶段**就被拒绝，不会等到开机才发现。
上游生成器要 Python 3.14（它要读 `.tar.zst`），和构建镜像用的 Python 不是同一个要求。

### 前置条件

| 条件 | 原因 |
|---|---|
| RTX 3090（`10de:2204`，VBIOS `94.02.*`） | 这里只有这一族的实测原型；其它卡会**主动停止** |
| 关闭 Secure Boot | 镜像没有微软签名，开了就启动不了 |
| `C:` 的 BitLocker 已完全解密、保护关闭 | 否则安装器拒绝运行；它从不改你的加密设置 |
| 管理员 PowerShell | 改启动配置和写 ESP 需要 |
| Python 3、clang/lld | 只有从源码构建才需要；能找到内置工具时自动使用 |

### 全部命令

```powershell
git clone https://github.com/JumpEggKiller/Windows-GPU-UNLOCK.git
cd Windows-GPU-UNLOCK

.\Adopt.ps1                 # 我现在在哪一步，下一步是什么（中英对照）
.\Adopt.ps1 -Next           # 执行下一步
.\Adopt.ps1 -All            # 把所有不需要人的步骤跑完，然后停下
```

`-Next` 就是全部接口：跑一步，并明确告诉你下一步做什么。只有两步会要求你重启机器再回来，
另有两步会写启动配置，**不加 `-Yes` 就不写**：

```powershell
.\Adopt.ps1 -Next -Yes      # 允许这一步修改启动配置
.\Adopt.ps1 -Restore        # 任何时候把 Windows 恢复成第一个，什么都不删
```

### 十步流程

| # | 步骤 | 谁做 |
|---|---|---|
| 1 | `check` — 显卡、Secure Boot、BitLocker、主板 | 自动 |
| 2 | `probe-build` — 构建只读探测镜像并复制到 U 盘 | 自动 |
| 3 | — **用 U 盘启动一次，然后回来** | **你** |
| 4 | `pins` — 把探测报告变成这台机器的显卡表 | 自动 |
| 5 | `configure` — 绑定这台机器的专用 ESP | 自动 |
| 6 | `build` — 构建四个镜像（两个子程序、两个外壳） | 自动 |
| 7 | `stage` — 把镜像和固件资源写入 ESP | 自动 |
| 8 | `register` — 注册启动项（`-Yes`） | 自动，需一次确认 |
| 9 | — **手动冷启动一次，然后回来** | **你** |
| 10 | `arm` + `verify` — 让固件先试镜像（`-Yes`） | 自动 |

第 10 步之后，每次冷启动都会这样，全程无人值守：

```
固件 -> 我们的镜像 -> 解锁全部显卡 -> 证明结果 -> 启动 Windows Boot Manager -> Windows
```

### 你会看到什么

* 正常时：一行横幅加一个倒计时，按 **Esc** 可以取消（外壳 3 秒，解锁镜像里再 3 秒）。按任意键直接进 Windows。
* 失败时：屏幕**停住**，不会重启循环，也不会进 Windows。这是故意的——会自己反复重试固件改动的机器无法排查。
  断电，用主板的开机菜单选 Windows，或者之后跑 `.\Adopt.ps1 -Restore`。
* 证据是文件不是提示：`<esp>:\RTX3090-UNLOCK\HANDOFF.ST` 里是
  `GUH1 <status> <eligible> <unlocked> <retained> <clean>`。干净的一次是
  `GUH1 0000000000000000 4 4 4 4`。记录不干净，外壳就**拒绝**启动 Windows。

### 出问题怎么办

| 现象 | 含义 | 处理 |
|---|---|---|
| 停在 `0xc000007b` / `0xc0000221` / `0xc0000428` | **Windows Boot Manager** 试图加载镜像并拒绝 | 所以走的是固件启动顺序而不是 Windows 菜单；继续 `-Next` |
| 停住并显示 `HANDOFF STOPPED` | 解锁批次不干净 | 读 `<esp>:\RTX3090-UNLOCK\FULLnn.TXT` 和 `RUNnn\REPORT.TXT`，然后 `-Restore` |
| `CHECK stage=display` 被拒 | 这块卡占着控制台显示路径，且没有别的显示适配器 | 把它排除在表外（生成器已经把它放最后并标注） |
| `CHECK stage=ownership` 被拒 | 有驱动占着卡且不肯放手 | 显示卡的子句柄会被显式释放；其它拒绝都是故意停下的 |
| 屏幕上出现 `?` 和语法错误 | 脚本被重新保存时丢了 UTF-8 BOM | 重新存成 **UTF-8 带 BOM**；`internal-boot\Test.ps1` 会扫描整棵树 |

### 不要做

* 不要刷 VBIOS。本流程从不刷，刷过的卡也没法用它恢复。
* 不要为了"让难搞的卡跑起来"关掉显示检查——它是你和控制台全黑之间唯一的一道门。
* 不要一个个去试固件启动项。每次写入都会先离线演练、写后回读校验，校验不过就自动回滚。

---

## Where the details are

| file | contents |
|---|---|
| `internal-boot/ADOPT-RIG.md` | the full agent-facing procedure: every command, every refusal, the recovery table, what is still rig-specific |
| `internal-boot/MAINTENANCE.md` | the steps executed on the reference machine, with the exact commands and the rollback for each |
| `internal-boot/CHANGE-PROPOSAL.md` | what is changed in boot configuration, in what order, and how each change is undone |
| `internal-boot/README.md` | why the wrapper is a plain EFI application, why the firmware order is the trigger, and why the Windows menu is not |
| `unlock/pins-from-report.ps1` | how a probe report becomes the per-card pin table |
