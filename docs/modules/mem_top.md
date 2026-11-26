---
module: mem_top
area: memsys
rtl: rtl/memsys/mem_top（mem_top.sv、mem_axi.sv）、rtl/memsys/memcpu_pkg/memcpu_pkg.sv
model: trace-model MemSubSystem/MemSubsystem.cpp、include/MemSubsystem.h（容器类 `MemSubsystem`，不是调度单元：它的成员 `dcache_`、`mshr_`、`wb_`、`mem_route_block`、`ptw_block`、`peripheral_axi_` 各自是调度单元，由 `SimCpu::cycle` 的生成序列调度）；AXI 一侧对应 `AxiSubsystem.cpp`（调度单元 `axi`）和 `SimCpu.cpp` 里的 I-cache 端口寄存器 `icache_port_regs_seq`
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 待测（由协调者补）
---

# mem_top 设计文档

## 1. 职责

访存子系统的顶层：把核（`core_top`）的访存侧端口和下面这些模块接起来，对外只露出核一侧的端口和 DDR 一侧的 AXI 从口。它自己几乎没有逻辑，做的事是：

1. 实例化并连接 `mem_route`（LSU / ICache 探测 / 页表遍历的请求分流）→ `dcache`（含 MSHR、写回缓冲、预取）→ `mem_axi`；`ptw_walk`（页表遍历器）；`peripheral_axi`（外设访问）；
2. **节拍**：产生 `phase0`（CPU 周期的第 0 个存储域节拍）和 `phase_last`，现行配置下恒为 1（见 7）；
3. **两级核侧寄存器**：ICache 探测响应寄存一拍、外设响应寄存一拍（和模型里对应寄存器的时序一致，见 5.3）；
4. **AXI 一侧**（`mem_axi`）：把四个主口（ICache 读、数据缓存 MSHR 读、数据缓存写回缓冲写、外设读和写）接到 `axi_subsys`（互连 + LLC），再接 DDR 从口；并用 `axi_cpu_port_adapter` 得到 CPU 侧看到的握手。

端口名取 `core_top` 的名字、方向取反，`soc_top` 用 `.*` 把它们接起来（`rtl/core/soc_top/soc_top.sv`）。

`memcpu_pkg` 是这些 CPU 相位模块共用的常量包（端口数、路由 id 宽度、页表常量、外设和 AXI 适配器常量），在 `mem_route.md`、`ptw_walk.md`、`peripheral_axi.md` 里按用到的部分引用。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| 存储域节拍数 | `TICKS = AXI_SUBSYSTEM_FREQ_DIV = 1`（1 = 与 CPU 同频；16 = 原来的 16 倍频结构），节拍计数器 4 位，最大 16 | `ttg_cfg_pkg`、`mem_top.sv` |
| load / store 口 | 4 / 3 | `LSU_LDU_COUNT`、`LSU_STA_COUNT` |
| 数据字 | `XLEN_BITS = 64`；store strb `DST_STRB_W = XLEN/8 + 1`；第二字 `DST_L2_W` | `ttg_cfg_pkg` |
| ICache 行 | `ICACHE_WORD_NUM = 16` 个 32 位字（64 字节） | `ttg_cfg_pkg` |
| 数据缓存行 | 16 个 32 位字（64 字节） | `DCACHE_WORD_NUM` |
| AXI 主口 | 读 4 个（0 ICache、1 数据缓存 MSHR、2 未使用 `UNCORE_LSU_R`、3 外设）；写 2 个（0 写回缓冲、1 外设） | `mem_axi.sv` |
| DDR 从口 | 数据 256 位、地址 32 位、id 6 位 | `mem_top` 端口 |
| AXI id | CPU 侧主口 4 位（`AX_ID_W`），3 个适配通道（`AX_NCH`：ICache 读、外设读、外设写） | `memcpu_pkg` |
| 预取开关 | 参数 `PF_EN`（默认 1，传给 `dcache`） | |
| 外部 MMIO 开关 | 参数 `EXT_MMIO_EN`（默认 0 走仿真 `peripheral_axi`；1 走独立 64-bit AXI4-Lite `mmio_*` 绕开 LLC，`chip_top` 开启） | `mem_top.sv` / `mem_periph_wrap.sv` / `mem_mmio_axi.sv` |

## 3. 接口

分三组（完整端口表见 `mem_top.sv`，与 `core_top` 同名、方向取反）：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 / 出 | `mem_req_*`、`mem_resp_*`、`mem_req_accepted(_id)` | ICache 的 AXI 读主口（取指缺失填行），经 `mem_axi` |
| 入 / 出 | `dc_req_valid/addr`、`dc_resp_valid/retry/miss/data` | ICache 对数据缓存的探测请求与响应（响应寄存了一拍，见 5.3） |
| 入 / 出 | `itlb_walk_*`、`dtlb_walk_*` | 两个 TLB 与页表遍历器（请求、响应、`resp_consumed`、`flush`） |
| 入 / 出 | `lsu2dcache_load_ports_*`、`lsu2dcache_store_ports_*`、`dcache2lsu_*` | LSU 与数据缓存（经 `mem_route`）；`*_retry_busy` 为隐藏重试寄存器占用；`dcache2lsu_mshr_fill(_line)` 为填充通知 |
| 入 / 出 | `peripheral_req_*`、`peripheral_resp_*` | 外设访问请求与响应（响应寄存了一拍） |
| 入 / 出 | `env_modeled`、`env_rdata`、`env_rd_en/addr/func3` | 测试台里的设备模型（见 peripheral_axi.md） |
| 入 / 出 | `d_*` | DDR 的 AXI 从口（测试台里的 `SimDDR`） |
| 入 / 出 | `mmio_ar*`/`r*`/`aw*`/`w*`/`b*` | 可选 64-bit AXI4-Lite 外部 MMIO 主口（`EXT_MMIO_EN=1` 启用，保留精确字节地址） |
| 出 | `phase0` | 给测试台：CPU 域寄存器（核没有使能）只在这一拍更新 |

## 4. 结构

```
 mem_top
  ├ phase_q 节拍计数器 → phase0 / phase_last
  ├ mem_route  (u_route)   : LSU / ICache 探测 / 遍历器 -> dcache 的请求与响应分流
  ├ ptw_walk   (u_ptw)     : 页表遍历器，client 0 = DTLB，1 = ITLB
  ├ dcache     (u_dcache)  : L1D + MSHR + WB + 预取
  ├ peripheral_axi (u_periph) + 外设响应保持寄存器
  ├ ICache 探测响应寄存器（dc_resp_*_q）
  └ mem_axi    (u_axi)     : 四个主口的粘合、axi_subsys、axi_cpu_port_adapter
        ├ axi_subsys           (u_axi)   : AXI 互连 + LLC（axi_subsys.md、axi_interconnect.md、axi_llc.md）
        └ axi_cpu_port_adapter (u_adapt) : 非数据缓存主口的 CPU 侧握手视图（axi_cpu_port_adapter.md）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `mem_top.sv` | 393 | 顶层：端口、节拍、各模块连线、两个核侧寄存器 |
| `mem_axi.sv` | 233 | AXI 一侧：四个主口的输入整形、实例化 `axi_subsys` 和 `axi_cpu_port_adapter`、把响应拆回各主口 |
| `memcpu_pkg.sv` | 60 | 共用常量：端口数（`NLD`、`NST`、`P3`）、id 宽度（`LD_ID_W`、`ST_ID_W`、`RT_ID_W`、`FILL_LINE_W`）、路由主人枚举、ReplayType、Sv39 页表常量、遍历器状态枚举、外设和 AXI 适配器常量 |

状态：`phase_q`（4 位）；ICache 探测响应寄存器（valid / retry / miss / 32 位数据）；外设响应保持寄存器（ready / is_mmio / 64 位数据）。其余状态都在各子模块里。

## 5. 一拍内的数据流

### 5.1 请求方向

LSU 请求 → `mem_route`（P3 上可能被 ICache 探测或遍历器请求替换）→ `dcache`。LSU 的请求只在节拍 0 送进数据缓存（`rt_dc_ld_valid & phase0`），其余节拍呈现空请求；`dc_icache_req` = 有探测时为 `NLD - 1`，否则为 `NLD`。遍历器的读请求 `issue_walk_read/walk_read_addr` 进 `mem_route`；它的授权 / 事件 / 唤醒从 `mem_route` 回来。

### 5.2 AXI 方向（`mem_axi`）

- 数据缓存的两个主口每个节拍都工作：读主口（MSHR）每次读整行（`total_size = 63`），id 取 MSHR 项号；写主口（写回缓冲）写整行，`wstrb` 全 1，写响应 ready 恒为 1；
- CPU 侧的主口（ICache、外设）只在节拍 0 有效（`phase0 &` 门控），RTL 注释说对应模型的 `mask_axi_cpu_boundary_for_internal_tick`，但这个函数在当前模型代码里已经找不到（16 倍频结构的遗留），现行 TICKS = 1 时这个门控恒为 1；
- 外设读写主口带 `bypass`（旁路 LLC）；
- 互连的响应按主口号拆回：数据缓存两个口的响应 / 接受信号直接回 `dcache`，ICache 与外设的接受 / 响应先过 `axi_cpu_port_adapter` 得到 CPU 侧视图，ICache 读响应的数据（16 个 32 位字）直接取自互连主口 0 的响应数据。

### 5.3 核侧寄存器

- **ICache 探测响应**：`mem_route` 产生的响应寄存一拍再给前端（`dc_resp_*_q`，`phase0` 时更新）。原因（`mem_top.sv` 注释）：前端的 ICache 在一拍里比 `MemSubsystem::comb_outputs` 先运行，所以只能看到上一拍路由块产生的探测响应；模型对应 `SimCpu::icache_port_regs_seq` 里的 `icache_resp_q = icache_resp`；
- **外设响应**：`peripheral_axi` 的响应寄存一拍再给核（`hold_*_q`，`phase0` 时更新；注释写的是 `SimCpu::peripheral_resp_hold`，模型里对应的是 LSU 的 `mmio_resp_d` 寄存器）。

## 6. 关键路径与深度

depth: 待测（由协调者补）。`mem_top` 自己没有逻辑，深度完全取决于它连接的模块。从代码读出的，未综合验证：整个存储域现在与 CPU 同拍，所以下面这些原本被 16 倍频切开的路径都落在一拍里：

- LSU 请求 → `mem_route` → `dcache` 第一级（bank 授权）——寄存后，第二级读阵列 → 命中数据 → `mem_route` 响应分流 → LSU（见 dcache.md、mem_route.md）；
- MSHR 分配 → 新项当拍发 AXI 读请求 → `axi_subsys` 的接受信号 → 回 `dcache`；`scripts/lint.sh` 里对 `mem_top` 单独关掉了 UNOPTFLAT（注释写的理由是互连与 LLC 的握手在结构体粒度上看起来成环，实际不是真的环，仿真正常）；
- AXI 读响应 → MSHR 暂存槽 → 填充转发 → 响应发布（见 dcache.md 第 6 节）。

## 7. 与模型的差异和取舍

- **节拍**：`mem_top` 里的节拍计数器是 16 倍频旧结构的遗留（`TICKS = 16` 时存储域一个 CPU 周期跑 16 拍，测试台只在第 0 拍给核时钟）。现在 `AXI_SUBSYSTEM_FREQ_DIV = 1`，`phase0` 和 `phase_last` 是常数（`g_ph_const`），门控和寄存器的使能全部消去，`phase_q` 只保留作测试台的探针（`tb/core/core_public.vlt`）；
- **模型没有顶层模块**：`MemSubsystem` 只是容器和端口绑定（`MemSubsystem::init`），各子模块的先后顺序由 `SimCpu::cycle` 里自动生成的序列给出（`wb_` → `mshr_` → `dcache_.comb_stage2` → `mem_route_block.comb_response` → …… → `ptw_block.comb_request` → `mem_route_block.comb_request` → `dcache_.comb_stage1` → `wb_` / `mshr_` 的 `comb_dcache_to_axi` → `ptw_block.comb_feedback` → `peripheral_axi_`）。RTL 是一个纯组合网表加寄存器；
- **LLC 的表**：模型里 LLC 的元数据、有效位、替换位表在 `MemSubsystem.cpp` 里的 `AxiLlcTableRuntime` 实现（并且没有数据存储，数据来自功能内存）；RTL 的 LLC 在 `axi_llc`（见 axi_llc.md）；
- **DDR**：RTL 的 DDR 一侧是 256 位 AXI 从口，由测试台的 `SimDDR` 回答；模型里是 `AxiSubsystem` 内部的内存模型；
- **设备**：不在 RTL 内，见 peripheral_axi.md。

代码里看起来不一致的地方（未改，仅记录）：
- `memcpu_pkg.sv` 里 `NST` 的注释写 "4 store ports"，实际 `LSU_STA_COUNT = 3`；`NLD` 的注释和 `mem_top.sv` 里 "ICache 读主口"、"16 倍频" 的措辞是旧结构的表述；
- `mem_top.sv` 文件头注释写 "`clk` is the fast tick clock (16 ticks per CPU cycle)"，现行配置是 1 拍；
- `memcpu_pkg::PT_LEVELS = 3` 但遍历器状态枚举只有 `L1` / `L2` 两组（见 ptw_walk.md 第 4 节）；
- `mem_axi.sv` 的主口 2（`UNCORE_LSU_R`）整个未使用，只是占位（输入恒 0）。

未核对（继承自旧文档）：无，`mem_top` 是新文档。`axi_subsys` 一侧的行为（互连仲裁、LLC）由对应文档负责，没有在这里核对。

## 8. 验证

- **整核门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比功能模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）。`mem_top` 作为整体就是被这个门禁覆盖的（测试台 `tb/soc` 里是 Verilated 的 `core_top` + `mem_top`，`scripts/soc_smoke.sh`）；
- **Linux 整核门禁**：`scripts/linux_gate.sh`；
- **Lint**：`scripts/lint_chip.sh`（`scripts/lint.sh` 对 `mem_top` 单独加 `-Wno-UNOPTFLAT`）；
- **没有 mem_top 的模块级测试**（它没有自己的逻辑，各子模块的验证见各自文档）。

## 9. 参数与开关速查

`PF_EN`（`mem_top` 参数，来自 `soc_top`）；`AXI_SUBSYSTEM_FREQ_DIV`（`ttg_cfg_pkg`，决定 `TICKS`）；`LSU_LDU_COUNT`、`LSU_STA_COUNT`、`XLEN_BITS`、`DCACHE_WORD_NUM`、`ICACHE_WORD_NUM`；`memcpu_pkg` 的 `RT_ID_W`、`LD_ID_W`、`ST_ID_W`、`FILL_LINE_W`、`PT_*`、`PA_SIZE_W`、`AX_ID_W`、`AX_NCH`。

## 10. 变更记录

- 2026-11-26（`rtl/soc-env`）：新增 `EXT_MMIO_EN` 参数及 `mem_periph_wrap.sv`、`mem_mmio_axi.sv`，为 `chip_top` 提供绕开 LLC 的独立 **64-bit Full-AXI4** MMIO 主口（带真实 `ARSIZE/AWSIZE`、`Device-nGnRnE` 属性、1/2/4/8 字节读写及精确字节偏移副作用识别）；`axi_ic_aw.sv` 解耦 `o_bready` 对 `d_bid` 的组合依赖；默认 `EXT_MMIO_EN=0` 保持 `soc_top` 与 `fm_gate` 行为零变化。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`mem_top.sv` 透传 `fdip_snoop_line` / `fdip_snoop_dirty` 连接 `core_top`（ICache FDIP）与 `dcache`；修复 `mem_axi.sv` 在 `AXI_SUBSYSTEM_FREQ_DIV == 1` 下 `raw_accepted[0]` / `raw_accepted_id[0]` 误接组合 `ax_rd_acc_new[0]` 导致 ICache 通道接受脉冲早到 1 拍的问题（改为使用已寄存 `ax_rd_accepted[0]`，严格对齐 `SimCpu` 的 `icache_axi_q` 语义），单拍消除 2-slot FDIP 在 7 个程序上的 1 拍偏差；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗对齐。
- 本分支未改动（`git log 261bd67..HEAD -- rtl/memsys/mem_top rtl/memsys/memcpu_pkg` 为空）。更早：`8dbb7cd` 合入 rv64imab；`f0bd79d` rv64 step 6（8 字节 MMIO）；`72f2cd9` rv64 step 3（Sv39）；`fb05807` rv64 step 2（数据字 XLEN 位）；`4e954d7` ROB 紧凑的清理批次；`b1e0335` EXP-024。`memcpu_pkg` 另有 `8abb7ab`（RTL 清理）、`f21cebf`（前端 XLEN 位 PC）。
