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

## 预测准确率修复（2026-11-15）：trace-model 与 RTL 同步

hmmer 的 rv64gc 点上 48.7% 的取指组被 predecode 检查器冲刷（rv32 几乎为 0）。查到三处，trace-model（`exp/rvc-carry`）和 RTL 都已改：

| 问题 | 原来 | 现在 | RTL |
|---|---|---|---|
| BTB 未命中的预测目标 | `Btb::select` 收到的是银行内本地 pc（pc 右移 `BANK_W`），兜底返回它 + 4，得到 `(pc>>4)+4`，一个落在前 64 KiB 的地址，前端去取没有映射的页 | 兜底 = 真实 pc + 指令长度，只在第一个 taken 槽算一次（与 `ras_val` 共用加法器） | `bpu_btb_sel` 只输出 `tgt_valid`，`bpu_main_sel` 选 `first_fall` |
| 过期的类型表记录 | 非控制指令提交不训练类型表，一次错误的 type 命中会在循环的每次迭代里冲刷一次 | predecode 发现“预测了 taken 但那里不是分支”，把该 pc 的类型条目清成 NONCTL；这个 bank 的类型更新通道本周期有队列项时放弃（下次冲刷再试） | `front_pd_info` 输出 `pd_nb_valid` / `pd_nb_pc`，`bpu_banks` 的类型通道在没有队列写时接清除请求 |
| 跨组边界的 4 字节预测 taken 分支 | 最后一个槽位的指令被丢弃（预测已跳到目标，没人补上半个半字），冲刷重取 | 上半个半字在同一 cache line 时直接补全；补全后组的顺序下一地址是该指令之后（`seq_next_pc = pc + 4`，不是块末尾，否则预测错误后会从指令中间开始取指） | `icache_resp` 输出 `upper_ok`，经取指缓冲和指令 FIFO（`up_ok`）到 `front_head_fix` |

验证：
- RTL（rv64，FP=1，RVC=1）58 个 C 程序与 `bench`、`benchs`、`chase`，周期与 trace-model 逐个相等，逐条提交与 function-model 一致（`bench` 2025 万条提交，9,698,580 周期）。
- 默认配置（rv32，RVC=0，无 FP）`fm_gate` 64 / 64 通过，周期与新模型逐个相等；新模型与旧 `ref_cycles.txt` 只有 `vm-sum-fetch-test` 一个程序不同（3983 → 3990），表已更新。
- 没做：rv32 `RVC=1`（`ref_cycles_rvc.txt` 是修复前的模型周期，会有变化，没有重新生成）。
hmmer 点：sp11 / sp13 周期 -43% / -42%（3.2 → 5.5 IPC）。


## RAS：推测栈改成追加队列，检查点只存指针（trace-model 73aea0d，2026-11-15）

起因：rv64 gcc 在 libc `memset` 的 `ret` 上最多 6% 误预测。memset 的 `sd` 循环以一条跨 32 B 块边界的 32 位 `bne` 结束，即携带指令（pc = 块基址 − 2）。
旧的修复对它没有记录（`BR_NOREPAIR`），走回退（推测状态 = 提交状态 + epoch + 1），飞行中所有记录随之作废，连锁误预测。

模型与 RTL 的改动（同一套逻辑）：

- 推测 RAS 是 64 槽的追加队列（`bpu_spec`：`st_q[]`、`nos_q[]`、`rp_q` = tosr / tosw / cnt）：压栈写新槽 `tosw`（`nos` = 下面一项），弹栈只沿 `nos` 回退 `tosr`，因此**指针检查点是精确的**（环形栈在“弹栈后错误路径压栈”时会覆盖栈内的项）。深度仍是 32（`cnt` 饱和）。提交 RAS 仍是环形栈。
- 检查点只有 tosr / tosw / cnt（18 位）加栈顶值；后端 FTQ 携带的检查点从 140 位变为 158 位（`HCK_W` = RAS 指针 + 历史），`back_top` 和 `spec/*.io` 的位宽同步。
- 误预测修复：历史和 RAS 都从记录恢复，不再强制用提交 RAS（模型的 `repair_blk` 里 `n.sras = n.aras` 删除）。无记录时回退：由提交栈重建队列（槽 0 = 栈底）。
- 携带指令（pc = 块基址 − 2）由补全它的块的记录精确修复：`pre_idu_ftq_bpu` 不再给槽 0 返回 `BR_NOREPAIR`（该类型删除），槽取 0，类型取该槽的 kind。

实现注意（编译时间）：队列不能做成一个打包的 4096 位结构体在组合逻辑里逐级传递。第一版这样写，Verilator 生成的 C++ 里 clang 单个文件编了 30 分钟以上。现在是数组 + 指针，一次命令的结果是“指针 + 最多两次槽写入（重叠视图）”，两次命令（REFONLY 的重取命令加 S0 压栈）用 `rst_t` 组合，数组只在寄存器更新时写。

验证（均为逐提交 function-model 检查）：

- rv32 `RVC=0` `fm_gate`：64 / 64 通过，周期与新模型逐个相等；7 个程序周期随 RAS 改动变化（coremark、dhrystone、bit、fence-i-self-modify、recursion、smc-addi、vm-pagefault-test），`ref_cycles.txt` 已更新。
- rv64（`RVC=1`、`FP=1`）：58 个 C 程序 RTL 周期与模型全部相同；`bench`、`benchs`、`chase` 也相同（9545188 / 419407 / 4941826）。
- 模型侧：gcc 的 sp19 / sp42 / sp35 周期 −14.8% / −18.1% / −8.5%；12 个程序共 93 个点几何平均 −0.48%，没有一个高于 +0.1%。
- 没做：rv32 `RVC=1` 的参考表 `ref_cycles_rvc.txt` 仍是旧模型的周期，没有重新生成；EXP-015 “RAS 取自提交状态”的结论来自 rv32 数据和环形栈检查点，不适用于这个队列实现。
