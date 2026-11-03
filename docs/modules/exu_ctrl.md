# exu_ctrl 设计笔记

## 1. 对应的 C++
- 文件/类：`back-end/Exu/Exu.cpp` `class Exu`（去掉 28 个 FU 实例本身）；FU 基类契约 `Exu/include/AbstractFU.h`
  （`SingleCycleFU / FixedLatencyFU / IterativeFU`）；FU 清单与端口映射 `Exu::init`（Exu.cpp:37-147）、`config.h:371-398`。
- 在 `BackTop::comb()` 里的调用顺序：`exu->comb_begin` → … → `exu->comb_to_csr` → `csr->comb_csr_read` → `exu->comb_exec`
  （`comb_fu_ctrl → comb_exu2fu_dispatch → comb_fu_exec → comb_fu2exu_collect`）→ `rob->comb_complete` → `exu->comb_ready` → `isu->comb_issue`
  → … → `exu->comb_pipeline`；`BackTop::seq()` 里 `exu->seq()`。
- 输入：`prf2exe.iss_entry[22]`、`dec_bcast{mispred,br_mask,clear_mask}`、`rob_bcast.flush`、`lsu2exe{wb_req[4],sta_wb_req[4]}`、`csr2exe.rdata`，
  以及 FU 侧（`fu2exu`）：单周期 FU 的计算结果、多周期 FU（MUL/DIV/FPU）的 `ready/complete/inst`。
- 输出：`exe2prf{entry[22],bypass[28]}`、`exe2iss.fu_ready_mask[22]`、`exe2csr`、`exe2lsu{agu_req[8],sdu_req[4]}`、`exu2id`、`exu2rob.entry[22]`，
  以及到 FU 的 `exu2fu`（`en/consume/flush/flush_mask/clear_mask/inst`）。
- 边界方案：`docs/analysis/exu-boundary.md` 的两层划分（E6）。参考模型无需改：`BackTop::comb()` 之后 `bt.exu->in.fu2exu / out.exu2fu` 都是最终值。

### FU 边界的约定（本模块与 E1–E5 叶子 FU 的接口）
- **单周期 FU**（ALU×6、AGU×8、SDU×4、BRU×4、CSR×1，`SingleCycleFU`）：C++ 基类保证 `complete == en`、`ready == !en || consume`，
  `out.inst` 就是本拍派发的 `in.inst` 加上 `impl_compute` 改写的字段。所以 exu_ctrl 不从它们取 `complete/ready`，而是**自己按基类契约推出**；
  FU 只收计算操作数（`exu2fu_alu_*/bru_*/agu_*/sdu_*`），只回计算结果（`fu_alu_result`、`fu_agu_result`、`fu_sdu_result`、`fu_bru_{diag_val,mispred,br_taken}`）；
  `dest_preg/rob_idx/br_mask/…` 等直通字段全部取自 exu_ctrl 自己的槽位。CSR FU 的 `impl_compute` 为空（result 恒为 0），无任何 FU 侧信号。
  BRU 的 `inst.result` 在 `BruUnit::impl_compute` 里从未被写（恒 0），所以也不回传。
- **多周期 FU**（MUL×2、DIV×2、FPU×1，`FixedLatencyFU/IterativeFU`）：自己持有在飞指令（含 `br_mask` 的 clear/kill），
  收完整指令（`exu2fu_mc_*`）+ `en/consume`，回 `ready/complete/result/dest_preg/dest_en/br_mask/rob_idx`（`fu_mc_*`）。
  `op` 取 FU 种类的常量（MUL/DIV/FP 各自只有一个 op）。`mc` 数组按 fu_idx 序：{MUL(0), DIV(3), FPU(5), MUL(6), DIV(8)}。
- FU 下标映射（`Exu::units` 顺序，已由运行时打印验证，见分析文档 1.1）：alu={1,4,7,9,10,11}（端口 0..5），agu=12..19（LD 12..15，STA 16..19），
  sdu=20..23，bru=24..27，CSR=2。

## 2. 硬件结构

```
 prf2exe.iss_entry[22] ──► exu_ctrl_slot ──fu_en[28], fu_inst[28]──► exu2fu 各组 (ALU/BRU/AGU/SDU/MC)
 dec_bcast / rob flush ──►  (28 个 FU 输入槽 slot_valid/slot_inst,         │
                             kill/clear/load,                             │
                             csr_idx)                                     ▼
                                │ fu_inst                   FU 侧结果 fu_* (单周期:计算结果; 多周期:完整握手)
                                ▼                                         │
                         exu_ctrl_fu_view  ◄──────────────────────────────┘
                                │ fu_done[28] (统一的 xc_done_t)
                                ▼
                         exu_ctrl_port_arb ── consume[28], win_valid/win[22], win_is_csr[22]
                                │
              ┌─────────────────┼───────────────┬───────────────┬───────────────┐
              ▼                 ▼               ▼               ▼               ▼
       exu_ctrl_wb_prf   exu_ctrl_wb_rob  exu_ctrl_lsu_req  exu_ctrl_br_arb  exu_ctrl_ready
       exe2prf entry/    exu2rob          exe2lsu           exu2id            fu_ready[28] → 槽释放
       bypass                                                                  exe2iss.fu_ready_mask
                                          exu_ctrl_csr_req: exe2csr（CSR 槽 → we/re/idx/wdata/wcmd），re 回给 wb_prf 做 rdata 覆盖
```

- 子模块：
  - `exu_ctrl_slot`：28 个 FU 输入槽（每个 FU 一个，`valid + xc_inst_t` + CSR 槽的 `csr_idx`），负责 kill/clear/装载/释放，输出 `fu_en`、`fu_inst`（派发副本，`br_mask` 已 clear）。
  - `exu_ctrl_fu_view`：把 slot 与 FU 侧结果合成每个 FU 统一的 `xc_done_t`（单周期：`complete=en`、直通字段取槽；多周期：取 `fu_mc_*`、`op` 取常量）。
  - `exu_ctrl_port_arb`：每个发射口内按 FU 序（MUL>DIV>LD>STA>STD>BR>ALU>CSR>FP）选第一个 `complete` 的 FU：`ttg_first_set` + `ttg_onehot_mux`；产生 `consume[f]`。
  - `exu_ctrl_ready`：`fu_ready[f]`（单周期 `!en||consume`；多周期取 FU 输入）和 `fu_ready_mask[p]`。
  - `exu_ctrl_wb_prf`：`exe2prf.entry`（INT 口胜者 + LSU 写回）与 `bypass`（每个 `complete` 的 FU）。
  - `exu_ctrl_wb_rob`：`exu2rob.entry`（FU 胜者 + LSU 写回，LSU 写回受 flush/kill 约束）。
  - `exu_ctrl_lsu_req`：AGU/SDU 的完成 → `exe2lsu`。
  - `exu_ctrl_br_arb`：BRU 结果 → `clear_mask`（OR 掩码）与最老误预测（全对比较，不用运行比较器）。
  - `exu_ctrl_csr_req`：端口 0 的 CSR 槽 → `exe2csr`。
  - 顶层 `exu_ctrl.sv`：端口适配（打包 `iss_inst`、`fu_res`、`lsu_wb`，拆出 `exu2fu_*` 各组）与上述子模块连线，不放逻辑。
- 状态（只有这一处）：`slot_valid_q[28]`、`slot_q[28]`（`xc_inst_t` ≈ 330 位）、`csr_idx_q[12]`。FU 的状态（MUL 流水、DIV/FPU busy…）在 FU 里。
- 读写端口：槽 `slot_q[f]` 只有一个写口（`load[f]`，由 `iss_entry[fu_port(f)]` 装载）；clear 对所有槽的 `br_mask` 是常驻的 AND-NOT。

### C++ → 硬件的对应
| C++ | 硬件 |
| --- | --- |
| `fu_inst_r / fu_inst_r_1`（槽位现态/次态） | `slot_valid_q/slot_q` / `_d` |
| `port_mappings[p].entries`（vector） | 包里的常量函数 `xc_port_fu_*`（由 config 的端口能力掩码推出），generate 展开 |
| 端口内 `for … break` 选第一个 complete | `ttg_first_set`（`req & -req`）+ `ttg_onehot_mux` |
| `target_fu_idx` 搜索（`support_mask & (1<<op)`） | 各 FU 的 `kind_mask[op]` 译码（掩码不相交，所以不是仲裁） |
| `comb_fu2exu_collect` 里的 `int_res/br_res` 容器 | 直接由端口胜者连线，无容器 |
| `mispred_uop` 逐个比较 `cmp_inst_age` | `{rob_flag,rob_idx}` 8 位减法判“更老”（`0 < a-b < 128`）的全对比较矩阵 |
| `FuOutput.ready`（经 `comb_consume` 的最终值） | `fu_ready[f]`（单周期推出，多周期来自 FU） |
| 每个 FU 一份的 `flush/flush_mask/clear_mask` | 三个标量（28 份完全相同） |

## 3. 一拍内的数据流（一次求值，无组合环）
1. `slot_killed[f] = mispred & |(slot_q[f].br_mask & dec.br_mask)`；`fu_en[f] = slot_valid_q[f] & !flush & !slot_killed[f]`；
   派发副本 `fu_inst[f] = slot_q[f]`（`br_mask & ~clear`）。（C++ `comb_exu2fu_dispatch`）
2. FU 侧给出结果（单周期 FU：`result`…；多周期 FU：`complete/ready/inst`），`exu_ctrl_fu_view` 合成 `fu_done[f]`。
3. 每个端口选胜者；`consume[f]=win_onehot`；`fu_ready[f]` = 单周期 `!en || consume` / 多周期 FU 的 `ready`（`consume` 之后的最终值）。
   这是唯一“输出→输入→输出”的路径：多周期 FU 的 `ready` 依赖 `consume`，但 `consume` 只依赖 `complete`，不依赖 `ready`，无环。
4. 写回：`exe2prf.entry`（INT 口胜者且 `dest_en`；CSR 胜者且 `exe2csr.re` 时 `result=csr2exe.rdata`；口 6..13 来自 `lsu2exe`，`op` 为常量 LOAD/STA）；
   `bypass[f]`（每个 `complete` 的 FU，用 FU 原始结果，不含 CSR 覆盖）；`exu2rob`；`exe2lsu`；`exu2id`。
5. 槽的次态：`valid_d = (fu_en & !fu_ready) | load`，`load[f] = !flush & iss_valid[p] & !killed(iss) & kind_mask(f)[iss.op]`；载荷 `slot_d = load ? iss : slot_q`，`br_mask &= ~clear`。
6. `fu_ready_mask[p] = flush ? 0 : OR_f (( !fu_en[f] || fu_ready[f]) ? kind_mask(f) : 0)`。

C++ 里 Exu 各阶段的拍内顺序（04 第 3.1 节核对）：
- `comb_to_csr` 在 `comb_exec` 之前执行，读的是 `fu_inst_r`（寄存器现态）、`rob_bcast.flush`、`dec_bcast`（`Idu::comb_branch` 更早已定）：全是本拍定值，没有 stale 读。
  它的 `re` 被 `comb_fu2exu_collect` 同拍使用（CSR 结果覆盖）；`csr2exe.rdata` 是 Csr 在 `comb_to_csr` 之后同拍算出的输入。无寄存器需要。
- `exu2rob/exe2prf` 在 BackTop 里不是每拍清零的（只有 `Exu::comb_begin` 清 `valid`），`uop` 字段在 `valid=0` 时是残留值：
  所有读者（Rob.cpp:538 起、Prf.cpp:33/203）都先判 `valid`，所以用 `when valid`，**不复刻**残留。Prf 在 `comb_pipeline`（`exu->comb_exec` 之后）才读 `exe2prf.entry`，Rob 的 `comb_complete` 紧跟 `comb_exec`，读到的是本拍值。
- `exe2prf/exe2lsu` 在 BackTop 层有 `= {}` 的清零（`BackTop.cpp:251-253`），`exu2id` 也在 `BackTop.cpp:246` 清零，但 Exu 自己也先写默认值，无差别。
- `prf2exe.iss_entry` 依赖本模块输出的 `fu_ready_mask`（经 Isu/Prf），但只流入槽的**次态**，没有组合环。
- 结论：**没有需要建成寄存器的 stale 值**，无隐含依赖表新增项。

## 4. 与 C++ 的差异点、放宽、删除

### 4.1 单周期 FU 契约的内化（不是放宽，是边界选择）
`complete`/`ready` 对单周期 FU 不作输入：由 `AbstractFU.h` 的 `SingleCycleFU`（`comb_issue: if (in.en) complete=true`；`comb_consume: ready=!en||consume`）推出，
trace 上 `fu_ready_mask`、`exu2fu` 等输出的逐位比较证明了这一点。

### 4.2 未复刻 / 删除
1. **`flushed` 对 FU 胜者的约束**（`comb_fu2exu_collect` 里 `!flushed` 对 ROB/LSU/BR 的门控）：对 FU 路径恒为假，不复刻。
   理由：单周期 FU 的 `en` 已经包含 `!flush && !killed`；多周期 FU 在 `comb_ctrl` 里用同一个 `flush_mask/clear_mask` 先清掉被杀项再报告 `complete`；
   而 `is_br_killed(u)` 看的是 clear 之后的 `br_mask`。所以 `complete` 的项永远没被 flush/kill。RTL 里放了时钟采样断言（`ifndef SYNTHESIS`）；
   **LSU 写回路径的 `flushed` 是真实存在的**（`lsu2exe.br_mask` 可能与 `dec_bcast.br_mask` 相交），保留。
2. **`exe2prf.entry` 对被 kill 项不门控**：C++ 本来就不门控（`int_res` 只看 `dest_en`），RTL 同样；Prf 自己用 `dec_bcast` 杀。
3. **`Assert(target_fu_idx >= 0)` / `Assert(!entry[p].valid)`**：不可达（`fu_ready_mask` 由本模块给出，Isu 只发被允许的 op；LSU 口只有 LSU 写回），不复刻。
   发射到 FU 时“槽空或 FU ready”的条件只用于断言，RTL 里按 `kind_mask[op]` 直接选目标 FU。
4. **槽无效时保留旧载荷**：无读者（`fu_inst_r[i].valid` 先判），RTL 只在装载时写载荷（clear 仍常驻）。
5. **`exu2rob.entry[p].uop` 无效时的残留值**：不复刻（`when valid`）。
6. **`exe2lsu` 的 `uop` 在 `valid=0` 时**：`BackTop` 清零，但读者（`RealLsu::comb_exe2lsu` 先判 `valid`）不读，`when valid`。
7. `ExuInst.page_fault_inst / flush_pipe`：全后端无写者（grep：`flush_pipe` 只在 Rob.cpp:473/620 被读），恒 0，删除。
8. `exu2rob.uop.dbg`、`exe2lsu.uop.dbg`、`exe2prf` 的 `dbg`：不翻译。
9. `ExePrfWbUop.br_mask/op` 在 **bypass** 上无读者（Prf.cpp:33-36 只读 `dest_en/dest_preg/result`），删除；entry 上保留（Prf 严格比较）。
10. `PrfExeUop` 里 `ftq_resp_valid / ftq_offset / src1_preg / src2_preg / src2_en`：Exu/FU 无读取点（Prf 的笔记已列出同样结论），删除。
11. `exe2lsu` 的 `op/dest_en/br_mask`、STA 的 `stq_flag/ldq_idx`：Lsu 无读取点（以 `spec/lsu.io` 的字段集为准，op 由口决定）；`func7` 只剩 `func7>>2`（`amo_op`）。
12. `lsu2exe` 的 `op / flush_pipe`：Lsu 对每个口恒为 LOAD/STA / 0（`RealLsu.cpp:930-1030`），不作输入；STA 写回的 `dest_preg/dest_en/page_fault_load` 恒为 0。
13. `csr_status`、`dec_bcast.{br_id, redirect_rob_idx}`、`rob_bcast` 的 flush 以外字段：Exu 不读。
14. 未使用的 FU 输入槽位字段随 FU 种类不同而异，但槽结构是各 FU 通用的超集（综合时无读者的位会被裁掉）。

### 4.3 放宽（`when`）与消费者核对
| 字段 | `when` | 读取点核对 |
| --- | --- | --- |
| `exe2prf_entry_uop_*` | `exe2prf_entry_valid` | `Prf.cpp:203` 先判 `entry[i].valid` 才取 uop |
| `exe2prf_bypass_uop_*` | `exe2prf_bypass_valid` | `Prf.cpp:33` 先判 `bypass[k].valid` |
| `exu2rob_entry_uop_*` | `exu2rob_entry_valid` | `Rob.cpp:537` 先判 `valid`；其中 result/diag_val/page_fault 只在 LD/STA 口（Rob.cpp:560-600）被读，diag_val/mispred/br_taken 另在 `is_branch_uop`（Rob.cpp:624）被读，**其余位置在 spec 里用 `@` 表达式掩成 0**（无读者） |
| `exe2lsu_*_req_uop_*` | 各 `valid` | `RealLsu.cpp:260-281` 先判 `valid` |
| `exu2id_{redirect_pc,redirect_rob_idx,br_id,ftq_idx}` | `exu2id_mispred` | `Idu::comb_bcast` 只在 `br_latch.mispred` 下用 br_id/redirect_rob_idx（Idu.cpp:186-200）；`redirect_pc`/`ftq_idx` 见 `docs/modules/idu.md` 的核对（BackTop.cpp:346、PreIduQueue.cpp:225 均在 `mispred` 下） |
| `exe2csr_{wdata,wcmd}` | `exe2csr_we` | `Csr.cpp:340-344` 在 `if (we)` 内 |
| `exu2fu_flush_mask` | `exu2fu_flush` | FU 的 `comb_ctrl` 在 `if (in.flush)` 内读 |
| `exu2fu_*` 指令字段 | 各组 `en` | FU 的 `comb_issue` 只在 `en` 时读 `in.inst` |
| `exe2csr_idx` | （严格比较） | 读者在 `we||re` 时读；`we|re` 不能写成 `when`，所以 RTL 在无 CSR 请求时输出 0，与 C++ 一致 |

### 4.4 与 C++ 的差异（`deviations.md` 候选）
- 无功能差异。疑点（只记录，不改）：
  - **MUL 重复接收的可能性**：槽在 FU `ready=false`（流水满）时不释放，下一拍同一条指令会再次 `en`。靠 `MUL` 在端口内的最高优先级（其 `complete` 必被消费）避免重复，
    属于“靠仲裁顺序保证正确”的脆弱点；若将来改端口内优先级需重新审视。
  - DIV/FPU 在忙期间槽里始终有一份在飞指令的副本且每拍 `en=1`（被 FU 忽略）：行为正确，但槽被一条已在 FU 内的指令占着直到完成。
  - 多个 CSR 槽等待写回仲裁（MUL 同拍完成）时 `exe2csr.we/re` 会每拍重复发出（CSR 槽未被 consume 前一直 `en`）。Csr 模块是否对重复写幂等由 Csr 侧保证。

## 5. 验证
- spec：`spec/exu_ctrl.io`（157 个字段，输入 1381 B + 输出 1610 B / 拍）。
- trace：73 个真实程序（61 gate 测试各 8000 拍，dhrystone/coremark/coremark10/4 个 vm/float/sha/cjpeg/linear_alg/parser 各 20000 拍；
  录制窗口按 06 的建议缩短，总 895 MB）共 312,821 条记录 + 4 条随机 trace（`tests/exu_ctrl/run_rand.sh`，驱动参考模型真实 `Exu` 类 + 真实 FU 类，
  各 40003 条，约束见 `rand_trace.cpp` 文件头）。**全部 PASS**。
- 真实程序覆盖（`build` 外的统计脚本，312,602 个非复位拍）：flush 620、mispred 6683、clear_mask≠0 85,884、端口内 MUL/DIV/FP 与 ALU 同拍完成
  （p0 MUL×ALU 1081、p1 DIV×ALU 16、p1 FP×ALU 134、p2 MUL×ALU 613、p3 DIV×ALU 9）、多周期 FU 忙时槽被占 35,751、flush 时有多周期 FU 在飞 351、
  同拍 ≥2 个 BRU 误预测 525、同拍 ≥2 个 BRU 解析 21,275、CSR `we&re` 同拍 28、LSU load 写回被丢弃 1516 / STA 被丢弃 1121、同拍 ≥10 个 FU 旁路 3407。
  未覆盖：CSR 槽被 MUL 抢占（真实程序里 CSR 与 MUL 同拍完成几乎没有）、FP 的 fsgnj/fmin/fmax/fclass（FU 内部，与本模块无关）；这些由随机 trace 覆盖。
- 随机 trace 覆盖（4 条合计）：端口 0..3 的多 FU 同拍完成各数千~数万次，多 BRU 同拍误预测 12 万次，CSR we&re 2.9 万次；
  断言 “FU 胜者从不被 flush/kill” 的计数为 0（16 万拍）。
- 变异（一条被严格比较字段抓到；dhrystone(20000 拍) / rand_a；记录号）：
  - M1 槽释放极性 `fu_en&&!ready`→`fu_en&&ready`：`exe2prf_entry_valid[0]` rec37 / `exe2prf_bypass_valid[18]` rec5
  - M2 `clear_mask` 只含误预测分支：`exu2id_clear_mask` rec78 / rec5
  - M3 最老误预测改为最年轻：`exu2id_redirect_pc` rec600 / rec4
  - M4 LSU 写回的 kill 极性：`exu2rob_entry_valid[6]` rec228 / rec53
  - M5 CSR `we` 对零源的判断：`exe2csr_we` rec18 / rec44
  - M6 flush 时 ready 掩码全 1：`exe2iss_fu_ready_mask[0]` rec19 / rec18
  - M7 CSR 读数据覆盖极性：**仅 rand_a 抓到**（`exe2prf_entry_uop_result[0]` rec44；dhrystone 不含 CSR 读写回）
  - M8 `exe2prf` valid 忽略 dest_en：`exe2prf_entry_valid[0]` rec60 / rec5
  - M9 新发射指令不受误预测 kill：**dhrystone 通过，rand_a 抓到**（`exe2prf_bypass_valid[12]` rec9）
  - M10 clear 用 kill 掩码：`exe2prf_entry_uop_br_mask[0]` rec359 / rec25
  - M11 ROB flush 时 `flush_mask` 为 0：`exu2fu_flush_mask` rec19 / rec18
  共 11 个变异，全部被抓到；其中 M7、M9 只被随机 trace（在 dhrystone 之外未逐个真实程序核对）抓到。
