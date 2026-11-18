---
module: exu_fu
area: backend
rtl: rtl/backend/exu_fu
model: trace-model back-end/Exu/include/Fu.h（`FuUnit`、`FuMode`、`fu_pipe_latency`、`fu::iter_latency`、`fu::compute`）和 back-end/Exu/Exu.cpp（`Exu::exec` 里按模式处理 FU 的部分）；没有独立的调度单元，属于 `back.exu`
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；沿用 isu.md 记录的验收结果，本文作者没有重跑）
depth: 73 层（exu（含 exu_ctrl 和全部功能单元），单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# exu_fu 设计文档

旧文档名 `exu_int`，现与目录名一致改为 `exu_fu`；旧内容描述的是 rv32 时期的 spec / trace 回放体系，没有沿用。

## 1. 职责

功能单元：真正做运算的部分，以及多周期单元自己的在飞状态。分三类（和模型 `FuMode` 一致）：

- **单周期**（SINGLE）：ALU、BRU、AGU、SDU，输入槽里的指令这一拍就出结果，没有状态；CSR 单元没有硬件（见下）；
- **流水线**（PIPE）：定延迟、每拍可收一条：MUL（延迟 `MUL_MAX_LATENCY = 3`），浮点的 FMA（`FP_FMA_LAT = 3`）、FMISC（`FP_MISC_LAT = 2`）、I2F（`FP_I2F_LAT = 2`）；
- **迭代**（ITER）：一次只做一条、延迟按操作而变：DIV（`DIV_MAX_LATENCY = 32`，*W 除法减半为 16）、浮点的 FDIV（除法 / 开方，单精度 `FP_FDIV_S_LAT = 11`、`FP_FSQRT_S_LAT = 13`，双精度 `FP_FDIV_D_LAT = 19`、`FP_FSQRT_D_LAT = 23`）。

槽、口内仲裁、写回、flush / 分支号清除的分发都在 `exu_ctrl`；本模块只在两个地方自己处理 flush 和分支掩码：MUL / DIV / 浮点这些会把指令留在单元里若干拍的 FU，要自己杀掉被 flush 或被误预测杀死的指令，并清掉在飞指令 `br_mask` 里已解析的位。

CSR 单元（模型 `FuKind::CSR`）没有运算也没有 FU 侧状态：CSR 指令在槽里被 `exu_ctrl` 当作单周期 FU 处理，读数据由 CSR 文件给，`exu_fu/csr_fu.sv` 目前没有被任何地方实例化（见第 7 节）。

模型里 FU 没有运算：地址、存储数据、分支结果取自 trace 的事实，只建模"何时能收、何时完成、flush 对在飞指令做什么"。RTL 真算，由逐条提交的函数模型检查（`scripts/fm_gate.sh`）对账。

## 2. 配置（`ttg_cfg_pkg` / `exu_fu_pkg` / `exu_ctrl_pkg`，现行默认）

`back_top/exu.sv` 实例化的 FU 共 30 个（加上没有硬件的 CSR 单元，对应 `exu_ctrl` 的 31 个 FU 实例）：

| FU | 实例数（常量） | bank 模块 → 叶子 | 模式和延迟 | 所在口 |
| --- | --- | --- | --- | --- |
| ALU | 6（`ALU_NUM`） | `alu_bank` → `alu` | 单周期 | 0..5 |
| BRU | 2（`BRU_NUM`） | `bru_bank` → `bru` | 单周期 | 16、17 |
| AGU | 7（`LSU_AGU_COUNT`；4 个 load 口的、3 个 STA 口的） | `agu_bank` → `agu` | 单周期 | 6..9、10..12 |
| SDU | 3（`LSU_SDU_COUNT`） | `sdu_bank` → `sdu` | 单周期 | 13..15 |
| MUL | 2（`exu_fu_pkg::MUL_NUM`） | `mul_bank` → `mul_unit`（`mul_core` + `mul_pipe`） | 流水线，3 拍 | 0、2 |
| DIV | 2（`exu_fu_pkg::DIV_NUM`） | `div_bank` → `div_unit`（`exu_iter_ctl` + `div_core`） | 迭代，32 拍（*W 16 拍） | 1、3 |
| FMA、FMISC、I2F | 2、3、2 | `fp_pipe_unit`（`mul_pipe` + `fp_core`） | 流水线，3、2、2 拍 | 18、19；18、19、20；2、3 |
| FDIV | 1 | `fp_div_unit`（`exu_iter_ctl` + `fp_core`） | 迭代，按操作 11 / 13 / 19 / 23 拍 | 20 |

AGU 的 7 个实例是 7 个独立的加法器：共用 AGU 的两对口（load 口 8、9 与 STA 口 11、12）在本模块里没有合并，共用只体现在 ISU（同拍只发一条）、PRF（STA 口借用 load 口的 src1 读口）、DTLB（按物理 AGU `LSU_AGU_PHYS = 5` 配口）。`MUL_NUM`、`DIV_NUM` 是 `exu_fu_pkg` 里手写的常量（`ttg_cfg_pkg` 不导出），`exu_ctrl_pkg::N_MC = 4`、`N_FPU = 8` 也是手写的；`exu_ctrl.sv` 的 `g_cfg_check` 检查个数是否对得上。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

其他：`XLEN_BITS = 64`；浮点寄存器宽度 `FLEN = 64`（`fp_pkg`，`FW`）；MUL 内部 `W = XLEN`，操作数带符号位共 `AW = XLEN + 1` 位，乘积 `2 * XLEN` 位。

## 3. 接口

每个 bank 的端口是"每个实例一份"的平铺数组（`en [N]`、`result [N]` 等）。信号含义：

| FU | 入（除 `en`、`consume`） | 出 |
| --- | --- | --- |
| ALU | `op`、`func3`、`func7`、`src1_is_pc`、`src2_is_imm`、`is_word`、`pc`、`imm`、`src1_rdata`、`src2_rdata` | `result`（`complete`、`ready` 见下） |
| BRU | `op`、`func3`、`src1_en`、`src1_rdata`、`src2_rdata`、`pc`、`imm`、`ftq_pred_taken`、`ftq_is_rvc`、`ftq_next_pc` | `br_taken`、`mispred`、`diag_val`（跳转目标或下一条顺序 pc） |
| AGU | `src1_rdata`、`imm` | `result` = `src1 + 符号扩展的 imm`，`XLEN` 位 |
| SDU | `is_atomic`、`amo_op`（`func7[6:2]`）、`amo_w`、`src1_rdata`、`src2_rdata` | `result`：普通 store 取 `src2`，AMO 按 `amo_op` 把 `src1`（旧值）和 `src2` 合并 |
| MUL、DIV | `flush`、`flush_mask`、`clear_mask`、`func3[1:0]`、`is_word`、`src1_rdata`、`src2_rdata`、`rob_idx`、`dest_preg`、`dest_en`、`br_mask` | `complete`、`ready`、`result`、`done_rob_idx`、`done_dest_preg`、`done_dest_en`、`done_br_mask` |
| 浮点 | 同上再加 `func7`（FDIV）、`imm`、`src1_rdata`（整数源）、`fsrc1..3`、`frm` | 同上，`result` 换成 64 位 `fresult`，再加 `fflags`、`illegal` |

握手约定（`exu_ctrl` 与 FU 的合同）：单周期 FU 的 `complete = en`、`ready = !en || consume`（`exu_fu_sc_ctl`，对应模型单周期 FU 的行为）；但 `exu_ctrl` 自己按这个规则推 `complete` / `ready`，不读 FU 的这两个输出，`exu.sv` 把 `consume` 接 0、`complete` / `ready` 悬空到具名线（所以 `exu_fu_sc_ctl` 在整核里是死逻辑，只被时钟采样断言用：ALU 和 BRU 的 `complete == en`）。多周期 FU 的 `complete`、`ready` 是真输入。`op`、`pc` 等不由 FU 回传，`exu_ctrl` 从槽里取；MUL / DIV / 浮点因为指令在 FU 里停留若干拍，要自己带回 `rob_idx`、`dest_preg`、`dest_en`、`br_mask`。

## 4. 结构

```
 exu_ctrl ─ exu2fu_* ─► alu_bank / bru_bank / agu_bank / sdu_bank          （纯组合，各 N 个叶子）
                    ─► mul_bank → mul_unit = mul_core（乘法，3 拍展开）+ mul_pipe（在飞指令队列）
                    ─► div_bank → div_unit = exu_iter_ctl（忙 / 倒计时 / 杀死）+ div_core（恢复除法）+ 载荷寄存
                    ─► fp_pipe_unit = fp_core（运算）+ mul_pipe（FP 载荷）     fp_div_unit = fp_core + exu_iter_ctl + 载荷寄存
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `exu_fu_pkg.sv` | 95 | uop 类型常量、AMO 编码、`MUL_NUM`、`DIV_NUM`、`alu_ctl_t`（ALU 译码结果）、`fu_uop_t` / `fp_uop_t`（多周期 FU 在飞指令的载荷） |
| `exu_fu_sc_ctl.sv` | 20 | 单周期握手（见第 3 节，整核里不读） |
| `alu.sv`、`alu_bank.sv` | 150、43 | 整数 ALU（RV64I、*W、Zba / Zbb / Zbs / Zbc 子集） |
| `alu_decode.sv` | 140 | 把 `op / func3 / func7 / imm[4:0]` 译成 `alu_ctl_t` 的互斥选择位 |
| `alu_shift.sv`、`alu_clmul.sv`、`alu_bitcnt.sv` | 29、19、58 | 漏斗移位器、无进位乘法、clz / ctz / cpop / sext / rev8 / orc.b |
| `bru.sv`、`bru_bank.sv` | 68、45 | 分支：条件、目标、误预测判定 |
| `agu.sv`、`agu_bank.sv` | 22、33 | 地址加法 |
| `sdu.sv`、`sdu_bank.sv` | 52、37 | 存储数据 / AMO |
| `csr_fu.sv` | 21 | 只有握手，**没有被实例化**（见第 7 节） |
| `mul_unit.sv`、`mul_bank.sv` | 66、48 | 乘法 FU：乘法器 + 在飞队列 |
| `mul_core.sv` | 145 | 乘法器，跨 3 拍：仿真用 `a * b`，综合用 Wallace 树 + Kogge-Stone 加法器 |
| `mul_pipe.sv` | 147 | 定延迟 FU 的在飞指令队列（MUL 和浮点流水 FU 共用，载荷类型是参数） |
| `div_unit.sv`、`div_bank.sv`、`div_core.sv`、`div_step.sv` | 77、48、122、26 | 除法 FU、恢复除法的数据通路、一步恢复除法 |
| `exu_iter_ctl.sv` | 72 | 迭代 FU 的控制骨架（DIV 和 FDIV 共用） |
| `fp_pipe_unit.sv`、`fp_div_unit.sv`、`fp_core.sv` | 70、92、58 | 浮点 FU 和浮点运算（见第 7 节：综合时 `fp_core` 是占位） |

几个非平凡的块：

- **`alu`**：一个共享加减法器（add、sub、sh1 / 2 / 3add：先把操作数 1 左移 0..3 位再加）、有符号和无符号比较器（slt / sltu 与 min / max 家族共用）、位逻辑单元（操作数 B 可取反或取 `1 << shamt`，and / or / xor 的各变种都落在这里）、`alu_shift`（右移 `{填充, x}`，左移和旋转走位反转）、`alu_clmul`、`alu_bitcnt`，最后 9 路独热选择。rv64 的 *W 指令由译码给 `w_*` 位：操作数预处理（零 / 符号扩展、旋转用 `{a, a}`）和结果符号扩展。选不到任何单元时结果为 0。
- **`mul_core`**：操作数在接受拍（t）按 `func3` 做符号 / 零扩展后寄存；t+1 拍把 `AW × AW` 的乘积算成"和 + 进位"两个向量寄存；t+2 拍做进位传播加法并按 mul / mulh / mulhsu / mulhu / mulw 选半。结果只在 t+2 这一拍有效，所以必须在完成那拍被取走：`mul_pipe` 恰好在这一拍报完成，ISU 的完成周期预留（`isu_wb_gate`）保证口空着，`mul_unit` 在仿真里用 `$error` 检查"完成了没被取走"。`STRUCT` 参数：综合（定义 `SYNTHESIS`）时 1，用显式 Wallace 树；仿真时 0，用 `a * b`；`scripts/mul_check.sh` 对比两者和一个 C++ 参考。
- **`mul_pipe`**：深度 `DEPTH` 的按序队列，新指令放最后，最老的先完成。每拍：杀死（flush 且全 1 掩码，或与 `br_mask` 相交）、清分支位、接收（在弹出之前判满）、完成（最老的存活项倒计时 `rem == 0`）、弹出。新项接收后下一拍 `rem = DEPTH - 2`，每拍减 1，减到 0 保持（完成后没被取走就一直"已完成"）。`DEPTH >= 2`（仿真断言）。
- **`exu_iter_ctl` + `div_core`**：`busy`、倒计时 `cnt`（接收时装 `延迟 - 1`，减到 0 为完成）、`br_mask`；接收在取走之前判忙。`div_core` 每拍做 `XLEN / LAT = 2` 步恢复除法（`div_step` 串 2 级），接收拍就做第一拍的 2 步，共 `LAT` 拍；*W 除法把被除数放在高半，只做 `XLEN / 2` 步，所以 `lat_m1 = LAT / 2 - 1`。有符号运算取绝对值，商在符号不同且除数非 0 时取负，余数取被除数的符号；除数为 0 时商全 1、余数等于被除数，`INT_MIN / -1` 自然得到 `INT_MIN` 和 0。

状态：MUL：`mul_core` 的操作数寄存器（`a_q`、`b_q` 各 65 位）、"和 / 进位"寄存器（各 128 位）、`func3`、`is_word` 的两级寄存，`mul_pipe` 的 3 项 `valid_q / uop_q / rem_q`；DIV：`div_core` 的 `rem_q`、`qd_q`、`dvs_q`（各 64 位）和符号 / 类型标志，`exu_iter_ctl` 的 `busy_q`、`cnt_q`（5 位）、`br_mask_q`（32 位），载荷 `rob_idx`、`dest_preg`、`dest_en`；浮点流水 FU 是 `mul_pipe`（载荷 `fp_uop_t`：64 位结果、5 位 `fflags`、`illegal`、`rob_idx`、`dest_preg`、`dest_en`、`br_mask`）；FDIV 是 `exu_iter_ctl` 加结果和载荷寄存。单周期 FU 没有状态。

## 5. 一拍内的数据流

### 5.1 单周期 FU

输入来自 `exu_ctrl` 的槽，纯组合出结果。BRU：条件（`func3` 选 `==`、`!=`、有符号 `<` / `>=`、无符号 `<` / `>=`；`func3` 为 2 / 3 不是分支编码，条件取 1）；目标 = JALR（`src1_en`）为 `(src1 + imm)` 清最低位，其余为 `pc + imm`；`br_taken = JUMP || (BR && 条件)`；`diag_val = br_taken ? 目标 : pc + (RVC ? 2 : 4)`；`mispred = br_taken ? !(预测跳 && ftq_next_pc == 目标) : 预测跳`。这与模型 `resolve_branch` 的判据等价。

### 5.2 MUL（每拍一条进、一条出）

t：槽里的操作数进 `mul_core` 的寄存器，同时 `mul_pipe` 接收（载荷 `rob_idx`、`dest_preg`、`dest_en`、`br_mask`，不含结果）；t+1：`rem = 1`；t+2：`rem = 0`，`complete = 1`，结果来自 `mul_core` 的组合输出（t 拍的操作数）。`complete` 那拍如果 `exu_ctrl` 不取走，结果丢失（见第 4 节）。

### 5.3 DIV 和 FDIV

接收（`en` 且不忙）那拍载荷入寄存器，DIV 同时开始迭代；之后每拍 `cnt` 减 1，DIV 每拍迭代 2 步；`cnt == 0` 为完成，完成后保持直到被取走；取走那拍同时不接新指令（接收在取走之前判忙，`ready` 在两者之后求）。FDIV 的结果在接收拍就由 `fp_core` 算好并存下来，只是倒计时按操作的延迟走。

### 5.4 杀死和清分支位

flush 是 `exu_ctrl` 送来的 `exu2fu_flush = rob_bcast_flush || dec_bcast_mispred`，掩码在全局 flush 时为全 1，否则是被误预测分支的独热码。在飞指令的 `br_mask` 与掩码相交即杀；存活的每拍先和 `~clear_mask` 相与，完成时给出的 `done_br_mask` 已含本拍的清除。

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
- **`csr_fu.sv` 是死代码**：没有任何文件实例化它（`exu.sv` 的注释说明 CSR FU 的握手由 `exu_ctrl` 内化）；单周期 FU 的 `exu_fu_sc_ctl` 在整核里也只剩断言在读；
- **AGU 7 个实例各自一个加法器**：共用 AGU 的两对口没有合并成同一个加法器；
- `exu_fu_pkg.sv` 的注释里引用的 `config.h:371-398` 行号和 `alu_decode.sv` 头注释里的 `docs/modules/exu_int.md` 都是过时引用；`alu_decode.sv` 说"ALU 口见不到 UOP_JUMP，所以模型里 JUMP 时 `operand2 = 4` 的分支不翻译"，该模型分支现在已不存在（Fu.h 里没有运算）。

未核对（继承自旧文档）：

- 旧文档关于 `rol` / `ror` 移位量为 0 时 C++ 未定义行为的疑点（D-EXU-1）：当前模型没有 ALU 运算，该疑点已无对象；RTL 实现是正确旋转；
- 旧文档的变异检查表（47 个变异）和覆盖统计：随 `spec/`、`tests/exu_fu` 退役，没有重跑。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`。名字对得上 FU 的程序：`bitmanip-boundary`、`bit`、`shift`（ALU 位操作）、`mul-longlong`、`div`、`atomic-boundary`（SDU 的 AMO）、`csr-alias-boundary`、`fd-basic`、`fd-fcvt`、`fd-fdiv`、`fd-fsqrt`、`fd-matmul`（浮点 FU）；没有逐个核对每个程序实际覆盖了哪些操作。
- **乘法器**：`scripts/mul_check.sh`（`tb/mul/mul_check_top.sv`、`tb/mul/mul_check.cpp`）：随机和角点操作数，对比 `STRUCT = 1`（Wallace 树）、`STRUCT = 0`（`a * b`）和 C++ 参考，逐拍比较（t 拍操作数对应 t+2 拍结果）；提交 `48d547e` 记录 400 万个乘积相等。
- **浮点**：`tests/fp_dpi`（DPI 运算对函数模型的差分测试）、`tests/fp_chain`（`rv64imafd` 小程序在 RTL 上逐提交检查）。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有除 MUL 之外的模块级测试**：ALU、BRU、AGU、SDU、DIV 目前只靠整核对账；旧的随机 trace + 变异体系已退役。**待补**：ALU（含 Zb* 的各编码）、DIV（除数为 0、`INT_MIN / -1`、*W）、BRU（各 `func3`、JALR 清最低位）各补一个和 C++ 运算参考并排的随机测试，像 `mul_check` 那样。

## 9. 参数与开关速查

`ALU_NUM`、`BRU_NUM`、`LSU_AGU_COUNT`、`LSU_SDU_COUNT`、`MUL_MAX_LATENCY`、`DIV_MAX_LATENCY`、`FP_FMA_LAT`、`FP_MISC_LAT`、`FP_I2F_LAT`、`FP_FDIV_S_LAT`、`FP_FSQRT_S_LAT`、`FP_FDIV_D_LAT`、`FP_FSQRT_D_LAT`、`FPRF_NUM`（`ttg_cfg_pkg`）；`MUL_NUM`、`DIV_NUM`（`exu_fu_pkg`）；`mul_core` 的 `STRUCT`（由 `SYNTHESIS` 决定，`mul_pipe` 的 `DEPTH`、`UOP_T`、`div_core` 的 `LAT` 是实例化参数）；`SYNTHESIS`（`fp_core` 和 `mul_core` 的两套实现）。

## 10. 变更记录

- 2026-11-18（exp/agu-share，`261bd67..HEAD`）：`48d547e` 乘法器摊在 3 拍延迟上（见第 6 节表），新增 `scripts/mul_check.sh`、`tb/mul`。
- 2026-11-12：rv64（`is_word`、*W 运算、`div_core` 每拍 2 步、`MUL_MAX_LATENCY = 3`、`DIV_MAX_LATENCY = 32`）；F/D（浮点 FU）。
- 更早：见 git 历史。
