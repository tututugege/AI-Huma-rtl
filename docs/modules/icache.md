# icache 设计笔记（指令缓存 + ITLB + 访存侧接口）

分析与边界见 `docs/analysis/icache-boundary.md`（功能分解、状态清单、一拍数据流、**冲刷拍双步合并规则（评审点）**、录制点、死代码、覆盖盲区）。
录制点见 `docs/analysis/icache-record-hook.md`。本文是 RTL 设计笔记。

## 1. 对应的 C++
- `front-end/icache/icache.cpp`（`icache_comb_calc/icache_peek_ready`、三张 `GenericTable`）、`ICacheTop.cpp`（`TrueICacheTopT::comb/seq`、`comb_mmu_view`、`eval_true_glue`）、
  `icache_module.cpp`（`ICache::eval_state_machine/lookup/step_dcache_probe/latch_mem_refill/finish_refill`；`ICacheCompactKernel.h` 等是它的机器生成位级网表，翻译以可读逻辑为准，等价性实验见分析 §0）、`back-end/Lsu/TlbMmu.cpp`（ITLB）。
- 前端调用：`front_top.cpp` S2（peek）、S6（主调用）、S12（冲刷拍第二次调用）。
- 输入/输出：`spec/icache.io`（48 字段，字段说明见分析 §8）。

## 2. 硬件结构
```
  req_valid/pc ─┬─► icache_ctl ──► mmu_req(valid,vtag) ─► icache_itlb(tlb_mmu_core FETCH=1) ─► ppn, ppn_valid, page_fault ─┐
  refetch,fence_i,invalidate        │  ▲                                                                                   │
                                    │  └─ meta(hit,way,has_invalid) ◄── icache_arr(tag/valid/data) ◄── rd_index, cmp_tag ◄─┘
                                    ├─► 表写口 ──► icache_arr            ├─► AXI 读请求 / mem_resp_ready / DCache 探针请求
                                    └─► resp(valid,pc,line,pf,single) ─► icache_resp ─► read_complete, fetch_group[8], …
```
| 模块 | 职责 |
| --- | --- |
| `icache`（顶层）| 端口适配 + 连线 |
| `icache_pkg` | 状态编码、寄存器结构 `ic_regs_t`、地址函数 |
| `icache_arr` | tag/valid/data 阵列（存储器写法）+ 命中比较 + 无效路选择 |
| `icache_txn` | AXI 响应分类（active/canceled/orphan）|
| `icache_probe` | DCache 字探针一步（16 字顺序探针）|
| `icache_idle` | `IDLE` 状态一步（快速通路、登记通路、缺失分配）|
| `icache_swap` | `SWAP_IN/WAIT_DCACHE_AFTER_MEM/CANCEL_WAIT_ACCEPT` 一步 + 重填收尾 |
| `icache_kill` | 杀死步 `K`（组合函数）；例化两份（作用在 `R0` 和 `R1` 上，冲刷拍覆盖层）|
| `icache_slot` | `lookup()`：请求槽 `req_valid/req_pc/ifu_ready` 更新、`mmu_req` |
| `icache_ctl` | 例化以上、状态选择、寄存器、冲刷合并（R2 = invalidate ? K(R1) : R1）|
| `icache_itlb` | `tlb_mmu_core(FETCH=1,LANES=1)` + 结果映射 |
| `icache_resp` | 取指组切片与 `icache_ready` |

状态：`ic_regs_t`（~120 位标量/小向量）+ `resp_line_q`（512b，`mem_resp_data_r`）+ `probe_line_q`（512b）+ 阵列（data 64×8×512b、tag 64×8×20b、valid 512 位）+ ITLB（64 项）。
状态编码：`(state, mem_axi_state)` 合成 5 个状态 `IDLE/SWAP_REQ(axi 空闲)/SWAP_WAIT(axi 忙)/WAIT_DC/CANCEL_WAIT`（不变式：axi 忙 ⇒ SWAP_IN；`DRAIN` 不可达）。

## 3. 一拍内的数据流
1. `kill1 = refetch | fence_i`。`mmu_req_valid = !kill1 && (req_valid_q || (req_valid && state==IDLE && !miss_txid_valid))`，`vtag = req_valid_q ? req_pc_q[31:12] : pc[31:12]`（C++ pass1，与 ITLB 结果无关，无组合环）。
2. ITLB：`fence=itlb_flush`、`cancel=refetch`、`translate = mmu_req_valid`（`mmu_req_valid` 在 `kill1` 时为 0）→ `ppn_valid/ppn/page_fault`。
3. 阵列读：`rd_en = !refetch && (req_valid || req_valid_q)`，`rd_index = req_valid_q ? req_pc_q[11:6] : pc[11:6]`；比较：`cmp_valid = state==IDLE && !kill1 && ppn_valid && !page_fault && (req_valid_q || req_valid)`，`cmp_tag = ppn`。
4. `N`：按状态选 `icache_idle/icache_swap` 的结果；序言（响应分类 + 探针）两者共用；`kill1` 时用 `K(R0)`。
5. 冲刷合并：`R1 = kill1 ? K(R0) : N`；`R2 = invalidate ? K(R1) : R1`；存储侧输出（`mem_req_valid/mem_resp_ready/dc_req_*`）取 `invalidate ? K(R1).out : (kill1 ? K(R0).out : N.out)`。表写口/前端输出只来自第一步。
6. 沿上：`ic_regs_t`、`resp_line_q`、`probe_line_q`（按字写使能）、阵列（写口）、ITLB 寄存器。
无 stale 读；没有同拍多次推进（`R1` 是组合信号）。

## 4. 与 C++ 的差异点、放宽、不复刻
### 4.1 隐含依赖 / 行为登记（RTL 与 C++ 行为一致，写明以便评审）
1. **冲刷拍双步推进**（分析 §5）：RTL 用 `K(R1)` 覆盖层表达，存储侧输出取最后一步。
2. 冲刷拍里 `K` 在 `SWAP_IN` 会先调 `step_dcache_probe()`，**可能新发一条 DCache 探针请求**（参考行为，保留）。
3. ITLB 在 `req_valid_r` 为真时每拍被查询（含 `SWAP_IN` 等内存期间）。
4. 取指 `paddr < 0x40000000` 走单字旁路读（`total_size=3, bypass=1`），不写 cache；`rd_data` 只有 `(pc&63)/4` 号字有值。
5. 复位值：`ifu_ready_q` 复位为 **0**（C++ `ICache()` 里是 1）。原因：参考在复位调用之后第一拍 `icache_peek_ready` 还 AND 了"上一次 comb 的 `ifu_req_ready`"，它是 `io.out` 的默认值 false（复位调用不求值 FSM）；
   之后每次 comb 都重写。RTL 的 `ifu_ready_q` 只被 peek 用，复位为 0 复现第一拍的 `icache_ready=0`，第二拍起与 C++ 一致（`ifu_ready_d` 每拍重算）。
6. `replace_idx` 是全局轮转计数器（不是每组）；无效路优先。写入路是 `replace_idx_next`（新值）。
7. `ppn_r` 在登记通路每次 `ppn_valid`（命中/未命中）都更新，保持。
### 4.2 放宽（`when`）与消费者核对（见分析 §8）
| 字段 | 限定 | 核对 |
| --- | --- | --- |
| `fetch_pc/inst_valid/page_fault_inst/fetch_group` | `read_complete` | S7 `icache_slot0_data_valid` 保护的指令 FIFO 写，`front_top.cpp:1576-1696` |
| `mem_req_addr/total_size/bypass/id` | `mem_req_valid` | `AXI_Interconnect.cpp` 读口所有读取都在 `req.valid` 内 |
| `dc_req_addr` | `dc_req_valid` | 见分析 §12 第 1 条（核实结果见 §5）|
| `ptw_walk_req_vpn/root_ppn` | `ptw_walk_req_valid` | `tlb_mmu.md` §4 |
### 4.3 删除 / 不复刻
`lookup_pending/lookup_pc/lookup_index`（SRAM 查表模型）、`DRAIN`、"命中但数据未就绪"、perf/debug、`std::exit` 自检、slot1、`icache_read_ready`（主调用，仅 perf）、`txid` 位图之外的所有 perf 状态。
ITLB：`itlb_flush ⇒ refetch` 前提（分析 §9），RTL 用 `fence > cancel > translate` 并加仿真断言。
