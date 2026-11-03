# exu_int 设计笔记（Exu 整数类叶子功能单元：ALU / BRU / AGU / SDU / CSR FU / MUL / DIV）

覆盖分析文档 `docs/analysis/exu-boundary.md` §6 的 E1–E4。FPU（fu 5）与 `exu_ctrl`/`exu` 不在本任务内。
RTL 在 `rtl/backend/exu_fu/`，spec 在 `spec/{alu,bru,agu,sdu,mul,div}_bank.io`、`spec/csr_fu.io`。

## 1. 对应的 C++

文件：`back-end/Exu/include/Fu.h`（`AluUnit`、`BruUnit`、`AguUnit`、`SduUnit`、`CsrUnit`、`MulUnit`、`DivUnit` 的
`impl_compute`）和 `AbstractFU.h`（三个基类 `SingleCycleFU`、`FixedLatencyFU`、`IterativeFU`，决定握手与时序）。
`Exu.cpp` 里 FU 只经 `AbstractFU::FuInput/FuOutput` 与 Exu 交互（`comb_fu_ctrl` → `comb_exu2fu_dispatch` →
`comb_fu_exec` → `comb_fu2exu_collect`），所以边界取在 FU 的 `in/out`（`bt.exu->units[i]->in`、
`bt.exu->in.fu2exu->entry[i]`），**不需要改参考模型**。

模块与 spec（一个 spec = 同类 FU 的一个 bank，下标 = 该类实例序号）：

| RTL 叶子 | bank 顶层 / spec | 实例（fu_idx）| C++ 基类 | 时序 |
| --- | --- | --- | --- | --- |
| `alu` | `alu_bank` ×6 | 1,4,7,9,10,11 | SingleCycleFU | 同拍 |
| `bru` | `bru_bank` ×4 | 24–27 | SingleCycleFU | 同拍 |
| `agu` | `agu_bank` ×8 | 12–15（LD），16–19（STA）| SingleCycleFU | 同拍 |
| `sdu` | `sdu_bank` ×4 | 20–23 | SingleCycleFU | 同拍 |
| `csr_fu` | `csr_fu` ×1 | 2 | SingleCycleFU | 同拍 |
| `mul_unit` | `mul_bank` ×2 | 0,6 | FixedLatencyFU(lat=2) | 接受后下一拍完成 |
| `div_unit` | `div_bank` ×2 | 3,8 | IterativeFU(lat=16) | 接受后第 16 拍完成，非流水 |

实例数 `ALU_NUM/BRU_NUM/LSU_AGU_COUNT/LSU_SDU_COUNT/MUL_MAX_LATENCY/DIV_MAX_LATENCY` 来自 `ttg_cfg_pkg`；
**MUL/DIV 的实例数（2、2）`ttg_cfg_pkg` 不导出**（是端口表里 `support_mask` 含 `OP_MASK_MUL/DIV` 的端口数，
`config.h:371-398`），暂放在 `exu_fu_pkg::MUL_NUM/DIV_NUM`（注释写明来源）。

### 输入（每个 FU 实际读取的字段）

| FU | 读取 |
| --- | --- |
| 所有 | `en`、`consume`（握手） |
| ALU | `op`、`func3`、`func7`、`src1_is_pc`、`src2_is_imm`、`pc`、`imm`、`src1_rdata`、`src2_rdata` |
| BRU | `op`、`func3`、`src1_en`、`src1_rdata`、`src2_rdata`、`pc`、`imm`、`ftq_pred_taken`、`ftq_next_pc` |
| AGU | `src1_rdata`、`imm` |
| SDU | `is_atomic`、`func7[6:2]`（spec 名 `amo_op`）、`src1_rdata`、`src2_rdata` |
| CSR FU | 无（`impl_compute` 为空）|
| MUL | `flush`、`flush_mask`、`clear_mask`、`func3[1:0]`、`src1_rdata`、`src2_rdata`、`rob_idx`、`dest_preg`、`dest_en`、`br_mask` |
| DIV | 同 MUL |

### 输出（有消费者的字段）

`complete`、`ready`（`Exu.cpp` 分发/槽位释放/`fu_ready_mask`）永远比较；其余只在 `complete` 时被 Exu 读取
（`comb_fu2exu_collect`：旁路 `Exu.cpp:361-366` 与端口扫描 `Exu.cpp:376-380` 均以 `complete` 为条件），故用 `when complete`：

| FU | 输出 | 消费者 |
| --- | --- | --- |
| ALU / AGU / SDU | `result` | ALU→PRF 写回/旁路（`to_exe_prf_wb_uop`）；AGU/SDU→`exe2lsu`（`to_exe_lsu_req_uop`）|
| BRU | `br_taken`、`mispred`、`diag_val` | `exu2rob`（Rob `comb_complete` 只对 `is_branch_uop` 读 diag_val/mispred/br_taken）、分支仲裁 `exu2id.redirect_pc=diag_val` |
| MUL / DIV | `result`、`done_rob_idx`、`done_dest_preg`、`done_dest_en`、`done_br_mask` | 旁路/PRF 写回（dest_preg,result,br_mask,dest_en）、ROB（rob_idx）、`is_br_killed`（br_mask）|

## 2. 硬件结构

### 2.1 单周期 FU（`exu_fu_sc_ctl` 握手：`complete = en`、`ready = !en | consume`）

* **alu**：`alu_decode`（把 C++ 的 op/func3/func7 嵌套 if-else 改成互斥的 AND 项，输出 `alu_ctl_t` 控制字）+
  共享数据通路：一个加/减法器（add、sub、sh1/2/3add：`opa << add_shamt` 后加，`sub` 取反）、signed/unsigned 比较器
  （slt/sltu 与 min/max/minu/maxu 共用）、位逻辑单元（and/or/xor，B 可取 `~opb` 或 `1<<shamt`：andn/orn/xnor/bclr/bset/binv
  都落在这里）、`alu_shift`（一个 64→32 漏斗移位器：右移 `{fill,x}`，旋转 `{x,x}`，左移/左旋走位反转：`rol=rev(ror(rev x))`）、
  `alu_clmul`（32×32 无进位乘法，clmul/clmulr/clmulh 取 `prod[31:0]/[62:31]/[63:32]`）、`alu_bitcnt`
  （clz/ctz 各一个 `ttg_first_set`，cpop 用 `ttg_popcount`，sext.b/h、rev8、orc.b；`ttg_onehot_mux` 选一）。
  最终结果用 `ttg_onehot_mux`（9 路）选择。没有任何单元被选中时结果为 0（对应 C++ 里 `result` 保持输入的 0）。
* **bru**：比较（==、有符号 <、无符号 <）→ 条件；目标 `pc+imm` 或 JALR 的 `(src1+imm)&~1`；`br_taken = JUMP | (BR & cond)`；
  `diag_val = taken ? target : pc+4`；`mispred = taken ? !(pred_taken & next_pc==target) : pred_taken`（`CONFIG_BPU` 已定义，走真实比较分支）。
* **agu**：`src1 + imm`（C++ 先 64 位加再截 32 位，等于 32 位回绕加）。
* **sdu**：非原子 `src2`；AMO 按 `amo_op` 选 add/xor/and/or/min/max/minu/maxu/swap，其余编码（LR/SC/保留）走 `default: src2`。
* **csr_fu**：只有握手。CSR 读数据由 Exu 在写回阶段覆盖（`Exu.cpp:461`）。

### 2.2 MUL（`mul_unit` = `mul_core` + `mul_pipe`）

* `mul_core`：一个 33×33 有符号乘法器，操作数按 mulh/mulhsu/mulhu 做符号/零扩展，`func3==0` 取低 32 位否则取 `[63:32]`。
  乘积在**接受拍**算出（与 C++ `impl_compute` 在接受时算一致），随负载进入流水。
* `mul_pipe`：DEPTH(=MUL_MAX_LATENCY=2) 项**压缩**的按序结果流水（`valid_q[]`、`uop_q[]`=`{result,rob_idx,dest_preg,dest_en,br_mask}`、
  `rem_q[]` 倒计时）。每拍：①kill（`flush` 且 全 1 `flush_mask` 或与 `br_mask` 相交）②clear（`br_mask &= ~clear_mask`，作用于存活项）
  ③accept（`en` 且 kill 之后**未满**——判满在 pop 之前，与 C++ 的 `comb_issue` 先于 `comb_consume` 一致）
  ④complete = 最老存活项 `rem==0`；`consume` 弹出最老项 ⑤`ready` = pop 与 accept 之后未满。
  下一状态：存活项按"其下方被移除的项数"压缩（`ttg_popcount` 求新下标），新项放最后（每个目的槽一个 `ttg_onehot_mux`）。
  `rem`：C++ 的 `done_cycle - sim_time`。新项 `done = t + LAT - 1`，所以次拍 `rem = LAT-2`，之后每拍减 1 并饱和在 0
  （完成后不被消费就一直保持完成，`has_finished` 用 `<=`）。LAT=1 的 FU 会在接受拍就 complete（需要组合旁路），故参数断言 `DEPTH>=2`。

### 2.3 DIV（`div_unit` = `exu_iter_ctl` + `div_core` + 负载寄存）

* `exu_iter_ctl`（迭代 FU 骨架，FPU 可复用，延迟由 `lat_m1` 输入给出）：状态 `busy_q`、`cnt_q`（= `done_cycle - sim_time`）、`br_mask_q`。
  `kill`→`live`；`complete = live & cnt==0`；`accept = en & !live`（busy 在 consume 之前判）；`pop = consume & complete`；
  `busy_d = accept | (live & !pop)`；`ready = !busy_d`；`run = live & cnt!=0`（给数据通路的迭代使能）。
  `done_br_mask = br_mask_q & ~clear_mask`（clear 在 comb_ctrl 里先于 complete 输出）。
* `div_core`：**真正的迭代除法器**，不用 `/`、`%`：恢复除法，每拍 `32/LAT = 2` 步（`div_step` 串 2 级），接受拍即做第一拍的 2 步
  （操作数取绝对值 → 状态），之后 15 拍各 2 步，共 16 拍 32 步，第 16 拍 `cnt==0` 完成。符号处理：有符号运算先取绝对值，
  商在符号不同且除数非 0 时取负，余数取被除数符号。除数为 0 时恢复除法每步都"放得下"，自然得到商全 1、余数=被除数，
  `INT_MIN/-1` 由绝对值运算自然得到商 `INT_MIN`、余数 0，都不需要特判。
  与 C++ 的不同只在内部：C++ 在接受拍一次算出整个商再倒计时，RTL 逐拍迭代，**FU 边界行为逐拍一致**。
  时序提示：接受拍路径 = 取绝对值 + 2 步减法，若要降到更短需把第一步推迟一拍（会改变延迟，需 Exu 配合，本任务不做）。

### 2.4 C++ 数据结构 → 硬件结构

| C++ | RTL |
| --- | --- |
| `FixedLatencyFU::pipeline`（deque，`pipeline_1` 拷贝）| `mul_pipe` 的 `valid_q/uop_q/rem_q` 压缩数组 + 组合 kill/clear/pop/push（无拷贝）|
| `IterativeFU::{current_inst,done_cycle,busy}` | `exu_iter_ctl` 的 `busy_q/cnt_q/br_mask_q` + `div_unit` 的负载寄存 + `div_core` 状态 |
| `done_cycle <= sim_time` | 倒计时 `cnt==0` / `rem==0`（饱和）|
| `ExuInst` 全部字段 | 只保留消费者读的：`{result, rob_idx, dest_preg, dest_en, br_mask}`（见 §4）|
| `AluUnit` 嵌套 if/else | `alu_decode` 互斥选择位 + 共享数据通路 |

## 3. 一拍内的数据流

* 单周期 FU：纯组合；`complete` 只依赖 `en`，`ready` 依赖 `en`/`consume`（与 C++ `comb_consume` 一致：`ready` 是 consume 之后的值，
  所以 Exu 侧 `consume` → `ready` → 槽位释放有一条组合路径，`complete` 不依赖 `consume`，无环）。
* MUL/DIV：C++ 单拍内顺序 `comb_begin`（状态 → 初值）→ `comb_ctrl`（kill/clear）→ `comb_issue`（接受、complete）→ `comb_consume`（弹出、ready）。
  RTL 展开成数据流：`kill → surv/clear → accept(判满) → complete → pop → keep/ready → 下一状态`。
  **无 stale 读、无同拍覆盖**：C++ 里 `FuOutput.inst` 在 `complete=0` 时是上拍残留，Exu 从不读，RTL 的该输出在无效时不关心。
* `en` 在 FU 忙/满时每拍都可为 1（槽位占着）：RTL 的接受条件包含"未忙/未满"，忙时的 `en` 被忽略，不会重复启动。

## 4. 与 C++ 的差异点、放宽/删除/不复刻清单

### 4.1 放宽（`when complete`，消费者已核对）

* 所有 FU 的 `result`/`br_taken`/`mispred`/`diag_val`/`done_*`：读取点只有 `Exu::comb_fu2exu_collect` 里以
  `in.fu2exu->entry[i].complete` 为条件的两处（旁路与端口扫描，Exu.cpp 的 `if (in.fu2exu->entry[i].complete)` 和
  `if (in.fu2exu->entry[map_entry.fu_idx].complete)`），`comb_fu_exec` 的拷贝（`in.fu2exu->entry[i].inst = units[i]->out.inst`）不被消费。
  变异检查仍有效（§5）：`when` 的输出在 `complete` 时严格比较。

### 4.2 删除（spec 与 RTL 都没有）

* 直通字段（`rob_idx`、`dest_preg`、`br_id`、`ftq_idx`、`stq_idx` 等）：单周期 FU 不改它们，由 Exu 顶层（E6）核对；
  只有 MUL/DIV 因为负载要在 FU 里停留若干拍，才带 `rob_idx/dest_preg/dest_en/br_mask`（这四项是 `to_exe_prf_wb_uop`/`to_exu_rob_uop`/
  `is_br_killed` 读的全部）。
* **恒 0 的输出字段**（已在真实程序上用探针 spec 验证，见 §5，并在生成器里断言）：
  BRU、CSR FU 的 `result`；MUL/DIV 的 `diag_val`、`mispred`、`br_taken`、`page_fault_inst`、`flush_pipe`。原因：`ExuInst` 由
  `from_prf_exe_uop` 构造，`result/diag_val/mispred/...` 默认 0，这些 FU 的 `impl_compute` 不写它们。
  **集成提示（E6/E7）**：Exu 顶层必须把 BRU/CSR 的 `result` 当 0、MUL/DIV 的 `op`（恒 `UOP_MUL`/`UOP_DIV`，由 `support_mask` 决定）、
  `diag_val/mispred/br_taken/page_fault_inst/flush_pipe`（恒 0）自己补上；CSR 的 `result` 在 `exe2csr.re` 时被 `csr2exe.rdata` 覆盖。
* `ftq_resp_valid`（BRU 不读）、`BruUnit` 的 `CONFIG_ORACLE_STEADY_FETCH_WIDTH && !CONFIG_BPU` 分支（参考构建里 `CONFIG_BPU` 已定义，该分支不存在）。
* `op` 只剩 ALU 与 BRU 的 `op`：MUL/DIV/AGU/SDU/CSR 的 `op` 由端口 `support_mask` 决定，FU 不读。
* `flush` 输入保留（C++ 读 `in.flush`），虽然 Exu 保证 `flush=0 ⇒ flush_mask=0`；RTL 严格按 `flush && (全 1 || 相交)` 实现，随机生成器 1% 的拍故意违反该不变量以证明 RTL 忽略 `flush=0` 时的 mask。

### 4.3 不复刻 / 取最简行为（均为 C++ 不可达，真实 trace 与 Exu 约束下不出现）

| C++ 位置 | 行为 | RTL |
| --- | --- | --- |
| `Fu.h` `AluUnit`：`op == UOP_JUMP` 时 `operand2 = 4` | ALU 端口 `support_mask`（`OP_MASK_ALU`）不含 JUMP，不可达 | 不实现；ALU 只会见到 ADD/FENCE/ECALL/EBREAK/SFENCE_VMA/FENCE_I/MRET/SRET/WFI，生成器只产生这些 op |
| `AluUnit`：`op` 为 ADD 以外且非 WFI（FENCE/ECALL/…）→ `op1 + op2` | 可达 | **复刻**（`alu_decode` 的非 ADD 分支）；WFI → 0 |
| `AluUnit`：各 func3 下未列出的 func7/imm 组合（如 `rev8` 的 shamt≠24、`clz` 之类子码未列出） | C++ 不写 `result`，保持输入的 0 | **复刻**（无选中单元 ⇒ 0），因为是免费的；依赖"进入 FU 的 `ExuInst.result` 恒为 0"（`from_prf_exe_uop`）|
| `AluUnit::default: Assert(0)`、`MulUnit/DivUnit::default: Assert(0)` | func3 取值全覆盖或 func3 范围被 op 限定 | spec 里 MUL/DIV 只有 `func3[1:0]`，`Assert` 不复刻 |
| `BruUnit`：`op==BR` 且 `func3` 为 2/3（非分支编码）| C++ 保持初值 `br_taken=true` | **复刻**（`default: cond_taken = 1`，免费）|
| `BruUnit`：`op` 非 BR/JUMP | `br_taken=false` | 自然得到（不选 BR/JUMP 即不跳）|
| `AguUnit`：`uint64_t vaddr` 加法 | 结果赋给 32 位 `result` | 32 位回绕加 |
| `SduUnit`：`default: result_data = op2`（LR/SC/保留 AMO 编码）| 可达（LR/SC 的 STD uop 是否出现未验证）| **复刻** |

### 4.4 参考模型疑点（不修、只登记，建议协调者收入 `deviations.md` 疑点栏）

1. **`rol`/`ror` 移位量为 0**（`Fu.h` ALU，`(x << s) | (x >> (32 - s))`）：`x >> 32` 是 C++ 未定义行为。实测：生成器对同一份
   参考源码分别用 `-O0` 与 `-O3 -march=native`（与 refsim 相同的优化选项）编译，对 `rol/ror` 移位量为 0 的向量（每个 trace 数百个）
   得到逐字节相同的 trace，结果均为 `x`（即正确的旋转）。RTL 按"正确旋转"实现（`alu_shift` 里 `{x,x} >> 0`），与实测一致。
   真实程序里 `rol`/`ror` 基本不出现（`bitmanip-boundary` 一个 `ror`），该分支只能靠随机 trace 验证。登记为 D-EXU-1（疑点，行为与实测一致，无需偏差）。
2. **MUL 的槽位释放与"满"**（`AbstractFU.h` `FixedLatencyFU::comb_consume` + `Exu::comb_fu2exu_collect` 槽位释放）：接受新项后若流水满（2 项），
   `ready=0` 导致 Exu 槽位不释放，次拍 `en` 仍为 1。若次拍恰好另一项（更老、带该次 flush 命中的 br_mask 的那项）被 flush 杀掉而该槽位指令
   （与流水里那份同一条指令，br_mask 相同）未被杀，则流水未满而槽位仍有效 → **同一条 MUL 被接受第二次**。只读代码得出，**未做实验**，
   属于 E6（`exu_ctrl`）集成时需要留意的行为；本任务的 FU 与 C++ 逐拍一致，所以会同样复现。
3. **`IterativeFU::comb_issue` 的接受发生在 `comb_consume` 之前**：FU 完成并被 consume 的同一拍不会接受新 `en`（`!busy_1` 判在 pop 之前），
   `ready` 在接受之后才求。属于已知时序，已复刻（`accept = en & !live`），仅提示 Exu 侧不要假设"完成即可同拍接新活"。

### 4.5 隐含依赖（04 §3 表格补充）

无 stale 读、无同拍多次覆盖。唯一的"跨边界依赖"：`ExuInst.result` 进入 FU 前恒为 0（见 4.3 第三行）。

## 5. 验证

* **spec**：`spec/alu_bank.io`（12 字段/实例×6）、`bru_bank.io`（12×4）、`agu_bank.io`（6×8）、`sdu_bank.io`（8×4）、`csr_fu.io`（4×1）、
  `mul_bank.io`（19×2）、`div_bank.io`（19×2）。
* **trace**：每个 spec 录 61 个 gate 程序 + `scripts/progs.txt` 的 12 个（`GATE_CYCLES=30000`，大程序上限见 progs.txt），
  外加随机 trace（见下）。记录数和覆盖在最终报告里给出（`tests/exu_fu/cov.py` 统计每个 C++ 决策分支被多少个 uop 命中）。
* **随机 trace 生成器** `tests/exu_fu/rand_fu.cpp` + `run_rand.sh`：直接驱动参考模型的 `AluUnit/BruUnit/AguUnit/SduUnit/CsrUnit/MulUnit/DivUnit`
  （经 `AbstractFU` 接口 `comb_begin/comb_ctrl/comb_issue/comb_consume/seq`），把 FU 边界写成 trc。**C++ 类即 golden**。
  `run_rand.sh` 对同一生成器分别用 `-O0` 与 `-O3 -march=native` 编译并要求两份 trace 字节相同（固定 UB 行为）。不定义 `NDEBUG`，参考模型的 `Assert` 全开，
  保证激励合法。激励约束（均依据 C++ 与 Exu 的实际行为）：
  * ALU：`op` 只取 ALU 端口支持的 op；func7 85% 取有含义的值（0x00/0x20/0x10/0x05/0x04/0x30/0x24/0x14/0x34）、15% 随机；
    imm 低 5 位覆盖 Zbb 子码与 rev8/orc.b 的 shamt；操作数一半取角点值（0、1、-1、INT_MIN/MAX、移位量边界 31/32/33…）。
  * BRU：`op` 为 BR/JUMP；func3 90% 取分支编码、10% 全随机（含 2/3）；`ftq_next_pc` 35% 取等于真目标；pred_taken 随机；`src1_en` 随机。
  * AGU/SDU：操作数角点；SDU `amo_op` 覆盖 0..31（含 LR/SC/保留）。
  * MUL/DIV：随机 `en/consume/flush/flush_mask/clear_mask`，参数组合覆盖 FU 空闲、常满、频繁 flush、从不 flush；`func3` 在 spec 范围内；
    除数 0、`INT_MIN`、`-1`、操作数相等等角点；`sim_time` 每拍加 1。C++ 的 FU 类对任意输入序列都有定义（`consume`、`en` 在忙时被忽略），
    所以不需要额外约束；1% 的拍违反"`flush=0 ⇒ flush_mask=0`"。
* **变异检查**：见下表（`mutation runner` 对每个变异单独编译，分别对真实程序 trace 与随机 trace 回放，报告首个失败的 trace@记录 字段）。

| FU | 变异 | 真实程序 trace 首个抓到 | 随机 trace 首个抓到 |
| --- | --- | --- | --- |
| alu | slt 用无符号比较 | bitmanip-boundary@590 result | rand1@7 result |
| alu | sub 不要求 reg 形式 | add-longlong@79 result | rand1@19 result |
| alu | binv 去掉（real 中 0 次） | 未抓到 | rand1@51 result |
| alu | 寄存器形式 sra 去掉（real 中 0 次） | 未抓到 | rand1@10 result |
| alu | rol 不再旋转（real 中 0 次） | 未抓到 | rand1@175 result |
| alu | clmulr 切片错位 | bitmanip-boundary@479 result | rand1@64 result |
| alu | sh2add 移位量错 | bitmanip-boundary@371 result | rand1@61 result |
| alu | maxu 当有符号比较 | bitmanip-boundary@667 result | rand1@96 result |
| alu | clz(0) 返回 31 | bitmanip-boundary@94 result | rand1@11640 result |
| alu | orc.b shamt 检查 7→6 | bitmanip-boundary@314 result | rand1@376 result |
| alu | pc 操作数被扰动 | add-longlong@60 result | rand1@4 result |
| alu | ready 忽略 consume 极性 | add-longlong@36 ready | rand1@3 ready |
| bru | 目标比较 == 变 != | add-longlong@60 mispred | rand1@4 mispred |
| bru | BGE 极性反 | cjpeg@1667 br_taken | rand1@8 br_taken |
| bru | JALR 不清 bit0 | coremark@91908 diag_val | rand1@5 mispred |
| bru | BLTU 当有符号 | cjpeg@10570 br_taken | rand1@31 br_taken |
| bru | func3=2/3 默认不跳（real 中 0 次） | 未抓到 | rand1@4 br_taken |
| bru | 预测不跳且不跳时误判 | bubble-sort@178 mispred | rand1@4 mispred |
| bru | 不跳时 diag_val 错 | add-longlong@237 diag_val | rand1@3 diag_val |
| agu | 加改减 | add-longlong@83 result | rand1@3 result |
| agu | 进位丢失 | software-interrupt-vectored@600 result | rand1@3 result |
| agu | ready 极性 | add-longlong@83 ready | rand1@3 ready |
| sdu | amominu 当有符号 | atomic-boundary@548 result | rand1@29 result |
| sdu | amomax 选择反 | atomic-boundary@478 result | rand1@41 result |
| sdu | 普通 store 取 src1 | add-longlong@116 result | rand1@3 result |
| sdu | 未列出的 AMO 编码取 src1 | atomic-boundary@110 result | rand1@3 result |
| sdu | amoadd 改减 | atomic-boundary@268 result | rand1@13 result |
| csr_fu | complete 依赖 consume | add-longlong@18 complete | rand1@4 complete |
| csr_fu | ready 极性 | add-longlong@18 ready | rand1@3 ready |
| mul | mulhsu 符号错 | mul-longlong@461 result | rand1@16 result |
| mul | mulh 的 rs2 当无符号 | mul-longlong@100 result | rand1@29 result |
| mul | 满时仍接受（真实中 0 次） | 未抓到 | rand1@17 ready |
| mul | 全 1 flush_mask 不清空（real 0 次） | 未抓到 | rand1@35 complete |
| mul | clear_mask 不作用于 br_mask | coremark10@320 done_br_mask | rand1@39 done_br_mask |
| mul | flush 位被忽略（real 0 次） | 未抓到 | rand1@259 result |
| mul | 延迟 +1 | cjpeg@269 complete | rand1@4 complete |
| mul | ready 在 pop 之前求 | coremark10@3560 ready | rand1@13 ready |
| div | 有符号除数 0 商取负（real 0 次） | 未抓到 | rand1@1112 result |
| div | 延迟 -1 | coremark10@316 complete | rand1@18 complete |
| div | 接受忽略同拍 kill（real 0 次） | 未抓到 | rand1@92 ready |
| div | 全 1 flush_mask 不杀 | smc-div@692 ready | rand1@65 ready |
| div | clear_mask 不作用于 br_mask | dhrystone@1908 done_br_mask | rand1@38 done_br_mask |
| div | 余数符号错 | div@475 result | rand1@93 result |
| div | ready 取 busy_q | coremark10@301 ready | rand1@3 ready |
| div | 恢复比较 >= 变 > | coremark10@317 result | rand1@38 result |
| div | 空闲时 consume 也释放（real 0 次） | 未抓到 | rand1@6 ready |
| div | en 就重载负载（real 0 次） | 未抓到 | rand1@19 done_rob_idx |

共 47 个变异，全部被抓到；其中 11 个只有随机 trace 能抓到（真实程序覆盖不到）。（`binv`、寄存器形式 `sra`、`rol` 在真实程序里 0 次，印证分析文档 §5.2。变异均先确认能编译通过、不是等价变异：另外两个变异——MUL 无 complete 即 pop、`rol` 在移位量 0 时置零——在 LAT=2 / 数学上是等价变异，已剔除。）

