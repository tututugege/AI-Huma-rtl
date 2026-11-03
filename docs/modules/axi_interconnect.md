# axi_interconnect（AXI_Interconnect.cpp，LLC 打开的活路径）设计笔记

状态：设计 + RTL + 锁步结果见第 8 节。参考：`axi-interconnect-kit/axi_interconnect/AXI_Interconnect.cpp`（3699 行，活代码约 900 行）。
配套：`docs/modules/axi_llc.md`（LLC 本体）、`docs/analysis/axi-record-hook.patch`（录制点）、`spec/axi_interconnect.io`、`spec/axi_subsys.io`。

## 1. 边界与时序

* 整个互连每 CPU 周期跑 16 个 tick（见 `memsys-boundary.md` §4）；每 tick：`comb_outputs → (主口驱动) → comb_inputs → seq`，RTL 是单时钟、每 tick 一个 `clk` 沿，输入 `phase0` = tick 0。
* 模块 `axi_interconnect` = 互连本体（`rtl/memsys/axi_interconnect/`），**LLC 在模块外**：LLC 输出（`lo_*`、`hz_*` 寄存器）是输入，互连送给 LLC 的（`li_*`）是输出；`axi_subsys`（`rtl/memsys/axi_subsys/`）把 `axi_interconnect` 与 `axi_llc` 连起来。三个锁步 spec：`axi_interconnect.io`（LLC 边界开环）、`axi_llc.io`、`axi_subsys.io`（整体，主口 + DDR 从口）。
* DDR 侧 = testbench 的 sim_ddr（256 位 beat，6 位 ID）；MMIO 口不可达（见 §4）。
* 主口：read[0]=ICache、read[1]=DCache MSHR、read[2]=UNCORE_LSU（未用）、read[3]=外设；write[0]=DCache WB、write[1]=外设。ICache/外设只在 tick 0 驱动（其余 tick 被 `mask_axi_cpu_boundary_for_internal_tick` 清零）。
* **录制值与观察点**（`TTG_AXI.t[tick]`，补丁 `axi-record-hook.patch`）：`b_*` = comb_inputs 时刻的主口请求（真实每拍请求），`o1_*` = comb_outputs 之后的输出（响应 valid/id/data、`accepted`、DDR `rready/bready`），`o2_*` = comb_inputs 之后（`req.ready`、DDR AR/AW/W），`d_*` = sim_ddr 的从口信号（comb_outputs 时刻采样）。

## 2. 推翻/修正分析报告中的说法（实测：68 程序 × 默认 4 MiB LLC，上限 30 万周期；另测 32KB/16 路、8KB/4 路、16KB/2 路三种缩小 LLC，总计 4×23.8M tick）

工具：`axi-record-hook.patch`（每 tick 录制）、`docs/analysis/tools/axi_stat.cpp`（每 tick 统计插件）、gcov（`axi_mkcov.sh`/`axi_runcov.sh`，只给两个 AXI 源文件加插桩）。补丁对输出逐字节一致（6 个程序：关闭钩子/开启钩子+统计插件，stdout 含周期数全部相同）。

| 报告里的结论/待核实项 | 实测 |
| --- | --- |
| "两次 `llc.comb()` 是否总产生相同 `ext_out.mem`" | **成立**：4 种 LLC 几何、全部 tick（含 CPU 周期 1）里，comb_outputs 的第一次与 comb_inputs 的最终一次 `ext_out`（mem + upstream 全字段）逐字段相同（23,800,930 / 23,800,930 tick，缩小 LLC 同样全等）。（补丁早期版本的 tap 在第 1 个周期结束时才打开，曾因此统计出"每程序前 16 tick 不同"，是录制假象，已修。）RTL 只实现最终一次。 |
| "LLC 查表窗口内是否出现同组写" | 4MB LLC：窗口内同组写 **0 次**（其他组的写 42 次）；缩小 LLC：32KB/16 路 27 次（t+1:2、t+2:25），8KB/4 路 50 次，16KB/2 路 56 次（涉及 dcache-conflict-writeback、memory-stress(-small)）。所有 104k-136k 次查表的交付延迟恒为 3 tick。表读无需写穿旁路：读地址寄存 3 拍后在 t+3 异步读，天然看到 ≤t+2 的写（LLC RTL 如此实现）。 |
| "MMIO 从口因 `AXI_KIT_DDR_BASE=0` 不可达" | 成立：MMIO AR/AW/W 有效计数 0、MMIO 从口活动 0、`ar_latched_mmio/aw_latched_mmio/w_active_mmio` 恒空；`classify_downstream_port` 恒为 DDR。 |
| "非 LLC 路径、`AXI_Router_AXI4`、运行期模式/维护、预取、noalloc 是死代码" | 成立：gcov（4 种几何并集）AXI_Interconnect.cpp 可执行 2,927 行中 1,509 行执行过（其中含 tap 的 ~90 行），其余为 debug/perf/printf 与上述死路径；`mode=1`、`mapped_offset` 为常量，`reconfig_pending_`、`invalidate_*` 计数 0。 |
| `drop_resp_credit` 上界 | PTW 的 `walk_drop_resp_credit`：5 种配置 × 68 程序最大值 **0**（代码上无界）。 |
| 32 深队列的实际最大深度 | r_pending **8**（= MSHR 数）、`llc_upstream_write_q` **0**、`w_resp_queue` **0**、`llc_write_resp_delay` **1**、LLC `read_resp_q` **1**（仅缩小 LLC）、`read_victim_wb_q` **2**、LLC `write_q` **0**（tick 末）、同时在用 MSHR 8。RTL 取 8 / 无 / 无 / 2 / 2 / 4 / 2，带时钟断言。 |
| 外设 AXI 口 | **全程未触发**：read[3]/write[1] 在 68 程序中 0 次 valid（外设访问都在 PeripheralModel 里解决）；read[2] 也为 0。互连对这些口的逻辑是主口数组上的通用代码，无覆盖，**如实报告：未验证**。 |
| 主口"陈旧"请求 `a_*`（comb_outputs 时刻）| tick 0：DCache 口被 `clear_axi_master_inputs` 清零（1,487,558/1,487,558），ICache 口 = 本拍 b（相等）；tick≥1：DCache 口 = 上一 tick 的 b（22.3M/22.3M 相等），其余口恒 0。**只影响 O1 的 `req.ready`（无人读）与 LLC 第一次 comb，RTL 不需要**。 |
| 同行 hazard 判断（AR 被挂起写阻塞、AW 被未完成读阻塞、写捕获被同行读阻塞） | 4 种几何、68 程序里**一次都没有生效**（tap 的 `dbg_*` 计数全 0）：这些是防御性逻辑，实现但没有任何程序能验证它们（变异 8/9/14/16 因此存活，见 §8）。 |

## 3. 状态与数据流（LLC 路径，全部 DDR、`mode=1`、无直映射）

C++ 的 `comb_outputs/comb_inputs/seq` 合并成"每 tick 一次次态函数"。下面是活的状态（`read_req_hold`、`w_pending`、`ar_latched_mmio`、`w_resp_queue`、`llc_upstream_write_q`、`llc_synth_*`、`llc_mem_ignored_b_count_`、`llc_mem_read/write 的 mmio/direct` 全部死，删除并断言）。

| 寄存器 | 含义 | C++ |
| --- | --- | --- |
| `req_ready_r[4]` `w_req_ready_r[2]` | ready-first 握手：先抬 ready，下一次请求仍在才接收。**ICache/外设/写口1 只在 tick 0 更新**（`restore_axi_internal_tick_boundary_state_except_dcache`），DCache 读写口每 tick 更新 | 1779 起 |
| `up_req[4]` `up_wreq[2]` | LLC 之前的每主口 1 项捕获槽（写数据 512b + strb 64b） | `llc_upstream_req/_write_req` |
| `stage`、`dispatch_rr` | 送给 LLC 的唯一一项（读或写），RR 6 口（先 4 读 2 写）；读被 LLC 拒绝且槽空时可被写抢占（`preempt_stalled_read_for_write`，6 次/68 程序） | `llc_core_req_stage_` |
| `rresp_*[4]` | LLC → 主口的读响应边界寄存器（接收条件：LLC 响应 valid ∧ 槽空 ∧ 非 fresh；主口 `resp.ready` 消费） | `llc_read_resp_*` |
| `w_resp_*[2]`、`wdelay[2]`(深 2，每项 age 位) | 写响应：LLC 给出 → 延迟 1 tick → `w_resp` 槽 → 主口 ready 消费 | |
| `ar_latch`、`r_pend[MSHR]` | DDR AR 请求 latch（arready=0 时保持）；在途读按 LLC mem id（=MSHR 槽）索引，保存 axi_id、beats、数据（2×256b）、`upstream_addr`（hazard、对齐提取） | `r_pending`（vector，顺序无关：同一时刻最多 1 项完成） |
| `aw_latch`、`w_cur`（active/aw_done/w_done/beats/数据）、`mem_wr_resp(_code)` | LLC 回写的 AW/W/B 通道；B 完成后给 LLC 一拍 `write_resp_valid` | |
| `rd_acc[4]`（+id）`wr_acc[2]` | 本拍 seq 置位、下一 tick 的 `req.accepted` | `read_req_accepted*` |
| `seen_*` | LLC 的读请求被发射后，同 (id,addr,size) 的"陈旧"请求不再重复发 AR | `llc_mem_read_issue_seen_*` |

组合关系（每 tick，按 C++ 顺序，括号为 C++ 行号）：

1. **读捕获**（comb_read_arbiter LLC 分支）：对每个主口 m：跳过条件 = `up_req[m].valid ∨ stage 正为该口读 ∨ !valid ∨ has_read_id_conflict`；否则 `m==DCACHE_R ∨ req_ready_r[m]` → 接收（ready=1，捕获），否则 `req_ready_r_n[m]=1`、ready=1。
   `has_read_id_conflict(m,id)`：r_pend 里有 orig_id==id 且 **m==0**（r_pending 的 master_id 恒 0——LLC 内存读的 orig_id 是 MSHR 槽号，所以 ICache 的 id 0/1 会与同号 MSHR 在途读冲突，**这是怪行为，必须复刻**）∨ stage 同口同 id ∨ `up_req` 同 id ∨ 本地 `rresp` 同 id ∨ LLC `read_resp_valid_r` 同 id ∨ LLC lookup 同 (master,id) ∨ 任一 MSHR 同 (master,id)。
2. **写捕获**：仅第一个 valid 且无同行读 hazard 的主口（`break`）：`w_req_ready_r[idx]` 已抬 → 接收，否则抬起；`w_arb_rr_idx` 在活路径里从不更新（恒 0），优先级固定 0 → 1。同行读 hazard：`up_req/stage/b_rd 请求/LLC lookup(读)/LLC mem 读请求/MSHR(读)/ar_latch/r_pend(未完成)` 任一同 64B 行。
3. **AR 发射**：`ar_latch` 有效则驱动 latch；否则 LLC `mem.read_req_valid ∧ ¬seen ∧ ¬latch ∧ ¬has_external_pending_write_hazard(addr)` → AR（`id` = r_pend/latch 未用的最小 6 位 ID；小读（≤32B）按 32B 对齐发单 beat 并在响应时右移提取；整行读发 2 beat）。
4. **AW/W**：LLC `mem.write_req_valid ∧ ¬mem_wr_resp ∧ ¬has_external_pending_read_hazard ∧ ¬w_active ∧ ¬aw_latch` → AW（与 latch 同路组合驱动）；`aw_done` 之后下一 tick 起逐 beat 驱动 W；`B` 与 `w_cur.id` 匹配且 `¬mem_wr_resp` 时 `bready`。
5. **LLC 输入**：`stage` 即送给 LLC 的读/写；`read_resp.ready = !rresp_valid ∧ ¬fresh`；`write_resp.ready = !w_resp_valid ∧ wdelay 数<2`；`mem.read_req_ready = ¬ar_latch ∧ (¬valid ∨ ¬hazard)`；`mem.read_resp_*` = r_pend 中第一个完成项（`extract` 则右移）；`mem.write_req_ready = ¬w_active ∧ ¬aw_latch ∧ ¬mem_wr_resp ∧ (¬valid ∨ ¬hazard)`。
6. **seq**：AR 握手 → r_pend 入表（同 tick R beat 在其后处理）；stage 弹出/抢占/调度；R beat 写入；LLC 读响应被 LLC 消费则释放 r_pend；rresp/写响应寄存器；AW/W/B 握手；`seen` 更新。

### 3.1 必须复刻的怪行为（可观察、会影响行为，登记为疑点）

1. **ICache 读 id 与 LLC 内存读的 MSHR 槽号冲突**（`has_read_id_conflict`，C++ 1427-1475）：`r_pending` 里 LLC 发出的内存读的 `master_id` 恒为 0、`orig_id` = MSHR 槽号，所以 ICache（master 0，id 0/1）的请求会被同号的在途 DDR 读卡住（并非真的同 id 事务）。变异 2 证明这是被观察到的行为。
2. **`accepted` 标志的 CPU 周期粘滞**：`restore_axi_cpu_boundary_state`（`rv_simu_mmu_v2.cpp`）在第 16 个 tick 之后把非 DCache 主口（read 0/2/3、write 1）的 `read_req_accepted/_id`、`write_req_accepted` 换成整个 CPU 周期的 OR（id 取最后一次）；DCache 口每 tick 自然。tick 0 的 O1 因此看到粘滞值（变异 13、首次锁步失败即由此发现）。
3. **ready-first 寄存器只在 tick 0 更新**（非 DCache 主口，`restore_axi_internal_tick_boundary_state_except_dcache`），DCache 读口 `allow_same_cycle_accept` 当拍接收。
4. **写口优先级固定 0→1**（`w_arb_rr_idx` 在活路径里从不更新），且只处理第一个有请求且无同行读 hazard 的主口。
5. **读响应寄存器"fresh"**：LLC 的读响应在被置位后的那个 tick 不可被互连取走（`read_resp_fresh_r`）。
6. **写响应延迟线**：LLC 写响应 → 1 tick 延迟 → `w_resp` 槽（深 2，满则 LLC 不被允许交出）。
7. **小读单 beat 发射**：≤32 B 的请求被对齐到 32 B 发一个 beat，响应时按低 5 位右移提取（bypass 读，如 ICache 的 4 字节非缓存取指）。写同理按字节通道左移，但 68 程序里无 bypass 写（未验证）。
8. **`stage` 抢占**：被 LLC 拒绝且其槽空的读，会被另一行的写抢占，读退回其捕获槽（68 程序 6 次）。

## 4. 不翻译 / 常量化（证据）

| 项 | 依据 |
| --- | --- |
| MMIO 口、`direct_mmio_*`、synth 读响应、`w_pending`、`write_req_fire_c`、non-LLC AR/AW、`mode_transition`、`invalidate_*` | gcov 0 次（4MB 与 3 种小 LLC 并集）；`AXI_KIT_DDR_BASE=0` |
| `read_req_hold`、`req_drop_warned`、`r_arb_rr_idx`、`w_arb_rr_idx`（恒 0） | 无读者/恒值；hold 仅在 MMIO 分支置位 |
| `can_accept_read_master`、32 项总数/每主口上限 | LLC 分支不使用；LLC mem 在途 ≤ MSHR 数（8），ID 4 位足够 |
| `llc_upstream_write_q`、`w_resp_queue`、`llc_mem_ignored_b_count_` | 实测 0；RTL 用断言（时钟采样 `assert property`）保证不触发 |
| 外设口（read3/write1）时序 | 通用逻辑保留，68 程序零触发（未验证） |

## 5. 放宽 / 删除（06 §2-3）

* spec 去掉 `req.ready` 的 O1 值（comb_outputs 时刻）：DCache `req_ready` 无人读（`memsys-boundary.md` §2.1），ICache/外设读的是 tick 末（O2）；写口 `req.ready` 只比较外设口（端口 1）。
* `m_rd_resp_data`、DDR `wdata` 等 `when valid`。
* DDR `arsize/arburst/awsize/awburst` 恒 5/1（不比较）。

## 6. RTL 结构

`rtl/memsys/axi_interconnect/`：`axi_ic_pkg.sv`（常量/函数）；`axi_ic_haz.sv`（写捕获用的同行读 hazard）；`axi_ic_rd.sv`（读捕获 + id 冲突）；`axi_ic_wr.sv`（写捕获 + 同行读 hazard）；`axi_ic_stage.sv`（捕获槽 / stage / 抢占 / `accepted` 寄存器）；`axi_ic_ar.sv`（AR/latch/r_pend/R/LLC 读响应）；`axi_ic_aw.sv`（LLC 回写 AW/W/B）；`axi_ic_resp.sv`（主口响应寄存器与写响应延迟）；`axi_interconnect.sv`（顶层，端口适配 + 连线）；`rtl/memsys/axi_subsys/axi_subsys.sv`（`axi_interconnect` + `axi_llc`，整体锁步用）。

## 7. 等价性说明（06 §0）

* comb_outputs/comb_inputs/seq 的 C++ 调用结构不复刻；`llc.comb()` 两次只实现最终一次（CPU 周期 1 除外，见 §2）。
* C++ 在 comb_inputs 里"预测式"驱动 DDR 的 AW（LLC 写请求直通，同 tick 可能被 latch 又被握手）按等价次态函数写成一拍规则：`aw_fire = awvalid ∧ awready`，未握手则 latch。

## 8. 验证与结果

锁步脚本 `scripts/lockstep_ticks_axi.sh <module> <prog> [cpu_cycles]`（每 tick 一个 RTL 时钟，输出逐位比较）；68 程序驱动 `tests/axi_interconnect/run_all.sh`（`MODULE=axi_subsys|axi_interconnect|axi_llc`，参考侧几何 `TTG_LLC_KB/TTG_LLC_WAYS`，RTL 侧 `SETS/WAYS`）。

| 验证 | 模块 | 结果 |
| --- | --- | --- |
| 整程序锁步，68 程序（61 gate + 4 vm + dhrystone/coremark/float），默认 4MiB LLC，上限 30 万周期（大程序 4.8M tick）| `axi_subsys` | **68/68 PASS** |
| 同上 | `axi_interconnect`（LLC 开环）/ `axi_llc` | **68/68 PASS** / **68/68 PASS** |
| 12 个短/大程序（含会产生驱逐/回写的 dcache-conflict-writeback、memory-stress(-small)、coremark、dhrystone 等），15 万周期，缩小 LLC：32KB/16 路、8KB/4 路、16KB/2 路 | `axi_subsys` | **12/12 ×3 PASS**（每个 240 万 tick）；`axi_interconnect` 同三种几何 **12/12 ×3 PASS** |
| **随机主口流量**（`tests/axi_llc/rand_axi.cpp`：驱动参考的 AXI_Interconnect + LLC + SimDDR，随机 DCache 读/写、ICache 读（含 4 字节非缓存 bypass）、外设读/写口、部分字节 strobe、同行读写竞争），每次 3 万周期 | `axi_subsys`（关闭 bypass 写与部分 strobe：LLC RTL 未实现）4 seeds × 3 种缩小 LLC | **12/12 PASS**（每个 48 万 tick）|
| 同上，全部特性打开 | `axi_interconnect`（LLC 开环）4 seeds × {4MiB, 8KB/4w, 16KB/2w} | **12/12 PASS**（含外设读写口、bypass 小写、部分 strobe、同行 hazard）|
| lint | `scripts/lint.sh rtl/memsys/axi_interconnect` | 干净（svlint S1–S12 + verilator -Wall）；`axi_subsys` 是装配顶层（需要像 `back_top` 那样在 `lint.sh` 里加一条装配规则，本任务不改共享脚本）|

随机驱动复制了 `rv_simu_mmu_v2.cpp` 里的每 tick 顺序与 CPU 边界适配（非 DCache 口掩码/捕获/累计/恢复），并在每个 CPU 周期之后像补丁版模拟器一样调用锁步插件的 `ttg_rec_cycle_end`；随机流量下参考模型的队列最大深度（write_q 0、upstream write_q 0、写响应延迟线 1、读响应队列 2、读受害者队列 7、r_pending 8）。

### 变异检查（18 个，一次构建、运行时选择，`tests/axi_interconnect/mut_ic.py`）

| # | 变异 | 结果 |
| --- | --- | --- |
| 1 | ready-first 握手去掉（立即接收） | 杀死（dcache-mshr-pressure，周期 65，`m_rd_accepted[0]`）|
| 2 | ICache id 与在途 LLC 内存读槽号冲突（C++ 怪行为）去掉 | 杀死（dcache-conflict-writeback，`m_rd0_req_ready`）|
| 3 | LLC lookup 的 (master,id) 不参与 id 冲突 | 杀死（同上）|
| 4 | 调度器固定优先级（非轮询）| 杀死（`li_rd_valid[1]`）|
| 5 | 被拒读被写抢占去掉 | 杀死（`li_rd_valid[1]`，周期 2599）|
| 6 | `seen`（陈旧请求）保护去掉 | **存活**：68 程序 × 4 几何 + 随机流量均不触发；该保护只在同一读请求被 LLC 重复呈现且 IC 已发 AR 时有意义，按 LLC 行为（发出后置 issued）不会出现，判为冗余但**无法证明**|
| 7 | AXI id 恒 0 | 杀死（`d_arid`）|
| 8 | AR 不被同行挂起写阻塞 | 程序全部存活；**随机流量杀死**（`d_arvalid`）|
| 9 | AW 不被同行在途读阻塞 | 程序全部存活；**随机流量杀死**（`d_awvalid`）|
| 10 | WLAST 恒 0 | 4MiB 存活（无 DDR 写）；缩小 LLC 杀死（`d_wlast`）|
| 11 | LLC 读响应不看 fresh | 杀死（周期 148）|
| 12 | 写响应延迟线深度限制去掉 | **存活**：需要同一主口有 2 个未决写；DCache WB / 外设都只有 1 个，协议上不可达（等价）|
| 13 | 非 DCache 口 accepted 粘滞去掉 | 杀死（周期 96）|
| 14 | 同行读 hazard 仍接收写 | 程序全部存活；**随机流量杀死**（`m_wr_accepted[0]`）|
| 15 | bypass 小读不从对齐 beat 右移 | 杀死（`li_mem_rd_resp_data`）|
| 16 | MSHR 读不参与写 hazard | 程序全部存活；**随机流量杀死** |
| 17 | 小写（bypass）不移到字节通道 | 程序全部存活（无 bypass 写）；**随机流量杀死**（`d_wdata`）|
| 18 | 写响应弹出不看同拍消费 | **存活**：同 12（需要同一主口两个相邻写响应）|

18 个里 15 个被杀死（9 个被程序、1 个被缩小 LLC 程序、5 个只被随机流量），3 个存活（6、12、18），理由见上。只有随机流量才能杀死的变异：5 个（8、9、14、16、17）。**程序里同行 hazard 判断从未生效（`dbg_*` 计数 0），这部分只由随机测试验证。**

## 9. 未验证 / 风险（如实）

1. 外设 AXI 读/写口在 68 程序里从未触发；只被随机流量覆盖（通用逻辑，等价性在随机下通过）。
2. LLC RTL 未实现 bypass 写与部分行写（`axi_llc.md` §5.1）：参考里 DCache 不会发这样的写，外设 AXI 写口不触发；用它们的流量会让 `axi_llc` 的 `bad` 断言触发。互连本体对这些写已验证（LLC 开环）。
3. 写响应延迟线、`seen` 保护、读 id 冲突里 LLC `lookup` 项等只在特定相对时序出现，变异 6/12/18 存活。
4. 队列深度是实测上界（r_pending 8，LLC 读响应队列 2，读受害者队列 8，LLC 写队列 2），带时钟断言；C++ 里是 32。
