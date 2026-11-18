---
module: icache
area: frontend
rtl: rtl/frontend/icache
model: trace-model front-end/icache/icache_top.h、icache_top.cpp、icache_module.cpp、include/icache_module.h（调度单元 `front.core.icache`，类 `ICacheTop`，阶段 `comb_fetch`、`comb_invalidate`）；ITLB 是 back-end 的 `TlbMmu`（`Kind::ITLB`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 69 层（icache，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# icache 设计文档（指令缓存 + ITLB + 存储侧口）

## 1. 职责

取指地址队列的队首地址进来，一个取指组出去。做五件事：

1. 把取指的虚拟地址交给 ITLB（指令 TLB）翻译，得到物理页号，或页故障；
2. 用物理页号在缓存阵列里查：命中就从缓存行里按地址切出 16 个槽的取指组（见 5.1）；
3. 缺失就通过 AXI 读口取一整行（物理地址 < 0x40000000 的取指不缓存，只取一个字，`mem_req_bypass = 1`），同时向 DCache 探针问同一行的 16 个字（自修改代码：DCache 里有更新的数据时用 DCache 的），回填一路；
4. 响应重取指（`refetch`）、FENCE.I（作废全部有效位）、SFENCE.VMA（`itlb_flush`）、预译码冲刷（`invalidate`，同拍的第二步）：取消在途请求和在途缺失；
5. 请求在途时记账 AXI 事务号：被取消的缺失的迟到响应要丢掉。

模型里是一个调度单元 `front.core.icache`（`ICacheTop`）：`comb_fetch` 做取指步 N，`comb_invalidate` 做预译码冲刷的第二步 K；时序更新在 `seq`。RTL 的模块边界是为综合划的，模型里没有对应的类（`icache_module.cpp` 的 `ICache` 是它的状态机）。

## 2. 配置（`ttg_cfg_pkg` / `icache_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 路数 × 组数 | 8 × 64，每行 64 字节（16 个 32 位字） | `ICACHE_WAY_NUM`、`ICACHE_SET_NUM`、`ICACHE_LINE_SIZE`、`ICACHE_WORD_NUM` |
| 标签 | 20 位（= 物理页号，32 位物理地址的高 20 位；`mem_req_addr` 是 32 位） | `ICACHE_TAG_BITS` |
| 组索引 / 行内偏移 | 6 位 / 6 位 | `ICACHE_INDEX_BITS`、`ICACHE_OFFSET_BITS` |
| 取指组 | 16 个槽，每槽一个 32 位窗口（从该半字起的 4 个字节） | `FETCH_WIDTH = 16`、`RVC_ENABLE = 1` |
| ITLB | 64 项（`tlb_mmu_core`，一个取指端口，`FETCH = 1`） | `ITLB_ENTRIES` |
| AXI 事务号 | 16 个（4 位 id） | `IC_TXID_N`、`IC_TXID_W` |
| 缓存行请求 | 总长 63（= 行字节数 - 1） | `mem_req_total_size`（`icache_ctl`） |
| 不缓存的取指 | 物理页号高两位为 0，即物理地址 < 0x40000000，总长 3，旁路 | `ic_is_uncache`（`icache_pkg`） |
| 替换 | 先用第一个无效路，否则全局轮转指针 +1（不是每组一个） | `icache_swap`：`replace_next` |
| 存储容量 | 数据 8×64×512 位，标签 8×64×20 位，有效位 512 位 | `icache_arr` |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `req_valid`、`fetch_address` | 取指地址队列队首（`fa_rd_valid / fa_rd_address`） |
| 入 | `refetch`、`itlb_flush`、`fence_i`、`invalidate` | 全局重取指、SFENCE.VMA、FENCE.I、预译码冲刷（`do_predecode_flush`） |
| 入 | `csr_status_satp / privilege / mxr / sum / mprv / mpp` | ITLB 的翻译条件 |
| 入 | `mem_req_ready / accepted / accepted_id`、`mem_resp_valid / id / data[16]` | AXI 读口：请求被接收的脉冲和事务号、响应 |
| 入 | `dc_resp_valid / retry / miss / data` | DCache 探针的响应 |
| 入 | `ptw_walk_req_ready`、`ptw_walk_resp_*` | 页表遍历器对 ITLB 的响应 |
| 出 | `icache_ready` | 能接新请求：`!(itlb_flush | fence_i) & ifu_ready_q & !req_valid_q & !miss_txv & 状态为 IDLE` |
| 出 | `read_complete`、`fetch_pc`、`inst_valid[16]`、`page_fault_inst[16]`、`fetch_group[16]`、`fetch_upper_ok[16]` | 取指组；`fetch_upper_ok[i]` = 第 i 个窗口有真实的高半字（它的下一个半字也在这行内） |
| 出 | `mem_req_valid / addr / total_size / bypass / id`、`mem_resp_ready` | AXI 读请求（地址 32 位） |
| 出 | `dc_req_valid`、`dc_req_addr` | DCache 探针请求（一拍脉冲，没有 ready） |
| 出 | `ptw_walk_req_valid / vpn / root_ppn`、`ptw_walk_resp_consumed`、`ptw_walk_flush` | ITLB 向页表遍历器的请求 |

## 4. 结构

```
 req_valid/pc ─► icache_slot ─► mmu_req ─► icache_itlb (tlb_mmu_core, FETCH=1) ─► ppn_valid / page_fault / ppn ─┐
 refetch, fence_i, invalidate ─►  icache_ctl ◄───────── hit, hit_line, first_invalid ◄── icache_arr ◄─ rd_index, cmp_tag ┘
                                   ├ icache_idle  : 空闲态一步（快速通路、登记通路、缺失分配）
                                   ├ icache_swap  : 缺失服务一步（发请求、等响应、等探针、回填）和 CANCEL_WAIT
                                   ├ icache_kill  : 取消一步 K（作用于 R0 或 R1）
                                   ├ icache_txn   : AXI 响应分类（有效 / 被取消 / 孤儿）
                                   ├ icache_probe : DCache 探针一步
                                   └ 响应 ─► icache_resp : 从行里切出 16 个槽的取指组
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `icache.sv` | 130 | 顶层：把 16 个字响应拼成一行、连线、`ptw_walk_flush` 在复位后第一拍也置位 |
| `icache_pkg.sv` | 78 | 参数、`ic_regs_t`（控制寄存器）、复位值、状态编码、地址函数 |
| `icache_ctl.sv` | 242 | 例化下面各块，选择、寄存器、冲刷合并、存储侧输出 |
| `icache_arr.sv` | 74 | 阵列（标签 / 有效 / 数据），命中比较，第一个无效路，命中行的选择 |
| `icache_itlb.sv` | 80 | `tlb_mmu_core(LANES=1, FETCH=1)` 加结果映射 |
| `icache_slot.sv` | 50 | 单项请求槽 `req_valid / req_pc / ifu_ready`、ITLB 请求 |
| `icache_idle.sv` | 63 | 空闲态一步 |
| `icache_swap.sv` | 121 | 缺失服务一步 |
| `icache_kill.sv` | 92 | 取消一步 |
| `icache_probe.sv` | 71 | 探针一步 |
| `icache_txn.sv` | 40 | 响应分类 |
| `icache_resp.sv` | 75 | 取指组切片 |

状态：`ic_regs_t` 共 137 位（请求有效 1、请求 pc 64、`ifu_ready` 1、状态 3、缺失事务号有效 1 + 号 4、`ready_seen` 1、在途 16、被取消 16、探针 3 位控制 + 字号 4、`ppn` 20、替换指针 3）；两个 512 位的数据寄存器 `resp_line_q`（响应行）、`probe_line_q`（探针行，按字写使能）；阵列；ITLB 的 64 项。

状态机 5 个状态（`ic_state_e`）：`IC_IDLE`；`IC_SWAP_REQ`（缺失，AXI 请求还没被接收）；`IC_SWAP_WAIT`（已被接收，等响应）；`IC_WAIT_DC`（响应已到，等探针完成）；`IC_CANCEL_WAIT`（缺失被取消，但请求刚好在被接收的路上，等一拍让接收脉冲过去）。模型是（状态，AXI 状态）两个量，AXI 忙只出现在 SWAP_IN，合成一个 5 态编码；模型的 `DRAIN` 没有任何入口，不编码。

### 一次冲刷拍里的双步

预译码冲刷那一拍（`invalidate = 1`）模型先做取指步 N，再做取消步 K。RTL 一次组合求值：`R1 = kill1 ? K(R0) : N(R0)`（`kill1 = refetch | fence_i`），`R2 = invalidate ? K(R1) : R1`，`R2` 是时钟沿装载的值。取指组和阵列写口只看第一步（`resp_valid = !kill1 & ...`，不含 `invalidate`），存储侧输出（AXI 请求、`mem_resp_ready`、DCache 探针请求）取最后一步：`invalidate ? K(R1) : (kill1 ? K(R0) : N(R0))`。冲刷拍里 K 在 SWAP_IN 会先走一次探针，因此可能新发一条 DCache 探针请求（保留了模型行为）。

## 5. 一拍内的数据流

### 5.1 取指组的切片（`icache_resp`）

槽 i 的窗口 = 从行内半字 `pc[5:1] + i` 起的 32 位（`{半字[h+1], 半字[h]}`）；半字下标超出这行的槽无效；行的最后一个半字的窗口高半是 0（`upper_ok = 0`）。页故障时 16 个槽全有效、全带 `page_fault_inst`、指令字为 NOP（`0x00000013`）。不缓存的响应只有一个字：槽 0、1 有效，槽 1 的高半为 0。`fetch_pc = resp_valid ? resp_pc : 0`。（`RVC_ENABLE = 0` 时改成按字切、16 个字槽，该分支未用于当前配置。）

### 5.2 请求、查表和快速通路

1. `icache_slot`：`mmu_req_valid = !kill & (登记槽有效 | (req_valid & 槽空闲))`，`mmu_req_vtag` 取登记槽的 pc 或本拍的 pc（不依赖 ITLB 的回答，没有组合环）；
2. ITLB 回答 `ppn_valid / page_fault / ppn`（未命中则 `ppn_valid = 0`，下一拍再问）；
3. 阵列读：`rd_en = !refetch & (req_valid | 登记槽有效)`，组索引取登记槽或本拍 pc 的 `[11:6]`；比较条件 `cmp_valid = IDLE & !kill1 & ppn_valid & !page_fault & (...)`，比较标签 = ppn；最低的匹配路命中；
4. 空闲态一步：**快速通路**——本拍新来的请求且 ITLB 已有回答（`fast = !req_valid_q & req_valid & ppn_valid`），命中或页故障就当拍回答；**登记通路**——否则请求登记到槽里，之后每拍用登记的 pc 重试，直到答出。登记的请求缺失（`ppn_valid & !page_fault & !hit`）则分配一个空闲事务号，进 `IC_SWAP_REQ`；
5. 缺失服务：发 AXI 读（`mem_req_valid = SWAP_REQ & !accepted`）；被接收后若响应还没到，进 `SWAP_WAIT`；响应到（`gnt`）后若探针已完成就回填，否则进 `WAIT_DC`；回填：写一路（`tw_we = finish & !不缓存`），同拍把行作为取指响应；探针 16 个字全命中时，回填并响应的是探针行（DCache 里的更新数据），否则是内存行；
6. 取消：`refetch | fence_i` 时 K：丢掉登记请求、`ifu_ready` 置 0；在途缺失：请求已经出去（或本拍被接收）就把事务号标为"被取消"，迟到的响应由 `icache_txn` 判为丢弃并用 `mem_resp_ready` 吞掉；若请求已经 `ready` 但接收脉冲还没来则进 `CANCEL_WAIT` 等一拍；否则直接释放；
7. `icache_ready` 来自寄存器。`FE_RFAST` 位 2：取消后 `ifu_ready` 当拍恢复（除非 AXI 接收脉冲还要等，由 `accepted_now` 压住）。

`icache_probe`：缺失服务期间，对同一行的 16 个字逐个向 DCache 发探针（不缓存的取指没有探针，直接完成）；响应可以要求重试（原字重发）；某个字缺失就整个探针算不命中；16 个字都命中才算命中。

## 6. 关键路径与深度

单模块综合深度 **69 层**（icache；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_ctl.r_q [136]` 到 `\u_ctl.r_q [44]`。。从代码读出的，未综合验证：快速通路把几件事放在了同一拍里——取指地址（来自取指地址队列的寄存器，经 `fa_rd_en` 选通）→ ITLB 查找（64 项的全相联比较，`tlb_mmu_core`）→ `ppn` → 阵列 8 路标签比较（阵列读是异步的）→ 命中路选择（8 选 1，512 位）→ `icache_resp` 的 16 路按偏移切片 → 取指侧的展开 / 预译码 / 起点扫描 → 指令队列写数据（`front_fetch_buf`）。这是前端里"从地址到指令队列"的一整条链，I-Cache 的响应在同一拍就进了指令队列。`icache_ctl` 里 `invalidate`、`kill1` 只影响次态和存储侧输出，不在这条链上。

本轮没有改 I-Cache 的深度。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- 模型的 I-Cache **没有数据阵列**：命中后的指令字从功能内存读（`icache_top.h` 文件头：`the instruction words from the functional memory`），只维护标签和有效位；RTL 有真正的数据阵列（8×64×512 位）。二者在自修改代码上靠 FENCE.I（作废有效位）和缺失时的 DCache 探针取得一致，由整核门禁（`fence-i-self-modify`）和 Linux 检验；
- `FE_PAIR` 的第二块读（`fetch_second`）和 `FE_IPF` 的预取（`prefetch_install`、`peek_hit`、`peek_translate`、`FrontIpf`）：RTL 没有，模型默认关；
- 模型的 PMU 分类（`drive_perf`）、`lookup_pending` 之类的 SRAM 查表模型、`std::exit` 自检、`ICacheCompactKernel.h` 等位级网表：RTL 以可读逻辑翻译，不复刻；
- 模型的 `read_ready` 在 `reset` 时返回 true；RTL 的 `ifu_ready` 复位值为 0，因此复位释放后第一拍 `icache_ready = 0`（`icache_pkg.sv` 里 `IC_REGS_RESET` 的注释）。模型的 `ifu_req_ready_r` 复位值是 true，但参考的第一拍还会与上一次 comb 的 `ifu_req_ready` 输出相与，那个值复位后是 false。第二拍起两边一致（`ifu_ready_d` 每拍重算）。

RTL 与模型保持一致的细节（容易误判为 bug）：

- 替换指针是**全局**轮转计数器，不是每组一个；有无效路时用第一个无效路，此时指针被设成那一路（`gnt` 时 `replace_idx = replace_next`），不缓存的取指不动指针；`WAIT_DC` 态回填用**旧**指针（`tw_way = wdc ? r.replace_idx : replace_next`）；
- `ppn_r`（缺失的物理页号）在登记通路每次 ITLB 有回答（非故障）都更新；
- 冲刷拍里 K 可能新发探针请求；
- ITLB 在登记请求有效的每一拍都被查询（含缺失服务期间）；`tlb_mmu_core` 的 `FETCH` 参数关掉 DTLB 才有的"提前回填 / 消费"路径；
- `ptw_walk_flush` 复位后第一拍也置位：参考的初始化调用把 ITLB 的 flush 留在遍历器口上；
- ITLB 前提 `itlb_flush ⇒ refetch`（后端 SFENCE.VMA 同时冲刷流水线）：RTL 用"fence > cancel > translate"的优先级，并加了仿真断言（`icache_itlb.sv`）。

未核对（继承自旧文档）：

- 旧文档说 `icache_ctl` 里 `has_invalid` 不看 `rd_en`、`ppn_r` 只在某些条件更新等若干"等价变异"：这是旧变异检查的结论，没有重做；
- 旧文档说"取指 `paddr < 0x40000000` 走单字旁路读"对应模型的 `CONFIG_ICACHE_MMIO_UNCACHE_LIMIT`：RTL 一侧（`ic_is_uncache`）已核对，模型一侧的常量名和值没有核对；
- `icache_pkg.sv` 和 `icache_itlb.sv` 的注释还引用旧文档的章节（"docs/modules/icache.md 4.1 item 5"、"Assumption (docs/modules/icache.md)"），对应本文第 7 节，注释本轮没有改。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比 function-model，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`：67/67 通过，周期逐个相等。触及 I-Cache 的有：`fence-i-self-modify`（FENCE.I 与探针路径）、`coremark` / `dhrystone`（缺失与回填；旧文档用它们和 `fence-i-self-modify` 做过 I-Cache 的真实程序检验）。取指页故障和 ITLB 遍历在 67 个程序里有没有、有多少，没有统计。哪些程序真正走到了 `CANCEL_WAIT`、重试探针、迟到响应丢弃等分支，没有做覆盖统计。
- **Linux**：`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`（Sv39 取指、页故障、FENCE.I、SFENCE.VMA 在内核里都会出现）。
- **Lint**：`scripts/lint_chip.sh` 0 告警（整芯片）。目录级 `scripts/lint.sh rtl/frontend/icache` 需要 `tlb_mmu_core`，旧文档说不能直接用，本轮没有重跑。
- **没有模块级的独立测试**：旧体系有随机 trace 生成器 + 33 个变异的回放测试（`tests/icache`，真实程序抓到约 25 个、其余 5 个只有随机能抓到：替换指针、写入路、探针重试、同拍接受的响应、`icache_ready` 与 `itlb_flush`），已随 `spec/` 退役，不在仓库里（旧表在本文件的 git 历史里：`git log -- docs/modules/icache.md`）。**待补**：给 `icache_ctl`（含冲刷合并）补一个"RTL 对状态机直译模型"的随机测试，尤其是那五类只有随机才能抓到的行为。

## 9. 参数与开关速查

`ICACHE_WAY_NUM`、`ICACHE_SET_NUM`、`ICACHE_LINE_SIZE`、`ICACHE_WORD_NUM`、`ICACHE_TAG_BITS`、`ITLB_ENTRIES`、`RVC_ENABLE`、`FE_RFAST`（位 2）、`XLEN_BITS`（`ttg_cfg_pkg`）；`IC_TXID_N`、`IC_TXID_W`、状态编码、`IC_REGS_RESET`（`icache_pkg`）。

## 10. 变更记录

- 2026-11-17/18（exp/agu-share）：`16de223`（EXP-TLBPORTS 第 3 步）顺带改了 `icache_itlb.sv`（`tlb_mmu_core` 例化去掉 `LD_LANES` 参数、加 `req_is_store` 接常 0，是 DTLB 多端口化的接口随动，ITLB 行为不变）；I-Cache 本身没有改。
- 更早：见 git 历史（含 2026-11-14/15 的 RVC：半字窗口、`fetch_upper_ok`、C910 风格携带，`e784f05` 等）。
