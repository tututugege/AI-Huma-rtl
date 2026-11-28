---
module: icache
area: frontend
rtl: rtl/frontend/icache
model: trace-model-fe-2ahead front-end/icache/icache_top.h、icache_top.cpp、icache_module.cpp、include/icache_module.h、front-end/front_top.cpp（F0 → F1 两级 ICache 流水、64 KiB `256×4` Lo/Hi 2 级流水、1 项 FDIP fill buffer）；ITLB 是 back-end 的 `TlbMmu`（`Kind::ITLB`）
status: 已实现并完成 77/77 fm_gate 与 Tier 0-elab / Tier 1 PPA 验证（64 KiB `256×4` Lo-32B/Hi-32B 2 级串联 Tag-then-Data VIPT，`rtl/fe-2ahead`）
depth: Tier 1 TSMC 28nm (Yosys+PrimeTime STA, clk=0.65ns, eda-07): icache 77 层 / Total 490,495.9 / WNS -1.24ns (Fmax_T1 0.529 GHz, pt_timing_reg2reg -1.18ns / 0.546 GHz)；front_top 64 层 / Total 2,682,267.5 / WNS -1.82ns (Fmax_T1 0.405 GHz，瓶颈已移出 u_icache)
---

# icache 设计文档（64 KiB 2 级 VIPT 指令缓存 + Lo/Hi 分体 + 单口 `1024×32` 宏）

> **2026-11-28 64 KiB（`256×4`）Lo-32B/Hi-32B 2 级串联 Tag-then-Data 升级（`rtl/fe-2ahead`）**：
> - **容量与宏重构（64 KiB，`16 × 1024×32` 1RW 宏）**：由 `8 ways × 64 sets`（`4-Bank 16×512b` 填满 `256 × 64×64`，`1,476.4k µm²`）改为 **`4 ways × 256 sets × 64B`**，按 **Lo-32B / Hi-32B** 垂直切分为两套独立单口 `ttg_sram_1rw #(DEPTH=1024, WIDTH=256)`（共 **`16 × TEM5N28HPCPLVTA1024X32M4SWSO`**，仅 `213.7k µm²`，`-85.5%` 宏面积且容量翻倍），彻底消灭 `4.00×` 深度 padding 与 8 路 512b Data Mux。
> - **2 级串联流水（`F0 → F1`）彻底斩断 92 级组合环**：
>   - **F0（ITLB + Even/Odd 2-Bank Tag + `hit_way` → 启动 1RW Data SRAM）**：仅用寄存 `ifu_addr` / `r_q.req_pc` 查 64 项 ITLB 与按 `idx[0]` 分奇偶 2-Bank FF 的 Tag/Valid（Block A 与同页下一行 Block B 奇偶永反、0 冲突，并行完成 4 路比对与 `arr_b_hit`），选定单路 `{hit_way, idx}`（和 `rd_pc[5]` 时 `Lo` 读 Block B）直接送入 `u_data_lo`/`u_data_hi`（取消 `fast_fire` 组合反推 `next_rd_index` 与 `ic_next_b_idx`）。
>   - **F1（Data SRAM 读出 + 半字切片拼接 → `inst_fifo`）**：锁存 `ic_f1_t` 与旁路行，直接从 `lo_rdata` / `hi_rdata` 经 `u_resp` / `u_resp_b` 切出指令槽推入 `inst_fifo`。
> - **严格单口 FDIP 1 项回填缓冲 + 零 SRRIP/hit 耦合**：`icache_fdip` 新增 1 项 `fb_v_q` 锁存 AXI 回填行，仅在 `!demand_tw_we && !demand_idle_req`（此时 `!fdip_fb_busy` 保证 `req_valid_in=0`）时写入 `u_arr`；`eff_fdip_we` 选路仅读寄存 `repl_q`/`valid_q`，彻底切断旧版 `hit_onehot -> SRRIP -> bank_we` 组合长路。
> - **VIPT 别名安全**：`256 sets` 使用 8-bit 虚拟索引 `VA[13:6]`（跨出 4 KiB 页 2-bit）；Tag 强制保留完整 20-bit 物理 PPN `PA[31:12]`，`icache` 只读且 `FENCE.I` 全清 `valid_q`，天然免疫同物理页不同 VA 颜色别名。
>
> **2026-11-27 Clean BPU v11 + 同页跨行 2-Fetch 精简**：
> - 随着 BPU 精简为单块 1-Taken 并引入同页跨 64B 缓存行 2-Fetch（`block_bnd` 仅在 4KB 页边界截断），ICache Port B 仅在 `base[5:0] > 32 && base[11:6] != 6'h3f` 时并行读取下一条同页相邻缓存行 `line + 1`（必然同物理页、必然不同 Bank）；
> - 直接复用 Port A 的 `resp_ppn`，删除 ITLB 第 2 个只读 peek 口（`icache_itlb` 由 `NPEEK=2` 缩减为 **`NPEEK=1`**，仅保留 `peek_fdip_*`），并删除 `icache.sv` 中的 `b_same_page` / `b_same_line` 旁路；
> - `front_pred_path` 对送往 `icache_fdip` 的 `fdip_s2_{en,va,clear}` 打 1 拍寄存（切口 B1），彻底切断 BPU S2 (`ovr/fin.next`) 到 FDIP 8 项去重 CAM 的跨模块长路径。
>
> **2026-11-26 `rtl/area-opt` 严格 1 拍同步 SRAM 升级（0 周期变化）**：
> - `icache_arr.sv` 4 个数据 bank（共 32 KiB，4×16×8×512b）由异步读切换为严格 1 拍同步 1R1W `ttg_sram_1r1w`（`WRITE_FIRST=1`）；
> - 借助 `front_fifo.next_rdata` / `fetch_addr_fifo.next_rd_*` / `front_fetch_buf.ic_next_{fa,b}_idx` 与 `icache_ctl.arr_next_{req_valid,rd_index}` 在 `T-1` 拍预发起读地址（VIPT 索引 `[11:6]` 虚实一致，且 `fa_head_fresh` 保证队首不于入队同拍弹出），内置 `` `ifndef SYNTHESIS `` SVA 断言逐拍校验预发起行号 100% 命中，77 测例 + 152 `riscv-tests` 零周期变化。
>
> **EXP-053 前端结构清理（Phase 1 + Phase 2）升级**：
> 1. **真 4-Bank 1R1W 阵列（`icache_arr.sv`）**：按 `set[1:0]` 显式拆成 4 个独立 1R1W bank（每 bank 16 组 × 8 路，综合落 7 个 `$mem_v2`）并配并行 SRRIP 更新，单模块面积由 916,659 降至 **389,270 单元（−57.5%）**；
> 2. **FDIP 去旁路一致性探针（P2-1，`icache_fdip.sv` / `icache.sv`）**：彻底删除跨子系统 `fdip_snoop_dirty` / `fdip_snoop_line` 旁路，改为 FDIP 预取发射前借既有 `dc_req` / `dc_resp` 通道发起 1 拍 DCache/WB/MSHR/fill 一致性探针（与 demand 探针互斥，命中或忙时让行）；同时删除 `resp_popped_q` 回波补丁（根治于 `axi_cpu_port_chan` 通道 0 的 `CLEAR_ON_POP=1`）；
>
> **EXP-051 里程碑 B 升级**：
> 1. **4-Bank 1R1W 数据/标签阵列**（`icache_arr` 按 `set[1:0]` 分为 4 bank，每 bank 16 组 × 8 路）：同拍支持需求块 A 与配对块 B（`fetch_second`）并行读出（同 64B 行时直接复用 A 的命中行，否则跨 bank 并行查读），不改变需求侧任何单块时序；
> 2. **2 读口只读 ITLB Peek**（`icache_itlb` 复用 `tlb_mmu_core` 的 2 个只读 CAM peek 口，零额外 PTW walker）：口 0 服务跨 4KB 页配对块 B 翻译，口 1 服务 FDIP 队首虚拟地址翻译，无副作用、不改替换状态、不触发页表遍历；
> 3. **S2 确认 2-Slot 实 AXI FDIP**（新增 `icache_fdip.sv`）：需求侧事务号收窄至 `0..7`，FDIP 独占 `8..9` 复用 `MASTER_ICACHE` 且严格让位于需求请求；8 项循环 VA 队列在 `refetch || bpu_ovr || fence_i` 清空、接收 S2 确认的 `predict_next_fetch_address` 以及配对块 B ICache 缺失行；每拍至多弹出 1 项队首（无组合 `while` 环），响应回填在 `!tw_we` 时经单写口写入并更新 SRRIP。

## 1. 职责

取指地址队列的队首地址进来，一个取指组出去。做五件事：

1. 把取指的虚拟地址交给 ITLB（指令 TLB）翻译，得到物理页号，或页故障；
2. 用物理页号在缓存阵列里查：命中就从缓存行里按地址切出 16 个槽的取指组（见 5.1）；
3. 缺失就通过 AXI 读口取一整行（物理地址 < 0x40000000 的取指不缓存，只取一个字，`mem_req_bypass = 1`），同时向 DCache 探针问同一行的 16 个字（自修改代码：DCache 里有更新的数据时用 DCache 的），回填一路；
4. 响应重取指（`refetch`）、FENCE.I（作废全部有效位）、SFENCE.VMA（`itlb_flush`）、预译码冲刷（`invalidate`，同拍的第二步）：取消在途请求和在途缺失；
5. 请求在途时记账 AXI 事务号：被取消的缺失的迟到响应要丢掉。

现行结构（2026-11-28，`rtl/fe-2ahead`）是两级流水：**F0** 用寄存的取指地址查 ITLB 和按 `idx[0]` 分奇偶两组的触发器标签 / 有效位，选出命中路后启动数据 SRAM 读；**F1** 拿到 Lo / Hi 两半的数据，由 `icache_resp`（A 块）和第二个 `icache_resp`（`u_resp_b`，B 块）切出取指组。B 块是同页下一行（取指块跨 64 字节行但不跨 4 KiB 页时，`b_is_pair` / `b_is_tail`）。另有 `icache_fdip`：接 BPU S2 确认的下一取指地址（`fdip_s2_*`，前端已打一拍），8 项去重队列（`FDIP_Q = 8`）、2 个 AXI 预取事务（`FDIP_N = 2`，事务号从 `FDIP_TX_BASE = 8` 起）和 1 项回填缓冲 `fb_v_q`（只在需求侧不写阵列时写入，保证阵列单口）。

模型里是一个调度单元 `front.core.icache`（`ICacheTop`）：`comb_fetch` 做取指步 N，`comb_invalidate` 做预译码冲刷的第二步 K；时序更新在 `seq`。RTL 的模块边界是为综合划的，模型里没有对应的类（`icache_module.cpp` 的 `ICache` 是它的状态机）。

## 2. 配置（`ttg_cfg_pkg` / `icache_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 路数 × 组数 | 4 × 256，每行 64 字节（Lo-32B / Hi-32B 分体，共 64 KiB） | `ICACHE_WAY_NUM`、`ICACHE_SET_NUM`、`ICACHE_LINE_SIZE`、`ICACHE_WORD_NUM` |
| 标签 | 20 位（强制保留完整物理页号 `PA[31:12]` 以免 VIPT 别名歧义） | `ICACHE_TAG_BITS` |
| 组索引 / 行内偏移 | 8 位虚拟索引（`VA[13:6]`）/ 6 位（`[5:0]`） | `ICACHE_INDEX_BITS`、`ICACHE_OFFSET_BITS` |
| 取指组 | 16 个槽，每槽一个 32 位窗口（从该半字起的 4 个字节） | `FETCH_WIDTH = 16`、`RVC_ENABLE = 1` |
| ITLB | 64 项（`tlb_mmu_core`，一个取指端口，`FETCH = 1`，F0 查询） | `ITLB_ENTRIES` |
| AXI 事务号 | 16 个（4 位 id，`0..7` 需求、`8..9` FDIP） | `IC_TXID_N`、`IC_TXID_W` |
| 缓存行请求 | 总长 63（= 行字节数 - 1） | `mem_req_total_size`（`icache_ctl`） |
| 不缓存的取指 | 物理页号高两位为 0，即物理地址 < 0x40000000，总长 3，旁路 | `ic_is_uncache`（`icache_pkg`） |
| 替换 | SRRIP（4 路每组 `IC_WAYS×2 = 8` 位 RRPV；先用无效路，否则 RRPV 最大路，无效时退回全局指针 +1） | `icache_arr`：`repl_q`；`icache_swap`：`replace_next` |
| 存储容量 | 数据 `Lo/Hi` 各 `1024×256b` 1RW（`16 × 1024×32` 宏）；标签 `2×4×128×20b`、有效位 `1024b`、SRRIP `256×8b`（Even/Odd FF） | `icache_arr`：`DATA_DEPTH = IC_WAYS × IC_SETS`、`HALF_W = IC_LINE_W / 2`、`BSETS = IC_SETS / 2` |
| FDIP | 8 项地址队列、2 个预取事务、1 项回填缓冲 | `icache_fdip`：`FDIP_Q`、`FDIP_N`、`FDIP_TX_BASE` |

数据 SRAM（`ttg_sram_1rw`）在复位里清零，见 [common.md](common.md) 4.1 节。

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n` | |
| 入 | `req_valid`、`fetch_address` | 统一 FTQ 的 IFU 队首（`fa_rd_valid / fa_rd_address`，见 [front_top.md](front_top.md)） |
| 入 | `fdip_s2_en`、`fdip_s2_va`、`fdip_s2_clear` | BPU S2 确认的下一取指地址送 FDIP（`front_pred_path` 已打一拍）；`clear` = 全局 refetch 或 S2 覆盖 |
| 入 | `refetch`、`itlb_flush`、`fence_i`、`invalidate` | 全局重取指、SFENCE.VMA、FENCE.I、预译码冲刷（`do_predecode_flush`） |
| 入 | `csr_status_satp / privilege / mxr / sum / mprv / mpp` | ITLB 的翻译条件 |
| 入 | `mem_req_ready / accepted / accepted_id`、`mem_resp_valid / id / data[16]` | AXI 读口：请求被接收的脉冲和事务号、响应 |
| 入 | `dc_resp_valid / retry / miss / data` | DCache 探针的响应 |
| 入 | `ptw_walk_req_ready`、`ptw_walk_resp_*` | 页表遍历器对 ITLB 的响应 |
| 出 | `icache_ready` | 能接新请求：`!(itlb_flush | fence_i) & ifu_ready_q & !req_valid_q & !miss_txv & 状态为 IDLE` |
| 出 | `ic_inflight` | 在途取指数（0..2：F1 有效 + 登记槽有效），给 `inst_fifo_room` |
| 出 | `read_complete`、`fetch_pc`、`inst_valid[16]`、`page_fault_inst[16]`、`fetch_group[16]`、`fetch_upper_ok[16]`、`fetch_single_word` | A 块取指组；`fetch_upper_ok[i]` = 第 i 个窗口有真实的高半字；`fetch_single_word` = 不缓存的单字取指 |
| 出 | `b_hit`、`b_is_pair`、`b_is_tail`、`b_a_len`、`b_addr`、`b_actual_n`、`b_fetch_group[16]` | B 块（同页下一行）：是否命中、是跨行续接还是只取尾半字、A 块槽数、地址、有效槽数、取指组 |
| 出 | `mem_req_valid / addr / total_size / bypass / id`、`mem_resp_ready` | AXI 读请求（地址 32 位） |
| 出 | `dc_req_valid`、`dc_req_addr` | DCache 探针请求（一拍脉冲，没有 ready） |
| 出 | `ptw_walk_req_valid / vpn / root_ppn`、`ptw_walk_resp_consumed`、`ptw_walk_flush` | ITLB 向页表遍历器的请求 |

## 4. 结构

```
 req_valid/pc ─► icache_slot ─► mmu_req ─► icache_itlb (tlb_mmu_core, FETCH=1, NPEEK=1) ─► ppn_valid / page_fault / ppn ─┐
 refetch, fence_i, invalidate ─►  icache_ctl ◄───────── hit, hit_line, first_invalid ◄── icache_arr ◄─ rd_index, cmp_tag ┘
                                   ├ icache_idle  : 空闲态一步（快速通路、登记通路、缺失分配）
                                   ├ icache_swap  : 缺失服务一步（发请求、等响应、等探针、回填）和 CANCEL_WAIT
                                   ├ icache_kill  : 取消一步 K（作用于 R0 或 R1）
                                   ├ icache_txn   : AXI 响应分类（有效 / 被取消 / 孤儿）
                                   ├ icache_probe : DCache 探针一步
                                   └ 响应 ─► icache_resp ×2 : 从 A 行 / B 行切出取指组（u_resp / u_resp_b）
 fdip_s2_* ─► icache_fdip : 8 项去重队列、2 个预取事务、1 项回填缓冲 ─► icache_arr 的回填写口（需求侧空闲时）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `icache.sv` | 264 | 顶层：F0 → F1 两级（`f1_q`）、A / B 两路响应、连线、`ptw_walk_flush` 在复位后第一拍也置位 |
| `icache_pkg.sv` | 95 | 参数、`ic_regs_t`（控制寄存器）、复位值、状态编码、地址函数 |
| `icache_ctl.sv` | 238 | 例化下面各块，选择、寄存器、冲刷合并、存储侧输出 |
| `icache_arr.sv` | 211 | 阵列：Lo / Hi 数据 SRAM（`ttg_sram_1rw` ×2）、奇偶两组触发器标签 / 有效位、A / B 两路命中比较、第一个无效路、SRRIP 选路与更新、FDIP 回填写口 |
| `icache_itlb.sv` | 100 | `tlb_mmu_core(LANES=1, FETCH=1, NPEEK=1)` 加结果映射；peek 口给 FDIP 翻译 |
| `icache_slot.sv` | 50 | 单项请求槽 `req_valid / req_pc / ifu_ready`、ITLB 请求 |
| `icache_idle.sv` | 58 | 空闲态一步 |
| `icache_swap.sv` | 125 | 缺失服务一步 |
| `icache_kill.sv` | 92 | 取消一步 |
| `icache_probe.sv` | 72 | 探针一步 |
| `icache_txn.sv` | 40 | 响应分类 |
| `icache_resp.sv` | 75 | 取指组切片（例化两次：A 行、B 行） |
| `icache_fdip.sv` | 284 | FDIP 预取：S2 地址去重队列、预取事务、1 项回填缓冲 |

状态：`ic_regs_t` 共 136 位（请求有效 1、请求 pc 64、`ifu_ready` 1、状态 3、缺失事务号有效 1 + 号 4（`IC_TXID_W`）、`ready_seen` 1、在途 16 + 被取消 16（`IC_TXID_N`）、探针 3 位控制 + 字号 4、`ppn` 20、替换指针 2（`IC_WAY_W`））；两个 512 位的数据寄存器 `resp_line_q`（响应行）、`probe_line_q`（探针行，按字写使能）；阵列；替换状态 `repl_q`（`IC_SETS` = 256 组 × `IC_RB` = 8 位，复位清 0，`fence.i` 不清）；F0 → F1 寄存器 `f1_q`；FDIP 的队列、事务槽和回填缓冲；ITLB 的 64 项。

状态机 5 个状态（`ic_state_e`）：`IC_IDLE`；`IC_SWAP_REQ`（缺失，AXI 请求还没被接收）；`IC_SWAP_WAIT`（已被接收，等响应）；`IC_WAIT_DC`（响应已到，等探针完成）；`IC_CANCEL_WAIT`（缺失被取消，但请求刚好在被接收的路上，等一拍让接收脉冲过去）。模型是（状态，AXI 状态）两个量，AXI 忙只出现在 SWAP_IN，合成一个 5 态编码；模型的 `DRAIN` 没有任何入口，不编码。

### 一次冲刷拍里的双步

预译码冲刷那一拍（`invalidate = 1`）模型先做取指步 N，再做取消步 K。RTL 一次组合求值：`R1 = kill1 ? K(R0) : N(R0)`（`kill1 = refetch | fence_i`），`R2 = invalidate ? K(R1) : R1`，`R2` 是时钟沿装载的值。取指组和阵列写口只看第一步（`resp_valid = !kill1 & ...`，不含 `invalidate`），存储侧输出（AXI 请求、`mem_resp_ready`、DCache 探针请求）取最后一步：`invalidate ? K(R1) : (kill1 ? K(R0) : N(R0))`。冲刷拍里 K 在 SWAP_IN 会先走一次探针，因此可能新发一条 DCache 探针请求（保留了模型行为）。

## 5. 一拍内的数据流

### 5.1 取指组的切片（`icache_resp`）

槽 i 的窗口 = 从行内半字 `pc[5:1] + i` 起的 32 位（`{半字[h+1], 半字[h]}`）；半字下标超出这行的槽无效；行的最后一个半字的窗口高半是 0（`upper_ok = 0`）。页故障时 16 个槽全有效、全带 `page_fault_inst`、指令字为 NOP（`0x00000013`）。不缓存的响应只有一个字：槽 0、1 有效，槽 1 的高半为 0。`fetch_pc = resp_valid ? resp_pc : 0`。（`RVC_ENABLE = 0` 时改成按字切、16 个字槽，该分支未用于当前配置。）

### 5.2 请求、查表和快速通路

1. `icache_slot`：`mmu_req_valid = !kill & (登记槽有效 | (req_valid & 槽空闲))`，`mmu_req_vtag` 取登记槽的 pc 或本拍的 pc（不依赖 ITLB 的回答，没有组合环）；
2. ITLB 回答 `ppn_valid / page_fault / ppn`（未命中则 `ppn_valid = 0`，下一拍再问）；
3. 阵列读：`rd_en = !refetch & (req_valid | 登记槽有效)`，组索引取登记槽或本拍 pc 的 `[13:6]`（`ICACHE_INDEX_BITS = 8`，VIPT：比 4 KiB 页多 2 位）；比较条件 `cmp_valid = IDLE & !kill1 & ppn_valid & !page_fault & (...)`，比较标签 = ppn；最低的匹配路命中；
4. 空闲态一步：**快速通路**——本拍新来的请求且 ITLB 已有回答（`fast = !req_valid_q & req_valid & ppn_valid`），命中或页故障就当拍回答；**登记通路**——否则请求登记到槽里，之后每拍用登记的 pc 重试，直到答出。登记的请求缺失（`ppn_valid & !page_fault & !hit`）则分配一个空闲事务号，进 `IC_SWAP_REQ`；
5. 缺失服务：发 AXI 读（`mem_req_valid = SWAP_REQ & !accepted`）；被接收后若响应还没到，进 `SWAP_WAIT`；响应到（`gnt`）后若探针已完成就回填，否则进 `WAIT_DC`；回填：写一路（`tw_we = finish & !不缓存`），同拍把行作为取指响应；探针 16 个字全命中时，回填并响应的是探针行（DCache 里的更新数据），否则是内存行；
6. 取消：`refetch | fence_i` 时 K：丢掉登记请求、`ifu_ready` 置 0；在途缺失：请求已经出去（或本拍被接收）就把事务号标为"被取消"，迟到的响应由 `icache_txn` 判为丢弃并用 `mem_resp_ready` 吞掉；若请求已经 `ready` 但接收脉冲还没来则进 `CANCEL_WAIT` 等一拍；否则直接释放；
7. `icache_ready` 来自寄存器；取消后 `ifu_ready` 当拍恢复（除非 AXI 接收脉冲还要等，由 `accepted_now` 压住），这是固定行为，没有开关。

**替换状态（SRRIP）**：RRPV（re-reference prediction value，再访问预测值，0 = 预计很快再用，3 = 预计很久不用）。

- 读：与标签 / 有效同一个组索引（`rd_index`），异步读，看到的是本拍开始时的值；
- 命中（`hit`，即比较有效且某路匹配）：该路置 0；
- 回填（`tw_we`）：先把整组"变老"到最大值为 3，再把回填的路置 2；
- 命中只发生在 IDLE、回填只发生在缺失服务态，同一拍不会同时有，写口一个；写在时钟沿生效；
- 选路（`icache_swap`，`gnt` 那一拍算出、存进 `replace_idx`）：不缓存的取指不动；有无效路用第一个无效路；否则查表读有效（`rd_en`）时选 RRPV 最大的路（同值取路号最小），读无效时用旧的全局指针 +1。

`icache_probe`：缺失服务期间，对同一行的 16 个字逐个向 DCache 发探针（不缓存的取指没有探针，直接完成）；响应可以要求重试（原字重发）；某个字缺失就整个探针算不命中；16 个字都命中才算命中。

## 6. 关键路径与深度

### 6.1 `rtl/fe-2ahead` 64 KiB (`256×4`) Lo-32B/Hi-32B 2 级串联 VIPT + 1-entry FDIP fill buffer（当前实测，`eda-07`，`clk=0.65ns`）

相比早期的"单拍 ITLB → 8 路全读异步阵列 → 512-bit 选中 → 取指队列"单拍大环，本轮改造将阵列拆分为 **Lo-32B / Hi-32B 2 级串联 Tag-then-Data (`F0→F1`) VIPT**，采用 **16× `TEM5N28HPCPLVTA1024X32M4SWSO` 严格 `1RW` 宏**，并加入 **1 项 FDIP fill buffer (`fb_v`)**，彻底消除了组合反馈环（`OPT-150`）与窄深拼宏造成的 4× 面积膨胀，同时让 `u_icache` 彻底退出 `front_top` 第一关键路径。

1. **Tier 0-elab 快速宏估算（`Fallback=0`）**：
   - `icache`：`Time=0.46s`，`Macros=16`（`16× TEM5N28HPCPLVTA1024X32M4SWSO`），`MacroArea=213,657.9`，`SRAM_ns=0.356`。
   - `front_top`：`Time=4.85s`，`Macros=117`（`16× 1024×32`、`8× 256×64`、`6× 256×72`、`87× 512×72`），`MacroArea=1,657,805.9`，`SRAM_ns=0.359`。
2. **Tier 1 Yosys+PrimeTime STA 实测（`PT_LINK_STATUS=1`、`mem_v2=0`、`fb_bb=0`、`unmapped_std=0`）**：

| 模块 / 配置 | Leaf | Seq | Macros | Macro 面积 | Logic+FF 面积 | Total 面积 | WNS_total / WNS_r2r (ns) | Levels | CPL (ns) | Fmax_T1 (GHz) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| `main (6c42731)` `icache` 32K (Tier 2a 历史参考) | — | — | — | — | — | 1,713,504.4 | — (WNS* -4.33) | — | — | — |
| `fe-2ahead` `icache` 64K 2 级 (Tier 1) | 349,502 | 31,258 | 16 (`1024×32`) | 213,657.9 | 276,838.0 | **490,495.9** (-71.4% vs 32K Tier 2a) | `-1.24` / `-1.12` (`pt_timing_reg2reg=-1.18`, `arrival=1.76`) | 77 | 1.82 | **0.529** (r2r 0.546) |
| `main (6c42731)` `front_top` 32K (Tier 1) | — | — | 436 | 3,495,845.0 | 876,338.6 | 4,372,183.6 | `-2.64` / `-2.13` (`pt_timing_reg2reg=-2.62`) | 92 | 3.13 | 0.304 |
| `fe-2ahead` `front_top` 32K (Tier 1) | — | — | 356 | 2,905,323.2 | 1,050,453.6 | 3,955,776.8 (-9.5%) | `-2.59` / `-1.90` (`pt_timing_reg2reg=-2.54` at `u_icache.u_arr`) | — | — | 0.309 |
| `fe-2ahead` `front_top` 64K 2 级 (Tier 1) | 1,231,646 | 111,888 | 116 (`16×1024×32`+BPU) | 1,642,622.9 | 1,039,644.6 | **2,682,267.5** (-38.7% vs main / -32.2% vs 32K) | `-1.82` / `-1.82` (`in->reg=-1.41`, `reg->out=-1.42`) | 64 | 2.30 | **0.405** (+33.2% vs main) |

3. **关键路径拆解**：
   - `icache` 独立综合（`t_yosys=133s`，`t_pt=21s`，`t_total=158s`，`TNS=-23,200.65`，`Violating=31,027`）：总最差路径 `pt_timing_max=-1.24ns` 为外部输入 `ptw_walk_resp_valid -> FF`（`in->reg=-1.24`, `reg->out=-0.00`, `in->out=-1.03`）；纯内部寄存器到寄存器路径 `pt_timing_reg2reg=-1.18ns`（`arrival=1.76ns`）位于 ITLB / `icache_ctl` 状态控制寄存器之间。
   - `front_top` 整前端综合（`t_yosys=375s`，`t_pt=64s`，`t_total=454s`，`TNS=-103,936.91`，`Violating=99,607`）：`u_icache` 已经完全退出前级关键路径（`32K` 时最差 `pt_timing_reg2reg=-2.54ns, arrival=3.03` 卡在 `u_icache.u_arr`），当前第一关键路径转移至 BPU 的 `u_pred_path.u_bpu.u_arrays.u_ftb1.u_wrb.rd_key[8] -> bk_addr[9] -> u_pred_path.u_bpu.u_arrays.u_ftb1.u_mem.g_bk[0].u_sram.g_512x72.g_t[0].u_macro/A[0]`。

### 6.2 历史基线参考（2026-11-19 SRRIP）

单模块综合深度 **70 层**（icache；2026-11-19，SRRIP 之后；之前 69；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_ctl.r_q [136]` 到 `\u_ctl.r_q [44]`。快速通路把取指地址、ITLB 查找、8 路标签比较、512 位命中路选择、16 路切片与取指侧展开/预译码压在同一拍里完成。

EXP-045 的 SRRIP 选路（4 个 RRPV 级各一个 `ttg_first_set`，再按级优先）只接在重填受害路的寄存器输入上，不在上述取指链上。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- 模型的 I-Cache **没有数据阵列**：命中后的指令字从功能内存读（`icache_top.h` 文件头：`the instruction words from the functional memory`），只维护标签和有效位；RTL 有真正的数据阵列（`IC_WAYS × IC_SETS` = 4 × 256 行 × 512 位，拆成 Lo / Hi 两个 `1024 × 256` 位 SRAM）。二者在自修改代码上靠 FENCE.I（作废有效位）和缺失时的 DCache 探针取得一致，由整核门禁（`fence-i-self-modify`）和 Linux 检验；
- 替换策略：模型的 `icache_module.cpp` 还读环境变量 `ICACHE_REPL`（`rr` / `plru` / `srrip`，只用于 EXP-045 的比较，默认 `srrip`）；RTL 只实现 `srrip`；
- 同页下一行的第二块读：模型在 `front_top.cpp` 里用 `ICacheTop::fetch_second`（功能内存读 + 标签 peek）；RTL 由同一次 F0 查 B 行标签、F1 读 Lo / Hi 实现（`b_*` 输出），周期一致靠 `fm_gate`；
- 模型的 PMU 分类（`drive_perf`）、`lookup_pending` 之类的 SRAM 查表模型、`std::exit` 自检：RTL 以可读逻辑翻译，不复刻；
- 模型的 `read_ready` 在 `reset` 时返回 true；RTL 的 `ifu_ready` 复位值为 0，因此复位释放后第一拍 `icache_ready = 0`（`icache_pkg.sv` 里 `IC_REGS_RESET` 的注释）。模型的 `ifu_req_ready_r` 复位值是 true，但参考的第一拍还会与上一次 comb 的 `ifu_req_ready` 输出相与，那个值复位后是 false。第二拍起两边一致（`ifu_ready_d` 每拍重算）。

RTL 与模型保持一致的细节（容易误判为 bug）：

- `replace_idx` 仍是一个**全局**寄存器（不是每组一个），存的是 `gnt` 那一拍选出的路（`replace_idx = replace_next`）；`WAIT_DC` 态回填用这个存下来的路（`tw_way = wdc ? r.replace_idx : replace_next`）；不缓存的取指不动它；查表读无效时选路退回"指针 +1"（模型同样）；
- SRRIP 的替换状态不随 `fence.i` 清除（有效位清掉后先用无效路，旧状态只影响之后的选路），模型同样；
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

- **64 KiB 2 级 VIPT + 2-Ahead 前端（`rtl/fe-2ahead`，本轮最新实测）**：
  - **77/77 全功能与逐拍周期门禁**：`JOBS=12 bash scripts/fm_gate.sh $PWD/build/core_fm/obj/core_tb $PWD/build/gate_ic64` → `PASS 77 FAIL 0 SKIP 0`，周期对 `scripts/ref_cycles.txt` 0 处不同，`SVA clean (0 assertion failures)`（与 `trace-model-fe-2ahead` 77 条定向/基准参考表逐程序逐拍严格相等）。
  - **Lint 检查**：
    - `python3 harness/tools/svlint.py rtl/frontend/icache/*.sv rtl/frontend/front_top/*.sv rtl/frontend/bpu/*.sv` → 0 errors；
    - `bash scripts/lint.sh rtl/frontend/bpu` → `lint ok (19 files, 1 dirs)`；
    - `bash scripts/lint.sh rtl/frontend/front_top` → `lint ok (3 files, 1 dirs)`；
    - `bash scripts/lint_chip.sh` → `lint_chip: 0 warnings/errors (build/lint_chip.txt)`。
  - **Tier 0-elab & Tier 1 Yosys+PrimeTime PPA 实测（`eda-07`，`clk=0.65ns`）**：详见 §6.1。
- **历史基线门禁（`main` / `exp/llc-plru` / EXP-045）**：当时 `scripts/fm_gate.sh` 67 个程序对当时的参考表（已删除）逐个相等；Linux 检查点窗口 s00–s12（各 400 万周期）13/13 PASS。
- **Linux 大规模窗口**：64 KiB VIPT 分支的 `linux_gate.sh` / `linux_segments_cmp.sh` 与 SPEC06 待在后续合入前补跑。
- **没有模块级的独立随机测试**：旧体系有随机 trace 生成器 + 33 个变异的回放测试（`tests/icache`，真实程序抓到约 25 个、其余 5 个只有随机能抓到：替换指针、写入路、探针重试、同拍接受的响应、`icache_ready` 与 `itlb_flush`），已随 `spec/` 退役，不在仓库里（旧表在本文件的 git 历史里：`git log -- docs/modules/icache.md`）。**待补**：给 `icache_ctl`（含冲刷合并）补一个"RTL 对状态机直译模型"的随机测试，尤其是那五类只有随机才能抓到的行为。

## 9. 参数与开关速查

`ICACHE_WAY_NUM`、`ICACHE_SET_NUM`、`ICACHE_LINE_SIZE`、`ICACHE_WORD_NUM`、`ICACHE_TAG_BITS`、`ITLB_ENTRIES`、`RVC_ENABLE`、`XLEN_BITS`（`ttg_cfg_pkg`）；`IC_TXID_N`、`IC_TXID_W`、状态编码、`IC_REGS_RESET`（`icache_pkg`）；`FDIP_Q`、`FDIP_N`、`FDIP_TX_BASE`（`icache_fdip`）。无开关。

## 10. 变更记录

- 2026-11-28（`rtl/fe-2ahead`，文档核对）：补 `icache_fdip.sv` 与 B 块 / FDIP 端口、文件行数、`ic_regs_t` 136 位、`repl_q` 256 × 8、组索引 `[13:6]`、SRAM 复位清零；删掉已不存在的 `FE_RFAST` 位 2、`FE_PAIR` / `ICacheCompactKernel.h` 的说法；门禁改为对 `scripts/ref_cycles.txt`。
- 本轮（`rtl/fe-2ahead`）：升级为 **64 KiB（`256 sets × 4 ways × 64B`）Lo-32B / Hi-32B 2 级串联 Tag-then-Data (`F0→F1`) VIPT ICache**：
  - 配置与生成：`trace-model-fe-2ahead/include/config.h` 改为 `ICACHE_WAY_NUM=4`、`ICACHE_INDEX_BITS=8`、`ICACHE_SET_NUM=256`、`ICACHE_TAG_BITS=20`，F0 → F1 两级流水是模型唯一实现（原 `FE_ICACHE_PIPE` 开关 2026-11-28 删除）；`gen_cfg.sh` 重生成 `ttg_cfg_pkg.sv`；`ttg_sram_1rw.sv` 新增 `DEPTH == 1024`（`TEM5N28HPCPLVTA1024X32M4SWSO`）硬宏映射。
  - RTL 实现：`icache_pkg.sv`、`icache_probe.sv`、`icache_idle.sv`、`icache_ctl.sv`、`icache_fdip.sv`、`icache_arr.sv`、`icache.sv` 及 `front_fetch_buf.sv` / `front_top.sv` 改为 strict 1RW Lo/Hi 两级取指流水与 1 项 FDIP fill buffer（`fb_v`），消除组合环（`OPT-150`）与 `4×` 拼宏面积开销。
  - 验证结果：`fm_gate` 77/77 PASS（0 diffs, SVA clean）；`lint_chip` 0 告警；`eda-07` Tier 1 `icache` 面积 `490,495.9`（`-71.4%` vs `main` 32K Tier 2a），`WNS -1.24ns`（`0.529 GHz`）；`front_top` 面积 `2,682,267.5`（`-38.7%` vs `main`），`WNS -1.82ns`（`0.405 GHz`，`+33.2%` vs `main`），关键路径已由 `u_icache` 退至 BPU `u_ftb1.u_wrb -> bk_addr[9]`。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`icache_arr` 升级 4-Bank 1R1W 支持同拍双块取指（`fetch_second`）；`icache_itlb` 启用 `tlb_mmu_core` `NPEEK=2` 只读 CAM 翻译口；新增 `icache_fdip.sv`（S2 确认 2-slot 实 AXI FDIP，txid `8..9`，8 项 VA 队列，1-pop/cycle，`issued` 保护 + `resp_popped_q` 抑制 1 拍回声 + 周期初 L1D/WB 脏行窥探）；修复 `IC_CANCEL_WAIT` 盲置 `mem_resp_ready`。Yosys 综合 `icache` 916,659 单元 / 106 层（路径起于 `u_ctl.r_q[136] -> mmu_req_vtag[4]`）；通过 `lint_chip` 0、`fm_gate` 68/68（含 `directed/fe_2taken_fdip.bin` 与 `fence-i-self-modify`）与 Linux 27 窗检查点对齐。
- 2026-11-19（`exp/llc-plru`，EXP-045）：替换从"全局轮转指针"改为每组 SRRIP（`icache_arr` 加 `repl_q` 与命中 / 回填更新，`icache_swap` 按 RRPV 选路）。29 个 SPEC06 高权重点几何平均 +0.42%（gobmk +3.2%）。

- 2026-11-17/18（exp/agu-share）：`16de223`（EXP-TLBPORTS 第 3 步）顺带改了 `icache_itlb.sv`（`tlb_mmu_core` 例化去掉 `LD_LANES` 参数、加 `req_is_store` 接常 0，是 DTLB 多端口化的接口随动，ITLB 行为不变）；I-Cache 本身没有改。
- 更早：见 git 历史（含 2026-11-14/15 的 RVC：半字窗口、`fetch_upper_ok`、C910 风格携带，`e784f05` 等）。
