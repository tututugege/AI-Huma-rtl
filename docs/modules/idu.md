---
module: idu
area: backend
rtl: rtl/backend/idu
model: trace-model back-end/Idu.cpp、back-end/include/Idu.h（调度单元 `back.idu`，类 `Idu`，阶段 `comb_decode`、`comb_fire`）
status: 整核周期与模型逐个相等（`fm_gate` 69/69 PASS、0 周期偏差，Linux 26/26 窗 PT/UP 100% 全等）
depth: **19 层 / 6,595 cells**（Yosys `strash;balance;map`，较 `main` 66 层 / 31,607 cells 降 **−79.1%**）；**TSMC 28nm HPC+ DC (`ssg0p81v125c`, `0.50ns`)：14 级 / 0.37 ns（2.70 GHz）/ WNS 0.00 ns / 1,994.2 µm²（较 `main` 18,195.6 µm² 面积 −89.0%）**
---

# idu 设计文档

## 1. 职责

译码单元（IDU）：把指令缓冲（`pre_idu_queue`）发来的最老 8 条指令译成 uop 字段，同时是整个后端的"分支误预测广播站"。自方案 C（9-bit `rob_ptr` 循环年龄冲刷）落地后，IDU **不再分配分支标签（`br_id`）或维护 `br_mask` / `clear_mask`**：

1. 译码：每个 lane 把一个 32 位指令字译成类型、源 / 目的寄存器号、立即数、功能码、是否非法等字段（`dec2ren`）；取指缺页的指令变成一条带缺页标志的 NOP（`diag_val` 里放指令字）；
2. 握手：重命名接收这一组（`ren2dec.ready`），所有有效 lane 就被消耗（`idu_consume.fire`）；冲刷或误预测那一拍什么都不消耗；
3. 广播分支结果（`dec_bcast`）：上一拍 EXU 报来的误预测及 9-bit ROB 指针 `{redirect_rob_flag, redirect_rob_idx}`，寄存一拍后广播给后端各模块，用于循环年龄比较（`(a_flag == b_flag) ? (a_idx > b_idx) : (a_idx < b_idx)`）。

模型对应一个调度单元 `back.idu`（`Idu::comb_decode` = 先 `branch()` 再 `decode()`；`Idu::comb_fire` = 握手）。RTL 删除了 `idu_br_alloc` / `idu_br_group` / `idu_br_state` / `idu_br_cp` / `idu_fire_ctl`，仅保留 8 路 `idu_decoder` + `idu_br_latch` + `idu_bcast`。

## 2. 配置（`ttg_cfg_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| lane 数 | 8 | `DECODE_WIDTH` |
| 分支冲刷机制 | 9-bit `rob_ptr`（`{rob_flag, rob_idx}`）循环年龄比较（已彻底删除 `br_id` / `br_mask` / `clear_mask`） | `ROB_IDX_WIDTH = 8` |
| 指令字宽度 | 32（压缩指令在前端展开后才进入） | `pre_issue_entries_inst[31:0]`；展开在 `rtl/frontend/rvc_expand.sv` |
| 译码类别 | 40 类（含"非法"）；无 FP 时 FP 类全零 | `idu_ctrl_decode` 的 `NCLS = 40` |
| F/D | 开 | `FPRF_NUM != 0` |
| 已知 CSR | 24 个（无 FP 时 21 个） | `idu_ctrl_decode` 的 `NUM_KNOWN_CSR`；不在表里的 CSR 访问译成一条 NOP 并标为非法指令（`CLS_CSR_NOP`，`csr_illegal` 恒为 1） |

## 3. 接口

信号组按模型的 `in` / `out` 命名；顶层 `idu.sv` 连接 8 路译码器、`idu_br_latch` 与 `idu_bcast`。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `pre_issue_entries_{valid, inst, page_fault_inst, ftq_idx, ftq_offset, ftq_is_last}[8]` | 指令缓冲发来的最老 8 条 |
| 入 | `ren2dec_ready` | 重命名可以接收这一组 |
| 入 | `rob_bcast_flush` | 全局冲刷（`FLUSH_REG` 后晚一拍，docs/FLUSH_REG.md） |
| 入 | `exu2id_{mispred, redirect_pc, redirect_rob_idx, redirect_rob_flag, ftq_idx, ftq_offset, br_pc, br_is_rvc}` | EXU 的分支结果；寄存一拍后才使用 |
| 出 | `dec2ren_valid[8]`、`dec2ren_uop_*[8]` | 译码结果（不含 `br_id` / `br_mask`） |
| 出 | `idu_consume_fire[8]` | 本拍消耗了哪些 lane（指令缓冲据此弹出） |
| 出 | `dec_bcast_{mispred, redirect_rob_idx, redirect_rob_flag}` | 分支误预测与 9-bit ROB 指针广播，供下游做循环年龄冲刷 |
| 出 | `br_latch_{mispred, redirect_pc, ftq_idx, ftq_offset, br_pc, is_rvc}` | 寄存后的分支结果，直接给 `back_top` / `pre_idu_queue` / 前端重定向用 |

没有输出 `is_rvc` 和 `mdp`：这两项在分派前再向 FTQ 读（见 dispatch.md / pre_idu_queue.md）。

## 4. 结构

```
 pre_issue[8] ─► idu_decoder × 8（idu_ctrl_decode: 类别一热 + ROM；idu_imm_gen: 立即数）─► dec2ren[8]
                 consume_fire[i] = pre_issue[i].valid & ren2dec_ready & !rob_bcast_flush & !latch_mispred
 exu2id       ─► idu_br_latch（EXU 结果寄存一拍，冲刷时清）─► idu_bcast（广播 dec_bcast）
```

| 文件 | 职责 |
| --- | --- |
| `idu.sv` | 顶层：连接 8 路译码器、`idu_br_latch`、`idu_bcast` 与 `consume_fire` |
| `idu_decoder.sv` | 一个 lane 的译码：包装控制字和立即数，取指缺页时变 NOP |
| `idu_ctrl_decode.sv` | 控制字：40 个互斥类别（一热）+ 常量表 ROM（22 位一行） |
| `idu_imm_gen.sv` | 各种格式的立即数一热选择 |
| `idu_br_latch.sv` | EXU 分支结果的一拍寄存（含 `redirect_rob_idx` / `redirect_rob_flag` / `ftq_offset`） |
| `idu_bcast.sv` | 广播寄存后的 `mispred` / `redirect_rob_idx` / `redirect_rob_flag` |

状态：仅保留 `br_latch` 一组寄存信号，译码本身无状态（原 `idu_br_alloc` / `idu_br_group` / `idu_br_state` / `idu_br_cp` / `idu_fire_ctl` 已全部删除）。

## 5. 一拍内的数据流

### 5.1 译码（只读指令缓冲的输出）

每个 lane：先看 `page_fault_inst`；有缺页则类型为 NOP，所有使能为 0，`diag_val = 指令字`，`page_fault_inst = 1`；否则按 `idu_ctrl_decode` 译码。几个规则（模型 `Idu::decode` 末尾）：

- 目的寄存器号是 x0（且不是浮点）则 `dest_en = 0`；f0 是真寄存器；
- 读改写 AMO（不是 LR 和 SC）且 rd = x0 时，目的寄存器号改成 32（整数 RAT 的第 33 项，见 ren.md），保持 `dest_en`；
- `func7` 取指令字 [31:25]，`csr_idx` 取 [31:20]；
- `src3` 只在 FP 融合乘加有，`src3_en` 同时表示"第三个源是浮点"；
- rv64：OP-IMM-32、OP-32 类的 `is_word = 1`；其中 `OP-32` 严格校验 RV64IM + Zba/Zbb 合法编码（`op32_alu_ok` 与 `MUL` 要求 `funct3 == 0`），非法编码落入 `CLS_ILLEGAL`（避免错误路径上被当作合法 ALU 改写目的寄存器）；
- `c.mv` 规范化（EXP-052）：`idu_decoder` 将 `add rd, x0, rs2`（含前端 `rvc_expand` 展开的全部 16-bit `c.mv rd, rs2`）规范化为语义等价的 `addi rd, rs2, 0`（`src1_areg = rs2, src2_en = 0, src2_is_imm = 1, imm = 0`），使后端 `ren` 的移动消除统一覆盖 RV64GC 压缩移动指令。

### 5.2 分支标签与掩码

1. `base_mask = now_br_mask & ~latch_clear_mask`：上一拍已解决的分支，这一拍译码的新指令就看不到它了（模型 `running`）。
2. `idu_br_alloc`：最低 8 个空闲标签，第 k 个给本组里第 k 条分支。
3. `idu_br_group`：lane i 里第 k 条分支（k = 前面分支数，`ttg_popcount`）取第 k 个标签；没有就是"截断"，该 lane 和之后的 lane 都丢弃（`lane_valid = 0`，`br_mask = 0`）；`lane_br_mask[i] = base_mask | 前面所有分支的标签`（前缀或）；`lane_cp_mask[i]` = 包含本分支自己的掩码，是写进快照表的值。

### 5.3 握手与标签状态

- `consume_fire = lane_valid & (重命名 ready & !冲刷 & !latch_mispred)`；只有 fire 的分支才真正占用标签。
- `idu_br_state` 次态，优先级：冲刷 > 误预测恢复 > 正常。
  - 冲刷：所有标签（除 0）空闲，掩码清零；
  - 误预测：先释放已解决的标签（`clear_mask`），再释放比被预测错的分支年轻的标签：`younger = now_br_mask & ~快照[br_id]`（用寄存的旧值），它们空闲、并从掩码里去掉；本拍不分配；
  - 正常：先释放已解决的标签，再占用本拍 fire 的分支的标签，掩码加上它们。
- 快照表：每拍所有项去掉 `clear_mask`；fire 的分支写自己标签的项（覆盖清除）。冲刷不清快照，因为标签再次分配前一定会被重写。
- `idu_br_latch`：`mispred_d = exu_mispred & !rob_flush`，`clear_mask_d = exu_clear_mask & !rob_flush`；其余字段（pc、`rob_idx`、标签、`ftq_idx`…）只在 `mispred` 时才有人读，原样寄存。

### 5.4 广播

`mispred`、`br_id`、`redirect_rob_idx`、`clear_mask` 直接是寄存值；`br_mask = 1 << br_id`（只在 `mispred` 时有人读）。模型 `branch()` 写成"没有误预测时 `br_id` = 0、`br_mask` = 0"，RTL 不屏蔽。

## 6. 关键路径与深度

单模块综合深度 **67 层**（idu；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_state.tag_free_q [0]` 到 `\u_state.now_mask_q [8]`。

从代码读出的长组合链（未综合验证）：

| 链 | 经过 |
| --- | --- |
| 译码 | 指令字 → 操作码 / funct 比较 → 40 个类别一热 → ROM 一热选择（22 位）→ `is_branch`（再进标签链）、`uop_*` 字段（出到 ren 的分配请求：`dest_en`、`dest_fp`） |
| 标签 | `is_branch` → 每 lane 的前面分支数（popcount）→ `rank_oh` → 在 8 个分配标签里选 → `lane_tag_oh` → `stall` → `dropped` 前缀或 → `lane_valid` → `consume_fire`（与 `ren2dec_ready`）→ `lane_commit_oh` → `commit_all_oh` → `tag_free_d` / `now_mask_d` |
| 空闲标签 | `tag_free_q` → `idu_br_alloc` 8 级取最低位 → `alloc_oh`（并入上一条链） |
| 掩码 | `base_mask` → 8 个 lane 的前缀或 → `lane_br_mask`（出到 ren 和分派，随指令走） |
| 误预测 | `latch_br_id` 译码 → 32 选 1 读快照（32 位）→ `younger_tags` → `tag_free_d` / `now_mask_d` |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `dbg`（pc、指令字、`inst_idx`）、`tma.*`（`is_ret`、`mem_commit_is_load/store`）、PMU（`idu_no_brtag`）、`uop_id`；
- 译码本身：模型用共享的软件译码器 `decode_inst`（`bridge/InstDecode.h`），RTL 是手写的类别一热 + ROM；两者一致靠 `fm_gate` 的逐条比较（含 Linux 启动）和 `tests/fp_decode`（只覆盖 F/D 类别）；
- 模型的 `Idu` 构造参数 `max_br`，RTL 固定为 `MAX_BR_PER_CYCLE`。

RTL 与模型保持一致的细节（读模型时容易误判）：

- 误预测的 `younger` 用寄存的旧掩码和旧快照（清除之前）；
- `clear_mask` 里标签 0 的位不起作用（模型循环从 1 开始）；
- 一拍内新 fire 的分支写快照时，值已经去掉了本拍的清除位；
- 译码结果对无效 lane 没有意义（RTL 对无效 lane 也照常译码，下游只在 `valid` 时读）。

已发现、未改动的点：

- `idu.sv`、`idu_*` 文件头注释里的"reference model commit 2f31e8d"已过时；
- `idu_br_state` 的 `clear_mask` 入参含义是"去掉标签 0 之后的"（`clear_eff`），`idu_br_group` 的 `base_mask` 用的是没去掉标签 0 的 `latch_clear_mask`，两处各自正确，但读时容易混；
- 模型 `branch()` 在没有误预测时把 `br_id` 清 0、`br_mask` 清 0，RTL 的 `idu_bcast` 不清；下游只在 `mispred` 时使用，应无影响，但没有逐一核对所有消费者。

**未核对（继承自旧文档）**：无（旧文档的内容全部没有采用）。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型（含译码结果：提交的指令是否正确），周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）：67/67 通过，周期逐个相等。
- **F/D 译码单测**：`tests/fp_decode/run.sh <工作目录>`：用 FP=1 的配置把 `idu_ctrl_decode` 单独 verilate，随机指令（浮点操作码各 4000 条）加 funct5 × fmt 的遍历，与 `check.py` 里按模型规则写的参考比较。这个测试不在整核门禁里，需要手工运行；只覆盖浮点指令的译码，整数部分没有。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有标签分配和掩码逻辑的独立测试**。旧体系（`spec/` 的 trace 回放、随机 trace、变异检查）已退役。**待补**：给 `idu_br_alloc` / `idu_br_group`（对照模型的串行循环）、`idu_br_state` + `idu_br_cp`（对照模型 `seq`）各补一个新旧并排的随机测试，尤其是"同拍清除、误预测、新分支"并存的情形；整数指令的译码也缺一个像 `fp_decode` 那样的单测。

## 9. 参数与开关速查

`DECODE_WIDTH`、`MAX_BR_NUM`、`BR_MASK_WIDTH`、`BR_TAG_WIDTH`、`MAX_BR_PER_CYCLE`、`FPRF_NUM`（F/D 类别）、`XLEN_BITS`（rv64 的 *W 类）、`CSR_IDX_WIDTH`。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 10. 变更记录

- 2026-11-25（`idu_br_latch` 迁出至 `back_top`）：将 `idu_br_latch.sv` 移至 `rtl/backend/back_top/` 并删除透传模块 `idu_bcast.sv`，`idu.sv` 去掉 `clk`/`rst_n` 与全部 `exu2id_*`/`dec_bcast_*`/`br_latch_*` 端口（仅保留 1-bit 输入 `dec_bcast_mispred`），成为纯组合 8 路译码器（零周期变化）。
- 2026-11-25（`rtl/rob-ptr-bpu`，方案 C 9-bit `rob_ptr` 冲刷）：彻底删除 `br_id` / `br_mask` / `clear_mask` 及 5 个分支标签子模块（`idu_br_alloc` / `idu_br_group` / `idu_br_state` / `idu_br_cp` / `idu_fire_ctl`），`idu_br_latch` / `idu_bcast` 透传 `{redirect_rob_flag, redirect_rob_idx}`；Yosys **19 层 / 6,595 cells**（原 66 层 / 31,607 cells），TSMC 28nm DC **14 级 / 0.37 ns（2.70 GHz）/ WNS 0.00 ns / 1,994.2 µm²**（较 `main` 18,195.6 µm² **−89.0%**）；`lint_chip` 0、`fm_gate` 69/69（0 周期差）、Linux 26/26 窗 PT/UP 100% 全等。
- 2026-11-21（`rtl/move-elim-1hop`，EXP-052）：`idu_decoder` 新增 `c_mv_canon`，将 `add rd, x0, rs2`（含全部展开后的 `c.mv`）规范化为 `addi rd, rs2, 0` 供 `ren` 移动消除识别；`eda-08` Yosys 深度 66 层（31,607 cells），`lint_chip` 0、`fm_gate` 68/68（0 周期偏差）。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`idu` 与 `idu_br_latch` 新增 4 位 `exu2id_ftq_offset` → `br_latch_ftq_offset` 寄存透传，供 `pre_idu_ftq_bpu` 按精确 `ftq_offset` 索引双块 FTQ 修复记录；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗对齐。
- `git log --oneline 261bd67..HEAD -- rtl/backend/idu`：本分支没有对本模块的提交；FLUSH_REG（`803692f`）只改了 `back_top` 的连线，使 `rob_bcast_flush` 到本模块晚一拍。更早：见 git 历史。
