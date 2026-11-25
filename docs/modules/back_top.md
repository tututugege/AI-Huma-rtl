---
module: back_top
area: backend
rtl: rtl/backend/back_top
model: trace-model back-end/BackTop.cpp（`BackTop::init` 的接线、`BackTop::seq` 的顺序）；胶水的行为在模型里分散在 back-end/Rob.cpp（`Rob::redirect`、`Rob::report_commit`、`Rob::comb_commit` 里的 `rob_bcast_d`）。模型的 `BackTop` 本身没有 comb 阶段，不是调度单元
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；沿用 isu.md 记录的验收结果，本文作者没有重跑）
depth: 142 层（back_top，单模块综合，2026-11-20，`SYNTH_ABC="strash;balance;map"`，生成门代理，见 09-synthesis-report 第 12 节）
---

# back_top 设计文档

范围：`back_top.sv`（后端的装配）、`back_top_glue.sv`（不属于任何子模块的几段逻辑）、`exu.sv`（执行单元的装配：`exu_ctrl` 加各 FU）。旧文档描述的是由 `tools/gen_backtop.py` 生成的版本和 lockstep 体系，现在这三个文件都是手工维护，没有沿用。

## 1. 职责

后端的顶层，只做连线和三段很小的逻辑，不做运算：

1. **装配 12 个实例**：`pre_idu_queue`（`u_pre`）、`idu`（`u_idu`）、`ren`（`u_ren`）、`dispatch`（`u_dis`）、`isu`（`u_isu`）、`prf`（`u_prf`）、`exu`（`u_exu`）、`csr`（`u_csr`）、`rob`（`u_rob`）、`tlb_mmu`（DTLB，`u_dtlb`）、`lsu`（`u_lsu`）、`back_top_glue`（`u_glue`）；后端和前端、DCache、MMIO、PTW 的边界就是这个模块的端口；
2. **全局 flush 晚一拍到达**（FLUSH_REG）：ROB 在第 t 拍决定一次全局 flush 并同拍清自己，三个寄存器 `rob_flush_q`、`rob_fence_q`、`rob_fence_i_q` 把它推迟一拍，再送给其余模块、前端重定向和 fence 广播（docs/FLUSH_REG.md）；
3. **胶水**（`back_top_glue`）：前端看到的 `out_mispred / out_stall / out_redirect_pc / out_rf_*`、DTLB 要的四个 `mstatus` 位、LSU 要的 AMO 子操作码；
4. **执行单元装配**（`exu.sv`）：`exu_ctrl` 与 FU 的连线和合同；
5. **LSU 写回作旁路源**（`lsu_byp_valid`，见 5.5）。

模型对应：`BackTop::init` 把各模块的 `out` 绑到其他模块的 `in`，RTL 里就是同名线网；模型里 flush 推迟是 `Rob::comb_commit` 生成 `rob_bcast_d`，前端重定向推迟是 `Rob::redirect` 里的 `pend_`；这两处在 RTL 里落在本模块的 `rob_flush_q` 寄存器和胶水。模型里 `Prf` 不存在，PRF 和执行单元的接线（`iss2prf`、`prf2exe`、`exe2prf`）是 RTL 才有的。术语：**胶水**指不属于任何子模块、只在装配层存在的逻辑。

## 2. 配置

| 项 | 值（常量） |
| --- | --- |
| 实例（文件行数） | `back_top.sv` 1660、`back_top_glue.sv` 103、`exu.sv` 657；子模块见各自文档 |
| 发射口、FU | `ISSUE_WIDTH = 21`，`TOTAL_FU_COUNT = 31`，6 个发射队列（`dis_pkg::IQ_NUM = 6`），唤醒通道 `MAX_WAKEUP_PORTS = 22` |
| 译码 / 提交宽度 | `DECODE_WIDTH = 8`，`COMMIT_WIDTH = 8`，`BACKEND_FETCH_WIDTH = 16` |
| 访存口 | `LSU_LDU_COUNT = 4`、`LSU_STA_COUNT = 3`、`LSU_SDU_COUNT = 3`、`LSU_AGU_COUNT = 7`、`LSU_AGU_SHARED = 2`、`LSU_AGU_PHYS = 5`（共用 AGU：load 口 8、9 与 STA 口 11、12；DTLB、LSU 的请求 / 响应数组按 5 个物理 AGU 配口，`back_top.sv` 的 `lsu2mmu_*`、`mmu2lsu_*`） |
| 寄存器 | 本层只有 `rob_flush_q`、`rob_fence_q`、`rob_fence_i_q`（各 1 位）和胶水里的 `redirect_pc_q`（`XLEN_BITS = 64` 位） |

`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。`back_top.sv` 和 `exu.sv` 文件头写的是"由 `tools/gen_backtop.py` 生成到 2026-11，生成器已删除"。

## 3. 接口

`back_top` 约 115 个端口声明（数组和打包向量各算一个），按方向和对端分组：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `front2pre_*`、`front_stall`、`bpu_upd_free`、`bpu_tq_free` | 前端送来的取指包（含预测元数据）、停顿、BPU 提交信用（紧凑 ROB） |
| 入 | `dcache2lsu_*`、`peripheral_resp_*`、`ptw_walk_resp_*`、`ptw_walk_req_ready` | 访存子系统、MMIO、页表遍历的响应 |
| 入 | `interrupt_inject_*` | 外部中断线，直接进 `csr` |
| 出 | `out_mispred`、`out_no_mispred`、`out_stall`、`out_redirect_pc`、`out_rf_valid / _pc / _is_rvc / _type / _ck / _epoch`、`pre2front_*`、`ftq_commit_info_*`、`commit_extra_*`、`out_commit_entry_uop_diag_val` | 给前端的重定向、停顿、BPU 训练和修复数据 |
| 出 | `rob_commit_commit_entry_*`、`rob_bcast_*`（flush、fence、fence_i、exception、interrupt、mret、sret、pc） | 提交信息和 ROB 广播，给前端、difftest 和测试台；其中 `rob_bcast_flush` 是 ROB 这一拍的决定（**未推迟**），`rob_bcast_fence`、`rob_bcast_fence_i` 是推迟一拍之后的值 |
| 出 | `csr_status_{mstatus, sstatus, satp, privilege}` | CSR 状态 |
| 出 | `lsu2dcache_*`、`peripheral_req_*`、`ptw_walk_req_*`、`ptw_walk_flush`、`ptw_walk_resp_consumed` | 发往访存子系统和 PTW |
| 出 | `dis2rob_dis_fire`、`pmu_slot_valid` | PMU 第一层事件 |

## 4. 结构

```
 front2pre ─► pre ─► idu ─► ren ─► dis ─► isu ─(iss2prf)─► prf ─(prf2exe)─► exu(exu_ctrl + FU) ─┬─(exe2prf)─► prf
   ▲                 ▲ exu2id（分支解析）     │ dis2rob/dis2lsu        ▲ exe2iss_fu_ready_mask    ├─(exu2rob)─► rob
   │                 └ dec_bcast_* ─► ren dis isu prf exu rob dtlb lsu glue            │ prf_awake                    ├─(exe2lsu)─► lsu ─(lsu2exe 写回)─► exu
   │                                                                                    └─► isu、dis    exe2csr ─► csr ─(csr2exe)─► exu
 rob ─(rob_bcast_flush)─► rob_flush_q ─► pre idu ren dis isu prf exu dtlb lsu；rob ─(mret / exception / pc …)─► csr、glue
 lsu ◄─► dtlb（按物理 AGU 的请求 / 响应）；lsu ─(lsu2iss_wake / cancel)─► isu、dis
 glue：out_mispred / out_redirect_pc / out_rf_*、mstatus 位、amo_op
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `back_top.sv` | 1660 | 装配 12 个实例；FLUSH_REG 寄存器块（第 1305..1321 行）；`lsu_byp_valid`；12 条无人读的输出接到具名悬空线（`nc_*`） |
| `back_top_glue.sv` | 103 | 见 5.3、5.4、5.5 |
| `exu.sv` | 657 | `exu_ctrl` + FU 的装配（见 5.6） |

重要的接线（"从谁到谁"，以 `back_top.sv` 为准）：

| 信号 | 从 | 到 |
| --- | --- | --- |
| `dec_bcast_{mispred, br_mask, clear_mask}`（及 `br_id`、`redirect_rob_idx`） | `idu` | `ren`、`dispatch`、`isu`、`prf`、`exu`、`rob`、`dtlb`、`lsu`、`glue`（`mispred`） |
| `exu2id_*`（分支解析、`clear_mask`、重定向） | `exu` | `idu` |
| `rob_flush_q`（推迟的 flush） | 本模块寄存器 | `pre`、`idu`、`ren`、`dispatch`、`isu`、`prf`、`exu`、`dtlb`、`lsu`；`rob` 收 `flush_pend`；`glue` 收 `flush_q` |
| `rob_bcast_flush`（ROB 这拍的决定） | `rob` | 寄存器输入；`glue`；`lsu`（`rob_flush_now`）；芯片端口 |
| `rob_bcast_{mret, sret, ecall, breakpoint, exception, page_fault_*, illegal_inst, trap_val, pc}` | `rob` | `csr`、`glue`（部分）和芯片端口；不推迟 |
| `rob_bcast_interrupt` | `rob` | `ren`、芯片端口；不推迟 |
| `iss2prf_*` / `prf2exe_*` | `isu` / `prf` | `prf` / `exu`；口 0 的 `csr_idx` 取 `prf2exe_iss_entry_uop_csr_idx[0]` 送 `exu`（CSR 固定在口 0） |
| `exe2prf_entry_*`（`[WB_LANES]`，寄存器写回总线，EXP-046）、`exe2prf_bypass_*` | `exu` | `prf` |
| `exe2iss_fu_ready_mask` | `exu` | `isu` |
| `prf_awake_*`（load 晚唤醒） | `prf` | `isu`、`dispatch` |
| `iss_awake_*`（唤醒广播） | `isu` | `dispatch` |
| `lsu2iss_wake_* / cancel_*` | `lsu` | `isu`、`dispatch` |
| `exe2lsu_*`（含 `*_req_occ`）、`lsu2exe_*`（写回） | `exu` / `lsu` | `lsu` / `exu`；`lsu2exe_wb_req_*` 另经 `lsu_byp_*` 去 `prf` |
| `exu2rob_entry_*` | `exu` | `rob` |
| `exe2csr_*`、`csr2exe_rdata / frm` | `exu` / `csr` | `csr` / `exu` |
| `rob2csr_*`、`csr2rob_*`、`csr2front_epc / trap_pc` | `rob` / `csr` | `csr` / `rob` / `glue` |
| `ftq_prf_pc_*`、`ftq_rob_pc_*` | `prf`、`rob` | `pre`（请求），`pre`（回答）回 `prf`、`rob` |
| `lsu2mmu_req_*`、`mmu2lsu_resp_*` | `lsu` / `dtlb` | `dtlb` / `lsu` |

## 5. 一拍内的数据流

### 5.1 发射 → 执行 → 写回的拍序

第 t 拍：ISU 授予，发射结果 `iss2prf` 同拍进 PRF，PRF 异步读出操作数（带旁路），经 `prf2exe` 在时钟沿写进 `exu_ctrl` 的槽。t+1：槽里的指令进 FU，FU 出结果；口内仲裁后赢家同拍变成 `exe2prf_entry`、`exe2prf_bypass`、`exu2rob`、`exe2lsu`、分支解析 `exu2id`；`exe2prf_bypass` 同拍旁路给 t+1 拍发射的指令的读口（单周期 FU 的"背靠背"）。t+2：写回级（t+1 拍进的结果）的值写进寄存器堆，同拍 load 的晚唤醒 `prf_awake` 广播（load 的写回级那一拍）。load 和 STA 的结果走 LSU：AGU 在 t+1 拍给 `exe2lsu` 请求，LSU 之后在口 6..9、10..12 上给写回请求（`lsu2exe`），再进写回级。

### 5.2 FLUSH_REG 块

`back_top.sv` 里一个 `always_ff`（复位清零）：`rob_flush_q <= rob_bcast_flush`，`rob_fence_q <= rob_fence_raw`，`rob_fence_i_q <= rob_fence_i_raw`，其中 `rob_fence_raw`、`rob_fence_i_raw` 是 ROB 的 fence 输出（`rob` 实例接到这两根线），`rob_bcast_fence`、`rob_bcast_fence_i` 端口取寄存后的值。哪些模块看哪个版本：

| 模块 | 看到的 flush |
| --- | --- |
| ROB | 自己 t 拍的决定 `rob_bcast_flush`（同拍清自己）；`flush_pend = rob_flush_q` 在 t+1 拍屏蔽陈旧的误预测恢复 |
| `pre`、`idu`、`ren`、`dispatch`、`isu`、`prf`、`exu`、`dtlb`、`lsu` | `rob_flush_q`（t+1 拍） |
| `lsu` | 另有 `rob_flush_now = rob_bcast_flush`（t 拍），限定"flush 这拍提交的 store 不能写出去" |
| `dtlb` | `rob_flush_q` 作 flush，`rob_fence_q` 作 fence |
| `csr` | 没有 flush 输入；陷入和 xRET 用 ROB 同拍的 `rob_bcast_*` |
| `ren` | flush 用 `rob_flush_q`；`rob_bcast_interrupt` 用同拍值（带中断退休的指令不算提交） |
| 前端 | `back_top_glue` 在 t+1 拍用 `flush_q` 重定向，见 5.3 |

### 5.3 前端重定向和停顿（`back_top_glue`）

- `flush_redirect_pc`（组合）：`mret / sret` 取 `csr2front_epc`；`exception` 取 `csr2front_trap_pc`；否则取 `rob_bcast_pc + (rob_bcast_is_rvc ? 2 : 4)`（`is_rvc` 来自 FTQ 的 ROB 口响应）。它每拍都存进 `redirect_pc_q`（无条件）。
- `out_mispred = flush_q | (dec_bcast_mispred & ~rob_bcast_flush)`：flush 决定的那一拍压住分支误预测（flush 优先），下一拍才重定向。
- `out_redirect_pc = flush_q ? redirect_pc_q : br_latch_redirect_pc`。
- `out_rf_valid = dec_bcast_mispred & ~rob_bcast_flush & ~flush_q`：只有分支误预测的重定向才做 BPU 历史修复，`out_rf_pc`、`out_rf_is_rvc` 取 IDU 的分支锁存。
- `out_stall = ~pre2front_ready`；`out_no_mispred = ~out_mispred`（边界规范里用它限定 `out_stall`）。

### 5.4 提交项的 `diag_val`（不覆盖）

`out_commit_entry_uop_diag_val[i]` 就是 ROB 提交项的 `diag_val[i]`，flush 时也不改。原来的实现在 flush 决定拍把它覆盖成重定向目标（模型 `Rob::report_commit` 同），前端训练用它当分支目标，结果是 flush 那一拍恰好提交的跳转 / 调用用陷入地址训练 BTB；加了 FLUSH_REG 之后模型的覆盖落在没有有效提交的推迟拍，等于不覆盖，RTL 仍在决定拍覆盖，Linux 窗口 s08 周期 2856352 出现训练目标不同（RTL `0x80000408` 是 mtvec，模型是调用的真目标）。现在 RTL 不覆盖，与模型一致。

### 5.5 其他胶水和装配层逻辑

- `csr_status_mstatus_{mxr, sum, mprv, mpp}`：取自 `mstatus` 的第 19、18、17、12:11 位，送 DTLB；
- `rob_commit_commit_entry_uop_amo_op[i] = func7[6:2]`，给 LSU 提交 store 时用；
- `lsu_byp_valid[k] = ((lp_pkg::LP_L2 & 9) == 9) && lsu2exe_wb_req_valid[k] && lsu2exe_wb_req_uop_dest_en[k]`：LSU 的写回请求作为 PRF 读口的旁路源（只在 `LP_L2` 的位 0 和位 3 都开时有效）。现行 `LP_L2 = 1907`（`lp_pkg.sv`）位 3 为 0，所以现行配置下这四路恒为 0；
- `unused_fp_issue`：把 `iss2prf_iss_entry_uop_dest_fp` 归约成一根无人读的线，消除未使用告警（目的寄存器是浮点还是整数由编号判断）。

### 5.6 `exu.sv` 与 FU 的合同

- `exu_ctrl` 之外实例化：`alu_bank`（6）、`bru_bank`（2）、`agu_bank`（`LSU_AGU_COUNT = 7`）、`sdu_bank`（3）、`mul_bank`（2）、`div_bank`（2）、浮点 FU（`FP_EN` 时 `N_FPU = 8` 个：FDIV 用 `fp_div_unit`，其余用 `fp_pipe_unit`，延迟取 `FP_FMA_LAT`、`FP_MISC_LAT`、`FP_I2F_LAT`），共 30 个；CSR FU 不实例化（`exu_ctrl` 自己处理 CSR 槽的握手）；
- 单周期 FU：`consume` 接 0，`complete` / `ready` 悬空到具名线，`exu_ctrl` 自己按"`complete = en`、`ready = !en || consume`"推；仿真断言 ALU 和 BRU 的 `complete == en`；
- 多周期 FU 按 `exu_ctrl` 的 MC 下标映射：`MC_MUL = {0, 2}`、`MC_DIV = {1, 3}`；`func3` 截成 2 位；`flush`、`flush_mask`、`clear_mask` 复制给每个实例；
- 浮点 FU 的舍入模式取 `csr2exe_frm`；
- 没有 F/D 时浮点组的所有 FU 侧信号接 0。

## 6. 关键路径与深度

depth: 142 层（back_top，单模块综合，2026-11-20，`SYNTH_ABC="strash;balance;map"`，生成门代理，见 09-synthesis-report 第 12 节）。已知的数字：整个 `back_top` 最近一次测量是 135 层（在本分支若干改动之前，这些改动之后没有复测）。以下是从代码读出的，未综合验证：

| 环路 | 内容 |
| --- | --- |
| ISU 选择 → 授予 → PRF 读 → 槽 | `isu` 授予 → `iss2prf` → `prf` 读口和旁路比较 → `prf2exe` → `exu_ctrl` 槽的寄存器；同时授予 → 唤醒 → 下一拍的就绪（isu.md 的 88 层环路）。这条路径跨三个模块 |
| 分支解析 → kill | `bru` 比较 → `exu_ctrl_br_arb` → `exu2id_mispred` → `idu` → `dec_bcast_*` → 扇出到 `ren`、`dispatch`、`isu`、`prf`、`exu`、`rob`、`dtlb`、`lsu` 的杀死逻辑 |
| ROB 提交 → flush → 陷入目标 | `rob` 提交 → `rob_bcast_*` → `csr` 陷入目标 → `back_top_glue` 的 `flush_redirect_pc` → `redirect_pc_q`；docs/FLUSH_REG.md 记录原来最长路径的头是这条（约 29 层）再经 AGU 使能、LSU 请求被接受进 DTLB，FLUSH_REG 把后半段切在寄存器上 |

本分支和深度有关的改动：

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| 全局 flush、fence 广播晚一拍 | `803692f` | ROB 提交 → trap → flush 不再进其他模块的组合路径；ROB 同拍清自己，晚一拍屏蔽陈旧误预测；周期对 `ref_cycles_memiq6_nr_int2_ev3.txt`（`CFG_FLUSH_REG = 1`） |
| AGU 槽占用 | `e49618c` | LSU 重放口分配看 AGU 槽的 `valid_q`（`exe2lsu_*_req_occ`），不经杀死逻辑；周期对 `ev2` |
| DTLB 每个物理 AGU 一个口 | `16de223`（`back_top.sv` 的数组宽度改为 `LSU_AGU_PHYS`） | 5 个物理 AGU、5 个 DTLB 口；周期对"212 参考"（提交说明） |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的，或两边不同的：

- **推迟的字段**：模型 `rob_bcast_d`（`CFG_FLUSH_REG = 1`）把 flush 和陷入的全部字段推迟一拍（head 信息、`interrupt`、`flush_now` 不推迟）；RTL 只推迟 `flush`、`fence`、`fence_i`，因为 `rob_bcast_*` 的其他字段只有 `csr` 和 `glue` 读（`back_top.sv` 里接线可见），它们在模型里也读未推迟的 `rob_bcast`（`SimCpu.cpp`：`csr.in.rob_bcast = &back.rob->out.rob_bcast`）；
- **`out_stall`**：模型在 flush 推迟的"决定那一拍"设 `o.stall = !pre2front->ready`，推迟的下一拍不赋值；RTL 的 `out_stall = ~pre2front_ready` 每拍都是。边界上谁读 `out_stall`（前端只在非重定向拍读它，所以边界规范有 `out_no_mispred` 限定）本文没有逐点核对；
- **`br_type`、`rf_pc`**：模型在 `Rob::redirect` 里从 FTQ 取 `rf_pc`、`rf_is_rvc`、`rf_type`；RTL 的 `out_rf_pc`、`out_rf_is_rvc` 取 IDU 的分支锁存（`br_latch_*`），`out_rf_type` 在 `pre_idu_queue` 里读出；
- **`tbhook::on_flush`、`run_interrupt_hook`、统计**：RTL 不带；
- **没有 trace bridge**：模型 `Rob::redirect` 在 flush 决定那一拍通知 trace bridge 倒回，RTL 没有对应物。
- **`diag_val` 不覆盖**：模型 `Rob::report_commit` 的覆盖 `if (o.flush) ... = o.redirect_pc` 在 `CFG_FLUSH_REG = 1` 时落在推迟拍，那一拍没有有效提交，所以对前端训练无效；RTL 也不覆盖（5.4）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- flush 决定那一拍分支误预测被丢弃，`out_rf_valid` 为 0；推迟的下一拍 `out_mispred` 为 1、`out_rf_valid` 为 0（模型 `pend_` 分支同）；

死线网和过时注释（没有改）：`back_top.sv` 有 12 条输出接到 `nc_*` 线（`csr2exe_rdata_vld`、`csr2front_epc_vld`、`csr2front_trap_pc_vld`、`dis2lsu_func3`、`dis2lsu_stq_flag`、`dis2rob_uop_func3`、`dis2rob_uop_is_atomic`、`ftq_prf_pc_resp_resp_valid`、`ftq_rob_pc_resp_resp_valid`、`mmu2lsu_resp_hit`、`rob_bcast_trap_val_valid`、`rob_commit_commit_entry_uop_mispred`）；`exu.sv` 文件头写"27 个功能单元"（实际实例化 30 个）、"boundary = spec/exu.io"（spec 已删除）、"MC 序是 `{MUL(0), DIV(3), MUL(5), DIV(7)}`"（现在是 FU 号 `{0, 3, 5, 8}`，下标 `{MUL 0, DIV 1, MUL 2, DIV 3}`）；`back_top.sv` 里注释"intentionally unread: listed in docs/modules/back_top.md"现在由本文第 7 节代替；`isu_wake_src.sv`（不属于本模块）的头注释写"14 个唤醒通道"，现在是 `WAKE_NUM = 22`。

未核对（继承自旧文档）：

- 旧文档的"集成问题"表（I-1..I-7）、"边界选择（SimCpu 侧 / 后端侧）"和"已知未验证项"（difftest 直接观测的状态、复位只验证全零输入 3 拍等）：描述的是已退役的 lockstep 验证体系，本文没有重新核对；
- 旧文档的连线统计（实例数、端口数、线网数）：已不适用。

## 8. 验证

- **整核门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）。装配层的接线错误会在这里表现为提交值或周期不对。
- **Linux**：`scripts/linux_gate.sh`（RTL 和模型启动同一镜像同样周期数，逐条提交检查，PMU 数字逐区间对比，控制台出现 `login:`）；`scripts/linux_segments_cmp.sh`（从检查点分段并行跑，头注释称为快速 Linux 门禁，从复位的完整运行是最终门禁）；构建脚本 `scripts/build_soc64_linux.sh`（`-DTTG_EBREAK_TRAP`）。
- **Lint**：`scripts/lint_chip.sh`（`soc_top` 为顶层的整芯片 `verilator -Wall` lint）0 告警。
- **没有装配层的独立测试**：旧的 `back_top` lockstep（整程序逐拍对 trace）和 `tools/lint_back_top.sh` 已随生成器退役。**待补**：胶水（`back_top_glue`）的 `out_mispred / out_redirect_pc / out_rf_valid` 在 flush 决定拍、推迟拍、同拍误预测各一个定向测试；FLUSH_REG 的 `rob_flush_q` 与 `flush_pend` 配合（陈旧误预测）一个定向程序。

## 9. 参数与开关速查

`ISSUE_WIDTH`、`TOTAL_FU_COUNT`、`DECODE_WIDTH`、`COMMIT_WIDTH`、`BACKEND_FETCH_WIDTH`、`LSU_*_COUNT`、`LSU_AGU_SHARED`、`LSU_AGU_PHYS`、`FPRF_NUM`（决定 `FP_EN`）、`MAX_WAKEUP_PORTS`（`ttg_cfg_pkg`）；`lp_pkg::LP_L2`（决定 `lsu_byp_valid`）；`SYNTHESIS`（`exu.sv` 里的断言只在仿真）。FLUSH_REG 在 RTL 里没有开关（总是推迟一拍），模型对应 `CFG_FLUSH_REG`。

## 10. 变更记录

- 2026-11-25（`idu_br_latch` 迁入 `back_top`）：将 `idu_br_latch.sv` 从 `rtl/backend/idu/` 移入 `rtl/backend/back_top/` 并直接在 `back_top.sv` 中实例化 `u_br_latch` 驱动 `dec_bcast_*` 与 `br_latch_*`，使 `u_idu` 成为纯组合 8 路译码器（零周期变化）。
- 2026-11-17/18（exp/agu-share，`261bd67..HEAD`）：
  - `16de223`：DTLB 每个物理 AGU 一个口（`LSU_AGU_PHYS = 5`），`back_top.sv` 里的请求 / 响应数组改宽；
  - `e49618c`：`exe2lsu_ldu_req_occ`、`exe2lsu_sta_req_occ` 接线（`back_top.sv`、`exu.sv`）；
  - `803692f`：FLUSH_REG（`rob_flush_q`、`rob_fence_q`、`rob_fence_i_q`，胶水里的 `redirect_pc_q` 和 `out_mispred` / `out_redirect_pc` / `out_rf_valid` 逻辑），docs/FLUSH_REG.md。
- 2026-11-16：生成器 `tools/gen_backtop.py` 和 `spec/*.io` 删除，`back_top.sv`、`exu.sv` 改手工维护。
- 更早：见 git 历史。
