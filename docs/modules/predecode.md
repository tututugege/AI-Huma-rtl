---
module: predecode
area: frontend
rtl: rtl/frontend/front_head_fix.sv、rvc_expand.sv、predecode_lane.sv、predecode_checker.sv、front_pd_info.sv（front_slot_kind.sv 2026-11-29 清理 F 起不再使用）
model: trace-model front-end/front_checker.h、predecode_checker.cpp、predecode.cpp、front_top.cpp（调度单元 `front.core.checker`，类 `FrontChecker`，阶段 `comb`；展开 / 预译码 / 顺序下一 pc 在 `InstPort::comb_write`，头修正在 `InstPort::comb_read`）；function-model/include/rvc.h（`rvc::expand`）
status: 整核周期与模型逐个相等（fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: 27 层 / 10,144 单元（predecode，单模块综合，2026-11-21，`SYNTH_ABC="strash;balance;map"`，较 main 29 层 / 11,780 单元降 2 层）
---

# predecode 设计文档（预译码、头修正、预测检查）

> **EXP-053 前端结构清理（Phase 1 + P2-2）升级**：
> - `front_head_fix` 承接来自 `inst_fifo` 的紧凑原始半字流，统一做单份 `rvc_expand` + `predecode` 及 4 轮 Kogge-Stone `start_a`/`start_b` 前缀扫描（`` `ifdef SYNTHESIS `` 综合走并行树、仿真走快速扫描，与 `fe_clean_eq_tb` 65,536 全枚举双路径零差异），并用按 64B 行掩码对齐的 `s1_seq` 兼容错路奇地址；
> - 跨 4KB 页 RVC 第二半字取指缺页改为输出显式 1-bit `pf_inst_hi`（替代原先写 `insts_o[0]=32'd2` 借 `diag_val[1]` 透传）；
> - `front_pd_info` 复用公用 `ttg_first_set` / `ttg_onehot_mux`（原 `ttg_pick_k K=2` 在 2026-11-29 清理 C 换成 `ttg_first_set`）（继承 `rtl/common` 双路径加速），`predecode_checker` 与新 `front_head_fix` 零周期偏差对齐。
>
> **EXP-051 里程碑 B 升级**（历史；EXP-070 起 BPU 不再产生双块，其中 3、4 两条的多段 / 双符号 / 双 RAS / `pd_nb_base` 已在 2026-11-29 清理 C 删除，只剩单段规则）：
> 1. `predecode` 支持每槽独立 `slot_pc[FETCH_WIDTH]`（兼容 Block A + Block B 不连续 PC）；
> 2. `front_head_fix` 接收 S2-mux 及 PC 对齐截断后的 `slot_pc[FETCH_WIDTH]`、`up16`、`up_ok`，按实际段末槽计算 `group_end_pc`、`complete` 与 `seq_next_o`；
> 3. `predecode_checker` 新增多段模式（`multi`、`in_range`、`seg_first`、`slot_pc`、`inst_valid`、`is_rvc`），逐段核验 `corrected != claimed || (!last && (ft != e || !inst_valid[e+1]))`，并输出截断槽数 `keep_n`；
> 4. `front_pd_info` 支持双段历史符号拼接（至多 2 个 taken 槽 = 6 位历史）、双 RAS 操作（`pd_ras_op2 / pd_ras_val2`）以及按 PTAB 段基址输出的 `pd_nb_base`（避免 RVC 携带块 `pc0 = base - 2` 导致清槽失配）。

## 1. 职责

I-Cache 回来的取指组（16 个 2 字节的槽，原始半字；跨行 A / B 已在写入前由 `front_fetch_buf` 合并，存在 `inst_fifo` 里）在送后端之前要经过预译码检查，全部在检查侧（`inst_fifo` 队首和统一 FTQ 的 `pd_ptr` 项一起读出，在 `front_pred_path`，见 [front_top.md](front_top.md)）：

1. `front_head_fix`：
   - 槽窗口：槽 i 的 32 位窗口 = 槽 i+1 有效时 `{half[i+1], half[i]}`，否则 `{0, half[i]}`（末槽之上的半字 `up16` 由条目带来；跨行 A / B 合并在队列前的 `front_fetch_buf`，见 [front_top.md](front_top.md)）；
   - 单份 `rvc_expand`（窗口低两位不是 `11` 的是 16 位压缩指令，展开成等价的 32 位指令，非法编码展开成 0）和 `predecode_lane`（前端唯一的分支译码：BPU 类别 `BR_*` + 直接目标；检查器的 2 位类型由类别导出）；
   - 指令起点扫描（`start_a / start_b`，4 轮前缀扫描）；按 FTQ 项的 pc（`pd_base_pc`，接 `ftq2fe.pd_base_pc`）截断；
   - 16 位 / 32 位混排带来的组间"携带"（见下）、跨页 RVC 第二半字缺页（`pf_hi_o`）、末槽 32 位指令的处理、顺序续接地址 `seq_next_o`；
2. `predecode_checker`：用预译码结果检查 FTQ 里的 BPU 预测：取第一个"确实跳"的槽，它的目标（JAL / 条件分支用预译码目标，JALR 沿用 BPU 的目标）应当等于预测的下一取指地址；不等就是一次预译码冲刷，下一拍用修正后的地址重取；
3. `front_pd_info`：把检查结果登记一拍后告诉 BPU（丢不丢 PDCKPT 记录；冲刷时修正后的块往历史和 RAS 里推什么）；
4. 槽类别：`front_head_fix` 的 `kind_o`（送出的指令字的 `BR_*` 类别，缺页槽为 `NONCTL`）写进 FTQ（`fe2ftq_pd.slot_kind`），误预测时由 `ftq_bpu` 读回给前端（RTL 独有，见第 7 节；原来的 `front_slot_kind` x16 从送出的指令字再译一遍，2026-11-29 清理 F 并入 `predecode_lane`）。

模型里 2–3 是调度单元 `front.core.checker`（`FrontChecker::comb`），1 在 `InstPort::comb_read`。RTL 的模块边界是为综合划的。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| 取指组槽数 | 16 | `FETCH_WIDTH` |
| 槽宽 | 2 字节 | `SLOT_BYTES = 2` |
| 压缩指令 | 开；`rvc_expand` 只译 rv64 编码，`HAS_FP = (FPRF_NUM != 0)`（现行为 1） | `RVC_ENABLE = 1` |
| 缓存行 | 64 字节 | `ICACHE_LINE_SIZE` |
| 预译码类型编码 | 非分支 0、条件分支 1（`PREDECODE_BRANCH`）、JALR 2、JAL 3；由类别导出：`front_pkg::ptype_of_kind`（DIRECT → 1，CALL / JAL → 3，RET / ICALL / IDIRECT → 2，NONCTL → 0） | `front_pkg` |
| `slot_kind` 宽度 | 3 位 | `KIND_W`；取值 `BR_DIRECT / CALL / RET / IDIRECT / NONCTL / JAL / ICALL`（`bpu_pkg`） |
| 历史符号 | 每个跳转推 3 位 | `HSYM_W = 3`（`bpu_stage_pkg`） |

## 3. 接口

| 模块 | 输入 | 输出 |
| --- | --- | --- |
| `front_head_fix` | `inst_fifo` 队首 `inst_e`、FTQ 项的 `pd_base_pc`、预测方向、携带寄存器 `lh_valid / lh_pc / lh_data` | 修正后的指令字 `insts_o`、`valid_o`、`pf_o`、`pf_hi_o`、`ptype_o`（无效槽 0）、`kind_o`（`insts_o` 的 `BR_*`，每个槽都给）、`ptarget_o`、`is_rvc_o`、`slot_pc_o`、`pd_pc_o`、`carry`、`straddle`、`carry_low`、`group_end_pc`、`seq_next_o` |
| `rvc_expand` | 16 位半字 | 32 位指令 |
| `predecode_lane` | `pc`、32 位指令字 | `kind`（3 位 `BR_*`）、`target`（JAL / 条件分支 = pc + 立即数，否则 0） |
| `predecode_checker` | 预测方向和下一地址、修正后的类型和目标、`seq_next_pc` | `predict_dir_corrected`、`predict_next_fetch_address_corrected`、`predecode_flush_enable` |
| `front_pd_info` | `checked`、`flush`、`slot_pc`、`is_rvc`、`kind`、`inst_valid`、类型、目标、修正后方向、预测方向、`pd_next_pc` | `pd_valid / flush / hn（1 位）/ hbits（3 位）/ ras_op / ras_val / nb_valid / nb_pc`（寄存一拍） |

`predecode_checker` 是纯组合，没有 `clk / rst_n` 端口（2026-11-28 删掉了原来未用的这两个口）。

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `front_head_fix.sv` | 282 | 头修正：槽窗口、单份展开与分支译码（18 个 `predecode_lane`：16 槽 + 携带拼接 + 末槽完整指令）、起点扫描、FTQ pc 截断、携带、末槽、`seq_next_o` |
| `rvc_expand.sv` | 148 | 16 位指令展开（只 rv64：含 c.addiw / c.subw / c.addw / c.ld / c.sd / c.ldsp / c.sdsp，开 FP 时含 c.fld / c.fsd 一族） |
| `predecode_lane.sv` | 37 | 分支译码：`BR_*` 类别（条件分支、`rd = ra` 的 JAL = CALL、其他 JAL、`jalr x0, ra, 0` = RET、`rd = ra` 的 JALR = ICALL、其他 JALR）+ JAL 的 21 位 / 条件分支的 13 位立即数符号扩展后加 pc |
| `predecode_checker.sv` | 49 | 检查器：第一个 taken 槽（`ttg_first_set` + 独热选择）决定修正后的下一地址 |
| `front_pd_info.sv` | 124 | PDCKPT 信息：第一个 taken 槽的历史符号（至多 1 个，3 位）、一组 RAS 操作、`nb_pc` |

状态：只有 `front_pd_info` 里的一拍寄存器（`pd_valid_q` 等）；`front_head_fix`、检查器等是纯组合。携带寄存器 `lh_valid_q / lh_pc_q / lh_data_q` 在 `front_pred_path.sv`（见 [front_top.md](front_top.md)）。

### front_head_fix

16 位和 32 位指令混排时，一个 32 位指令可能跨组：它的前半半字是上一组的最后一个槽，后半半字是本组的槽 0。约定（C910 风格的携带）：

- 上一组检查时发现自己最后有一条 32 位指令的前半（`straddle`），不送出它，把前半半字存进携带寄存器（`lh_data_q`），把"下一组应从哪个 pc 开始"存进 `lh_pc_q`；
- 本组到来时，若 `lh_valid & lh_pc == 本组基址 & 槽 0 有效`，则 `carry = 1`：槽 0 的指令 = `{本组 half[0], 携带的前半}`，pc = 基址 - 2，`is_rvc = 0`，用 `predecode_lane` 重新预译码；本组的指令起点按 `start_b`（槽 0 是后半，槽 1 开始）；否则按 `start_a`；
- 不是起点的槽作废（类型 非分支、目标 0）；
- 末槽（最后一个有效槽）如果是一条 32 位指令的开头（`chain & !is_rvc & !page_fault`），它的高半在下一组：若 BPU 预测它跳且这个槽的窗口里有真实高半字（`up_ok`），则按完整指令送出——此时取指已经走到目标，不送出就再也没人补全；顺序续接地址改成 `该槽 pc + 4`；否则不送出（`straddle`），前半进携带寄存器。

后端对携带槽的处理：预译码把 `pc0`（携带时 = 基址 - 2）和 `carry` 写进 FTQ（`fe2ftq_pd`），后端读 pc 时由 FTQ 重建。

### predecode_checker 的规则

- 逐槽修正方向：非分支 → 不跳；条件分支 → 用 BPU 的方向；JAL、JALR → 跳；
- 第一个"跳"的槽决定下一地址：JAL / 条件分支用它的预译码目标，JALR 沿用 FTQ 里的预测下一地址；没有跳就用 `seq_next_pc`（头修正后的）；
- `predecode_flush_enable = (FTQ 里的预测下一地址 != 修正后的下一地址)`。

### front_pd_info 的规则

`checked`（本拍检查器读了队首）寄存一拍成 `pd_valid`；冲刷时：第一个"跳"的有效槽的历史符号 `hsym_of(pc, 目标)`（JALR 的目标用 FTQ 里的预测下一地址）；若它的类别是 `BR_CALL`（`rd = ra` 的 JAL），RAS 操作为"压栈，值 = pc + 指令长度"；若是 `BR_RET`（`jalr x0, ra, 0`），RAS 操作为"弹栈"（这一支走不到：第一个 taken 槽是 JALR 时修正后的下一地址就是预测的下一地址，不会冲刷；保留与模型一致）；另外找第一个"预测为跳但预译码是非分支"的槽（`nb_pc`），BPU 据此清掉类型预测器里的陈旧表项。

## 5. 一拍内的数据流

检查侧（寄存器出发：`inst_fifo` 读口 + FTQ 的 `pd_ptr` 寄存视图）：

1. `front_head_fix`：槽窗口 → 16 路展开与分支译码 → `carry`（`lh_valid & lh_pc == 本组基址 & 槽 0 有效`）→ 拼接槽 0 → 重预译码；`chain = carry ? start_b : start_a` → FTQ pc 截断 → 末槽判定（`straddle / complete`）→ 修正后的 `valid_o / ptype_o / ptarget_o`；`seq_next_o`；
2. `predecode_checker`：16 路 `taken` → 第一个 taken 的独热 → 目标选择 → 与 FTQ 的预测下一地址比较 → `predecode_flush_enable`；
3. 同拍 `front_pd_info`（第一个 taken 槽的选择）、`front_pred_path` 里第一个修正后跳转之后的截断（`pd_cut_valid`）；
4. 携带寄存器次态：`lh_new_valid = straddle & !组内有 taken & (!flush | 修正后下一地址 == group_end_pc)`，只在 `predecode_can_run` 时更新，后端重定向或复位清零。

## 6. 关键路径与深度

单模块综合深度 **27 层 / 10,144 单元**（predecode，2026-11-21，EXP-053 之后，较当时 main 29 层 / 11,780 单元降 2 层；`SYNTH_ABC="strash;balance;map"`）。更早一次：**29 层**（predecode；predecode_checker 22 层；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\inst_valid [15]` 到 `\predecode_target_address [63]`。从代码读出的，未综合验证：这几个模块没有单独测过。最长的链在检查侧：指令队列读口 → `front_head_fix`（槽窗口 → 展开 / 分支译码 → 64 位 `lh_pc == base_pc` 比较 → `carry` → 槽 0 重预译码里的 pc + 立即数加法 → 选择）→ `predecode_checker`（16 路 `first_set` → 独热选 64 位目标 → 与 FTQ 预测的 64 位地址比较）→ `do_predecode_flush`；另有 `seq_next_o` 里 `complete_pc + 4` 的 64 位加法再进 checker 的 `seq_next_pc` 选项。`front_pd_info` 的第一个 taken 槽选择与检查器并行。

深度相关的改动：2026-11-29 清理 F 把 A / B 选择移到队列写入侧（`front_fetch_buf`），检查侧少一级 16 槽 × 2 选 1（未重测深度）。EXP-053 把指令起点扫描（4 轮前缀扫描）、单份展开与预译码移进 `front_head_fix`（原来在 `front_fetch_buf`）。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- 模型里"指令队列的 pc 与 PTAB / FTQ 的 pc 不等就 `fatal`"的检查：**RTL 没有**。指令队列不存每槽 pc，检查器用的 pc 来自 FTQ 的 `pd_ptr` 项；I-Cache 回来的组与 FTQ 项是否对得上，RTL 不检查（靠 `ifu_ptr` / `pd_ptr` 同序、同时回滚保证）；
- `predecode()` 里 `inst == 0 || inst == INST_NOP` 直接判非分支：RTL 不需要特判，这两个字的操作码本来就不是 JAL / 分支 / JALR；
- 模型的 `rvc_head_fix` 里 `last >= (carry ? 1 : 0)`：RTL 里 `chain[0]`（`start_b[0] = 0`）使携带时槽 0 不会被当成末槽的前半，两者等价；
- `lh_new_pc`：RTL 用 `group_end_pc = 基址 + 2 * 有效槽数`，模型用头修正后 `pc[n-1] + 2`；二者只在携带且只有槽 0 有效时不同（模型 = 基址，RTL = 基址 + 2），这种情形没有 `straddle`，`lh_new_valid = 0`，不影响行为。

RTL 独有的：

- 槽类别 `kind_o` → `slot_kind`：模型的后端自己从指令译 `br_type`（`back-end/Rob.cpp` 里 `rf_type = idu_br_latch->br_type`）；RTL 的统一 FTQ（`ftq_ibuf` 的 `ftq_bpu`）存预译码写入的 `slot_kind`，误预测时按槽读回给前端。规则同后端提交侧分类（`predecode_lane.sv` 头注释写明参考 `Exu::comb_fu2exu_collect`，本轮没有逐行对照）。缺页槽的类别是 `NONCTL`（送出的是 NOP），但检查器的 `ptype_o` 仍是拼出的字的类型（携带 + 第二半缺页时与旧行为一致）。

RTL 与模型保持一致的细节（容易误判为 bug）：

- JALR 在检查器里恒当"跳"，但目标沿用 BPU 的；所以 JALR 的目标不对不会引起预译码冲刷，由后端发现后重定向；
- 预测为"跳"但预译码是非分支的槽，检查器把它当不跳（`predict_dir_corrected = 0`），下一地址退回顺序续接，这就是一次冲刷，同时 `nb_pc` 告诉 BPU 清类型表项；
- 无效槽的类型是 非分支、目标 0（`valid_o` 为 0 时在 `front_head_fix` 里清）。

未核对（继承自旧文档）：

- 旧文档（front_basic.md 第 4 节）说模型里的 `exit(1)` 自检（含 `fifo.pc != ptab.pc`、`predecode_type` 的 default 分支）在 RTL 里"不可达或调试用"所以不建：现行代码里确实没有这些检查（已核对），"不可达"的理由没有重新证明；

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，每条提交对比 function-model，周期对 `scripts/ref_cycles.txt` 逐个相等。
- **Linux**：全程 Linux（rv64gc，含压缩指令的内核和用户态）：`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`；PT / UP 指纹 `scripts/align_check.sh`。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **等价测试（清理 F）**：`tests/fe_clean_f/run.sh`，新 RTL 对 `tests/fe_clean_f/ref/` 里清理前的副本（rtl `3834bbe`）：
  - `chain`：`icache_resp → front_fetch_buf → inst_fifo → front_head_fix → predecode_checker → front_pd_info`（旧链另加 `front_slot_kind` x16），同一随机 F1 响应（按 `icache.sv` 的 straddle / tail / `a_len` / `b_nwords`，含奇地址、缺页、非缓存单字、refetch）、队列读写和头修正侧输入，每拍比较 `front_head_fix` 全部输出、槽类别、检查器结果和 `front_pd_info` 寄存器；100 万拍 0 差异（覆盖：跨行条目 25.8 万、tail 带 B 11.1 万、携带 28.4 万、末槽半条 20.6 万、末槽完整 4.6 万、缺页 3.9 万（其中携带 1.2 万）、冲刷 57.9 万、RAS 压栈 7.3 万）；
  - `decode`：`rvc_expand` 65,536 个半字全枚举 + 分支译码（展开后的全部半字 + 100 万个偏向 jal / jalr / 分支、`rd / rs1 ∈ {x0, ra}`、立即数 0 或单比特的 32 位字）对旧 `predecode_lane` / `front_slot_kind` / `front_pd_info` 的压栈弹栈判定，0 差异；
  - 变异检查：`MUT=1..8` 各改一处新 RTL（`up16` 选择、槽窗口、`fetch_up16` 下标、RET 的立即数判定、CALL 判定、缺页槽类别、B 区无效槽半字、`c.slli`），全部 FAIL。
- **没有对直译模型的独立测试**。**待补**：`front_head_fix` + 检查器对一个直译模型（`rvc_head_fix` + `predecode_check`）的随机对拍。

## 9. 参数与开关速查

`RVC_ENABLE`（只支持 1：`icache_resp` 的按字取指分支 2026-11-29 清理 F 删除；`front_head_fix` 里 `RVC_ENABLE != 0` 的条件仍在）、`FETCH_WIDTH`、`SLOT_BYTES`、`ICACHE_LINE_SIZE`、`XLEN_BITS`、`FPRF_NUM`（`rvc_expand` 的 `HAS_FP`）；`front_pkg` 的 `PREDECODE_*` 编码和 `KIND_W`。

## 10. 变更记录

- 2026-11-29 清理 F：（1）跨行 A / B 合并移到队列前的 `front_fetch_buf`，`front_head_fix` 直接用合并好的窗口（删第 1 步的 A / B 选择和 16 路高半字选择；`asm_word` 用 `half[0]`：携带要求槽 0 有效，而 `a_len ≥ 1`，槽 0 总是 A 槽）；（2）分支译码只留一份：`predecode_lane` 改为出 `BR_*` 类别 + 目标（去掉 `inst_valid`），检查器的 2 位类型由 `front_pkg::ptype_of_kind` 导出，`front_head_fix` 新增 `kind_o`（替代 `front_pred_path` 里对 `insts_o` 的 16 个 `front_slot_kind`），`front_pd_info` 的压栈 / 弹栈改看类别（`insts` 入口换成 `kind`）；删 `s2_ty / s2_tgt` 的截断清零（`valid_o` 已蕴含未截断）；（3）`rvc_expand` 删 rv32 分支和 `IS_RV64` 参数（周期不变）。
- 2026-11-29 清理 E：改名 `PREDECODE_DIRECT_JUMP_NO_JAL` → `PREDECODE_BRANCH`（值仍为 1，trace-model `front-end/predecode.h` 同步改）；`front_head_fix` 的 `ptab_base_pc` → `pd_base_pc`、`ptab_pc` / `ptab_pc_o` → `pd_pc` / `pd_pc_o`、`use_pair` → `use_straddle`，`inst_fifo_entry_t.is_pair` → `is_straddle`；`front_pd_info` 的 `ptab_next` → `pd_next_pc`（只改名字，周期不变）。
- 2026-11-29 清理 C：删 EXP-051 2-taken 双块残留（EXP-070 起不再产生）：`front_head_fix` 删 `ptab_is_pair / ptab_base_b / ptab_a_len` 输入（原恒 0）、`pair_disc` / `bnd_vec`（跨行拼接时 B 恒为 A 的下一行，`base_a + a_len × 2 == base_b`，恒 0）及由它导出的 `seg_first_o / multi_o / in_range_o`，保留跨行 A / B 拼接与 `gb_gen` 在 i = 1 的项；`predecode_checker` 删整个 `multi` 分支（13 个 `ttg_*` 实例）及 `multi / in_range / seg_first / slot_pc / inst_valid / is_rvc` 入口和 `keep_n` 出口（原恒 `FETCH_WIDTH`）；`front_pd_info` 删段 1 逻辑、第二个 taken 槽（`ttg_pick_k K=2` 换成 `ttg_first_set`）、第二组 RAS 操作 `pd_ras_op2 / pd_ras_val2`、`pd_nb_base`、`multi / keep_n / seg_first / ptab_pc` 入口，`pd_hn` 收为 1 位、`pd_hbits` 收为 3 位；删临时 `batch C probe` 断言（周期不变）。
- 2026-11-28 清理：删 `predecode_checker` 未用的 `clk / rst_n` 端口，删 `predecode_checker` / `front_head_fix` / `front_pd_info` 里不起作用的 `UNUSEDSIGNAL` 豁免（`unused_*` 汇点本就不报）（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`，文档核对）：第 1、3、5 节按现行 RTL 重写（展开 / 预译码 / 起点扫描都在 `front_head_fix`；PTAB 改为统一 FTQ；双段检查 `multi` / `keep_n` 是现行功能）；文件表更新行数并去掉没有被例化的 `predecode.sv`、`sequential_next_pc.sv`（RTL 清理中删除）；第 6 节补 2026-11-21 的深度；门禁改为 77/77 对 `scripts/ref_cycles.txt`。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`predecode` 支持每槽独立 `slot_pc[FETCH_WIDTH]`；`front_head_fix`、`predecode_checker`、`front_pd_info` 升级支持双块多段（`multi`/`in_range`/`seg_first`/`keep_n`、双历史符号/双 RAS 操作、`pd_nb_base` 修复 RVC 携带假分支清槽）。Yosys 综合 `predecode` 10,144 单元 / 27 层（原 11,780 / 29）；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差，含 `directed/fe_2taken_fdip.bin`）与 Linux 27 窗检查点对齐。
- 2026-11-18（exp/agu-share）：本组文件没有改动；指令起点前缀扫描（`front_fetch_buf`）见 front_top.md。
- 2026-11-14/15：RVC 前端：C910 风格的携带取代 I-Cache 第二行（`e784f05`）、RVC=1 的非压缩程序周期与 `ref_cycles_rvc.txt` 相等（`f8feff3`）、模型三处预测修正（`1a3d458`）；设计说明见 docs/RVC_RTL.md。
- 更早：见 git 历史。
