---
module: back_top
area: backend
rtl: rtl/backend/back_top
model: trace-model back-end/BackTop.cpp（`BackTop::init` 的接线、`BackTop::seq` 的顺序）；胶水的行为在模型里分散在 back-end/Rob.cpp（`Rob::redirect`、`Rob::report_commit`、`Rob::comb_commit` 里的 `rob_bcast_d`）。模型的 `BackTop` 本身没有 comb 阶段，不是调度单元
status: 整核周期与模型逐个相等（fm_gate 77/77，参考 scripts/ref_cycles.txt；沿用 isu.md 记录的验收结果，本文作者没有重跑）
depth: 142 层（back_top，单模块综合，2026-11-20，`SYNTH_ABC="strash;balance;map"`，生成门代理，见 09-synthesis-report 第 12 节）
---

# back_top 设计文档

> **2026-11-28 `rtl/iss-rr` 后端五墙合一时序切分**：
> - 在 `u_isu` 与 `u_prf` 之间插入 `iss_rr_reg`（`u_iss_rr`）打通 **ISS → RR → EX/LSU** 两拍，斩断 `u_lsu/u_wake → u_isu → u_prf(27R) → u_exu` 跨模块环；
> - `lsu2iss_wake` 扩宽至 14 路（`3*LSU_LDU_COUNT + 2`：L1 推测 4 + L3 直发 4 + L2b STLF/L2a fallback 4 + V2 WBP 2）；`u_isu` 向 `u_dis` 传 `iss_awake_cancel[ALU_NUM]`（ALU 孙代取消）；`u_exu` 改传提前 2 拍 `exe2iss_div_wb_in2`。

> **2026-11-26 `rtl/area-opt` 后端内部总线 `packed struct` 化与命名统一**：
> - 将后端 9 条内部总线（`ibuf2idu`、`dec2ren`、`ren2dis`、`dis2rob`、`dis2iss`、`iss2prf`、`prf2exe`、`exe2prf`、`exu2rob`）统一打包为结构体（新增 `dis_rob_uop_t`、`xc_prf_wb_t`、`xc_rob_wb_t`），端口前缀同步统一为 `front2ftq_*` / `ftq2front_*` / `ibuf2idu_*`；`back_top.sv` 由 1,650 行精简至 563 行（连同 `ren`/`dispatch`/`prf` 共净减 2,000+ 行样板连线），同时保持全部顶层对外端口与 `soc_public.vlt` 探针不变；
> - `back_top_glue.sv` 删除 ROB 64-bit `diag_val` 后改为直接由 `ftq_commit_next_pc` / 顺序 PC 重建提交分支训练目标。

范围：`back_top.sv`（后端的装配）、`back_top_glue.sv`（不属于任何子模块的几段逻辑）、`exu.sv`（执行单元的装配：`exu_ctrl` 加各 FU）。旧文档描述的是由 `tools/gen_backtop.py` 生成的版本和 lockstep 体系，现在这三个文件都是手工维护，没有沿用。

## 1. 职责

后端的顶层，只做连线和三段很小的逻辑，不做运算：

1. **装配 14 个实例**：`ftq_ibuf`（`u_ftq_ibuf`，统一 FTQ + 指令缓冲）、`back_br_redirect`（`u_br_redirect`，分支重定向锁存）、`idu`（`u_idu`）、`ren`（`u_ren`）、`dispatch`（`u_dis`）、`isu`（`u_isu`）、`iss_rr_reg`（`u_iss_rr`，ISS→RR 流水寄存器）、`prf`（`u_prf`）、`exu`（`u_exu`）、`csr`（`u_csr`）、`rob`（`u_rob`）、`tlb_mmu`（DTLB，`u_dtlb`）、`lsu`（`u_lsu`）、`back_top_glue`（`u_glue`）；后端和前端、DCache、MMIO、PTW 的边界就是这个模块的端口；
2. **全局 flush 晚一拍到达**（FLUSH_REG）：ROB 在第 t 拍决定一次全局 flush 并同拍清自己，三个寄存器 `rob_flush_q`、`rob_fence_q`、`rob_fence_i_q` 把它推迟一拍，再送给其余模块、前端重定向和 fence 广播（docs/FLUSH_REG.md）；
3. **胶水**（`back_top_glue`）：前端看到的 `out_mispred / out_stall / out_redirect_pc / out_rf_*`、DTLB 要的四个 `mstatus` 位、LSU 要的 AMO 子操作码；
4. **执行单元装配**（`exu.sv`）：`exu_ctrl` 与 FU 的连线和合同；
5. **LSU 写回作旁路源**（`lsu_byp_valid`，见 5.5）。

模型对应：`BackTop::init` 把各模块的 `out` 绑到其他模块的 `in`，RTL 里就是同名线网；模型里 flush 推迟是 `Rob::comb_commit` 生成 `rob_bcast_d`，前端重定向推迟是 `Rob::redirect` 里的 `pend_`；这两处在 RTL 里落在本模块的 `rob_flush_q` 寄存器和胶水。模型里 `Prf` 不存在，PRF 和执行单元的接线（`iss2prf`、`prf2exe`、`exe2prf`）是 RTL 才有的。术语：**胶水**指不属于任何子模块、只在装配层存在的逻辑。

## 2. 配置

| 项 | 值（常量） |
| --- | --- |
| 实例（文件行数） | `back_top.sv` 1660、`back_top_glue.sv` 103、`exu.sv` 657；子模块见各自文档 |
| 发射口、FU | `ISSUE_WIDTH = 19`，`ROB_WB_WIDTH = 21`，`TOTAL_FU_COUNT = 28`，6 个发射队列（`dis_pkg::IQ_NUM = 6`），唤醒通道 `MAX_WAKEUP_PORTS = 21` |
| 译码 / 提交宽度 | `DECODE_WIDTH = 8`，`COMMIT_WIDTH = 8`，`BACKEND_FETCH_WIDTH = 16` |
| 访存口 | `LSU_LDU_COUNT = 4`、`LSU_STA_COUNT = 3`、`LSU_SDU_COUNT = 3`、`LSU_AGU_COUNT = 5`、`LSU_AGU_SHARED = 2`（统一 5 个物理 AGU：口 6..7 只做 load，口 8..9 load/STA 共用，口 10 只做 STA；`exe2lsu_agu`、DTLB 与 LSU 按 `LSU_AGU_COUNT = 5` 配口，`back_top.sv` 的 `lsu2mmu_*`、`mmu2lsu_*`） |
| 寄存器 | 本层只有 `rob_flush_q`、`rob_fence_q`、`rob_fence_i_q`（各 1 位）和胶水里的 `redirect_pc_q`（`XLEN_BITS = 64` 位） |

`ttg_cfg_pkg.sv` 已由 `make cfg` 同步生成。`back_top.sv` 和 `exu.sv` 文件头写的是"由 `tools/gen_backtop.py` 生成到 2026-11，生成器已删除"。

## 3. 接口

`back_top` 118 个端口声明（数组和打包向量各算一个），按方向和对端分组：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `front2ftq_{inst, page_fault_inst, pf_inst_hi, valid, ftq_idx}`、`fe2ftq_s0 / s2 / pd`（结构体 `fe_ftq_s0_t / s2_t / pd_t`）、`front_stall`、`bpu_upd_free`、`bpu_tq_free` | 前端送来的取指包（`[BACKEND_FETCH_WIDTH]`）、写统一 FTQ 的三级请求（预测 S0 / S2 与预译码 PD）、停顿、BPU 提交信用 |
| 出 | `ftq2fe`（`ftq_fe_view_t`）、`ftq2front_fire [BACKEND_FETCH_WIDTH]`、`ftq2front_ready` | FTQ 给前端的视图、本拍接收的取指槽、能否接收 |
| 入 | `dcache2lsu_*`、`peripheral_resp_*`、`ptw_walk_resp_*`、`ptw_walk_req_ready` | 访存子系统、MMIO、页表遍历的响应 |
| 入 | `interrupt_inject_*` | 外部中断线，直接进 `csr` |
| 出 | `out_mispred`、`out_no_mispred`、`out_stall`、`out_redirect_pc`、`out_rf_valid / _pc / _is_rvc / _type / _blk`、`ftq_commit_info_*`、`commit_extra_*`、`out_commit_entry_uop_diag_val` | 给前端的重定向、停顿、BPU 训练和修复数据 |
| 出 | `rob_commit_commit_entry_*`、`rob_bcast_*`（flush、fence、fence_i、exception、interrupt、mret、sret、pc） | 提交信息和 ROB 广播，给前端、difftest 和测试台；其中 `rob_bcast_flush` 是 ROB 这一拍的决定（**未推迟**），`rob_bcast_fence`、`rob_bcast_fence_i` 是推迟一拍之后的值 |
| 出 | `csr_status_{mstatus, sstatus, satp, privilege}` | CSR 状态 |
| 出 | `lsu2dcache_*`、`peripheral_req_*`、`ptw_walk_req_*`、`ptw_walk_flush`、`ptw_walk_resp_consumed` | 发往访存子系统和 PTW |
| 出 | `dis2rob_dis_fire`、`pmu_slot_valid` | PMU 第一层事件 |
| 入 / 出 | `pf_xq_v / va / llc`（入）、`pf_xq_pop`、`pf_xans_v / line / llc`（出） | L1D Berti 预取器跨页翻译：预取器的待翻译虚拟地址进 LSU，借空闲 DTLB 口翻译，结果回预取器（见 dcache_pf.md） |

## 4. 结构

```
 front2ftq ─► ftq_ibuf ─► idu ─► ren ─► dis ─► isu ─(iss2prf)─► prf ─(prf2exe)─► exu(exu_ctrl + FU) ─┬─(exe2prf)─► prf
   ▲                 ▲ exu2id（分支解析）     │ dis2rob/dis2lsu        ▲ exe2iss_div_wb_in2      ├─(exu2rob [21])─► rob
   │                 └ dec_bcast_* ─► ren dis isu prf exu rob dtlb lsu glue            │ prf_awake                    ├─(exe2lsu_agu [5])─► lsu ─(lsu2exe 写回)─► exu
   │                                                                                    └─► isu、dis    exe2csr ─► csr ─(csr2exe)─► exu
 rob ─(rob_bcast_flush)─► rob_flush_q ─► ftq_ibuf idu ren dis isu prf exu dtlb lsu；rob ─(mret / exception / pc …)─► csr、glue
 lsu ◄─► dtlb（按物理 AGU 的请求 / 响应）；lsu ─(lsu2iss_wake / cancel)─► isu、dis
 glue：out_mispred / out_redirect_pc / out_rf_*、mstatus 位、amo_op
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `back_top.sv` | 801 | 装配 14 个实例；FLUSH_REG 寄存器块；`lsu_byp_valid`；7 条无人读的输出接到具名悬空线（`nc_*`） |
| `back_top_glue.sv` | 112 | 见 5.3、5.4、5.5 |
| `back_br_redirect.sv` | 69 | 分支重定向锁存：`dec_bcast_*` 与 `br_redirect_*`（重定向 pc、分支 pc、`is_rvc`），给 `ftq_ibuf` 与胶水 |
| `iss_rr_reg.sv` | 74 | ISS→RR 一拍流水寄存器：`valid_q`、旁路选择 `src1/2_byp_q`、L1 推测掩码 `spec_mask_q`，按 `lsu2iss_cancel_valid` 取消 |
| `exu.sv` | 490 | `exu_ctrl` + FU 的装配（见 5.6） |

重要的接线（"从谁到谁"，以 `back_top.sv` 为准）：

| 信号 | 从 | 到 |
| --- | --- | --- |
| `dec_bcast_{mispred, redirect_rob_idx, redirect_rob_flag}` | `back_br_redirect`（`exu2id_*` 锁存一拍） | `ren`、`dispatch`、`isu`、`prf`、`exu`、`rob`、`dtlb`、`lsu`、`glue`（`mispred`） |
| `exu2id_*`（最老误预测分支的重定向信息） | `exu` | `back_br_redirect`（锁存后广播 `dec_bcast_*`，并给 `ftq_ibuf` / 胶水 `br_redirect_*`） |
| `rob_flush_q`（推迟的 flush） | 本模块寄存器 | `ftq_ibuf`、`idu`、`ren`、`dispatch`、`isu`、`prf`、`exu`、`dtlb`、`lsu`；`rob` 收 `flush_pend`；`glue` 收 `flush_q` |
| `rob_bcast_flush`（ROB 这拍的决定） | `rob` | 寄存器输入；`glue`；`lsu`（`rob_flush_now`）；芯片端口 |
| `rob_bcast_{mret, sret, ecall, breakpoint, exception, page_fault_*, illegal_inst, trap_val, pc}` | `rob` | `csr`、`glue`（部分）和芯片端口；不推迟 |
| `rob_bcast_interrupt` | `rob` | `ren`、芯片端口；不推迟 |
| `iss2prf_*` → `u_iss_rr` → `rr_*` / `prf2exe_*` | `isu` / `iss_rr_reg` / `prf` | `prf` / `exu`（1 拍 ISS→RR 流水级，按 `lsu2iss_cancel_valid` 与 `spec_mask_q` 取消未命中 L1 推测消费者；口 0 的 `csr_idx` 随 `prf2exe` 送 `exu`） |
| `exe2prf [WB_LANES]`（`xc_prf_wb_t`，寄存器写回总线兼 EXU 级旁路，EXP-046） | `exu` | `prf` |
| `exe2iss_div_wb_in2`、`exe2iss_div_wake_*` | `exu` | `isu`（DIV 提前 2 拍写回通告与晚唤醒） |
| `prf_awake_*`（load 晚唤醒） | `prf` | `isu`、`dispatch` |
| `iss_awake_*`（唤醒广播） | `isu` | `dispatch` |
| `iss_awake_cancel_*` | `isu` | `dispatch`（6 路 1 周期 ALU 孙代取消） |
| `lsu2iss_wake_* / cancel_*` | `lsu` | `isu`、`dispatch`（`lsu2iss_wake_*` 为 14 路：L1 推测 4 + L3 4 + L2b STLF/L2a fallback 4 + WBP 2） |
| `exe2lsu_agu [5]`、`exe2lsu_sdu_* [3]`、`lsu2exe_*` | `exu` / `lsu` | `lsu` / `exu`；`lsu2exe_wb_req_*` 另经 `lsu_byp_*` 去 `prf` |
| `exu2rob [ROB_WB_WIDTH]` | `exu` | `rob` |
| `exe2csr_*`、`csr2exe_rdata / frm` | `exu` / `csr` | `csr` / `exu` |
| `rob2csr_*`、`csr2rob_*`、`csr2front_epc / trap_pc` | `rob` / `csr` | `csr` / `rob` / `glue` |
| `ftq_prf_pc_*`、`ftq_rob_pc_*` | `prf`、`rob` | `ftq_ibuf`（请求），`ftq_ibuf`（回答）回 `prf`、`rob` |
| `lsu2mmu_req_*`、`mmu2lsu_resp_*` | `lsu` / `dtlb` | `dtlb` / `lsu` |

## 5. 一拍内的数据流

### 5.1 发射 → 执行 → 写回的拍序

第 t 拍（ISS）：ISU 授予，发射结果在时钟沿进 `iss_rr_reg`。t+1（RR）：寄存后的 `iss2prf` 进 PRF，PRF 异步读出操作数（带旁路），经 `prf2exe` 在时钟沿写进 `exu_ctrl` 的槽；L1 推测失败时 `iss_rr_reg` 按 `spec_mask_q` 取消对应消费者。t+2（EX）：槽里的指令进 FU，FU 出结果；口内一热选择后赢家同拍变成 `exe2prf`（`WB_LANES = 13` 条写回通道，ALU 通道 0..5 同拍由 PRF 按独热 `src*_byp` 旁路给读口，单周期 FU 背靠背）、`exu2rob`、`exe2lsu`、分支解析 `exu2id`。t+3：写回级的值写进寄存器堆，同拍 load 的晚唤醒 `prf_awake` 广播。load 和 STA 的结果走 LSU：AGU 在 EX 拍给 `exe2lsu` 请求，LSU 之后在 load 写回通道（`ROB_WB_LD_BASE` 起 4 路）和 STA 写回通道（`ROB_WB_STA_BASE` 起 3 路）给写回请求（`lsu2exe`）。

### 5.2 FLUSH_REG 块

`back_top.sv` 里一个 `always_ff`（复位清零）：`rob_flush_q <= rob_bcast_flush`，`rob_fence_q <= rob_fence_raw`，`rob_fence_i_q <= rob_fence_i_raw`，其中 `rob_fence_raw`、`rob_fence_i_raw` 是 ROB 的 fence 输出（`rob` 实例接到这两根线），`rob_bcast_fence`、`rob_bcast_fence_i` 端口取寄存后的值。哪些模块看哪个版本：

| 模块 | 看到的 flush |
| --- | --- |
| ROB | 自己 t 拍的决定 `rob_bcast_flush`（同拍清自己）；`flush_pend = rob_flush_q` 在 t+1 拍屏蔽陈旧的误预测恢复 |
| `ftq_ibuf`、`idu`、`ren`、`dispatch`、`isu`、`prf`、`exu`、`dtlb`、`lsu` | `rob_flush_q`（t+1 拍） |
| `lsu` | 另有 `rob_flush_now = rob_bcast_flush`（t 拍），限定"flush 这拍提交的 store 不能写出去" |
| `dtlb` | `rob_flush_q` 作 flush，`rob_fence_q` 作 fence |
| `csr` | 没有 flush 输入；陷入和 xRET 用 ROB 同拍的 `rob_bcast_*` |
| `ren` | flush 用 `rob_flush_q`；`rob_bcast_interrupt` 用同拍值（带中断退休的指令不算提交） |
| 前端 | `back_top_glue` 在 t+1 拍用 `flush_q` 重定向，见 5.3 |

### 5.3 前端重定向和停顿（`back_top_glue`）

- `flush_redirect_pc`（组合）：`mret / sret` 取 `csr2front_epc`；`exception` 取 `csr2front_trap_pc`；否则取 `rob_bcast_pc + (rob_bcast_is_rvc ? 2 : 4)`（`is_rvc` 来自 FTQ 的 ROB 口响应）。它每拍都存进 `redirect_pc_q`（无条件）。
- `out_mispred = flush_q | (dec_bcast_mispred & ~rob_bcast_flush)`：flush 决定的那一拍压住分支误预测（flush 优先），下一拍才重定向。
- `out_redirect_pc = flush_q ? redirect_pc_q : br_redirect_pc`。
- `out_rf_valid = dec_bcast_mispred & ~rob_bcast_flush & ~flush_q`：只有分支误预测的重定向才做 BPU 历史修复，`out_rf_pc`、`out_rf_is_rvc` 取 `back_br_redirect` 的分支锁存（`br_redirect_br_pc`、`br_redirect_is_rvc`）。
- `out_stall = ~ftq2front_ready`；`out_no_mispred = ~out_mispred`（边界规范里用它限定 `out_stall`）。

### 5.4 提交项的 `diag_val`（不覆盖）

`out_commit_entry_uop_diag_val[i]` 就是 ROB 提交项的 `diag_val[i]`，flush 时也不改。原来的实现在 flush 决定拍把它覆盖成重定向目标（模型 `Rob::report_commit` 同），前端训练用它当分支目标，结果是 flush 那一拍恰好提交的跳转 / 调用用陷入地址训练 BTB；加了 FLUSH_REG 之后模型的覆盖落在没有有效提交的推迟拍，等于不覆盖，RTL 仍在决定拍覆盖，Linux 窗口 s08 周期 2856352 出现训练目标不同（RTL `0x80000408` 是 mtvec，模型是调用的真目标）。现在 RTL 不覆盖，与模型一致。

### 5.5 其他胶水和装配层逻辑

- `csr_status_mstatus_{mxr, sum, mprv, mpp}`：取自 `mstatus` 的第 19、18、17、12:11 位，送 DTLB；
- `rob_commit_commit_entry_uop_amo_op[i] = func7[6:2]`，给 LSU 提交 store 时用；
- `lsu_byp_valid[k] = lsu2exe_wb_req_valid[k] && lsu2exe_wb_req_uop_dest_en[k]`：LSU 的 load 写回请求作为 PRF 读口的旁路源（`LSU_LOAD_WB_WIDTH = 4` 路），总是开（原来的 `LP_L2` 位 0、位 3 条件已随 `LP_L2` 在 EXP-069 删除，行为固定为开）；
- `unused_fp_issue`：把 `iss2prf_iss_entry_uop_dest_fp` 归约成一根无人读的线，消除未使用告警（目的寄存器是浮点还是整数由编号判断）。

### 5.6 `exu.sv` 与 FU 的合同

- `exu_ctrl` 之外实例化：`alu_bank`（6）、`bru_bank`（2）、`agu_bank`（`LSU_AGU_COUNT = 5`）、`sdu_bank`（3）、`mul_bank`（2）、`div_bank`（1）、浮点 FU（`FP_EN` 时 `N_FPU = 8` 个：FDIV 用 `fp_div_unit`，其余用 `fp_pipe_unit`，延迟取 `FP_FMA_LAT`、`FP_MISC_LAT`、`FP_I2F_LAT`），共 27 个（加 CSR 槽共 `TOTAL_FU_COUNT = 28`）；CSR FU 不实例化（`exu_ctrl` 自己处理 CSR 槽）；
- 所有 FU 不再使用 `ready` / `consume` 握手；单周期 FU（`alu`、`bru`、`agu`、`sdu`）只保留输入操作数与组合结果，无 `en`/`complete`/`ready`/`consume`；
- 多周期 FU 按 `exu_ctrl` 的 MC 下标映射：`MC_MUL`（口 0、2）、`MC_DIV`（口 1）；`func3` 截成 2 位；`flush_all`、`flush_br`、`flush_rob_idx / flush_rob_flag` 复制给每个实例（误预测按 ROB 号杀更年轻的在飞指令）；口 1 DIV 的 `div_wb_in2`（提前 2 拍的写回预告）经 `exe2iss_div_wb_in2` 导出至 ISU，flush 时屏蔽；
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
| DTLB 每个物理 AGU 一个口 | `16de223`（`back_top.sv` 的数组宽度改为 `LSU_AGU_PHYS`，现名 `LSU_AGU_COUNT = 5`） | 5 个物理 AGU、5 个 DTLB 口；周期对"212 参考"（提交说明） |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的，或两边不同的：

- **推迟的字段**：模型 `rob_bcast_d`（`CFG_FLUSH_REG = 1`）把 flush 和陷入的全部字段推迟一拍（head 信息、`interrupt`、`flush_now` 不推迟）；RTL 只推迟 `flush`、`fence`、`fence_i`，因为 `rob_bcast_*` 的其他字段只有 `csr` 和 `glue` 读（`back_top.sv` 里接线可见），它们在模型里也读未推迟的 `rob_bcast`（`SimCpu.cpp`：`csr.in.rob_bcast = &back.rob->out.rob_bcast`）；
- **`out_stall`**：模型在 flush 推迟的"决定那一拍"设 `o.stall` 为前端队列不可接收，推迟的下一拍不赋值；RTL 的 `out_stall = ~ftq2front_ready` 每拍都是。边界上谁读 `out_stall`（前端只在非重定向拍读它，所以边界规范有 `out_no_mispred` 限定）本文没有逐点核对；
- **`br_type`、`rf_pc`**：模型在 `Rob::redirect` 里从 FTQ 取 `rf_pc`、`rf_is_rvc`、`rf_type`；RTL 的 `out_rf_pc`、`out_rf_is_rvc` 取 `back_br_redirect` 的分支锁存（`br_redirect_*`），`out_rf_type`、`out_rf_blk` 在 `ftq_ibuf` 里读出；
- **`tbhook::on_flush`、`run_interrupt_hook`、统计**：RTL 不带；
- **没有 trace bridge**：模型 `Rob::redirect` 在 flush 决定那一拍通知 trace bridge 倒回，RTL 没有对应物。
- **`diag_val` 不覆盖**：模型 `Rob::report_commit` 的覆盖 `if (o.flush) ... = o.redirect_pc` 在 `CFG_FLUSH_REG = 1` 时落在推迟拍，那一拍没有有效提交，所以对前端训练无效；RTL 也不覆盖（5.4）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- flush 决定那一拍分支误预测被丢弃，`out_rf_valid` 为 0；推迟的下一拍 `out_mispred` 为 1、`out_rf_valid` 为 0（模型 `pend_` 分支同）；

死线网和过时注释（没有改）：`back_top.sv` 有 7 条输出接到 `nc_*` 线（`csr2exe_rdata_vld`、`csr2front_epc_vld`、`csr2front_trap_pc_vld`、`ftq_prf_pc_resp_resp_valid`、`ftq_rob_pc_resp_resp_valid`、`mmu2lsu_resp_hit`、`rob_bcast_trap_val_valid`）；`exu.sv` 文件头写"27 个功能单元"、"boundary = spec/exu.io"（spec 已删除）；`isu_wake_src.sv`（不属于本模块）的头注释写"14 个唤醒通道"，现在是 `WAKE_NUM = MAX_WAKEUP_PORTS = 21`。

未核对（继承自旧文档）：

- 旧文档的"集成问题"表（I-1..I-7）、"边界选择（SimCpu 侧 / 后端侧）"和"已知未验证项"（difftest 直接观测的状态、复位只验证全零输入 3 拍等）：描述的是已退役的 lockstep 验证体系，本文没有重新核对；
- 旧文档的连线统计（实例数、端口数、线网数）：已不适用。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`lint_chip` & `lint_soc` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` `fm_gate` 77/77（与 `trace-model` `0` 周期差）、`riscv-tests` 152/152（1 SKIP `rv64ui-ma_data`）、`soc_gate --linux` 12/12 全通；集群 Linux 26/26 窗（5.1M insts/窗）PT/UP 100% 全等；SPEC06 INT 386/386 `geomean +0.144%`（`13.30 /GHz`）。
- **整核门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）。装配层的接线错误会在这里表现为提交值或周期不对。
- **Linux**：`scripts/linux_gate.sh`（RTL 和模型启动同一镜像同样周期数，逐条提交检查，PMU 数字逐区间对比，控制台出现 `login:`）；`scripts/linux_segments_cmp.sh`（从检查点分段并行跑，头注释称为快速 Linux 门禁，从复位的完整运行是最终门禁）；构建脚本 `scripts/build_soc64_linux.sh`（`-DTTG_EBREAK_TRAP`）。
- **Lint**：`scripts/lint_chip.sh`（`soc_top` 为顶层的整芯片 `verilator -Wall` lint）0 告警。
- **没有装配层的独立测试**：旧的 `back_top` lockstep（整程序逐拍对 trace）和 `tools/lint_back_top.sh` 已随生成器退役。**待补**：胶水（`back_top_glue`）的 `out_mispred / out_redirect_pc / out_rf_valid` 在 flush 决定拍、推迟拍、同拍误预测各一个定向测试；FLUSH_REG 的 `rob_flush_q` 与 `flush_pend` 配合（陈旧误预测）一个定向程序。

## 9. 参数与开关速查

`ISSUE_WIDTH`、`TOTAL_FU_COUNT`、`DECODE_WIDTH`、`COMMIT_WIDTH`、`BACKEND_FETCH_WIDTH`、`LSU_*_COUNT`、`LSU_AGU_SHARED`、`LSU_AGU_COUNT`、`FPRF_NUM`（决定 `FP_EN`）、`MAX_WAKEUP_PORTS`（`ttg_cfg_pkg`）；`SYNTHESIS`（`exu.sv` 里的断言只在仿真）。FLUSH_REG 在 RTL 里没有开关（总是推迟一拍），模型对应 `CFG_FLUSH_REG`。

## 10. 变更记录

- 2026-11-28（文档核对，无 RTL 变化）：接口按 fe-2ahead 端口重写（`front2ftq_*`、`fe2ftq_s0/s2/pd`、`ftq2fe`、`ftq2front_*`、`out_rf_blk`、Berti 跨页翻译 `pf_xq_* / pf_xans_*`）；实例改为 14 个（`ftq_ibuf`、`back_br_redirect`、`iss_rr_reg`）；`dec_bcast_*` 来自 `back_br_redirect`、无分支掩码；`exe2iss_div_wb_in2`；`lsu_byp_valid` 去掉已删除的 `LP_L2` 条件；拍序加入 ISS→RR 级；文件表补 `back_br_redirect.sv`、`iss_rr_reg.sv`；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/exu-clean`，EXP-072）：`back_top.sv` 与 `exu.sv` 删除 `exe2iss_fu_ready_mask` 线网、取消 `ready/consume` 协议，并由逻辑 7 AGU 收敛为真 5 物理 AGU（`ISSUE_WIDTH = 19`），改接 `exe2iss_div_wb_next` 给 `isu`；TSMC 28nm DC `exu_ctrl` 面积 −38.8%（`19,432 µm²`, `WNS 0.00 ns`）、`exu` 面积 −4.84% / FF −22.4%；通过 strict+SVA `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 与 Linux 26/26 窗对齐。

- 2026-11-26（`rtl/soc-env`）：将 `idu_br_latch.sv` 重命名为 `back_br_redirect.sv`（实例 `u_br_redirect`，同步更新 `ftq_ibuf` / `back_top_glue` 端口前缀 `br_redirect_*`），消除迁出 `idu` 后的遗留命名（纯重命名，零行为变化）。
- 2026-11-25（`idu_br_latch` 迁入 `back_top`）：将 `idu_br_latch.sv` 从 `rtl/backend/idu/` 移入 `rtl/backend/back_top/` 并直接在 `back_top.sv` 中实例化 `u_br_latch` 驱动 `dec_bcast_*` 与 `br_latch_*`，使 `u_idu` 成为纯组合 8 路译码器（零周期变化）。
- 2026-11-17/18（exp/agu-share，`261bd67..HEAD`）：
  - `16de223`：DTLB 每个物理 AGU 一个口（`LSU_AGU_PHYS = 5`），`back_top.sv` 里的请求 / 响应数组改宽；
  - `e49618c`：`exe2lsu_ldu_req_occ`、`exe2lsu_sta_req_occ` 接线（`back_top.sv`、`exu.sv`）；
  - `803692f`：FLUSH_REG（`rob_flush_q`、`rob_fence_q`、`rob_fence_i_q`，胶水里的 `redirect_pc_q` 和 `out_mispred` / `out_redirect_pc` / `out_rf_valid` 逻辑），docs/FLUSH_REG.md。
- 2026-11-16：生成器 `tools/gen_backtop.py` 和 `spec/*.io` 删除，`back_top.sv`、`exu.sv` 改手工维护。
- 更早：见 git 历史。
