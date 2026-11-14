# RTL 的 C 扩展（RVC=1）

> 状态（2026-11-14）：R0–R3 完成：`RVC=1` 非 C 程序 64 / 64 提交与 function-model 一致，周期与 `ref_cycles_rvc.txt` 逐个相等；`RVC=0` fm_gate 64 / 64 周期不变。R4（C 程序、Linux）未做。分支 `exp/rvc-rtl`（工作区 `rtl-rvc`），未合并。
> 设计：**C910 式携带**（不是香山式二次取行）：组末 32 位指令的前半字存进携带寄存器，下一个顺序组的 slot 0 拼成整条（pc = 组 pc − 2），预测仍按第一个半字。

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
| R2 | 前端：`rvc_expand`（对 function-model 的 `rvc::expand` 全量比对）、每槽展开 / `is_rvc` / 起点链 `start_a` `start_b` / `raw0` 存进指令队列、`front_head_fix`（携带拼接、起点过滤、组末跨界指令）、携带寄存器、`is_rvc` 和 carry 位经 f2b 到后端、FTQ 的 slot 0 pc；I$ 只给半字窗口（组末最后一个半字没有高半字） | `RVC=0` 全部相等 |
| R3 | BPU（已完成）：16 槽几何、uBTB 字段（`UB_SLOT_BITS` / `UB_TGT_BITS`、`ub_expand`）、BTB / TAGE 哈希按 `SLOT_SHIFT`、RAS 压栈 `pc + 长度`、训练带长度位、块边界 | 同上，BPU 计数与模型一致 |
| R4 | C 程序（`build_c`：cpu-tests、`rvc-*`、`rvc-sv32`、`rvc-fencei`、`rvc-irq`）和 Linux（rv32c）逐条对 function-model、周期对 trace-model | 全部 PASS、周期相等 |

## 约定（slot / pc）

- slot 是 2 字节位置，一个 32 字节块 16 个槽；一组的第 i 个槽 pc = 组基址 + `SLOT_BYTES` × i。
- 唯一的例外：携带拼成的指令占 slot 0，pc = 组基址 − `SLOT_BYTES`（`front_head_fix` 的 `carry`，f2b 项里的 `carry` 位）。FTQ 取 pc：slot 0 单独读，slot 1.. 从 slot 1 起算（`pre_idu_ftq_pc`）；BPU 修复记录里的槽号用多一位的相对槽号，`−1` 表示携带的 slot 0（`pre_idu_ftq_bpu`）。
- BPU 的 bank = `pc[BANK_TOP-1:SLOT_SHIFT]`（`BANK_TOP` = 5），bank pc = pc >> `BANK_W`；所有哈希在 slot 地址（pc >> `SLOT_SHIFT`）上做。
- 预测按指令的第一个半字；携带指令不参与 BPU 训练的元数据对齐（它用下一块 slot 0 的预测元数据）——对 SPEC 的影响还没量化。

## 已知遗留

- RVC=1 的 uBTB 块跟踪器是逐 lane 串行版本（`bpu_ub_track_ser`），RVC=0 是并行版本；时序没评估。
- RVC=0 的指令队列项里也存 `raw0` / `start_a` / `start_b` / `is_rvc`（综合会剪掉，面积没统计）。
- `is_rvc` 的位置、周期都已与模型对齐，但 C 程序的周期表还没有（R4）。
