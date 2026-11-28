---
module: prf
area: backend
rtl: rtl/backend/prf
model: 当前 trace-model 里没有对应的调度单元：模型没有寄存器堆（操作数值是 trace 的事实），`Prf.cpp` 已不存在。唯一有对应的时序行为是 back-end/Exu/Exu.cpp 的 `Exu::load_wake` 和 `LoadWake` 写回寄存器（RTL 的 `prf_awake`）；FTQ pc 读口对应 `Exu::seq` 里的 `needs_ftq_pc`
status: 整核周期与模型逐个相等（EXP-060，`fm_gate` 69/69 PASS、0 周期偏差，Linux 26 窗 100% 全等）
depth: 25 层 / 639,644 单元（EXP-060 开启 `HAS_LSU_BYP` 4 路整数 `lsu_byp` 旁路，深度 0 增长、面积 +4.1%）（prf，单模块综合，2026-11-23，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 10 节）
---

# prf 设计文档

> **2026-11-28 `rtl/iss-rr`**：`u_prf` 现接在 `iss_rr_reg`（`u_iss_rr`）输出端读取寄存器并在 RR 拍送入 `exu_ctrl` 槽：1 周期 ALU / 3 周期 MUL 保持 0 气泡旁路（`exe2prf[0..5]`）、L1 推测 load 经 `lsu_byp` 在 L3 写回同拍旁路（4 路常开），DIV 改走 `wb_result_q` 写回级旁路。

## 1. 职责

物理寄存器堆，是 ISU 和执行单元之间的一环。每拍做五件事：

1. 为 ISU 这拍发射的每条指令读出操作数：整数读口按口需要生成（共 27 个，见第 2 节），浮点口和浮点 store-data 口另有浮点读口；读口带**旁路**：如果想读的寄存器正好被某个执行单元这拍出结果、或者被写回级这拍要写，就直接取那个值，不等写进寄存器堆；
2. 接收 `exu_ctrl` 的写回总线（`exe2prf`，`WB_LANES = 13` 条通道，EXP-046 之前按发射口编号是 21 条）：先在**写回级**（每条通道一组寄存器）停一拍，下一拍写进寄存器堆，同一拍被旁路给读口；
3. 为需要 pc 的指令（用 pc 做源的 ALU 指令、分支）向 FTQ 要 pc、预测方向、下一 pc，并把回答按口送回（`ftq_prf_pc_req / resp`）；
4. 把写回级里的 load 广播成唤醒（`prf_awake`，最多 `LSU_LOAD_WB_WIDTH = 4` 个），去 ISU 和分派；
5. 读口的旁路：EXU 级 6 路 ALU 通道按 ISU 送来的独热 `src*_byp` 直选，写回级和 LSU 写回按编号比较。

模型里没有寄存器堆，所以没有"PRF 的周期行为"可对：写回晚一拍、读口旁路这些在 RTL 里是为了数据正确，模型靠 trace 事实绕过。模型里和 PRF 有关的时序只有 load 的晚唤醒（`Exu::load_wake`：load 写回时若 LSU 没有提前唤醒其消费者，写回寄存器之后一拍才唤醒）。术语：**写回级**是 `prf_wb_pipe` 里每口的那组寄存器；**旁路**是不经寄存器堆直接取值。

## 2. 配置（`ttg_cfg_pkg` / `fp_pkg`，现行默认）

| 项 | 值（常量） |
| --- | --- |
| 整数物理寄存器 | `PRF_NUM = 256`，每个 `XLEN_BITS = 64` 位 |
| 浮点物理寄存器 | `FPRF_NUM = 96`，每个 `FW = FLEN = 64` 位；浮点寄存器的编号从 `FP_TAG_BASE = 256` 起，和整数寄存器共用一个编号空间 `TAG_NUM = 352`，编号宽 `PRF_IDX_WIDTH = 9` |
| 写回通道数 | `WB_LANES = 13`（`ttg_cfg_pkg`，由模型 `config.h` 的 `WB_*` 生成）：通道 `WB_ALU_BASE = 0`..5 是 ALU 口 0..5，`WB_LD_BASE = 6`..9 是 4 路 load 写回（含 SC），`WB_FP_BASE = 10`..12 是浮点口 16..18。STA / STD / BR 口不写寄存器，没有通道。整数寄存器堆 13 个写口；浮点寄存器堆 6 个（见 5.1） |
| 发射通道数（读侧） | `NIP = ISSUE_WIDTH = 19`：与 19 个物理发射口一一对应 |
| 整数读口 | 仅按发射口实际需要生成 **27 个**（ALU 6×2 + 物理 AGU 5×1 + STD 3×2 + BR 2×2；5 个 AGU 口直接各有 1 个 `src1` 读口，无需 STA 借用逻辑；FP 口 16..18 不读整数） |
| 浮点读口 | `NRD = 3 * FP_LANES + LSU_SDU_COUNT = 12`：3 个浮点口（`ISSUE_WIDTH - IQ_FP_PORT_BASE`）各 3 个源，3 个 store-data 口各 1 个数据源（fsw / fsd） |
| 旁路源 | **唤醒驱动二维 Mask + 写回级混合架构**：整数 EXU 级直接复用 `exe2prf[WB_ALU_BASE + 0..5]`（6 条 ALU/MUL/CSR/WB 通道），由 ISU 随发射送来的 6 位独热码 `src{1,2}_byp`（经 `iss_rr_reg` 锁存一拍）直驱 6:1 MUX（**0 个 EXU 级 tag 比较器**）；浮点 EXU 级仅需 1 路迭代 FDIV（`exe2prf[WB_FP_BASE + 2]`，流水化 FMA/FMISC/I2F 唤醒时已完成、消费者发射时已在 `wb_fres_q`）；WB 级保留寄存 tag 比较；`lsu_byp` 4 路常开并入 |
| FTQ pc 口 | `FTQ_PRF_PC_PORT_NUM = 4`：前 `FTQ_PRF_PC_PORT_NUM - BRU_NUM = 2` 个给有 `src1_is_pc` 能力的 ALU 口 0、2（`PC_ALU_NUM = 2`），后 2 个给分支口 14、15（`prf.sv` 的 `NPC_ALU`） |
| 唤醒槽 | `LSU_LOAD_WB_WIDTH = 4` |
| 物理 AGU 口 | `IQ_AGU_PORT_BASE = 6` 起共 `LSU_AGU_COUNT = 5` 个物理口（口 6..10）；无独立 load/STA 共享借用表 |
| 口号 | 与 isu.md 一致（0..5 整数、6..10 AGU、11..13 STD、14..15 BR、16..18 FP） |

`ttg_cfg_pkg.sv` 已由 `make cfg` 同步生成。

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `iss2prf_valid`、`iss2prf_uop`（`isu_uop_t`）、`iss2prf_src1_byp / src2_byp`（各 `ALU_NUM = 6` 位独热）`[ISSUE_WIDTH]` | 经 `iss_rr_reg` 打一拍的发射结果，读口用其中的 `src*_preg`、`src*_en`、`src1_fp / src2_fp`、`src3_*`、`ftq_idx`、`ftq_offset` 等；`src*_byp` 选 EXU 级旁路的 ALU 口 |
| 入 | `exe2prf [WB_LANES]`（`xc_prf_wb_t`：`valid`、`dest_preg`、`result`、`fresult`、`dest_en`、`rob_idx / rob_flag`、`op` 等） | 写回总线（按通道编号），进写回级；其中 ALU 通道 0..5 同拍也作 EXU 级旁路源（由 `src*_byp` 独热选），FDIV 通道作浮点 EXU 级旁路源 |
| 入 | `lsu_byp_valid / dest_preg / result / is_w [LSU_LOAD_WB_WIDTH]` | LSU 的 load 写回请求作旁路源（`back_top.sv` 里由 `lsu2exe_wb_req_*` 生成），总是开（无开关） |
| 入 | `ftq_prf_pc_resp_{pc, pred_taken, is_rvc, next_pc} [FTQ_PRF_PC_PORT_NUM]` | FTQ 的回答 |
| 入 | `dec_bcast_{mispred, redirect_rob_idx, redirect_rob_flag}`、`rob_bcast_flush` | 误预测（按 ROB 号杀掉更年轻的写回）、全局 flush（经 `rob_flush_q` 晚一拍，docs/FLUSH_REG.md） |
| 出 | `prf2exe_valid`、`prf2exe_uop`（`xc_inst_t`）`[ISSUE_WIDTH]` | 发射结果透传，加上读出的 `src1_rdata`、`src2_rdata`、`fsrc1..3`，以及口 0、2、14、15 的 `pc`、`ftq_pred_taken`、`ftq_is_rvc`、`ftq_next_pc`（其他口为 0） |
| 出 | `prf2exe_csr_idx` | 口 0 的 `csr_idx` |
| 出 | `ftq_prf_pc_req_{ftq_idx, ftq_offset} [FTQ_PRF_PC_PORT_NUM]` | 向 FTQ 要 pc（没有 valid：FTQ 每拍都读，口只在需要 pc 时用回答） |
| 出 | `prf_awake_wake_valid / _preg [LSU_LOAD_WB_WIDTH]` | load 晚唤醒 |

## 4. 结构

```
 exe2prf ─► prf_wb_pipe（13 通道写回级）┬─► prf_write_arb ─► prf_regfile（256 × 64，整数）
 dec_bcast / flush ─┘                         ├─► prf_fp（浮点：写回暂存、96 × 64、12 个读口含旁路）
                                              ├─► 各读口的旁路比较
                                              └─► prf_awake ─► prf_awake_wake_*
 iss2prf 的 src_preg ─► prf_regfile 读口（27 个）─► prf_bypass × 27 ─► src1_rdata / src2_rdata
 exe2prf ALU 通道（src*_byp 独热）、lsu_byp ──────────► （旁路源）
 iss2prf ─► ftq_prf_pc_req（ftq_idx / ftq_offset）；ftq_prf_pc_resp 按口直连回发射口
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `prf.sv` | 379 | 顶层：端口适配、按口需求生成 27 个整数读口及其旁路实例、浮点读口编号、浮点写回暂存与压缩（EXP-046）、pc 口接线 |
| `prf_wb_pipe.sv` | 61 | `WB_LANES = 13` 通道写回级寄存器 |
| `prf_write_arb.sv` | 29 | 每个整数寄存器的写使能和写数据 |
| `prf_regfile.sv` | 38 | 整数寄存器堆存储和异步读口 |
| `prf_bypass.sv` | 55 | 一个读口的旁路选择：EXU 级 6 路按独热直选（无比较），写回级 13 路和 LSU 4 路按编号比较 |
| `prf_fp.sv` | 75 | 浮点寄存器堆：写口（调用方给的写回级通道）、读口加旁路（同一个编号空间里编号 ≥ `FP_TAG_BASE` 的才是浮点寄存器） |
| `prf_awake.sv` | 44 | load 唤醒 |

状态：整数寄存器堆 `reg_file_q[PRF_NUM]`（256 项，复位全 0）；浮点寄存器堆 `reg_file_q[FPRF_NUM]`（96 项）；写回级每通道 `wb_wen_q`、`wb_is_load_q`、`wb_dest_preg_q`（`PRF_IDX_WIDTH = 9` 位）、`wb_result_q`（64 位）、`wb_rob_idx_q / wb_rob_flag_q` 和浮点的 `wb_fres_q`（64 位）。

## 5. 一拍内的数据流

### 5.1 写回级和寄存器堆

`prf_wb_pipe`：`wb_wen_d = !flush && 写回有效 && 有目的寄存器 && !被本拍误预测杀（dec_bcast_mispred 且本条比 redirect_rob_idx/flag 更年轻）`；载荷（`dest_preg`、`result`、`is_load`、`rob_idx/flag`）每拍无条件采样 `exe2prf`。`prf_write_arb` 对每个整数寄存器：命中它的写口（`wb_wen_q && wb_dest_preg_q == p`）做 AND-OR，`写使能 = |命中`，不排优先级，因为一个物理寄存器同时只有一个生产者在飞；浮点编号（≥ `FP_TAG_BASE = 256`）不命中任何整数寄存器，写 `p0` 无害（读 `p0` 恒为 0）。`prf_fp` 对浮点寄存器做同样的事，但只有 `FPL = LSU_LOAD_WB_WIDTH + FP_WB_PORTS = 6` 条写通道（EXP-046）：4 条 load 写回通道，加上把浮点单元 / I2F 的写回（`isu_pkg::MASK_FPD` 的 5 个口：2、3、16、17、18）压缩成的 `FP_WB_PORTS = 2` 条。发射级的 `isu_fp_gate` 保证这 5 个口每拍最多 2 个写浮点寄存器，所以写回级按口序取前两个（`ttg_first_set` 两级）就是全部；仿真里有检查（`[FPWB]`，超过就打印）。浮点结果只为这 9 条通道（load 4 条、ALU 通道 2、3、浮点通道 10..12）在 `prf.sv` 里暂存一拍（EXP-046 前所有口都暂存在 `prf_fp` 里）。写回级的 load 唤醒（`prf_awake`）按通道序取 load，与原来按口序同序。

### 5.2 读操作数

1. 读口的寄存器号取自 `iss_rr_reg` 寄存后的发射结果（ISS→RR 一拍）：`iss2prf_uop.src*_preg → prf_regfile 异步读 → prf_bypass`。
2. `prf_bypass`：`!src_en` 或 `src_preg == 0` 读 0；否则如果写回级某条通道（`wb_wen_q && wb_dest_preg_q == src_preg`）或 LSU 写回请求的目的寄存器等于 `src_preg`，取它的值；`src*_byp` 独热位为 1 时直接取对应 ALU 通道（`exe2prf[WB_ALU_BASE + k]`）的结果，不做编号比较。优先顺序：EXU 独热 > LSU > 写回级 > 寄存器堆（`prf_bypass.sv` 末段）。一个寄存器只有一个生产者在飞，所以最多一个命中，不排优先级。
3. 5 个物理 AGU 口（6..10）各有自己的 `src1` 读口，没有借用（EXP-072 删除了原来共用口的读口借用）。
4. 浮点：浮点口的三个源和 store-data 口的数据源读 `prf_fp`（旁路规则同上，旁路源多了 `lsu_byp` 的 `fp_load_data`，即 `flw` 的 NaN-boxing）；store-data 口的 `src2_rdata` 在 `src2_fp` 为 1 时换成浮点读出值的低 `XLEN` 位。
5. FTQ pc：口 0、2 和分支口 14、15 每拍把自己的 `ftq_idx / ftq_offset` 送 FTQ（不带 valid）；FTQ 的回答按口号直连回对应发射口，其他口的 pc 字段接 0。

### 5.3 唤醒

`prf_awake`：写回级里 `wb_wen_q && wb_is_load_q` 且不被本拍误预测杀的 lane 按口序压缩进 4 个槽（每槽数自己前面有几个唤醒的 lane，选第 k 个）。写回级里的 load 来自口 6..9 的 LSU 写回，最多 4 个，所以不会丢。

## 6. 关键路径与深度

2026-11-21（`rtl/be-wake-byp-opt`，`eda-06`，`SYNTH_ABC="strash;balance;map"`，无工艺库）：阶段 1A（读口 42→27 + 旁路按域裁剪）后 `679,466 → 447,058` 单元（−34.2%）；阶段 1B（整数 EXU 级改为 ISU 6 位二维独热 Mask 直驱、0 比较器，浮点 EXU 级压至 1 路 FDIV）后进一步降至 **395,785 单元（−41.8%）**，深度保持 **27 层**。EXP-046（2026-11-19，同一口径）：main 1,077,848 单元、36 层 → 浮点写通道压缩 867,357、36 层 → 写回总线按通道（整数写口 21 → 13）**679,466 单元（−37%）、27 层**，触发器 3570 → 1698。这是单模块口径：恒为 0 的通道在整芯片展平时本来也会被常量传播去掉，那部分不是真节省；真节省是浮点单元 5 条写通道压成 2 条。main 时的记录：单模块综合深度 **36 层**（prf；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_wb_pipe.wb_br_mask_q [671]` 到 `\prf_awake_wake_preg [7]`。，本模块没有单独综合过。以下是从代码读出的，未综合验证：

| 路径 | 内容 |
| --- | --- |
| ISU 发射 → 读 → 槽 | ISU 授予 → 被选中 uop 的 `src_preg`（`iss2prf`）→ 整数寄存器堆按编号读（256 选 1）并行 `prf_bypass` 里的 17 个编号比较（写回级 `WB_LANES = 13` 路 + LSU 4 路）和 6 路 EXU 级独热直选 → 独热选择 → `prf2exe_*_rdata` → `exu_ctrl` 槽的寄存器；这条路径把 ISU 的"选择 → 授予"接在后面，是整核最长环路的一部分 |
| 写回级 → 写回 / 唤醒 | 每个整数寄存器（256 个）对 13 个写口、每个浮点寄存器（96 个）对 6 个写口（EXP-046 前都是 21 个）比较 `wb_dest_preg_q` 生成写使能；唤醒槽的前缀计数 |
| FTQ pc | `iss2prf` 的 `ftq_idx / ftq_offset` → FTQ（模块外）→ 回答 → 发射口 pc；FTQ 的回答直接穿过 PRF |

本分支和深度有关的改动：`41e5893` 让共用 AGU 的 STA 口借用 load 口的 `src1` 读口（读口个数减少，读口输入多一个二选一）；全局 flush 晚一拍（`803692f`）使 `rob_bcast_flush` 来自寄存器。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的、或两边不同的：

- **没有寄存器堆**：模型里 `ISSUE → PRF 读 → 槽` 的数据通路、旁路、写回级都不存在，PRF 的正确性只能靠整核逐条提交的函数模型检查（fm_gate）；
- **晚唤醒的条件**：模型 `Exu::seq` 只对"没被 LSU 提前唤醒"的 load（`!early_woken`，LSU 在 L3 寄存器处已唤醒的不算）在写回寄存器一拍后唤醒；RTL 的 `prf_awake` 对写回级里每个有目的寄存器、没被杀的 load 都广播，RTL 没有 `early_woken` 这根线。RTL 里 LSU 的提前唤醒（`lsu2iss_wake_*`）和这里的晚唤醒会对同一个寄存器各唤醒一次，周期仍与模型逐个相等（fm_gate），重复唤醒为何无害本文没有逐点核对；
- **浮点写通道压缩（EXP-046）**：模型没有数据通路，没有对应结构；它成立的前提是模型的 FP 写口预约（`FpWbBusy`，`isu_fp_gate`），RTL 用仿真检查 `[FPWB]` 确认；
- **写回总线**：模型的 `exe2prf.entry` 同样按通道编号（`WB_LANES`），但只填 ALU 和 load 通道（模型没有数据通路，只用它产生 load 的晚唤醒）；RTL 的浮点通道 10..12 写浮点寄存器堆（以及 `fmv.x` / `fcvt.w` / `fcmp` / `fclass` 的整数结果）；
- **EXU 级与 LSU 写回旁路**：模型没有数据通路，没有对应结构；RTL 的读口旁路源包含 6 路 ALU 通道（独热直选）和 4 路 `lsu_byp`（总是开）。

RTL 与模型保持一致的细节：

- 晚唤醒按口序取前 `LSU_LOAD_WB_WIDTH` 个、跳过被本拍误预测杀的（模型 `load_wake`）；
- 写回级 `wb_wen` 用 flush 之外还看误预测，但寄存堆的写入本身不被下一拍的误预测撤销（写一个已经死掉的物理寄存器无害）。

未核对（继承自旧文档）：

- 旧文档的"放宽（`when valid`）与消费者核对"清单、变异检查（10/10）和 trace 回放结果：随 `spec/` 退役；旧文档提到的"rv64 的 PRF 位数翻倍，面积 / 综合数字是 rv32 的"：本文没有综合，不重复。

代码里的小问题（没有改）：`prf.sv` 顶部注释"commit 2f31e8d"指一个已不存在的模型文件；`prf_write_arb.sv` 注释里的"see notes"指旧文档。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`lint_chip` & `lint_soc` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 全通；Linux 26/26 窗对齐。
- **EXP-046（`exp/wb-presel`，浮点写通道压缩）**：`fm_gate` 67/67 逐条对函数模型无不一致，周期对模型 `CFG_WB_PRESEL=1` 67/67 相等（参考周期要用 `LSU_PIPE_NOWD=1` 生成：模型的 LDQ / STQ 看门狗 RTL 没有，不关它 crc32、memory-stress-small 会差几十拍；早先记录的"crc32 是 main 原有的差异"就是没关看门狗造成的误判）；`prf.sv` 里的仿真检查 `[FPWB]`（写回级浮点单元 / I2F 写浮点寄存器超过 `FP_WB_PORTS`）在 67 个程序里一次都没出现。综合（单模块，`synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`）：main 1,077,848 单元、36 层 → 867,357 单元、36 层（触发器 3570 → 2546）；其中暂存只留 9 个口的部分在整芯片展平时本来也会被常量传播去掉，真正的节省是浮点单元 5 条写通道压成 2 条（96 个浮点寄存器各少 3 个写口比较和数据选择，12 个浮点读口的写回级旁路各少 3 路）。

- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`。寄存器值（含旁路和写回级）靠这个逐条提交检查：错值会在下一个提交里被发现。浮点寄存器堆由 `fd-*` 程序和 `tests/fp_chain` 覆盖。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧的 trace 回放和变异检查随 `spec/` 退役。**待补**：写一个"读口 + 旁路 + 写回级"对一个简单的软件寄存器堆参考模型的随机测试（随机写回、随机旁路源、随机读），重点测同拍被写和被旁路、共用 AGU 的 `src1` 借用、`p0`。

## 9. 参数与开关速查

`PRF_NUM`、`FPRF_NUM`、`FP_TAG_BASE`、`TAG_NUM`、`PRF_IDX_WIDTH`、`ISSUE_WIDTH`、`TOTAL_FU_COUNT`、`LSU_LOAD_WB_WIDTH`、`LSU_SDU_COUNT`、`FTQ_PRF_PC_PORT_NUM`、`LSU_AGU_SHARED`、`IQ_*_PORT_BASE`、`ALU_NUM`、`BRU_NUM`（`ttg_cfg_pkg`）；`FW`、`FLEN`（`fp_pkg`）。没有开关（F/D 与 LSU 旁路总是开）。

## 10. 变更记录

- 2026-11-29 清理 E：改名 `ftq_prf_pc_req_req_*` / `_resp_resp_*` → `ftq_prf_pc_req_*` / `_resp_*`（只改名字，周期不变）。
- 2026-11-29 清理 D：去重——`prf.sv` 删参数 `UOP_TYPE_WIDTH` 与本地 `UOP_LOAD`，改用 `dis_pkg::UOP_LOAD`（数值 3 不变；`back_top` 从未覆盖该参数）；`prf_awake` / `prf_wb_pipe` 删本地 `rob_younger`，改用同体的 `ttg_util_pkg::ttg_rob_younger`（周期不变）。
- 2026-11-28 清理：删 `FP_EN`（`prf.sv` 的 `g_fp` 生成块展开、`g_no_fp` 删除；`FW = FLEN`）、`HAS_LSU_BYP`（`prf_bypass` 参数及 `g_no_lsu_byp`，旁路写死开）、`FP_WB_PORTS == 0` 分支；删输出 `ftq_prf_pc_req_req_valid`（FTQ 不读，其响应 valid 也已删）及 `prf_pc_port` 实例，`prf_pc_port.sv` 成死文件；删不抑制任何告警的 lint 豁免（`prf.sv` 3 处，以去掉豁免后整树 lint 普通 / `-DSYNTHESIS` 均无新告警为准）（周期不变）。
- 2026-11-28（文档核对，无 RTL 变化）：`FTQ_PRF_PC_PORT_NUM = 4`（口 0、2、14、15）；`PRF_NUM = 256` 下的寄存器堆与位宽；接口改为 `iss2prf_* / exe2prf / prf2exe_*` 结构体端口，误预测按 ROB 号；旁路改为 EXU 独热 + 写回级 / LSU 编号比较，`lsu_byp` 总是开；删掉已不存在的 AGU 读口借用；文件表行数；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/exu-clean`，EXP-072）：随真 5 物理 AGU 与 `ISSUE_WIDTH = 21 → 19` 收敛，`prf` 删除原逻辑 AGU 共用口读借用分支，口数与旁路按 `ISSUE_WIDTH = 19` 直接映射；TSMC 28nm HPC+ DC（`0.50 ns`）新旧同条件对比：基线 vs 新版 **`WNS` 均 `0.00 ns`（MET ≥2.00 GHz）**、`CPL 0.45 ns`、`TNS −0.00`、`Seq 24,196` 持平、面积 `580,853.60 → 587,386.28 µm²`（`+1.12%`）。

- 2026-11-23（`rtl/ld-wake`，EXP-060）：`prf_bypass.sv` 新增 `HAS_LSU_BYP` 参数与 4 路 `lsu_byp` 旁路（`ttg_onehot_mux`），`prf.sv` 将 `lsu_byp_{valid,dest_preg,result}` 接入整数读口旁路（FP 侧此前已接通），支持 L2 推测唤醒消费者在 L3 写回同拍直接旁路取值；`eda-08` Yosys：`prf` **25 层**（0 增长）/ 639,644 单元（+4.1%）；`fm_gate` 69/69 PASS 0 周期差，Linux 26 窗 100% 全等。
- 2026-11-21（`rtl/be-wake-byp-opt`，后端阶段一瘦身）：整数读口按发射口需求由 42 减至 27 个（`prf_regfile` 改为平铺 `NRD` 口，裁掉 LD/STA `src2`、共用 STA `src1` 及 FP 口整数读口）；FU 旁路源按数据域裁剪（整数 35→14 路，浮点 35→8 路，`lsu_byp` 随 `LP_L2[3]` 编译期门控）；零周期变化。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`prf.sv` 透传 4 位 `iss2prf_iss_entry_uop_ftq_offset` → `prf2exe_iss_entry_uop_ftq_offset` 至 EXU；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗对齐。
- 2026-11-19（`exp/wb-presel`，EXP-046）：写回总线按通道编号（`WB_LANES = 13`），不再按发射口（21）：STA / STD / BR 口的空通道去掉，整数寄存器堆 21 → 13 个写口，写回级、写回旁路、load 唤醒同步；`prf_bypass` 的参数改名 `WBL`（避开包里的 `WB_LANES`）。周期不变。
- 2026-11-19（`exp/wb-presel`，EXP-046）：浮点寄存器堆的写通道 21 → 6（4 条 load + 浮点单元写回压缩成 `FP_WB_PORTS` 条，靠发射级的 FP 写口预约保证不超）；浮点结果的写回暂存移到 `prf.sv`，只暂存会写浮点寄存器的 9 个口。周期不变。

- 2026-11-17/18（exp/agu-share，`261bd67..HEAD`）：`41e5893` 共用 AGU 的 STA 口借用 load 口的 `src1` 读口（EXP-TLBPORTS 第 2 步）；`803692f` 全局 flush 晚一拍到达（本模块自身没改，见 docs/FLUSH_REG.md）。
- 2026-11-12：rv64（寄存器、pc、旁路结果 `XLEN_BITS` 位）；F/D（浮点寄存器堆 `prf_fp`、浮点读口、`lsu_byp` 的 NaN-boxing）。
- 更早：见 git 历史。
