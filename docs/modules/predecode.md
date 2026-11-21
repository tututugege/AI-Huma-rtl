---
module: predecode
area: frontend
rtl: rtl/frontend/predecode.sv、predecode_lane.sv、predecode_checker.sv、rvc_expand.sv、sequential_next_pc.sv、front_head_fix.sv、front_pd_info.sv、front_slot_kind.sv
model: trace-model front-end/front_checker.h、predecode_checker.cpp、predecode.cpp、front_top.cpp（调度单元 `front.core.checker`，类 `FrontChecker`，阶段 `comb`；展开 / 预译码 / 顺序下一 pc 在 `InstPort::comb_write`，头修正在 `InstPort::comb_read`）；function-model/include/rvc.h（`rvc::expand`）
status: 整核周期与模型逐个相等（EXP-051 里程碑 B：fm_gate 68/68 + Linux 27 窗，零环境变量）
depth: 27 层 / 10,144 单元（predecode，单模块综合，2026-11-21，`SYNTH_ABC="strash;balance;map"`，较 main 29 层 / 11,780 单元降 2 层）
---

# predecode 设计文档（预译码、头修正、预测检查）

> **EXP-051 里程碑 B 升级**：
> 1. `predecode` 支持每槽独立 `slot_pc[FETCH_WIDTH]`（兼容 Block A + Block B 不连续 PC）；
> 2. `front_head_fix` 接收 S2-mux 及 PC 对齐截断后的 `slot_pc[FETCH_WIDTH]`、`up16`、`up_ok`，按实际段末槽计算 `group_end_pc`、`complete` 与 `seq_next_o`；
> 3. `predecode_checker` 新增多段模式（`multi`、`in_range`、`seg_first`、`slot_pc`、`inst_valid`、`is_rvc`），逐段核验 `corrected != claimed || (!last && (ft != e || !inst_valid[e+1]))`，并输出截断槽数 `keep_n`；
> 4. `front_pd_info` 支持双段历史符号拼接（至多 2 个 taken 槽 = 6 位历史）、双 RAS 操作（`pd_ras_op2 / pd_ras_val2`）以及按 PTAB 段基址输出的 `pd_nb_base`（避免 RVC 携带块 `pc0 = base - 2` 导致清槽失配）。

## 1. 职责

I-Cache 回来的一个取指组（16 个 2 字节的槽）在进入后端之前要经过几步处理，RTL 里分在两个位置：

**取指侧**（组刚从 I-Cache 回来，写指令队列之前，在 `front_fetch_buf`，见 [front_top.md](front_top.md)）：

1. `rvc_expand`：窗口低两位不是 `11` 的是 16 位压缩指令，展开成等价的 32 位指令（非法编码展开成 0，后端会报非法指令）；
2. `predecode`（16 个 `predecode_lane`）：对每个有效槽判断是 JAL、条件分支、JALR 还是别的，并算直接目标（JAL 和条件分支是 `pc + 立即数`，JALR 没有直接目标）；
3. `sequential_next_pc`：顺序执行时下一个取指块的地址 = 取指块起点 + 2 × 有效槽前缀长度，跨 64 字节缓存行时截到下一行起点。

**检查侧**（指令队列队首和 PTAB 队首一起读出，在 `front_pred_path`）：

4. `front_head_fix`：处理 16 位 / 32 位混排带来的组间"携带"：上一组末尾一条 32 位指令只有前半在上一组时，本组槽 0 是它的后半，要把两半拼起来；非指令起点的槽作废；末槽开头的 32 位指令要么按预测完整送出、要么不送出而把前半留给下一组；
5. `predecode_checker`：用预译码结果检查 BPU 的预测：取第一个"确实跳"的槽，它的目标（JAL / 条件分支用预译码算出的目标，JALR 沿用 BPU 的目标）应当等于 BPU 预测的下一取指地址；不等就是一次预译码冲刷（predecode flush），下一拍用修正后的地址重取；
6. `front_pd_info`：把检查结果登记一拍后告诉 BPU（要不要丢最老的 PDCKPT 记录；冲刷时修正后那个块往历史和 RAS 里推什么）；
7. `front_slot_kind`：按指令位给每个槽译出 BPU 的分支类型，随组存进 front2back 队列，后端把它存进自己的 FTQ，误预测时带回来（RTL 独有的字段，见第 7 节）。

模型里 4–6 是一个调度单元 `front.core.checker`（`FrontChecker::comb`，头修正在 `InstPort::comb_read` 里，是另一个单元）；1–3 在 `InstPort::comb_write`。RTL 的模块边界是为综合划的。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| 取指组槽数 | 16 | `FETCH_WIDTH` |
| 槽宽 | 2 字节 | `SLOT_BYTES = 2` |
| 压缩指令 | 开；`rvc_expand` 的 `IS_RV64 = (XLEN_BITS == 64)`、`HAS_FP = (FPRF_NUM != 0)`（现行均为 1） | `RVC_ENABLE = 1` |
| 缓存行 | 64 字节 | `ICACHE_LINE_SIZE` |
| 预译码类型编码 | 非分支 0、条件分支 1（`DIRECT_JUMP_NO_JAL`）、JALR 2、JAL 3 | `front_pkg` |
| `slot_kind` 宽度 | 3 位 | `KIND_W`；取值 `BR_DIRECT / CALL / RET / IDIRECT / NONCTL / JAL / ICALL`（`bpu_pkg`） |
| 历史符号 | 每个跳转推 3 位 | `HSYM_W = 3`（`bpu_stage_pkg`） |

## 3. 接口

| 模块 | 输入 | 输出 |
| --- | --- | --- |
| `predecode` | `fetch_pc`、16 个指令字、`inst_valid` | 每槽 `predecode_type`、`predecode_target_address` |
| `predecode_lane` | 一个槽的 `pc`、指令字、`inst_valid` | 类型、目标（无效槽给 非分支 / 0） |
| `rvc_expand` | 16 位半字 | 32 位指令 |
| `sequential_next_pc` | `fetch_pc`、`inst_valid` | `seq_next_pc` |
| `front_head_fix` | 基址（PTAB）、指令队列队首各字段、PTAB 预测方向、携带寄存器 `lh_*` | 修正后的指令字 / 有效位 / 类型 / 目标 / `is_rvc`，`carry`、槽 0 的 pc、`straddle`、`carry_low`、`group_end_pc`、`seq_next_o` |
| `predecode_checker` | PTAB 的方向和下一地址、修正后的类型和目标、`seq_next_pc` | `predict_dir_corrected`、`predict_next_fetch_address_corrected`、`predecode_flush_enable` |
| `front_pd_info` | `checked`、`flush`、基址、`pc0`、`is_rvc`、指令字、类型、目标、修正后方向、PTAB 预测 | `pd_valid / flush / hv / hbits / ras_op / ras_val / nb_valid / nb_pc`（寄存一拍） |
| `front_slot_kind` | 一个指令字 | 3 位类型 |

`predecode`、`predecode_checker` 的 `clk / rst_n` 端口没有用（纯组合，只为满足顶层模块的端口约定）。

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `predecode.sv` | 30 | 16 个 `predecode_lane`，槽 i 的 pc = `fetch_pc + 2*i` |
| `predecode_lane.sv` | 45 | 一个槽：按操作码分类，JAL 的 21 位、条件分支的 13 位立即数符号扩展后加 pc |
| `rvc_expand.sv` | 171 | 16 位指令展开（RV64 含 c.addiw / c.subw / c.addw / c.ld / c.sd / c.ldsp / c.sdsp，开 FP 时含 c.fld / c.fsd 一族） |
| `sequential_next_pc.sv` | 45 | 第一个无效槽的下标 = 有效前缀长度；行尾截断 |
| `front_head_fix.sv` | 130 | 头修正（下面详述） |
| `predecode_checker.sv` | 64 | 检查器：`ttg_first_set` + 独热 mux |
| `front_pd_info.sv` | 131 | PDCKPT 信息：第一个 taken 槽的历史符号、RAS 操作 |
| `front_slot_kind.sv` | 30 | 译 BPU 分支类型 |

状态：只有 `front_pd_info` 里八个一拍寄存器（`pd_valid_q` 等）；`front_head_fix`、检查器等是纯组合。携带寄存器 `lh_valid_q / lh_pc_q / lh_data_q` 在 `front_pred_path.sv`（见 [front_top.md](front_top.md)）。

### front_head_fix

16 位和 32 位指令混排时，一个 32 位指令可能跨组：它的前半半字是上一组的最后一个槽，后半半字是本组的槽 0。约定（C910 风格的携带）：

- 上一组检查时发现自己最后有一条 32 位指令的前半（`straddle`），不送出它，把前半半字存进携带寄存器（`lh_data_q`），把"下一组应从哪个 pc 开始"存进 `lh_pc_q`；
- 本组到来时，若 `lh_valid & lh_pc == 本组基址 & 槽 0 有效`，则 `carry = 1`：槽 0 的指令 = `{本组 raw0, 携带的前半}`，pc = 基址 - 2，`is_rvc = 0`，用 `predecode_lane` 重新预译码；本组的指令起点按 `start_b`（槽 0 是后半，槽 1 开始）；否则按 `start_a`；
- 不是起点的槽作废（类型 非分支、目标 0）；
- 末槽（最后一个有效槽）如果是一条 32 位指令的开头（`chain & !is_rvc & !page_fault`），它的高半在下一组：若 BPU 预测它跳且这个槽的窗口里有真实高半字（`up_ok`），则按完整指令送出——此时取指已经走到目标，不送出就再也没人补全；顺序续接地址改成 `该槽 pc + 4`；否则不送出（`straddle`），前半进携带寄存器。

后端对携带槽的处理：front2back 队列只存基址和 `carry` 位，输出时槽 0 的 pc 是 `基址 - 2`（`front_pred_path` 里 `out_pc[0]`）。

### predecode_checker 的规则

- 逐槽修正方向：非分支 → 不跳；条件分支 → 用 BPU 的方向；JAL、JALR → 跳；
- 第一个"跳"的槽决定下一地址：JAL / 条件分支用它的预译码目标，JALR 沿用 PTAB 的下一地址；没有跳就用 `seq_next_pc`（头修正后的）；
- `predecode_flush_enable = (PTAB 的预测下一地址 != 修正后的下一地址)`。

### front_pd_info 的规则

`checked`（本拍检查器读了队首）寄存一拍成 `pd_valid`；冲刷时：第一个"跳"的有效槽的历史符号 `hsym_of(pc, 目标)`（JALR 的目标用 PTAB 的下一地址）；若它是 `rd = ra` 的 JAL，RAS 操作为"压栈，值 = pc + 指令长度"；若它是 `jalr x0, ra, 0`，RAS 操作为"弹栈"；另外找第一个"预测为跳但预译码是非分支"的槽（`nb_pc`），BPU 据此清掉类型预测器里的陈旧表项。

## 5. 一拍内的数据流

取指侧（纯组合，I-Cache 响应到指令队列写数据）：`ic_fetch_group[i]` → `rvc_expand`（只在低两位非 `11` 时取展开结果）→ 展开后的字送 `predecode_lane`；`ic_inst_valid` 的有效前缀 → `sequential_next_pc`。

检查侧（寄存器出发，指令队列读口 + PTAB 读口）：

1. `front_head_fix`：`carry` → 拼接槽 0 → 重预译码；`chain = carry ? start_b : start_a` → `keep` → 末槽判定（`straddle / complete`）→ 修正后的 `valid_o / ptype_o / ptarget_o`；`seq_next_o`；
2. `predecode_checker`：16 路 `taken` → 第一个 taken 的独热 → 目标 mux → 与 PTAB 的预测下一地址比较 → `predecode_flush_enable`；
3. 同拍 `front_slot_kind`（16 路）、`front_pd_info`（第一个 taken 槽的选择）；
4. 携带寄存器次态：`lh_new_valid = straddle & !any_taken & (!flush | 修正后下一地址 == group_end_pc)`，只在 `predecode_can_run`（检查器本拍真的读了队首）时更新，后端重定向或复位清零。

## 6. 关键路径与深度

单模块综合深度 **29 层**（predecode；predecode_checker 22 层；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\inst_valid [15]` 到 `\predecode_target_address [63]`。从代码读出的，未综合验证：这几个模块没有单独测过。最长的链在检查侧：指令队列读口 → `front_head_fix`（64 位 `lh_pc == base_pc` 比较 → `carry` → 槽 0 重预译码里的 pc + 立即数加法 → 选择）→ `predecode_checker`（16 路 `first_set` → 独热选 64 位目标 → 与 PTAB 的 64 位地址比较）→ `do_predecode_flush`；另有 `seq_next_o` 里 `complete_pc + 4` 的 64 位加法再进 checker 的 `seq_next_pc` 选项。`front_pd_info` 的第一个 taken 槽选择与检查器并行。

深度相关的改动：无（本轮没有动这些模块；指令起点扫描在 `front_fetch_buf`，见 [front_top.md](front_top.md)）。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `FE_PAIR`（一拍两块）相关：`multi`、`in_range`、`seg_first`、`keep_n`（只保留检查器认可的前缀）、`pair_on` 下按 pc 截断：RTL 没有，对应 `inst_valid & (i < keep_n)` 在 RTL 里就是 `valid_o`；
- 模型非 `FE_PAIR` 路径里"指令队列的 pc 与 PTAB 的 pc 不等就 `fatal`"的检查：**RTL 没有**。指令队列不存每槽 pc，也不存取指块起点，检查器用的 pc 全部来自 PTAB；I-Cache 回来的组与 PTAB 项是否对得上，RTL 里不检查（靠取指地址队列、PTAB 同序、同时清空保证）；
- `predecode()` 里 `inst == 0 || inst == INST_NOP` 直接判非分支：RTL 不需要特判，这两个字的操作码本来就不是 JAL / 分支 / JALR；
- 模型的 `rvc_head_fix` 里 `last >= (carry ? 1 : 0)`：RTL 里 `chain[0]`（`start_b[0] = 0`）使携带时槽 0 不会被当成末槽的前半，两者等价；
- `lh_new_pc`：RTL 用 `group_end_pc = 基址 + 2 * 有效槽数`，模型用头修正后 `pc[n-1] + 2`；二者只在携带且只有槽 0 有效时不同（模型 = 基址，RTL = 基址 + 2），这种情形没有 `straddle`，`lh_new_valid = 0`，不影响行为。

RTL 独有的：

- `front_slot_kind`：模型的后端自己从指令译 `br_type`（`back-end/Rob.cpp` 里 `rf_type = idu_br_latch->br_type`）；RTL 的后端 FTQ（`pre_idu_queue`）用前端随组带来的 `slot_kind` 记每槽类型，误预测时带回前端。规则同后端提交侧分类（`front_slot_kind.sv` 头注释写明参考 `Exu::comb_fu2exu_collect` 和 `class_br_type`，本轮没有逐行对照）。

RTL 与模型保持一致的细节（容易误判为 bug）：

- JALR 在检查器里恒当"跳"，但目标沿用 BPU 的；所以 JALR 的目标不对不会引起预译码冲刷，由后端发现后重定向；
- 预测为"跳"但预译码是非分支的槽，检查器把它当不跳（`predict_dir_corrected = 0`），下一地址退回顺序续接，这就是一次冲刷，同时 `nb_pc` 告诉 BPU 清类型表项；
- 无效槽的类型是 非分支、目标 0（`valid_o` 为 0 时在 `front_head_fix` 里清）。

未核对（继承自旧文档）：

- 旧文档（front_basic.md 第 4 节）说模型里的 `exit(1)` 自检（含 `fifo.pc != ptab.pc`、`predecode_type` 的 default 分支）在 RTL 里"不可达或调试用"所以不建：现行代码里确实没有这些检查（已核对），"不可达"的理由没有重新证明；
- 旧文档说 `sequential_next_pc` 对应 `CONFIG_FRONT_VALID_PREFIX_SEQ_NEXT = 1`：现行模型 `sequential_next_pc()` 只有这一种写法，该开关已不存在，`sequential_next_pc.sv` 头注释里的行号和开关名是旧的。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比 function-model，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`：67/67 通过。展开（`rvc_expand`）的正确性靠逐条提交对比 function-model（指令字被展开后执行，结果不对会立刻比出来）；头修正、携带、检查器靠周期逐个相等和提交流对。`fence-i-self-modify`、`itt-dispatch`、`coremark`、`dhrystone` 是前端检查链上最密的程序。
- **Linux**：全程 Linux（rv64gc，含压缩指令的内核和用户态）：`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`；PT / UP 指纹 `scripts/align_check.sh`。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧体系的 spec 回放、随机 trace、变异检查（旧文档记录过 34 个变异）已随 `spec/` 退役。**待补**：（1）`rvc_expand` 对 `rvc::expand` 的穷举对拍（只有 65536 个半字，几秒钟能做完）；（2）`front_head_fix` + 检查器对一个直译模型（`rvc_head_fix` + `predecode_check`）的随机对拍，覆盖携带、末槽完整 / 不完整、冲刷后续接。

## 9. 参数与开关速查

`RVC_ENABLE`（0 时 `front_head_fix` 直通，`icache_resp` 走按字取指的分支；未用于当前配置，也未验证）、`FETCH_WIDTH`、`SLOT_BYTES`、`ICACHE_LINE_SIZE`、`XLEN_BITS`、`FPRF_NUM`（`rvc_expand` 的 `HAS_FP`）；`front_pkg` 的 `PREDECODE_*` 编码和 `KIND_W`。

## 10. 变更记录

- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`predecode` 支持每槽独立 `slot_pc[FETCH_WIDTH]`；`front_head_fix`、`predecode_checker`、`front_pd_info` 升级支持双块多段（`multi`/`in_range`/`seg_first`/`keep_n`、双历史符号/双 RAS 操作、`pd_nb_base` 修复 RVC 携带假分支清槽）。Yosys 综合 `predecode` 10,144 单元 / 27 层（原 11,780 / 29）；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差，含 `directed/fe_2taken_fdip.bin`）与 Linux 27 窗检查点对齐。
- 2026-11-18（exp/agu-share）：本组文件没有改动；指令起点前缀扫描（`front_fetch_buf`）见 front_top.md。
- 2026-11-14/15：RVC 前端：C910 风格的携带取代 I-Cache 第二行（`e784f05`）、RVC=1 的非压缩程序周期与 `ref_cycles_rvc.txt` 相等（`f8feff3`）、模型三处预测修正（`1a3d458`）；设计说明见 docs/RVC_RTL.md。
- 更早：见 git 历史。
