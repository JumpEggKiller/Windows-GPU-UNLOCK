# Windows GPU UNLOCK — unlock your RTX 30-series cards before Windows starts

A UEFI application that runs **before** Windows, unlocks the factory power/virtualization
limits on every card it finds, **proves** the result from a file on disk, and then starts
Windows without a reset. The unlock is volatile: it is re-done on every cold boot, on purpose.

It is written for a machine that has **never** been unlocked — a normal desktop with a stock
RTX 3090 (one, or several), Windows installed, nothing prepared. Nothing here is permanent:
after a power cycle the card is exactly as it was until the next boot re-applies the unlock.

> **Start here / 从这里开始: [ADOPT.md](ADOPT.md)** — one command, ten resumable steps,
> English and 中文. This page is the summary; ADOPT.md is the procedure.

```
firmware -> our image -> detect + unlock every card -> prove it in HANDOFF.ST -> Windows
```

## Quick start (a machine whose 3090 compute is not unlocked)

```powershell
git clone https://github.com/JumpEggKiller/Windows-GPU-UNLOCK.git
cd Windows-GPU-UNLOCK

.\Adopt.ps1                 # what stage am I in, and what is next (bilingual)
.\Adopt.ps1 -Next           # run the next step
```

`-Next` runs one step and prints exactly what to do next. Two steps end with "now reboot and
come back"; two steps write boot configuration and refuse to unless you add `-Yes` on that
call. `.\Adopt.ps1 -Restore` puts Windows back in front at any time and deletes nothing.

## What it detects itself

* **how many cards** exist, and which one drives the display (`nvidia-smi`)
* each card's **BDF, device id, subsystem, VBIOS version**
* each card's **VBIOS PROM SHA-256 and `config[0xc8]`**, from one read-only probe boot
* the **dedicated ESP** and the **Windows ESP** identities, and the firmware boot order

There is **no board or VBIOS whitelist any more**. The board/BIOS is recorded and printed, not
enforced. Any NVIDIA card is inventoried and pinned; the flow does not stop at detection time.

## What still refuses, and where

Two refusals matter, and both are deliberate.

**1. No console to fall back on.** Unlocking a card releases its firmware driver, which can blank
the screen. So the **display card** is only unlocked when at least one other display path survives
(an iGPU, a BMC/IPMI console, or a second GPU). On a single-GPU desktop whose only output is the
card itself, the flow refuses that card instead of taking the screen away from you.

**2. An unmeasured VBIOS/GFW family.** Before touching a card the unlock compares what it observes
(chip id, GUFW status words, SS0/SS1) with the selected stock profile, and stops that card with a
log on the ESP if the family does not match. Fail-closed by design: a card with an unmeasured
family is *not* unlocked, and Windows still starts.

`-StockProfile` (default `entryLatchedSs1Full`) selects the family. Adding a new family means
measuring it, not disabling the check.

## What only you can do

1. Provide a **dedicated FAT32 ESP ≥ 1 GiB** (never the Windows ESP) and a spare UEFI stick.
2. **Generate the five firmware assets once** under WSL/Linux (they are not in the repo for
   licensing reasons; ADOPT.md prints the exact commands).
3. **Boot the probe stick once**, then come back and run `-Next`.
4. **Boot the unlock entry once by hand** and confirm the result, before it is armed.

Everything else is automated, and every step is resumable.

## Verified state

On the reference machine (4 × RTX 3090, GIGABYTE MZ32-AR0-00): **Gate C, D and E all PASS** —
manual boot, first unattended cold boot, and a second unattended cold boot. On that machine the
record reads `GUH1 0000000000000000 4 4 4 4`: four cards `unlocked=1 retained=1 clean=1`,
`batch summary: eligible=4 attempted=4 unlocked=4 retained=4 of 4 targets`,
`FINAL(multi) status=0`, Windows up 4 s later with driver 617.42 and no reset. A one-card machine
is expected to record `GUH1 0000000000000000 1 1 1 1`; the numbers follow **your** card count, and
your timings will differ.
Evidence: [`internal-boot/evidence/gate-c-2026-10-26/`](internal-boot/evidence/gate-c-2026-10-26/),
`internal-boot/CHANGE-PROPOSAL.md`, `internal-boot/MAINTENANCE.md`.

## Read before you run

* The image is **unsigned**; Secure Boot must be off, and Windows Boot Manager will refuse to
  load it (`0xC0000428`). The trigger is therefore the **firmware boot order**, not a Windows
  menu row — this is why automatic mode needs a firmware-order change.
* Unlocking the **display card** releases its firmware driver; the console can go dark for the
  rest of the boot even when it succeeds. That is expected, and the proof is a file, not the screen.
* On failure it **stops**. No reset, no retry, no forced Windows. Escape is power-off plus the
  firmware boot menu, or the USB image.
* Everything is reversible: `.\Adopt.ps1 -Restore`.

## The original Korean research log

The upstream single-machine log (measurements, the manual USB procedure, the ASUS
`Boot Override` notes) is preserved verbatim as **[README.ko.md](README.ko.md)**.

---

# Windows GPU UNLOCK —— 在 Windows 启动之前解锁你的 30 系显卡

一个 UEFI 应用程序：在 Windows **之前**运行，找出并解锁每张卡的出厂功耗/虚拟化限制，
用磁盘上的文件**证明**结果，然后**不复位**直接启动 Windows。解锁是易失的，每次冷启动
都重新做一遍，这是设计如此。

**这份东西是写给一张从没解锁过的普通机器的**：装了 Windows、显卡还是出厂状态的台式机，
单卡或多卡都行，什么准备都没有。这里的一切都不留痕：断电之后卡就是原样，直到下次开机再自动做一遍。

> **从这里开始：[ADOPT.md](ADOPT.md)** —— 一条命令、十个可续跑的步骤，英文 + 中文。
> 本页是摘要，ADOPT.md 是流程。

## 快速开始（没有解锁 3090 算力的机器）

```powershell
git clone https://github.com/JumpEggKiller/Windows-GPU-UNLOCK.git
cd Windows-GPU-UNLOCK

.\Adopt.ps1                 # 我现在在第几步、下一步是什么（中英对照）
.\Adopt.ps1 -Next           # 跑下一步
```

`-Next` 只跑一步，并明确告诉你下一步做什么。只有两步要求“重启再回来”；只有两步会写启动
配置，**不加 `-Yes` 就不写**。`.\Adopt.ps1 -Restore` 随时把 Windows 恢复成第一个，什么都不删。

## 它会自己检测什么

* **有几张卡**，以及哪一张在驱动显示器（`nvidia-smi`）
* 每张卡的 **BDF、设备号、子系统、VBIOS 版本**
* 每张卡的 **VBIOS PROM SHA-256 与 `config[0xc8]`**（来自一次只读探测启动）
* **专用 ESP** 与 **Windows ESP** 的身份，以及固件启动顺序

**不再有主板或 VBIOS 白名单。** 主板/BIOS 只记录并打印，不再拒绝。任何 NVIDIA 卡都会被
盘点并写入卡表，流程不会在“识别”阶段停下。

## 仍会拒绝的地方

有两处拒绝，都是故意的。

**一、没有第二条显示通路。** 解锁会释放这张卡的固件驱动，可能把屏幕弄黑。所以**显示卡**只有在
还有别的显示通路活着时才解锁（核显、BMC/IPMI 控制台、或第二张卡）。单卡、且唯一输出就是这张卡
的台式机，流程会**拒绝解锁这张卡**，而不是把你的屏幕拿走。

**二、VBIOS/GFW 族没有实测过。** 动卡之前，解锁内部把实测值（芯片 id、GUFW 状态字、SS0/SS1）
与所选 stock profile 比对，族不匹配就**不解锁这张卡**，并在 ESP 上写日志。这是 fail-closed：
族未实测的卡不会被解锁，但 Windows 照常启动。

`-StockProfile`（默认 `entryLatchedSs1Full`）用来选择族。新增一族意味着**去实测它**，
而不是关掉校验。

## 只有你能做的四件事

1. 准备一个**专用 FAT32 ESP（≥ 1 GiB，绝不能用 Windows 的 ESP）**和一个空 U 盘。
2. 在 WSL/Linux 上**生成一次五个固件资源**（因授权原因不在仓库里，ADOPT.md 会打印确切命令）。
3. **用 U 盘探测启动一次**，回来再跑 `-Next`。
4. **手动冷启动解锁项一次**并确认结果，之后才允许固化。

其余全自动，每一步都可续跑。

## 已验证状态

参考机（4 × RTX 3090，技嘉 MZ32-AR0-00）：**Gate C、D、E 全部 PASS** —— 手动启动、第一次
无人值守冷启动、第二次无人值守冷启动。那台机器上的记录是 `GUH1 0000000000000000 4 4 4 4`：
四张卡 `unlocked=1 retained=1 clean=1`，`batch summary: eligible=4 attempted=4 unlocked=4
retained=4 of 4 targets`，`FINAL(multi) status=0`，4 秒后 Windows 起来，驱动 617.42，全程无复位。
单卡机器的记录应当是 `GUH1 0000000000000000 1 1 1 1` —— 数字按**你自己的**卡数走，时间也会不同。

## 运行前必须知道

* 镜像**没有签名**：Secure Boot 必须关；Windows Boot Manager 会拒绝加载它（`0xC0000428`）。
  所以触发器是**固件启动顺序**，不是 Windows 菜单项 —— 这就是自动化模式需要改固件顺序的原因。
* 解锁**显示卡**会释放它的固件驱动，控制台可能在这一轮启动里黑掉（即使成功）。这是预期行为，
  证据是文件不是屏幕。
* 失败就**停住**：不重启、不重试、不强推 Windows。逃生方式是断电 + 主板启动菜单，或 U 盘镜像。
* 一切可逆：`.\Adopt.ps1 -Restore`。

## 原始韩文研究记录

上游的单机记录（测量数据、U 盘手动流程、ASUS `Boot Override` 记录）原样保留在
**[README.ko.md](README.ko.md)**。
