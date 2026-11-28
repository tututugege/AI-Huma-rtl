---
module: exu_ctrl
area: backend
rtl: rtl/backend/exu_ctrl
model: trace-model back-end/Exu/Exu.cpp、back-end/Exu/include/Exu.h、back-end/Exu/include/Fu.h（调度单元 `back.exu`，类 `Exu`，阶段 `comb_exec`，内部 `load_wake → exec → ready`；本文只管其中的控制和仲裁）
status: 整核周期与模型逐个相等（fm_gate 68/68，0 周期偏差）
depth: 17 层（rtl/be-wake-byp-opt，20,037 单元，已删除 31 路 `exe2prf_bypass` 总线；main 20,133 / 17 层）（exu_ctrl，单模块综合，2026-11-21，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# exu_ctrl 设计文档

## 1. 职责

执行单元的控制侧：每个功能单元（FU）前面有一个一项的输入寄存器，叫**输入槽**；每个发射口上可能挂几个 FU，同拍只有一个能把结果交出去。exu_ctrl 管这些槽、管口内仲裁、管结果往哪里送，但不做任何运算（运算在 `exu_fu`）。每拍做六件事：

1. 把 PRF 读出的发射结果（`prf2exe_iss_entry_*`）装进每发射口一套的 19 个无停顿流水线寄存器（`valid_q / slot_q`）；被 flush 或被误预测杀死时清掉；
2. 由组合逻辑将口寄存器分发至匹配的 FU（`exu2fu_*`），收回 FU 的结果（`fu_*`），整理成每个 FU 一条统一的"完成记录"；
3. 每个发射口内由写回预约保证每拍至多一个 FU 完成（仿真 `$onehot0` 断言检查），直接用一热选择器选出赢家（无 `consume` 反压）；
4. 把结果送出去：写回 PRF 并兼作 EXU 级旁路（`exe2prf [WB_LANES]`，`WB_LANES = 13`；其中 ALU 通道 0..5 由 PRF 按独热直选旁路）、完成报告给 ROB（`exu2rob`，21 通道 `ROB_WB_WIDTH`）、AGU 结果变成 5 路统一 LSU 请求（`exe2lsu_agu`）、CSR 指令的读写请求（`exe2csr`）；
5. 汇总 BRU 的结果：最老的一条误预测分支触发重定向（`exu2id_*`）；
6. 仅从 `exu.sv` 顶层口 1 迭代除法器输出 1-bit `exe2iss_div_wb_in2`（提前 2 拍即 DIV accept 且 `lat_m1 == 1` 或 `live && cnt_q == 2` 时屏蔽 Port 1 ALU 发射，适配 **ISS → RR → EX** 两拍；DIV 的晚唤醒走 `exe2iss_div_wake_*`；`exu_iter_ctl` 仍输出 `div_wb_next`，但 `exu.sv` 只接线、没有使用；这些都在 `exu.sv`，不经过 `exu_ctrl`；EXP-072 已删除 `exu_ctrl_ready` 与 `exe2iss_fu_ready_mask`）。

模型里对应一个调度单元 `back.exu`（类 `Exu`）。RTL 把它拆成三块：控制和仲裁在本模块；FU 的时序状态和运算在 `exu_fu`（模型的 FU 没有运算，结果直接取自 trace 的事实，只有"何时完成"的时序）；模型 `Exu::load_wake`（load 写回寄存器后的晚唤醒，输出 `prf_awake`）在 RTL 里落在 `prf` 的 `prf_awake`，不在本模块。

术语：**发射口**（口）是 ISU 发射结果的 19 个出口之一（编号见第 2 节）；**完成**指 FU 这一拍有一个结果可以交；**赢得口**指本口完成的那个 FU。

## 2. 配置（`ttg_cfg_pkg` / `exu_ctrl_pkg`，现行默认）

口号与 isu.md 一致：`ISSUE_WIDTH = 19`，口基址 `IQ_ALU_PORT_BASE = 0`、`IQ_AGU_PORT_BASE = 6`、`IQ_STD_PORT_BASE = 11`、`IQ_BR_PORT_BASE = 14`、`IQ_FP_PORT_BASE = 16`。ROB 写回通道数 `ROB_WB_WIDTH = 21`（将 4 load 与 3 STA 拆开：`ROB_WB_ALU_BASE = 0`、`ROB_WB_LD_BASE = 6`、`ROB_WB_STA_BASE = 10`、`ROB_WB_STD_BASE = 13`、`ROB_WB_BR_BASE = 16`、`ROB_WB_FP_BASE = 18`）。每个口上的 FU 实例由口能力表 `dis_pkg::issue_port_cap()`（与 ISU 共用的唯一一份）给出的能力掩码推出，实例号（`fu_idx`）按"口号从小到大，口内按优先级顺序"排，`TOTAL_FU_COUNT = 28`：

| 口 | 能力（`dis_pkg::issue_port_cap`） | FU 实例（口内优先级从高到低）和 `fu_idx` |
| --- | --- | --- |
| 0 | ALU、MUL、CSR | MUL 0、ALU 1、CSR 2（`CSR_FU = 2`，`CSR_PORT = 0`） |
| 1 | ALU、DIV | DIV 3、ALU 4 |
| 2 | ALU、MUL、I2F | MUL 5、I2F 6、ALU 7 |
| 3 | ALU、I2F | I2F 8、ALU 9 |
| 4、5 | ALU | ALU 10、ALU 11 |
| 6、7 | LOAD | load AGU 12、13 |
| 8、9 | LOAD、STA | 共享 AGU 14、15 |
| 10 | STA | STA AGU 16 |
| 11..13 | STD | SDU 17..19 |
| 14、15 | BR | BRU 20、21 |
| 16、17 | FMA、FMISC | FMA、FMISC（22、23；24、25） |
| 18 | FDIV、FMISC | FDIV 26、FMISC 27 |

优先级顺序就是 `exu_ctrl_pkg` 里 `XC_K_*` 的编号顺序（MUL、DIV、AGU、SDU、BR、I2F、ALU、CSR、FMA、FDIV、FMISC，共 `XC_KINDS = 11` 类），和模型 `Exu::init` 里 `kSpecs` 的顺序一致。

FU 分组数组（按 `fu_idx` 序排）：多周期 FU（MUL、DIV）`N_MC = 3`（MUL 0、DIV 3、MUL 5）；浮点 FU `N_FPU = 8`（I2F 6、I2F 8、FMA 22、FMISC 23、FMA 24、FMISC 25、FDIV 26、FMISC 27）；AGU `N_AGU = LSU_AGU_COUNT = 5`（前 2 个仅 load，中间 2 个共用，最后 1 个仅 STA）；`N_SDU = 3`。uop 类型、宽度和集合类型用 `dis_pkg::uop_op_e` / `UOP_TYPE_W = 5` / `uop_set_t`（`UOP_TYPE_NUM = 21`）（`lsu.sv` 也直接用 `dis_pkg::UOP_LOAD / UOP_STA`）。

`ttg_cfg_pkg.sv` 由 `make cfg` 生成；`exu_ctrl.sv` 开头的 `g_cfg_check` 检查各类 FU 个数及 `xc_fu_total() == TOTAL_FU_COUNT`。

## 3. 接口

信号组按模型 `Exu` 的 `in` / `out` 命名，数组展开成平铺端口：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `rob_bcast_flush` | 全局 flush，已被 `back_top` 的 `rob_flush_q` 推迟一拍（docs/FLUSH_REG.md） |
| 入 | `dec_bcast_mispred / _redirect_rob_idx / _redirect_rob_flag` | 误预测及重定指向标 |
| 入 | `prf2exe_valid / _uop [ISSUE_WIDTH]` | 发射结果加上 PRF 读出的操作数（`src1_rdata`、`src2_rdata`、浮点 `fsrc1..3`）和 FTQ 读出的 PC 元数据（口 0..5 和 14、15） |
| 入 | `prf2exe_csr_idx` | 口 0 的 `csr_idx`（CSR 固定在口 0） |
| 入 | `fu_alu_result[6]`、`fu_agu_result[5]`、`fu_sdu_result[3]`、`fu_bru_{diag_val,mispred,br_taken}[2]` | 单周期 FU 只回计算结果；`complete` 由 `fu_en` 直接推 |
| 入 | `fu_mc_*[3]`、`fu_fp_*[8]` | 多周期 FU 回 `complete`、结果、`dest_preg`、`dest_en`、`rob_idx`、`rob_flag`（浮点还有 `fresult`、`fflags`、`illegal`），无 `ready`/`consume` |
| 入 | `lsu2exe_wb_req_*[4]`、`lsu2exe_sta_wb_req_*[3]` | LSU 的 load（含 SC）和 STA 写回请求，映射至 `exu2rob` 的 `ROB_WB_LD_BASE` 与 `ROB_WB_STA_BASE` |
| 入 | `csr2exe_rdata` | CSR 读出的值 |
| 出 | `exu2fu_*` | 交给 FU 的操作数与 `flush_all/br`（按 ALU / BRU / AGU / SDU / MC / FP 分组；MC 组没有 `func7 / op / imm`） |
| 出 | `exe2prf [WB_LANES]` | 寄存器写回 + 旁路总线，13 条通道（ALU 6 + load 4 + FP 3） |
| 出 | `exu2rob [ROB_WB_WIDTH]` | 21 通道 ROB 完成报告 |
| 出 | `exe2lsu_agu [LSU_AGU_COUNT]`（`xc_agu_req_t`）、`exe2lsu_sdu_req_*[3]` | 5 个物理 AGU 的统一 LSU 请求（含 `raw` / `valid` / `op`）及 3 个 SDU 请求 |
| 出 | `exe2csr_we / _idx / _wdata / _wcmd` | CSR 指令的请求（读使能 `csr_re` 只在 `exu_ctrl` 内部选写回数据） |
| 出 | `exu2id_mispred`、`exu2id_redirect_{pc, rob_idx, rob_flag}`、`exu2id_ftq_{idx, offset}`、`exu2id_br_{pc, is_rvc}` | 最老误预测分支重定向信息（重定向 pc、分支 ROB 号、FTQ 位置、分支自身 pc 与是否 16 位），去 `back_br_redirect`（再由它广播 `dec_bcast_*`） |

模型 `Exu::Out` 另有 `prf_awake` 和 `div_wake_*`（RTL 分别在 PRF 和 ISU）；RTL 另有 `exe2csr` 和 `exu2fu`。

## 4. 结构

```
 prf2exe_uop[p] ─► exu_ctrl_slot（19 个口寄存器）─► fu_en / fu_inst ─► exu_ctrl_fu_out ─ exu2fu_* ─► exu_fu 各 FU
                                                                                                         │ fu_*
                           exu2rob / exe2prf / exe2lsu ◄─ win[p] ◄─ exu_ctrl_port_arb ◄─ fu_done ◄─ exu_ctrl_fu_view ◄─ exu_ctrl_fu_in
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `exu_ctrl_pkg.sv` | 370 | FU 种类掩码、FU 编号表（由 `dis_pkg::issue_port_cap` 推出）、`XC_K_AGU` 统一类型、`xc_agu_req_t`、`xc_inst_t`、`xc_fu_res_t`、`xc_done_t`、`xc_lsu_wb_t` |
| `exu_ctrl.sv` | 265 | 顶层：端口与内部结构体互转，实例化各子模块并检查 `$onehot0(complete_vec)` |
| `exu_ctrl_slot.sv` | 75 | 每发射口 1 槽寄存器（无停顿/无重放）、comb 译码生成 `fu_en`、`agu_occ`、`agu_is_sta`；独立寄存口 0 `csr_idx_q` |
| `exu_ctrl_fu_in.sv` | 76 | 把分组数组按 `fu_idx` 收成每个 FU 一条 `xc_fu_res_t` |
| `exu_ctrl_fu_view.sv` | 66 | 把槽和 FU 结果合成统一的完成记录 `fu_done` |
| `exu_ctrl_port_arb.sv` | 47 | 口内一热仲裁：`ttg_onehot_mux` 直接选出赢家，OR 归约生成 `win_valid`（无 `consume`） |
| `exu_ctrl_wb_prf.sv` | 51 | 寄存器写回与 EXU 级旁路总线（`WB_LANES = 13`） |
| `exu_ctrl_wb_rob.sv` | 67 | 21 通道 ROB 完成报告（按 `ROB_WB_*_BASE` 分流） |
| `exu_ctrl_br_arb.sv` | 62 | 最老误预测分支选择 |
| `exu_ctrl_csr_req.sv` | 41 | CSR 槽 → `exe2csr` |
| `exu_ctrl_lsu_req.sv` | 49 | 5 路 AGU / 3 路 SDU → `exe2lsu_agu` / `exe2lsu_sdu_*` |
| `exu_ctrl_fu_out.sv` | 138 | 槽里的指令 → 各 FU 组的输入端口 |

状态：每个发射口 1 槽（19 槽，`valid_q` + `xc_inst_t`）及 `csr_idx_q`（12 位，口 0）。无 FU 输入缓存槽。

`exu_ctrl_slot`：`load[p] = prf2exe_valid[p] && !flush && !误预测杀`；无条件更新 `valid_q <= load[p]`，绝不保留到下一拍；`fu_en[f]` 由所属口 `valid_q[p] && !flush && !杀 && (能力匹配)` 组合生成。

## 5. 一拍内的数据流

### 5.1 槽和交给 FU 的内容

1. 读口寄存器：`agu_occ[a] = valid_q[IQ_AGU_PORT_BASE + a]`（不看是否被杀），`agu_is_sta[a] = (slot_q.op == UOP_STA)`。
2. `fu_en[f]` 为 1 时通过 `exu_ctrl_fu_out` 驱动对应 FU（单周期与多周期 FU 均保证空闲或流水未满）。
3. 单周期 FU（ALU、BRU、AGU、SDU、CSR）同拍完成，`complete = fu_en`；多周期 FU 用自己的 `complete`。

### 5.2 口内一热选择

由于 ISU 写回周期预约与口 1 的 DIV 写回预告（`exe2iss_div_wb_in2`，在 `exu.sv`）互斥，`complete_vec`（本口各 FU 的 `complete`）在每拍至多 1 位为 1。`exu_ctrl_port_arb` 直接用 `|` 归约得出 `win_valid[p]` 并通过 `ttg_onehot_mux` 取出赢家，`exu_ctrl.sv` 在仿真态用 SVA `$onehot0` 断言保护。

### 5.3 写回、完成报告、LSU 请求

- **`exe2prf`**：通道 0..5 = ALU 口 0..5 赢家、通道 6..9 = LSU 4 路 load 写回、通道 10..12 = 浮点口 16..18 赢家。
- **`exu2rob`（21 通道 `ROB_WB_WIDTH`）**：ALU 0..5、LD 6..9（LSU）、STA 10..12（LSU）、STD 13..15（口 11..13）、BR 16..17（口 14..15）、FP 18..20（口 16..18）。
- **LSU 请求**：5 个 AGU 直接按物理口号驱动 `exe2lsu_agu[0..4]`（含 `valid`、`raw`、`op` 及结果载荷），3 个 SDU 驱动 `exe2lsu_sdu_req[0..2]`。

### 5.4 分支与 CSR

BRU（口 14..15）误预测由 `exu_ctrl_br_arb` 比较最老者重定向；CSR（口 0 槽且 `alu_en` 之外匹配 `OP_CSR`）直接驱动 `exe2csr`，且永不被口 0 的 MUL 挤住重试（发射级已排开同拍完成）。

## 6. 关键路径与深度

删除了 `exu_ctrl_ready`、`exu_ctrl_port_arb` 优先编码链与 `exu_ctrl_slot` 重放保持路径；`exu_ctrl` 不再有去 ISU 的输出；口 1 DIV 的写回预告 `exe2iss_div_wb_in2` 由 `exu.sv` 直接从 `g_div[0].u_div` 引出。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- **FU 的运算**：模型 `fu::compute` 取自 trace 事实，RTL 真算（`exu_fu`）；
- **`tbhook::on_exec`、`MSD_TRACE` 打印、`Assert`**：RTL 用 SVA `$onehot0(complete_vec)` 检查口内无碰撞。

RTL 与模型保持一致的细节：

- 被杀的指令也占 AGU 槽：`exe2lsu_agu[a].raw` 看口寄存器的 `valid_q`（不看杀死信号）。

未核对（继承自旧文档）：

- 旧文档的真实程序覆盖统计和变异检查结果（trace 回放体系随 `spec/` 一起退役，没有重跑）；
- 旧文档关于"MUL 在口内最高优先级才避免重复接收"的疑点：本文只核对了 `mul_pipe` 的接收条件在取走之前判满（`accept = en && !(&surv)`，与模型 `PIPE` 先推再弹一致），没有推演所有时序。

代码里的小问题（没有改）：`exu_ctrl_wb_rob.sv`、`exu_ctrl_lsu_*.sv`、`exu_ctrl_port_arb.sv` 的注释还写着"22 个写回口"、"口 6..13"、"agu 0..3 loads, 4..7 store-address"、"MUL > DIV > LD > STA > STD > BR > ALU > CSR > FP"（现在是 21 口、load 4 个、STA 3 个、优先级里还有 I2F）；`exu_ctrl_pkg.sv` 里 `N_AGU` 的注释同样过时；`exu_ctrl_br_arb.sv`、`exu_ctrl_wb_rob.sv` 注释里的"notes 4.2-1"指旧文档的一节，新文档没有这一节。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`scripts/lint_chip.sh` & `scripts/lint_soc.sh` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` 严格模式 `scripts/fm_gate.sh` 77/77 通过（0 FM 偏差）；`scripts/riscv_tests_gate.sh` 152/152 通过（1 SKIP `rv64ui-ma_data`）；`scripts/soc_gate.sh --linux` 12/12 通过；集群 Linux 26 窗（5.1M insts/窗）26/26 PT/UP 全等；SPEC06 INT 386/386 `geomean +0.144%`（`13.30 /GHz`）。
- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）。其中名字对得上本模块特殊路径的有：`csr-alias-boundary`（CSR 槽）、`atomic-boundary`（STD 的 AMO）、`mul-longlong`、`div`（口 0..3 的 MUL / DIV）、`fd-*`（浮点口）；其余程序都经过口内仲裁、旁路和分支解析。没有逐个核对每个程序实际覆盖了哪些路径。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **浮点**：`tests/fp_chain`（`rv64imafd` 小程序在 RTL 上逐提交检查，要 F/D 配置的构建）。
- **没有模块级的独立测试**：旧体系（trace 回放、随机 trace、变异）已随 `spec/`、`tests/exu_ctrl` 退役。目前靠整核周期逐拍相等和 Linux 启动。**待补**：口内仲裁和 `exu_ctrl_br_arb` 各补一个和模型行为并排的随机测试（口 0 上 CSR 与 MUL 同拍完成、同拍多个 BRU 误预测、被杀的 AGU 槽的 `*_req_occ`）。

## 9. 参数与开关速查

`ISSUE_WIDTH`、`TOTAL_FU_COUNT`、`ALU_NUM`、`BRU_NUM`、`LSU_LDU_COUNT`、`LSU_STA_COUNT`、`LSU_SDU_COUNT`、`LSU_AGU_COUNT`、`LSU_LOAD_WB_WIDTH`、`IQ_*_PORT_BASE`、`FPRF_NUM`（F/D 总是有，`ttg_cfg_pkg`）；`N_MC`、`N_FPU`、`CSR_FU`、`CSR_PORT`（`exu_ctrl_pkg`）；口能力表 `issue_port_cap()`（`dis_pkg`，手写）。没有运行时开关。

## 10. 变更记录
- 2026-11-29：`exu_ctrl_fu_in` 每个 FU 按种类取结果的写法从运行时 `case (KIND)` 改成 generate 分支：原来不属于本种类的那几个分支也会被展开，它们用本种类的序号去索引别的种类的数组，常量下标越界（不可达，但综合 / lint 工具会报）；现在只展开本种类那一支（周期不变）。

- 2026-11-29 清理 E：改名 `lsu2exe_{,sta_}wb_req_valid` / `_wb_req_uop_*` → `lsu2exe_{,sta_}wb_valid` / `_wb_uop_*`（只改名字，周期不变）。
- 2026-11-29 清理 D：去重——删 `xc_port_cap`（与 `isu_pkg::port_cap` 同一张表，现只留 `dis_pkg::issue_port_cap`，`xc_port_has` 直接读它）；删 uop 编码副本 `XC_OP_NUM`、`XC_UOP_MUL/DIV/FMA/FMISC/FDIV/I2F`，`xc_mc_op` / `xc_fp_op` 改用 `dis_pkg::UOP_*`，`xc_opset_t` / `xc_op_t` 由 `dis_pkg::uop_set_t` / `UOP_TYPE_W` 定义；`exu_ctrl` / `exu_ctrl_fu_out` / `exu_ctrl_wb_prf` / `exu_ctrl_wb_rob` 改用 `dis_pkg::UOP_TYPE_W` / `UOP_LOAD` / `UOP_STA`；`XC_OP_W` / `XC_UOP_LOAD` / `XC_UOP_STA` 仅为 `lsu.sv` 留作别名（数值不变）（周期不变）。
- 2026-11-28 清理：删 `FP_EN`（`XC_OP_NUM = 21`、`N_FPU = 8`、`exu_ctrl_fu_out` 的 `g_no_fp`、端口能力里的 I2F 条件）、输出 `exu2fu_mc_func7 / _op / _imm`（`exu.sv` 不读）与 `exe2csr_re`（`csr` 不读，改为内部线 `csr_re`）、`exu_ctrl_pkg` 两处 `LSU_MEMSPEC:` 注释前缀；删不抑制任何告警的 lint 豁免（`exu_ctrl_fu_out` / `exu_ctrl_lsu_req` / `exu_ctrl_wb_prf` / `exu_ctrl_wb_rob` 各 1 处，以去掉豁免后整树 lint 普通 / `-DSYNTHESIS` 均无新告警为准）（周期不变）。
- 2026-11-28（文档核对，无 RTL 变化）：`exe2iss_div_wb_in2` 在 `exu.sv` 而不在 `exu_ctrl`，删去错误的 `exe2iss_div_wb_next` 输出；写回 / 旁路总线为 `exe2prf`；`exu2id_*` 列全；文件表补行数；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/exu-clean`，EXP-072）：非阻塞 EXU 控制面重构与真 5 物理 AGU 收敛——删除 `exu_ctrl_ready.sv`、`exu_ctrl_lsu_out.sv` 及全部逐 FU `ready/consume` 协议，改为发射即占用；AGU 槽由逻辑 7 槽+映射直接收敛为真 5 物理端口（复用口 4 由 ISU 直选），仅传 `div_wb_next` 通知 ISU 错开 PORT 1 写回；TSMC 28nm HPC+ DC（`0.50 ns`）实测 **`WNS = 0.00 ns`（`CPL 0.37 ns`, `11 lvl`）**、触发器 `4,765`、面积 **`19,432.06 µm²`（较旧 `31,760.90 µm²` 降 −38.8%）**；通过 `lint_chip`/`lint_soc` 0、strict+SVA `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 与 Linux 26/26 窗对齐。

- 2026-11-24（`rtl/timing-opt2`，EXP-063，0 周期变化）：将 `exu_ctrl_pkg.sv` 中 `xc_is_fp_kind` 返回类型由 `bit` 改为 `int`（返回 `1 : 0`），并同步调整 `exu_ctrl_fu_view` / `exu_ctrl_ready` / `exu_ctrl_fu_in` 3 处调用与 `localparam` 计数循环，消除 Synopsys DC Presto 内部断言 `(VER-37)`；TSMC 28nm HPC+ DC 实测 **WNS = 0.00 ns（MET ≥2.00 GHz）**、13 级、`31,761 um²`；通过 `lint_chip` 0、`fm_gate` 69/69。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`exu_ctrl_pkg`（`xc_inst_t` / `xc_done_t`）、`exu_ctrl_fu_view`、`exu_ctrl_br_arb`、`exu_ctrl` 透传 4 位 `ftq_offset`（`prf2exe_iss_entry_uop_ftq_offset` → `exu2id_ftq_offset`），供后端误预测精确索引双块 FTQ（避免同 PC 在 Block A/B 重复时的歧义）；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗对齐。
- 2026-11-19（`exp/wb-presel`，EXP-046）：`exu_ctrl_wb_prf` 输出按通道编号的写回总线（`WB_LANES = 13`：ALU 6、load 4、浮点口 3），不再按发射口输出 21 路；STA 写回不再进写回总线（`sta_wb` 只给 `exu_ctrl_wb_rob`）。周期不变。
- 2026-11-18（exp/agu-share，`261bd67..HEAD`）：
  - `e49618c`：AGU 槽的占用 `exe2lsu_ldu_req_occ`、`exe2lsu_sta_req_occ`（`exu_ctrl_slot` 的 `fu_occ`，经 `exu_ctrl_lsu_out`）；LSU 重放口的分配看它（模型 `ExeLsuReqEntry::raw`），周期对 `ref_cycles_memiq6_nr_int2_ev2.txt`；
  - `803692f`：`rob_bcast_flush` 现在来自 `back_top` 的 `rob_flush_q`（晚一拍），本模块自身没改，见 docs/FLUSH_REG.md。
- 更早：见 git 历史。
- 2026-11-29 清理：`exu_ctrl_pkg` 删包级 `lint_off UNUSEDPARAM` 豁免（`scripts/lint.sh` 改为只编所需的包，包常量是否未用只在整芯片 lint 判定，见 `docs/01-rtl-coding-standard.md` 8.5；整芯片 lint 普通 / `-DSYNTHESIS` 下无死常量）（周期不变）。
