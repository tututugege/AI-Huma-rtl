---
module: core_top
area: core
rtl: rtl/core/core_top（core_top.sv、core_front.sv、core_back2front.sv、core_front2back.sv）
model: trace-model Back2Front.cpp、include/Back2Front.h（调度单元 `b2f`，类 `Back2Front`，阶段 `comb_front`）；Front2Back.cpp、include/Front2Back.h（调度单元 `f2b`，类 `Front2Back`，阶段 `comb`）；SimCpu.cpp 的 `SimCpu::cycle`（把前端、后端和这两个寄存器接起来）
status: 整核周期与模型逐个相等（fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: 待测
---

# core_top 设计文档

## 1. 职责

不含访存子系统的核心：把前端（`front_top`）、后端（`back_top`）和夹在它们之间的两个"胶水"寄存器接成一个核。边界之外是 `mem_top`（`soc_top` 里按端口名对接）。四个文件各管一块：

| 文件 | 管什么 |
| --- | --- |
| `core_top.sv` | 顶层：实例化 `back_top`、`core_front`、PMU 事件总线（`pmu_ev_core`），把后端的输出接给前端 / 外面；对外端口 = ICache 的存储侧、页表遍历（PTW）的两个客户端（ITLB、DTLB）、LSU 与 DCache / 外设的端口、中断注入、退休流（`rob_commit_*`、`rob_bcast_*`） |
| `core_front.sv` | 前端加胶水：`front_top` + `core_back2front` + `core_front2back`，并决定前端本拍能不能交付（`can_read`） |
| `core_back2front.sv` | 后端 → 前端的寄存器：本拍后端决定的重定向、`fence` 冲刷、停顿标志、BPU 训练数据，下一拍才是前端的输入 |
| `core_front2back.sv` | 前端 → 后端：后端停顿时保持（hold）这一组（第一个预测跳转之后的截断已在 `front_pred_path` 里做） |

模型对应：`b2f`（`Back2Front`）和 `f2b`（`Front2Back`）是模型里两个独立的调度单元，RTL 的 `core_back2front` / `core_front2back` 是它们的寄存器和组合逻辑；`core_top` 对应 `SimCpu`（`SimCpu::cycle` 的调用顺序：前端各阶段 → `f2b.comb` → 后端各阶段，访存和 AXI 的阶段穿插其中，最后 `axi.comb_inputs`；之后 `front.seq_core`、`b2f.seq`、`f2b.seq`、`back.seq`）。

## 2. 配置（`ttg_cfg_pkg`、前端包，现行默认）

| 量 | 值 | 来源 |
| --- | --- | --- |
| 取指宽度 `FETCH_WIDTH` | 16（`FETCH_BYTES = 32`，`SLOT_BYTES = 2`） | `ttg_cfg_pkg`；模型 `config.h` 的 `FETCH_WIDTH = FETCH_BYTES / SLOT_BYTES` |
| 后端取指宽度 `BACKEND_FETCH_WIDTH` | 16（= `FETCH_WIDTH`） | `ttg_cfg_pkg`；模型 `CFG_BACKEND_FETCH_WIDTH` 默认 `FETCH_WIDTH` |
| 提交宽度 `COMMIT_WIDTH` | 8（= `DECODE_WIDTH`） | `ttg_cfg_pkg` |
| 每 lane 训练数据 | 有效、是否 RVC、基址 pc、实际方向、分支类别（3 位）、目标、预测方向、`alt_pred`、`pcpn`（3 位，`PCPN_W`）、块号（10 位，`FTB_BLK_ID_W`） | `core_back2front.sv` 端口 |
| 误预测修复信息 | 块号 `rf_blk`（`FTB_BLK_ID_W` = 10 位）、类别 3 位、pc、是否 RVC；BPU 用内部的 `u_rf_rec` 恢复历史 | `core_back2front.sv` |

## 3. 接口

端口很多，按组列（名字与 `mem_top` 同名、方向相反，`soc_top` 用 `.*` 连）：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `mem_req_ready / accepted / accepted_id`、`mem_resp_valid / id / data [ICACHE_WORD_NUM]`、`dc_resp_*` | ICache 的存储侧（AXI 读口的视图）和对 DCache 的一致性探针响应 |
| 入 | `itlb_walk_*`、`dtlb_walk_*` 的 `req_ready`、`resp_*` | 页表遍历的两个客户端 |
| 入 | `dcache2lsu_*`、`peripheral_resp_*`、`interrupt_inject_*` | LSU 来自 DCache / 外设的响应，外部注入的中断 |
| 出 | `mem_req_*`、`mem_resp_ready`、`dc_req_*` | ICache 的请求 |
| 出 | `itlb_walk_req_*`、`itlb_walk_flush`、`itlb_walk_resp_consumed`、`dtlb_walk_*` 同组 | 页表遍历请求 |
| 出 | `lsu2dcache_load_ports_*`、`lsu2dcache_store_ports_*`、`peripheral_req_*` | LSU 的 load / store 口、MMIO 请求 |
| 出 | `rob_commit_commit_entry_*`、`rob_bcast_*`、`out_mispred`、`out_redirect_pc`、`ftq_commit_info_resp_pc`、`out_commit_entry_uop_diag_val` | 退休流和重定向，给测试平台的逐条对比和 `soc_top` 的输出 |

内部连线：`core_front` 的输入是后端本拍的输出（`out_mispred`、`out_rf_*`（块号、类别、pc）、`out_stall`、`out_redirect_pc`、`rob_bcast_fence / fence_i`、提交流、FTQ 提交信息（含 `blk_id`）、FTQ 寄存视图 `ftq2fe`、`csr_status_*`）；输出是给 `ftq_ibuf` 的 `front2ftq_*`（取指组：指令、缺页、`pf_inst_hi`、`ftq_idx`）和 `fe2ftq_s0 / s2 / pd`（对统一 FTQ 的写请求），以及 `commit_upd_free / commit_tq_free`。

## 4. 结构

```
 back_top ──out_mispred / out_rf_* / out_stall / out_redirect_pc / 提交流 / FTQ 提交信息 / ftq2fe──┐
    ▲ front2ftq_* (16 lane)、fe2ftq_s0/s2/pd                                                         ▼
    │                                                              core_back2front（寄存一拍）
 core_front2back ◄── 前端输出 ◄── front_top ◄── 重定向 / 训练 / fence ──────────┘
   （hold）        ▲ can_read = !stall_q | refetch_q
 core_top: pmu_ev_core（事件总线，给测试平台读）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `core_top.sv` | 362 | 顶层连线，`pmu_ev_core` 实例 |
| `core_front.sv` | 229 | `front_top`、`core_back2front`、`core_front2back` 的连接，`can_read` |
| `core_back2front.sv` | 183 | 提交 lane 的指令类别判定（JAL / JALR / BR、call / icall / ret）和训练包，重定向和 fence 寄存器 |
| `core_front2back.sv` | 83 | hold 寄存器（有效、缺页、`pf_inst_hi`、指令、`ftq_idx`，约 566 个触发器） |

状态：`core_back2front`：`refetch_q`、`refetch_address_q`、`rf_*_q`（分支修复信息）、`itlb_flush_q`、`fence_i_q`、`stall_q`，以及每个提交 lane 一组 `upd_*_q`（共 8 组）；`core_front2back`：`hold_valid_q`、`hold_inst_q`、`hold_page_fault_q`、`hold_pf_inst_hi_q`、`hold_ftq_idx_q`。

## 5. 一拍内的数据流

模型顺序（`SimCpu::cycle`）：先由寄存的 `b2f` 给前端的输入，前端各阶段组合，`f2b` 取前端输出给后端，后端各阶段组合；时钟沿上 `b2f`、`f2b` 的寄存器更新。RTL 一一对应：

### 5.1 `core_back2front`：后端 → 前端（寄存一拍）

- 重定向：`refetch_q <= out_mispred`、`refetch_address_q <= out_redirect_pc`。`out_mispred` 在 `back_top_glue` 里已经把冲刷算进去：`flush_q | (dec_bcast_mispred & ~rob_bcast_flush)`（`FLUSH_REG` 打开时冲刷晚一拍，见 docs/FLUSH_REG.md）；分支修复记录 `rf_*_q` 只在 `out_rf_valid`（不含冲刷）时有意义，且只在重定向的周期被读；
- `itlb_flush_q <= rob_bcast_fence`、`fence_i_q <= rob_bcast_fence_i`、`stall_q <= out_stall`（`out_stall = ~ftq2front_ready`，`back_top_glue`）；
- 训练包：对每个有效提交 lane，按指令类型分类（JAL → `BR_JAL`；JAL 且 `rd = x1` → `BR_CALL`；JALR 且 `rd = x1` → `BR_ICALL`；JALR 且 `rs1 = x1`、`rd = x0`、立即数 0 → `BR_RET`；其他 JALR → `BR_IDIRECT`；条件分支 → `BR_DIRECT`；其余 `BR_NONCTL`），实际方向 = JAL / JALR 恒真、条件分支取 `br_taken`，目标 = 分支 / JAL / JALR 取 `diag_val`、其他取 `pc + (is_rvc ? 2 : 4)`；预测方向、`alt_pred`、`pcpn`、tag、idx 取自 FTQ 提交信息。无效 lane 的字段清零。

### 5.2 `core_front`：能否交付

`can_read = !stall_q | refetch_q`（用寄存值）。它同时作为 `front_top.fifo_read_enable`，决定前端是否读取取指组 FIFO，也决定 `core_front2back` 选前端输出还是 hold。

### 5.3 `core_front2back`：前端 → 后端

1. 前端送来的取指组已经在 `front_pred_path` 里截断到第一个修正后跳转（`out_lane_valid`）；
2. `can_read` 为真时 `back_* = 前端输出`，否则 `back_* = hold`；`BACKEND_FETCH_WIDTH` 大于 `FETCH_WIDTH` 的部分补无效 NOP（现行两者都是 16，不起作用）；
3. 时钟沿：hold 寄存器每拍都装 `back_*`。它只在"上一拍后端停顿且没有重定向"的拍被读，此时 `can_read = 0`，后端上一拍什么都没接收（`ftq_ibuf` 的接收是全有或全无），所以整组正是要保持的那一组。

## 6. 关键路径与深度

depth 待测。从代码读出的、未综合验证的链：

- `core_back2front` 的类别判定：提交类型 / `dest_areg` / `src1_areg` / `imm == 0` 比较 → 类别选择 → 目标选择（含 `pc + 2 / 4` 加法）→ `upd_*_d` → 寄存器。起点是 ROB 的提交输出，所以它是"提交 → 训练包寄存器"路径；
- `core_front2back`：`can_read` 选择 → `front2ftq_valid`；`can_read` 来自两个寄存器，路径很短；
- `can_read` 同时扇出到整个取指组 + hold 的 16 lane 选择（每 lane 的 32 位指令、pc、预测信息），扇出大。

## 7. 与模型的差异和取舍

- **前端 → 后端的取指组**：模型 `Front2Back::comb` 里的截断在 RTL 里属于 `front_pred_path`（[front_top.md](front_top.md)）；同页跨行 2-Fetch 的 B 块在前端就拼进同一组，`core_front2back` 不区分；
- **hold 寄存器不用 `fire` 清 lane**：模型在停顿时把后端已接收的 lane 的 valid 清掉（`Front2Back::seq`）；RTL 因为后端接收是全有或全无而不需要。这个"全有或全无"的前提写在 RTL 文件头注释里，由 `PreIduQueue::comb_accept_front` 的实现保证，本次没有逐行核对。
- **无效训练 lane 清零**：模型对无效提交 lane 保持字段旧值，RTL 清零（所有消费者都用 `upd_valid` 屏蔽），这个差别不可观察。
- **前端 → 后端的元数据**：模型传 `meta`（`fo.meta`）和 `front_stall` / `front_tq_free` / `front_upd_free`；RTL 的预测和元数据直接写统一 FTQ（`fe2ftq_s2 / pd`），取指组只带 `ftq_idx`；额度走 `commit_upd_free / commit_tq_free` 直接进后端（`core_top` 里 `back_top.front_stall` 接常量 0）；
- **JAL / JALR 类别判定的细节**：模型对 JALR 先判 RET 再判 `dest_areg == 1`（不看 `dest_en`），RTL 的 `BR_ICALL` 多要求 `dest_en`。`rd = x1` 的 JALR 总是 `dest_en`，所以不可观察；未验证。
- **没有 `restart_at` / `restart`**：模型里从快速模式切回时给 `b2f` 和 `f2b` 注入重取指、丢 hold 组（`SimCpu::restore_pc`）；RTL 没有这个入口（检查点恢复由测试平台完成）。
- **PMU 事件总线**在 RTL 里挂在 `core_top`（`u_pmu_ev`，见 pmu.md）；模型里 PMU 在后端采样（`back.pmu_sample`）。

RTL 里注释和代码不一致、值得清理的地方（只记录，没有改）：

- `core_front2back.sv` 里 `for (j < BACKEND_FETCH_WIDTH)` 先清零再按 `FETCH_WIDTH` 覆盖：现行两者相等，前一段是多余的；
- `core_top.sv` 文件头"the pmu counters are not on a CSR yet"：现状见 pmu.md。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（模型默认配置 = RTL 配置）。
- **Lint**：`scripts/lint_chip.sh`（以 `soc_top` 为顶，覆盖本模块）。
- **Linux 启动门禁**：`scripts/build_soc64_linux.sh` + `scripts/linux_gate.sh`（全程）；`scripts/linux_segments_cmp.sh`（并行窗口，RTL 对模型）。
- **与模型对齐**：`scripts/cmp_trace_model.sh`（整程序周期与提交数）、`scripts/align_check.sh`（PMU 序列与 PTAB 写 / 预测表更新的指纹，找第一个不同的区间）。
- **没有模块级的独立测试**（`tests/` 下没有 core_top、b2f、f2b 的测试）。胶水逻辑只靠整核周期相等和对比保证。**待补**：一个 `core_front2back` 与模型 `Front2Back::comb` 的随机并排测试（随机取指组 + 随机停顿 / 重定向序列）；训练包分类与模型 `Back2Front::seq` 的并排测试。

## 9. 参数与开关速查

`FETCH_WIDTH`、`BACKEND_FETCH_WIDTH`、`COMMIT_WIDTH`、`DECODE_WIDTH`、`FTQ_IDX_WIDTH`（`ttg_cfg_pkg`）；`FTB_BLK_ID_W`（`bpu_types_pkg`）。无开关。

## 10. 变更记录

- 2026-11-28（`rtl/fe-2ahead`，文档核对）：按统一 FTQ 后的 RTL 更新：截断已移到 `front_pred_path`、hold 寄存器只存指令与 `ftq_idx`、训练包用块号、修复信息用块号；删掉已不存在的 `TN_MAX`、`HCK_W`、`BCK_W`、`bpu_ck` / `slot_kind` 传递和 `FE_PAIR` 说法；文件行数更新；门禁改为 77/77 对 `scripts/ref_cycles.txt`。
- 2026-11-26：新增 `interrupt_inject_software_irq_pending(_valid)` 输入端口并透传至 `back_top` → `csr`（支持 `chip_top` CLINT `msip` 软中断；`soc_top` 接 `1'b0` 保持原行为，0 周期变化）。
- 本分支（`261bd67..HEAD`）未改动 `rtl/core`；更早：见 git 历史。
- PMU 事件包 `rtl/pmu/pmu_ev_pkg.sv` 已提交为 60ed422：发射队列事件 LD / STA 换成 MEM，新增 FP 队列事件，总数仍 66，id 52..65 重新排布（详见 pmu.md 第 10 节）；`core_top.sv` 只写 tier 1 的 18 个事件（id 0..34 之内），不受影响。
- 2026-11-18：删除 `core_top.sv` 里一个空的 `always_comb begin end` 及其注释。
