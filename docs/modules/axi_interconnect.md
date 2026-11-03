# axi_interconnect（AXI_Interconnect.cpp，LLC 打开的活路径）设计笔记

状态：设计 + RTL + 锁步结果见第 8 节。参考：`axi-interconnect-kit/axi_interconnect/AXI_Interconnect.cpp`（3699 行，活代码约 900 行）。
配套：`docs/modules/axi_llc.md`（LLC 本体）、`docs/analysis/axi-record-hook.patch`（录制点）、`spec/axi_interconnect.io`、`spec/axi_subsys.io`。

## 1. 边界与时序

* 整个互连每 CPU 周期跑 16 个 tick（见 `memsys-boundary.md` §4）；每 tick：`comb_outputs → (主口驱动) → comb_inputs → seq`，RTL 是单时钟、每 tick 一个 `clk` 沿，输入 `phase0` = tick 0。
* 模块 `axi_interconnect` = 互连本体（`rtl/memsys/axi_interconnect/`），**LLC 在模块外**：LLC 输出（`lo_*`、`hz_*` 寄存器）是输入，互连送给 LLC 的（`li_*`）是输出；`axi_subsys`（`rtl/memsys/axi_subsys/`）把 `axi_interconnect` 与 `axi_llc` 连起来。三个锁步 spec：`axi_interconnect.io`（LLC 边界开环）、`axi_llc.io`、`axi_subsys.io`（整体，主口 + DDR 从口）。
* DDR 侧 = testbench 的 sim_ddr（256 位 beat，6 位 ID）；MMIO 口不可达（见 §4）。
* 主口：read[0]=ICache、read[1]=DCache MSHR、read[2]=UNCORE_LSU（未用）、read[3]=外设；write[0]=DCache WB、write[1]=外设。ICache/外设只在 tick 0 驱动（其余 tick 被 `mask_axi_cpu_boundary_for_internal_tick` 清零）。
* **录制值与观察点**（`TTG_AXI.t[tick]`，补丁 `axi-record-hook.patch`）：`b_*` = comb_inputs 时刻的主口请求（真实每拍请求），`o1_*` = comb_outputs 之后的输出（响应 valid/id/data、`accepted`、DDR `rready/bready`），`o2_*` = comb_inputs 之后（`req.ready`、DDR AR/AW/W），`d_*` = sim_ddr 的从口信号（comb_outputs 时刻采样）。

## 2. 推翻/修正分析报告中的说法（实测，68 程序，上限 30 万周期，另测 4 种缩小 LLC）

| 报告里的结论 | 实测 |
| --- | --- |
| "两次 llc.comb() 是否总产生相同 ext_out.mem" 未验证 | **成立**：68 程序、全部 tick（含 CPU 周期 1）里第一次（comb_outputs）与最终一次（comb_inputs）的 `ext_out`（mem 与 upstream 全部字段）逐字段相同。（注意：补丁早期版本的 tap 在第 1 个周期末才打开，曾因此统计出"每程序前 16 tick 不同"——是录制假象，已改为在第 1 拍之前打开。）RTL 只实现最终一次。 |
| MMIO 从口不可达 | 成立：MMIO AR/AW/W 有效计数 0，从口活动 0，`AXI_KIT_DDR_BASE=0` 使 `classify_downstream_port` 恒为 DDR。 |
| 非 LLC 路径、`AXI_Router_AXI4`、运行期模式/维护、预取、noalloc 是死代码 | 成立（gcov：这些行 0 次；`mode=1`、`llc_mapped_offset` 为常量）。 |
| LLC 表读 t 发请求 t+3 交付 | 成立：104,284/104,284 次交付延迟恒为 3 tick。**同组写进入查表窗口：4MB LLC 为 0 次，32KB/16 路为 27 次（age2 ×2、age3 ×25）**——必须精确建模（LLC RTL 用寄存的 index 流水 + 交付时异步读，自然正确）。 |
| `drop_resp_credit`（PTW） | 所有 68 程序 × 5 种 LLC 几何下最大值 0（代码上无界，RTL 取 ≥2 位饱和计数 + 断言，不属于本模块）。 |
| 队列 32 深 | 实测最大：r_pending 8（=MSHR 数）、llc_upstream_write_q 0、w_resp_queue 0、llc_write_resp_delay 1、LLC read_resp_q 1、read_victim_wb_q 2、LLC write_q 0（tick 末）。 |
| 外设 AXI 口活跃 | **未触发**：`b_rd_valid_m3`、`b_wr_valid_m1` 在 68 程序中为 0（外设 MMIO 全在 PeripheralModel 里建模，不走 AXI）。互连对 m3/w1 的逻辑是对 master 数组通用的，但无覆盖——如实报告。 |
| 旧说法 `A` 值 | comb_outputs 时刻互连读到的"陈旧"请求 `a_*`：tick 0 时 DCache 口被 `clear_axi_master_inputs` 清零，ICache 口 = 本拍 b（已验证 1,487,492/1,487,492 相等）；tick≥1 时 DCache 口 = 上一 tick 的 b（22,313,370/22,313,370 相等）；其余口恒为 0。**这些值只影响 O1 的 `req.ready`（无人读）与 LLC 第一次 comb，故 RTL 不需要它们**（只需 O2）。 |

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

（结果在文末"结果"节，由最后一次运行填写。）
