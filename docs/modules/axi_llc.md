---
module: axi_llc
area: memsys
rtl: rtl/memsys/axi_llc
model: trace-model axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp、include/AXI_LLC.h、include/AXI_LLC_Config.h；行表（数据 / 标签 / 脏 / 有效 / 替换状态）在 MemSubSystem/MemSubsystem.cpp 的 `AxiLlcTableRuntime`（调度单元 `axi`，类 `AxiSubsystem`；见 axi_subsys.md）
status: 整核周期与模型逐个相等（EXP-062：BOP 5 级树+3 路并行预计算 0 周期变化，rv64gc Linux 26/26 窗 PT/UP 逐拍全等）
depth: `axi_llc_bop` **75 层**（EXP-062：Yosys `291→75` 层；**TSMC 28nm DC `ssg0p81v125c` `0.50ns`：`WNS -0.45→-0.18 ns`、`1.05→1.47 GHz`、`51→42 lvl`、面积 `46,209 um²`**）；`axi_llc_bingo` 48 层 / 41,232 cells（见 09-synthesis-report 第 15 节）
---

# axi_llc 设计文档

## 1. 职责

最后一级缓存（LLC）：4 个读主口和 2 个写主口（与 axi_interconnect.md 同一套主口编号）共用的一块统一缓存，写回式。名词先定义：

- **查表**（lookup）：用请求的组号读一次行表（数据 / 标签 / 脏位 / 有效位 / 替换状态），3 个 tick 后拿到一整组 16 路的内容，再判断命中还是缺失。查表引擎同一时刻只处理一个请求（读或写）。
- **MSHR**（miss status holding register，缺失状态寄存器）：记一次在途缺失的表项，共 16 项（`NMSHR`）；它的槽号就是发给内存的读请求的 id。
- **受害行**（victim）：缺失时被换出的行；脏的要先写回内存。
- **替换状态**（SRRIP，EXP-045）：每组 16 路各 2 位的"再访问预测值"（RRPV，re-reference prediction value；0 = 预计很快再用，3 = 预计很久不用），一组 32 位。命中把该路置 0；缺失要换出时选 RRPV 最大的路；新装入的行先把整组"变老"到最大值为 3，再把新行置 2（不是 0：新行只有再被命中才算"常用"，一次性扫过的行会先被换掉）。
- **LLC 预取（BOP + Bingo 4KB，EXP-048 / EXP-058）**：
  - **Best-Offset Prefetcher（`axi_llc_bop`，EXP-048）**：由 L1D 读缺失（`master == 1`）以及对预取行（`pf_q` 置位）的首次 L1D 需求命中触发学习与候选生成。偏移表为 4 KiB 页内 26 个 5-平滑正偏移（1..60），最近请求表 RR 为 256 项直映表（重填时写入），8 项去重候选队列。
  - **Bingo 4KB 空间预取器（`axi_llc_bingo` / `axi_llc_bingo_agt` / `axi_llc_bingo_pht`，EXP-058）**：由相同 L1D 触发事件（携带经 `dcache_mshr → axi_interconnect → axi_llc_lookup` 透传的 12-bit 负载 `pc_hash`）和 LLC 受害行换出事件驱动。包含 32 项 FIFO 过滤表 FT、32 项 31-bit tree-PLRU 累积表 AGT、4 项提交队列 `cmt_q`、1RW SRAM 4 路组相联长表 PHT_L（256×4=1024 项，3-bit tree-PLRU）与短表 PHT_S（128×4=512 项，相对偏移，3-bit tree-PLRU）、密集流过滤（`popcount >= 48` 跳过）、无乘法器周期准确率节流器（256 发窗口、<26 命中即 <10.16% 降为 1/8 试探 `deg=2`）、1 候选/拍桶形移位发射器与 16 项去重队列 `bingo_q`。
  - **双优先级发射**：`bop_q` 严格优先于 `bingo_q`；仅在互连无可见上游请求（`pf_allow`）、查表引擎空闲、空 MSHR > 2（`BOP_RES = 2`）且在途预取 MSHR < 8（`BOP_INF = 8`）时发起预取查表。发往内存时需求缺失严格优先于预取；预取命中或无法分配 MSHR 时静默放弃，预取重填写入缓存并置 `pf_q` 后直接释放 MSHR（不回上游响应）。
- **bypass**：不缓存的请求（外设、ICache 的非缓存取指）。bypass 读可以命中已有的行，缺失时不分配行；bypass 写只在行已缓存时更新它（保持脏位），并总是写穿到内存。

每个 tick 按固定顺序做五步（`axi_llc_core.sv` 文件头）：1 读响应离开；2 写路径（受害行写回、写请求接收、写上下文）；3 解析刚到的查表（命中 / 缺失，写行表、分配 MSHR、产生响应）；4 内存读路径（内存读响应、发内存读、重填）；5 接收新的读请求、发起行表读。每一步只看到前面步骤已经决定的状态。

模型对应：`AXI_LLC` 类（LLC 在 `AxiSubsystem::interconnect` 里面，`CONFIG_AXI_LLC_ENABLE = 1`），行表在 `MemSubsystem` 里（`llc_comb_outputs` / `llc_seq`，`AxiSubsystem::comb_outputs` 先调前者，`seq` 先调后者）。RTL 把行表放进 LLC 模块（`axi_llc_tables`）。

## 2. 配置（`axi_llc_pkg`，现行默认）

| 量 | 值 | 来源 |
| --- | --- | --- |
| 组数 `SETS` | 4096 | 宏 `AXI_LLC_SETS`（默认 4096） |
| 路数 `WAYS` | 16（必须是 2 的幂） | 宏 `AXI_LLC_WAYS` |
| 行大小 | 64 字节 | `line_of` / `set_of` 用地址 `[31:6]` |
| 容量 | 4096 × 16 × 64 = 4 MiB | 与模型 `CONFIG_AXI_LLC_SIZE_BYTES = 4 << 20`、`CONFIG_AXI_LLC_WAYS = 16`（`config.h`）一致 |
| 标签位宽 `TAGW` | 32 − 6 − 12 = 14 | `axi_llc_pkg` |
| MSHR 数 `NMSHR` | 16（支持 8 或 16：槽号放在 4 位 AXI id 里） | 宏 `AXI_LLC_MSHR`（默认 16）；顶层有综合期检查（`axi_llc_core.sv` 的 `g_geometry`）；模型 `CONFIG_AXI_LLC_MSHR_NUM = 16` |
| 替换状态 `RB` | 每组 2 × WAYS = 32 位（16 个 2 位 RRPV，第 w 路在 `[2w+1:2w]`） | `axi_llc_pkg`；模型 `LLC_REPL` 默认 `srrip`（`AXI_LLC.cpp`，行内容放在 8 字节的 `AXI_LLC_REPL_BYTES` 里） |
| 查表延迟 | 3 tick | `axi_llc_tables` 的 3 级读索引流水；模型 `CONFIG_AXI_LLC_LOOKUP_LATENCY = 3` |
| 读响应队列 `RQD` | 16 项 / 读主口，加 1 个响应寄存器（`RQC = 17`） | `axi_llc_pkg` |
| 写请求队列 `WQD` | 2 项 / 写主口 | 同上 |
| 受害行写回队列 `VQD` | 32 项 | 与模型 `AXI_LLC.h` 深度一致（16 MSHR + LLC BOP 下 Linux 启动峰值超过 8，由 8 扩至 32） |
| 受害行持有者表 `NVL` | 1 + VQD + NW + NMSHR = 51 | 同上（写回槽、队列、写上下文、MSHR） |
| BOP 预取参数 | 26 偏移、RR 256 项、候选队列 `BOP_Q = 8`、`ROUNDS = 100`、`SCORE_MAX = 31`、`BAD = 1`、`DEG = 1`、`BOP_RES = 2`、`BOP_INF = 8` | `axi_llc_pkg`、`axi_llc_bop.sv`；模型 `LLC_BOP=1`（`Bop.h`） |
| Bingo 4KB 预取参数 | `BINGO_FT_N = 32`、`BINGO_AGT_N = 32`、`BINGO_PHTL_SETS = 256`、`BINGO_PHTS_SETS = 128`、`BINGO_PHT_WAYS = 4`、`BINGO_CMTQ_N = 4`、`BINGO_Q = 16`、`BINGO_DEG = 16`（节流 `2`）、`BINGO_MAXDENSE = 48`、`BINGO_TWIN = 256`、`BINGO_TMIN = 26` | `axi_llc_pkg`、`axi_llc_bingo*.sv`；模型 `LLC_BINGO=1`（`BingoHw.h`） |
| 主口数 | 读 4、写 2 | `NR`、`NW` |

模型的三个队列是 32 项（`AXI_LLC_READ_RESP_QUEUE_DEPTH`、`AXI_LLC_READ_VICTIM_WB_QUEUE_DEPTH` 等于 `MAX_OUTSTANDING`；写队列 `MAX_WRITE_OUTSTANDING`），RTL 取小，见第 7 节。

## 3. 接口

LLC 的"上游"端口（`up_*`）连互连的 `li_*` / `lo_*`，"内存"端口（`mem_*`）连互连的 `lo_mem_*` / `li_mem_*`：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `up_rd_valid / addr / size / id / bypass / resp_ready [4]`、`up_rd_dcache_pc_hash [11:0]`、`up_wr_valid / addr / data(512) / strb(64) / size / id / bypass / resp_ready [2]` | 互连的台送来的请求（同一时刻最多一个读或写有效）、DCache 读主口 12-bit PC hash 边带与主口响应 ready |
| 入 | `mem_rd_req_ready`、`mem_rd_resp_valid / data / id`、`mem_wr_req_ready`、`mem_wr_resp_valid / resp` | 互连的 DDR 侧 |
| 出 | `up_rd_req_ready [4]`、`up_rd_resp_valid / id / data [4]`、`up_wr_req_ready [2]`、`up_wr_resp_valid / id / resp [2]` | 对主口的 ready 和响应 |
| 出 | `mem_rd_req_valid / addr / size / id`、`mem_wr_req_valid / addr / data / strb / size / id` | 内存侧读写请求（读 id = MSHR 槽号） |
| 出 | `hz_lookup_*`、`hz_rresp_fresh / valid / id [4]`、`hz_mshr_valid / is_write / master / id / line [8]` | 给互连的冲突检查读 |
| 出 | `hz_wctx_valid / line [2]`、`hz_wresp_valid / line [2]` | 写上下文和写响应的行地址；`axi_subsys` 没有用它们（`unused_hz`） |

## 4. 结构

```
 up_rd / up_wr ─► axi_llc_rdacc（读接收）  axi_llc_wsched ─► axi_llc_wport[w]（写队列 → 写上下文 → 写响应）
                         │ launch                │ launch
                         ▼                       ▼
                    axi_llc_lookup（查表引擎，1 个请求）──► axi_llc_tables（行表，3 tick 读延迟）
                         │ 行到达
                         ▼
                    axi_llc_resolve（命中 / 缺失判定）── axi_llc_waypick（选路）、axi_llc_merge（按字节合并写数据）
        ├─► axi_llc_rq[m]（读响应队列）   ├─► axi_llc_mshr（8 项 MSHR，含 axi_llc_mshr_ent）──► mem_rd_req
        └─► axi_llc_victim（受害行写回槽 + 队列）  axi_llc_refill（重填：存受害行、写行表、应答）
                    axi_llc_memwr（内存写请求多路选择）──► mem_wr_req
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `axi_llc_pkg.sv` | 118 | 几何常量、类型 `tw_t`（行表写请求）、地址函数、`is_full_write`、替换状态函数 `rrip_hit` / `rrip_alloc` |
| `axi_llc.sv` | 162 | 顶层：端口（数组）与压缩向量互转，`hz_*` 导出 |
| `axi_llc_core.sv` | 414 | 实例化各单元，连窄接口，行表写源选择，仿真断言 |
| `axi_llc_tables.sv` | 146 | 行表：数据 / 标签 / 脏 / 有效 / 替换状态；每个数组 1 个同步写口，3 级读索引流水后异步读 |
| `axi_llc_lookup.sv` | 93 | 查表引擎：launch → 下一拍发行表读 → 3 拍后行到达，解析完成（done）或重试（retry） |
| `axi_llc_resolve.sv` | 175 | 解析：命中 / 缺失 × 读 / 写的各种情况 |
| `axi_llc_rdacc.sv` | 101 | 读接收（轮询）、行表读的发射条件 |
| `axi_llc_wsched.sv`、`axi_llc_wport.sv` | 71、252 | 写接收的轮询、写上下文的推进、bypass 写的发射 |
| `axi_llc_mshr.sv`、`axi_llc_mshr_ent.sv` | 283、146 | MSHR 表与选择逻辑；单个表项 |
| `axi_llc_refill.sv` | 95 | 重填引擎 |
| `axi_llc_victim.sv` | 192 | 受害行写回槽和读受害行队列 |
| `axi_llc_rq.sv` | 99 | 每读主口的读响应队列 |
| `axi_llc_memwr.sv` | 48 | 内存写请求：受害行写回优先，否则 bypass 写 |
| `axi_llc_waypick.sv`、`axi_llc_rrpick.sv` | 41、38 | 缺失选路（无效路，否则 RRPV 最大的未占用路）；旋转优先级仲裁（读 / 写主口选择） |
| `axi_llc_linecam.sv`、`axi_llc_merge.sv` | 19、27 | N 项行地址比较；按字节合并 |
| `axi_llc_bop.sv` | 227 | Best-Offset 预取器及双优先级（BOP > Bingo）预取查表发射仲裁；候选队列是 `axi_llc_pfq`（`N = BOP_Q`，3 个候选并行查重） |
| `axi_llc_pfq.sv` | 76 | 预取候选队列（BOP 与 Bingo 共用）：N 项去重 FIFO（最老在 0 号），满时丢最老项；NCAND 个候选并行对出队后的队列查重，`cand_sel` 选一个入队；`pop` 只在非空时给（两个使用者都由构造保证） |
| `axi_llc_bingo.sv`、`axi_llc_bingo_agt.sv`、`axi_llc_bingo_pht.sv` | 160、268、289 | EXP-058 Bingo 4KB 空间预取器（FT/AGT/提交队列 + 1RW SRAM PHT_L/PHT_S（4 路树形 PLRU 用 `ttg_util_pkg::ttg_plru4_*`）+ 节流器/1 候选每拍发射器/16 项队列（`axi_llc_pfq`，行寄存器不复位）；`eda-05` Yosys 综合 `41,232` 单元 / **48 层**） |

状态：行表是同步 1R1W SRAM（`axi_llc_tables.sv`，`ttg_sram_1r1w`，`WRITE_FIRST = 1`）：每路一个数据 SRAM（`LLC_DATA`，`SETS = 4096` 深 × 512 位）和一个标签 SRAM（`LLC_TAG`，`TAGW = 14` 位），每组一个 valid / dirty / pf SRAM（`LLC_VALID` / `LLC_DIRTY` / `LLC_PF`，各 `WAYS = 16` 位，按路写掩码）和替换状态 SRAM（`LLC_REPL`，`RB = 32` 位）；MSHR `NMSHR = 16` 项（每项含 512 位重填数据和 512 位受害行快照）；受害行写回槽和队列（`VQD = 32` 项 × 512 位）；每写主口的请求队列（`WQD = 2` 项）和写上下文；每读主口的响应队列（`RQD = 16` 项 + 1 个响应寄存器）；轮询指针；查表引擎的 valid / issued 等。Bingo 的两张 PHT（`LLC_BINGO_PHTL` / `LLC_BINGO_PHTS`）是 `ttg_sram_1rw`。所有 SRAM 在 `rst_n` 期间由外壳逐地址写 `INIT_VAL` 清零，复位由 `ttg_rst_sweep` 拉长 `SRAM_SWEEP_CYCLES = 4100` 拍（大于最深的 LLC 表 4096 组），不再依赖上电值（common.md 4.1）。

## 5. 一拍内的数据流

### 5.1 读接收与行表读（`axi_llc_rdacc`、`axi_llc_lookup`、`axi_llc_tables`）

每 tick 最多接收一个读请求：对每个读主口算 `ok = 请求有效 & 本主口的响应槽空 & 查表引擎空闲 & 没有同行的写（本拍到达的、写队列里的、受害行在途的、MSHR 里的）& 没有"非 DCache 主口的第二个整行取行"（非 bypass 读、主口不是 1，且该主口已有在途的行，`has_master_d`）& 有空闲 MSHR`，再按轮询指针选第一个。"本拍末状态"的各列表（`vl_*_d`、`wl_*_d`、`ml_*_d`，即各单元的次态）用于这些检查。接收后进入查表引擎（`valid`），下一拍起发行表读（条件：没有行表写在进行、该行不是在途受害行、不是在被重填的行），3 个 tick 后拿到整组内容，进入解析。行表读在 `t` 请求，读到的是 `t+2` 的写之后的内容。

### 5.2 解析（`axi_llc_resolve`）

用 16 路的 `valid & 标签相等` 求命中路（`ttg_first_set`），无命中时由 `axi_llc_waypick` 选路：第一个无效且未被在途重填 / 写回占用的路，否则未被占用的路里 RRPV 最大的、同值取路号最小的；全被占用则本拍不能处理（`retry`，行表读重新发）。情形：

| 情形 | 动作 |
| --- | --- |
| 命中 + 写 | 把写数据按字节合并进该行，写行表（置脏；bypass 写保持原脏位），更新在途重填的受害行快照（bypass 写不更新） |
| 命中 + 读 | 响应队列有空位才完成：把该行按字偏移右移送响应队列；非 bypass 把该路 RRPV 置 0 |
| 缺失 + 写 + bypass | 无操作（内存写由写上下文发起） |
| 缺失 + 写 + 整行写 | 受害行脏则先写回（写上下文等待），否则直接写行表 |
| 缺失 + 写 + 部分行写 | 分配一个写 MSHR：重填后合并、写行表 |
| 缺失 + 读 | 分配 MSHR（bypass 读也分配） |

任何前提不满足（行表忙、无可选路、MSHR 满、响应队列满、写回忙）都是 `retry`。

**替换状态的更新只在解析这一拍做**（读改写：用这次查表读到的那一行算新值，写回 `repl_q`）。查表引擎同一时刻只有一个请求，下一次查表一定读到写回后的值。

- 命中（读、写，都不含 bypass）：命中路置 0（`rrip_hit`）。bypass 写命中只写行，不动替换状态。
- 分配（缺失 + 读非 bypass、写缺失的三种：直接写、先写回受害行、部分行写分配 MSHR）：整组变老到最大值为 3，选中的路置 2（`rrip_alloc`）。是在**分配时**更新，不是在重填写进行表时更新：重填和"受害行写回后的写提交"都不再写替换状态。
- 行表写口每 tick 只有一个（第 5.4 节 stage 2 的写提交优先）：分配那一拍若写提交占了写口（`tbl_busy2`），这次分配的替换状态更新**直接丢掉**，不重试（命中和直接写缺失本来就要求写口空闲，不受影响）。模型同样处理（`AXI_LLC.cpp` `lookup_tbl_busy_`）。
- 解析写了替换状态的那一拍，重填写行表要等下一拍（`busy3` 含 `repl_en`，与原来命中读时一样）。整行写 = `addr[5:0] == 0 & size == 63 & strb 全 1`（`is_full_write`）。

### 5.3 内存读与重填（`axi_llc_mshr`、`axi_llc_mshr_ent`、`axi_llc_refill`）

MSHR 分配给第一个空闲项。内存读按"第一个还没发过的项"发出（同拍新分配的 bypass 项在没有等待项时可立即发）。内存读响应（id = 槽号）把数据存进该项；bypass 读且主口响应队列有空位时直接应答。重填引擎处理第一个有重填数据的项，分两个 tick：先把脏受害行快照停放（写回槽或队列；若受害行上还有未解决的写则等待），再把重填行写进行表；第二个 tick 在响应队列有空位时应答主口、释放 MSHR。写 MSHR（部分行写缺失）在第一个 tick 就完成：合并写数据、写脏行、释放，不产生读响应。

### 5.4 写路径（`axi_llc_wsched`、`axi_llc_wport`、`axi_llc_victim`、`axi_llc_memwr`）

两个写主口各有 2 项请求队列（空队列时请求直通）和 1 个写上下文（同时只有一个未完成的写）。写上下文依次：填充 → 等查表引擎（`LPEND`）→ 查表 →（可能）等受害行写回或部分行写缺失的重填（`CPEND`）→ 行表已更新（`CDONE`）→ 响应。bypass 写的上下文改为等内存写响应才结束，查表只用来更新已缓存的副本。接收与查表发起共用一个轮询指针；受害行写回占着写路径时不收新的写。受害行来源有三个：写缺失换出脏行、读受害行队列的队首、重填把 MSHR 的快照停进空闲的写回槽。`axi_llc_memwr` 的优先级：受害行写回（整行、使能全 1、id 0）高于 bypass 写。

### 5.5 读响应（`axi_llc_rq`）

每个读主口一个移位 FIFO（`RQC` 项），第 0 项就是主口看到的响应寄存器；该项在出现后的一个 tick 内是"刚出现"（`fresh`，互连不能取）。一拍最多三个生产者按优先级入队：0 查表命中、1 bypass 的内存响应、2 MSHR 完成；生产者 k 在弹出后和更低编号生产者之后还有空位才被接受。

## 6. 关键路径与深度

单模块综合深度 **238 层**（axi_llc；2026-11-18，2026-11-19 换 SRRIP 后复测不变；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\mem_wr_resp_valid` 到 `\u_core.u_resolve.u_line.data [8191]`。从代码读出的、未综合验证的长组合链：

- **解析**：16 路 `valid & 标签相等` → `ttg_first_set` → 命中路号 → 16 选 1 的 512 位行选择（`ttg_onehot_mux`）→ 按字节合并（`axi_llc_merge`，512 位，字节偏移移位）→ 行表写数据；同时 `done` 依赖响应队列接收（`acc_a`）、`retry` 依赖 `done`；`axi_llc_waypick` 在缺失路径上多一级旋转优先级。
- **读接收**：对每个读主口做 3 组行 CAM（受害行持有者 27 项、写列表 6 项、MSHR 16 项），与响应槽、查表引擎、空闲 MSHR 等合成 `ok`，再旋转优先级选择；它的输出（`up_rd_req_ready`）又回到互连的台（见 axi_interconnect.md 第 6 节）。
- **MSHR 选择**：第一个未发的项、第一个有重填数据的项，各是对 16 项的 `first_set`，后接 512 位数据选择。
- **受害行写回**：三个来源的优先级和"队首再发一次"的怪行为（第 7 节）。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- **替换策略开关**：模型的 `LLC_REPL`（`rr` 旧轮转指针、`plru`、`lru`、`brrip`、`drrip`）和 `LLC_PF_LOW` 只用于 EXP-045 的比较，RTL 只实现默认的 `srrip`。
- **预取、`invalidate_line` / `invalidate_all` 维护、`nine` / `unified` / `pipt` 开关**：`AXI_LLCConfig` 里有（`prefetch_enable = false` 默认），RTL 固定为现行配置，不实现。
- **队列深度**：读响应队列、写请求队列、受害行写回队列在模型里是 32 项，RTL 是 16 / 2 / 8，溢出用断言守着（`axi_llc_rq` 的 `cnt_d <= RQD`、`axi_llc_victim` 的 `!(&rv_vld_d)`）；是否在所有程序下都不会超过，只在 fm_gate 的程序和 Linux 启动里被检验过，没有证明。
- **不可达路径**：RTL 的 `axi_llc_core.sv` 在"内存写响应没有对应的写回或 bypass 写"和"读响应指向未使用的槽"两处置 `bad_any` 断言；行表写的三个来源互斥另有断言（`ifndef SYNTHESIS`）。
- 行表读的写穿旁路：RTL 没有（读地址在 t 请求，t+3 异步读，天然看到 t+2 及之前的写）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- 队首受害行的响应弹出队首之后，"装载下一个受害行"一步仍看到旧队首，会把同一行再发一次（`axi_llc_victim.sv` 头注释）；
- 读响应"刚出现"的 tick 内主口不能取；
- 非 DCache 主口的非 bypass 读，该主口已有在途行时不接收；
- bypass 写的上下文等内存写响应才结束。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）。
- **EXP-045（SRRIP，2026-11-19）**：`fm_gate.sh` 67/67，周期与模型（trace-model `exp/llc-plru` `429172d` 默认）逐个相等，对新的 `scripts/ref_cycles.txt`（相对旧表 3 个程序变化，旧表 `ref_cycles_repl_rr.txt`）；程序用 rv64 不带 C 的构建（`TTG_PROGS=trace-model-simplify/build`；`env.sh` 默认的 `trace-model/build` 里是旧的 rv32 程序）。Linux 检查点窗口 s00–s12（`linux_segments_cmp.sh`，各 400 万周期）13/13 PASS，逐条检查 0 不一致，PT / UP 指纹与模型相同。`lint_chip.sh` 0 告警。
- **Lint**：`scripts/lint_chip.sh`。
- **Linux 启动门禁**：`scripts/build_soc64_linux.sh`、`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`。
- **仿真断言**：见第 7 节。
- **没有模块级的独立测试**：`tests/`、`tb/` 下没有 LLC 的测试。旧体系的锁步 spec（`axi_llc.io`）和变异表随 `spec/` 退役。**待补**：LLC 的随机并排测试（随机请求流，对比模型的 `AXI_LLC` 每 tick 的上游 / 内存侧输出）；缩小的几何（组数、路数）下的测试，以便更容易走到替换、受害行写回和"同组写在查表窗口内"的路径（4 MiB 下这些路径很少被走到，见"未核对"）。
- **未核对（继承自旧文档）**：
  - 各队列的实测最大深度（读响应队列 Linux 启动峰值 5，受害行写回队列程序里 2、随机测试里 7，写队列 0）——这是 RQD / WQD / VQD 取值的依据；
  - 覆盖率分析认为"不可达"的模型路径（`bad_any` 对应的两处）；
  - 4 MiB LLC 下查表窗口内同组写 0 次，缩小的 LLC 下才出现；
  - 旧文档里的"变异存活表"。

## 9. 参数与开关速查

`AXI_LLC_SETS`（4096）、`AXI_LLC_WAYS`（16）、`AXI_LLC_MSHR`（16，与 `axi_ic_pkg` 一致）；替换策略固定为 SRRIP（RTL 无开关；模型 `LLC_REPL`，见第 7 节）；`RQD`、`WQD`、`VQD`（`axi_llc_pkg` 内常量，不是宏）；模型侧 `CONFIG_AXI_LLC_ENABLE`、`CONFIG_AXI_LLC_SIZE_BYTES`、`CONFIG_AXI_LLC_WAYS`、`CONFIG_AXI_LLC_MSHR_NUM`、`CONFIG_AXI_LLC_LOOKUP_LATENCY`（`config.h`）。

## 10. 变更记录

- 2026-11-29 清理 D：去重（周期不变）。`axi_llc_bop`（`BOP_Q = 8`，3 个候选）与 `axi_llc_bingo`（`BINGO_Q = 16`，1 个候选）各自的去重丢最老 FIFO 抽成 `axi_llc_pfq`：Bingo 原来出队时多判一次 `cnt != 0`，但它的 `pop_head` 就是 `axi_llc_bop` 的 `bingo_pop`，后者要求 `has_bingo = !bingo_q_empty`，所以从不对空队列出队，去掉该判断等价；BOP 的行寄存器照旧复位、Bingo 的照旧不复位（`RST_LINES`）。新旧两组（BOP + Bingo 按 `axi_llc_core` 连接）随机输入 100 万拍逐拍对比输出和队列内部状态 0 差异。`axi_llc_bingo_pht` 删除本地 `plru4_update / plru4_victim`，改用同一函数 `ttg_util_pkg::ttg_plru4_touch / ttg_plru4_victim`。
- 2026-11-28 清理：`axi_llc.sv` 注释里的 "spec ports" 改为 "flat ports"（周期不变）。
- 2026-11-28（rtl 73761fa，SRAM 复位清扫）：`axi_llc_tables` 的数据 / 标签 / valid / dirty / pf / 替换状态 SRAM 与 `axi_llc_bingo_pht` 的 PHT SRAM 接上 `rst_n`；复位期间 SRAM 外壳逐地址写 `INIT_VAL`，`ttg_rst_sweep` 把复位拉长 `SRAM_SWEEP_CYCLES = 4100` 拍。原来 valid / dirty / pf / 替换表依赖上电值（硅片上是随机值，会假命中、写回垃圾）；0 周期变化，`fm_gate` 77/77（common.md 4.1）。同日文档核对：第 4 节状态改按 SRAM 描述，MSHR 16 项、受害行队列 32 项。
- **2026-11-22（EXP-058）**：新增硬件忠实版 **LLC Bingo 4KB 空间预取器**（`axi_llc_bingo.sv`、`axi_llc_bingo_agt.sv`、`axi_llc_bingo_pht.sv`），与 `axi_llc_bop` 组成双优先级预取（BOP > Bingo，`BOP_INF` `4 → 8`）；12-bit 负载 `pc_hash` 经 `dcache_mshr → mem_axi → axi_subsys → axi_interconnect → axi_llc_lookup` 透传；PHT_L（256×4）与 PHT_S（128×4）均采用 4 个独立 1D 1RW SRAM bank（干净 `$mem_v2`）与桶形移位掩码旋转，`eda-05` Yosys 综合 `axi_llc_bingo` 仅 **`41,232` 单元 / 48 层**；`lint_chip.sh` 0 警告，`fm_gate.sh` **69/69 PASS（0 FM 差、0 周期差）**，SPEC06 INT 386/386 SimPoint 加权 **`+1.26%`（`14.69 → 14.88 /GHz`）**。

- 2026-11-19（`exp/llc-plru`，EXP-045）：替换从"每组一个下一受害路指针"改为 SRRIP（每路 2 位 RRPV，查表解析时读改写；分配时更新，重填 / 写提交不再写替换状态；写口被写提交占用时丢弃分配的更新）。29 个 SPEC06 高权重点几何平均 +1.23%（omnetpp +9.0%）。
- 更早：见 git 历史。
