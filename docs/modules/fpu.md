---
module: fpu
area: backend
rtl: rtl/backend/fpu
spec: fpu*
status: green
lockstep: trace 回放 + back_top 整程序 68/68 + softfloat 差分
mutants: 33/35（2 等价）
note: 手写，非网表
---

# fpu 设计笔记（Exu 的浮点单元，分析文档 E5a–E5d）

## 1. 对应的 C++
- `back-end/Exu/include/FPU.h` 类 `FPUSoftfloat`（继承 `AbstractFU.h` 的 `IterativeFU`），在 `Exu.cpp:119` 创建，**只有 1 个实例**：
  `Exu::units[5]`（发射口 1：DIV(3)、ALU(4)、FPU(5)，`config.h` 的 `GLOBAL_ISSUE_PORT_CONFIG`）。
  **`FPURtl`、`fadd.h`、`fmul.h` 在 Exu 里是死代码**（`FPURtl` 从未被实例化）；真正的行为是 Berkeley softfloat（`libs/softfloat.a`，
  RISC-V specialisation：NaN 一律 `0x7FC00000`，f→int 饱和，`fcvt.wu.s` 负数→0）。网表只是"可以机械转 SV 的实现来源"，
  **按协调者决定：RTL 全部手写，不使用网表**（网表 22k 行 AIG 不可读）。网表和转换脚本只留在 `tests/fpu/` 作为可选的交叉验证参考，不进 `rtl/`。金标准一律是 softfloat。
- FU 边界 = `AbstractFU::FuInput`（`en, consume, flush, flush_mask, clear_mask, inst`）/`FuOutput`（`ready, complete, inst`）。
  钩子在 `BackTop::comb()` 之后，`units[5]->in`（含 consume 终值）和 `in.fu2exu->entry[5]`（`ready` 为 consume 之后的值）都是终值；
  **参考模型不需要改**（沿用 `docs/analysis/examples/alu_bank.io` 的做法）。
- 语义（`FPU.h impl_compute`，`AbstractFU.h IterativeFU`）：
  - `inst.func7` 选指令（`func7>>2`：0 fadd、1 fsub、2 fmul、3 fdiv；其余按整 func7：0x2C fsqrt、0x10 fsgnj*、0x14 fmin/max、0x50 feq/flt/fle、
    0x70 fclass、0x60 fcvt.w[u].s、0x68 fcvt.s.w[u]），`inst.imm&0x1F` 是 rs2 选择（0 有符号/1 无符号），`func3` 是舍入模式（`7`→RNE）或子操作。
  - zfinx：浮点值就在整数寄存器里，没有 NaN-boxing（`FPU.h` 直接用 32 位 `src1_rdata/src2_rdata`），不需要处理 boxing。
  - 结果在**接受时**一次算出（`impl_compute`），延迟由 `calculate_latency` 决定：fadd/fsub/其余 5、fmul/fcvt.w/fcvt.s 3、fdiv/fsqrt 10；
    `done_cycle = sim_time + lat`，`complete = busy && done_cycle <= sim_time`（接受后第 lat 拍）。单项、非流水：忙时 `en` 被忽略。
  - `comb_ctrl`：`flush && busy && (flush_mask==全1 || br_mask&flush_mask)` 杀掉在途项；`clear_mask` 清 `br_mask`。
    `comb_issue`：在"杀"之后 `en && !busy` 接受；`comb_consume`：`consume && complete` 释放；`ready = !busy`（consume 之后）。
- 输入（只列 FU 真正读的）：`en consume flush flush_mask clear_mask`、`inst.{func3, func7, imm[0], src1_rdata, src2_rdata, br_mask}`，
  加上直通 Exu 的 `dest_preg dest_en rob_idx`。输出：`ready complete`、`inst.{result, br_mask, dest_preg, dest_en, rob_idx}`（仅 complete 时）。
  - Exu 读取 FU 输出 inst 的位置：`Exu.cpp:423`（`if complete` → `to_exe_prf_wb_uop`：dest_preg/result/br_mask/dest_en/op）、`Exu.cpp:447`
    （`if complete` → `to_exu_rob_uop`：diag_val/result/rob_idx/mispred/br_taken/page_fault_inst/op/flush_pipe）。FP uop 的
    diag_val/mispred/br_taken/page_fault_inst/flush_pipe 恒为 `ExuInst` 默认 0（`from_prf_exe_uop` 只拷贝 `PrfExeUop` 字段），`op` 恒为 `UOP_FP`
    （发射口按 `OP_MASK_FP` 路由），所以不进 spec；这些常量由 exu_ctrl 层补。其余 ExuInst 字段（pc、ftq_*、src*_preg…）FU 不读，也不进 spec。

## 2. 硬件结构
```
 func7/func3/imm0 ─► fpu_decode ─► kind(18 位独热) , latency-1 ─┐
 en/consume/flush/masks/br_mask ─► fpu_ctrl (busy, 倒计数, br_mask) ─► accept, complete, ready, br_mask
 accept ─► fpu_slot (kind, func3, src1, src2, dest_preg, dest_en, rob_idx 寄存) ─► fpu_compute(kind,func3,a,b) ─► result
```
- **多周期路径而不是流水线**：参考模型接受时就把结果算好、等 lat 拍再给出。RTL 把操作数/类型寄存在 `fpu_slot`，结果是这些寄存器的**纯组合函数**，
  只在 `complete`（≥3 拍之后）才被消费，所以"所有运算单元并联 + 独热选择"在时序上是多周期路径（SDC 里设 multicycle，周期数 = 延迟表）；
  不另存结果寄存器。这样 fdiv/fsqrt 不需要真的迭代 10 拍，延迟 5/3/10 只是计数器。
- 子模块：
  | 模块 | 职责 |
  | --- | --- |
  | `fpu_pkg` | 指令类型（独热下标）、延迟常量、舍入模式解码（softfloat 的 func3 视图）、通用函数 |
  | `fpu_decode` | func7/func3/imm0 → kind 独热 + 延迟-1 |
  | `fpu_ctrl` | `IterativeFU` 的 busy/倒计数/杀/clear/accept/complete/ready（`comb_ctrl/issue/consume`） |
  | `fpu_slot` | 在途 uop 的寄存器（接受时装载） |
  | `fpu_compute` | 各运算并联 + `ttg_onehot_mux` 选结果 |
  | `fpu_addsub` | 手写加减：按幅值排序、小操作数对齐（右移 jam sticky）、加/减、`fpu_clz` 规格化、`fpu_round_pack`；fsub 翻 b 符号；完全抵消的零符号由舍入模式定（RDN 为 -0） |
  | `fpu_mul` | 手写乘法：次正规规格化、24×24 乘积、进位位判断、`fpu_round_pack` |
  | `fpu_div`(+`fpu_div_array`) | 单精度除法：28 级恢复除法阵列 + 规格化/特殊值 + `fpu_round_pack` |
  | `fpu_sqrt`(+`fpu_sqrt_array`) | 单精度开方：27 级逐位开方阵列 |
  | `fpu_round_pack` | 舍入打包（次正规右移 jam、5 种舍入、上溢到 inf/最大有限数），div/sqrt/i2f 共用 |
  | `fpu_cvt_f2i` / `fpu_cvt_i2f` | fcvt.w[u].s（RISC-V 饱和）/ fcvt.s.w[u] |
  | `fpu_cmp` `fpu_minmax` `fpu_sgnj` `fpu_fclass` | feq/flt/fle、fmin/fmax、fsgnj*、fclass（精确按 softfloat/`FPU.h` 的变体） |
  | `fpu_unpack` `fpu_clz` `fpu_norm` | 字段拆分与类别、前导零计数、次正规规格化 |
- 状态：`busy_q`(1)、`remaining_q`(4，最大 9)、`br_mask_q`(64)、slot 里 `kind_q`(18)+`func3_q`(3)+`src1/2_q`(64)+`dest_preg_q`(7)+`dest_en_q`+`rob_idx_q`(7)。
- C++ → 硬件对应：`done_cycle/sim_time` 比较 → 倒计数器（装 lat-1，到 0 即 complete，等价于 `sim_time+lat <= sim_time'`）；
  `current_inst`（含结果）→ slot 寄存器 + 组合结果；`impl_compute` 里的 switch → 独热 kind + 并联运算 + 独热 mux。
- **与 Isu 延迟唤醒/FU 忙闲的对应**：FU 单项非流水，`ready=~busy_d`（Exu 据此决定槽位释放/`fu_ready_mask`），`complete` 的拍号严格等于 C++ 的 `sim_time+lat`
  （5/3/10），Isu 的 FP 倒计数槽（`isu_wake_src.sv`）按同一延迟表唤醒，FU 本身不产生唤醒信号；FU 级 trace 已逐拍验证 ready/complete。
- **舍入与 NaN 取舍**：所有运算共享 `fpu_rm_decode`（rm=7→RNE，5→RTZ，6 不实现）和 `fpu_round_pack`（次正规 jam、5 种舍入、上溢到 inf/最大有限数）；
  任何 NaN 结果（含 sNaN 输入、inf-inf、0*inf、0/0、sqrt 负数）一律规范 NaN `0x7FC00000`（softfloat RISC-V specialisation，不传播 payload）；
  fmin/fmax 一个 NaN 返回另一个操作数的原始位型、两个 NaN 返回规范 NaN。fflags 不计算（`Exu.cpp`/全树无读取点，见下）。

## 3. 一拍内的数据流
`fpu_ctrl`：`killed = busy_q & flush & (flush_mask==全1 | br_mask_q&flush_mask != 0)`；`alive = busy_q & ~killed`；
`accept = en & ~alive`（杀之后的空闲，所以"杀掉旧项的同拍接受新项"与 C++ 一致）；`complete = alive & remaining_q==0`
（C++ 的 complete 在杀之后求，所以被杀的项这拍不 complete；接受的同拍绝不 complete，因为 lat≥3）；
`busy_d = accept | (alive & ~(consume & complete))`；`ready = ~busy_d`；`br_mask_d = accept ? in_br_mask(不受 clear_mask 影响) : br_mask_q & ~clear_mask`；
输出 `out_inst_br_mask = br_mask_q & ~clear_mask`（C++ 的 `out.inst` 取自 comb_ctrl 清除之后的 `current_inst_1`）。
没有 stale 读、没有同拍多次覆盖；无隐含依赖登记项。

## 4. 与 C++ 的差异点、放宽与消费者核对
**放宽（`when out_complete`）**：`out_inst_result/br_mask/dest_preg/dest_en/rob_idx`。C++ `out.inst` 在 `complete=0` 时是上一项的残留。
消费者核对：Exu.cpp 对 `fu2exu->entry[i].inst` 只有 404（赋值）、423（`if complete` 内）、447（`if complete` 内）三处读取；grep 全树无其他读取点（tbhook/difftest 不读）。
**删除的字段**：`op`（输入输出都是常量 `UOP_FP`）、输入里 FU 不读的全部 ExuInst 字段、`imm` 的高 31 位（C++ 只读 `imm&0x1F`，且仅 0/1 合法）、
输出里恒 0 的 `diag_val mispred br_taken page_fault_inst flush_pipe`、`fflags`（没人读）。
**选择不复刻的 C++ 行为**（均登记在此，报告里逐条列出）：
1. `impl_compute` 里的 `assert(0)` 分支（reserved func7、`fcvt` 的 rs2 选择≥2、`fsqrt/fclass` 的 rs2≠0、fsgnj/fminmax/fcmp 的保留 func3、fclass 的 func3≠1）：
   RTL 对这些编码"不选任何 kind、结果为 0"（延迟按默认 5），trace/随机生成器不出现。fsqrt/fclass 的 rs2≠0 RTL 不检查（当作合法）。
2. `inst.op != UOP_FP` 的 default 分支（当作 fadd）：该 FU 只挂 `OP_MASK_FP`，不可达。
3. **rm=6**：这个 softfloat 构建里 `softfloat_roundingMode=6` 是 round-to-odd（`SOFTFLOAT_ROUND_ODD`），而 RV32F 的 rm=5/6 是保留编码、
   译码出来的 F 指令不会带；差分测试里 rm=6 对除 fsgnj/cmp/class 之外所有指令都不一致（已验证只有 rm=6 不一致）。RTL 把 6 当 RTZ，**不实现 round-to-odd**，
   生成器不产生 rm=6。rm=5 按 softfloat 是 RTZ，RTL 一致（生成器少量产生）；rm=7 按参考模型当 RNE（网表前改写）。
4. 浮点异常标志（fflags）：整个模型不读（grep `fflags` 只在死代码 `FPURtl` 局部变量里出现），RTL 不输出、trace 不比较。
5. 延迟靠倒计数而不是全局 `sim_time`；`done_cycle` 的绝对值不复刻。
**参考模型疑点**：无（`fpcmp` 观察到网表 fflags 与 softfloat 不一致，但参考模型不读 fflags，属死代码）。
**差分是采样不是证明**：见第 5 节规模；手写 fadd/fmul 与 softfloat 之外还可用 `tests/fpu/netlist_ref/` 的网表做独立交叉验证（可选）。

## 5. 验证
- spec：`spec/fpu.io`（21 个字段：输入 14、输出 7，其中 5 个输出 `when out_complete`）。
- **（可选）网表转换脚本与参考网表**（不进 `rtl/`，位于 `tests/fpu/netlist_ref/`）：`python3 tools/fp/netlist2sv.py <fadd.h|fmul.h> <module> <out.sv> [--with-flags] [--no-prune]`，严格语法（识别不了的行/非拓扑序即报错），
  节点编号与 C++ 一致，一行一个 `logic nK; assign nK = ...;`，文件头 `// Generated by tools/fp/netlist2sv.py`（svlint 对该标记豁免 400 行限制；
  不需要 lint 豁免，所有 nK 都被声明且被使用，fflags 锥已裁掉）。`tests/fpu/run_netlist.sh`：用 Verilator 把生成的 SV（"全 37 输出+不裁剪"和"交付的裁剪版"各一份）
  与 C++ 网表函数 `fadd_io_generator/fmul_io_generator` 对照。
- **组合数据通路差分**：`tests/fpu/run_compute.sh`：Verilated `fpu_decode+fpu_compute` 对参考类 `FPUSoftfloat`（`#define protected public` 直接调 `impl_compute/calculate_latency`）；
  每类指令随机+边角（±0、次正规、inf、qNaN、sNaN、近最大/近最小、近 1、整数边界、tie、1ulp 邻居…），rm∈{0..4,5,7}，结果位（和延迟）必须逐位一致。
- **FU 级 trace**：真实程序 trace（73 个，含 zfinx*/matmul_fpu/float_test 等 6 个 FPU 程序）+ 随机 trace `tests/fpu/rand_trace.cpp`：
  直接驱动**真实的 `FPUSoftfloat` 对象**按 Exu 的调用顺序（`comb_begin→comb_ctrl→comb_issue→[consume 决定]→comb_consume→seq`）逐拍产生输入输出，不是手写模型。
  4 个 profile（少量冲刷 / 大量 flush+clear（小 br_mask 全集）/ 很少 consume / div+sqrt 为主）× 2 seed × 15 万拍。
  合法性约束：consume 只在 complete 时；en 任意（FU 忙时忽略）；en=0 时 `inst` 填垃圾（对应 Exu 槽位残留）；`imm` 高位随机、低 5 位合法；
  func7/func3 为合法 RV32F 编码，rm∈{0..4,5,7}。
- 结果见第 6 节与最终报告（数字在运行后回填）。

## 6. 结果（手写版，最终）
- lint：`bash scripts/lint.sh` 干净（109 文件，全仓库）。RTL 手写 1,1xx 行（22 个文件，最长 fpu_cvt_f2i 77 行，无生成代码），对比 `FPU.h` 380 行 C++（FPUSoftfloat 约 270 行 + softfloat 库）。
- 回放：81 个 trace 全部 PASS —— 73 个真实程序（61 gate + 12 个标准程序，含 6 个 FPU 程序，共约 76 万拍，约 5.9k 条 FP 指令，其中 fadd/fmul 为主，33 次 flush 杀死在途项）
  + 8 个随机 trace（4 profile × 2 seed × 15 万拍 = 120 万拍，13.6 万条指令，18 类指令各 2k–21k 条，杀死 17.7k 次、clear 命中 36.8k 次、"完成未被 consume" 20.7 万拍）。
- 与 softfloat 的组合差分（`tests/fpu/run_compute.sh`，18 类指令 × 各 1200 万向量（3 seed × 400 万）+ 单 seed 30 万，rm∈{0,1,2,3,4,5,7}）：**0 不一致**。
  结果类别覆盖（每类指令约 1/3–1/2 向量落在 NaN/inf/零/次正规/溢出边角，见 `compute_tb` 输出的分类直方图）。fsqrt 无次正规结果（数学上不可能）。
  已知唯一不一致：rm=6（softfloat 是 round-to-odd，保留编码，不实现，见第 4 节）。
- （可选）`tests/fpu/run_netlist.sh`：脚本转换的 SV 与 C++ 网表函数对照，5187 万向量 × {fadd,fmul} × {全输出,裁剪版}，0 不一致；人为改 1 个节点极性，20 万向量内即被抓（97% 不一致）。
- 变异（`tests/fpu/mutants.py`，35 个，33 个被抓，2 个等价）：
  - 真实程序 trace 即抓到 11 个：M01 fdiv 延迟、M02 fcvt.s.w 延迟、M04 br_mask 重叠杀、M08 ready 用 busy_q、M10 rob_idx 不装载、M11 fsub 不翻符号、M14 fsqrt 奇偶指数、M15 fcvt.wu 负数、M20 次正规移位、M22 NaN 规范化、M27 延迟 +1。
  - **只有随机 trace 才抓到的 22 个**：M03（全 1 flush 杀）、M05（accept 忽略杀）、M06/M09（clear_mask）、M12（rm=7）、M13/M28（fdiv sticky/精确商）、M16、M17（fmin ±0）、M18（flt ±0）、M19（fclass）、M21（RDN 上溢）、M23（fsgnjx）、
    M24（fcvt.w 2^31）、M25（feq ±0）、M26（dest_en 在忙时变化）、M29（fmul 进位）、M30（fcvt 小值 sticky）、M32（抵消零符号）、M33/M34（fadd 对齐/规格化 sticky）、M35（fmul sticky）。
  - 等价变异（不可抓）：M07（consume 不带 complete：合法激励下 consume 只在 complete 时出现）、M31（相等幅值的排序方向：同号结果相同、异号走抵消分支）。
- 没做/限制：fflags；rm=6 round-to-odd；保留编码（见第 4 节）；真实程序对 fsgnj*/fmin/fmax/fclass/sNaN/次正规几乎为 0，这些只靠随机 trace 与组合差分覆盖。
