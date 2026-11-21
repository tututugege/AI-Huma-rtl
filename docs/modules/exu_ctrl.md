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

1. 把 PRF 读出的发射结果（`prf2exe_iss_entry_*`）装进对应 FU 的输入槽；槽里的指令被 flush 或被误预测杀死时丢掉，分支解析后清掉它 `br_mask` 里对应的位；
2. 把槽里的指令交给 FU（`exu2fu_*`），收回 FU 的结果（`fu_*`），整理成每个 FU 一条统一的"完成记录"；
3. 每个发射口内按固定优先级选第一个"完成"的 FU（口内仲裁），被选中的 FU 的结果才被取走（`consume`）；
4. 把结果送出去：写回 PRF（`exe2prf_entry`）、旁路广播（`exe2prf_bypass`，每个完成的 FU 一路，不管是否赢得本口）、完成报告给 ROB（`exu2rob`）、AGU 结果变成 LSU 的请求（`exe2lsu`）、CSR 指令的读写请求（`exe2csr`）；
5. 汇总 BRU 的结果：所有解析了的分支释放自己的分支号（`exu2id_clear_mask`），最老的一条误预测分支触发重定向（`exu2id_*`）；
6. 告诉 ISU 每个发射口下一拍还能收哪些操作类（`exe2iss_fu_ready_mask`）。

模型里对应一个调度单元 `back.exu`（类 `Exu`）。RTL 把它拆成三块：控制和仲裁在本模块；FU 的时序状态和运算在 `exu_fu`（模型的 FU 没有运算，结果直接取自 trace 的事实，只有"何时能收、何时完成"的时序）；模型 `Exu::load_wake`（load 写回寄存器后的晚唤醒，输出 `prf_awake`）在 RTL 里落在 `prf` 的 `prf_awake`，不在本模块。

术语：**发射口**（口）是 ISU 发射结果的 21 个出口之一（编号见第 2 节）；**完成**指 FU 这一拍有一个结果可以交；**赢得口**指同口的几个 FU 同拍完成时被选中的那个。

## 2. 配置（`ttg_cfg_pkg` / `exu_ctrl_pkg`，现行默认）

口号与 isu.md 一致：`ISSUE_WIDTH = 21`，口基址 `IQ_ALU_PORT_BASE = 0`、`IQ_LD_PORT_BASE = 6`、`IQ_STA_PORT_BASE = 10`、`IQ_STD_PORT_BASE = 13`、`IQ_BR_PORT_BASE = 16`、`IQ_FP_PORT_BASE = 18`。每个口上的 FU 实例由 `exu_ctrl_pkg::xc_port_cap()` 给出的能力掩码推出，实例号（`fu_idx`）按"口号从小到大，口内按优先级顺序"排，`TOTAL_FU_COUNT = 31`：

| 口 | 能力（`xc_port_cap`） | FU 实例（口内优先级从高到低）和 `fu_idx` |
| --- | --- | --- |
| 0 | ALU、MUL、CSR | MUL 0、ALU 1、CSR 2（`CSR_FU = 2`，`CSR_PORT = 0`） |
| 1 | ALU、DIV | DIV 3、ALU 4 |
| 2 | ALU、MUL、I2F | MUL 5、I2F 6、ALU 7 |
| 3 | ALU、DIV、I2F | DIV 8、I2F 9、ALU 10 |
| 4、5 | ALU | ALU 11、ALU 12 |
| 6..9 | LOAD | load AGU 13..16 |
| 10..12 | STA | STA AGU 17..19 |
| 13..15 | STD | SDU 20..22 |
| 16、17 | BR | BRU 23、24 |
| 18、19 | FMA、FMISC | FMA、FMISC（25、26；27、28） |
| 20 | FDIV、FMISC | FDIV 29、FMISC 30 |

优先级顺序就是 `exu_ctrl_pkg` 里 `XC_K_*` 的编号顺序（MUL、DIV、LD、STA、STD、BR、I2F、ALU、CSR、FMA、FDIV、FMISC），和模型 `Exu::init` 里 `kSpecs` 的顺序一致；I2F 排在 ALU 前面是为了不让 ALU 饿死它（模型注释同）。

注意这里数的"FU 实例"是 31 个，不是 isu.md 说的 19 个执行单元：一个整数口上的 ALU、MUL、CSR 各算一个实例；共用 AGU 的两对口（load 口 8、9 与 STA 口 11、12）在本模块里是 4 个互相独立的 AGU 实例，共用只体现在 ISU 不会同拍发这一对口里的两条、PRF 里 STA 口借用 load 口的 src1 读口、DTLB 按物理 AGU 配口（见 prf.md、back_top.md）。LSU 侧的数组大小：load 请求 `LSU_LDU_COUNT = 4`、STA 请求 `LSU_STA_COUNT = 3`、STD 请求 `LSU_SDU_COUNT = 3`、load 写回 `LSU_LOAD_WB_WIDTH = 4`。

FU 分组数组（按 `fu_idx` 序排）：多周期 FU（MUL、DIV）`N_MC = 4`，下标 0..3 依次是 MUL 0、DIV 3、MUL 5、DIV 8；浮点 FU `N_FPU = 8`（I2F 6、I2F 9、FMA 25、FMISC 26、FMA 27、FMISC 28、FDIV 29、FMISC 30，按 `fu_idx` 序）；AGU `N_AGU = LSU_AGU_COUNT = 7`（前 4 个是 load 口的，后 3 个是 STA 口的）；`N_SDU = 3`。`XC_OP_W = 5`、`XC_OP_NUM = 21`（有 F/D 时，`FPRF_NUM != 0`）。

口的能力表 `xc_port_cap` 是模型 `GLOBAL_ISSUE_PORT_CONFIG` 的手抄副本（不是从 `ttg_cfg_pkg` 推出来的）；`exu_ctrl.sv` 开头的 `g_cfg_check` 只检查各类 FU 的个数（`xc_fu_total()` 等于 `TOTAL_FU_COUNT`、ALU/BR/LD/STA/STD 的个数、`N_MC`、`N_FPU`、CSR 在口 0 的实例 2）；能力表本身改了不会报错。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 3. 接口

信号组按模型 `Exu` 的 `in` / `out` 命名，数组展开成平铺端口：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `rob_bcast_flush` | 全局 flush，已被 `back_top` 的 `rob_flush_q` 推迟一拍（docs/FLUSH_REG.md） |
| 入 | `dec_bcast_mispred / _br_mask / _clear_mask` | 误预测（`br_mask` 是被误预测分支的独热码）、本拍解析完的分支号 |
| 入 | `prf2exe_iss_entry_valid / _uop_*  [ISSUE_WIDTH]` | 发射结果加上 PRF 读出的操作数（`src1_rdata`、`src2_rdata`、浮点 `fsrc1..3`）和 FTQ 返回的 `pc`、`ftq_pred_taken`、`ftq_is_rvc`、`ftq_next_pc`（只有口 0..5 和 16、17 有 pc） |
| 入 | `prf2exe_iss_entry_uop_csr_idx` | 只有一个：`back_top` 取的是口 0 的 `csr_idx`（CSR 固定在口 0） |
| 入 | `fu_alu_result[6]`、`fu_agu_result[7]`、`fu_sdu_result[3]`、`fu_bru_{diag_val,mispred,br_taken}[2]` | 单周期 FU 只回计算结果；`complete` / `ready` 由本模块自己推 |
| 入 | `fu_mc_*[4]`、`fu_fp_*[8]` | 多周期 FU 回整套握手：`ready`、`complete`、结果、`dest_preg`、`dest_en`、`br_mask`、`rob_idx`（浮点还有 `fresult`、`fflags`、`illegal`） |
| 入 | `lsu2exe_wb_req_*[4]`、`lsu2exe_sta_wb_req_*[3]` | LSU 的 load（含 SC）和 STA 写回请求，走口 6..9 和口 10..12 |
| 入 | `csr2exe_rdata` | CSR 读出的值 |
| 出 | `exu2fu_*` | 交给 FU 的操作数，按 ALU / BRU / AGU / SDU / MC / FP 分组；`exu2fu_flush = rob_bcast_flush \| dec_bcast_mispred`，`exu2fu_flush_mask = rob_bcast_flush ? 全 1 : dec_bcast_br_mask`，`exu2fu_clear_mask` |
| 出 | `exe2iss_fu_ready_mask [ISSUE_WIDTH]` | 每个口下一拍能收的操作类，一位对应一种 uop 类型 |
| 出 | `exe2prf_entry_* [WB_LANES]` | 寄存器写回总线，13 条通道（见 5.4） |
| 出 | `exe2prf_bypass_* [TOTAL_FU_COUNT]` | 31 路旁路：每个完成的 FU 一路 |
| 出 | `exu2rob_entry_* [ISSUE_WIDTH]` | 完成报告 |
| 出 | `exe2lsu_ldu_req_*[4]`、`exe2lsu_sta_req_*[3]`、`exe2lsu_sdu_req_*[3]` | AGU / SDU 的结果；`exe2lsu_ldu_req_occ`、`exe2lsu_sta_req_occ` 表示 AGU 槽里有一条指令（不管它是否已被杀） |
| 出 | `exe2csr_we / _re / _idx / _wdata / _wcmd` | CSR 指令的请求 |
| 出 | `exu2id_mispred / _clear_mask / _redirect_pc / _redirect_rob_idx / _br_id / _ftq_idx / _br_pc / _br_is_rvc` | 分支解析结果，去 IDU |

模型 `Exu::Out` 另有 `prf_awake`（RTL 在 prf）；RTL 另有 `exe2csr` 和 `exu2fu`（模型里 CSR 在完成时直接读 `csr_state()`，FU 就在 Exu 内部）。

## 4. 结构

```
 prf2exe_iss_entry[p] ─► exu_ctrl_slot（31 个槽）─ fu_en / fu_inst ─► exu_ctrl_fu_out ─ exu2fu_* ─► exu_fu 各 FU
                              ▲ fu_ready                                                               │ fu_*
 exu_ctrl_ready ◄─ consume ─ exu_ctrl_port_arb ◄─ fu_done ◄─ exu_ctrl_fu_view ◄─ exu_ctrl_fu_in ◄──────┘
   └► exe2iss_fu_ready_mask       └► win[p]（每口一个赢家）
 win / fu_done / LSU 写回 ─► exu_ctrl_wb_prf → exe2prf_entry、exe2prf_bypass
                           ─► exu_ctrl_wb_rob → exu2rob_entry
 fu_done ─► exu_ctrl_br_arb → exu2id_*       fu_done ─► exu_ctrl_lsu_req / exu_ctrl_lsu_out → exe2lsu_*
 CSR 槽 ─► exu_ctrl_csr_req → exe2csr_*
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `exu_ctrl_pkg.sv` | 357 | 口能力表、FU 编号表（由口能力推出的常量函数）、分组索引函数、`xc_inst_t`（槽里的指令，28 个字段）、`xc_fu_res_t`（FU 回来的结果）、`xc_done_t`（统一的完成记录）、`xc_lsu_wb_t`、"是否被杀"和"谁更老"函数 |
| `exu_ctrl.sv` | 401 | 顶层：端口与内部结构体互转，实例化下面各块，生成 `exu2fu_flush` 等 |
| `exu_ctrl_slot.sv` | 75 | 输入槽：装载、杀死、清分支位、释放；`csr_idx` 只有 CSR 槽需要，单独存一份 |
| `exu_ctrl_fu_in.sv` | 81 | 把分组数组（`fu_alu_*`、`fu_mc_*` 等）按 `fu_idx` 收成每个 FU 一条 `xc_fu_res_t` |
| `exu_ctrl_fu_view.sv` | 67 | 把槽和 FU 结果合成统一的完成记录 `fu_done` |
| `exu_ctrl_port_arb.sv` | 46 | 口内仲裁：`ttg_first_set` 选第一个完成的 FU，`ttg_onehot_mux` 取出赢家，产生 `consume` |
| `exu_ctrl_ready.sv` | 49 | 每个 FU 的 `fu_ready` 和每口的 `fu_ready_mask` |
| `exu_ctrl_wb_prf.sv` | 84 | 旁路和寄存器写回总线（`WB_LANES = 13` 条通道） |
| `exu_ctrl_wb_rob.sv` | 80 | 完成报告 |
| `exu_ctrl_br_arb.sv` | 67 | 分支号释放和最老误预测的选择 |
| `exu_ctrl_csr_req.sv` | 41 | CSR 槽 → `exe2csr` |
| `exu_ctrl_lsu_req.sv`、`exu_ctrl_lsu_out.sv` | 55、96 | AGU / SDU 完成 → LSU 请求；`lsu_out` 只是端口适配 |
| `exu_ctrl_fu_out.sv` | 173 | 槽里的指令 → 各 FU 组的输入端口 |

状态：每个 FU 一个槽，共 31 个，每个槽一位 `valid_q` 加一份 `xc_inst_t`（28 个字段）；另有 `csr_idx_q`（12 位，只对应 CSR 槽）。本模块没有别的寄存状态。FU 自己的状态（MUL 流水、DIV 迭代等）在 `exu_fu`。

`exu_ctrl_slot` 里一个槽怎么走：`fu_en = valid_q && !flush && !被杀`；`load` = 本口这拍有发射、没被 flush、没被误预测杀、而且操作类属于这个 FU 的能力（同一口上各 FU 的操作类互不相交，所以装哪个槽没有歧义）；次态 `valid_d = (fu_en && !fu_ready) || load`，载荷 `load ? 发射结果 : 原值`，`br_mask` 每拍先清掉 `clear_mask`。

## 5. 一拍内的数据流

### 5.1 槽和交给 FU 的内容

1. 读寄存的槽：`fu_en` 如上；`fu_occ = valid_q`（不看是否被杀）；交给 FU 的指令副本 `fu_inst` 是槽里的指令，`br_mask` 已清掉本拍的 `clear_mask`。
2. `fu_en` 为 1 的槽把操作数送到对应 FU（`exu_ctrl_fu_out`）。浮点 FU 还带三个浮点源，STD 的 `amo_w` 取 `func3 == 2`。
3. 单周期 FU（ALU、BRU、AGU、SDU、CSR）这一拍就完成，`complete = fu_en`；多周期 FU（MUL、DIV、浮点）用自己的 `complete`。

### 5.2 口内仲裁

每个口：`complete_vec` = 本口各 FU 的 `complete`；`ttg_first_set` 取编号最小（即优先级最高）的完成者，它的 `consume` 为 1，没被选中的 FU 这拍结果不被取走。同拍两个 FU 在一个口上完成靠 ISU 的完成周期预留避免（见 isu.md 的 `isu_wb_gate`），所以仲裁只是兜底；MUL 的结果只在完成那一拍有效，更依赖这条预留。口 0..5 还要记下赢家是不是 CSR（`win_is_csr`）。

### 5.3 ready

`fu_ready`：单周期 FU 为 `!fu_en || consume`；多周期 FU 取 FU 自己给的 `ready`（它已经算过本拍的取走和接收）。每口的 `fu_ready_mask` = 本口所有"槽空（`!fu_en`）或 FU ready"的 FU 的操作类之并；`flush`（推迟一拍的那个）为 1 时整口清零。

### 5.4 写回、完成报告、LSU 请求

- **旁路**：每个 FU 一路，`valid = complete`，不管赢没赢口。CSR FU 的旁路值在 CSR 槽正在读时换成 `csr2exe_rdata`。
- **`exe2prf_entry`**（寄存器写回总线，`WB_LANES = 13` 条通道，EXP-046）：通道 0..5 = ALU 口 0..5 的赢家、通道 10..12 = 浮点口 18..20 的赢家，`valid = 赢家完成且有目的寄存器`，结果取赢家（ALU 口上赢家是 CSR 且 `exe2csr_re` 时换成 CSR 读数据）；通道 6..9 = LSU 的 4 路 load 写回请求（含 SC），浮点结果按 `is_w` 做 NaN-boxing（`fp_load_data`）。STA / STD / BR 口不写寄存器，没有通道（STA 的完成只走 `exu2rob`）。
- **`exu2rob_entry`**：load / STA 口取 LSU 写回，被 flush 或被误预测杀的丢掉；其余口直接取赢家的完成（FU 自己已经把被杀的项清掉，不会报被杀的完成）。分支口带 `diag_val`、`mispred`、`br_taken`，浮点口带 `fflags`、`illegal`。
- **LSU 请求**：load AGU 的完成 → `exe2lsu_ldu_req`，STA AGU → `exe2lsu_sta_req`，SDU → `exe2lsu_sdu_req`；这三类 FU 各独占一个口，完成就是请求。

### 5.5 分支

`exu_ctrl_br_arb`：每个 BRU 完成就把 `1 << br_id` 并入 `clear_mask`；有误预测的 BRU 之间两两比较谁更老（`{rob_flag, rob_idx}` 做 8 位差，差在 `(0, ROB_NUM)` 内为"更老"），最老的那条被选出，同龄取编号小的（和模型逐个扫描、新的更老才替换一致）；`exu2id_redirect_pc` 等取自它的完成记录。

### 5.6 CSR 请求

CSR 槽有效时：`we = csrrw 族 || imm != 0`，`re = !csrrw 族 || dest_preg != 0`（csrrw 族指 `func3` 为 001 或 101），`idx` 取槽里存的 `csr_idx`，`wdata` 在 `src2_is_imm` 时取立即数、否则取 `src1_rdata`，`wcmd = func3[1:0]`。CSR 槽被口 0 上更高优先级的 MUL 挤住时，请求每拍重复发出，值不变（槽里的内容不变）。

## 6. 关键路径与深度

单模块综合深度 **17 层**（exu_ctrl；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_slot.g_slot[24].slot_q [20]` 到 `\exu2id_ftq_idx [1]`。，本模块没有单独综合过。以下是从代码读出的，未综合验证：

| 路径 | 内容 |
| --- | --- |
| 槽 → FU → 口内仲裁 → 写回 | `valid_q / slot_q` → `fu_en`、`fu_inst` → FU 运算（ALU 最深）→ `fu_done` → `ttg_first_set` 和对 `$bits(xc_done_t)` 位的 `ttg_onehot_mux` → `win` → `exe2prf_entry`（CSR 读数据多一级选择）；同一个 `fu_done.result` 还作为旁路送 PRF，在 PRF 里和下一条指令的读出比较，再进下一拍的槽 |
| 完成 → ready → ISU | `fu_en`（单周期）或 FU 的 `complete` → `consume` → `fu_ready` → `fu_ready_mask` → ISU 的 `cand_valid` / `grant_valid`，ISU 已经是最深的一环 |
| 分支解析 → 重定向 | BRU 比较 → `mispred` → `exu_ctrl_br_arb` 两两比较老 → `exu2id_mispred`；之后经 IDU 变成 `dec_bcast_mispred`，进 `exu_ctrl_slot` 的 `fu_en` 和各 FU 的杀死逻辑，同时进 ISU、PRF、LSU、DTLB |

本分支和深度有关的改动：全局 flush 晚一拍到达（`803692f`，docs/FLUSH_REG.md）使 `rob_bcast_flush` 不再来自 ROB 提交路径；`e49618c` 的 `*_req_occ` 直接取槽的 `valid_q`，不经杀死逻辑。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- **FU 的运算**：模型 `fu::compute` 里 AGU 地址、STD 数据、分支结果都取自 trace 的事实，RTL 真算（`exu_fu`），由逐条提交的函数模型检查（fm_gate）保证一致；
- **`tbhook::on_exec`、`MSD_TRACE` 打印、`Assert`**：RTL 不带；模型 `Exu::seq` 里"没有空槽可装"的断言，RTL 靠操作类互不相交加 ISU 只发 ready 的类保证；
- **`br_type`**：模型 `exu2id.br_type` 由 Exu 根据 JAL / JALR 和寄存器号算（call / ret / 间接）；RTL 的 `exu2id_*` 没有这一项，`out_rf_type` 在 `pre_idu_queue` 里读出（`pre_idu_queue.sv`），本文没有核对两者结果是否一致；RTL 另有 `exu2id_br_pc`、`exu2id_br_is_rvc`（取自 BRU 完成记录），模型里 `rf_pc` 在 `Rob::redirect` 里从 FTQ 取；
- **PRF 写回**：模型没有寄存器堆，`exe2prf.entry` 同样按通道编号但只填 ALU 和 load 通道，RTL 的浮点通道 10..12 写浮点寄存器堆；
- **模型 `FuUnit` 的三种模式**（`SINGLE`、`PIPE` 环形队列、`ITER` 忙到 `done`）：RTL 的单周期 FU 没有状态，PIPE 对应 `exu_fu` 的 `mul_pipe`，ITER 对应 `exu_iter_ctl`，槽释放条件相同（单周期：被取走；PIPE：没满；ITER：不忙）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- 被杀的指令也占 AGU 槽：`*_req_occ` 看槽的 `valid_q`（模型 `ExeLsuReqEntry::raw`），LSU 的重放口分配要看它，不能看杀死之后的 `valid`；
- 分支口赢家的 `exu2rob` 不再判"是否被 flush / 杀"：模型判了，但单周期 FU 的 `fu_en` 已含这两条，多周期 FU 在自己里面先杀再报完成，所以模型里该判断对 FU 路径恒为假；LSU 写回路径的判断是真的，RTL 保留；
- 旁路广播不判口仲裁结果，也不判是否被误预测杀；被杀的写回由 PRF 的写回级自己丢。

未核对（继承自旧文档）：

- 旧文档的真实程序覆盖统计和变异检查结果（trace 回放体系随 `spec/` 一起退役，没有重跑）；
- 旧文档关于"MUL 在口内最高优先级才避免重复接收"的疑点：本文只核对了 `mul_pipe` 的接收条件在取走之前判满（`accept = en && !(&surv)`，与模型 `PIPE` 先推再弹一致），没有推演所有时序。

代码里的小问题（没有改）：`exu_ctrl_wb_rob.sv`、`exu_ctrl_lsu_*.sv`、`exu_ctrl_port_arb.sv` 的注释还写着"22 个写回口"、"口 6..13"、"agu 0..3 loads, 4..7 store-address"、"MUL > DIV > LD > STA > STD > BR > ALU > CSR > FP"（现在是 21 口、load 4 个、STA 3 个、优先级里还有 I2F）；`exu_ctrl_pkg.sv` 里 `N_AGU` 的注释同样过时；`exu_ctrl_br_arb.sv`、`exu_ctrl_wb_rob.sv` 注释里的"notes 4.2-1"指旧文档的一节，新文档没有这一节。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）。其中名字对得上本模块特殊路径的有：`csr-alias-boundary`（CSR 槽）、`atomic-boundary`（STD 的 AMO）、`mul-longlong`、`div`（口 0..3 的 MUL / DIV）、`fd-*`（浮点口）；其余程序都经过口内仲裁、旁路和分支解析。没有逐个核对每个程序实际覆盖了哪些路径。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **浮点**：`tests/fp_chain`（`rv64imafd` 小程序在 RTL 上逐提交检查，要 F/D 配置的构建）。
- **没有模块级的独立测试**：旧体系（trace 回放、随机 trace、变异）已随 `spec/`、`tests/exu_ctrl` 退役。目前靠整核周期逐拍相等和 Linux 启动。**待补**：口内仲裁和 `exu_ctrl_br_arb` 各补一个和模型行为并排的随机测试（口 0 上 CSR 与 MUL 同拍完成、同拍多个 BRU 误预测、被杀的 AGU 槽的 `*_req_occ`）。

## 9. 参数与开关速查

`ISSUE_WIDTH`、`TOTAL_FU_COUNT`、`ALU_NUM`、`BRU_NUM`、`LSU_LDU_COUNT`、`LSU_STA_COUNT`、`LSU_SDU_COUNT`、`LSU_AGU_COUNT`、`LSU_LOAD_WB_WIDTH`、`IQ_*_PORT_BASE`、`FPRF_NUM`（决定 `FP_EN`，`ttg_cfg_pkg`）；`N_MC`、`N_FPU`、`XC_OP_NUM`、`CSR_FU`、`CSR_PORT`、`xc_port_cap()`（`exu_ctrl_pkg`，手写）。没有运行时开关。

## 10. 变更记录

- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`exu_ctrl_pkg`（`xc_inst_t` / `xc_done_t`）、`exu_ctrl_fu_view`、`exu_ctrl_br_arb`、`exu_ctrl` 透传 4 位 `ftq_offset`（`prf2exe_iss_entry_uop_ftq_offset` → `exu2id_ftq_offset`），供后端误预测精确索引双块 FTQ（避免同 PC 在 Block A/B 重复时的歧义）；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗对齐。
- 2026-11-19（`exp/wb-presel`，EXP-046）：`exu_ctrl_wb_prf` 输出按通道编号的写回总线（`WB_LANES = 13`：ALU 6、load 4、浮点口 3），不再按发射口输出 21 路；STA 写回不再进写回总线（`sta_wb` 只给 `exu_ctrl_wb_rob`）。周期不变。
- 2026-11-18（exp/agu-share，`261bd67..HEAD`）：
  - `e49618c`：AGU 槽的占用 `exe2lsu_ldu_req_occ`、`exe2lsu_sta_req_occ`（`exu_ctrl_slot` 的 `fu_occ`，经 `exu_ctrl_lsu_out`）；LSU 重放口的分配看它（模型 `ExeLsuReqEntry::raw`），周期对 `ref_cycles_memiq6_nr_int2_ev2.txt`；
  - `803692f`：`rob_bcast_flush` 现在来自 `back_top` 的 `rob_flush_q`（晚一拍），本模块自身没改，见 docs/FLUSH_REG.md。
- 更早：见 git 历史。
