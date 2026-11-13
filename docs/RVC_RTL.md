# RTL 的 C 扩展（RVC=1）

> 状态（2026-11-14）：R0、R1、R2a（I$ 第二行）完成；R2b（预译码 / 起点链 / lastHalf / FIFO）、R3 未开始。分支 `exp/rvc-rtl`（工作区 `rtl-rvc`），未合并。

目标：RTL 与 trace-model 的 `RVC=1` 配置周期逐个相等、提交逐条与 function-model（`RVC=1`）一致。设计依据在总仓库 `docs/EXPLORATION.md` 的 EXP-037 / 038：
slot 是 2 字节位置（32 B 块 16 个槽）、预译码按槽展开压缩指令并给出指令起点链、跨块 32 位指令归起始所在的块（`lastHalf`）、
每条指令带 `is_rvc`、后端所有「pc + 4」变成 `pc + (is_rvc ? 2 : 4)`。

## 配置

`SIM_SRC=<trace-model> bash scripts/gen_cfg.sh -DFP=0 -DRVC=1`（rv32 无 F/D；默认提交的配置包是 `RVC=0`）。配置包多了 `RVC_ENABLE`、`FETCH_BYTES`、
`SLOT_SHIFT`、`SLOT_BYTES`，`RVC=1` 时 `FETCH_WIDTH = BACKEND_FETCH_WIDTH = 16`、`FTQ_OFFSET_WIDTH = 4`。

## 参考周期

`scripts/ref_cycles_rvc.txt`：trace-model（`FP=0 RVC=1`，`LSU_PIPE_NOWD=1`）在 `scripts/ref_cycles.txt` 的程序上的周期（没有 C 的程序，前端按 16 槽几何取指）；
与 `RVC=0` 的表有 26 个程序不同。带 C 的程序（`trace-model/build_c`）以后另列一张表。`RVC=0` 的模型和 `ref_cycles.txt` 完全相等（64 / 64）。

## 步骤

| 步骤 | 内容 | 验证 |
|---|---|---|
| R0 | 配置包导出 `RVC_ENABLE` / `SLOT_*`；`RVC=1` 参考周期表 | `RVC=0` 配置包下 lint 不变 |
| R1 | 后端：每槽 `is_rvc`（FTQ 存、前端 → 后端通路，前端先接 0）、`pc + ilen`（BRU、ROB 刷新后取指、提交时的顺序目标）、JAL / JALR 的链接值、`misa.C`、FTQ 槽 pc = 基址 + `SLOT_BYTES` × 偏移 | `RVC=0`：lint、`fm_gate` 周期与 `ref_cycles.txt` 全部相等 |
| R2a | I$ 第二行（香山式，按需；trace-model `icache_module.cpp` 的 `xl_*`）：第二个 tag / 半字读口、两阶段请求寄存器、重放、半字窗口（`icache_resp`）。`RVC=0` 的 lint、`fm_gate` 周期不变；`RVC=1` 的行为要等 R2b 才能整体验证 | `RVC=0` 全部相等 |
| R2b | 前端其余：I$ 每槽 32 位窗口（行尾跨行、页尾取下一页，见 trace-model `ICacheTop.cpp`）、压缩指令展开、起点链 `start_a` / `start_b`、`lastHalf`、`seq_next_pc`、预译码检查器的 `is_rvc`、各 FIFO / PTAB 宽度 16、指令缓冲按指令 | `RVC=1`：非 C 程序周期等于 `ref_cycles_rvc.txt` |
| R3 | BPU：16 槽几何、uBTB 字段（`UB_SLOT_BITS` / `UB_TGT_BITS`、`ub_expand`）、BTB / TAGE 哈希按 `SLOT_SHIFT`、RAS 压栈 `pc + 长度`、训练带长度位、块边界 | 同上，BPU 计数与模型一致 |
| R4 | C 程序（`build_c`：cpu-tests、`rvc-*`、`rvc-sv32`、`rvc-fencei`、`rvc-irq`）和 Linux（rv32c）逐条对 function-model、周期对 trace-model | 全部 PASS、周期相等 |
