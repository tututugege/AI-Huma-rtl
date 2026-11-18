---
module: front_ctrl
area: frontend
rtl: rtl/frontend/front_ctrl.sv、front_ctrl_enables.sv、front_refetch_ctrl.sv
model: trace-model front-end/front_ctrl.h、front-end/front_top.cpp（调度单元 `front.core.ctrl`，类 `FrontControl`，阶段 `control`、`enables`、`finish`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 5 层（front_ctrl，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# front_ctrl 设计文档

## 1. 职责

前端的控制：决定这一拍有没有全局重取指（refetch）、各个队列读不读写不写、BPU 能不能往前走、送后端的取指组从队列还是从旁路出。模型里是一个调度单元 `front.core.ctrl`（类 `FrontControl`），分三个阶段：

- `control`：全局 refetch（后端重定向，或上一拍预译码检查器要求的重定向）、BPU 最后一级的决定、取指地址队列队首能不能弹出（`pipe_head_ok`）；
- `enables`：取指地址队列读使能、指令队列与 PTAB 的读使能（二者总是一起读）、PTAB 写使能和旁路；
- `finish`：下一拍的前端寄存器（`front_state`）、送后端的输出、PMU 的前端分类。

RTL 把它拆成三个文件，装配在 `front_ctrl.sv`：

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `front_ctrl.sv` | 59 | 只连线：`front_refetch_ctrl` + `front_ctrl_enables` |
| `front_refetch_ctrl.sv` | 49 | 全局 refetch 和重取指地址；前端控制里**唯一的状态**（晚一拍的预译码 refetch） |
| `front_ctrl_enables.sv` | 75 | 纯组合：读写使能、BPU 门控、f2b 输出旁路、预译码冲刷 |

模型 `finish` 里的其他项在 RTL 里的位置：携带寄存器 `lh_*` 在 `front_pred_path.sv`（见 [front_top.md](front_top.md)、[predecode.md](predecode.md)）；PDCKPT 信息 `pd` 在 `front_pd_info.sv`；队列满 / 空标志是各队列计数的函数，直接在 `front_fifo` 里算（见 [front_fifos.md](front_fifos.md)）；输出 mux 在 `front_pred_path.sv`；`commit_upd_free / commit_tq_free` 来自 BPU。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| 取指地址队列"满"阈值 | 15（= 深度 16 - 1） | `FETCH_ADDR_FIFO_FULL_AT`（`front_pkg`） |
| 指令队列、PTAB、front2back 的"满"阈值 | 16、15、8 | `INST_FIFO_FULL_AT`、`PTAB_FULL_AT`、`F2B_FIFO_FULL_AT`；PTAB 的"满"在 RTL 里没有用（`ptab.sv` 的 `full` 悬空），PTAB 溢出由 BPU 的信用防止 |
| 预译码重取指地址 | 64 位 | `XLEN_BITS` |
| `FE_RFAST` 位 1（PTAB 旁路） | 开 | `(FE_RFAST & 2) != 0`，见 `front_ctrl_enables.sv` |

## 3. 接口

`front_ctrl` 的端口（信号名与模型的线名一致）：

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `be_refetch`、`be_refetch_address` | 后端重定向 |
| 入 | `be_fifo_read_enable` | 后端本拍读 front2back 队列（后端上一拍没有停顿或有重定向） |
| 入 | `icache_ready` | I-Cache 能接一个取指请求（来自寄存器） |
| 入 | `fa_full / fa_empty / inst_empty / ptab_empty / f2b_full / f2b_empty` | 各队列拍初状态 |
| 入 | `fa_head_fresh` | 取指地址队列队首是上一拍才 push 的 |
| 入 | `bpu_icache_read_valid`、`bpu_ptab_write_enable`、`bpu_override_squash` | BPU 的 S0 发射、S2 块写 PTAB、S2 覆盖要丢最年轻的取指地址 |
| 入 | `checker_flush_enable`、`checker_flush_address` | 预译码检查器要冲刷及修正后的取指地址 |
| 出 | `global_refetch`、`refetch_address` | 全局重取指及地址（后端优先） |
| 出 | `fa_rd_en`、`predecode_can_run`（= 指令队列 / PTAB 读使能） | 读使能 |
| 出 | `fa_wr_en`、`fa_drop_tail`、`ptab_wr_en`、`f2b_wr_en` | 写使能；丢取指地址队列最年轻项 |
| 出 | `bpu_can_run`、`bpu_icache_read_ready` | BPU 门控（`bpu_can_run` 只用于内部，顶层未用） |
| 出 | `f2b_use_bypass`、`front_out_valid` | 输出旁路和输出有效 |
| 出 | `do_predecode_flush` | 预译码冲刷（检查器要求且本拍确实读了队首） |

## 4. 结构

```
 be_refetch / 地址 ─┐
 do_predecode_flush,                  predecode_refetch_q (1 位) + predecode_refetch_address_q (64 位)
 checker_flush_address ─► front_refetch_ctrl ──► global_refetch、refetch_address
 队列满空、icache_ready、BPU 信号、checker_flush_enable ─► front_ctrl_enables（纯组合）──► 各使能、旁路、do_predecode_flush
```

状态只有 `predecode_refetch_q` 和 `predecode_refetch_address_q`：检查器在第 t 拍发现预测错，第 t+1 拍它们成为全局 refetch 和重取指地址。

## 5. 一拍内的数据流

`front_refetch_ctrl`：`global_refetch = be_refetch | predecode_refetch_q`；`refetch_address = be_refetch ? be_refetch_address : predecode_refetch_address_q`（后端优先）；次态每拍都装载 `do_predecode_flush` 和 `checker_flush_address`（模型在没有冲刷时把地址清 0，RTL 不清；这个地址只在 `predecode_refetch_q` 为 1 时被用到，`bpu_cmd` 里 `refetch_address` 只在 `refetch` 下进入 pc 和历史）。

`front_ctrl_enables`：

| 信号 | 表达式 |
| --- | --- |
| `fa_rd_en` | `icache_ready & !fa_empty & !global_refetch & !fa_head_fresh` |
| `predecode_can_run` | `!inst_empty & (!ptab_empty | bpu_ptab_write_enable) & !f2b_full & !global_refetch`（`| bpu_ptab_write_enable` 是 `FE_RFAST` 位 1：S2 块同拍写 PTAB、检查器同拍读） |
| `bpu_can_run` | `!fa_full | global_refetch` |
| `bpu_icache_read_ready` | `!fa_full & bpu_can_run` |
| `fa_wr_en` | `bpu_icache_read_valid & bpu_can_run` |
| `ptab_wr_en` | `bpu_ptab_write_enable & !global_refetch` |
| `fa_drop_tail` | `bpu_override_squash` |
| `do_predecode_flush` | `predecode_can_run & checker_flush_enable` |
| `f2b_use_bypass` | `be_fifo_read_enable & f2b_empty & predecode_can_run` |
| `f2b_wr_en` | `predecode_can_run & !f2b_use_bypass` |
| `front_out_valid` | `(be_fifo_read_enable & !be_refetch & !f2b_empty) | f2b_use_bypass` |

三点说明：

- `fa_head_fresh` 项是 EXP-FEOVR 的改动（`4eb8f0e`）：BPU 的 S2 可能覆盖一个块并把"最年轻的取指地址"丢掉；这一拍的覆盖决定如果直接决定队首能不能弹出，路径就从 BPU 末级一直延伸到 I-Cache 的请求。现在规定：一个地址在被 push 之后的下一拍不弹（push 在第 t 拍，第 t+1 拍队首是"新鲜的"，第 t+2 拍才可弹），因为能丢掉它的覆盖最迟在第 t+1 拍决定并应用。代价是这个地址晚一拍进 I-Cache，模型对应 `CFG_FE_OVR_REG = 1`，16 个 SPEC 点几何平均 IPC -0.82 %（提交信息）。`head_fresh` 本身的实现见 [front_fifos.md](front_fifos.md)；
- BPU 的 `ptab_size` 信用（`bpu_ctl`）替代了 PTAB 的"满"锁存，所以这里没有 `ptab_full`；
- `bpu_stall = fa_full`：取指地址队列满（15 项）就停 BPU，但有全局 refetch 时仍然放行。

## 6. 关键路径与深度

单模块综合深度 **5 层**（front_ctrl；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\inst_empty` 到 `\front_out_valid`。。这三个文件的逻辑本身很浅（一级与或）；从代码读出的，未综合验证：值得看的是进出它们的路径而不是它们自己——`checker_flush_enable`（检查链末端）→ `do_predecode_flush` → `predecode_refetch_q` 次态、I-Cache `invalidate`、`front_pd_info`；以及 `bpu_ptab_write_enable`（BPU 的 `d_valid`，来自 S2 阶段寄存器）→ `predecode_can_run` → 两个队列的读使能和 `front2back` 写使能。EXP-FEOVR 去掉的是 `bpu_override_*` → `fa_rd_en`，使 BPU 末级到 I-Cache 请求的路径断开。

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| `fa_rd_en` 不看同拍 BPU 覆盖，改为 `!fa_head_fresh` | `4eb8f0e` | 断开 BPU 末级 → 取指地址弹出 → I-Cache 请求 |

## 7. 与模型的差异和取舍

模型里有、RTL 里没有复刻的：

- `FrontControl::finish` 里的 PMU 前端分类（`g_pmu_front`）：RTL 不在前端里做；
- `global_reset`：模型的 `ctrl.out.global_reset` 只在 `FrontTop::init()` 一拍有效，RTL 用 `rst_n`，所有使能里没有"& !reset"；
- `front_ctrl_enables` 头注释列出的条件编译掉的路径（slot1、mini flush、2-ahead、两条 I-Cache 旁路、dummy PTAB 项）：没有构建；
- 模型的 `pipe_head_ok` 用队首的 `head_age`（保留到 3 的计数）和 BPU 流水深度（`depth()`）；RTL 没有年龄字段，用一位 `head_fresh`（深度固定为 2，`MAIN_LAT = 2`）。

RTL 与模型保持一致的细节：

- `predecode_can_run` 已经含 `!f2b_full`，所以模型里的 `front2back_can_write` 与它相同；
- `f2b_use_bypass` 里模型还有 `!saved.front2back_FIFO_valid`，RTL 省掉：队列空时没有队首（`front_out_valid` 的第一项含 `!f2b_empty`）；
- `front_out_valid` 的 `be_fifo_read_enable & !be_refetch`：模型的 `f2b_port` 用 `redirect.valid` 清队列并以 `fifo_read_enable` 读，二者合起来就是这里的写法。

未核对（继承自旧文档）：

- `front_ctrl_enables.sv` 头注释说"上述简化都经过对字面转写的穷举回放证明"：回放是旧体系（`spec/` 回放，已退役）做的，本轮没有重做；
- 旧文档（front_basic.md）写 `bpu_can_run = ~(fa_full | ptab_full) | global_refetch`：这是旧设计，现行 RTL 和模型（`BpuPipe::comb_front`：`!fetch_addr_fifo_full || reset || refetch`）都没有 `ptab_full`，该式不再适用，没有带入本文。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`：67/67 通过，周期逐个相等。这是控制使能的实际检验：任何一个使能错一拍，取指时序就变，周期会差。
- **Linux**：`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`（见 [front_top.md](front_top.md) 第 8 节）；前端 PT / UP 指纹 `scripts/align_check.sh`。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧的 spec 回放（`front_ctrl.io`、变异检查）已随旧体系退役。**待补**：给 `front_ctrl_enables` 补一个"与模型表达式并排"的穷举测试（输入只有十几个位，可以穷举），在后续改深度时用。

## 9. 参数与开关速查

`FE_RFAST`（位 1：PTAB 旁路）、`FETCH_ADDR_FIFO_SIZE`、`PTAB_SIZE`、`INSTRUCTION_FIFO_SIZE`、`FRONT2BACK_FIFO_SIZE`（`ttg_cfg_pkg`）；`FETCH_ADDR_FIFO_FULL_AT` 等（`front_pkg`）。模型侧 `CFG_FE_OVR_REG`（`include/config.h`，默认 0；RTL 与参考周期表对应 1）。

## 10. 变更记录

- 2026-11-18（exp/agu-share）：`fa_rd_en` 加 `!fa_head_fresh`，去掉对同拍 BPU 覆盖的依赖 `4eb8f0e`。
- 更早：见 git 历史。
