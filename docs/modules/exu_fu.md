---
module: exu_fu
area: backend
rtl: rtl/backend/exu_fu
model: trace-model back-end/Exu/include/Fu.h（`FuUnit`、`FuMode`、`fu_pipe_latency`、`fu::iter_latency`、`fu::compute`）和 back-end/Exu/Exu.cpp（`Exu::exec` 里按模式处理 FU 的部分）；没有独立的调度单元，属于 `back.exu`
status: 整核周期与模型逐个相等（fm_gate 77/77，参考 scripts/ref_cycles.txt；沿用 isu.md 记录的验收结果，本文作者没有重跑）
depth: 98 层（exu（含 exu_ctrl、优化后乘除法与全部自研可综合 RV64FD FPU），单模块综合，2026-11-23，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# exu_fu 设计文档

> **2026-11-28 `rtl/iss-rr`（Wall #2 + Wall #3）**：
> - **Wall #3**：将 `fp_fma_core` 原 Stage 1（`53×53` 乘 + `163b` 对齐 + `163b` 比较/加减/判零）拆为 **S1a（乘法 + C 对齐 → `s1b_*_q`）** 与 **S1b（加减 + 符号 + exact_zero → `s2_*_q`）**，总延迟从 3 拍增至 **4 拍**（`FP_FMA_LAT = 4`，由 `trace-model` `CFG_FP_FMA_LAT = 5` 同步至 `ttg_cfg_pkg.sv`）；
> - **Wall #2**：`exu_iter_ctl` 将 `wb_next = live && (cnt_q == 1)` 对齐到 `live`，并新增提前 2 拍组合信号 `wb_in2 = (accept && (lat_m1 == 1)) || (live && (cnt_q == 2))`（经 `div_unit` / `div_bank` 输出 `div_wb_in2`，兼容 early-out `L=2`）。

旧文档名 `exu_int`，现与目录名一致改为 `exu_fu`；旧内容描述的是 rv32 时期的 spec / trace 回放体系，没有沿用。

## 1. 职责

功能单元：真正做运算的部分，以及多周期单元自己的在飞状态。分三类（和模型 `FuMode` 一致）：

- **单周期**（SINGLE）：ALU、BRU、AGU、SDU，输入槽里的指令这一拍就出结果，没有状态；CSR 单元没有硬件（见下）；
- **流水线**（PIPE）：定延迟、每拍可收一条：MUL（延迟 `MUL_MAX_LATENCY = 3`），浮点的 FMA（`FP_FMA_LAT = 4`）、FMISC（`FP_MISC_LAT = 2`）、I2F（`FP_I2F_LAT = 2`）；
- **迭代**（ITER）：一次只做一条、延迟按操作而变：DIV（**1 个 Radix-16 双 Radix-4 + Early-out 变延迟除法器**，`DIV_MAX_LATENCY = 17`，实际延迟 `2..17` 拍，完成前 2 拍经 `wb_in2` 通知 ISU 预留写回口，完成前 1 拍在 EXU 侧唤醒消费者）、浮点的 FDIV（除法 / 开方，单精度 `FP_FDIV_S_LAT = 11`、`FP_FSQRT_S_LAT = 13`，双精度 `FP_FDIV_D_LAT = 19`、`FP_FSQRT_D_LAT = 23`）。

槽、口内仲裁、写回、flush / 分支号清除的分发都在 `exu_ctrl`；本模块只在一处自己处理 flush：MUL / DIV / 浮点这些会把指令留在单元里若干拍的 FU，要自己杀掉被全局 flush 或误预测杀死（比被预测错的分支更年轻）的在飞指令。

CSR 单元（模型 `FuKind::CSR`）没有运算也没有 FU 侧状态：CSR 指令在槽里被 `exu_ctrl` 当作单周期 FU 处理，读数据由 CSR 文件给（原来有一个只有握手的 `csr_fu.sv`，没有被任何地方实例化，2026-11-18 已删除）。

模型里 FU 没有运算：地址、存储数据、分支结果取自 trace 的事实，只建模"何时能收、何时完成、flush 对在飞指令做什么"。RTL 真算，由逐条提交的函数模型检查（`scripts/fm_gate.sh`）对账。

## 2. 配置（`ttg_cfg_pkg` / `exu_fu_pkg` / `exu_ctrl_pkg`，现行默认）

`back_top/exu.sv` 实例化的 FU 共 27 个（加上没有硬件的 CSR 单元，对应 `exu_ctrl` 的 28 个 FU 实例）：

| FU | 实例数（常量） | bank 模块 → 叶子 | 模式和延迟 | 所在口 |
| --- | --- | --- | --- | --- |
| ALU | 6（`ALU_NUM`） | `alu_bank` → `alu` | 单周期 | 0..5 |
| BRU | 2（`BRU_NUM`） | `bru_bank` → `bru` | 单周期 | 14、15 |
| AGU | 5（`LSU_AGU_COUNT`；2 仅 load、2 共享、1 仅 STA） | `agu_bank` → `agu` | 单周期 | 6..10 |
| SDU | 3（`LSU_SDU_COUNT`） | `sdu_bank` → `sdu` | 单周期 | 11..13 |
| MUL | 2（`exu_fu_pkg::MUL_NUM`） | `mul_bank` → `mul_unit`（`mul_core` + `mul_pipe`） | 流水线，3 拍 | 0、2 |
| DIV | 1（`exu_fu_pkg::DIV_NUM`） | `div_bank` → `div_unit`（`exu_iter_ctl` + `div_core`） | 迭代，变延迟 2..17 拍（Radix-16 Early-out） | 1 |
| FMA、FMISC、I2F | 2、3、2 | `fp_pipe_unit`（`mul_pipe` + `fp_core`） | 流水线，3、2、2 拍 | 16、17；16、17、18；2、3 |
| FDIV | 1 | `fp_div_unit`（`exu_iter_ctl` + `fp_core`） | 迭代，按操作 11 / 13 / 19 / 23 拍 | 18 |

5 个 AGU 即 5 个物理 AGU（统一覆盖 load 6..7、共享 8..9、STA 10）；`MUL_NUM = 2`、`DIV_NUM = 1` 是 `exu_fu_pkg` 常量，`exu_ctrl_pkg::N_MC = 3`、`N_FPU = 8`；`ttg_cfg_pkg.sv` 由 `make cfg` 同步生成。

其他：`XLEN_BITS = 64`；浮点寄存器宽度 `FLEN = 64`（`fp_pkg`，`FW`）；MUL 内部 `W = XLEN`，操作数带符号位共 `AW = XLEN + 1` 位，乘积 `2 * XLEN` 位。

## 3. 接口

每个 bank 的端口是"每个实例一份"的平铺数组（`result [N]` 等）；所有 FU 均已删除 `ready` 和 `consume` 握手，单周期 FU 同时删除 `en`、`complete` 与 `clk`/`rst_n`。信号含义：

| FU | 入 | 出 |
| --- | --- | --- |
| ALU | `op`、`func3`、`func7`、`src1_is_pc`、`src2_is_imm`、`is_word`、`pc`、`imm`、`src1_rdata`、`src2_rdata` | `result` |
| BRU | `op`、`func3`、`src1_en`、`src1_rdata`、`src2_rdata`、`pc`、`imm`、`ftq_pred_taken`、`ftq_is_rvc`、`ftq_next_pc` | `br_taken`、`mispred`、`diag_val`（跳转目标或下一条顺序 pc） |
| AGU | `src1_rdata`、`imm` | `result` = `src1 + 符号扩展的 imm`，`XLEN` 位 |
| SDU | `is_atomic`、`amo_op`（`func7[6:2]`）、`amo_w`、`src1_rdata`、`src2_rdata` | `result`：普通 store 取 `src2`，AMO 按 `amo_op` 把 `src1`（旧值）和 `src2` 合并 |
| MUL、DIV | `en`、`flush_all`、`flush_br`、`flush_rob_idx/flag`、`func3[1:0]`、`is_word`、`src1_rdata`、`src2_rdata`、`rob_idx`、`dest_preg`、`dest_en` | `complete`、`result`、`done_rob_idx`、`done_dest_preg`、`done_dest_en`、`done_rob_flag`（DIV 另输出 `div_wb_next`） |
| 浮点 | 同上再加 `func7`（FDIV）、`imm`、`src1_rdata`（整数源）、`fsrc1..3`、`frm` | 同上，`result` 换成 64 位 `fresult`，再加 `fflags`、`illegal` |

握手约定（`exu_ctrl` 与 FU 的合同）：ISU 已在发射前预约好功能单元互斥与写回周期，因此 FU 绝不会被反压；单周期 FU 的 `complete` 即 `exu_ctrl_slot` 的 `fu_en`；多周期 FU 只需按时输出 `complete` 并由 `mul_unit`/`exu_iter_ctl` 仿真断言无重入/无冲突即可。

## 4. 结构

```
 exu_ctrl ─ exu2fu_* ─► alu_bank / bru_bank / agu_bank / sdu_bank          （纯组合，无握手，各 N 个叶子）
                    ─► mul_bank → mul_unit = mul_core（乘法，3 拍展开）+ mul_pipe（STAGES=DEPTH-1 移位链）
                    ─► div_bank → div_unit = exu_iter_ctl（无反压忙/倒计时）+ div_core（恢复除法）+ 载荷寄存
                    ─► fp_pipe_unit = fp_core（运算）+ mul_pipe（FP 载荷）     fp_div_unit = fp_core + exu_iter_ctl + 载荷寄存
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `exu_fu_pkg.sv` | — | uop 类型常量、AMO 编码、`MUL_NUM`、`DIV_NUM`、`alu_ctl_t`、`fu_uop_t` / `fp_uop_t` |
| `alu.sv`、`alu_bank.sv` | — | 整数 ALU（RV64I、*W、Zba / Zbb / Zbs / Zbc 子集） |
| `alu_decode.sv` | — | 把 `op / func3 / func7 / imm[4:0]` 译成 `alu_ctl_t` 的互斥选择位 |
| `alu_shift.sv`、`alu_clmul.sv`、`alu_bitcnt.sv` | — | 漏斗移位器、无进位乘法、clz / ctz / cpop / sext / rev8 / orc.b |
| `bru.sv`、`bru_bank.sv` | — | 分支：条件、目标、误预测判定 |
| `agu.sv`、`agu_bank.sv` | — | 地址加法（5 个实例） |
| `sdu.sv`、`sdu_bank.sv` | — | 存储数据 / AMO |
| `mul_unit.sv`、`mul_bank.sv` | — | 乘法 FU：乘法器 + 移位寄存器 |
| `mul_core.sv` | — | 乘法器，跨 3 拍 |
| `mul_pipe.sv` | — | 固定延迟无反压的 `STAGES = DEPTH - 1` 拍移位寄存器（MUL 和浮点流水 FU 共用） |
| `div_unit.sv`、`div_bank.sv`、`div_core.sv`、`div_step.sv` | — | 除法 FU、恢复除法 |
| `exu_iter_ctl.sv` | — | 无反压迭代 FU 的控制骨架（DIV 和 FDIV 共用，仿真断言 `!(en && live)`） |
| `fp_pipe_unit.sv`、`fp_div_unit.sv`、`fp_core.sv` | — | 浮点 FU 封装与双路径选择：默认仿真走 `fp_core`（DPI SoftFloat），`SYNTHESIS` 或 `-DFPU_REAL` 走自研可综合核心 |
| `fp_arith_pkg.sv`、`fp_misc_core.sv`、`fp_i2f_core.sv`、`fp_fcvt_core.sv`、`fp_fma_core.sv`、`fp_div_core.sv` | — | 自研可综合 RV64FD 算术核心 |

几个非平凡的块：

- **`alu`**：同前，移除了 `en`/`consume`/`complete`/`ready`。
- **`mul_core`**：同前，共 3 拍；`mul_pipe`（`STAGES = DEPTH - 1`）精确在完成拍报 `complete`。
- **`mul_pipe`**：`STAGES = DEPTH - 1` 级无停顿移位链，`s = 0` 在 `en` 有效时压入，每拍向 `STAGES - 1` 移动并在沿上应用 Flush/误预测杀死，`complete` 取末级输出（当 `DEPTH=2` 时仅 1 级；`DEPTH >= 2`）。
- **`exu_iter_ctl` + `div_core`**：收到 `en` 即装载 `busy_q=1`、`cnt_q = lat_m1`，每拍递减，`cnt_q == 0` 报 `complete` 且下拍自然释放（无需 `consume`），`wb_next = live && (cnt_q == 1)`（`exu.sv` 只接线、不使用）；`wb_in2 = (accept && lat_m1 == 1) || (live && cnt_q == 2)`，即提前 2 拍的写回预告，口 1 的经 `exe2iss_div_wb_in2` 送 ISU（适配 ISS → RR → EX 两拍）。仿真下 `$error` 检查 `!(en && live)` 保证不重入。

## 5. 一拍内的数据流

### 5.1 单周期 FU

输入来自 `exu_ctrl` 的口寄存器，纯组合出结果。BRU / AGU / ALU / SDU 均无内部寄存器状态。

### 5.2 MUL（每拍一条进、一条出）

t：操作数进 `mul_core`、载荷进 `mul_pipe[0]`；t+2（或 `t + DEPTH - 1`）：末级有效即 `complete = 1`。

### 5.3 DIV 和 FDIV

接收（`en` 且不忙）那拍载荷与操作数入寄存器，之后每拍 `cnt_q` 减 1；提前 2 拍口 1 DIV 输出 `div_wb_in2 = 1`（ISU 那一拍不在口 1 发射）；`cnt_q == 0` 时报 `complete = 1` 并自动清空 `busy_q`，下拍起接收后续请求（ISU 由本地 `div_busy_q` / `fdiv_cnt_q` 与 `exe2iss_div_wb_in2` 保证无重入和写回不冲突）。

### 5.4 杀死和清分支位

flush 由 `exu_ctrl` 送来：`exu2fu_flush_all = rob_bcast_flush`；`exu2fu_flush_br` 加 `exu2fu_flush_rob_idx / _rob_flag` 表示误预测，在飞指令比这个 ROB 号更年轻（`fu_rob_younger`，9 位 `{rob_flag, rob_idx}` 循环年龄比较）即杀。没有分支掩码。

## 6. 关键路径与深度

单模块综合深度 **73 层**（exu（含 exu_ctrl 和全部功能单元）；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_ctrl.u_slot.g_slot[1].slot_q [107]` 到 `\exe2prf_entry_uop_result [1343]`。已知的一个数字：提交 `48d547e` 的说明记录 `mul_unit` 单模块综合从 209 层降到 90 层（那次提交时测的，本文没有复测）。其余 FU 没有单独测过。以下是从代码读出的，未综合验证：

| 路径 | 内容 |
| --- | --- |
| ALU 最长路径 | 槽 → 操作数选择（`src1_is_pc`、`src2_is_imm`）→ 加减法器或移位 / clmul / bitcnt → 9 路独热选择 → *W 符号扩展 → `result`；之后它还要经 `exu_ctrl` 口内仲裁和 PRF 旁路比较才回到下一拍的槽 |
| BRU | 比较（64 位）→ 条件 → `br_taken` → `mispred`（要和 `ftq_next_pc == 目标` 的 64 位比较），再进 `exu_ctrl_br_arb` |
| DIV 接收拍 | 取绝对值 → 2 步恢复除法（两级 64 位减法比较）→ 寄存 |
| `mul_core` t+2 拍 | 128 位 Kogge-Stone 加法（`LV = clog2(2 * XLEN) = 7` 级前缀）→ 选半 → `result` |

本分支和深度有关的改动：

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| 乘法器摊在 3 拍延迟上 | `48d547e` | 操作数寄存、乘积存成和 + 进位、再做进位传播加法；综合用 Wallace 树 + Kogge-Stone；`mul_unit` 209 → 90 层；周期不变 |
| 乘法器 Radix-4 Booth + 1× Radix-16 Early-out 变延迟除法 + 自研可综合 RV64FD FPU | `EXP-061` | `mul_unit` 40,041→27,473 cells (−31.4%)/30 层；`div_unit` 缩为 1 个 Radix-16 双 Radix-4 + Early-out（2..17 拍，EXU 动态唤醒），`div_unit` 12,340 cells / 50 层，`isu` 1,079,759→1,071,347 (−8,412) / 60 层；新增全套自研可综合 RV64FD FPU（`fp_misc_core` 1,874/39 层、`fp_i2f_core` 1,790/73 层、`fp_fcvt_core` 4,646/83 层、`fp_fma_core` 33,776/98 层、`fp_div_core` 10,885/73 层）；整块 `exu` 304,977 cells / 98 层 |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- **模型的 `fu::compute`**：AGU 地址、SDU 数据、分支结果取自 trace 事实；RTL 真算。BRU 的误预测判据两边等价（`Fu.h` 的 `resolve_branch`）；
- **`fp_trap`**：模型里 FP / CSR(fflags / frm / fcsr) uop 若 trace 事实显示"以非法指令陷入"，就把 `illegal_inst` 置位；RTL 由 `fp_core` 的 `illegal` 输出经 `exu2rob_entry_uop_illegal` 报给 ROB（FP 口的完成报告带这一位），`mstatus.FS == Off` 另有 `csr2rob_fs_off` 去 ROB；本文没有逐条比对两者的判据与模型的 `fp_trap`；
- **`Assert`、调试打印、`tbhook`**：RTL 不带，仿真断言只有 `mul_pipe` 的深度、`mul_unit` 的"完成未取走"和 `exu.sv` 里 ALU / BRU 的 `complete == en`。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- MUL / 浮点流水 FU 的接收先判满再弹出；DIV / FDIV 的接收先判忙再取走（与模型 `Exu::exec` 里 PIPE 先推后弹、ITER 先看 `busy` 一致），所以取走那拍同一个 FU 不接新指令（ITER）；
- 新项的完成周期 = 接收周期 + 延迟 - 1（模型 `done_cycle = now + depth - 1`）；
- DIV 的 *W 版延迟减半对应模型 `div_latency(word)`；ISU 里 `Isu::get_latency` 也用同一个函数。

配置相关的有意取舍：

- **`fp_core` 综合时是占位**：仿真时通过 DPI 调 Berkeley softfloat（`tb/fp_dpi/fp_dpi.cpp`），与函数模型逐位一致（`tests/fp_dpi`）；综合时（`SYNTHESIS`）结果恒为 0、`fflags` 恒为 0、`illegal` 恒为 0，等可综合的浮点数据通路（代码里称 S7，未做）。所以任何含浮点 FU 的综合深度和面积都不含真正的浮点运算；
- **AGU 5 个物理实例各服务对应端口**（共享口 4 在 `isu_iq_select` 选口并由 `exu_ctrl_lsu_req` 复用 `agu_bank[4]`）；
- `exu_fu_pkg.sv` 的注释里引用的 `config.h:371-398` 行号和 `alu_decode.sv` 头注释里的 `docs/modules/exu_int.md` 都是过时引用；`alu_decode.sv` 说"ALU 口见不到 UOP_JUMP，所以模型里 JUMP 时 `operand2 = 4` 的分支不翻译"，该模型分支现在已不存在（Fu.h 里没有运算）。

未核对（继承自旧文档）：

- 旧文档关于 `rol` / `ror` 移位量为 0 时 C++ 未定义行为的疑点（D-EXU-1）：当前模型没有 ALU 运算，该疑点已无对象；RTL 实现是正确旋转；
- 旧文档的变异检查表（47 个变异）和覆盖统计：随 `spec/`、`tests/exu_fu` 退役，没有重跑。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`lint_chip` & `lint_soc` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 全通；Linux 26/26 窗对齐。
- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`。名字对得上 FU 的程序：`bitmanip-boundary`、`bit`、`shift`（ALU 位操作）、`mul-longlong`、`div`、`atomic-boundary`（SDU 的 AMO）、`csr-alias-boundary`、`fd-basic`、`fd-fcvt`、`fd-fdiv`、`fd-fsqrt`、`fd-matmul`（浮点 FU）；没有逐个核对每个程序实际覆盖了哪些操作。
- **乘法器**：`scripts/mul_check.sh`（`tb/mul/mul_check_top.sv`、`tb/mul/mul_check.cpp`）：随机和角点操作数，对比 `STRUCT = 1`（Wallace 树）、`STRUCT = 0`（`a * b`）和 C++ 参考，逐拍比较（t 拍操作数对应 t+2 拍结果）；提交 `48d547e` 记录 400 万个乘积相等。
- **浮点**：`tests/fp_dpi`（DPI 运算对函数模型的差分测试）、`tests/fp_chain`（`rv64imafd` 小程序在 RTL 上逐提交检查）。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有除 MUL 之外的模块级测试**：ALU、BRU、AGU、SDU、DIV 目前只靠整核对账；旧的随机 trace + 变异体系已退役。**待补**：ALU（含 Zb* 的各编码）、DIV（除数为 0、`INT_MIN / -1`、*W）、BRU（各 `func3`、JALR 清最低位）各补一个和 C++ 运算参考并排的随机测试，像 `mul_check` 那样。

## 9. 参数与开关速查

`ALU_NUM`、`BRU_NUM`、`LSU_AGU_COUNT`、`LSU_SDU_COUNT`、`MUL_MAX_LATENCY`、`DIV_MAX_LATENCY`、`FP_FMA_LAT`、`FP_MISC_LAT`、`FP_I2F_LAT`、`FP_FDIV_S_LAT`、`FP_FSQRT_S_LAT`、`FP_FDIV_D_LAT`、`FP_FSQRT_D_LAT`、`FPRF_NUM`（`ttg_cfg_pkg`）；`MUL_NUM`、`DIV_NUM`（`exu_fu_pkg`）；`mul_core` 的 `STRUCT`（由 `SYNTHESIS` 决定，`mul_pipe` 的 `DEPTH`、`UOP_T`、`div_core` 的 `LAT` 是实例化参数）；`SYNTHESIS`（`fp_core` 和 `mul_core` 的两套实现）。

## 10. 变更记录

- 2026-11-28（文档核对，无 RTL 变化）：flush 按 ROB 号（`exu2fu_flush_br` + `flush_rob_idx/flag`），无分支掩码；DIV 的 `wb_in2` 提前 2 拍预告；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/exu-clean`，EXP-072）：非阻塞 EXU 与真 5 物理 AGU 重构——删除 `exu_fu_sc_ctl.sv` 及全部单周期/流水线 FU 单元与 bank 上的 `ready_o`/`consume_i`/`busy_o` 握手端口；`mul_pipe` 精简为无条件固定 3 拍推进；`exu_iter_ctl` 删除 `busy_o` 保留 `div_wb_next`；`agu_bank` 按真 5 物理口（`LSU_AGU_COUNT=5`）直连。TSMC 28nm HPC+ `exu` 实测：`WNS = −0.41 ns`（与基线相同，仍为 `u_fma` 路径），**`TNS −1,230.70 → −1,008.16`（−18.1%）**、**`Seq 8,704 → 6,755`（−1,949 FF / −22.4%）**、**总面积 `217,730.69 → 207,202.80 µm²`（−4.84%）**。

- 2026-11-18（exp/agu-share，`261bd67..HEAD`）：`48d547e` 乘法器摊在 3 拍延迟上（见第 6 节表），新增 `scripts/mul_check.sh`、`tb/mul`。
- 2026-11-12：rv64（`is_word`、*W 运算、`div_core` 每拍 2 步、`MUL_MAX_LATENCY = 3`、`DIV_MAX_LATENCY = 32`）；F/D（浮点 FU）。
- 更早：见 git 历史。
- 2026-11-18：删除没有被任何文件实例化的 `csr_fu.sv`（21 行，只有握手；CSR 指令的握手在 `exu_ctrl` 里做）。
