---
module: idu
area: backend
rtl: rtl/backend/idu
model: trace-model back-end/Idu.cpp、back-end/include/Idu.h（调度单元 `back.idu`，类 `Idu`，阶段 `comb_decode`、`comb_fire`）
status: 整核周期与模型逐个相等（fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: **19 层 / 6,595 cells**（Yosys `strash;balance;map`，2026-11-25，较 2026-11-21 的 66 层 / 31,607 cells 降 −79.1%）；**TSMC 28nm HPC+ DC (`ssg0p81v125c`, `0.50ns`)：14 级 / 0.37 ns（2.70 GHz）/ WNS 0.00 ns / 1,994.2 µm²**；见第 6 节
---

# idu 设计文档

## 1. 职责

译码单元（IDU）：把指令缓冲（`ftq_ibuf` 的 `ibuf`）发来的最老 8 条指令译成 uop 字段，交给重命名。它是纯组合的 8 路译码器，没有时钟和状态：

1. 译码：每个 lane 把一个 32 位指令字译成类型、源 / 目的寄存器号、立即数、功能码、是否非法等（`dec2ren_uop`）；取指缺页的指令变成一条带缺页标志的 NOP（`diag_val` 里放指令字）；
2. FTQ 窗口限制：一组里第 i 条（i ≥ 1）的 `ftq_idx` 与第 0 条的差必须小于 8（`diff[FTQ_IDX_WIDTH-1:3] == 0`），否则从这条起截断——后面分派读 FTQ 用的是以 `ftq_idx[0]` 为起点的 8 bank 窗口（[ftq_ibuf.md](ftq_ibuf.md) 5.3）；
3. 握手：`idu_consume_fire[i] = lane_valid[i] & ren2dec_ready & !rob_bcast_flush & !dec_bcast_mispred`，指令缓冲据此弹出。

分支结果的寄存和广播不在 IDU：误预测由 `back_top` 的 `back_br_redirect` 寄存，只把 1 位 `dec_bcast_mispred` 送进来做握手门控。后端用 9 位 `rob_ptr` 循环年龄冲刷，IDU 不分配分支标签、不维护分支掩码。

模型对应：调度单元 `back.idu`（`Idu::comb_decode`、`Idu::comb_fire`）。

## 2. 配置（`ttg_cfg_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| lane 数 | 8 | `DECODE_WIDTH` |
| 指令字宽度 | 32（压缩指令在前端 `front_head_fix` 里已展开） | `ib_entry_t.inst` |
| FTQ 窗口 | 一组内 `ftq_idx` 差 < 8 | `idu.sv`（8 = `ftq_pc` 的 bank 数，代码里是位切片 `[FTQ_IDX_WIDTH-1:3]`） |
| 译码类别 | 40 类（含"非法"） | `idu_ctrl_decode` 的 `NCLS = 40` |
| 常量表 ROM 行宽 | 21 位 | `ROMW` |
| F/D | 总是开 | 无开关 |
| 已知 CSR | 24 个 | `NUM_KNOWN_CSR`；不在表里的 CSR 访问译成 NOP 并标为非法指令（`CLS_CSR_NOP`，`csr_illegal` 恒为 1） |

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `ibuf2idu_valid[8]`、`ibuf2idu_entry[8]`（`ftq_ibuf_pkg::ib_entry_t`：`inst`、`page_fault_inst`、`pf_inst_hi`、`ftq_idx`、`ftq_offset`、`ftq_is_last`） | 指令缓冲发来的最老 8 条 |
| 入 | `ren2dec_ready` | 重命名可以接收这一组 |
| 入 | `rob_bcast_flush` | 全局冲刷 |
| 入 | `dec_bcast_mispred` | 寄存后的误预测（`back_top` 的 `back_br_redirect`） |
| 出 | `dec2ren_valid[8]`、`dec2ren_uop[8]`（`ren_pkg::ren_inst_t`） | 译码结果 |
| 出 | `idu_consume_fire[8]` | 本拍消耗了哪些 lane |

没有 `clk` / `rst_n`。没有输出 `is_rvc` 和 `mdp`：分派前再向 FTQ 读（见 dispatch.md、[ftq_ibuf.md](ftq_ibuf.md)）。

## 4. 结构

```
 ibuf2idu[8] ─► FTQ 窗口截断（lane_valid）─► idu_decoder × 8（idu_ctrl_decode: 类别一热 + ROM；idu_imm_gen: 立即数）─► dec2ren[8]
                consume_fire[i] = lane_valid[i] & ren2dec_ready & !rob_bcast_flush & !dec_bcast_mispred
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `idu.sv` | 88 | 顶层：FTQ 窗口截断、8 路译码器、`consume_fire` |
| `idu_decoder.sv` | 112 | 一个 lane：包装控制字和立即数，取指缺页时变 NOP，`c.mv` 规范化 |
| `idu_ctrl_decode.sv` | 283 | 控制字：40 个互斥类别（一热）+ 常量表 ROM（`ROMW = 22` 位一行） |
| `idu_imm_gen.sv` | 35 | 各种格式的立即数一热选择 |

状态：无。

## 5. 一拍内的数据流

### 5.1 译码（只读指令缓冲的输出）

每个 lane：先看 `page_fault_inst`；有缺页则类型为 NOP，所有使能为 0，`diag_val = 指令字`，`page_fault_inst = 1`；否则按 `idu_ctrl_decode` 译码。几个规则（模型 `Idu::decode` 末尾）：

- 目的寄存器号是 x0（且不是浮点）则 `dest_en = 0`；f0 是真寄存器；
- 读改写 AMO（不是 LR 和 SC）且 rd = x0 时，目的寄存器号改成 32（整数 RAT 的第 33 项，见 ren.md），保持 `dest_en`；
- `func7` 取指令字 [31:25]，`csr_idx` 取 [31:20]；
- `src3` 只在 FP 融合乘加有，`src3_en` 同时表示"第三个源是浮点"；
- rv64：OP-IMM-32、OP-32 类的 `is_word = 1`；其中 `OP-32` 严格校验 RV64IM + Zba/Zbb 合法编码（`op32_alu_ok` 与 `MUL` 要求 `funct3 == 0`），非法编码落入 `CLS_ILLEGAL`（避免错误路径上被当作合法 ALU 改写目的寄存器）；
- `c.mv` 规范化（EXP-052）：`idu_decoder` 将 `add rd, x0, rs2`（含前端 `rvc_expand` 展开的全部 16-bit `c.mv rd, rs2`）规范化为语义等价的 `addi rd, rs2, 0`（`src1_areg = rs2, src2_en = 0, src2_is_imm = 1, imm = 0`），使后端 `ren` 的移动消除统一覆盖 RV64GC 压缩移动指令。

### 5.2 窗口截断与握手

`raw_ok[0] = 1`；`raw_ok[i] = !valid[i] | ((ftq_idx[i] - ftq_idx[0]) 的高 3 位为 0)`；`lane_valid[i] = valid[i] & raw_ok[0..i] 全为 1`。`dec2ren_valid = lane_valid`；`consume_fire` 见第 1 节。冲刷或误预测那一拍什么都不消耗。

## 6. 关键路径与深度

| 日期 | 口径 | 结果 |
| --- | --- | --- |
| 2026-11-25 | Yosys 门代理（`SYNTH_ABC="strash;balance;map"`），删除分支标签之后 | 19 层 / 6,595 单元 |
| 2026-11-25 | TSMC 28nm HPC+ DC（`ssg0p81v125c`，0.50 ns） | 14 级 / 0.37 ns（2.70 GHz）/ WNS 0.00 ns / 1,994.2 µm² |
| 2026-11-21 | Yosys 门代理，EXP-052 之后 | 66 层 / 31,607 单元 |
| 2026-11-18 | Yosys 门代理（`scripts/synth_depth.sh`） | 67 层（当时最长路径在分支标签状态里，已删除） |

从代码读出、未综合验证：最长链是指令字 → 操作码 / funct 比较 → 40 个类别一热 → ROM 一热选择 → `uop_*` 字段；FTQ 窗口截断是 8 个 6 位减法加前缀与，与译码并行。

## 7. 与模型的差异和取舍

- 模型里有、RTL 没有复刻的：`dbg`（pc、指令字、`inst_idx`）、`tma.*`、PMU、`uop_id`；
- 译码本身：模型用共享的软件译码器 `decode_inst`（`bridge/include/InstDecode.h`），RTL 是手写的类别一热 + ROM；两者一致靠 `fm_gate` 的逐条比较（含 Linux 启动）和 `tests/fp_decode`（只覆盖 F/D 类别）；
- 译码结果对无效 lane 没有意义（RTL 对无效 lane 也照常译码，下游只在 `valid` 时读）。

已发现、未改动：`idu.sv`、`idu_*` 文件头注释里的"reference model commit 2f31e8d"已过时。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77（每条提交对比函数模型，含译码结果），周期对 `scripts/ref_cycles.txt` 逐个相等。
- **F/D 译码单测**：`tests/fp_decode/run.sh <工作目录>`：FP=1 配置下单独 verilate `idu_ctrl_decode`，随机指令（浮点操作码各 4000 条）加 funct5 × fmt 遍历，与 `check.py` 的参考比较。不在整核门禁里，需要手工运行；只覆盖浮点指令。
- **Lint**：`scripts/lint_chip.sh` 0 告警。

## 9. 参数与开关速查

无开关。常量：`DECODE_WIDTH`、`FTQ_IDX_WIDTH`、`FPRF_NUM`（F/D 类别）、`XLEN_BITS`（rv64 的 *W 类）、`CSR_IDX_WIDTH`（`ttg_cfg_pkg`）。

## 10. 变更记录

- 2026-11-28 清理：删 ROM 的 `is_branch` 列（`ROMW` 22 → 21）、`idu_ctrl_decode` / `idu_decoder` 的 `is_branch` 输出和 `idu_decoder` 的 `entry_valid` 输入、`idu.sv` 的 `lane_is_branch`；F/D 写死（删 `HAS_FP`，`NUM_KNOWN_CSR = 24`）；`idu_decoder` 头注释去掉 `br_id / br_mask`（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`）：文档按现行 RTL 重写（第 1–9 节；旧正文描述的是 EXP-070 之前 / 删除分支标签之前的结构）。
- 2026-11-25（`idu_br_latch` 迁出至 `back_top`）：将 `idu_br_latch.sv` 移至 `rtl/backend/back_top/` 并删除透传模块 `idu_bcast.sv`，`idu.sv` 去掉 `clk`/`rst_n` 与全部 `exu2id_*`/`dec_bcast_*`/`br_latch_*` 端口（仅保留 1-bit 输入 `dec_bcast_mispred`），成为纯组合 8 路译码器（零周期变化）。
- 2026-11-25（`rtl/rob-ptr-bpu`，方案 C 9-bit `rob_ptr` 冲刷）：彻底删除 `br_id` / `br_mask` / `clear_mask` 及 5 个分支标签子模块（`idu_br_alloc` / `idu_br_group` / `idu_br_state` / `idu_br_cp` / `idu_fire_ctl`），`idu_br_latch` / `idu_bcast` 透传 `{redirect_rob_flag, redirect_rob_idx}`；Yosys **19 层 / 6,595 cells**（原 66 层 / 31,607 cells），TSMC 28nm DC **14 级 / 0.37 ns（2.70 GHz）/ WNS 0.00 ns / 1,994.2 µm²**（较 `main` 18,195.6 µm² **−89.0%**）；`lint_chip` 0、`fm_gate` 69/69（0 周期差）、Linux 26/26 窗 PT/UP 100% 全等。
- 2026-11-21（`rtl/move-elim-1hop`，EXP-052）：`idu_decoder` 新增 `c_mv_canon`，将 `add rd, x0, rs2`（含全部展开后的 `c.mv`）规范化为 `addi rd, rs2, 0` 供 `ren` 移动消除识别；`eda-08` Yosys 深度 66 层（31,607 cells），`lint_chip` 0、`fm_gate` 68/68（0 周期偏差）。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`idu` 与 `idu_br_latch` 新增 4 位 `exu2id_ftq_offset` → `br_latch_ftq_offset` 寄存透传，供 `pre_idu_ftq_bpu` 按精确 `ftq_offset` 索引双块 FTQ 修复记录；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗对齐。
- `git log --oneline 261bd67..HEAD -- rtl/backend/idu`：本分支没有对本模块的提交；FLUSH_REG（`803692f`）只改了 `back_top` 的连线，使 `rob_bcast_flush` 到本模块晚一拍。更早：见 git 历史。
