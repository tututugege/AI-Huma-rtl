# Exu / 功能单元（FU）RTL 模块边界与录制方案（分析报告）

> 基线：参考模型 `baseline-sim/src`，文件 `back-end/Exu/Exu.cpp`、`Exu/include/{Exu,Fu,AbstractFU,FPU,ExuTypes}.h`、`include/config.h`。
> 行号均为原版。**[已验证]** = 本报告附带实验得出（`tools/exu_cov.cpp`、`tools/exu_map.cpp`、`tools/fpcmp.cpp`、`examples/alu_bank.io`+`check_alu_trace.py`）；**[未核实]** = 只读代码未实验/未读完。

## 0. 摘要

1. Exu = **28 个 FU 实例**挂在 **22 个发射端口**上（`config.h:371-398`、运行时打印已验证，§1.1）：6×ALU、4×BRU、2×MUL、2×DIV、1×FPU、1×CSR、4×AGU(Load)、4×AGU(STA)、4×SDU。Exu 本体（槽位寄存器 + 端口仲裁 + 分发/收集 + 分支仲裁 + ready 掩码 + CSR/LSU/PRF/ROB 输出）与 FU 完全解耦：**FU 之间没有互相访问，FU 与 Exu 之间只走 `AbstractFU::FuInput/FuOutput`**。
2. **推荐：两层划分** —— 叶子 FU 模块（`alu`、`bru`、`agu`、`sdu`、`csr_fu`、`mul_unit`、`div_unit`、`fpu`）各按 `FuInput/FuOutput` 边界验证；`exu_ctrl`（Exu 去掉 FU）以 `FuOutput` 为输入、`FuInput` 为输出验证；最后整个 Exu 在对外口上闭合回放。**所有这些边界都不需要改参考模型**：钩子之后（`back.comb()` 之后）每个 FU 的 `in/out` 与 Exu 的 `in/out/exu2fu_io/fu2exu_io` 都还是最终值（§4，`alu_bank.io` 已验证可录制并通过独立核对）。
3. 纯函数 FU（ALU/BRU/AGU/SDU，约 60% 的 FU 实例）真实程序**覆盖很差**（Zbb/Zbs/Zbc 指令基本只被 `bitmanip-boundary` 一个程序碰到，FP 指令很稀疏），必须用 **"C++ golden + 随机向量写 trc"** 的生成器验证；真实程序 trace 用于 `exu_ctrl` 的仲裁/冲刷/旁路等协议逻辑（这些覆盖得很好，§5）。
4. **FP：`FPURtl`/`fadd.h`/`fmul.h` 在参考模型里是死代码**。实际执行的是 `FPUSoftfloat`（Berkeley softfloat，`Exu.cpp:119`），`FPURtl` 在整个源码树里没有被实例化（grep 仅有定义）。两个网表是纯组合 AIG（`fadd.h` 12,298 个 AND 节点、`fmul.h` 9,562 个；67 输入、37 输出；拓扑序无前向引用，[已验证]）。**实验（300 万随机 + 676 组角点，每种舍入模式）表明：`rm=0..4` 时两个网表的结果位与 softfloat 完全一致**（`fflags` 不一致但整个模型从不读 fflags）。因此 FADD/FSUB/FMUL 可由脚本从网表机械转 SV；FDIV/FSQRT/FCVT/CMP/MINMAX/CLASS/SGNJ 没有网表，需手写 SV 并用 softfloat 库做差分随机测试（§3）。
5. 难度：全 Exu 约 8 个子任务，最难的是 `exu_ctrl`（仲裁/冲刷语义）和 FP 的 FDIV/FSQRT（逐位对齐 softfloat），见 §6。

## 1. 结构

### 1.1 FU 清单与端口映射 [已验证：运行时打印 `Exu::port_mappings`]

`GLOBAL_ISSUE_PORT_CONFIG`（`config.h:371-398`）共 22 个端口；`Exu::init`（`Exu.cpp:37-147`）按端口顺序、每端口内按 **MUL → DIV → LD → STA → STD → BR → ALU → CSR → FP** 的顺序创建 FU，**同一端口内的这个顺序就是写回仲裁优先级**（先完成的先赢，`comb_fu2exu_collect` 取第一个 `complete` 的 FU）。

| 端口 | FU（fu_idx）| 备注 |
| --- | --- | --- |
| 0 | MUL(0)、ALU(1)、CSR(2) | CSR 硬绑定端口 0（`config.h:373` 注释）；`comb_to_csr` 只看端口 0 |
| 1 | DIV(3)、ALU(4)、FPU(5) | |
| 2 | MUL(6)、ALU(7) | |
| 3 | DIV(8)、ALU(9) | |
| 4、5 | ALU(10)、ALU(11) | |
| 6–9 | AGU_LD ×4（fu 12–15，LSU agu 口 0–3）| |
| 10–13 | AGU_STA ×4（fu 16–19，LSU agu 口 4–7）| |
| 14–17 | SDU ×4（fu 20–23，LSU sdu 口 0–3）| |
| 18–21 | BRU ×4（fu 24–27）| |

派生常量：`ISSUE_WIDTH=22`、`TOTAL_FU_COUNT=28`、`ALU_NUM=6`、`BRU_NUM=4`、`LSU_LDU_COUNT=4`、`LSU_STA_COUNT=4`、`LSU_SDU_COUNT=4`、`LSU_AGU_COUNT=8`、`BR_MASK_WIDTH=64`、`MAX_WAKEUP_PORTS=15`、`IQ_ALU_PORT_BASE=0/IQ_LD=6/IQ_STA=10/IQ_STD=14/IQ_BR=18`、`MUL_MAX_LATENCY=2`、`DIV_MAX_LATENCY=16`。这些都在 `config.h`，RTL 只能通过 `ttg_cfg_pkg` 使用（`make cfg` 目前是否导出端口表/FU 派生常量 [未核实]）。

FU 类型：

| 类型 | 基类 | 行为（`Fu.h`/`AbstractFU.h`/`FPU.h`）| 状态 | 延迟 |
| --- | --- | --- | --- | --- |
| ALU（6）| `SingleCycleFU` | 纯函数 `AluUnit::impl_compute`（`Fu.h:11-220`）：RV32I + Zba/Zbb/Zbs/Zbc 的子集，`op==UOP_ADD` 以外（ecall/ebreak/mret/sret/sfence/fence(.i)）走 `default: op1+op2`，`UOP_WFI` 结果 0 | 无 | 同拍（comb）|
| BRU（4）| `SingleCycleFU` | 纯函数 `BruUnit`（`Fu.h:338-425`）：6 种条件分支 + JAL/JALR；用 `ftq_pred_taken/ftq_next_pc` 判 `mispred`；`diag_val = taken ? target : pc+4` | 无 | 同拍 |
| AGU（4 LD + 4 STA）| `SingleCycleFU` | `result = src1_rdata + imm`（`Fu.h:222-237`，实际 64 位加再截断）| 无 | 同拍 |
| SDU（4）| `SingleCycleFU` | 存数据：非原子 `result=src2_rdata`；AMO 按 `func7>>2` 做 swap/add/xor/and/or/min/max/minu/maxu（`Fu.h:239-300`）| 无 | 同拍 |
| CSR（1）| `SingleCycleFU` | `impl_compute` 空；结果在 Exu 收集阶段被 `csr2exe->rdata` 覆盖（`Exu.cpp:461`）| 无 | 同拍 |
| MUL（2）| `FixedLatencyFU(lat=2)` | `mul/mulh/mulhsu/mulhu`（`Fu.h:303-336`）；2 项流水（`pipeline` deque，`limit=latency`），按 `done_cycle = sim_time + lat - 1` 完成，只有队首可完成/被消费；`flush_mask`/`clear_mask` 在队内逐项作用 | `pipeline`（≤2 项含完整 `ExuInst`）| 接受后下一拍可见（lat=2）|
| DIV（2）| `IterativeFU(lat=16)` | `div/divu/rem/remu`（含除零、`INT_MIN/-1` 特例，`Fu.h:427-477`）；**非流水**：`busy` 期间不接受新项；`calculate_latency` 未覆写 → 固定 16 | `current_inst, done_cycle, busy` | 接受后第 16 拍完成 |
| FPU（1）| `IterativeFU`（`FPUSoftfloat`）| softfloat（`FPU.h:18-273`）：fadd/fsub/fmul/fdiv/fsqrt/fcvt/fmin/fmax/feq/flt/fle/fclass/fsgnj*（§3）| 同 DIV | 按指令：FADD/FSUB/其它 5，FMUL 3，FDIV/FSQRT 10，FCVT 3 |

> **所有时序 FU 用全局 `sim_time` 比较完成时刻**（`AbstractFU.h` 的 `done_cycle <= sim_time`），RTL 里要换成"每项一个倒计时/或全局拍计数器的差"；`has_finished` 用的是 `<=`，完成后若不被消费则**一直保持完成**。`sim_time` 在 `main.cpp:624` 的循环里每拍加 1（与 `ctx.perf.cycle` 同步，绝对偏移无关，只用差值）。

### 1.2 `comb_*` 阶段与数据流（`BackTop::comb`，`BackTop.cpp:278-392`）

Exu 每拍的调用顺序（周围模块也列出以便看依赖；Exu 各函数定义行：`comb_begin` 150、`comb_ready` 209、`comb_to_csr` 241、`comb_pipeline` 287、`comb_fu_ctrl` 344、`comb_exu2fu_dispatch` 369、`comb_fu_exec` 399、`comb_fu2exu_collect` 415、`comb_exec` 608、`seq` 625）：

```
278 exu->comb_begin()      默认清零所有输出；fu_inst_r_1 = fu_inst_r；每个 FU comb_begin()（由 FU 自身状态给出 out.ready/out.complete/out.inst）
        ... idu->comb_branch/comb_decode(dec_bcast) ... prf->comb_complete/awake/write ... isu->comb_ready ... rob->comb_commit(产生 rob_bcast.flush) ...
308 exu->comb_to_csr()      读 fu_inst_r（端口 0 上的 CSR 槽）→ exe2csr{we,re,idx,wcmd,wdata}   [flush 时不驱动]
        csr->comb_csr_read()   → csr2exe.rdata
311 exu->comb_exec()       ┌ comb_fu_ctrl      每个 FU：flush=(rob.flush|dec.mispred)，flush_mask，clear_mask → FU.comb_ctrl()
                           ├ comb_exu2fu_dispatch  fu_inst_r 有效的槽 → exu2fu.entry[i].{en,inst}（被杀/flush 的槽 fu_inst_r_1.valid=false；clear_mask 作用于 br_mask）
                           ├ comb_fu_exec      每个 FU：comb_issue()（接受并计算，或给出 complete/inst）
                           └ comb_fu2exu_collect  (a) 旁路 bypass[fu_idx] ← 每个 complete 的 FU（不管能否写回）
                                                  (b) 逐端口扫描，winner = 端口内第一个 complete 的 FU：
                                                      驱 exu2rob（非 LOAD/STA）、exe2lsu（LOAD/STA→agu_req, STD→sdu_req）、
                                                      收集 int_res（ALU 端口 0..5 且 dest_en）与 br_res（BRU 端口 18..21，未被 flush/kill）、winner.consume=1
                                                  (c) 每个 FU comb_consume()：弹出完成项，更新 ready；槽位 fu_inst_r_1 在 ready 时释放
                                                  (d) exe2prf.entry ← int_res；LSU 回写 lsu2exe.wb_req[4]/sta_wb_req[4] → exe2prf.entry[6..13] + exu2rob
                                                  (e) 分支仲裁：所有存活 BRU 结果贡献 clear_mask |= 1<<br_id；最老的 mispred（`cmp_inst_age`）→ exu2id{mispred,redirect_pc=diag_val,rob_idx,br_id,ftq_idx}
        rob->comb_complete()  （同拍消费 exu2rob）
314 exu->comb_ready()      exe2iss.fu_ready_mask[p] = OR(support_mask of 端口内每个 FU，若 !槽有效 || fu.ready)；flush 时全 0
        isu->comb_issue(用 fu_ready_mask) ... prf->comb_read(用 exe2prf.bypass) ... → prf2exe.iss_entry[22]
392 exu->comb_pipeline()   flush：全部槽清；否则先杀/清 mask 现有槽，再把 prf2exe.iss_entry 写进 fu_inst_r_1[选中的 FU]（端口内第一个"支持该 op 且 (槽空||FU ready)"的 FU）
406 exu->seq()             fu_inst_r = fu_inst_r_1；每个 FU seq()
```

没有组合环：`FU.complete`（只依赖 FU 状态与本拍 `en/inst`）→ Exu 仲裁 → `FU.consume` → `FU.ready` → `fu_ready_mask`/槽释放；`complete` 不依赖 `consume`。**Exu 内部没有读"上拍残留值"的路径**（04 §3.1）：`exu2rob` 等输出都在 `comb_begin` 被清零后由 `comb_exec` 在 `rob->comb_complete` 之前重新生成；`BackTop.cpp:246-247` 的注释"ROB consumes exu2rob before EXU refreshes it"只出现在诊断开关 `CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN` 的分支里，而 `Rob.cpp` 只有 `comb_complete`（538 行）读 `exu2rob`，在 `comb_exec` 之后 [已核对，未做该开关实验]。

### 1.3 与其它模块的接口

| 信号 | 方向 | 内容（位宽见 §4.3）| 对端 |
| --- | --- | --- | --- |
| `prf2exe->iss_entry[22]` | 入 | `{valid, PrfExeUop}`：pc、ftq 预测、`dest/src1/src2_preg`、`src1/src2_rdata`、flags、`func3/func7/imm`、`br_id/br_mask`、`csr_idx`、`rob_idx/rob_flag`、`stq_idx/flag`、`ldq_idx`、`op`，另有 `DebugMeta dbg`（**不翻译**）| Prf（`Prf.cpp:113-140`，读寄存器堆+旁路）|
| `dec_bcast` | 入 | `mispred, br_mask[64], clear_mask[64]`（Exu 用来杀/清除在途指令）| Idu；Idu 的 `br_latch` 是把 `exu2id` 寄存一拍（`Idu.cpp:216`）[**只读到这一行，整条 exu2id→br_latch→dec_bcast 链路未逐拍验证**]|
| `rob_bcast->flush` | 入 | 全局冲刷 | Rob（`Rob.cpp:436` 在 `comb_commit`，早于 `comb_exec`）|
| `lsu2exe` | 入 | `wb_req[4]`（Load 回写）、`sta_wb_req[4]`：`LsuExeRespUop`（`diag_val,result,dest_preg,br_mask,rob_idx,dest_en,page_fault_load/store,op,flush_pipe`）| Lsu（`RealLsu.cpp:917-1030`）|
| `csr2exe->rdata` | 入 | CSR 读数据 | Csr（`Csr.cpp:75-76`）|
| `csr_status` | 入 | **Exu.cpp 里没有使用**（FPU/softfloat 不读 `frm`：`rm` 来自指令 `func3`）| — |
| `exe2prf->bypass[28]` | 出 | `{valid, wb uop}`，按 fu_idx 编号，**每个 complete 的 FU 都广播**（109 位 wb uop：`dest_preg,result,br_mask,dest_en,op`）| Prf（旁路读）|
| `exe2prf->entry[22]` | 出 | 写回：ALU 端口(0..5)上 `dest_en` 的结果（含 MUL/DIV/FP/CSR 经该端口完成的）+ LSU 回写（端口 6..13）| Prf |
| `exu2rob->entry[22]` | 出 | 完成通报：所有非 LOAD/STA 的完成 + LSU 回写（83 位）| Rob（`comb_complete`）|
| `exe2lsu->agu_req[8]/sdu_req[4]` | 出 | `ExeLsuReqUop`（141 位）| Lsu（`comb_exe2lsu`）|
| `exe2csr` | 出 | `we,re,idx[12],wcmd[2],wdata[32]` | Csr |
| `exu2id` | 出 | `clear_mask[64], mispred, redirect_pc[32], redirect_rob_idx[7], br_id[6], ftq_idx[6]`（早期分支恢复）| Idu（寄存一拍）|
| `exe2iss->fu_ready_mask[22]` | 出 | 每端口 64 位"能接收的 op 类型掩码" | Isu（`Isu.cpp:204`）|

## 2. 推荐的 RTL 模块划分与录制边界

### 2.1 比较

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| **A. 整个 Exu 一个模块** | 边界 = 外部 IO，逐拍闭合；真实程序覆盖仲裁/冲刷好 | 一个 spec 约 **19k 位**（见 §2.3）、~110 个字段行；失败难定位；纯函数 FU（ALU 的 Zb* 等）在真实程序里覆盖太差，无法靠 trace 证明正确 |
| **B. 只按 FU 拆**（`FuInput/FuOutput`）| 每个 FU 小而独立；可随机；并行开发 | 不验证仲裁/槽位/旁路/分支仲裁/ready 掩码——这些才是易错处 |
| **C. 两层（推荐）**| 叶子 FU 用 B 验证（含随机）；`exu_ctrl` 用"FU 当输入输出"验证；最后 A 闭合 | spec 数量多（但每个小）|

**推荐 C**，理由：
1. 参考模型本身就是这个结构（`AbstractFU` 接口、`Exu2FuIO/Fu2ExuIO`），不用重构；
2. FU 之间互相独立（并行任务）；`exu_ctrl` 的验证可以不依赖 FU 的 RTL（把 FU 的 `complete/ready/inst` 当 trace 输入）；
3. **覆盖盲区不同**：ALU/BRU/MUL/DIV/FPU 的"功能"盲区要靠随机 golden 补，`exu_ctrl` 的"协议"盲区靠真实程序 trace（实测 §5 覆盖良好）。

### 2.2 模块与边界

| 模块 | 内容 | 边界 | 状态 |
| --- | --- | --- | --- |
| `alu` | `AluUnit::impl_compute` | 入：`op, func3, func7, src1_is_pc, src2_is_imm, pc, imm, src1_rdata, src2_rdata`（+`en`）→ 出：`result`；其余 `ExuInst` 字段 pass-through（在 `exu_ctrl` 层验证）| 无 |
| `bru` | `BruUnit` | 入：`op, func3, src1_en, src1_rdata, src2_rdata, pc, imm, ftq_pred_taken, ftq_next_pc` → 出：`br_taken, mispred, diag_val` | 无 |
| `agu` / `sdu` / `csr_fu` | 纯函数 / 空 | `agu`：`src1_rdata, imm → result`；`sdu`：`is_atomic, func7, src1_rdata, src2_rdata → result`；`csr_fu` 无逻辑 | 无 |
| `mul_unit` | `FixedLatencyFU(2)` + `MulUnit` | 完整 `FuInput`（`en, consume, flush, flush_mask, clear_mask`, `ExuInst`）→ `FuOutput`（`ready, complete, ExuInst`）；内部 2 项流水带完整 uop（kill/clear）| `sim_time` → 倒计时 |
| `div_unit` | `IterativeFU(16)` + `DivUnit` | 同上；`busy/done` | 同上 |
| `fpu` | `IterativeFU` + `FPUSoftfloat`（§3）| 同上；延迟按 `func7` 类别 | 见 §3 |
| `exu_ctrl` | `Exu` 去掉 FU：槽位 `fu_inst_r[28]`、`comb_to_csr/exec(ctrl,dispatch,collect)/ready/pipeline`、分支仲裁、写回/旁路/ROB/LSU 输出 | 外部 IO（§1.3）+ `Fu2ExuIO`（入）/`Exu2FuIO`（出）共 28 对 | 见 §6 |
| `exu`（整体）| `exu_ctrl` + 28 个 FU 实例（`generate`）| 外部 IO（§1.3）| 集成 |

### 2.3 spec 字段规模估计（位宽来自 `config.h`，`tools/exuw.cpp` 计算；未录制的整 Exu 与 `exu_ctrl` 仅为**估算**）

宽度：`PRF_IDX 7, FTQ_IDX 6, FTQ_OFFSET 4, BR_TAG 6, BR_MASK 64, CSR_IDX 12, ROB_IDX 7, STQ_IDX 6, LDQ_IDX 6, UOP_TYPE 5`；`PrfExeUop` 317 位、wb uop 109 位、ROB uop 83 位、LSU req uop 141 位。

| spec | 输入位 | 输出位 | 字段行数 | 单拍记录（按每元素整字节）|
| --- | --- | --- | --- | --- |
| **`alu_bank`**（6 实例，已实现，**已录制并核对**）| 6×(1+5+3+7+1+1+32×4)=876 | 6×33=198 | 12 | 实测 171 B/拍（2 万拍 3.3 MB）|
| `bru_bank`（4）| 4×~140 | 4×~70 | ~12 | ~0.3 KB |
| `mul_unit` / `div_unit` / `fpu`（各 1~2 实例）| ~1000（`FuInput` 含完整 `ExuInst`）| ~480 | ~45 | ~0.3 KB |
| **`exu` 整体** | **~8.4k**：`iss_entry` 22×318、`dec_bcast` 129、`rob flush` 1、`lsu2exe` 8×152、`csr rdata` 32 | **~10.6k**：`bypass` 28×110、`entry` 22×110、`fu_ready_mask` 22×64、`exu2rob` 22×84、`agu/sdu` 12×142、`exe2csr` 48、`exu2id` 116 | ~110 | ~3 KB（10 万拍 ≈ 300 MB，建议每程序 ≤3 万拍）|
| `exu_ctrl`（FU 作输入/输出）| 整 Exu 输入 + `Fu2ExuIO` 28×(2+386)：**未裁剪 ≈ 19.3k**；裁掉 ctrl 不读的 `ExuInst` 字段（pc/ftq/src preg…，每个约 290 位）后 ≈ 16.6k | 整 Exu 输出 + `Exu2FuIO` 28×(3+128+386)：**未裁剪 ≈ 25.1k**；裁剪后 ≈ 22.4k | ~130 | ~5 KB |

## 3. FP（`fadd.h` / `fmul.h` / `FPU.h`）

### 3.1 事实

- **实际在用的是 `FPUSoftfloat`**：`Exu.cpp:119` `new FPUSoftfloat("FPU", i, 10)`；它的 `impl_compute`（`FPU.h:137-246`）调 Berkeley softfloat（`libs/softfloat.a` 预编译库 + `libs/include/softfloat.h`，**库源码不在仓库里**，只能当黑盒 golden）。
- `FPURtl`（`FPU.h:275-380`）通过 `fadd_io_generator/fmul_io_generator` 调两个门级网表，但**从未被实例化**（grep 全树只有定义）。因此网表只是"可能的实现来源"，不是参考行为本身。
- 网表（[已验证]）：纯组合 AIG。`fadd.h`：12,409 行，67 个输入别名（`pi[0..66]` = `a[31:0]`、`b[31:0]`、`rm[2:0]`）、1 个常量 `n0=false`、**12,298 个二输入 AND 节点**（四种形态 `!a&&!b`/`!a&&b`/`a&&b`/`a&&!b`）、37 个输出（`po[0..31]`=结果，`po[32..36]`=fflags，其中 `fadd` 的 `po[35]` 恒 0）。`fmul.h`：9,673 行、9,562 个 AND 节点。节点按下标拓扑排序、**无前向引用**。无 `if`/`?:`/数组/状态。

### 3.2 网表 vs softfloat 差分实验 [已验证]（`tools/fpcmp.cpp`）

对每种 `(op ∈ {fadd, fmul}, rm ∈ 0..7)`：676 组角点（±0、最小/最大次正规、±Inf、qNaN/sNaN、1.0、2^23 附近…的两两组合）+ 300 万对随机（一半样本把 `b` 的指数调到接近 `a` 以覆盖消去/对齐路径）。softfloat 一侧用 `softfloat_roundingMode = rm`（与 `FPUSoftfloat` 相同，`rm=7` 映射为 0）。

| 结果位 | `rm=0..4`（RNE/RTZ/RDN/RUP/RMM）| `rm=5,6,7` |
| --- | --- | --- |
| fadd | **0 个不一致**（3,000,676 × 5）| 约 1/3 不一致 |
| fmul | **0 个不一致**（3,000,676 × 5）| 约 1/3 不一致 |

- `rm=5,6` 是 RISC-V 保留编码，真实程序不产生；`rm=7`（DYN）在 `FPUSoftfloat` 里被当作 RNE（`FPU.h:142`），网表对 `rm=7` 行为不同 → **RTL 必须在网表前把 `func3==7` 改写成 0**（该改写属于 FPU 包装，不在网表里）。
- `fflags`（`po[32..36]`）与 softfloat 的 `exceptionFlags` **不一致**（fadd 约 0.6%、fmul 约 33%），但整个模型**从不读取 fflags**（`grep fflags back-end include` 只在 `FPURtl` 局部变量里出现）→ 可忽略，但 SV 里 fflags 输出也可直接丢弃。
- 采样不是证明：3M 随机 ≠ 2^67 穷举。要更强的保证需要形式等价检查（把 softfloat 逻辑综合成 AIG 再 `cec`），超出本报告范围。

### 3.3 转 SV 的方案

1. **生成脚本** `scripts/aig2sv.py`（待写，规则很简单）：逐行正则 `bool nK = [!]nA && [!]nB;` → `assign nK = ~nA & nB;`（或把全部节点放进一个 `logic [N:0] n` 向量），输入 `pi[i]` → `a/b/rm` 位，输出 `po[i]`。约 2.2 万行生成物；**生成物不入手写区**，Makefile 里作为生成步骤（04 §1 表 "FP 网表" 行）。Verilator `-Wall` 下大量 `assign` 无风险；编译时间 [未测]。
2. **验证生成物**：写一个 Verilator C++ 测试台，每个向量同时调用 C++ `fadd_io_generator`（同一份网表）与 SV 网表，比较 37 个输出位：随机 ≥10^7 + 角点 + 每个输入位翻转的"单比特敏感度"集。因为两者是**同一张布尔图**，这个检查几乎是可穷举性质的（任何转换错误会立即在随机向量上暴露）。
3. **接到行为上**：`fpu` 包装负责 `rm` 改写（7→0）、`FSUB`（`b ^= 0x8000_0000` 再 `fadd`，`FPU.h:174-176`）、延迟（5/3）、结果选择。FADD/FSUB/FMUL 的**行为等价**依赖 §3.2 的差分结果。
4. **没有网表的指令**（手写 SV，golden = softfloat 库）：`FDIV`(lat 10)、`FSQRT`(10)、`FCVT.W.S/WU.S/S.W/S.WU`(3)、`FMIN/FMAX`、`FEQ/FLT/FLE`、`FCLASS`、`FSGNJ/N/X`(默认 5)。其中 FDIV/FSQRT 要逐位对齐 softfloat 的舍入与特殊值（次正规、NaN 规范化 `0x7fc00000`、五种舍入模式），工作量最大；FMIN/FMAX/FCLASS 要特别注意 `FPU.h:85-135` 的 RISC-V 变体（NaN/±0 处理）。
   验证方式：**差分随机测试，不依赖 trace**：一个小的 Verilator C++ 测试台把同一随机向量送给 SV `fpu` 与 softfloat 库，比较结果位（不比较 fflags）。也可以让该测试台直接**写 `.trc`**（输入=随机，输出=softfloat 结果），复用现有回放器。

### 3.4 FP 测试程序与覆盖（实测，73 个程序 ≤10 万拍；`data/exu_coverage_73prog_100kcyc.txt`）

只有 6 个程序真正把指令送进 FPU：`matmul_fpu`（4096 fadd + 4096 fmul）、`float_test`、`zfinx`、`zfinx-fcvt`、`zfinx-fdiv`、`zfinx-fsqrt`。

| 类别 | 被覆盖 | **未覆盖** |
| --- | --- | --- |
| 算术 | fadd 4098、fsub 2、fmul 4098、fdiv 29、fsqrt 24 | — |
| 转换 | fcvt.w.s 18、fcvt.wu.s 5、fcvt.s.w 9、fcvt.s.wu 7 | 溢出/NaN 输入的转换（仅少量 qNaN 操作数）|
| 比较/符号 | feq 11、flt 5、fle 2、fsgnjn 2 | **fsgnj、fsgnjx、fmin、fmax、fclass：0 次** |
| 舍入模式 | `rm=0` 8258、1:24、2:16、3:6、4:1、**7(DYN):5** | — |
| 操作数类别（fadd/fsub/fmul/fdiv 的 A 操作数）| norm 8027、zero 264、inf 6、qNaN 12、subnormal 1 | **sNaN、次正规结果、溢出/下溢、NaN 传播的 add/mul：基本没有** |

结论：真实程序对 FP 的**功能覆盖很薄**，FPU 验证主力必须是 §3.3 的 softfloat 差分随机测试；真实程序 trace 主要用于验证 `exu_ctrl` 里 FPU 的"忙/等待"协议（`fu_en_not_accepted_FPU` 3.4 万拍，`slot_held_fu_not_ready_FPU` 3.4 万拍）。

> 注意：`FPUSoftfloat::impl_compute` 对未支持编码用 `assert(0)`（`FPU.h` 多处，例如 `fclass` 要求 `func3==1`、`fcvt` 的 `rs2_sel` 只能 0/1）。这些是"不可达/UB"，RTL 取最简行为并登记，不要复刻 assert。

## 4. 录制方案（无需修改参考模型）

### 4.1 为什么不需要补丁

钩子在 `back.comb()` 之后：`Exu::comb_exec/comb_ready/comb_pipeline` 都已完成，`bt.exu->units[i]->in`（最终的 `FuInput`，含 `consume`）、`bt.exu->in.fu2exu->entry[i]`（最终 `FuOutput`：`ready` 为 consume 之后的值，`complete/inst` 为 `comb_issue` 之后）、`bt.exu->out.exu2fu->entry[i]`、`bt.exu->fu_inst_r[i]/fu_inst_r_1[i]`（槽位现态/次态）、以及 `bt.{prf2exe,dec_bcast,rob_bcast,lsu2exe,csr2exe,exe2prf,exe2iss,exe2lsu,exe2csr,exu2id,exu2rob}` 都是最终值。私有成员（FU 内部 `busy/done_cycle/pipeline`）插件以 `private=public` 编译可读。

### 4.2 注意事项（录 spec 时）

- `exu2fu_io.entry[i].inst` 在 `en=0` 时是**上拍残留**（`comb_begin` 只清 `en/consume/flush/masks`，不清 `inst`）→ 输入字段在 `en` 为 0 时无意义（输入字段本来就不比较，只是别误以为是 0）；`fu2exu_io.entry[i].inst`/`FuOutput.inst` 在 `complete=0` 时同理，输出字段要配 `when complete`。
- `FuOutput.complete` 在 `comb_issue` 之后求得，`ready` 在 `comb_consume` 之后求得，二者"同一拍的最终值"——与 RTL 端口的"settled 值"语义一致（`complete` 不依赖 `consume`，`ready` 依赖 `consume`）。
- MUL/DIV/FPU 的 `en` 在 FU 忙（槽被占住）时**每拍都为 1** 但被 FU 忽略（只有 `IterativeFU: !busy_1` / `FixedLatencyFU: pipeline_1.size()<limit` 时才真正接受）：RTL 的 FU 模块输入 `en` 要照此语义（DIV 忙时多个周期的 `en=1` 不能重复启动）。实测 `fu_en_not_accepted_DIV` 4.8 万拍、`..._FPU` 3.4 万拍，此语义被大量程序触发。
- `bypass[i]` 按 **fu_idx**（0..27）而不是端口号索引；`entry[]/exu2rob[]` 按端口号（0..21）。
- `ExuInst.dbg`（`DebugMeta`）不进 spec。

### 4.3 已演示

`examples/alu_bank.io`（6 个 ALU 实例，字段表达式如 `bt.exu->units[std::array<int,6>{1,4,7,9,10,11}[i0]]->in.inst.func3`）：用现有 `record.sh` 直接录制，dhrystone 2 万拍 3.3 MB；`examples/check_alu_trace.py` 用独立 Python ALU 对 9008 个 ALU 运算核对，**0 不一致**（跳过 617 个非基础 RV32I 的 op）——说明 `FuInput/FuOutput` 边界取值正确、位打包正确。

## 5. 覆盖盲区（实测）

方法：`tools/exu_cov.cpp`，73 个程序 × ≤10 万拍（126.5 万拍），原始数据 `data/exu_coverage_73prog_100kcyc.txt`（"#prog" = 出现的程序数）。

### 5.1 `exu_ctrl` 协议路径：覆盖良好

| 事件 | 次数 / 程序数 |
| --- | --- |
| ROB 全局冲刷（`rob_bcast.flush`）| 715 / 73 |
| 分支误预测（`dec_bcast.mispred`）| 13889 / 73；`clear_mask` 非零 43.4 万 / 73 |
| 端口内**多个 FU 同拍完成**（仲裁）| port0 4427 / 11 个程序；port1 782 / 12；port2 2429 / 9；port3 62 / **2** |
| ALU 结果因仲裁落败而"完成未消费"| 6990 / 17 |
| DIV 忙等（槽被占）| 4.8 万 / 12；FPU 忙等 3.4 万 / 6 |
| 同拍写回旁路峰值 | 一拍最多 18 个 FU 同时完成 |
| `exe2csr` 同时 `we&re` | 28 / 8 |
| LSU 回写（load 4 口、STA 4 口）| 50.9 万 / 67；38.1 万 / 69 |
| 多 BRU 同拍存活 | **未单独统计**（`max_ports_completing=4` 为全端口峰值）[未核实 BRU 之间的"最老 mispred"仲裁被多少次触发] |

### 5.2 叶子 FU 功能路径：盲区大

| FU | 覆盖 | 盲区 |
| --- | --- | --- |
| ALU 基础（add/sub/and/or/xor/sll/srl/srai/slt/sltu）| 都有（`alu_add` 120 万次…）| `alu_sra`（寄存器移位算术）**0 次**；`rol`、`binv` **0 次** |
| ALU Zba | sh1add 261、sh2add 2.8 万、sh3add 503 | — |
| ALU Zbb/Zbs/Zbc | **几乎只由 `bitmanip-boundary` 一个程序各打 1~3 次**：andn/orn/xnor/min/max/minu/maxu/pack/packh/clz/ctz/pcnt/sext.b/sext.h/ror/rev8/orc.b/bext/clmul/clmulr/clmulh；`bset` 在 linear_alg 里 3748 次、`bclr` 1 次 | 极端值（0、0xFFFFFFFF、shift=0/31/≥32 的 `rol/ror` 用 `32-shift`，shift=0 时 C++ `operand1 >> 32` 是 **UB**）基本没测；见下 |
| BRU | 6 种条件分支 × taken/not 全有、jal、jalr；jalr mispred 2948、cond mispred 万级 | **jal 从不 mispred**（predecode 已修正）；全部 `taken/nt` 组合在 `br_f3_*` 均出现 |
| MUL | f3=0/1/2/3 都有（mulh/mulhsu 各仅 `mul-longlong` 10/3 次）| 符号边界 |
| DIV | div/divu/rem/remu 都有；`div` 测试覆盖除零与 `INT_MIN/-1`（各 1~2 次，仅 1 个程序）| — |
| AGU | LD：f3=0/1/2/4/5；STA：0/1/2；`AGU_LD_atomic`/`AGU_STA_atomic` 仅 `atomic-boundary` 15/16 次 | 地址回绕（`vaddr` 64 位加再截断）|
| SDU | 普通 store 38 万；AMO：`atomic-boundary` 一个程序 10 种 op 各 1~3 次 | AMO 的符号比较边界 |
| FPU | 见 §3.4 | fsgnj/x、fmin/fmax、fclass、sNaN、次正规… |

> **UB 提醒**：`AluUnit` 里 `rol`/`ror` 写成 `(x << shift) | (x >> (32 - shift))`，`shift==0` 时 `x >> 32` 在 C++ 是未定义行为（x86/ARM 上结果依赖实现）。按 04 §1 "移位量 ≥ 位宽时 C++ 是未定义行为，RTL 需与实际测得行为一致并登记"：必须在 golden 生成器里实测该 shift==0 的实际输出，并写入 `deviations.md` 疑点栏。**部分核实**：本机 arm64 clang `-O3` 对变量移位量的独立小程序里，`rol(x,0)` 得到 `x`（移位量按 5 位取模，`x>>32` 等价 `x>>0`），恰好是正确的旋转结果；但参考模型 `-O3 -march=native` 构建里编译器是否对该表达式做了别的折叠 **[未核实]**，所以仍需在 golden 生成器里直接调用 `AluUnit` 取值。

### 5.3 随机生成器能驱动的类

| 类 | 随机化 | golden | 约束 |
| --- | --- | --- | --- |
| `alu`/`bru`/`agu`/`sdu` | **完全随机**（输入组合 = 指令字段 + 操作数），按 C++ `impl_compute` 写 trc（继承 `AluUnit` 等并 `#define protected public` 调用）| C++ FU 类 | 无；对 `op/func3/func7` 做"有效编码 + 少量无效编码（登记 UB）"的混合 |
| `mul_unit`/`div_unit`/`fpu` | 随机 `FuInput` 序列：随机 `en/consume/flush/flush_mask/clear_mask/inst`，golden = C++ FU 类 + 自己驱动 `sim_time` | C++ FU 类 + softfloat | 约束 `consume` 只在 `complete` 时、`en` 不在 `!ready` 的拍发新项（与 Exu 实际行为一致），另有少量违例用例看是否按 C++ 一致 |
| `exu_ctrl` | 约束随机较难（`Assert(!out.exe2prf->entry[p].valid)` 等不变量、op/端口匹配、flush 合法性）；**以真实程序 trace 为主** | C++ `Exu` | 后期可用真实 `Exu` + mock IO 做随机 |

## 6. 难度评估与任务拆分

| # | 任务 | 规模 | 依赖 | 难度 | 验证与覆盖缺口 |
| --- | --- | --- | --- | --- | --- |
| E1 | `alu`（含 Zba/Zbb/Zbs/Zbc 子集，clmul 循环）+ 随机 golden 生成器 | ~250 行 SV + 生成器 | 无 | ★★ | 真实程序只覆盖基础 ops → **生成器是主验证**；shift UB 登记 |
| E2 | `bru` + `agu` + `sdu` + `csr_fu` | ~150 行 SV | 无 | ★ | 真实程序覆盖基本充分；AMO 边界靠生成器 |
| E3 | `mul_unit`（2 项流水 + kill/clear + 倒计时）| ~100 行 | E 通用 FU 接口约定 | ★★ | 真实程序 11 个；kill/flush 注入靠生成器 |
| E4 | `div_unit`（`/`、`%`，特例，非流水，16 拍）+ 迭代 FU 骨架（`busy/done/kill/consume`）| ~120 行 | 同上 | ★★ | 12 个程序；除零/溢出 1 个程序 |
| E5a | FP：`aig2sv.py` + 网表 SV + 差分测试台 + `fadd/fsub/fmul` 包装（rm 改写）| 脚本 ~80 行、生成物 ~2.2 万行 | 无 | ★★ | 与 C++ 网表函数 + softfloat 差分（§3.3）|
| E5b | FP：`fdiv`、`fsqrt`（逐位对齐 softfloat）| ~300-400 行 | 无 | ★★★ | softfloat 差分随机（真实程序仅 29+24 次）|
| E5c | FP：`fcvt`×4、`fmin/fmax`、`feq/flt/fle`、`fclass`、`fsgnj*` | ~250 行 | 无 | ★★ | 同上；fmin/fmax/fclass/fsgnj 真实程序 0 次 |
| E5d | `fpu` 顶层：指令分类、延迟表（3/5/10）、迭代 FU 骨架（复用 E4）| ~100 行 | E4, E5a-c | ★★ | `zfinx*`/`matmul_fpu`/`float_test` trace 回放 |
| E6 | `exu_ctrl`（槽位、端口仲裁、dispatch/collect、写回/旁路、ROB/LSU/CSR 输出、分支仲裁、ready 掩码、flush/kill/clear）| ~500 行 | 接口 spec 先于实现；FU 当 trace 输入时可独立 | ★★★ | 真实程序 trace 覆盖好（§5.1）；多 BRU 同拍 mispred 仲裁 [待统计]；port3 多完成仅 2 个程序 |
| E7 | `exu` 整体集成 + 整 Exu spec 回放 | ~150 行连线 | E1-E6 | ★★ | 3 KB/拍的 trace，窗口 ≤3 万拍 |

**建议顺序**：E2 → E1（并行 E3/E4/E5a）→ E5b/c → E6 → E5d → E7。E6 的**接口 spec**（`exu_ctrl.io`，输入含 `Fu2ExuIO`、输出含 `Exu2FuIO`）可以第一天就由录制补全，这样 FU 与 ctrl 两条线完全并行。

## 7. 待核实 / 开放问题

1. `make cfg` 是否导出端口表（`GLOBAL_ISSUE_PORT_CONFIG`）与 `ISSUE_WIDTH/TOTAL_FU_COUNT/…` 派生常量；若没有，RTL 里 22 端口×FU 映射需要由生成脚本产出（不能手写数字）。
2. `dec_bcast.mispred` 从 `exu2id` 到 `Idu::br_latch`（`Idu.cpp:216`）再到 `dec_bcast` 的完整链路与拍数（只读到 `br_latch_1 = *in.exu2id`）。
3. `rol/ror` 在 `shift==0` 的 UB 实际输出（§5.2）；`AluUnit` 里其它 `default: Assert(0)` 分支（`func3` 全覆盖，故不可达）。
4. `FPUSoftfloat` 对非法/保留编码的 `assert(0)`；`rm=5,6` 在 softfloat 里的实际语义。
5. 网表 SV 的 Verilator 编译时间与仿真速度（2.2 万 `assign`，预期无问题但未测）。
6. 多 BRU 同拍 mispred 的"最老者"仲裁（`cmp_inst_age`，`Exu.cpp:17-22`）真实触发次数。
7. `Exu::comb_ftq_pc_req` 在 `Exu.h` 里声明但 `Exu.cpp` 无定义（死声明）。
8. 各 FU 的 `sim_time` 使用只核对了 `AbstractFU.h` 的三个基类；`FPUSoftfloat` 重写的 `calculate_latency` 已读。
