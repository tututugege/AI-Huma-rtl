---
module: core_top
area: core
rtl: rtl/core/core_top（core_top.sv、core_front.sv、core_back2front.sv、core_front2back.sv）
model: trace-model Back2Front.cpp、include/Back2Front.h（调度单元 `b2f`，类 `Back2Front`，阶段 `comb_front`）；Front2Back.cpp、include/Front2Back.h（调度单元 `f2b`，类 `Front2Back`，阶段 `comb`）；SimCpu.cpp 的 `SimCpu::cycle`（把前端、后端和这两个寄存器接起来）
status: 整核周期与模型逐个相等（最近一次提交 60ed422 的提交信息记 fm_gate 67/67、周期等于 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；本次写文档没有重跑）
depth: 待测（由协调者补）
---

# core_top 设计文档

## 1. 职责

不含访存子系统的核心：把前端（`front_top`）、后端（`back_top`）和夹在它们之间的两个"胶水"寄存器接成一个核。边界之外是 `mem_top`（`soc_top` 里按端口名对接）。四个文件各管一块：

| 文件 | 管什么 |
| --- | --- |
| `core_top.sv` | 顶层：实例化 `back_top`、`core_front`、PMU 事件总线（`pmu_ev_core`），把后端的输出接给前端 / 外面；对外端口 = ICache 的存储侧、页表遍历（PTW）的两个客户端（ITLB、DTLB）、LSU 与 DCache / 外设的端口、中断注入、退休流（`rob_commit_*`、`rob_bcast_*`） |
| `core_front.sv` | 前端加胶水：`front_top` + `core_back2front` + `core_front2back`，并决定前端本拍能不能交付（`can_read`） |
| `core_back2front.sv` | 后端 → 前端的寄存器：本拍后端决定的重定向、`fence` 冲刷、停顿标志、BPU 训练数据，下一拍才是前端的输入 |
| `core_front2back.sv` | 前端 → 后端：取指组在第一个预测跳转之后截断，后端停顿时保持（hold）这一组 |

模型对应：`b2f`（`Back2Front`）和 `f2b`（`Front2Back`）是模型里两个独立的调度单元，RTL 的 `core_back2front` / `core_front2back` 是它们的寄存器和组合逻辑；`core_top` 对应 `SimCpu`（`SimCpu::cycle` 的调用顺序：前端各阶段 → `f2b.comb` → 后端各阶段，访存和 AXI 的阶段穿插其中，最后 `axi.comb_inputs`；之后 `front.seq_core`、`b2f.seq`、`f2b.seq`、`back.seq`）。

## 2. 配置（`ttg_cfg_pkg`、前端包，现行默认）

| 量 | 值 | 来源 |
| --- | --- | --- |
| 取指宽度 `FETCH_WIDTH` | 16（`FETCH_BYTES = 32`，`SLOT_BYTES = 2`） | `ttg_cfg_pkg`；模型 `config.h` 的 `FETCH_WIDTH = FETCH_BYTES / SLOT_BYTES` |
| 后端取指宽度 `BACKEND_FETCH_WIDTH` | 16（= `FETCH_WIDTH`） | `ttg_cfg_pkg`；模型 `CFG_BACKEND_FETCH_WIDTH` 默认 `FETCH_WIDTH` |
| 提交宽度 `COMMIT_WIDTH` | 8（= `DECODE_WIDTH`） | `ttg_cfg_pkg` |
| TAGE 表数 `TN` / `TN_MAX` | 4 | `bpu_pkg`、`front_pkg` |
| 每 lane 训练数据 | 有效、是否 RVC、基址 pc、实际方向、分支类别（3 位）、目标、预测方向、`alt_pred`、`pcpn`、各表 tag（8 位）和 idx（10 位） | `core_back2front.sv` 端口 |
| `HCK_W`、`EPOCH_W`（8）、`BCK_W` | 后端带回前端的 BPU 修复记录位宽 | `bpu_stage_pkg`、`front_pkg` |

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

内部连线：`core_front` 的输入是后端本拍的输出（`out_mispred`、`out_rf_*`（后端的分支修复记录）、`out_stall`、`out_redirect_pc`、`rob_bcast_fence / fence_i`、提交流、FTQ 提交信息、`csr_status_*`）；输出是 `front2pre_*`（给后端预处理单元的取指组）和 `commit_upd_free / commit_tq_free`（BPU 队列空闲项数，给紧凑 ROB 的提交额度，EXP-028）。

## 4. 结构

```
 back_top ──out_mispred / out_rf_* / out_stall / out_redirect_pc / 提交流 / FTQ 提交信息──┐
    ▲ front2pre_* (16 lane)                                                         ▼
    │                                                              core_back2front（寄存一拍）
 core_front2back ◄── 前端输出 ◄── front_top ◄── 重定向 / 训练 / fence ──────────┘
   （截断 + hold）        ▲ can_read = !stall_q | refetch_q
 core_top: pmu_ev_core（事件总线，给测试平台读）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `core_top.sv` | 370 | 顶层连线，`pmu_ev_core` 实例 |
| `core_front.sv` | 283 | `front_top`、`core_back2front`、`core_front2back` 的连接，`can_read` |
| `core_back2front.sv` | 192 | 提交 lane 的指令类别判定（JAL / JALR / BR、call / icall / ret）和训练包，重定向和 fence 寄存器 |
| `core_front2back.sv` | 176 | 在第一个"有效且预测跳转"的 lane 之后截断；hold 寄存器 |

状态：`core_back2front`：`refetch_q`、`refetch_address_q`、`rf_*_q`（分支修复记录）、`itlb_flush_q`、`fence_i_q`、`stall_q`，以及每个提交 lane 一组 `upd_*_q`（共 8 组）；`core_front2back`：`hold_*_q`（16 个 lane 的整组 + `next` 地址、`bpu_ck`、`slot_kind`）。`core_top` 自己没有寄存器（`pmu_ev_core` 里有两个恢复状态位，见 pmu.md）。

## 5. 一拍内的数据流

模型顺序（`SimCpu::cycle`）：先由寄存的 `b2f` 给前端的输入，前端各阶段组合，`f2b` 取前端输出给后端，后端各阶段组合；时钟沿上 `b2f`、`f2b` 的寄存器更新。RTL 一一对应：

### 5.1 `core_back2front`：后端 → 前端（寄存一拍）

- 重定向：`refetch_q <= out_mispred`、`refetch_address_q <= out_redirect_pc`。`out_mispred` 在 `back_top_glue` 里已经把冲刷算进去：`flush_q | (dec_bcast_mispred & ~rob_bcast_flush)`（`FLUSH_REG` 打开时冲刷晚一拍，见 docs/FLUSH_REG.md）；分支修复记录 `rf_*_q` 只在 `out_rf_valid`（不含冲刷）时有意义，且只在重定向的周期被读；
- `itlb_flush_q <= rob_bcast_fence`、`fence_i_q <= rob_bcast_fence_i`、`stall_q <= out_stall`（`out_stall = ~pre2front_ready`）；
- 训练包：对每个有效提交 lane，按指令类型分类（JAL → `BR_JAL`；JAL 且 `rd = x1` → `BR_CALL`；JALR 且 `rd = x1` → `BR_ICALL`；JALR 且 `rs1 = x1`、`rd = x0`、立即数 0 → `BR_RET`；其他 JALR → `BR_IDIRECT`；条件分支 → `BR_DIRECT`；其余 `BR_NONCTL`），实际方向 = JAL / JALR 恒真、条件分支取 `br_taken`，目标 = 分支 / JAL / JALR 取 `diag_val`、其他取 `pc + (is_rvc ? 2 : 4)`；预测方向、`alt_pred`、`pcpn`、tag、idx 取自 FTQ 提交信息。无效 lane 的字段清零。

### 5.2 `core_front`：能否交付

`can_read = !stall_q | refetch_q`（用寄存值）。它同时作为 `front_top.fifo_read_enable`，决定前端是否读取取指组 FIFO，也决定 `core_front2back` 选前端输出还是 hold。

### 5.3 `core_front2back`：前端 → 后端

1. `taken_lane[j] = lane_valid[j] & predict_dir[j]`；`cut_valid[j] = lane_valid[j] & 没有更低的 lane 是 taken_lane`（取指组在第一个预测跳转之后截断）；
2. `can_read` 为真时 `back_* = 前端输出`，否则 `back_* = hold`；
3. 时钟沿：hold 寄存器每拍都装 `back_*`（后端看到的整组）。它只在"上一拍后端停顿且没有重定向"的拍被读，此时 `can_read = 0`，后端上一拍什么都没接收（`PreIduQueue` 的接收是全有或全无），所以整组正是要保持的那一组。

## 6. 关键路径与深度

depth 待测（由协调者补）。从代码读出的、未综合验证的链：

- `core_back2front` 的类别判定：提交类型 / `dest_areg` / `src1_areg` / `imm == 0` 比较 → 类别选择 → 目标选择（含 `pc + 2 / 4` 加法）→ `upd_*_d` → 寄存器。起点是 ROB 的提交输出，所以它是"提交 → 训练包寄存器"路径；
- `core_front2back`：16 lane 的"有更低 taken lane"前缀（`cut_before`）→ `cut_valid` → `can_read` 选择 → 到后端预处理单元的 `front2pre_valid`；`can_read` 来自两个寄存器，不是长的部分；
- `can_read` 同时扇出到整个取指组 + hold 的 16 lane 选择（每 lane 的 32 位指令、pc、预测信息），扇出大。

## 7. 与模型的差异和取舍

- **没有 `FE_PAIR`**：模型的 `Front2Back::comb` 带 `FE_PAIR` 逻辑（环境变量 `FE_PAIR`，默认 0，`include/env.h`；`config.h` 注明 FE_PAIR / FE_IPF 只在模型里、默认 0），一个取指组可以在预测跳转之后接第二个块。RTL 没有，只做"第一个预测跳转之后截断"，等价于 `FE_PAIR = 0`。
- **hold 寄存器不用 `fire` 清 lane**：模型在停顿时把后端已接收的 lane 的 valid 清掉（`Front2Back::seq`）；RTL 因为后端接收是全有或全无而不需要。这个"全有或全无"的前提写在 RTL 文件头注释里，由 `PreIduQueue::comb_accept_front` 的实现保证，本次没有逐行核对。
- **无效训练 lane 清零**：模型对无效提交 lane 保持字段旧值，RTL 清零（所有消费者都用 `upd_valid` 屏蔽），这个差别不可观察。
- **前端 → 后端的元数据**：模型传 `meta`（`fo.meta`）和 `front_stall` / `front_tq_free` / `front_upd_free`（前端的提交额度）；RTL 传 `bpu_ck`、`slot_kind`，额度走 `commit_upd_free / commit_tq_free` 直接进后端（`core_top` 里 `back_top.front_stall` 接常量 0）。模型的 `front_stall = fo.commit_stall`（`front_top.cpp` 里是 `bpu_output.update_queue_full`）。紧凑 ROB 下 `update_queue_full` 是否恒为 0、RTL 接 0 是否与模型一致，本次没有核对。
- **JAL / JALR 类别判定的细节**：模型对 JALR 先判 RET 再判 `dest_areg == 1`（不看 `dest_en`），RTL 的 `BR_ICALL` 多要求 `dest_en`。`rd = x1` 的 JALR 总是 `dest_en`，所以不可观察；未验证。
- **没有 `restart_at` / `restart`**：模型里从快速模式切回时给 `b2f` 和 `f2b` 注入重取指、丢 hold 组（`SimCpu::restore_pc`）；RTL 没有这个入口（检查点恢复由测试平台完成）。
- **PMU 事件总线**在 RTL 里挂在 `core_top`（`u_pmu_ev`，见 pmu.md）；模型里 PMU 在后端采样（`back.pmu_sample`）。

RTL 里注释和代码不一致、值得清理的地方（只记录，没有改）：

- `core_front2back.sv`、`core_top.sv` 的文件头仍写"8 → 16 lane 加宽"。现行 `FETCH_WIDTH = BACKEND_FETCH_WIDTH = 16`，没有加宽，那段 `for (j < BACKEND_FETCH_WIDTH)` 先清零再整体覆盖是多余的；
- `core_top.sv` 文件头"the pmu counters are not on a CSR yet"：现状见 pmu.md。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）。
- **Lint**：`scripts/lint_chip.sh`（以 `soc_top` 为顶，覆盖本模块）。
- **Linux 启动门禁**：`scripts/build_soc64_linux.sh` + `scripts/linux_gate.sh`（全程）；`scripts/linux_segments_cmp.sh`（并行窗口，RTL 对模型）。
- **与模型对齐**：`scripts/cmp_trace_model.sh`（整程序周期与提交数）、`scripts/align_check.sh`（PMU 序列与 PTAB 写 / 预测表更新的指纹，找第一个不同的区间）。
- **没有模块级的独立测试**（`tests/` 下没有 core_top、b2f、f2b 的测试）。胶水逻辑只靠整核周期相等和对比保证。**待补**：一个 `core_front2back` 与模型 `Front2Back::comb` 的随机并排测试（随机取指组 + 随机停顿 / 重定向序列）；训练包分类与模型 `Back2Front::seq` 的并排测试。

## 9. 参数与开关速查

`FETCH_WIDTH`、`BACKEND_FETCH_WIDTH`、`COMMIT_WIDTH`、`DECODE_WIDTH`（`ttg_cfg_pkg`）；`TN` / `TN_MAX`（前端包）；`FLUSH_REG`（docs/FLUSH_REG.md，影响 `out_mispred`）；模型侧 `CFG_BACKEND_FETCH_WIDTH`、`FE_PAIR`（环境变量，默认 0）。

## 10. 变更记录

- 本分支（`261bd67..HEAD`）未改动 `rtl/core`；更早：见 git 历史。
- PMU 事件包 `rtl/pmu/pmu_ev_pkg.sv` 已提交为 60ed422：发射队列事件 LD / STA 换成 MEM，新增 FP 队列事件，总数仍 66，id 52..65 重新排布（详见 pmu.md 第 10 节）；`core_top.sv` 只写 tier 1 的 18 个事件（id 0..34 之内），不受影响。
- 2026-11-18：删除 `core_top.sv` 里一个空的 `always_comb begin end` 及其注释。
