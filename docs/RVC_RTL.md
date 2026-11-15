# RTL 的 C 扩展（RVC=1）

> 状态（2026-11-15）：R0–R3 完成，R4（C 程序、rv64 Linux）验证中：rv64 `RVC=1` 58 个 C 程序与 bench / benchs / chase 的 RTL 周期与 trace-model 全部相同并逐提交与 function-model 一致；`RVC=0` rv32 fm_gate 64 / 64 周期与新模型逐个相等；推测 RAS 已改为追加队列（见末节）。分支 `exp/rvc-rtl`（工作区 `rtl-rvc`），合入 main 前的验证见末节。
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

- **rv32 `RVC=1`（`FP=0`）整核测试平台起不来（2026-11-15 查）**：`gen_cfg.sh -DFP=0 -DRVC=1` 生成配置包、`FMLIB` 用 `XLEN=32 FP=0 RVC=1` 的 function-model 库，`scripts/fm_gate.sh` 的 67 个程序全部在第一条提交（周期 219）报 `pc rtl=4 fm=0`。在没有任何未提交改动的 HEAD 上同样复现，**不是这次改动引入的**；没有查是 RTL 前端的起点、测试平台的启动桩还是 function-model 库的 RVC 设置。rv64 的 `RVC=1`（Linux 和 58 个 C 程序）是通的。要做 rv32 `RVC=1` 的参考表 `ref_cycles_rvc.txt` 之前要先解决这个。

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

## Linux 回归的构建与运行（rv64，2026-11-15）

- **构建**：`FMLIB=<XLEN=64 FP=1 RVC=1 的 librefcpu.a> bash scripts/build_soc64_linux.sh [输出目录]`。固定带 `-DTTG_EBREAK_TRAP`（OpenSBI 的半主机探测）和 **`--threads 4`**（`THREADS=<n>` 可改）。**全程 Linux 回归默认 4 线程**：不带 `--threads` 构建的仿真是单线程，跑 1.4 亿周期要多花 2~3 倍时间（这一轮曾因为重建时漏掉线程参数，单线程跑了 3 个多小时才到 62%）。几百万周期以内的检查点复现可以用单线程构建（构建快），但整段回归一律用本脚本。
- **rv64 的配置包不用手工生成**（2026-11-15）：`SOC_XLEN=64` 时 `tb/soc/build.sh` 在构建目录的 RTL 副本里从 trace-model 生成 `-DXLEN=64 -DRVC=1 -DFP=1` 的配置包（`SOC_RVC`、`SOC_FP` 可改；与 `gen_cfg.sh` 用同一个脚本），提交的 rv32 配置包不动；测试平台的 `soc_probe.inc`（解码 RTL 打包结构用的位宽）也读这份副本（`TTG_CFG_PKG`）——位宽不对会得到「功能检查全过、周期却分叉」这种难查的现象。`TM_DIR` 必须是带 `front-end/BPU/fpr.h` 的 trace-model（如 `trace-model-rvc`）。
- **运行**：`IV=500000 bash scripts/linux_gate.sh <soc_tb> <trace-model 的 simulator> <linux64gc.bin> 140000000 <输出目录>`。三项全过才算通过：逐条 function-model 检查（寄存器值、store 地址和数据、设备读必须真有 MMIO 请求、中断）、每个区间的 PMU 一级事件完全相同、控制台到 `login:`。
- **定位分叉**：`BIN=1000 IV=1000 MAXCYC=<周期> DRILL=1 bash scripts/align_check.sh <镜像> <soc_tb> <模型>` 按 1000 周期区间找第一个不同的区间和预测器指纹（PT/UP）；更近的复现用 function-model 的 `--mode special-ckpt` 生成检查点，再 `tools/ckpt2image.py` / `function-model/tools/ckpt2stub.py` 转成镜像和恢复程序，RTL 用 `SOC_TB_STUB`，trace-model 用 `--mode ckpt --restore-stub`，两边都加 `FPR=<bin>`。UP 指纹现在包含 TAGE 的索引和标签（`FPR_DUMP` 能看到 `idx=… tag=…`），可以在第一个索引不同的更新事件上直接停住。

## 新特性要补短 gate 测试程序（约定，2026-11-15）

实现了新的微架构特性（模型和 RTL 都要有的行为：推测执行的值路径、页错误 load 的写回、预测器结构、LSU 转发规则……），**同时补一个能稳定触发它的短 gate 测试程序**，
放在 `programs/directed/`（`build.sh` 里加一项，周期数进 `scripts/ref_cycles*.txt` 的对应表），做成 rv32 / rv64 同源。理由：

- 这类差异在 Linux 里要跑到几百万周期之后、靠偶然的推测窗口才出现，定位一次要几十分钟；短程序几秒钟复现，而且以后任何改动都会回归到它。
- 2026-11-15 的两个例子：页错误的 load 把出错地址写进目的寄存器（RTL）而模型用功能模型的值，在第 4012380 周期的错误路径上让两边的页表遍历不同；
  store 的基址寄存器来自读到旧值的 load，数据被写到旧地址（模型的 `LSU_MS_DATA` 第 2 位原来默认关）。两个都是从 Linux 里一路追下来的，
  这两种情形现在各有一个短程序：`programs/directed/memspec_addr.S`（旧地址 store / load，模型 `LSU_MS_DATA=1` 时周期不等，rv32 / rv64 都能区分）和 `memspec_pf.S`（错误路径上页错误的 load 的消费者，M 模式 `MPRV` 分页；rv64 版能区分旧 RTL，周期差 9，rv32 版只做功能检查和周期相等，区分不出旧 RTL）；`memspec_data.S` 覆盖旧值路径。rv64 的几个在 `scripts/ref_cycles_rv64.txt`，用 `REF_CYCLES=scripts/ref_cycles_rv64.txt bash scripts/fm_gate.sh <rv64 soc_tb> <输出目录>` 跑。
- 小程序的判据和 Linux 一样：逐条 function-model 检查无不一致 + 模型与 RTL 周期相同（必要时再加 PT/UP 指纹，`align_check.sh`）。
- 写之前先确认它真的能触发：在没有该特性的旧实现上它应当失败（周期不同或检查不一致）。

Linux 层面的快速 gate：`scripts/linux_segments_cmp.sh <soc_tb> <模型> <检查点目录> <输出目录> [周期]`，把 Linux 切成每 1000 万条指令一个检查点窗口，
RTL 和模型从同一个检查点冷启动、各自跑同样的周期数，只比较逐条检查和 PT/UP 指纹（PMU 区间按绝对周期切，恢复程序在 RTL 里比模型慢约 8k 周期，不比）。
并行跑，十几分钟出全部结果；从复位的 140M 周期完整 gate 留作合并前的最后确认。
