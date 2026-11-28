---
module: common
area: core
rtl: rtl/common（ttg_cfg_pkg.sv、fp_pkg.sv、ttg_first_set.sv、ttg_onehot_mux.sv、ttg_onehot_to_idx.sv、ttg_popcount.sv）
model: 配置包对应 trace-model include/config.h（经 harness/tools/gen_cfg_pkg.py 取值）；fp_pkg 的 FP 延迟取自同一份 config.h；四个小原语是 RTL 独有，模型里没有对应
status: 原语有穷举测试（make prims）；配置包与 config.h 不是机器同步的（见第 2 节），整核周期与模型逐个相等（最近一次提交 60ed422 的提交信息记 fm_gate 67/67、周期等于 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；本次写文档没有重跑）
depth: 待测（由协调者补）
---

# common 设计文档

## 1. 职责

整个 RTL 共用的东西，没有时钟、没有状态：

1. `ttg_cfg_pkg`：核的全部尺寸 / 宽度 / 开关常量（`localparam`），整个 RTL 里 227 个文件引用它；
2. `fp_pkg`：F / D 扩展共用的小常量和函数（FP 数据宽度、`flw` 的 NaN 装箱、`fdiv / fsqrt` 的延迟查表），11 个文件引用；
3. 四个组合逻辑原语：`ttg_first_set`（找最低位的 1）、`ttg_onehot_mux`（独热选择的 AND-OR 多路选择）、`ttg_onehot_to_idx`（独热转下标）、`ttg_popcount`（数 1 的个数），分别被 37 / 40 / 18 / 25 个其他文件使用（`grep` 统计，不含 `rtl/common` 自己）。

## 2. 配置：`ttg_cfg_pkg` 与模型 `config.h` 的关系

设计意图（文件头和 `Makefile`）：C++ 的 `config.h` 是所有尺寸的唯一来源，`make cfg`（= `scripts/gen_cfg.sh`）调用 `harness/tools/gen_cfg_pkg.py`，它生成一个临时 C++ 程序，包含 `config.h` 后把每个整型 `constexpr` 常量算出来打印，再写成 `ttg_cfg_pkg.sv`；这样 `clog2()`、表达式和宏都由编译器解决。`gen_cfg.sh` 默认用 `-DXLEN=64 -DRVC=1 -DFP=1`，模型目录取 `$SIM_SRC`（默认 `$AI_HUMA_ROOT/trace-model`），额外的 `-D` 会追加并覆盖。生成器还会加三类东西：

- 固定在 RTL 里的设计常量 `FIXED`：`LSU_MDP_BITS = 6`、`LSU_MDP_CLR = 2000`、`FE_RFAST = 15`（模型 `config.h` 里即使有同名常量也不导出）；
- 前端 FIFO 深度（`frontend_feature_config.h` 里的 `#define`）：`PTAB_SIZE`、`INSTRUCTION_FIFO_SIZE`、`FETCH_ADDR_FIFO_SIZE`、`FRONT2BACK_FIFO_SIZE`；
- 扫描看不到的几个：`FP_MISC_LAT`、`FP_I2F_LAT`、`FP_FDIV_D_LAT`、`FP_FSQRT_D_LAT`，以及 `FP_IQ_SIZE`、`FP_IQ_ENQ_WIDTH`（取自 `CFG_FP_IQ_*`）。

文件末尾还有两个由 `XLEN_BITS` 推出的常量：`DST_STRB_W`、`DST_L2_W`（store 请求的字节使能和第二数据字的位宽）。

**现状与生成结果不一致（本次对照的结果）**：文件头还写着"Generated … do not edit"，但检入的文件已经手工改过。本次用 `trace-model-tlbports` 的 `config.h` 实际跑了一遍生成器（输出写到临时目录，没有动检入文件）：

- 用 `gen_cfg.sh` 的默认 `-D` 生成：173 个常量，与检入文件相比有 5 个值不同——`LSU_AGU_SHARED`（0 对 2）、`LSU_AGU_PHYS`（7 对 5）、`IQ_INT_ENQ_WIDTH`（7 对 4）、`IQ_MEM_ENQ_WIDTH`（8 对 6）、`IQ_INT_SIZE`（64 对 32）。这是因为现行 RTL 配置不是模型的默认配置；
- 再加 `-DCFG_AGU_SHARED=2 -DCFG_INT_IQ_SIZE=32 -DCFG_INT_IQ_ENQ_WIDTH=4 -DCFG_MEM_IQ_ENQ_WIDTH=6`，生成的值与检入文件逐个相同；
- 检入文件里有 7 个生成器不会输出的、没有人用的常量（2026-11-18 之前还有 3 个手工加的：`INT_CLUSTERS`、`MEM_AGE`、`IQ_SAME_CYCLE_REUSE`，现在 RTL 只有一种取值，已经删掉）：（`VIRTUAL_MEMORY_LENGTH`、`DCACHE_WORDS_PER_BANK`、`DCACHE_MISS_NUM`、`LDQ_WAIT_MMU_UPPER_BOUND`、`STQ_WIAT_MMU_UPPER_BOUND`、`STQ_MMU_DONE_UPPER_BOUND`、`UART_ADDR_MASK`）是模型里已经没有的旧常量，RTL 里也没有任何文件用它们；
- 文件里的顺序与生成器的输出也不同（例如 `XLEN_BITS` 等生成器放在最后）。

所以：数值上，检入文件 = "模型 + 上面那组 `-D`" 再加上几个手工常量；但没有机器同步，`make cfg` 会改掉手工加的内容并回到模型默认值，不能直接用。待办（`isu.md` 第 9 节也提到）：把现行配置固化成生成器的输入（一个固定的 `-D` 列表），删掉 7 个无用常量。

参考周期也依赖同一组开关：`scripts/ref_cycles_memiq6_nr_int2_ev5.txt` 由模型在"与 RTL 同配置"下生成（上面的 `CFG_*`，加上 `CFG_ISSUE_OLDEST_FIRST/QUEUES`、`CFG_IQ_SAME_CYCLE_REUSE`、`CFG_FE_OVR_REG` 等不进配置包的开关）。完整的开关列表本次没有逐个核对。

`lint_chip.sh` 支持用环境变量 `CFG=<pkg.sv>` 换一个配置包做整芯片 lint。

## 3. 接口

- `ttg_cfg_pkg`：只有 `localparam`（`int`，少数 `longint unsigned`：`RAM_SIZE`、`MAX_SIM_TIME`、`UART_ADDR_MASK`、`SIM_CACHE_ADDR_2_MIN`）。常量的分组（按文件里的出现顺序）：核宽度（`XLEN_BITS`、取指 / 译码 / 提交宽度）、ICache / DCache 几何、寄存器堆（`PRF_NUM`、`FPRF_NUM`、`TAG_NUM`）、ROB / 队列大小、功能单元掩码（`OP_MASK_*`）和延迟、发射口与发射队列（`ISSUE_WIDTH`、`IQ_*`……）、LSU、TLB、各种位宽（`*_IDX_WIDTH`）、MMIO 地址（`UART_*`、`TIMER_*`、`XPS_INTC_*`……）、前端 FIFO 深度、FP 延迟。数值见文件；其他模块文档引用具体常量时写常量名。
- `fp_pkg`：`FP_EN`（`FPRF_NUM != 0`）、`FLEN`（64）、`FW`（FP 数据总线位宽：有 F/D 时 `FLEN`，否则 1）、`FFLAGS_W`（5）、函数 `fp_load_data(d, is_w)`（`is_w` 时返回 `{32'hFFFF_FFFF, d[31:0]}`，即 NaN 装箱，否则整个字）、`FP_LAT_MAX`、`FP_LAT_W`、函数 `fp_div_latency(func7)`（`func7[0]` 是 D 格式、`func7[6:2] == 5'h0b` 是 `fsqrt`，返回 `FP_FDIV_S_LAT / FP_FSQRT_S_LAT / FP_FDIV_D_LAT / FP_FSQRT_D_LAT`）。
- 原语端口：

| 模块 | 参数 | 端口 | 行为 |
| --- | --- | --- | --- |
| `ttg_first_set` | `N` | `req[N]` → `onehot[N]`、`any` | 最低位的 1 的独热；无请求时全 0 |
| `ttg_onehot_mux` | `N`、`W` | `sel[N]`、`data[N][W]` → `out[W]` | AND-OR；`sel` 全 0 时输出 0；`sel` 多位有效时输出 OR |
| `ttg_onehot_to_idx` | `N`、`IDXW` | `onehot[N]` → `idx[IDXW]` | 各置位项的下标按位 OR；全 0 时输出 0 |
| `ttg_popcount` | `N`、`CW` | `bits[N]` → `count[CW]` | 置位个数，`CW` 默认 `$clog2(N+1)` |

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ttg_cfg_pkg.sv` | 192 | 配置常量包 |
| `fp_pkg.sv` | 31 | F / D 共用常量与函数 |
| `ttg_first_set.sv` | 27 | 找最低位的 1（Kogge-Stone 前缀 OR） |
| `ttg_onehot_mux.sv` | 20 | 独热 AND-OR 多路选择 |
| `ttg_onehot_to_idx.sv` | 20 | 独热转下标 |
| `ttg_popcount.sv` | 19 | 数 1 的个数 |

`ttg_first_set` 的写法：`pre[0] = req`，`pre[s+1] = pre[s] | (pre[s] << 2^s)`，共 `⌈log2 N⌉` 级，`onehot = req & ~(pre[最后一级] << 1)`。头注释说明理由：`req & -req` 功能相同，但是一条 N 位的进位链，N 层门深。其他三个都是单个 `always_comb` 的循环。

## 5. 一拍内的数据流

纯组合，没有状态。使用方式：`ttg_first_set` 用在选择和仲裁（发射选择、分配、轮询仲裁、LLC 的命中路选择等）；`ttg_onehot_to_idx` 把 `first_set` 的独热结果转成下标；`ttg_onehot_mux` 按 `first_set` 的结果取数据；`ttg_popcount` 用在计数（例如 `pmu_ev_core` 的退休数、分派槽数）。

## 6. 关键路径与深度

depth 待测（由协调者补）。从代码读出的、未综合验证的情形：

- `ttg_first_set`：`⌈log2 N⌉` 级 OR 加最后的一个 AND，深度随 N 对数增长；
- `ttg_onehot_to_idx`：每个下标位是 N 项里一部分的 OR（OR 树），对数深度；
- `ttg_onehot_mux`：每个输出位是 N 个 AND 的 OR，对数深度；
- `ttg_popcount`：写成 `for` 循环里的顺序累加（`count = count + bits[i]`）。写法上是 N-1 个加法器串起来，实际深度取决于综合器是否重排成平衡的树；用在宽度 8 的提交槽上影响不大，但 N 大时需要留意。

## 7. 与模型的差异和取舍

- 四个原语在模型里没有对应物；模型里的同类操作（"取最低的就绪槽"、"数有多少个"）是 C++ 循环。RTL 把 `ttg_first_set` 写成前缀 OR 是为了降逻辑深度（见 `isu.md` 第 6 节的深度改动表）。
- 配置包：RTL 现行配置与模型默认配置不同（第 2 节），参考周期由"同配置的模型"生成。
- `fp_pkg.sv` 头注释里"rv32: only flw exists"一类说法已过时：rv32 已不在主线，`fp_load_data` 在 `XLEN_BITS = 64` 下的行为是上面写的。只记录，没有改。

未核对（继承自旧文档）：旧体系里对这些原语的"锁步"和"变异"结果（`spec/` 已退役）。

## 8. 验证

- **原语的穷举测试**：`make prims`（`Makefile`：Verilator 编 `rtl/common/ttg_*.sv` + `tests/common/prims_tb.sv`，运行 `build/prims/Vprims_tb`，期望输出 `PRIMS PASS`）。它对 `N = 6` 的全部 2^6 种输入检查 `ttg_first_set`、`ttg_onehot_to_idx`、`ttg_popcount`（`CW = 4`）、`ttg_onehot_mux`（`W = 8`）与参考算法一致；`N` 只测了 6，其他 N（特别是大的 N，如 16、32、64）没有覆盖。本次没有运行它。
- **整核门禁**：`scripts/fm_gate.sh` 67 个程序，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`；`scripts/lint_chip.sh`（原语和配置包都在整芯片 lint 范围内；`PR=$(find rtl/common -name 'ttg_*.sv' ...)` 单独列入）。
- **配置包**：没有自动检查它与 `config.h` 的一致性。**待补**：一个脚本，用固定的 `-D` 列表跑生成器并与检入文件比较（见第 2 节的待办）。
- `fp_pkg`：没有独立测试；`tests/fp_gate`、`tests/fp_decode`、`tests/fp_chain` 等 FP 测试经过 FP 单元间接使用它，本次没有核对它们各自测什么。

## 9. 参数与开关速查

生成器参数：`gen_cfg.sh` 的 `-DXLEN=64 -DRVC=1 -DFP=1` 以及追加的 `-D<macro>=<val>`；`SIM_SRC`（模型目录）；`lint_chip.sh` 的 `CFG`。模型侧 `config.h` 的 `CFG_*` 宏（`CFG_AGU_SHARED`、`CFG_INT_CLUSTERS`、`CFG_INT_IQ_SIZE`、`CFG_INT_IQ_ENQ_WIDTH`、`CFG_MEM_IQ_SIZE`、`CFG_MEM_IQ_ENQ_WIDTH`、`CFG_FPRF_NUM`、`CFG_FP_IQ_SIZE`、`CFG_PRF_NUM`、`CFG_ROB_NUM` 等）。

## 10. 变更记录

- `261bd67..HEAD` 里 `rtl/common` 的改动（均为配置包）：`b9ae0d5`（共享 AGU：`LSU_AGU_SHARED`、`LSU_AGU_PHYS`）、`237738c` / `120701a`（合并的内存发射队列、6 条入队 lane、`MEM_AGE`）、`0e82d3f`（`IQ_SAME_CYCLE_REUSE`）、`6d7ed85`（两个 INT 队列：`INT_CLUSTERS`、`IQ_INT_SIZE`、`IQ_INT_ENQ_WIDTH`）、`2e6acb6`（去掉 `MEM_MERGE`、`IQ_LD_*`、`IQ_STA_*`）；另有 `1db84c7` 及其回退 `ad24170`。
- 更早：见 git 历史。
- 2026-11-28（`rtl/iss-rr`，0 周期变化）：`ttg_popcount` 综合树改用逐层收窄位宽加法器（第 `d` 层仅取 `min(d+1, CW)` 比特做 `min(d+2, CW)` 比特加法，消除叶层全宽 `CW` 进位链；`tests/common_prims` 与仿真路径保持逐位等价）。
- 2026-11-28（`exp/wbp-v2`）：彻底移除 `` `ifdef SRAM_BLACKBOX `` / `syn_black_box` 分支，所有综合统一走 `` `ifdef SYNTH_TSMC28_SRAM `` 真实 TSMC 28nm HS LVT SRAM 宏映射（含新增 `1024x32` 与通用 `512x72` bank/bit tiling）。
- 2026-11-26（`rtl/area-opt`）：新增 `rtl/common/sram/` 独立 SRAM 原语层：`ttg_sram_1rw.sv`（单口同步 1RW）与 `ttg_sram_1r1w.sv`（伪双口同步 1R1W，支持 `WRITE_FIRST` 与仿真初始化 `INIT_VAL`），彻底删除组合异步读封装 `ttg_sram_rf.sv`；两者均内置 `` `ifdef SRAM_BLACKBOX `` 宏分支供 Synopsys DC 黑盒与工艺宏映射（全芯片 `lint_chip.sh` 与 `-DSRAM_BLACKBOX` lint 均为 0 告警）；全芯片大存储已统一收口为严格 1 拍同步 SRAM：LLC（4 MiB+）、L1 D-Cache（64 KiB Data + Tag）、Bingo PHT（25.6 KiB）、L2 TLB STLB（9.5 KiB）、L1 I-Cache Data（32 KiB，4-bank 预发起）、ROB 非法指令字表（8×32×32b = 1 KiB）与 BPU 全部大表（~590 KiB，含 Main FTB / 1-Ahead A / 2-Ahead B / S2 8-table TAGE / S2 SC / S2 ITT / 2-bank `ftb_rec` / 2-bank `rf_rec`，经 `bpu_sram_sync` 统一封装）。
- 2026-11-18：删除只剩一种取值的常量：`INT_CLUSTERS`（2）、`MEM_AGE`（1）、`IQ_SAME_CYCLE_REUSE`（0）、`LSU_WAIT_MSHR_FILL`（1）、`LP_STAEV_REG`（1，在 `lp_pkg`），用到它们的地方直接写成唯一取值。
