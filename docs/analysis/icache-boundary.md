# ICache（含 ITLB 与访存侧接口）模块边界、结构与翻译方案（分析报告）

> 基线：参考模型 `baseline-sim/src`（`2f31e8d`），默认配置（`include/config.h.default`、`FRONTEND_ICACHE_MODE=0`）。
> 行号指 `front-end/icache/` 下原文件（`icache.cpp`、`ICacheTop.cpp`、`icache_module.cpp`、`include/icache_module.h`）与 `front-end/front_top.cpp`。
> 标注 **[已验证]** 的结论来自实验（第二个录制点 `TTG_IC` + 覆盖插件 `docs/analysis/tools/icov.cpp`，68 个程序 × ≤20 万拍 = 125 万拍，
> 原始汇总 `docs/analysis/data/icache_coverage_68prog_200kcyc.txt`；`ICACHE_KERNEL_CHECK` 等价性实验，第 2 节）；
> **[未核实]** 是只读代码得出的。录制点补丁与用法见 `icache-record-hook.md`、`icache-record-hook.patch`。
> 上游文档：`frontend-boundary.md`（S2/S6/S7、§3.5、§4.7）、`frontend-record-hook.md`、`tlb_mmu.md`。

## 0. 摘要

1. ICache = **一个 FSM（`icache_module_n::ICache`，5 个状态，实际可达 4 个）+ 三张表（tag/valid/data，64 组 × 8 路 × 64B 行，寄存器堆式零延迟读）+ 一个 ITLB（`TlbMmu`，64 项，复用 `tlb_mmu_core`）+ 取指组切片胶合**。
   默认配置 `ICACHE_LOOKUP_LATENCY=0`，"SRAM 延迟查表"那一半（`lookup_pending_r`、`lookup_pc_r`、`lookup_index_r`、`req_index_r` 的独立存储）整体是死代码（第 7 节）。
2. `ICacheCompactKernel.h`（2373 行）、`ICacheLookupMetaPackKernel.h`、`ICacheTopTrueGlueKernel.h` 是**机器生成的位级布尔网表**，是 `comb_core`/`eval_true_glue` 的打包版，**真正生效**（`CONFIG_QM3_ICACHE_USE_NATIVE_GENERATOR=0`，`comb_via_compact_io_generator` 用内核输出，`comb_core` 只在一份拷贝上跑来算 perf）。
   [已验证] 在 `refsim_k`（副本里加了对拍）里把内核输出与原生 `comb_core` 输出逐字段比较（输出、表写口、全部寄存器写回），smc-div 与 dhrystone **跑完全程**（1176 万次 comb 调用）0 不一致；
   **翻译以可读的 `eval_state_machine`/`lookup` 为准**，整程序锁步是最终裁判。
3. 一次 CPU 周期里 `icache_comb_calc` 被调用 **1 次，谓词预译码冲刷拍调用 2 次**（第二次 `invalidate_req`；125 万拍里 3267 次，占 0.26%，68 个程序全部出现 **[已验证]**）。
   每次调用都"求值 + 推进状态"（comb+seq 熔合）。**第 5 节**给出合并规则：`R2 = invalidate ? K(R1) : R1`，`R1 = kill ? K(R0) : N(R0)`，其中 `K` 是"杀死流水"（`refetch=1, flush=0`）的小函数；
   前端可见输出取第一步，存储侧输出（AXI 请求、DCache 探针请求、`mem_resp_ready`）取**最后一步**。一次组合网络 + 一次寄存器更新，无二次推进。
4. 存储侧端口录制点：第二个 tap（`FrontIcTap`/`TTG_IC`）在 `icache_comb_calc` 求值时刻拷出 AXI 读口视图、DCache 探针响应、ITLB 看到的 PTW 口值，以及最后一次调用之后端口上留下的输出。**加 tap 后周期数不变**（smc-div 8996 拍、dhrystone 3,911,612 拍、`front.out` 逐拍哈希一致 **[已验证]**）。
5. 三个"没想到"的参考模型行为（RTL 按参考实现，已登记）：(a) 冲刷拍的 `K` 在 `SWAP_IN` 状态会**重新发 DCache 探针请求**（第 5.4 节）；(b) ITLB 在 `req_valid_r` 为真时**每拍**被查询，哪怕 FSM 在 `SWAP_IN` 等待（第 4.3 节）；
   (c) 取指 `paddr < 0x40000000` 走"单字、旁路"的非缓存读（`mem_req_bypass`、`total_size=3`），不填 cache（实测 820 次、68 个程序全部出现）。
6. 覆盖盲区（真实程序）见第 10 节：冲刷拍里 FSM 处于 `SWAP_IN` 只有 2 次；ITLB 非直通翻译只有 `vm_sum_fetch_test` 一个程序（4 次 PTW 请求、13 次 RETRY、1 次 FAULT）；`fence.i` 3 个程序；`itlb_flush` 9 次。必须靠随机生成器补。

## 1. 在前端周期里的位置

`front_comb_calc`（S2/S6/S12，`front_top.cpp`）对 ICache 的调用，一个周期内按顺序：

| # | 位置 | 调用 | 作用 |
| --- | --- | --- | --- |
| 1 | 1207 | `icache_peek_ready(&icache_in,&icache_out)` | **只读**：`icache_ready = !hold && ifu_req_ready_r && !busy && 上一次comb的ifu_req_ready`，`hold = itlb_flush\|fence_i\|invalidate_req`（此时 `invalidate_req=false`）。读使能 `fetch_addr_fifo_read_enable_slot0` 用它 |
| 2 | 1544 | `icache_comb_calc(&icache_in,&icache_out)` | 主调用：`icache_in = {reset, refetch=global_refetch, itlb_flush, fence_i, invalidate_req=0, icache_read_valid, fetch_address, csr_status}`。**求值并推进状态** |
| 3 | 1870 | `icache_comb_calc(&invalidate_req_in,&icache_out)`，仅 `do_predecode_flush` | `invalidate_req_in` 是 `memset 0` 后只置 `invalidate_req=1`、`csr_status`：`reset=refetch=itlb_flush=fence_i=0`、`icache_read_valid=0`、`fetch_address=0` |

- `icache_out`（第 2 次调用的结果）里前端读到的只有 `icache_read_complete`、`fetch_group[8]`、`page_fault_inst[8]`、`inst_valid[8]`、`fetch_pc`（S7/S8，1576–1696）。第 3 次调用在这些读取**之后**，它的 `icache_out` 被丢弃；
  perf 用的 `perf_*` 不翻译。`icache_read_ready`（主调用的）只喂 perf，前端用的是第 1 步 peek 的值。
- 调用顺序：**ICache 在 `axi_subsystem_comb_outputs`/`mem_subsystem.comb_outputs` 之前**求值（1089 行），所以它读到的 AXI/DCache 端口值是"上一拍末/本拍 comb_outputs 之前"留下的（第 6 节），它写进端口的请求供后面的 `comb_inputs` 使用。
- 第 3 次调用的端口输入值与第 2 次**完全相同**（`ReadMasterPort_t` 的 `req.ready/accepted/resp.*`、DCache 探针响应在两次调用之间没人写；`comb_accept` 只写 `req.valid/addr/total_size/id/bypass` 与 `resp.ready`，ICache 自己不读它们）。

## 2. 功能分解与硬件结构

```
 fetch_address FIFO 读出的 (req_valid, pc) ──┐                                 ┌─► read_complete / fetch_pc / fetch_group[8] / inst_valid / page_fault  (→ 指令 FIFO)
 refetch, fence_i, invalidate ──► kill ──────┤                                 │
                                             ▼                                 │
 itlb_flush ─► ITLB (tlb_mmu_core, FETCH=1) ◄ mmu_req(valid,vtag) ── icache_ctl (FSM) ───► AXI 读请求/mem_resp_ready, DCache 字探针请求
   ▲  PTW 走表口(req_ready/resp, req/consumed/flush)  │ ppn,ppn_valid,page_fault ┘ ▲ │ ▲ DCache 探针响应, AXI 响应(+16 字行)
   └──────────────────────────────────────────────────────────────────────────────┘ │
                                  tag/valid/data 阵列（icache_arr）◄─ 读 set / 命中比较 ┘ └─► 表写口 (we,way,index,line,tag) / invalidate_all
```

| 子部件 | C++ | 职责 |
| --- | --- | --- |
| `icache_arr` | `icache.cpp`（`GenericTable` ×3，`RegfileTablePolicy`）、`ICacheLookupMetaPackKernel.h` | 64×8×{tag 20b, valid 1b, data 512b}。读口：组下标 → 8 路 tag/valid，命中比较（`compare_valid`、`compare_tag`）、`has_invalid/first_invalid`、命中路的行；写口：一路整行（data+tag+valid）；`invalidate_all` 只清 valid 位（data/tag 不动） |
| `icache_ctl` | `icache_module.cpp`：`eval_state_machine`、`lookup`、`step_dcache_probe`、`latch_mem_refill`、`finish_refill` | 请求槽（`req_valid_r/req_pc_r`）、FSM、AXI 读事务（16 个 txid 的 inflight/canceled 位图）、DCache 字探针（16 字顺序探针）、替换（有无效路选首个，否则轮转计数器 `replace_idx`） |
| `icache_kill` | 同上的 `kill_pipe` 分支 | 冲刷/重取时 FSM 的"杀死"次态；在**同一周期被用两次**（第 5 节）|
| `icache_itlb` | `ICacheTop.cpp` `comb_mmu_view`、`TlbMmu`（`Kind::ITLB`） | 把 FSM 的 `mmu_req_valid/vtag` 变成 `translate/flush/cancel`，把结果变成 `ppn/ppn_valid/page_fault`；内部复用 `tlb_mmu_core` |
| `icache_resp` | `ICacheTop.cpp` `eval_true_glue` | 把 `ifu_resp_valid/pc/rd_data[16]/page_fault/single_word` 切成 `fetch_group[8]`、`inst_valid[8]`、`page_fault_inst[8]`、`fetch_pc`，以及 `icache_ready` |
| `icache` | `ICacheTop.cpp`（`TrueICacheTopT::comb/seq`）| 顶层：只做端口适配与连线 |

配置（默认）：`ICACHE_WAY_NUM=8`、`ICACHE_SET_NUM=64`（`ICACHE_INDEX_BITS=6`）、`ICACHE_LINE_SIZE=64`（`ICACHE_WORD_NUM=16`、`ICACHE_OFFSET_BITS=6`）、`ICACHE_TAG_BITS=20`、`FETCH_WIDTH=8`、`ITLB_ENTRIES=64`，**随机替换**（实为全局轮转计数器 `replace_idx`，不是每组一个）。

## 3. 状态清单

### 3.1 FSM 寄存器（`ICache_regs_t`，默认配置下有效的）

| 寄存器 | 位宽 | 说明 | 复位（`ICache()`/`reset()`）|
| --- | --- | --- | --- |
| `req_valid_r`、`req_pc_r` | 1+32 | 已登记的取指请求。`req_index_r` = `req_pc_r[11:6]`（内核解码时由 pc 重算，C++ 的独立寄存器是冗余的）| 0、0 |
| `ifu_req_ready_r` | 1 | 下一拍 `icache_ready` 的一个因子 | **1** |
| `state` | 3 | `IDLE(0) SWAP_IN(1) WAIT_DCACHE_AFTER_MEM(2) DRAIN(3,不可达) CANCEL_WAIT_ACCEPT(4)` | IDLE |
| `mem_axi_state` | 1 | `AXI_IDLE/AXI_BUSY`。不变式：BUSY ⇒ `state==SWAP_IN`（所有离开 SWAP_IN 的转移都置 IDLE）→ RTL 可把 `(state,axi)` 编码成 5 个状态 | AXI_IDLE |
| `mem_resp_data_r[16]` | 512 | 内存响应行（只在 `WAIT_DCACHE_AFTER_MEM` 收尾时读：探针没全命中）| 0 |
| `replace_idx` | 8（取值 0..7，3 位足够）| 轮转替换指针 | 0 |
| `ppn_r` | 20 | 缺失时锁存的物理页号（重填 tag、AXI 地址、探针地址、是否非缓存）| 0 |
| `miss_txid_valid_r`、`miss_txid_r`、`miss_ready_seen_r` | 1+4+1 | 本次缺失的事务号（`alloc_free_txid`：`txid_inflight_r` 里第一个空位）| 0 |
| `txid_inflight_r[16]`、`txid_canceled_r[16]` | 16+16 | 在途事务位图 / 已作废（取消后其响应到来要丢弃）位图 | 0 |
| `dcache_probe_inflight_r/done_r/hit_r`、`dcache_probe_word_r`、`dcache_probe_data_r[16]` | 1+1+1+5(值 0..15,4 位足够)+512 | DCache 一致性字探针的进度与已取得的字 | 0 |
| `lookup_pending_r`、`lookup_pc_r`、`lookup_index_r` | — | **死**（`ICACHE_LOOKUP_LATENCY==0`）| — |

### 3.2 阵列

| 阵列 | 规模 | 读 | 写 | 说明 |
| --- | --- | --- | --- | --- |
| data | 64 组 × 8 路 × 512b = 256 Kib | 异步，1 个组下标；命中路的行（8 选 1）| 1 写口，**整路整行**（`chunk_enable[way]`）| 不复位（无效路的内容不可观察）|
| tag | 64 × 8 × 20b | 同上，8 路全读 | 1 写口，一路 | 不复位 |
| valid | 64 × 8 × 1b = 512 位 | 同上 | 一路置位；`invalidate_all`（`fence.i`）整体清零 | **必须复位为 0**（`reset()`）；`valid_table.reset()` 在 `invalidate_all` 时先于当拍写应用 |

三张表**同拍读到的是拍初内容**（`GenericTable::comb` 读 `storage_`，写在 `seq` 里）：RTL 按存储器写法（01 §3.1）：异步读 + 时钟沿写，valid 位用带整体清零的寄存器向量。
读使能：`data_read.enable = !reset && !global_refetch && (icache_read_valid || req_valid_r || lookup_pending_r)`，读地址 = `req_valid_r ? req_pc_r[11:6] : fetch_address[11:6]`。读使能为假时 `meta_resp_valid=0`，FSM 会把"没有表响应"当作未命中且 `has_invalid=0`（`capture_lookup_meta_result` 早退）。

### 3.3 ITLB（`TlbMmu`，`Kind::ITLB`）

状态与 DTLB 完全相同（`tlb_mmu.md` §2）：`entry_valid_q[64]`、`entry_q[64]`（59b）、`repl_q`、`walk_q`。`FETCH=1`、`LANES=1`、`ENTRIES=64`。
调用语义（`comb_mmu_view`，每次 `icache_comb_calc` 一次）：`context_flush = itlb_flush → flush()`；`cancel_pending = refetch(global) → cancel_pending_walk()`；`translate_valid = !refetch && mmu_req_valid → translate(vaddr = {vtag,12'b0}, type=0)`。
与 DTLB 路径的差别和风险见第 9 节。

## 4. 一拍内的数据流（主调用）

`TrueICacheTopT::comb()`（`ICacheTop.cpp` 约 890–1030）的求值顺序（`in->reset` 路径不在录制窗口内）：

```
 cancel_pending_req = refetch | invalidate_req | fence_i       # 给 FSM 的 "refetch"（kill）
 pass1: refresh_lookup_meta_input; comb_lookup_meta()          # 以 ppn_valid=0 求 FSM → 只为得到 mmu_req_valid / mmu_req_vtag
 ITLB:  flush?(itlb_flush) ; cancel?(refetch) ; translate?(!refetch && mmu_req_valid)
 pass2: comb_lookup_meta()  (ppn 已知)  → 得到 lookup_data_req_valid/index/way
 pass3: refresh_lookup_data_input; comb_lookup_data()          # 最终结果（data 阶段放开）
 comb_accept(mem_req_*, mem_resp_ready) ; drive_dcache_probe_req_port(dcache_req_*)
 glue: icache_read_complete/fetch_group/... = eval_true_glue(上述 FSM 输出)
 seq(): icache_hw.seq() (regs ← reg_write) ; ITLB seq() ; 表写在 icache_comb_calc 里 seq() 之后立即应用
```

### 4.1 三遍 comb 的真正含义（可折成一遍）

三遍都是 `(regs, inputs, lookup_in)` 的**纯函数**（`seq()` 才改寄存器）。pass1/pass2/pass3 的差别只有 `ppn/ppn_valid/page_fault` 与"data 阶段是否放开"：
- pass1 只被取用 `mmu_req_valid/vtag`（不依赖 ITLB 结果，故无组合环：下一节 4.3）；
- 零延迟查表下 pass2 恒得到 `lookup_data_req_valid == 命中`，pass3 的数据阶段因此恒就绪（`data_snapshot_valid` 与 `meta_resp_valid` 同源于读使能，下标一致）→ **"命中 ⇒ 数据就绪"**，`lookup_data_req_*`、`lookup_data_ready` 的"命中但数据未就绪"分支死（`req_ready_w=false; state_next=IDLE` 的两个分支，8 个 `lookup_data_*` 输出不翻译）。
RTL 只实现 pass3 一套逻辑 + pass1 的 `mmu_req` 小函数。

### 4.2 FSM 一步（`N(R0)`；非 kill）逐状态

记号：`kill = refetch|fence_i|invalidate`（FSM 的 `io.in.refetch`）；`resp_id = mem_resp_id`；
`canceled_resp = mem_resp_valid && canceled[resp_id]`；
`active_resp = mem_resp_valid && miss_txid_valid && resp_id==miss_txid && (inflight[resp_id] || 同拍接受) && !canceled_resp`（同拍接受 = `state==SWAP_IN && axi==IDLE && mem_req_accepted && accepted_id==miss_txid`）；
`orphan_resp = mem_resp_valid && !active_resp && !canceled_resp && !inflight[resp_id]`。
序言（任何状态，包括 kill）：`canceled_resp || orphan_resp` ⇒ `mem_resp_ready=1`、`canceled[resp_id]<=0`、`inflight[resp_id]<=0`。

| 状态 | 非 kill 行为 |
| --- | --- |
| `IDLE` | **快速通路**（`!req_valid_r && ifu_req_valid && ppn_valid`）：`page_fault` ⇒ 响应（`rd_data=0`、`ifu_page_fault`）；命中 ⇒ 响应（`resp_pc = in.pc`）；**未命中 ⇒ 不响应**，落到末尾 `else req_ready=1`，由 `lookup()` 把请求登记（`req_valid_r<=1, req_pc_r<=pc`）。<br>**登记通路**（`req_valid_r && ppn_valid`）：`page_fault` ⇒ 响应；命中 ⇒ 响应（`resp_pc=req_pc_r`）；未命中 ⇒ 取 txid（`miss_txid_valid_r ? miss_txid_r : alloc_free_txid`），无空位 ⇒ 保持（`req_ready=0`）；否则 `ppn_r<=ppn`、探针寄存器清零、`miss_txid_valid<=1`、`ready_seen<=0`、`state<=SWAP_IN`。<br>`req_valid_r && !ppn_valid`（ITLB 还在走表）⇒ `req_ready=0`，保持。`ppn_ready = req_valid_r`（命中/未命中拍 `ppn_r<=ppn`）|
| `SWAP_IN` | 先 `step_dcache_probe()`（探针推进一步）。`axi==IDLE`：`accepted && accepted_id==miss_txid` ⇒ 不再发请求；若 `active_resp`（响应同拍到）⇒ `latch_mem_refill` + 第二次探针 + 完成或进 `WAIT_DCACHE_AFTER_MEM`；否则 `axi<=BUSY`、`inflight[txid]<=1`。未被接受 ⇒ `mem_req_valid=1`（地址/总大小/旁路/id 见下）。`ready_seen` 在 `axi==IDLE && mem_req_ready && miss_txid_valid` 时置位。<br>`axi==BUSY`：`mem_resp_ready=active_resp`；`active_resp` ⇒ `latch_mem_refill`，探针没完 ⇒ `WAIT_DCACHE_AFTER_MEM`，否则 `finish_refill` |
| `WAIT_DCACHE_AFTER_MEM` | `step_dcache_probe()`；没完 ⇒ 等（`req_ready=0`）；完 ⇒ `finish_refill(hit ? 探针行 : mem_resp_data_r, replace_idx)` |
| `CANCEL_WAIT_ACCEPT` | `mem_resp_ready=1`；若 `accepted && miss_txid_valid && accepted_id==miss_txid` ⇒ `canceled[txid]<=1; inflight[txid]<=1`；下一状态 `IDLE`，清 `miss_txid_valid/ready_seen/探针`，`req_ready=1` |
| `DRAIN` | 不可达（没有任何转移进入）|

`finish_refill(line, way)`：`state<=IDLE; axi<=IDLE`；`miss_txid_valid` 则 `inflight[miss_txid]<=0`；清 `miss_txid_valid/ready_seen/探针寄存器`；非单字（缓存）时**写表**（`index=req_index, way, data=line, tag=ppn_r, valid=1`）；`ifu_resp_valid=1, single_word, rd_data=line`；`req_ready=1`。
`latch_mem_refill`：`mem_resp_data_w`（缓存请求取 16 字；非缓存请求只把 `mem_resp_data[0]` 放在 `(req_pc_r&63)/4` 号字）；`replace_idx_next = 非缓存 ? replace_idx : (有无效路 ? 首个无效路 : (replace_idx+1)%8)`；
SWAP_IN 里 `mem_gnt` 时 `mem_resp_data_r<=mem_resp_data_w; replace_idx<=replace_idx_next`。注意**写入的路是新值 `replace_idx_next`**。
`step_dcache_probe`：非缓存请求直接 `done`；否则若 `!done && !inflight && word<16 && req_valid_r` ⇒ `dcache_req_valid=1, addr = 行基址 + 4*word`、`inflight<=1`；`inflight && dc_resp_valid`：`retry` ⇒ 重发；`miss` ⇒ `done, hit=0`；命中 ⇒ 存字，`word+1`，满 16 ⇒ `done`。`hit` 只表示"探针整行命中"，此时用探针行代替内存行（自修改代码一致性，`smc-*` 测试）。
输出默认值（每个状态）：`mem_req_addr = 非缓存 ? {ppn_r,req_pc_r[11:0]} : {ppn_r, req_index, 6'b0}`、`total_size = 非缓存 ? 3 : 63`、`bypass = 非缓存`、`mem_req_id = miss_txid_valid ? miss_txid : 0`（`SWAP_IN&&axi==IDLE` 时 `=miss_txid`）；"非缓存" = `{ppn_r,req_pc_r[11:0]} < 0x40000000` 即 `ppn_r[19:18]==0`。
**请求槽更新（`lookup()`）**：`kill` ⇒ `req_valid<=0, ifu_req_ready_r<=0`（早退）；快速通路命中/缺页 ⇒ `req_valid<=0, ifu_req_ready_r<=1`；否则 `can_accept = ifu_req_valid && req_ready_w && slot_idle`（`slot_idle = !req_valid_r && state==IDLE && axi==IDLE && !miss_txid_valid_r`）⇒ `req_valid<=1, req_pc<=pc`；`else if (req_ready_w) req_valid<=0`；`ifu_req_ready_r <= req_ready_w && !req_valid_next`。

### 4.3 mmu_req（pass1）与 ITLB

`mmu_req_valid`（pass1，`ppn_valid=0,page_fault=0`）：`kill` ⇒ 0；否则 `(ifu_req_valid && slot_idle) || req_valid_r`（前一项 vtag = `pc[31:12]`，后一项 `req_pc_r[31:12]`，前者优先）。
**注意** `req_valid_r` 为真时不论 FSM 在哪个状态（含 `SWAP_IN` 等内存）都发 ITLB 请求；ITLB 命中时无副作用，未命中时会启动/推进走表。RTL 照做（参考实现，登记）。
`translate_valid = !refetch && mmu_req_valid`，`vaddr = {vtag,12'b0}`、`type=0`（取指）。结果映射：`OK ⇒ ppn_valid=1, ppn=paddr>>12`；`FAULT ⇒ ppn_valid=1, page_fault=1`；`RETRY ⇒ ppn_valid=0`。

## 5. 难点 1：`icache_comb_calc` 熔合 comb+seq，冲刷拍被调用两次

> 协调者决定：不复刻 C++ 的调用结构，只要求每个周期在边界上**最终可观察**的行为功能等价；本节方案已定稿并实现（不需评审）。

### 5.1 这一拍里到底发生了什么

设 `R0` = 拍初 FSM 寄存器，`inp` = 本拍主调用的输入（`refetch, itlb_flush, fence_i, req_valid, pc` + 端口值 `P`）。

| | 第一步（主调用，正常取指步）| 第二步（`invalidate_req`，仅 `do_predecode_flush`）|
| --- | --- | --- |
| 输入 | `refetch_g, fence_i, req_valid, pc, P` | `reset=refetch=itlb_flush=fence_i=0, req_valid=0, pc=0`，FSM 的 `kill=1, flush=0`；**`P` 与第一步相同**（端口无人更新）|
| 读 | `R0`、表（拍初内容）、ITLB | **`R1`（第一步的 `reg_write`）**；不读表、不用 ITLB 结果 |
| 写 | `R1`；表写口（重填/`invalidate_all`）；ITLB 状态（`translate`/`flush`/`cancel`）；AXI/DCache 请求端口 | `R2`；**表写口全 0**；ITLB 不被触发（`translate_valid=0`，`context_flush=cancel_pending=0`）；**覆盖** AXI/DCache 请求端口 |
| 对外可见 | `icache_read_complete/fetch_group/...`（前端在第二步之前已读走）；`icache_ready` 来自 peek | 只有存储侧端口：`mem_req_*`、`mem_resp_ready`、`dcache_req_*`（`comb_accept`/`drive_dcache_probe_req_port` 被第二步覆盖，最终留在端口上的是第二步的值）|

要点（**[已验证]** = `icov` 实验，其余读代码）：
1. 第二步不触发表写：`kill_pipe` 分支都不会 `finish_refill`，`invalidate_all = in.flush = 0`；表的 `seq` 里读使能是 `lookup_pending_r=0`，Regfile 表忽略读请求 → **表只在第一步被改**。
2. 第二步不触发 ITLB：`kill=1` 使 pass1 的 `mmu_req_valid=0`；`itlb_flush=0`、`refetch=0`。（ITLB 的 `seq()` 第二次被调用，但第一次 `seq()` 已清掉全部待提交量，第二次是空操作。）
3. 第二步的 FSM 行为 = `K(R1, P)`（"杀死"函数，第 5.2 节），与第一步里 `kill` 为真时的行为**是同一个函数**（`eval_state_machine`/`lookup` 的 kill 分支）。
4. `icache_read_complete` 等前端输出在第二步里被覆盖成 0（`icache_out` 被覆盖），但此时前端已经读完（S8 在 S12 之前）。
5. 同拍可能出现 `fence_i && invalidate`（理论上；`fence_i` 不带 `refetch` 的情形 125 万拍内 0 次 **[已验证]**，所以 `kill1 && invalidate` 的组合没有被实测，但 RTL 里按二次复合处理，不依赖这个观察）。
6. 周期数/前端行为：冲刷拍之后的下一拍 `global_refetch=1`（`predecode_refetch_q`），主调用再次进入 kill 分支。

### 5.2 `K`：杀死步（`kill=1, flush=fence_i, ifu_req_valid` 无关）

对寄存器 `R` 与端口 `P`（只有 `mem_req_ready/accepted/accepted_id/resp_valid/resp_id`、`dc_resp_*` 被用到）：
- 序言：`canceled_resp||orphan_resp` ⇒ `mem_resp_ready<=1`，`canceled[resp_id]<=0`，`inflight[resp_id]<=0`（用 `R` 的位图）；
- 按 `R.state`：
  - `IDLE`：`state<=IDLE`。
  - `SWAP_IN`：先 `step_dcache_probe()`（**会置 `dcache_req_valid`/`addr`**，原因见 5.4）；`ready_seen_now = (axi==IDLE) && mem_req_ready && miss_txid_valid`，置位 `ready_seen`；`accepted_now = (axi==IDLE) && accepted && accepted_id==miss_txid && miss_txid_valid`；
    `already_inflight = miss_txid_valid && (axi!=IDLE || accepted_now)`；`waiting_accept = miss_txid_valid && !already_inflight && (ready_seen || ready_seen_now)`；
    ① `already_inflight`：`canceled[txid]<=1; inflight[txid]<=1; state<=IDLE; miss_txid_valid<=0; ready_seen<=0; 探针清零`；
    ② `waiting_accept`：`state<=CANCEL_WAIT_ACCEPT`（`miss_txid_valid` 保持 1，`ready_seen` 保持），探针清零；
    ③ 其它：`state<=IDLE; miss_txid_valid<=0; ready_seen<=0; 探针清零`。三者 `axi<=IDLE`、`mem_req_valid=0`。
  - `WAIT_DCACHE_AFTER_MEM`：`state<=IDLE; miss_txid_valid<=0; ready_seen<=0; 探针清零; axi<=IDLE`（**不**先调 `step_dcache_probe`，不发探针请求）。
  - `CANCEL_WAIT_ACCEPT`：`mem_resp_ready<=1`；`accepted && miss_txid_valid && accepted_id==miss_txid` ⇒ `canceled[txid]<=1; inflight[txid]<=1`；`state<=IDLE; miss_txid_valid<=0; ready_seen<=0; 探针清零`。
- 收尾：`req_valid<=0`，`ifu_req_ready_r<=0`（`lookup()` 的 kill 早退）；`ppn_r`、`replace_idx`、`mem_resp_data_r`、`req_pc_r` 不变；`mem_req_valid=0`（`mem_req_addr/size/bypass/id` 取默认值，被 `when mem_req_valid` 放宽）。
- `fence_i` 额外：`invalidate_all`（表 valid 全清）。

### 5.3 合并规则（本方案）

```
 N(R0,inp)    : 正常步（kill=0）的次态与输出
 K(R,P)       : 5.2 的杀死步（不依赖表、ITLB 结果，只依赖 R 的 7 组字段 + 端口）
 kill1        = refetch_g | fence_i
 R1           = kill1 ? K(R0,P) : N(R0,inp)           # 第一步次态（前端输出也来自这一步）
 R2           = invalidate ? K(R1,P) : R1               # 冲刷拍：第二步作用在 R1 上
 mem_side_out = invalidate ? K.out(R1,P) : (kill1 ? K.out(R0,P) : N.out(R0,inp))
 front_out    = (kill1 ? 0 : N.front_out(R0,inp))       # 完成拍、fetch_group 等
 table_write  = (kill1 ? {invalidate_all=fence_i} : N.table_write)   # 第二步无表写
 ITLB         = 只看 inp（flush/cancel/translate），第二步不参与
```

即：**一次组合求值（`N` 与第一个 `K` 并列，`K(R1)` 是对 `R1` 的覆盖层）+ 一次时钟沿寄存器更新**。RTL 里没有"推进两次状态"：寄存器只在沿上写一次（`R2`），`R1` 只是组合信号。
`K` 只有 ~30 行逻辑（无表、无 ITLB、无 16 字数据通路）。`K(R1)` 读 `R1` 的字段：`state, axi, miss_txid_valid, miss_txid, ready_seen, inflight[16], canceled[16], probe(inflight,done,word), req_valid, ppn_r, req_pc` —— 这些在 `N` 里都已经是 `*_d` 组合信号，覆盖层不增加状态。

### 5.4 等价性论证

1. **第二步读的外部输入与第一步相同**：端口读视图（`comb_view`、`dcache_probe_comb_view`）读的是 `req.ready/accepted/accepted_id`、`resp.valid/id/data`、DCache `resp_*`，两次调用之间只有 `comb_accept/drive_dcache_probe_req_port` 写端口，且写的是 `req.valid/addr/total_size/id/bypass`、`resp.ready` 与 `req_valid/req_addr`——ICache 自己不读它们。→ `K` 的输入 = `(R1, P)`，`P` 与第一步同值（也由 tap 里 `mem_*` 字段每拍只录一份保证，第二步的字段 `step[1].*` 只用来调试）。
2. **第二步无副作用的外部状态**：表（第 5.1 条 1）、ITLB（条 2）。因此 `icache` 的状态只有 FSM 寄存器；表和 ITLB 的次态只由第一步决定。
3. **`K` 与第一步 kill 分支是同一函数**：`eval_state_machine` 的 `kill_pipe` 判定在 `lookup()` 与各状态分支里，完全由 `io.in.refetch` 与 `regs` 决定；`io.in.flush` 只影响 `table_write.invalidate_all` 与 `finish_refill` 里的表写判定（kill 下不可达）。
4. **输出的归属**：`icache_read_complete/fetch_group/...` 在前端 S8 被消费时是第一步的值（`icache_out` 在 S12 才被第二步覆盖）；AXI/DCache 端口在 `comb_accept`/`drive_dcache_probe_req_port` 之后不再被前端读，最终留在端口上、被后面 `comb_inputs` 读走的是**最后一次调用**的值。
   这对行为有真实影响：例如第一步在 `SWAP_IN/axi==IDLE` 发了 `mem_req_valid=1`，冲刷拍里第二步把它压成 0（请求没发出去）；第二步还可能因为 `step_dcache_probe()` **新发一条 DCache 探针请求**（参考实现行为，登记；覆盖：冲刷拍 R1 在 `SWAP_IN` 只有 2 次，必须靠随机）。
5. **没有第三次推进**：`ICacheTop::seq()` 里 `icache_hw.seq()` 与 `mmu_model->seq()` 各一次，`read_port.seq` 空函数。
6. **验证**：整程序锁步（冲刷拍 3267 次，按 R1 状态分布见第 10 节）+ 随机生成器的"冲刷拍"定向激励（驱动参考的 `icache_comb_calc` 两次调用，随机 R1 状态/端口值，覆盖 `K` 的三个 SWAP_IN 分支、CANCEL_WAIT、WAIT_DCACHE、探针请求、txid 位图变化）。
   变异：把 `K(R1)` 覆盖层去掉（只用 `R1`）、把 `K` 作用在 `R0` 而不是 `R1`、让存储侧输出取第一步，必须被抓到。

### 5.5 定稿

采用 5.3 的方案：`R2 = invalidate ? K(R1) : R1`，`K` 作为 `R1` 上的覆盖层（对"主调用刚收了新请求 / 刚进 `SWAP_IN`"的情形 `R1≠R0`，必须作用在 `R1` 上）。
冲刷拍里第一步的瞬态输出（被第二步覆盖的 AXI/DCache 请求）不复刻；边界取周期末环境实际看到的值。`K` 在 `SWAP_IN` 发探针请求这一点是**最终值**的一部分（探针请求留在端口上被 DCache 读走），所以保留。

## 6. 难点 2：存储侧端口的录制点

### 6.1 问题

现有 `TTG_FT.icache_in/icache_out`（`front_comb_calc` 里主调用之后拷出）只含前端侧信号。存储侧端口：
- AXI 读主口 `ReadMasterPort_t`（`icache_mem_read_port`）：输入 `req.ready/accepted/accepted_id`、`resp.valid/id/data[16]`；输出 `req.valid/addr/total_size/id/bypass`、`resp.ready`；
- DCache 探针口（`ICacheMemPortReq/Resp`）：输入 `resp_valid/retry/miss/data`；输出 `req_valid/addr`；
- ITLB 的 PTW 走表口（`PtwWalkPort`，适配器 `MemSubsystemPtwWalkPortAdapter`）：输入 `req_ready/resp{fault,vaddr,leaf_pte,leaf_level}`，输出 `req/resp_consumed/flush`；
这些值在 `icache_comb_calc` 求值时刻与录制钩子时刻（`back.comb()` 之后）不同（`axi_subsystem_comb_outputs`、`mem_subsystem.comb_outputs` 在前端之后才更新；ITLB 自己会改适配器的 `comb_out_`；冲刷拍里端口输出被第二步覆盖）。

### 6.2 方案（已实现，`docs/analysis/icache-record-hook.patch`）

第二个 tap `g_ttg_ic_tap`（`FrontIcTap`，宏 `TTG_IC`），与 `TTG_FT` 同风格：`front_tap.h` 加结构体；`front_top.cpp` 每拍清零；`icache.cpp`/`ICacheTop.cpp`/`icache_module.cpp` 里只写拷贝语句，全部包在 `if (g_ttg_front_tap_on)` 里。
- **输入（取第一次调用求值时刻）**：`ICacheTop::comb()` 一进来、ITLB 动作之前拷 `mem.*`（`comb_view`）、`dcache_probe.*`、`csr`、`in->*`、PTW 走表口 `comb_output()`（flush/translate 同拍时 ITLB 会改适配器，所以必须先拷）。
- **输出**：`comb_accept` 之前拷 FSM 的 `mem_req_*`/`dcache_req_*`/`mem_resp_ready`（**每次调用覆盖**，最终留下的是最后一次调用的值）；ITLB 的 PTW 输出在第一次调用的 ITLB 调用之后立刻从适配器拷（`comb_in_/seq_in_` 的镜像结构体，同 `tlb_mmu.io`）；表读请求、表写口、核内寄存器（每次调用的拍初/次态）。
- 子部件调试用：每次调用一份 `FrontIcStep`（`regs_before/regs_next`、FSM 输入输出、内核折叠后的 `meta`（`hit_valid/hit_way/has_invalid/first_invalid`）、表读/写），`step[0]` 主调用、`step[1]` 冲刷拍的第二次。
- 只读，仅 `TTG_REC` 设置时启用。**验证**：加 tap 前后周期数不变（smc-div 8996、dhrystone 3,911,612）、`front.out` 逐拍哈希一致（`docs/analysis/tools/verify.sh`）。

`FrontTap.icache_ready`（peek 值）与 `icache_out`（主调用后的拷贝）仍由现有 `TTG_FT` 提供。

## 7. 默认配置下的死代码 / 不复刻清单

| 路径 | 为何死 | 证据 |
| --- | --- | --- |
| SRAM 查表模型：`lookup_pending_r/lookup_pc_r/lookup_index_r`、`use_external_lookup` 分支、`SramTablePolicy`、`ICACHE_SRAM_*` | `ICACHE_LOOKUP_LATENCY=0`（全树无 `-D`，`ICACHE_USE_SRAM_MODEL` 默认 0）| 覆盖插件 `LOOKUP_PENDING_SEEN` 0 次 [已验证] |
| `DRAIN` 状态与 `mem_wait_must_drain_on_refetch` | 没有任何转移进入 `DRAIN` | `STATE_DRAIN_SEEN` 0 次 [已验证]；代码里 `state_next = DRAIN` 只在 `DRAIN` 自己的 case 里 |
| "命中但数据未就绪"分支（`lookup_data_req_valid`）| 第 4.1 节：命中 ⇒ 数据就绪 | 读代码 [未核实 随机]，RTL 不建 |
| `perf`、`perf_state`、`dump_*`、`icache_focus_*`、`log_*`、`std::exit(1)` 自检（`miss && resp_valid`）| 调试/统计 | — |
| `SimpleICacheTop`（`USE_IDEAL_ICACHE`）、slot1（`icache_read_valid_2`、`fetch_group_2`、`icache_read_ready_2`）| `FRONTEND_ICACHE_MODE=0` | frontend-boundary §3.4 |
| `reset` 路径（`icache_hw.reset()`、`valid_table.reset()` 的复位调用）| 录制窗口内 `in->reset` 恒 0；RTL 的复位 = `ICache()` 构造后的值 | frontend-boundary §8.3 |
| `req_index_r` 独立寄存器 | 恒 = `req_pc_r[11:6]` | 读代码（内核解码时即由 pc 重算）|
| `ICache::seq()` 的 `perf_state` 提交 | perf | — |
| `ICacheTop` 里 `icache_read_ready` 的 `module_ifu_req_ready` 项（peek）| `ifu_req_ready_r` ⇒ 上次 comb 的 `req_ready_w` | 读代码：`reg_write.ifu_req_ready_r = req_ready_w && ...`，peek 时 `io.out.ifu_req_ready` 即上一次 comb 的 `req_ready_w` |
| `txid` 全占用（`alloc_free_txid<0`）| 16 个 txid 全被取消的在途事务占满 | 实测 `txid_canceled_nonzero` 1093 拍但从未全满 [未核实 随机]；RTL **保留**该分支（代价 1 个比较器，保持行为）|

## 8. 接口规格（`spec/icache.io`）与放宽

字段（共 48 个，输入 105 B / 输出 77 B 每拍）：

| 方向 | 字段 | 备注 |
| --- | --- | --- |
| in | `refetch, itlb_flush, fence_i, invalidate, req_valid, fetch_address[32]` | `invalidate` = `do_predecode_flush`（第二次调用）|
| in | `csr_status_{satp,privilege,mstatus_{mxr,sum,mprv,mpp}}` | ITLB 读；同 `tlb_mmu.io` |
| in | `mem_req_ready, mem_req_accepted, mem_req_accepted_id[4], mem_resp_valid, mem_resp_id[4], mem_resp_data[16]×32` | AXI 读口视图（求值时刻）|
| in | `dc_resp_{valid,retry,miss,data}` | DCache 探针响应 |
| in | `ptw_walk_{req_ready, resp_valid, resp_fault, resp_vpn[20], resp_leaf_ppn[20], resp_leaf_perm[8], resp_leaf_level}` | ITLB 的 PTW 视图；同 `tlb_mmu.io`（只取有消费者的位）|
| out | `icache_ready, read_complete, fetch_pc, inst_valid[8], page_fault_inst[8], fetch_group[8]` | 后 4 个 `when read_complete` |
| out | `mem_req_valid, mem_req_addr/total_size/bypass/id (when mem_req_valid), mem_resp_ready, dc_req_valid, dc_req_addr (when dc_req_valid)` | **最后一次调用之后**端口上的值 |
| out | `ptw_walk_req_valid, req_vpn[20], req_root_ppn[22] (when req_valid), resp_consumed, flush` | 同 `tlb_mmu.io` |

不在 spec 里：`reset`（窗口内恒 0）、`perf_*`、主调用的 `icache_read_ready`（只喂 perf）、slot1、`csr_status.sstatus`。`PtwWalkReq.access_type`、`satp[31:22]`、`vaddr[11:0]`：PTW 不读（`tlb_mmu.md` §4）。

**放宽（`when`）与消费者核对**（均写进 `docs/modules/icache.md` §4）：
- `fetch_pc/inst_valid/page_fault_inst/fetch_group` 仅在 `read_complete`：消费者只有 S7 `icache_slot0_data_valid=icache_read_complete` 保护下的指令 FIFO 写（`front_top.cpp:1576–1696`，`if (!inst_fifo_full_for_write && icache_slot0_data_valid && ...)`）。
- `mem_req_addr/total_size/bypass/id` 仅在 `mem_req_valid`：`AXI_Interconnect.cpp` 里所有读取（1201、1960、2067–2084 等）都在 `read_ports[m].req.valid` 之内。
- `dc_req_addr` 仅在 `dc_req_valid`：`ICacheMemPortReq` 的消费者 [未核实，MemSubsystem 的探针接收处]；在核实之前按此放宽，核实结果写入笔记。
- `ptw_walk_req_vpn/root_ppn` 仅在 `req_valid`：同 `tlb_mmu.md` §4。
- `fetch_group` 在 `inst_valid=0` 的 lane、缺页 lane：C++ 输出 `INST_NOP`，**严格比较**（指令 FIFO 把 8 个 lane 都存下来）。

## 9. ITLB 复用 `tlb_mmu_core` 的差异与风险（tlb_mmu 笔记里写明未验证的部分）

`tlb_mmu_core` 参数已有 `FETCH/LANES/ENTRIES`；DTLB 路径已验证。ITLB 的调用方式有三处不同，必须在 RTL 里体现并单独验证：
1. **模式不互斥**：DTLB 每拍恰好三选一（fence > cancel > translate）。ICache 里是三个独立 `if`：`flush()`（`itlb_flush`）、`cancel_pending_walk()`（`refetch`）、`translate`（`!refetch && mmu_req_valid`）。`cancel` 与 `translate` 因 `!refetch` 互斥；`fence`（flush）与 `translate` 同拍时，C++ 先 `flush()`（写 `flush_pending_`、清 walk/refill、`flush_client()`），再 `translate()`（读未清的 TLB 内容、`walk_comb_` 已清、PTW 适配器被 `flush_client` 改写成 `req_ready=1, resp_valid=0`）。
   [已验证] 125 万拍里 `itlb_flush` 9 次，**全部与 `refetch` 同拍**（`itlb_flush && !refetch` = 0，`itlb_flush && translate` = 0）：SFENCE.VMA 的 `rob_bcast.fence` 与 `flush` 同拍（`BackTop.cpp:339`）。RTL 取 `mode = fence > cancel > translate`（与 DTLB 核心相同），并加仿真断言 `itlb_flush ⇒ refetch`；**这是一个前提（假设），写进笔记；随机生成器只在满足该前提时产生 `itlb_flush`**。如评审认为不可接受，需给 `tlb_mmu_core` 增加 `FETCH` 下"fence 与 translate 并存"模式（参考实现行为怪异：翻译用到旧 TLB 内容、并向 PTW 发出一个会被 flush 吃掉的请求）。
2. **没有"提前回填/提前消费"**：`translate_lsu_ports`（DTLB）在翻译前先调 `consume_completed_walk_refill(false)`；ITLB 的 `translate()` 直接进 `top_comb`，translate 拍里已回的 walk 响应只由请求该页的取指口消费。
   `cancel` 拍两者相同（`cancel_pending_walk()` 先消费）。`tlb_mmu_core` 的 `FETCH` 参数据此关掉 translate 拍的 `early_consume/early_refill`（随机生成器第 8512 拍首先抓到，真实程序没有）。
3. **单口、`type=0`**：`LANES=1`、`ACC_FETCH`（`FETCH=1` 已处理）；`effective_priv` 对取指不看 MPRV。
4. **结果编码**：`RES_HIT/FAULT/MISS` → `ppn_valid/page_fault`（第 4.3 节）。ITLB 响应在 `vaddr` 的低 12 位是 0，`paddr >> 12` 即 ppn（超级页合成 `compose_paddr` 已含 `vaddr_low` = 0）。
5. 复位值：`TlbMmu` 构造里 `flush_pending_=true; seq()`，即复位后 TLB 全空、`repl=0`、walk 空（与 `tlb_mmu_store` 复位一致）。
`itlb` 的 PTW 口输出在冲刷拍的第二步不变化（ITLB 只被第一步触发）。

## 10. 覆盖盲区与补充计划

### 10.1 真实程序覆盖（68 个程序，125 万拍，`data/icache_coverage_68prog_200kcyc.txt`）

| 事件 | 次数 / 程序数 | 评注 |
| --- | --- | --- |
| 主调用 / 冲刷拍双调用 | 1,251,182 / 3267（68）| |
| 冲刷拍 `R1` 状态 | `IDLE` 3265（其中 `req_valid_r=1` 的 706）、`SWAP_IN` **2**（axi 空闲 1、忙 1）| `K` 的 SWAP_IN 三个分支、CANCEL_WAIT、WAIT_DCACHE 几乎未覆盖 → 随机 |
| 冲刷拍里第二步压掉第一步的 `mem_req_valid` / `dcache_req_valid` | 0 / 0（本样本）| 随机 |
| FSM 各状态（拍初）| IDLE 1,215,017（kill 15,104）、SWAP_IN axi0/axi1 7650/5113（kill 316/415）、WAIT_DC 10,570（kill 191）、CANCEL_WAIT 70（kill 3）| `CANCEL_WAIT` 里 `accepted` 命中 txid 的分支未单独统计 |
| AXI 响应 | 有效 2706：active 2107、canceled 599、orphan 0 | orphan 需随机 |
| 非缓存取指（`paddr<0x40000000`）| 820 次，68/68 | |
| `table_write` / `invalidate_all`（fence.i）| 1485 / 194（3 个程序）| 重填写 8 路中的替换（缓存满）分支靠大程序 |
| DCache 探针响应 | valid 6030：hit 4167、miss 1812、retry 51（14 个程序）| |
| ITLB `translate` | 831,924：OK 831,910、FAULT 1、RETRY 13 | **全部直通（bare / M 态）除 `vm_sum_fetch_test`**；TLB 命中/替换/超级页/ASID 取指路径几乎没有 |
| PTW 请求 / 响应消费 / 响应有效 | 4 / 3 / 3（1 个程序）| |
| `itlb_flush` | 9（4 个程序），均与 `refetch` 同拍 | |
| `fence_i` | 194（3 个程序），均与 `refetch` 同拍 | |
| 页故障响应 | 1（1 个程序）| |
| `refetch`（全局）| 16,029 | |

### 10.2 随机生成器（补盲区，`tests/icache/rand_trace.cpp`）

驱动参考的 `icache_comb_calc`（与 `front_top.cpp` 同样的调用序列：`peek` → `comb_calc` → 可选的第二次 `invalidate_req`），环境模型：
- **AXI 读从机**：`ReadMasterPort_t`；`req.ready` 随机（ready-first 契约：`ready` 与 `accepted` 的一拍关系照 `AXI_Interconnect` 的行为）、接受后若干拍返回 16 字响应，`resp.id` = 请求 id，随机延迟/背压（`resp.ready` 由 ICache 给），取消后的响应仍会返回（`canceled`），偶发"孤儿响应"（id 不在途）；内存内容 = 随机字（自修改：探针与内存内容可不同，DCache 探针 `hit/miss/retry` 随机）。
- **DCache 探针**：`req_valid` 的下一拍给 `resp_valid`（`retry/miss/hit+data` 随机）。
- **ITLB/PTW**：复用 `tests/tlb_mmu/rand_trace.cpp` 的 `MockPort`（walk 客户端语义）+ 随机 Sv32 页表（3 个地址空间，含 U/S 位、X 位、超级页、缺页）；`satp/privilege/mstatus` 任意变化。
- **激励**：`req_valid/fetch_address` 随机（含跨页、非缓存地址、同组冲突造成替换）；`refetch/itlb_flush/fence_i/invalidate` 随机，**约束**：`itlb_flush ⇒ refetch`（SFENCE.VMA 的 flush 与 fence 同拍），`invalidate ⇒ !refetch`（`predecode_can_run` 含 `!refetch`），`fence_i ⇒ refetch`（FENCE.I 的 `rob_bcast->fence_i` 与 flush 同拍；不假设此前提时 RTL 也应通过——第 5.1 条 5，作为单独一组允许 `fence_i && !refetch` 的运行，若参考模型有 assert 则以参考为准）。
- **合法性依据**：参考模型对 ICache 输入没有 assert；约束全部来自上述 SoC 事实：端口握手遵守 AXI 契约（`resp.valid` 只对已接受的 id 或取消/孤儿响应；`accepted_id` 是请求 id）；`fetch_address` 4 字节对齐；探针响应只在探针请求的下一拍；CSR 变化任意。参考 Assert 全开（无 `-DNDEBUG`）自检。
- 输出：既写 `.trc`（`spec/icache*.io`，`iogen` 生成的 `TraceWriter`），也可单独用作变异检查的"随机"组。

## 11. 模块划分与翻译顺序

```
rtl/frontend/icache/
  icache_pkg.sv         类型/常量（状态编码、txid 位图、地址切分函数）
  icache_arr.sv         tag/valid/data 阵列 + 命中比较 + 命中路取数 + 无效路选择（存储器写法）
  icache_kill.sv        K：杀死步（组合函数，无状态）
  icache_ctl.sv         FSM 次态 N + 与 K 的合成 + 寄存器 + 输出（按需再拆 icache_probe / icache_miss）
  icache_itlb.sv        mmu_req → tlb_mmu_core(FETCH=1) → ppn/ppn_valid/page_fault
  icache_resp.sv        fetch_group 切片 + icache_ready
  icache.sv             顶层（端口适配）
```

| 顺序 | 任务 | 验证 |
| --- | --- | --- |
| 1 | `icache_arr` | 子 spec `icache_arr.io`（读请求/比较上下文/写口 → 命中、无效路、命中行）整程序锁步 + 变异 |
| 2 | `icache_kill` + `icache_ctl`（FSM、探针、替换、txid）| 子 spec `icache_ctl.io`（`icache_module` 边界：输入 = `lookup`/ITLB 结果/端口，输出 = 请求槽/AXI/DCache/表写口 + 冲刷合成）整程序锁步 + 随机冲刷 |
| 3 | `icache_itlb`（`tlb_mmu_core` FETCH=1）| 子 spec `icache_itlb.io`；真实程序只有 `vm_sum_fetch_test`，主要靠随机 |
| 4 | `icache_resp` + 顶层 | 顶层 spec `icache.io` 整程序锁步 `scripts/lockstep.sh icache` |

子 spec 与二分：`icache`（顶层）→ `icache_ctl`（去掉表/ITLB，输入含 meta、ppn）→ `icache_arr`/`icache_itlb`。三者的录制字段都来自 `TTG_IC.step[0]`（含冲刷拍 `step[1]`），不需要新 tap。

## 12. 待核实 / 开放问题

1. `dc_req_addr`/`dc_req_valid` 的消费者（MemSubsystem 的探针接收）是否只在 `req_valid` 内读地址——决定 `when dc_req_valid` 是否成立（第 8 节）。
2. `fence_i` 与 `refetch` 不同拍是否可能（决定 `kill1 && invalidate` 与 `fence_i && !refetch` 是否可达；RTL 与随机都按"可能"处理）。
3. `itlb_flush && !refetch`（第 9 节第 1 条）：RTL 假设不会发生，仿真断言保护。
4. `ICacheCompactKernel.h` 与 `comb_core` 的等价性只做了抽样（实验程序 + 实验调用数见 `icache.md` §5）；整程序锁步是最终依据。
5. 配置只覆盖 `PROFILE=default`（`small/medium/large` 的 `ICACHE_*`/`FETCH_WIDTH`/`ITLB_ENTRIES` 不同）。
