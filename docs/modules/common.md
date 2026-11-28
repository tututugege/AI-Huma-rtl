---
module: common
area: core
rtl: rtl/common（ttg_cfg_pkg.sv、fp_pkg.sv、ttg_first_set.sv、ttg_onehot_mux.sv、ttg_onehot_to_idx.sv、ttg_popcount.sv、ttg_pick_k.sv；sram/ttg_sram_pkg.sv、ttg_sram_1rw.sv、ttg_sram_1r1w.sv、ttg_rst_sweep.sv）
model: 配置包对应 trace-model include/config.h（经 harness/tools/gen_cfg_pkg.py 取值）；fp_pkg 的 FP 延迟取自同一份 config.h；五个组合原语和 SRAM 包装是 RTL 独有，模型里没有对应
status: 原语有穷举测试（make prims）和综合 / 仿真两种写法的等价测试（tests/common_prims/run.sh）；配置包与 config.h 不是机器同步的（见第 2 节）；整核 fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt
depth: 待测（第 6 节只有从代码读出的估计）
---

# common 设计文档

## 1. 职责

整个 RTL 共用的东西（除 4.1 节的 SRAM 包装外都没有时钟、没有状态）：

1. `ttg_cfg_pkg`：核的全部尺寸 / 宽度常量（`localparam`），`rtl/` 下 221 个文件引用它（2026-11-28 `grep` 统计）；
2. `fp_pkg`：F / D 扩展共用的小常量和函数（FP 数据宽度、`flw` 的 NaN 装箱、`fdiv / fsqrt` 的延迟查表），11 个文件引用；
3. 五个组合逻辑原语：`ttg_first_set`（找最低位的 1）、`ttg_onehot_mux`（独热选择的 AND-OR 多路选择）、`ttg_onehot_to_idx`（独热转下标）、`ttg_popcount`（数 1 的个数）、`ttg_pick_k`（并行找最低的 K 个 1），分别被 39 / 46 / 26 / 21 / 9 个其他文件使用（2026-11-28 `grep -w` 统计，不含自身）；
4. SRAM 包装 `ttg_sram_1rw` / `ttg_sram_1r1w` 和复位展宽 `ttg_rst_sweep`（4.1 节）。

## 2. 配置：`ttg_cfg_pkg` 与模型 `config.h` 的关系

设计意图（文件头和 `Makefile`）：C++ 的 `config.h` 是所有尺寸的唯一来源，`make cfg`（= `scripts/gen_cfg.sh`）调用 `harness/tools/gen_cfg_pkg.py`，它生成一个临时 C++ 程序，包含 `config.h` 后把每个整型 `constexpr` 常量算出来打印，再写成 `ttg_cfg_pkg.sv`；这样 `clog2()`、表达式和宏都由编译器解决。`gen_cfg.sh` 默认用 `-DXLEN=64 -DRVC=1 -DFP=1`，模型目录取 `$SIM_SRC`（默认 `$AI_HUMA_ROOT/trace-model`），额外的 `-D` 会追加并覆盖。生成器还会加三类东西：

- 固定在 RTL 里的设计常量 `FIXED`：`LSU_MDP_BITS = 6`、`LSU_MDP_CLR = 2000`（模型 `config.h` 里即使有同名常量也不导出）；
- 前端 FIFO 深度（`frontend_feature_config.h` 里的 `#define`）：现在只有 `INSTRUCTION_FIFO_SIZE`（原来的取指地址队列、PTAB、front2back 队列已并入统一 FTQ，模型不再定义它们的深度；生成器的匹配式里还留着这几个名字，匹配不到就不输出）；
- 扫描看不到的几个：`FP_MISC_LAT`、`FP_I2F_LAT`、`FP_FDIV_D_LAT`、`FP_FSQRT_D_LAT`，以及 `FP_IQ_SIZE`、`FP_IQ_ENQ_WIDTH`（取自 `CFG_FP_IQ_*`）。

文件末尾还有两个由 `XLEN_BITS` 推出的常量：`DST_STRB_W`、`DST_L2_W`（store 请求的字节使能和第二数据字的位宽）。

**现状与生成结果不一致（本次对照的结果）**：文件头还写着"Generated … do not edit"，但检入的文件已经手工改过。本次用 `trace-model-tlbports` 的 `config.h` 实际跑了一遍生成器（输出写到临时目录，没有动检入文件）：

- 用 `gen_cfg.sh` 的默认 `-D` 生成：173 个常量，与检入文件相比有 5 个值不同——`LSU_AGU_SHARED`（0 对 2）、`LSU_AGU_PHYS`（7 对 5）、`IQ_INT_ENQ_WIDTH`（7 对 4）、`IQ_MEM_ENQ_WIDTH`（8 对 6）、`IQ_INT_SIZE`（64 对 32）。这是因为现行 RTL 配置不是模型的默认配置；
- 再加 `-DCFG_AGU_SHARED=2 -DCFG_INT_IQ_SIZE=32 -DCFG_INT_IQ_ENQ_WIDTH=4 -DCFG_MEM_IQ_ENQ_WIDTH=6`，生成的值与检入文件逐个相同；
- 检入文件里有 7 个生成器不会输出的、没有人用的常量（2026-11-18 之前还有 3 个手工加的：`INT_CLUSTERS`、`MEM_AGE`、`IQ_SAME_CYCLE_REUSE`，现在 RTL 只有一种取值，已经删掉）：（`VIRTUAL_MEMORY_LENGTH`、`DCACHE_WORDS_PER_BANK`、`DCACHE_MISS_NUM`、`LDQ_WAIT_MMU_UPPER_BOUND`、`STQ_WIAT_MMU_UPPER_BOUND`、`STQ_MMU_DONE_UPPER_BOUND`、`UART_ADDR_MASK`）是模型里已经没有的旧常量，RTL 里也没有任何文件用它们；
- 文件里的顺序与生成器的输出也不同（例如 `XLEN_BITS` 等生成器放在最后）。

所以：数值上，检入文件 = "模型 + 上面那组 `-D`" 再加上几个手工常量；但没有机器同步，`make cfg` 会改掉手工加的内容并回到模型默认值，不能直接用。待办（`isu.md` 第 9 节也提到）：把现行配置固化成生成器的输入（一个固定的 `-D` 列表），删掉 7 个无用常量。

参考周期：`scripts/ref_cycles.txt` 由模型的默认配置生成（`scripts/regen_refs.sh`，a8ceec2），模型默认配置就是 RTL 配置，不需要额外的环境变量。

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
| `ttg_pick_k` | `N`、`K` | `req[N]` → `pick_oh[K][N]`、`valid[K]` | 第 1..K 个最低置位的独热；不足 k+1 个置位时 `pick_oh[k] = 0`、`valid[k] = 0` |

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ttg_cfg_pkg.sv` | 194 | 配置常量包 |
| `fp_pkg.sv` | 31 | F / D 共用常量与函数 |
| `ttg_first_set.sv` | 35 | 找最低位的 1（综合走 Kogge-Stone 前缀 OR，仿真走快速写法） |
| `ttg_onehot_mux.sv` | 43 | 独热 AND-OR 多路选择（综合 / 仿真两种写法） |
| `ttg_onehot_to_idx.sv` | 20 | 独热转下标 |
| `ttg_popcount.sv` | 42 | 数 1 的个数（综合走逐层收窄的加法树，仿真走循环累加） |
| `ttg_pick_k.sv` | 78 | 并行找最低的 K 个 1（温度计码前缀和，综合 / 仿真两种写法） |
| `sram/ttg_sram_pkg.sv` | 12 | `SRAM_SWEEP_CYCLES = 4100` |
| `sram/ttg_sram_1rw.sv` | 358 | 单口同步 SRAM 包装（复位清零、`SYNTH_TSMC28_SRAM` 宏映射） |
| `sram/ttg_sram_1r1w.sv` | 177 | 伪双口同步 SRAM 包装（`WRITE_FIRST` 可选、复位清零） |
| `sram/ttg_rst_sweep.sv` | 29 | 复位展宽：外部复位释放后再保持 `SRAM_SWEEP_CYCLES` 拍，输出 `init_done` |

### 4.1 SRAM 原语与复位清零（`rtl/common/sram`，2026-11-28）

`ttg_sram_1rw`（单口）/ `ttg_sram_1r1w`（伪双口，`WRITE_FIRST` 可选）是全芯片 SRAM 的唯一封装；阵列本身没有复位。以前阵列的初值来自 `` `ifndef SYNTHESIS `` 里的 `initial`：普通仿真是 `INIT_VAL`，`-DSYNTHESIS` 仿真由 Verilator 置 0（或 `--x-initial unique` 随机），真实芯片是随机上电值，三者不一致。设计依赖初值的地方（LLC 的 `valid / dirty / pf / repl`、BPU / ITT 表、DCache tag 等）在芯片上会出错，例如 LLC 随机上电产生假命中和把脏行乱写回 DDR。

做法（端口加 `rst_n`，参数加 `INIT_SWEEP`，默认 1）：

- `rst_n` 为低时，包装把 `INIT_VAL` 写到 `mem[sw_q]`，`sw_q` 每拍加 1、到 `DEPTH-1` 后回 0。`sw_q` **故意不复位**：上电时是任意值，只要复位持续 `DEPTH + 1` 拍，每个地址都至少被写一次（起点超出范围时第一拍回 0）。清零期间写口被占用，1R1W 的读使能被压住；包装外的逻辑都在复位里，不访问 SRAM。
- 删除了 `initial`：仿真、综合和芯片从同一个状态开始。
- `ttg_sram_pkg::SRAM_SWEEP_CYCLES = 4100`（最深的清零表是 LLC 的 4096 组）。每个 `INIT_SWEEP=1` 的包装在展开时检查 `DEPTH + 1 <= SRAM_SWEEP_CYCLES`，不满足就 `$error`。
- `ttg_rst_sweep`：复位展宽，外部复位释放后再保持 `SRAM_SWEEP_CYCLES` 拍，输出 `rst_n_o` 和 `init_done`。`soc_top`（`core_tb` 的顶层）用它给 `core_top` / `mem_top` 产生复位，并导出 `init_done`；`chip_top` 的 `soc_crg` 用它展宽 `sys_rst_n`（DFT 测试模式下旁路）。
- `soc_sram`（软件可见的 64 KiB 片上 RAM，测试台会预装内容）设 `INIT_SWEEP = 0`。
- 测试台 `tb/core/core_tb.cpp`：外部复位 3 拍后一直跑到 `init_done`，这些拍不计入周期，DDR / 外设模型和各种监视从 `init_done` 之后的第一拍开始，所以和模型比的周期不变。`SOC_TB_RAND_INIT=<seed>`（需要 `SOC_XINIT_UNIQUE=1` 编的测试台）给所有没有复位的寄存器和存储随机上电值。

`ttg_first_set` 的写法：`pre[0] = req`，`pre[s+1] = pre[s] | (pre[s] << 2^s)`，共 `⌈log2 N⌉` 级，`onehot = req & ~(pre[最后一级] << 1)`。头注释说明理由：`req & -req` 功能相同，但是一条 N 位的进位链，N 层门深。`ttg_onehot_to_idx` 是单个 `always_comb` 的循环；`ttg_first_set`、`ttg_onehot_mux`、`ttg_popcount`、`ttg_pick_k` 各有 `` `ifdef SYNTHESIS `` 的树形写法和仿真用的快速写法，二者由 `tests/common_prims/run.sh` 做随机等价检查。

## 5. 一拍内的数据流

纯组合，没有状态。使用方式：`ttg_first_set` 用在选择和仲裁（发射选择、分配、轮询仲裁、LLC 的命中路选择等）；`ttg_onehot_to_idx` 把 `first_set` 的独热结果转成下标；`ttg_onehot_mux` 按 `first_set` 的结果取数据；`ttg_popcount` 用在计数（例如 `pmu_ev_core` 的退休数、分派槽数）。

## 6. 关键路径与深度

depth 待测。从代码读出的、未综合验证的情形：

- `ttg_first_set`：`⌈log2 N⌉` 级 OR 加最后的一个 AND，深度随 N 对数增长；
- `ttg_onehot_to_idx`：每个下标位是 N 项里一部分的 OR（OR 树），对数深度；
- `ttg_onehot_mux`：每个输出位是 N 个 AND 的 OR，对数深度；
- `ttg_popcount`：综合时是递归的二叉加法树，每个内部节点只用 `min($clog2(子树大小+1), CW)` 位（对数深度）；仿真时是 `for` 循环顺序累加（只为仿真快，不进综合）；
- `ttg_pick_k`：温度计码饱和前缀和，`⌈log2 N⌉` 级，没有进位链。

## 7. 与模型的差异和取舍

- 五个原语在模型里没有对应物；模型里的同类操作（"取最低的就绪槽"、"数有多少个"）是 C++ 循环。RTL 把 `ttg_first_set` 写成前缀 OR 是为了降逻辑深度（见 `isu.md` 第 6 节的深度改动表）。
- 配置包：RTL 现行配置与模型默认配置不同（第 2 节），参考周期由"同配置的模型"生成。
- `fp_pkg.sv` 头注释里"rv32: only flw exists"一类说法已过时：rv32 已不在主线，`fp_load_data` 在 `XLEN_BITS = 64` 下的行为是上面写的。只记录，没有改。

未核对（继承自旧文档）：旧体系里对这些原语的"锁步"和"变异"结果（`spec/` 已退役）。

## 8. 验证

- **原语的穷举测试**：`make prims`（`Makefile`：Verilator 编 `rtl/common/ttg_*.sv` + `tests/common/prims_tb.sv`，运行 `build/prims/Vprims_tb`，期望输出 `PRIMS PASS`）。它对 `N = 6` 的全部 2^6 种输入检查 `ttg_first_set`、`ttg_onehot_to_idx`、`ttg_popcount`（`CW = 4`）、`ttg_onehot_mux`（`W = 8`）与参考算法一致；`N` 只测了 6，其他 N（特别是大的 N，如 16、32、64）没有覆盖。本次没有运行它。
- **综合 / 仿真两种写法的等价测试**：`tests/common_prims/run.sh [工作目录]`：`ttg_first_set`、`ttg_onehot_mux`、`ttg_popcount`、`ttg_pick_k` 的 `SYNTHESIS` 树形写法与仿真写法在 10 万组随机向量上逐位相同（`N = 64`、`K = 6`、`W = 32`）。
- **整核门禁**：`scripts/fm_gate.sh` 77/77，周期对 `scripts/ref_cycles.txt`；`scripts/lint_chip.sh`（原语和配置包都在整芯片 lint 范围内；`PR=$(find rtl/common -name 'ttg_*.sv' ...)` 单独列入）。
- **SRAM 复位清零（4.1 节）**：`SOC_XINIT_UNIQUE=1 CORE_VOPT=-DSYNTHESIS` 编的 `core_tb`，`SOC_TB_RAND_INIT=7 / 11 / 12345` 下 `fm_gate.sh` 都是 77/77、周期与 `ref_cycles.txt` 0 处不同（2026-11-28，fe-2ahead）。改之前同样配置下 coremark 随种子变成 289,640 / 296,512 拍（全 0 初值 285,752）。
- **配置包**：没有自动检查它与 `config.h` 的一致性。**待补**：一个脚本，用固定的 `-D` 列表跑生成器并与检入文件比较（见第 2 节的待办）。
- `fp_pkg`：没有独立测试；`tests/fp_gate`、`tests/fp_decode`、`tests/fp_chain` 等 FP 测试经过 FP 单元间接使用它，本次没有核对它们各自测什么。

## 9. 参数与开关速查

生成器参数：`gen_cfg.sh` 的 `-DXLEN=64 -DRVC=1 -DFP=1` 以及追加的 `-D<macro>=<val>`；`SIM_SRC`（模型目录）；`lint_chip.sh` 的 `CFG`。模型侧 `config.h` 的 `CFG_*` 宏（`CFG_AGU_SHARED`、`CFG_INT_CLUSTERS`、`CFG_INT_IQ_SIZE`、`CFG_INT_IQ_ENQ_WIDTH`、`CFG_MEM_IQ_SIZE`、`CFG_MEM_IQ_ENQ_WIDTH`、`CFG_FPRF_NUM`、`CFG_FP_IQ_SIZE`、`CFG_PRF_NUM`、`CFG_ROB_NUM` 等）。

## 10. 变更记录

- 2026-11-28（`rtl/fe-2ahead`，文档核对）：补 `ttg_pick_k` 和 `sram/` 的文件行、各原语的综合 / 仿真两种写法与 `tests/common_prims`；配置包一节去掉已删除的前端 FIFO 深度和 `FE_RFAST`；门禁改为 77/77 对 `scripts/ref_cycles.txt`。
- 2026-11-28（`rtl/fe-2ahead`）：SRAM 复位清零（4.1 节）：包装加 `rst_n` / `INIT_SWEEP`，删除 `initial`；新增 `ttg_sram_pkg`、`ttg_rst_sweep`；`soc_top` / `soc_crg` 复位展宽 `SRAM_SWEEP_CYCLES` 拍。
- `261bd67..HEAD` 里 `rtl/common` 的改动（均为配置包）：`b9ae0d5`（共享 AGU：`LSU_AGU_SHARED`、`LSU_AGU_PHYS`）、`237738c` / `120701a`（合并的内存发射队列、6 条入队 lane、`MEM_AGE`）、`0e82d3f`（`IQ_SAME_CYCLE_REUSE`）、`6d7ed85`（两个 INT 队列：`INT_CLUSTERS`、`IQ_INT_SIZE`、`IQ_INT_ENQ_WIDTH`）、`2e6acb6`（去掉 `MEM_MERGE`、`IQ_LD_*`、`IQ_STA_*`）；另有 `1db84c7` 及其回退 `ad24170`。
- 更早：见 git 历史。
- 2026-11-28（`rtl/iss-rr`，0 周期变化）：`ttg_popcount` 综合树改用逐层收窄位宽加法器（第 `d` 层仅取 `min(d+1, CW)` 比特做 `min(d+2, CW)` 比特加法，消除叶层全宽 `CW` 进位链；`tests/common_prims` 与仿真路径保持逐位等价）。
- 2026-11-28（`exp/wbp-v2`）：彻底移除 `` `ifdef SRAM_BLACKBOX `` / `syn_black_box` 分支，所有综合统一走 `` `ifdef SYNTH_TSMC28_SRAM `` 真实 TSMC 28nm HS LVT SRAM 宏映射（含新增 `1024x32` 与通用 `512x72` bank/bit tiling）。
- 2026-11-26（`rtl/area-opt`）：新增 `rtl/common/sram/` 独立 SRAM 原语层：`ttg_sram_1rw.sv`（单口同步 1RW）与 `ttg_sram_1r1w.sv`（伪双口同步 1R1W，支持 `WRITE_FIRST` 与仿真初始化 `INIT_VAL`），彻底删除组合异步读封装 `ttg_sram_rf.sv`；两者均内置 `` `ifdef SRAM_BLACKBOX `` 宏分支供 Synopsys DC 黑盒与工艺宏映射（全芯片 `lint_chip.sh` 与 `-DSRAM_BLACKBOX` lint 均为 0 告警）；全芯片大存储已统一收口为严格 1 拍同步 SRAM：LLC（4 MiB+）、L1 D-Cache（64 KiB Data + Tag）、Bingo PHT（25.6 KiB）、L2 TLB STLB（9.5 KiB）、L1 I-Cache Data（32 KiB，4-bank 预发起）、ROB 非法指令字表（8×32×32b = 1 KiB）与 BPU 全部大表（~590 KiB，含 Main FTB / 1-Ahead A / 2-Ahead B / S2 8-table TAGE / S2 SC / S2 ITT / 2-bank `ftb_rec` / 2-bank `rf_rec`，经 `bpu_sram_sync` 统一封装）。
- 2026-11-18：删除只剩一种取值的常量：`INT_CLUSTERS`（2）、`MEM_AGE`（1）、`IQ_SAME_CYCLE_REUSE`（0）、`LSU_WAIT_MSHR_FILL`（1）、`LP_STAEV_REG`（1，在 `lp_pkg`），用到它们的地方直接写成唯一取值。
