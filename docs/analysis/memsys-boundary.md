# 访存子系统（DCache 域 / PTW / 路由 / 外设 AXI / AXI 互连 / LLC）边界、结构与翻译方案（分析报告）

> 基线：参考模型 `baseline-sim/src`（`2f31e8d`），默认配置（`include/config.h` 与 `config.h.default` 相同）。
> 路径简写：`S=baseline-sim/src`，`M=S/MemSubSystem`，`K=S/axi-interconnect-kit`，`RV=S/rv_simu_mmu_v2.cpp`。
> 标注 **[已验证]** 的来自实验（本阶段做的录制点，见 `memsys-record-hook.md`/`.patch`）；**[读码]** 为只读代码得出；**[未验证]** 明确写出。
> uncore（互连/LLC）与 PTW/外设两节的初稿由两个只读调研 agent 完成，我抽查了关键结论（16 tick 结构、DDR_BASE=0 等），未逐行复核的写了 [未验证]。
> 配套：`memsys-record-hook.patch`（对 `refsim_tap` 的补丁，DCache 域每 tick 的边界）、`memsys-record-hook.md`。

## 0. 摘要（先看这里）

1. **整个访存域跑在 16 倍频上**：`CONFIG_AXI_SUBSYSTEM_FREQ_DIV=16` 且 `CONFIG_DCACHE_FAST_DOMAIN=16`。每个 CPU 周期 = 16 个内部 tick：tick 0 是 `SimCpu::cycle()` 的常规路径（LSU 请求注入、路由、PTW、外设都只在这里），tick 1..15 在 `run_extra_axi_subsystem_ticks()`（`RV:711-736`）里：AXI 互连 + LLC + DDR + MMIO 每 tick 推进一次，**DCache 域（RealDcache + MSHR + WriteBuffer + 响应锁存/转发）也每 tick 推进一次**（用空请求，`dcache_fast_comb/seq`）。
   RTL 表达：单一快时钟 `clk` + CPU 相位使能（第 5 节）。**[已验证]** 录制点实测：每 CPU 周期 16 个 tick，LSU 请求只在 tick 0 非空。
2. **DCache 域是一个"每 tick 一次的同步设计"**，边界很干净：输入 = {路由后的 LSU 请求（仅 tick 0）, MSHR AXI 读口输入, WB AXI 写口输入}，输出 = {发布给 LSU/路由的响应（仅 tick 0 发布）, MSHR AXI 读口输出, WB AXI 写口输出}。C++ 里 MSHR/WB 的 `nxt` 在 comb 阶段被多个函数就地修改（comb/seq 熔合），RTL 按 06 §0 合并成一次次态规则即可。
3. **CPU 周期域（tick 0 only）**：MemRouteBlock（147 行）、MemPtwBlock（只有 walk 客户端活着）、PeripheralAxi（+ 顶层 `peripheral_resp_hold` 寄存器）。这三块边界在 CPU 周期粒度，**最先闭合、最适合并行**。
4. **PtwWalker.cpp / PtwCompactCoreKernel.h / PtwMemPort 全部死代码**（TLB 走 `PtwWalkPort`，MemPtwBlock 的 mem-client 机制也不可达）；`AXI_Router_AXI4.cpp` 整体死；LLC 预取、noalloc、运行期模式切换、MMIO 下游口（`DDR_BASE=0` 使所有地址走 DDR 口）都死。
5. **最大的难点是 LLC 控制器**（`AXI_LLC.cpp` 3321 行，live 约 2000 行，难度 5）和互连读/写前端的 ready-first 握手；其次是 DCache 域里 8 读口/16 bank/填充旁路。
6. 已交付：分析报告、DCache 域 tick 级录制点（补丁 + 验证：周期数、全部输出与原版逐字节一致，5 个程序）、翻译分工建议。**未做 RTL 翻译**（理由见第 9 节：DCache 域需要 16 tick 的锁步外壳，PTW/路由还需第二轮 tap；先让分工方案落地更划算）。

## 1. 每个 CPU 周期里的调用顺序（`RV:1059-1190`）

```
 tick 0 (= cycle()):
  1 front_comb_before_back          # ICache.comb 在此执行（早于下面的 AXI 输出，见 icache-boundary §6）
  2 axi_subsystem_comb_outputs      # LLC table lookup_in → DDR/MMIO.comb_outputs → interconnect.comb_outputs
  3 bridge_axi_to_mem_subsystem     # interconnect 端口 → mshr_axi_in / wb_axi_in / peripheral_axi_*_in
  4 mem_subsystem.comb_outputs      # dcache_domain_comb_outputs; capture_raw_response; forward_from_fill; publish; route.comb_response
  5 back.comb                       # LSU/DTLB 在此产生请求（lsu2dcache、walk 请求、peripheral_req）
  6 mem_subsystem.comb_inputs       # ptw.comb_begin; route.comb_request; dcache_domain_comb_inputs; ptw.comb_finish; peripheral_axi
  7 bridge_mem_subsystem_to_axi     # mshr_axi_out/wb_axi_out/peripheral_*_out → interconnect.read/write_ports
  8 axi_subsystem_comb_inputs       # interconnect.comb_inputs → DDR/MMIO.comb_inputs
  9 front/back seq; mem_subsystem.seq; axi_subsystem_seq
 tick 1..15 (run_extra_axi_subsystem_ticks):
  axi_subsystem_comb_outputs → bridge_dcache_axi_to_mem → dcache_fast_comb(空请求) → bridge_dcache_mem_to_axi
  → axi_subsystem_comb_inputs_dcache_fast_tick → dcache_fast_seq → axi_subsystem_seq → 累加 CPU 边界状态
```
`dcache_domain_comb_outputs` = `wb.comb_inputs_axi; mshr.comb_inputs_axi; wb/mshr.comb_outputs_dcache; Dcache_Read; dcache.stage2_comb; Dcache_Write`；
`dcache_domain_comb_inputs` = `dcache.stage1_comb; mshr.comb_inputs_dcache; wb.comb_inputs_dcache; mshr/wb.comb_outputs_axi`（`MemSubsystem.cpp:~870-960`）。每个 tick 各调 1 次。
tick 0 里 `dcache_domain_comb_inputs` 之后还有 PTW 的 `comb_finish` 和外设；tick 1..15 里没有（**[读码]** PTW/路由/外设不在 extra tick 里被调用）。

## 2. 各模块边界、结构与死代码

### 2.1 DCache 域（RealDcache + MSHR + WriteBuffer + 阵列 + 响应锁存）——每 tick 1 次

配置：`DCACHE_SETS_NUM=256, WAYS=4, LINE=64B(16 字)`，`TAG_BITS=18, SET_BITS=8, OFFSET_BITS=6`，bank = `set&15`（16 bank），MSHR 8 项，WB 8 项，LSU 端口 `LSU_LDU_COUNT=4, LSU_STA_COUNT=4`（共 8 个请求口）。

**边界输入（每 tick）**
| 信号 | 内容 | 来源 |
| --- | --- | --- |
| `req`（`LsuDcacheIO`）| 4×LoadReq{valid, addr32, req_id32}、4×StoreReq{valid, addr32, data32, strb8, req_id32}、`icache_req`(3b) | `mem_route_block.comb_request` 的输出 `dcache_req_mux_`；**tick 1..15 全空**（`dcache_empty_req_`，`icache_req=LSU_LDU_COUNT`）。`LoadReq/StoreReq.replay` 只喂 perf，丢弃 |
| `mshr_in`（`MshrAxiIn`）| req_ready, req_accepted, req_accepted_id(8b, 值<8), resp_valid, resp_id(8b), resp_data[16×32] | interconnect `read_ports[MASTER_DCACHE_R]`（`RV:346-358`）；`req_ready` 未被 MSHR 读（**[读码]**，可删）|
| `wb_in`（`WbAxiIn`）| req_ready(未读), req_accepted, resp_valid | `write_ports[MASTER_DCACHE_W]` |

**边界输出**
| 信号 | 内容 | 可见时刻 |
| --- | --- | --- |
| `resp_pub`（`DcacheLsuIO`→经 `MemRouteBlock.comb_response` 分发）| 4×LoadResp{valid, data32, req_id, retry, bank_conflict, replay(2b)}、4×StoreResp{valid, bank_conflict, replay, req_id}、`mshr_fill`、`mshr_fill_addr` | **仅 tick 0 的 comb_outputs 发布**（`publish_pending_dcache_response`，之后 `MemSubsystem::seq` 清空）；tick 1..15 里产生的响应在 `dcache_resp_pending_` 里累积到下一个 tick 0 |
| `mshr_out`（`MshrAxiOut`）| req_valid, req_addr, req_total_size(=63), req_id(0..7), resp_ready | 每 tick（`comb_outputs_axi`，在 `comb_inputs_axi` 的 accepted 消去之后）|
| `wb_out`（`WbAxiOut`）| req_valid, req_addr, req_total_size, req_id(=0), req_wstrb(64b 全 1), req_wdata[16×32], resp_ready(恒 1) | 每 tick |

**内部结构与硬件对应（RTL 应有的样子）**
- **tag/valid/dirty/PLRU 阵列**：`[256][4]`（20 位 tag 实际 18 位）、valid/dirty 各 1 位/路、PLRU 3 位/组。**data 阵列 `[256][4][16 字]` = 64 KiB**。C++ 把它们写成全局数组；RTL 写成 16 个 bank（bank = set&15；每 bank 16 组×4 路×512b 行），每个 bank 每 tick 最多 1 个读（`DcacheConfig.cpp check_data_bank_access` 在冲突时直接 abort，等价于"stage1 的 bank 授权保证每 bank ≤1 读"）。
- **读口（8 个，4 load + 4 store 探测）**：stage1 授权后，下一 tick 开头 `Dcache_Read` 读 `[set]` 的 4 路 valid/tag/dirty 与 **每路 `data[word_off]`**（一个 32 位字）。**这等价于"寄存器化地址 + 异步读"**：读请求恰好是 stage1 授权结果 `s1s2.slot`（`valid && !replayed`），RTL 不需要额外的读请求寄存器。
- **填充快照读口（1 个）**：`fillout.valid` 时读整组 4 路的 valid/tag/dirty/data(整行)/PLRU，供 stage2 选牺牲路、产生脏行写回。
- **写口**：4 个 store 的 `pendingwrite`（字写 + strobe + 置 dirty）、`lru_updates`×8（PLRU 触碰）、1 个填充整行写（`write_dcache_line`：若 set 内已有同 tag 的有效路则覆盖那一路，否则写 `way_idx`；清 dirty，随后 `fill.dirty` 再置位）。**写在 `stage2_comb` 之后立即生效（`Dcache_Write` 在同一 tick），读在下一 tick 开头**，所以对 RTL 就是"同步写、读先于写"的普通存储器；**同一 tick 的 `Dcache_Read` 读到的是上一 tick 写之后的值**。
- **两级流水**：stage1（`stage1_comb`）接请求（真实请求 / 隐藏 bank-retry 重发 / 无），做 bank 授权（填充读优先占 bank，然后 load 0..3、store 0..3 依次），输出 MSHR 查找请求（`find_req`）、WB 旁路/合并请求；锁存到 `S1S2Reg`。stage2（`stage2_comb`）读 `S1S2Reg` + 阵列读数据 + MSHR/WB 响应，产生 hit/miss/replay 分类、MSHR 分配、LRU/pendingwrite/fill 写、给 LSU 的响应。
- **隐藏 bank retry**：LSU 请求 bank 冲突且 `req_id` 最高位为 0（LSU 来源）时，不回 replay，而是在 `bank_retry_issue_wires` 里锁存，下一 tick 在无新请求时自动重发（`bank_retry_cur/nxt`，每口 1 槽）；`MemSubsystem::dcache_domain_comb_inputs` 把"该口 pending 响应还没被取走"作为 `retry_blocked` 传入。
- **响应锁存/转发**（`MemSubsystem` 里，不是 RealDcache）：`capture_dcache_raw_response` 把 tick 内的 raw 响应存到 `dcache_resp_pending_`（每口 1 槽，溢出为 Assert）并记 meta（addr/data/strb）；`forward_pending_response_from_fill`：若 MSHR 此 tick 的 `fill_req` 与某个等待 `MSHR_HIT/MSHR_FULL` 的 pending load 同行，直接把 load 响应改成 HIT 带填充数据；store 则合并进 `fill.data` 并置 dirty。→ 这是 RTL 里 DCache 顶层的一段独立逻辑（`dcache_resp_latch`，约 250 行）。
- **MSHR**：8 项 `{valid, issued, addr32, merged_store_dirty, merged_store_data[16], merged_store_strb[16×8]}` + `mshr_count` + 1 个 AXI 响应保持槽 `{valid, id, data[16]}`。分配：同行已有项则合并 store，否则取第一个空项；AXI 发射：第一个 `valid && !issued` 的项，`req_accepted` 当 tick 立即置 issued 并撤销请求；响应接收：保持槽空且 `resp_id` 指向 valid&&issued 项时接收；填充完成（`fill_resp.done`）释放项。`find_resp`、`free = 8 - count` 读的是 **comb 阶段就地改过的 nxt**（所以同一 tick 里 AXI 响应/accept 先于 find 与 free 生效）——RTL 必须按这个"先 AXI 后 DCache 读"的依赖链组合。
- **WriteBuffer**：8 项环形 `{addr, data[16]}`，`count/head/send`。旁路（load 命中 WB 最新同行项，**最后匹配者优先**）、合并（store，命中 head 且 `send` 时 busy）、脏行入队（stage2 的 `dirty_info`）、AXI 写发射（head，`send==0`）、`req_accepted` 置 send，`resp_valid` 弹出。`count`/`free` 同样读 nxt。

**死代码 / 不翻译**（DCache 域）
- 全部 `COUNT_L1D_*`、`ctx->perf.*`、`alloc_cycle/axi_read_start_cycle/axi_read_active`、`axi_write_*`、`perf_replay`、`mshr_average/max_count`：perf。
- **`lsu_origin`**（MSHR/WB/FILLWrite/DirtyInfo 里一路带到底）：**只喂 perf**（[读码]：读点全部在 `ctx->perf` 增量里），删。
- `MSHRFINDResp.hit`（与 `valid` 相同）、`MSHR_FILLReq.way_idx`、`MSHR_FILLReq.id`（保持槽 id 用 `axi_resp_hold_id`）冗余；`DcacheConfig.cpp` 的 `begin_data_bank_cycle/check_data_bank_access`（abort 断言）；`DcacheLsuIO.mshr_fill_addr` **要保留**：`RealLsu.cpp:43,74` 用它唤醒同行的 LDQ/STQ 项（`MemRouteBlock` 只读 `mshr_fill`）。
- `RealDcache.cpp` 中被注释掉的 `CheckAddr` 重放检查、`Assert` 溢出检查（"latch overflow"）、`dump_debug_state`。
- `#if !BSD_CONFIG` 在默认配置下**生效**（`BSD_CONFIG=0`）；其内容几乎都是 perf，功能字段只有 `bank_conflict`/`retry`（LSU 读）。

**已知"怪行为"（必须复刻，登记疑点）**
- `stage2` 里 store 命中正在填充的同一路时回 `CONFLICT`（`RealDcache.cpp:657-663`）；store 与 MSHR 填充同行时把 store 合并进填充数据并回 HIT（`626-647`）；WB 满时 `dirty_info` 被丢弃且 `fill_write.valid=false`（填充停顿，`470-473`），注释自相矛盾，按代码行为实现。
- ICache 探测（`s1s2.icache_req==i`）是**只查不分配**：miss 时回 `CONFLICT`、不分配 MSHR（`548-557`）。load 口 `LSU_LDU_COUNT-1`（=3）被路由块用于 PTW/ICache 请求。
- load 响应在 `WB.bypass_resp.valid` 时优先于 cache 命中（`531-537`）；store 命中判断在 MSHR 合并之后。

### 2.2 MemRouteBlock（CPU 周期域，tick 0 only；147 行）
- 输入：LSU 请求口（4 load + 4 store，直通）、`icache_req{req_valid, req_addr}`、`ptw_walk_req/ptw_dtlb_req/ptw_itlb_req{valid, addr}`、`dcache_resp_pub`（DCache 发布的响应）。
- 输出：`dcache_req`（= LSU 请求直通 + **load 口 3 被 ICache/PTW 抢占**：优先级 ICACHE > PTW_WALK > PTW_DTLB > PTW_ITLB，同一 owner 不能连续两拍发，`req_id` 最高位恒 1 由本块分配），`lsu_resp`（DCache 响应，剔除路由 id 的 load 响应；口 3 被抢占时回给 LSU 的是 `CONFLICT` 重放）、`icache_resp{resp_valid, resp_retry, resp_miss, resp_data}`、`ptw_grant{valid, owner, req_id}`、`ptw_events{valid, owner, data, replay=0, req_addr, req_id}`、`wakeup{dtlb, itlb, walk}`。
- 状态：`issued_tags{owner, req_addr, req_id}`、`ptw_wait{3}`、`lsu_replay{valid, req_id}`、`next_req_id`（32 位，仅用最高位恒 1 的递增）。`comb_response` 在 `mem_subsystem.comb_outputs`（早于 back.comb），`comb_request` 在 `comb_inputs`（晚于 back.comb）；对 RTL 就是"状态寄存器 + 两段独立组合"，**无 comb/seq 熔合难题**。
- 死代码：`PTW_DTLB/PTW_ITLB` 分支（ptw mem client 不可达，见 §2.3）；`next_req_id` 位宽可缩；perf 计数。
- 难度 2，RTL 约 200 行。

### 2.3 PTW（MemPtwBlock，CPU 周期域；PtwWalker 死）
（详见调研结论；核对要点）
- **活的**：`MemPtwBlock` 的 walk 客户端（DTLB、ITLB 各一个 `PtwWalkPort`），共享一个 walker：`IDLE, L1_REQ, L1_WAIT_RESP, L2_REQ, L2_WAIT_RESP`，轮转选客户端（`walk_rr_next`），读地址 L1=`(satp[21:0]<<12)+(vaddr[31:22]<<2)`，L2=`(l1_pte[31:10]<<12)+(vaddr[21:12]<<2)`；PTE 检查：L1 `!V||(!R&&W)` 故障、L1 叶且 `pte[19:10]!=0` 故障、L2 `!V||(!R&&W)||!(R||X)` 故障；不查 A/D/U/X（TLB 查）。通过 MemRouteBlock 走 DCache load 口 3（grant → 下一拍 event/wakeup）。
- **死的**：`PtwWalker.cpp/.h`、`PtwMemPort`、`PtwCompactCoreKernel.h`（可读的打包实现，无调用者，但是"最小接口/状态编码"的好规格）、MemPtwBlock 的 mem-client 全套（h:41-52,320-326,954-1027,1154-1161）、`on_walk_mem_replay`（`replay` 恒 0）、事件槽 1..3、`access_type`、`events[0].req_addr`。
- 边界（每 CPU 周期）：输入 = 两个客户端的 `{req_valid, vaddr32, satp32, resp_consumed}` + `walk_client_flush[2]`（seq 期）+ grant/event/wakeup（路由输出）；输出 = 每客户端 `{req_ready, resp_valid, resp{fault, vaddr[31:12], leaf_pte[31:10]与[7:0], leaf_level}}` + `issue_walk_read, walk_read_addr`（**唯一一条组合路径**：新请求当拍选中、当拍发 L1 读）。
- 状态约 185 位 + `walk_req_id(32)`；`drop_resp_credit` 活代码里是无界 uint32（打包版 2 位饱和——与活代码不等价，RTL 用 ≥8 位）。
- 难度 3，RTL 250-300 行。TLB 侧适配器（`send_walk_req` 后 `req_ready` 立即掉、`consume_resp` 后 `resp_valid` 立即掉）属于 TlbMmu 的接口行为，PTW 不用复刻。

### 2.4 PeripheralAxi（CPU 周期域；PeripheralModel 留 testbench）
- 核心侧：`peripheral_req{is_mmio, wen, addr, wdata, fun3}`（LSU 出）、`peripheral_resp{ready, is_mmio, rdata}`（回 LSU，**经顶层 `peripheral_resp_hold` 寄存器一拍延迟**，`RV:1066/1110/1186`）。AXI 侧：EXTRA_R/W 主口，`bypass=1`，事务只有 1/2/4 字节。
- 状态约 140 位（busy/write/req_accepted/resp_valid/addr/wdata/func3/rdata）。请求按地址分三类：uncached RAM（直接读写 pmem）、modeled（UART/CLINT/INTC/SD/boot，读 `PeripheralModel::read_load`）、其余走 AXI。modeled/uncached 的 CPU 侧时序：请求周期 N 接受，N+1 `resp_valid`，LSU 经 hold 在 N+2 看到，N+2 空闲。
- 保留在 testbench：`PeripheralModel`（CLINT/INTC/UART/SD/DMA/随机延迟中断，805 行），RTL 通过只读/DPI 风格的 testbench 钩子取 `read_load` 结果与 pmem 访问；其对核的时序（中断注入时刻 = `sim_time`）必须保持。
- 难度 2-3，RTL 150-200 行。
- 注意副作用：`comb_inputs` 里做 `write_uncached_ram`（pmem 写）——RTL 里必须在时钟沿做，不能在组合里。

### 2.5 AXI 互连 `AXI_Interconnect`（`K/axi_interconnect/AXI_Interconnect.cpp` 3699 行；每 tick 1 次）
- 主口：read[0]=ICACHE、read[1]=DCACHE_R、read[2]=UNCORE_LSU_R（**不用**）、read[3]=EXTRA_R（外设，bypass）；write[0]=DCACHE_W、write[1]=EXTRA_W（外设，bypass）。从口：DDR（256b beat，6b id）、MMIO。**默认构建 `AXI_KIT_DDR_BASE=0`，`axi_dual_port_is_ddr_addr` 恒真，所有流量走 DDR 口，MMIO 口不可达** **[读码，未运行验证]**（与 docs 里"≥0x4000_0000 走 DDR"不符，文档与默认值均已过期：docs 写 8 MB/lookup 8/MSHR 4，实际 4 MB/3/8）。
- 每 tick 三段：`comb_outputs`（`prepare_llc_inputs(false); llc.comb(); comb_read_response; comb_write_response; 计算 req.ready/accepted`）、`comb_inputs`（`comb_read_arbiter(1779-2207) → comb_write_request(2249-2498) → prepare_llc_inputs(true) → llc.comb()`）、`seq`（~1000 行：AR 握手、capture→core-stage 派发、R 握手、LLC 读响应→边界寄存器、写响应延迟队列、LLC 内存写发射、`llc.seq()`）。**LLC 的 `comb()` 每 tick 调用两次**（第二次的 `reg_write` 才是次态；两次 `ext_out.mem.*` 是否恒等 [未验证]）。
- 状态大头：`r_pending`（≤32，含数据）、`llc_upstream_write_q`、`llc_core_req_stage_`（含 512b 写数据）、`llc_read_resp_data_[4]`。
- **CPU 侧视图**（对 icache、外设这两个非 dcache 主口）：16 tick 里主口输入只在 tick 0 有效（其余被 `mask_axi_cpu_boundary_for_internal_tick` 清零），`ready` 取 16 tick 的 OR、`accepted` 粘滞（id 取最后一次）、`resp.*` 取最后一个 tick 的值，且**同 id 响应在 accepted 首次出现的那个 CPU 周期被抑制**（`RV:560-612`）。→ RTL 需要一个 `axi_cpu_port_adapter`（150-250 行）。DCache 主口不经此适配，每 tick 直连。
- 死代码：non-LLC 路径整套（`IC:2054-2206, 2445-2571, 3371-3585` 及配套）、MMIO 分支、runtime mode/maintenance（`IC:648-790`）、reconfig、`AXI_Router_AXI4.cpp` 整体、全部 printf/perf 计数（`AXI_LLCPerfCounters_t` 38 个）。

### 2.6 AXI_LLC（`AXI_LLC.cpp` 3321 行 + 4 张表）
- 默认：4 MB、16 路、64 B 行、4096 组、MSHR 8、`lookup_latency=3`；表 data(4 MiB)/meta/valid/repl，**RTL 最小位宽**：data 32 Mib、tag 14b+dirty 1b/路、valid 1b/路、repl 4b/组（轮转）。
- `comb()` 内固定阶段链（就地修改 `reg_write`/`table_out`，部分阶段读旧 `regs`、部分读 `reg_write`——翻译时必须逐处区分）：`drive_read_responses → drive_write_path(~400 行) → try_complete_lookup(~775 行) → drive_mem_read_path(~320 行) → try_launch_pending_write_lookup → accept_new_requests → drive_lookup_request`。单 lookup 引擎、8 个 MSHR（refill 512b + victim 512b + 控制）、2 个 write ctx、全局 victim_wb 槽。`AXI_LLC_Regs_t` sizeof 60,368 B，其中 `read_resp_q_data[4][32]`(32 KiB) 与 `write_q`(9 KiB) 深度 32 远大于实际占用（需 tap 统计后裁剪）。
- **表读延迟不是普通 SRAM 流水**：请求 tick t 置 `table_out.enable`，t+3 的 `comb_outputs` 才一次性交付 `lookup_in`，**读取发生在交付 tick**（含 t..t+2 之间的写入）。RTL 精确做法：用 2 级计数器携带 index，在 t+2 末尾发起同步读（t+3 出数），并对同 tick 同 set 的写做写穿旁路（是否有此场景 [未验证]，需用 tap 统计）。
- 死代码：预取（`1166-1309` 及所有 `is_prefetch_lookup` 分支）、NOALLOC(`2568-2594`)、direct_mapped、`invalidate_all`/maintenance、mode2、全部 debug/perf。

## 3. 建议的 RTL 模块划分、行数与难度

| # | 模块（目录 `rtl/memsys/<mod>`）| C++ 来源（行）| RTL 估计 | 难度 | 风险点 | 域 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `dcache`（顶层）= `dcache_arr`(tag/valid/dirty/plru/data 阵列 + 读口 + 填充快照 + 写口) + `dcache_s1`(bank 授权、bank retry、s1s2 寄存) + `dcache_s2`(hit/miss/replay 决策、LRU、pendingwrite、fill_write) + `dcache_mshr` + `dcache_wb` + `dcache_resp_latch`(raw 捕获/fill 转发/发布) | RealDcache 774 + MSHR 307 + WB 219 + DcacheConfig 247 + MemSubsystem 的 dcache_domain 部分 ~250 | 1800-2300 | 4 | 8 读口 + 同拍 AXI→MSHR→find/free 的依赖链；填充/store 合并怪行为；响应 pending 累积 | tick |
| 2 | `mem_route`（MemRouteBlock）| 147 | ~200 | 2 | 优先级与 `issued_tags` 防连发 | cpu |
| 3 | `ptw_walk`（含 `ptw_pte_check`）| MemPtwBlock 活的部分 ~500 | 250-350 | 3 | 同拍 select→issue 组合路径；flush 在 seq 覆盖一切；credit 位宽 | cpu |
| 4 | `peripheral_axi` | 264 | 150-200 | 2-3 | 地址分类优先级、顶层 hold 寄存器 | cpu |
| 5 | `axi_cpu_port_adapter` | RV:495-646 | 150-250 | 3 | 抑制规则 | cpu↔tick |
| 6 | `ic_read_front` / `ic_write_front` / `ic_axi_down` / `hazard` | AXI_Interconnect 活代码 ~2500 | 1700-2700 | 4 | ready-first、同拍 accept 的 dcache 例外、两次 LLC comb | tick |
| 7 | `llc_ctrl` | AXI_LLC 活代码 ~2000 | 2500-3500 | **5** | 阶段链的 `regs`/`reg_write` 混读；`table_out` 互斥 | tick |
| 8 | `llc_tables` | MemSubsystem.cpp:44-247 + GenericTable | 300-500 | 3 | 3-tick 读延迟的精确建模 | tick |

总量 ~7-10k 行 SV（C++ 活代码约 10k 行，去 debug/perf/死代码后）。留在 testbench：SimDDR（读延迟 `CONFIG_SIM_DDR_LATENCY=60`，**单位是 AXI tick**）、MMIO/UART、PhysMemory、PeripheralModel、DMA、difftest。

### 翻译顺序与并行分工建议
- **第 0 步（我已做）**：DCache 域 tick 级 tap。
- **可立即并行（互相独立）**：
  - **A 组（1-2 人）`dcache`**：最关键、最重。可拆 A1 = 阵列+s1+s2（核心命中/替换/重放），A2 = MSHR + WB + resp_latch；但两者边界耦合紧（find/free/fill 在同 tick 组合依赖），建议 **同一人先出整体再拆文件**，或先做 A2 以 `dcache_mshr`/`dcache_wb` 各自的 spec 做 tick 级回放（它们边界清晰：MSHR 输入 `{find_req[8], mshr_req[8], fill_resp, AXI}`、输出 `{free, find_resp[8], fill_req, AXI}`，需要补 tap）。
  - **B 组 `mem_route` + `ptw_walk`**（CPU 周期，最易闭合，可用现有"每 CPU 周期一条记录"的 harness，不需 16 tick 外壳）：需要第二轮 tap（路由输入/输出、PTW 输入/反馈/输出，位置见调研：`MemSubsystem.cpp:1087/1090/1106/1160/1228/1253`）。
  - **C 组 `peripheral_axi`**：小，可与 B 同一人。
- **后续（依赖 tick 外壳与 AXI tap）**：D `axi_cpu_port_adapter` + 互连读/写前端；E `llc_ctrl` + `llc_tables`（2 人，最重）。互连+LLC 的 DUT 边界在"各主口 ↔ DDR 从口 + 表口"，DDR/MMIO/DCache/ICache 都在 testbench 里，只靠录制的输入驱动。
- 集成顺序：dcache 先与 C++ 路由/互连混合（RTL 插件只替换 DCache 域并锁步比较），再接 mem_route/ptw，最后互连+LLC。

## 4. 16 倍频（FREQ_DIV）的 RTL 表达

**方案：单时钟 `clk`（= 内部 tick 时钟，快时钟）+ CPU 相位使能。**
- 相位计数 `phase ∈ [0,15]`，`cpu_en = (phase==0)`（tick 0）。CPU 域状态（路由、PTW、外设、LSU 侧全部后端/前端）仅在 `cpu_en` 的沿更新；快域（DCache 域、互连、LLC）每个 `clk` 更新。
- 与 C++ 一一对应：tick 0 的 seq 与 CPU seq 同一沿（`RV:1119-1156`），随后 15 个 tick 仅快域推进。**不用真异步 16:1 时钟 + CDC**（C++ 是严格整数同步，CDC 不精确、无收益）；不用门控时钟（仅物理实现差异）；不在一个 CPU 周期内组合展开 16 tick。
- 非 DCache 主口（ICache、外设）的 `valid`/`resp.ready` 只在 `phase==0` 通过；`ready`/`accepted` 在 `axi_cpu_port_adapter` 累加并在 15→0 边界交给 CPU 域。
- DCache 域：LSU 请求输入仅在 `phase==0` 有效，其余 tick 内部看到空请求；`resp_pub` 在 tick 0 发布并清空 pending 累积器（对应 `MemSubsystem::seq` 里的 `clear_pending_dcache_response`）。
- 整核集成时后端/前端 RTL 的时钟使能 = `cpu_en`（它们的"一个 CPU 周期一次 clk 沿"语义不变，只是 `clk_en` 门控）。**对已翻译模块不需要改**：仿真中仍然每 CPU 周期给它们一个时钟沿即可；只有访存域需要见到 16 个沿。
- Verilator 开销：访存域每 CPU 周期 16 次 eval（LLC 4 MiB 数据阵列按存储器写法，不影响 eval 速度）。

## 5. 大存储器怎么写（01 §3.1）

- **DCache 阵列**：tag/valid/dirty `[256][4]` 寄存器堆式（`bpu_mem` 同步写异步读原语）；PLRU `[256]×3b`；data 按 16 bank × 4 路 × 16 深 × 512b 行，**填充行写 + store 字写（strobe）是两个写口**，每 bank/路各自一条 `if (we) mem[addr] <= ...`；store 字写用 `wstrb` 展开为 byte 使能。读：异步，地址 = `s1s2.slot.addr`；每路读一个字（`word_off` 选）。填充快照读是第 9 个读口（整组 4 路）。
- **MSHR/WB 表**（8 项，含 512b 数据）：不为整表建 `_d`；按项写使能；WB 用读写指针；保持槽单独寄存器。MSHR 的 `merged_store_data/strb` 每项 16 字——合并写按（项, 字）粒度。
- **LLC**：data 16 个 way-bank × 4096×512b（way 粒度写使能）；meta 4096×(16×15b)、valid 4096×16b、repl 4096×4b。读时序按 §2.6（2 级延迟 + 交付 tick 同步读 + 写穿旁路）。**LLC 阵列写在每 tick 的 `seq`**，读与写互斥（`table_out` busy）。

## 6. 配置/死代码核对表（默认 config）

| 项 | 状态 | 依据 |
| --- | --- | --- |
| `CONFIG_AXI_SUBSYSTEM_FREQ_DIV=16`、`CONFIG_DCACHE_FAST_DOMAIN=16` | 生效 | `config.h:241`、`RV:29-34` |
| `CONFIG_AXI_LLC_ENABLE=1`（4 MB/16 路/MSHR 8/lookup 3）| 生效 | `config.h:262-280` |
| `CONFIG_ICACHE_USE_AXI_MEM_PORT=1` | 生效（icache 直接绑 `read_ports[0]`）| `RV:996` |
| `BSD_CONFIG` | 0：`#if !BSD_CONFIG` 块生效，但几乎全是 perf | `IO.h`、`RealDcache.cpp` |
| `MemSubsystem.internal_axi_runtime_active_` | **false**（顶层共享 AXI）：`MemSubsystem::comb_outputs` 里的内部 interconnect/ddr 路径不执行 | `RV:992` `set_internal_axi_runtime_active(false)` **[读码]** |
| PTW mem-client / `PtwWalker` / `PtwCompactCoreKernel.h` | 死 | 调研 §1/§4 |
| `AXI_Router_AXI4`、MMIO 下游口、non-LLC 路径、runtime mode、prefetch、noalloc | 死 | 调研 §4 |
| `AXI_KIT_DDR_BASE=0` | 所有地址走 DDR 口 | **[读码，未运行验证]** |

## 7. 边界信号的"谁读谁"速查

- DCache 域 → LSU：`resp_pub`（经路由）；`mshr_fill`（路由读，用于唤醒 PTW 等待者与 icache 路径）；`mshr_fill_addr`（`RealLsu.cpp:43,74` 读，唤醒同行 LDQ/STQ 项）。
- LSU → DCache：8 个口的请求 + `req_id`；`req_id` 最高位 1 表示路由块发起（PTW/ICache）。
- DCache 域 ↔ 互连：`mshr_*`↔`read_ports[1]`；`wb_*`↔`write_ports[0]`（**每 tick 直连**，读口允许同 tick accept：`allow_same_cycle_accept=(master==MASTER_DCACHE_R)`）。
- 外设：LSU `peripheral_req/resp` ↔ PeripheralAxi ↔ `read_ports[3]`/`write_ports[1]`；中断注入 `csr_interrupt_inject` 来自 testbench 模型。

## 8. 录制点设计（已实现）与后续

**已实现（`memsys-record-hook.patch`，详见 `memsys-record-hook.md`）**：`MemTap`（`MemSubSystem/include/memsys_tap.h`）：16 个 tick 槽，每槽记录 DCache 域边界（上表）。填充点：`dcache_domain_comb_outputs` 入口（AXI 输入）、`dcache_domain_comb_inputs` 末尾（请求、AXI 输出）、`comb_outputs` 的 publish 之后（`resp_pub`，tick 0）；`cycle()` 每拍把 `cur` 置 0，extra tick 循环里置 tick 号；周期末调用环境变量 `TTG_REC_END` 指定插件的 `ttg_rec_cycle_end`（16 个 tick 一次交付）。`TTG_REC_END` 未设置时 `g_ttg_ms_tap.on=false`，所有钩子是单个 bool 判断。
**验证 [已验证]**：补丁副本 vs `refsim_tap`：dcache-mshr-pressure(193 拍)、dcache-conflict-writeback(896)、memory-stress(1,541,195 拍，IPC 4.837140) 的**全部输出（含周期数、IPC、所有统计）逐字节一致**；每拍 16 个 tick 槽均被填充，LSU 请求只出现在 tick 0。补丁对 `refsim_tap` 的 `patch -p1 --dry-run` 无冲突。

**锁步外壳（尚未做，下一步）**：生成的 `<mod>_lock.cpp` 每次调用比较一条记录。DCache 域 spec 写成 `@ TTG_MS.t[TTG_MS.cur].<字段>`，再用 `EXTRA_CPP` 注入一个 `ttg_rec_cycle_end`，对 `t=0..15` 设 `TTG_MS.cur=t` 后调用生成的 `ttg_rec_cycle` 16 次（同一动态库里两个符号，不用改 scripts）；用 `BUILD_ONLY=1 bash scripts/lockstep.sh` 建动态库，再自己用 `TTG_REC_END=<dylib> build/simulator <prog>` 运行（`lockstep.sh` 自身固定设 `TTG_REC`，不能直接跑）。RTL 顶层需要 `cpu_phase0` 输入（= `TTG_MS.cur==0`，也可让 RTL 自带相位计数器）。**[未验证]**：生成的 lock.cpp 对重复调用、`cycle` 参数的处理，需在第一次接线时确认。

**第二轮 tap（B 组需要）**：MemRouteBlock 输入/输出（`mem_route_block.in/out` 全部，tick 0 end-of-cycle 即可读）、PTW 端口（调研列出的 `MemSubsystem.cpp:1087/1090/1106/1160/1228/1253`）、PeripheralAxi（`peripheral_req/resp`、AXI 口、hold 寄存器前后值）。以及互连/LLC tap（每 tick 的主口输入输出、表口、`lookup_in`，调研 §8 的表）。这些都能在同一个 `MemTapTick` 里扩字段。

## 9. 状态与风险

- 本阶段**没有翻译 RTL**。原因：(1) DCache 域的锁步需要 16 tick 外壳（新的验证基础设施，需要先确认 harness 行为）；(2) 评估后 DCache 域是 ~2000 行、依赖链复杂的块，值得先由分工后的专人做，而不是在分析阶段赶工；(3) PTW/路由/外设需第二轮 tap。
- **风险**：(a) tick 内 comb 就地修改 nxt 的顺序必须逐处保持（MSHR/WB/LLC）；(b) LLC 表读延迟与同 set 写的交互 [未验证]；(c) `AXI_Interconnect` 对 icache 的"同 id 响应抑制"与 ready-first 是 cpu 边界适配逻辑，ICache RTL 已按"CPU 边界视图"录制（`icache-boundary.md` §6），两处需保持一致；(d) `PeripheralAxi` 经 hold 寄存器的一拍延迟；(e) DDR 模型延迟单位是 AXI tick，testbench DDR 必须每 tick 推进。
- **对共享脚本的需求**：(1) `lockstep.sh` 增加 `TTG_REC_END` 运行模式（或允许 `PLUG_ENV` 覆盖环境变量名）；(2) 一个"多 tick 记录"的 iogen 选项（`@` 表达式里可用 tick 下标，生成器在 `ttg_rec_cycle_end` 内循环 N 次）；(3) `scripts/refsim_setup.sh` 合入 `memsys-record-hook.patch`（`refsim_tap` 由协调者合并）。
