---
module: front_ctrl
area: frontend
rtl: rtl/frontend/front_ctrl.sv、front_ctrl_enables.sv、front_refetch_ctrl.sv
model: trace-model front-end/front_ctrl.h、front-end/front_top.cpp（调度单元 `front.core.ctrl`，类 `FrontControl`，阶段 `control`、`enables`、`finish`）
status: 整核周期与模型逐个相等（fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: 5 层（front_ctrl，单模块综合，2026-11-18，EXP-070 之前测量，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# front_ctrl 设计文档

## 1. 职责

前端的控制：决定这一拍有没有全局重取指（refetch）及其地址、统一 FTQ（`ftq_ibuf` 里的 64 项 Unified FTQ，见 [ftq_ibuf.md](ftq_ibuf.md)）各指针能不能前进、指令队列 `inst_fifo` 读不读、BPU 能不能往前走、预译码冲刷是否生效。模型里是调度单元 `front.core.ctrl`（类 `FrontControl`，阶段 `control`、`enables`、`finish`）。

RTL 拆成三个文件，装配在 `front_ctrl.sv`：

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `front_ctrl.sv` | 53 | 只连线：`front_refetch_ctrl` + `front_ctrl_enables` |
| `front_refetch_ctrl.sv` | 49 | 全局 refetch 和重取指地址；前端控制里**唯一的状态**（晚一拍的预译码 refetch） |
| `front_ctrl_enables.sv` | 46 | 纯组合：FTQ 的 S0 写 / IFU 读 / S2 写使能、`inst_fifo` 读使能（`predecode_can_run`）、BPU 门控、预译码冲刷 |

前端已经没有独立的取指地址队列、PTAB 和 front2back 队列（EXP-070 并入统一 FTQ）。代码里 `fa_*`（取指地址）、`s2_*` 这些名字指的是统一 FTQ 的指针：`fa_empty` = `ifu_ptr == bpu_ptr`，`s2_empty` = `pd_ptr == s2_ptr`（`ftq_ptr.sv`）。端口名 `bpu_ptab_write_enable` 是旧名，含义是"BPU 的 S2 块要写 FTQ"。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| FTQ 满 `ftq_full` | `bpu_ptr - comm_ptr >= FTQ_SIZE - 1`（63）或 `bpu_ptr - ifu_ptr >= 15` | `ftq_ptr.sv`（`FTQ_SIZE = 64`；15 是 `ftq_ptr.sv` 里的字面量，没有具名常量） |
| `fa_cnt_sat` | `min(bpu_ptr - ifu_ptr, 3)`，2 位 | `ftq_ptr.sv` |
| 指令队列有空位 `inst_fifo_room` | `inst_fifo` 占用 + I-Cache 在途取指数 `ic_inflight` < `INST_FIFO_DEPTH`（= `INSTRUCTION_FIFO_SIZE` = 16） | `front_fetch_buf.sv`、`front_pkg` |
| 重取指地址 | 64 位 | `XLEN_BITS` |

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n` | |
| 入 | `be_refetch`、`be_refetch_address` | 后端重定向（寄存后的 back2front） |
| 入 | `be_fifo_read_enable` | 后端本拍收取指组（`core_front` 的 `can_read`） |
| 入 | `icache_ready` | I-Cache 能接一个取指请求 |
| 入 | `ftq_full`、`fa_empty`、`fa_cnt_sat`、`s2_empty` | 统一 FTQ 的寄存视图（`ftq2fe`） |
| 入 | `bpu_hold_n` | BPU：S1 里还可能被 S2 覆盖丢掉的块数（0 或 1，`bpu_ctl`：`r0.valid && r0.sq`） |
| 入 | `inst_empty`、`inst_fifo_room` | 指令队列空、有空位 |
| 入 | `bpu_icache_read_valid` | BPU 的 S0 块要写 FTQ（分配 `bpu_ptr`） |
| 入 | `bpu_ptab_write_enable` | BPU 的 S2 块要写 FTQ（`s2_ptr`） |
| 入 | `bpu_override_squash_n` | S2 覆盖要丢掉的最年轻块数（0..2） |
| 入 | `checker_flush_enable`、`checker_flush_address` | 预译码检查器要冲刷及修正后的地址 |
| 出 | `global_refetch`、`refetch_address` | 全局重取指及地址（后端优先） |
| 出 | `fa_rd_en` | IFU 读 FTQ 队首（`ifu_ptr`）并向 I-Cache 发请求 |
| 出 | `predecode_can_run` | 读指令队列队首并做预译码检查 |
| 出 | `bpu_icache_read_ready` | BPU 门控 |
| 出 | `fa_wr_en`、`fa_drop_tail_n`、`s2_wr_en` | FTQ 的 S0 写、丢尾块数、S2 写 |
| 出 | `do_predecode_flush` | 预译码冲刷（检查器要求且本拍确实检查了） |

## 4. 结构

```
 be_refetch / 地址 ─┐
 do_predecode_flush, checker_flush_address ─► front_refetch_ctrl ──► global_refetch、refetch_address
                                                 (predecode_refetch_q 1 位 + predecode_refetch_address_q 64 位)
 FTQ 视图、inst_fifo 状态、icache_ready、BPU 信号 ─► front_ctrl_enables（纯组合）──► 各使能、do_predecode_flush
```

状态只有 `predecode_refetch_q` 和 `predecode_refetch_address_q`：检查器在第 t 拍发现预测错，第 t+1 拍它们成为全局 refetch 和重取指地址。

## 5. 一拍内的数据流

`front_refetch_ctrl`：`global_refetch = be_refetch | predecode_refetch_q`；`refetch_address = be_refetch ? be_refetch_address : predecode_refetch_address_q`；次态每拍装载 `do_predecode_flush` 和 `checker_flush_address`（模型在没有冲刷时把地址清 0，RTL 不清；地址只在 `predecode_refetch_q` 为 1 时被用到）。

`front_ctrl_enables`（`front_ctrl_enables.sv` 原样）：

| 信号 | 表达式 |
| --- | --- |
| `fa_rd_en` | `icache_ready & !fa_empty & !global_refetch & (fa_cnt_sat > bpu_hold_n) & inst_fifo_room` |
| `predecode_can_run` | `be_fifo_read_enable & !inst_empty & !s2_empty & !global_refetch` |
| `bpu_stall` | `ftq_full` |
| `bpu_can_run`（内部信号） | `!bpu_stall | global_refetch` |
| `bpu_icache_read_ready` | `!bpu_stall` |
| `fa_wr_en` | `bpu_icache_read_valid & bpu_can_run` |
| `s2_wr_en` | `bpu_ptab_write_enable & !global_refetch` |
| `fa_drop_tail_n` | `global_refetch ? 0 : bpu_override_squash_n` |
| `do_predecode_flush` | `predecode_can_run & checker_flush_enable` |

几点说明：

- `fa_cnt_sat > bpu_hold_n`：S1 里的块（还可能被 S2 覆盖丢掉）对应的 FTQ 项不让 IFU 取走。这替代了原来取指地址队列的 `head_fresh`，S2 覆盖不再组合地决定本拍能不能弹出；
- `predecode_can_run` 含 `be_fifo_read_enable`：取指组检查完直接送后端（`core_front2back`），后端不收就不检查；也要求 S2 已经写过该 FTQ 项（`!s2_empty`），否则检查器没有预测可比；
- 预译码冲刷后 FTQ 的回滚（`pd_ptr` 之后的项作废）在 `ftq_ptr` 里做（`pd_flush`），见 [ftq_ibuf.md](ftq_ibuf.md)。

## 6. 关键路径与深度

单模块综合深度 **5 层**（front_ctrl；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。这是统一 FTQ 改写（EXP-070）之前测的，之后 `front_ctrl_enables` 改过，没有重测。逻辑本身是一级与或；值得看的是进出它的路径：`checker_flush_enable`（检查链末端）→ `do_predecode_flush` → `predecode_refetch_q` 次态、I-Cache `invalidate`、`front_pd_info`、FTQ 的 `pd_flush`。BPU 侧的输入（`bpu_hold_n`、`bpu_override_squash_n`、S2 写）都来自 BPU 的阶段寄存器。

## 7. 与模型的差异和取舍

- `FrontControl::finish` 里的 PMU 前端分类（`g_pmu_front`）：RTL 不在前端里做；
- `global_reset`：模型的 `ctrl.out.global_reset` 只在 `FrontTop::init()` 一拍有效，RTL 用 `rst_n`，使能里没有"& !reset"；
- `bpu_can_run` 只是 `front_ctrl_enables` 的内部信号（不出端口）。

未核对：`front_ctrl_enables` 与模型 `FrontControl::enables` / `BpuPipe::comb_front` 的逐项对照只靠整核周期相等，没有单独的穷举测试。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，周期对 `scripts/ref_cycles.txt`（模型默认配置 = RTL 配置）逐个相等。任何一个使能错一拍，取指时序就变，周期会差。
- **Linux**：`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`；前端 PT / UP 指纹 `scripts/align_check.sh`。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**。**待补**：`front_ctrl_enables` 与模型表达式并排的穷举测试（输入十几位，可以穷举）。

## 9. 参数与开关速查

无开关。用到的常量：`XLEN_BITS`、`INSTRUCTION_FIFO_SIZE`、`FTQ_SIZE`（`ttg_cfg_pkg`）；`INST_FIFO_DEPTH`（`front_pkg`）。

## 10. 变更记录

- 2026-11-28 清理：删 `front_ctrl` / `front_ctrl_enables` 无读者的输出 `bpu_can_run`（改为 `front_ctrl_enables` 内部信号）（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`）：文档按现行 RTL 重写（第 1–9 节；旧正文描述的是 EXP-070 之前 / 删除分支标签之前的结构）。
- 2026-11-18（exp/agu-share）：`fa_rd_en` 加 `!fa_head_fresh`，去掉对同拍 BPU 覆盖的依赖 `4eb8f0e`。
- 更早：见 git 历史。
