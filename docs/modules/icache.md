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
1. **冲刷拍双步推进**（分析 §5，协调者决定不复刻调用结构，只要最终可观察行为一致）：RTL 一次组合求值 + 一次时序更新，`R2 = invalidate ? K(R1) : R1`；`K`（杀死步）是 `R1` 上的覆盖层，存储侧输出（AXI/DCache 请求、`mem_resp_ready`）取周期末的最终值（冲刷拍即 `K(R1)` 的输出）。等价性：第二步读同样的端口值、不碰阵列与 ITLB，只改 FSM 寄存器与端口输出，见分析 §5.4。
2. 冲刷拍里 `K` 在 `SWAP_IN` 会先调 `step_dcache_probe()`，**可能新发一条 DCache 探针请求**（参考行为，保留）。
3. ITLB 在 `req_valid_r` 为真时每拍被查询（含 `SWAP_IN` 等内存期间）。ITLB 的 `translate()` 没有 DTLB 的"提前回填/消费"，`tlb_mmu_core` 的 `FETCH` 参数据此关闭 translate 拍的 early 路径（DTLB 网表不变，tlb_mmu 锁步复验通过）。
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

`first_cycle_q`（顶层）：复位后第一拍 `ptw_walk_flush=1`（参考的初始化调用把 ITLB 的 flush 留在 PTW 口上）；子 spec `icache_itlb.io` 的 `ptw_flush` 排除该拍。
ITLB 前提：`itlb_flush ⇒ refetch`（仿真断言，`icache_itlb.sv`）。

## 5. 验证
- spec：顶层 `spec/icache.io`（48 字段）+ 子部件 `icache_ctl.io`（48）/`icache_arr.io`（14）/`icache_itlb.io`（25），均来自 `TTG_IC`/`TTG_FT`，子 spec 用于二分。
- 整程序实时锁步（`REFSIM` = 打了 tap 补丁的副本）：68 个程序（61 gate + 4 vm + dhrystone 3.9M 拍跑完 + coremark（≤4M 拍）+ float）× 4 个 spec = **272/272 PASS**，0 失败；其中冲刷拍 3267 次、fence.i 194 次、ITLB 非直通只在 vm 测试。
- 随机生成器 `tests/icache/rand_trace.cpp`（`run_rand.sh`）：4 条 × 20 万拍 = 80 万拍，全部 PASS（每条约 1 万次冲刷拍，其中 2000–3600 次冲刷后 FSM 处于 `SWAP_IN`；5000+ 次 PTW 请求，3500–4100 次 ITLB 缺页；fence.i 300–400、itlb_flush 500–700、孤儿响应 ≈800、取消响应、非缓存、DCache 探针重试/缺失/命中）。
  随机首先抓出一个真实 RTL 问题：ITLB 无提前回填（第 8512 拍，已修，见 §4.1 第 3 条）。
- 变异（`tests/icache/mutants.txt`，`run_mut.sh`，33 个；REAL = 5 个真实程序（smc-div、vm_sum_fetch、fence-i-self-modify、dhrystone、coremark，各 ≤30 万拍）锁步，RANDOM = rand_1 回放）：
  | 子部件 | 变异 | REAL | RANDOM |
  | --- | --- | --- | --- |
  | arr | 比较 tag 少一位 | smc-div c71 `read_complete` | rec 605 |
  | arr | `invalidate_all` 不清 valid | smc-div c107 | rec 1992 |
  | arr | `first_invalid` 错 | dhrystone c337 | rec 1429 |
  | arr | tag 写错 | smc-div c71 | rec 605 |
  | swap | 替换指针 +2 | 未抓到 | rec 36192（仅随机）|
  | swap | 写入路取旧指针 | 未抓到 | rec 38853（仅随机）|
  | swap | 非缓存字取错 | smc-div c10 `fetch_group[0]` | rec 395 |
  | swap | 未被接受也发请求 | smc-div c6 `mem_req_valid` | rec 24 |
  | probe | 最后一字下标错 | smc-div c187 | rec 74 |
  | probe | retry 当 miss | 未抓到 | rec 1004（仅随机）|
  | idle | 缺页时 `req_ready` 错 | vm_sum_fetch c2392 `icache_ready` | rec 922 |
  | pkg | 非缓存判定错 | smc-div c4 | rec 388 |
  | txn | 同拍接受的响应不算 active | 未抓到 | rec 163（仅随机）|
  | kill | 已发请求的取消不标记 canceled | smc-div c22 | rec 467 |
  | kill | `waiting_accept` 不看 `ready_seen_now` | vm_sum_fetch c2298 | rec 1447 |
  | kill | 冲刷拍探针请求去掉 | fence-i-self-modify c126 `dc_req_valid` | rec 1446 |
  | ctl（冲刷合并）| 去掉 `K(R1)` | smc-div c72 | rec 143 |
  | ctl（冲刷合并）| `K` 作用在 `R0` 而非 `R1` | coremark c91965 | rec 142 |
  | ctl（冲刷合并）| 存储侧请求取第一步 | coremark c91983 | rec 142 |
  | slot | 不查 `req_valid_r` 的 ITLB 请求 | smc-div c4 | rec 22 |
  | itlb | 不 cancel | smc-div c12 `ptw_flush` | rec 137 |
  | itlb | fault 不算 ppn_valid | vm_sum_fetch c2391 | rec 921 |
  | itlb | FETCH 开启 early 回填 | vm_sum_fetch c2355 | rec 22 |
  | resp | 行尾不截断 | smc-div c75 | rec 279 |
  | resp | 缺页 lane 不输出 NOP | vm_sum_fetch c2391 | rec 921 |
  | ctl | `icache_ready` 忽略 `itlb_flush` | 未抓到 | rec 9640（仅随机）|
  真实程序能抓 ≈25 个，**只有随机能抓 5 个**（替换指针、写入路、probe retry、同拍接受响应、icache_ready/itlb_flush）。未抓到的等价变异（不可观察，已核对）：`has_invalid` 不看 `rd_en`、`ppn_r` 只在未命中时更新、kill 里 `ready_seen` 清零（CANCEL_WAIT 下一拍必清）、`ifu_ready_d` 不与 `!req_valid_d`（`icache_ready` 已含 `!req_valid_q`）、`K(R1)` 的 `mem_resp_ready` 再 OR 一次 `drop_resp`。
- lint：`bash scripts/lint.sh rtl/frontend/icache` **不能直接用**（目录内的 `icache_itlb` 例化 `rtl/backend/tlb_mmu/tlb_mmu_core`，该脚本只编译本目录；需要像 `back_top` 那样给 `icache` 加装配分支）。按相同规则手工跑：`svlint.py` + `verilator --lint-only -Wall --top-module icache`（含 packages、`ttg_*` 原语、tlb_mmu 子模块）**干净**。
