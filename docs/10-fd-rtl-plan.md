# RTL 的标准 F/D：实施计划（EXP-030 / EXP-031 之后）

2026-11-12 写。基线：RTL `exp/no-zfinx`（Zfinx 的 FPU 已删除，`ttg_cfg_pkg.sv` 用 `-DFP=0` 生成，lint 0 / lint_chip 0 / soc_smoke 56/56，dhrystone、coremark 与模型逐周期相同）；参考模型是 trace-model `exp/fd-all`（`FP=1`，默认配置）。本计划只写了方案，**还没有改 RTL 功能代码**（只新建了分支 `exp/fd-rtl`）。

## 1. 目标和约束

- RTL 实现和模型 `FP=1` 一样的微架构（统一标签编号、FP 重命名、FP 发射队列、3 个 FP 口 + 整数口上的 I2F、FP load/store 走现有 LSU），并且**逐周期一致**：纯整数程序与现在的 `ref_cycles.txt` 一致，FP 程序与模型的周期一致（模型的 `fd-*` 和 `scripts/fp_check.sh` 的 26 个程序、微基准）。
- 值通路是真的（RTL 要算出 FP 结果）：对拍对象是 function-model（`fm_check.h`，要加 f 寄存器和 fcsr）。
- 现在的配置生成器已经能给出 FP 配置（`scripts/gen_cfg.sh -DFP=1`）：`FPRF_NUM` 96、`TAG_NUM` 224、`PRF_IDX_WIDTH` 8（原 7）、`ISSUE_WIDTH` 21（原 18）、`MAX_WAKEUP_PORTS` 22、`TOTAL_FU_COUNT` 31、`IQ_FP_PORT_BASE` 18。用这个配置生成后，只有 `back_top` 的 lint 失败（位宽），其余模块因为是参数化的 lint 通过，**但是功能是错的**：`exu_ctrl_pkg`、`isu_pkg` 里的端口能力、FU 编号、唤醒通道都是手写的表，FP 口会被当成 LD/STA/BR 口。

## 2. 要改的模块（按流水线顺序）和接口变化

规模：`ren` 1203 行、`dispatch` 1357、`isu` 970、`prf` 519、`idu` 832、`exu_ctrl` 1407、`rob` 1517、`lsu` 7501，加手改过的生成文件 `back_top.sv`（1521 行）、`exu.sv`，加 `spec/*.io`。所有层之间的数据都是 packed struct，加字段要逐层转发。

| 模块 | 改动 |
|---|---|
| `idu` | `idu_ctrl_decode` 新增 OP-FP / 融合乘加 / `flw` `fld` `fsw` `fsd` 的类（现在已删除 `CLS_FP*`）；输出域位 `dest_fp`/`src{1,2,3}_fp`、`src3_en`、`src3_areg`、`fp_cls`；`dest_en` 对 `f0` 不能被 `areg==0` 清掉；静态保留编码当非法指令。 |
| `ren` | 第二套 RAT（32 项，无 x0）、空闲表（`FPRF_NUM`，标签 `FP_TAG_BASE+`）、分支检查点和提交回收；`ren_core` 里的 `ren_alloc_sel`/`ren_dep_check`/`ren_rat`/`ren_free_list`/`ren_ckpt` 都要有 FP 版（参数化实例）；每个域各自停顿；`src3` 的查找；`ren_inst_t`/`ren_out_uop_t`/`ren_commit_t` 加字段。move elimination 不做 FP。 |
| `dispatch` | `busy_table` 按 `TAG_NUM`；`src3_busy`；`dispatch_decompose` 加 `FPOP` 的 4 类（FMA/FDIV/MISC → `IQ_FP`，I2F → `IQ_INT`）；FP 队列的入队宽度和反压；`dis_pkg` 的 `uop_op_e`/`inst_type_e` 加 `UOP_FMA/FMISC/FDIV/I2F`；同组依赖检查跳过 `areg==0` 的条件要区分域。 |
| `isu` | 第 6 个队列 `IQ_FP`（32 项、入队宽度 4、3 个口、`src3` 唤醒矩阵）；唤醒通道加 `FPW_CH`（8 个，延迟唤醒槽 24 个，倒计时，对应模型 `fp_wake_slots`）；`isu_pkg` 的端口能力表（FP 口 = FMA+MISC / FMA+MISC / FDIV+MISC，INT 口 2、3 加 I2F）、`OP_NUM` 21、`IQ_NUM` 6、`WAKE_PORTS`/通道基址。 |
| `prf` | 新增 FP 寄存器堆 `fprf`（96×64，读口：3 个 FP 口 × 3 个源 + 3 个 STD 口的 FP 数据读；写口：FMA/MISC/FDIV 每口 1 个 + 2 个 I2F + FP load 的 LD 口写回），FP 域的旁路和写回仲裁；`prf_regfile` 现在是 2 读口 × `ISSUE_WIDTH` 车道。 |
| `exu_ctrl` / `exu` | FU 表重排（新增 FMA×2、FMISC×3、FDIV×1、I2F×2 共 8 个 FU，`TOTAL_FU_COUNT` 31，写回优先顺序和模型的 `Exu::init` 一致）；FP 口读 FP PRF 的 3 个源；`exu_ctrl_pkg` 的手写表（`xc_fu_kind`、`xc_port_fu_base`、`xc_fu_port`、`xc_port_cap`）；FP FU 需要 `src3`；FP 结果和 fflags 回 ROB。 |
| FP 运算单元 | FMA（fadd/fsub/fmul/fmadd 族，S 和 D，4 拍间隔即模型延迟 3）、MISC（fsgnj、fmin/fmax、比较、分类、fcvt、FP→INT，延迟 2）、FDIV/FSQRT（迭代，S 12/D 20 间隔、fsqrt 14/24）、I2F（延迟 2）；NaN-boxing；5 种舍入模式；5 位异常标志；动态舍入读 `frm`。 |
| `lsu` | `flw/fld`：load 写回写 FP 寄存器堆（`flw` 做 NaN-boxing），唤醒按统一标签；`fsw/fsd`：STD 的数据来自 FP 寄存器堆（所有 3 个 STD 口）；rv32 的 `fld/fsd` 是 8 字节访问（LSU 数据宽度要到 64 位）；检查点/MMIO 不动。 |
| `rob` / `csr` | ROB 每项加 5 位 fflags，提交时累积；`fcsr`/`fflags`/`frm` 真正的 CSR 读写（串行化，现在是 NOP）；`mstatus.FS/SD` 和 `misa` F/D；FS=Off 时 FP 指令和 fcsr 访问非法；FS 在提交时置 Dirty。 |
| 生成/规格 | `tools/gen_backtop.py`、`spec/*.io`（新增/改动的口）、`back_top.sv`/`exu.sv`（手改的生成文件，同步或再手改一次）。 |
| 测试平台 | `tb/soc` 的逐条对拍加 f 寄存器和 fcsr；DPI 或 softfloat 链接。 |

## 3. 分阶段实施（每一阶段都要 lint 干净、纯整数程序周期不变）

1. **S1 前端和重命名**：解码、`ren` 的 FP 域、`dispatch` 的域位和 `busy_table`。**已完成（2026-11-12，`exp/fd-rtl`）**。
   - 验收改为两部分（`-DFP=1` 配置下整核 lint 在 S2/S3 之前做不到：`exu_ctrl_pkg`/`isu_pkg` 的手写端口表按 FP=0 排布，`isu` 有布局断言）：① 默认配置（FP=0）整核 lint 0、lint_chip 0、`soc_smoke` 55 PASS / 0 FAIL（另 1 个 SKIP：`directed/memspec_vio.bin` 不存在，与之前相同），dhrystone、coremark 周期与模型一致；② `-DFP=1` 配置下 `idu`、`ren`、`dispatch`、`rob` 各模块 lint 0，`idu_ctrl_decode` 的 F/D 译码单元测试通过（`tests/fp_decode/run.sh`，28256 条，对拍 `Idu.cpp` 的规则：flw/fld/fsw/fsd、融合乘加、OP-FP 的 funct5 分类、保留编码、`f0` 的 dest_en、`src3_areg`）。
   - 做了什么：`idu_ctrl_decode` 新增 11 个类和一张 FP 副表（`dest_fp/src1_fp/src2_fp/src3_en/src3_areg/fp_cls`，`FPRF_NUM==0` 时全 0）；`ren_inst_t`/`ren_out_uop_t`/`ren_commit_t` 加域位；`ren_fp` 新模块（FP RAT/arch RAT/环形空闲表（96 槽，非 2 的幂，指针模加）/分支检查点，每个域各自按序停顿），`ren_rat`/`ren_ckpt` 参数化复用；`ren_elim_sel` 不让 FP 目的寄存器旁路整数源；`dispatch` 加 `src3`（唤醒 CAM、忙位、组内 RAW）、`dest_written` 对 `f0` 计入，忙表/唤醒矩阵由 `PRF_NUM` 改为 `TAG_NUM`；ROB 项加 `dest_fp` 并回到 `ren_commit_t`；所有带 preg 的端口位宽由字面 `[6:0]` 改为 `PRF_IDX_WIDTH`（FP=0 时仍 7 位，`ren_arch_cnt` 只管整数寄存器）。
   - **没做 / 只做了 lint**：FP 重命名路径（`ren_fp`）还没有被任何程序跑到，真正的验证要等 S2/S3 之后跑 FP 程序（周期与模型逐周期比较）；`spec/*.io` 里 preg 宽度仍是字面 7（旧harness 的接口规格，现行流程不用）；`tools/gen_backtop.py` 还没有同步 S1 新增的口（`back_top.sv` 是手改的）；FP 指令此时在 dispatch 里被当成整数 uop（`to_int`），S2 要把 FMA/FDIV/MISC 引到 `IQ_FP`、I2F 留在 `IQ_INT` 并去掉 FP 目的寄存器的整数写回。
2. **S2 发射**：`IQ_FP`、三源唤醒、FP 口和 I2F 能力、FP 唤醒通道。**已完成（2026-11-12，`exp/fd-rtl`）**。
   - 验收：FP=0 整核 lint 0、lint_chip 0、`soc_smoke` 55 PASS / 0 FAIL（周期不变）；FP=1 下 `idu`/`ren`/`dispatch`/`rob`/`isu` 各模块 lint 0。FP=1 整核 lint 还剩 S3 的内容：`exu_ctrl` 的 FU 表（`XC_OP_NUM`、FU 编号）和 `prf_regfile` 的 8 位标签索引。`isu_fp_gate` 有单元测试（`tests/fp_gate/run.sh`，2 万拍随机，对拍参考模型的 `try_reserve`：0 不一致）。
   - 做了什么：`isu_pkg` 按 `FPRF_NUM` 切换（OP_NUM 21、IQ_NUM 6、`IQ_FP` 32 项入队 4 口、FP 口能力 FMA+MISC / FMA+MISC / FDIV+MISC、整数口 2/3 加 I2F、`fp_latency`、FP 唤醒通道基址）；`isu_uop_t` 加 `src3_preg/src3_en/dest_fp/src1_fp/src2_fp`；`isu_iq_store` 加第三源等待位；新模块 `isu_wake_compact`（24 个延迟唤醒槽按槽序压到 8 个 FPW 通道）、`isu_fp_gate`（FP 写口上限 `FP_WB_PORTS=2`：发射时在 64 项环上预占写回周期，满则该 uop 留在队列，候选按 INT 队列 I2F 口再 FP 队列口的顺序）；`isu_wake_src` 接全部发射口，FP 延迟唤醒用 `isu_wake_iter`（24 槽、5 个请求口、计数宽度参数化）；`dispatch` 的 `decompose` 把 FMA/FDIV/MISC 引到 `IQ_FP`、I2F 留在 `IQ_INT`，ROB 完成组 G0，`dis_pkg` 加 UOP_FMA..I2F 和 src3 字段；`gen_cfg_pkg.py` 补导出 `FP_MISC_LAT/FP_I2F_LAT/FP_FDIV_D_LAT/FP_FSQRT_D_LAT/FP_IQ_SIZE/FP_IQ_ENQ_WIDTH`。
   - **没做 / 只做了 lint**：FP 队列和 FP 唤醒通道没有被任何 FP 程序跑到（`exu` 还没有 FP 单元，S3）；`isu_wake_compact` 没有单独的单元测试；`FP_WB_PORTS` 在 RTL 里是 `isu_pkg` 的固定常量 2（模型里是环境变量）；被冲刷的预占在全局冲刷时整体清零，与模型一致；`back_top.sv` 里 S2 新增的 `iss2prf` 域位信号目前只接到一个丢弃的汇总信号，S3 再接到 PRF/EXU。
3. **S3 FP 寄存器堆和运算单元（行为模型）**：`fprf`、`exu_ctrl` 的 FP FU；运算先用 **DPI 调 softfloat**（沿用 `mul_pipe` 的"行为计算 + 延迟线"做法），保证流水线本身与模型逐周期一致。验收：单个 `fadd`/`fmadd` 微程序与模型周期一致。
   **已完成（2026-11-12，`exp/fd-rtl`）。**
   - 验收：FP=0 整核 lint 0、lint_chip 0、`soc_smoke` 55 PASS / 0 FAIL（周期不变）；**FP=1 整核 lint 0**（`exu_ctrl`/`prf` 的表和位宽都已按 FP 配置），FP=1 的 SoC 仿真器（`SOC_OUT=build/soc_fp1 bash tb/soc/build.sh`，自动链接 DPI）整数程序 55 PASS / 0 FAIL，周期与默认配置一致；6 个 FP 内核（`scripts/fp_bench.sh` 的 dgemm / saxpy-dot / jacobi / nbody / fir / mixed）周期与模型（`FP_WB_PORTS=2`）**逐周期相同**（29198 / 20415 / 49181 / 57295 / 54647 / 38243）；`tests/fp_chain`（40 轮 D 和 S 的相关链：FMA 族、fdiv / fsqrt、fmin / fmax / fsgnj、比较、fclass、各种舍入模式的转换、fmv）带 function-model 逐条对拍（`SOC_FM=1`）2859 条指令 0 不一致，周期与模型相同（4069）；`tests/fp_dpi`（DPI 浮点运算对 function-model 的差分，rv32，10 万条有效随机指令）0 不一致。
   - 做了什么：`exu_ctrl_pkg` 的 FU 编号表改成由端口能力表推导（一次性算成常量表，FU 种类加 FMA / FDIV / FMISC / I2F，N_FPU = 8）；`exu_ctrl` 新增 F/D 单元的平铺端口组（`fu_fp_*` / `exu2fu_fp_*`）、`fresult`（64 位）和 `fflags`，端口仲裁、旁路、写回、就绪沿用 mc 路径；`exu_ctrl_lsu_out` 拆出（文件行数限制）；`exu_fu` 新增 `fp_core`（DPI softfloat，位精确）、`fp_pipe_unit`（FMA / FMISC / I2F，复用参数化的 `mul_pipe`）、`fp_div_unit`（`exu_iter_ctl`，按 S/D 和 fdiv/fsqrt 的延迟）；`prf_fp`（FP 寄存器堆 96×64、写口、写回暂存、带旁路的读口；FP 口 3 个源、STD 口的 FP 数据）；译码给 FP 指令的 `imm` 放 `{inst[6:2], inst[31:20]}`（`IMM_FP`，FP 单元据此区分 fmadd 族 / funct5 / rs2）；`ren_free_list` 的环指针按 `log2(PRF_NUM)` 位回绕（标签变宽后原来按标签位宽回绕是错的，整数程序会死锁）；ROB 完成组加 FP 口；`tb/soc/build.sh` 在 FP 配置下编入 `tb/fp_dpi/fp_dpi.cpp` 并链接 softfloat；`fm_check.h` 对 FP 目的的指令不比整数寄存器（FP 寄存器对拍在 S6）。
   - **没做 / 注意**：FP load / store 的数据通路（S4：`flw/fld` 写 FP 寄存器堆时目前拿的是 XLEN 位数据，不做 NaN-boxing，`fsd` 数据在 rv32 上只有低 32 位）；`fcsr.frm` 动态舍入模式在 RTL 里固定当 RNE（S5）；`fflags` 算出来了但没有进 ROB 累积（S5）；非法指令（FS = Off、保留舍入模式）没有陷入（S5）；`fp_core` 在 `ifndef SYNTHESIS` 下用 DPI，综合时是占位（S7）；FP 寄存器的值没有被逐条对拍，只通过整数目的的指令间接验证（S6）。
4. **S4 LSU**：FP load/store、STD 的 FP 数据。验收：`rv64uf/ud` 的 `ldst`。
   **S4a 已完成（2026-11-12）：`flw` / `fsw`**。`flw` 的 load 结果写 FP 寄存器时做 NaN-boxing（`fp_pkg::fp_load_box`，写回和 LSU 旁路两处），`fsw` 的数据由 PRF 在 STD 口读 FP 寄存器堆（S3 已做）、低 32 位存入，LSU 本身不用改。验收：`tests/fp_chain` 的 `SRC=mem`（60 轮：flw → 算术 → fsw → 整数 lw / fmv.x.w，含 store-to-load 转发、NaN-boxed 单精度转 double、未正确 box 的操作数得到 canonical NaN）带 function-model 对拍 6453 条 0 不一致，周期 2620 与模型相同；FP=0 lint 0、FP=1 `soc_smoke` 55/55、FP 内核周期不变。
   **S4b 决定不做（2026-11-12，用户：rv32 上一般不会用 double）**。以下是当时的分析：
   **rv32 的 `fld` / `fsd`（8 字节访问）**。模型把它当一次 8 字节访问（`get_mem_width` 返回 8、写掩码 0xFF），RTL 的核↔dcache 数据字是 XLEN 位（rv32 为 32 位），要一次 8 字节必须把 LSU 的 load 返回、STQ 数据、store-to-load 转发、dcache 核侧 load/store 口（以及写缓冲）加宽到 64 位，改动范围在 LSU（约 7500 行）和访存子系统；rv64 的 `fld/fsd` 是一个数据字，不需要加宽，只缺 load 宽度位（flw 要 box，fld 不要）。
5. **S5 CSR / ROB**：fflags 累积、FS/SD、fcsr、非法指令。验收：`rv32-fp-trap`、`rv32-fp`。
   **已完成（2026-11-12，`exp/fd-rtl`；模型侧是 trace-model `exp/fcsr` 分支，EXP-033）。**
   - 模型改动（RTL 周期要与之对齐，必须先改）：`fflags / frm / fcsr` 在模型里原来是无时序的 NOP，现在是正经的 CSR 指令（串行化，FS=Off 时非法；`CSR_NUM` 22）；ROB 从写回取 `illegal_inst`（原来执行期发现的非法 FP 指令根本不会触发异常，`rv32-fp-trap` 87154 → 95438 周期）；timing 模型的 CSR 值不再回写函数模型（否则 fflags 读出值被覆盖成 0，测试在模型里就失败）。
   - RTL：`fflags / frm / fcsr` 是真 CSR（`R_FCSR` 存 {frm, fflags}，表驱动加移位字段；译码为已知 CSR）；mstatus.FS 可写、SD 由 FS==3 推出（只读）；misa 加 F、D；FP 指令 / `flw` `fsw` / FP CSR 访问带 `fs_need`，在**完成**时对已提交的 mstatus 判 FS==Off（CSR 写和陷入提交时会冲刷更年轻的指令，所以只会有被丢弃的指令看到旧 FS），非法则 ROB 项置 `illegal_inst`，提交时取异常、不写 CSR（`csr_wbuf` 丢弃暂存的写）；FP 单元对保留编码 / 保留舍入模式经 DPI 给出 `illegal` 并走 `exu2rob` 写回；`fflags` 随写回进 ROB 项，提交时按位或累加进 fcsr（异常指令和中断不累加）；FP 目的 / 有 flags / 写 fcsr 的指令提交时置 FS=Dirty；动态舍入模式读已提交的 `frm`。
   - 验收：FP=0 整核 lint 0、lint_chip 0、`soc_smoke` 55/55；FP=1 整核 lint 0、`soc_smoke` 55/55、FP 内核与 `fp_chain` 周期不变；官方 `rv32uf-*` 11 个程序在 RTL 上带 function-model 逐条对拍（含 fflags 读出值）0 不一致，11 个周期全部与模型相同（`rv32uf-fcmp` 和 `rv32uf-fdiv` 原来各差 1 周期，查到是 RTL 的一个真 bug：CSR FU 的旁路结果恒为 0，只有 CSR 写回项才带 CSR 读出值，所以与 CSR 指令同一周期读操作数的消费者（这里是 `fsflags` 后面依赖 a1 的 `bne`）读到 0，算出一次假的分支误预测，多占一拍提交；已修：CSR FU 的旁路给 CSR 读数据）；`rv32-fp-trap` 前 690 条指令（FS 各值、SD、CSR 非法、保留舍入模式）对拍一致，之后进入 `fclass.d` 等 double 数据（rv32 的 fld/fsd 未做）。
   - `fm_check.h`：mstatus / sstatus / misa / fflags / frm / fcsr 的读出值严格比较，不再采纳 RTL 值。
6. **S6 对拍和全量**：26 个 FP 程序（`scripts/fp_check.sh` 的集合）与模型逐周期一致、f 寄存器对拍通过；微基准的延迟一致。
   **已完成（2026-11-12，`exp/fd-rtl`）。**
   - `fm_check.h` / `soc_tb.cpp`：提交时除整数 rd 外，目的是 FP 寄存器的指令还读 `prf_fp` 的寄存器堆，和 function-model 的 `fpr[rd]` 比较全部 64 位（含 NaN-boxing）；FM 不写 FP 寄存器而 RTL 写了也报错。FP 配置的仿真器带 `-DSOC_FP`，`soc_public.vlt` 暴露 `prf_fp.reg_file_q` 和 ROB 提交的 `dest_fp`（`tools/gen_soc_top.py` 已不能运行，vlt 是手改的）。已确认比较有效：rv32 的 `fld` 会立即报 `f10 rtl=ffffffff00000000 fm=4009210000000000`。
   - 通过（带 FP 寄存器对拍，FM 0 不一致，且周期与模型逐周期相同）：`rv32uf-*` 11 个；`fd-basic` / `fd-fcvt` / `fd-fdiv` / `fd-fsqrt` / `fd-matmul`（951 / 1700 / 1693 / 1390 / 26717 周期，`fd-matmul` 56767 条指令）；`tests/fp_chain` 的 chain 和 mem；FP 内核里的单精度三个（saxpy-dot 69748 条、jacobi 174136 条、mixed 165588 条）；FP=0 默认配置 `soc_smoke` 55/55 且 FM 构建的 crc32 对拍通过。
   - 不能过（rv32 的 double 数据通路没做，用户决定不做）：`rv32ud-*`、`rv32-fp`、`rv32-fp-trap` 690 条之后、`fp-kernels`、FP 内核里用 double 的 dgemm / nbody / fir。
7. **S7 可综合的运算数据通路**：替换 DPI。FMA、除法/开方、转换。

## 4. 开始前要定的两件事

- **FP 运算数据通路怎么来（S7）**：推荐引入开源的 FPnew（SystemVerilog，许可宽松，流水级数可配），不自己手写 53 位 FMA 和 IEEE 边界；手写的代价是验证工作量。这需要你同意，因为项目目前要求 RTL 与 C++ 模型一一对应。S1 到 S6 不依赖这个决定。
- **FP 寄存器堆的口数（已定，EXP-032）**：模型默认 `FP_WB_PORTS=2`，6 个 FP 内核扫描结果见 trace-model `exp/fp-wb`：FU 写口 2 个周期几乎不变（最坏 saxpy-dot +4.0%、mixed +1.7%），3 个完全无损失。按此设计：
  - **写口 6 个**：FU 结果 2 个（FMA/MISC/FDIV/I2F 共享，发射时预占写口忙表 `fp_wb_busy`，周期满则该 uop 留在 IQ_FP，同香山 `WbFuBusyTable`，不需要重发）；FP load 4 个（4 个 LD 口都能写 FP，模型里 dgemm 有 3075 个周期同时写 4 个，不能限）。
  - **读口 9 个**：3 个 FP 发射口 × 3 个源 = 9，加 STD 的 FP 数据读 1 个（`fsd` 数据读多数周期 1 个，偶尔 2 到 3；如需 3 个 STD 口同时读则为 12，先按 9 + 1 做，STD 冲突由仲裁推迟，需要先在模型里加对应限制再改 RTL）。
  - FP load 写口上限、STD FP 读口上限目前**模型里没有**，RTL 第一版按全开实现保证周期一致，面积不行再回模型先改。
  - 写口忙表的槽数与模型一致（64 槽环，发射周期 + 延迟）；被冲刷的预占不释放（与模型一致）。

## 5. 风险

- 手改过的生成文件 `back_top.sv`、`exu.sv` 与 `spec` 不同步，F/D 要改的口很多，建议这一轮同时把生成器恢复成可用状态，否则每个口要手工加三处。
- `PRF_IDX_WIDTH` 从 7 变 8 会改变所有标签端口和 `busy_table`、唤醒矩阵的尺寸，整数路径的综合代理面积会变（先在 S1 验收时用综合代理量一下）。
- 运算单元的 IEEE 边界（NaN 传播、次正规、舍入模式、标志）靠 function-model 的定向测试加 Spike 对拍的思路覆盖：先对 DPI 版逐条一致，再对可综合版做随机差分。

## 8. RV64G（2026-11-12 补）

rv64 配置（`XLEN_BITS = 64`，`gen_cfg.sh -DFP=1 -DXLEN=64`；仿真器 `SOC_XLEN=64 FMLIB=<XLEN=64 的 librefcpu.a> SOC_FM=1 bash tb/soc/build.sh`）上的 F/D 已验证，核是 RV64G（IMAFD + Zicsr + Zifencei；没有 C）。
- 改动：load 通路加 `is_w`（LSU 写回的 word 宽度位，`lp_wb` → `lsu_pipe` → `exu_ctrl`）：rv64 的 `flw` 做 NaN-boxing、`fld` 整字不 box（`fp_pkg::fp_load_data`）；rv32 仍是 `flw` 一种，全 box。
- 发现并修了一个模型和 RTL 共有的写回优先级问题：整数→FP（I2F，在整数口 2、3 上）原来排在 ALU 之后，口上每拍都有 ALU 结果时 I2F 的结果一直输掉仲裁，其流水线满后新进来的 I2F 在槽里等，但消费者是按发射时的固定延迟被唤醒的，读到旧值（rv64 的 `fcvt.s.wu` 紧跟 `fmul.s` 触发）。现在 I2F 的 FU 排在 ALU 前面（模型 `Exu::init` 的 kSpecs 顺序和 RTL `exu_ctrl_pkg` 的 FU 种类编号同步改）。FMA 和 FMISC 在 FP 口上有同样的结构（FMA 在前），目前没有观察到问题，但原理上持续的 FMA 流可以让 FMISC 一直输；彻底的办法是消费者的唤醒不依赖固定延迟（或结果保证不排队），要改模型。
- 验收（rv64，FM 逐条对拍含 FP 寄存器，周期与 rv64 模型逐周期相同）：`rv64uf-*` 11 个、`rv64ud-*` 12 个（含 `structural`、`move`、`fclass`、`recoding`，double 的 `fld/fsd` 都在）、`rv64-fp`（348568 条指令）、`rv64-fp-trap`（16649 条）、`fp-kernels`、`fd-*` 5 个、6 个 FP 内核（double 的 dgemm / nbody / fir 也通过）。rv64 整数程序 54 个里 50 个周期与 rv64 模型相同，另 4 个（bitmanip-boundary、crc32、load-store、memory-stress）在 FP=0 的 rv64 构建上结果完全一样，不是 F/D 引入的（模型基线与 RTL 基线的既有差异，bitmanip-boundary 是既有的 FM 不一致）。
- rv32 重跑：`rv32uf-*`、`fd-*`、`fp_chain`、float 内核与新的模型周期逐周期相同；FP=0 `soc_smoke` 55/55，FP=1 `soc_smoke` 55/55，三种配置（FP=0 rv32、FP=1 rv32、FP=1 rv64）整核 lint 0、FP=0 lint_chip 0。


## 9. 端口完成周期预约（EXP-035，2026-11-13 补）

模型（trace-model `exp/fcsr`，提交 4a1d9df）在发射阶段给每个发射端口加了完成周期预约表：一个端口一拍只能完成一个 uop（一个 ROB / 写回条目），发射时按"发射周期 + 完成偏移"预约 (端口, 周期)，这一拍已被占用的 uop 不发射、留在 IQ 里。旧模型里同端口两个 uop 同拍完成时输家在单元里等待，但它的消费者已按固定延迟唤醒；这在 coremark 里发生 12247 次，不是罕见情况。预约之后冲突为 0。

RTL：新模块 `isu_wb_gate`（`rtl/backend/isu/isu_wb_gate.sv`）。每个端口一个 2^WB_OFF_W 位的忙位环（环大小由最长偏移决定：`max(DIV_MAX_LATENCY, FP_FSQRT_D_LAT) + 1`），当前拍的槽在拍末清零，全局冲刷清空。偏移函数 `wb_offset`（`isu_pkg`）：MUL = `MUL_MAX_LATENCY`；DIV = 迭代数（rv64 的 word 形式减半）+ 1；FDIV = FP 延迟 + 1；FMA/FMISC/I2F = FP 延迟；其余 1。迭代单元比唤醒延迟晚一拍完成，所以 +1。
- 一个端口一拍最多一个 pick，不同端口不会预约同一槽，所以每个端口的检查只依赖忙位环（没有端口之间的优先级链）。
- 和 `isu_fp_gate` 的关系：被端口门拒绝的 pick 不占 FP 写口（FP 门的 `cand_valid` 要与 `wb_ok` 相与）；预约用最终的 `grant_valid`；每个 IQ 的 `gate_ok` = FP 门 & 端口门。

验收：整核 lint 0（FP=0 和 FP=1），`lint_chip` 0（FP=0）；FP=1 的 SoC 仿真器与模型（`WB_RESERVE` 默认开）逐周期相同：smoke 58 个程序中 57 个相同（crc32 是之前就有的差异：模型 1983、RTL 2001，与本改动无关，关掉 `WB_RESERVE` 也一样）、dhrystone 116401、coremark 282616、memory-stress-small 325458、pf-stress 619531、fd-basic/fcvt/fdiv/fsqrt/matmul（951 / 1700 / 1693 / 1390 / 26827）、6 个 FP 内核（29198 / 20455 / 49181 / 57295 / 54647 / 38283）；rv64（FP=1）：div、mul-longlong、add-longlong、matrix-mul、fact、bubble-sort、goldbach、mersenne、fp-kernels、rv64-fp 周期相同（crc32 与之前一样不同）。`scripts/ref_cycles.txt` 已按新模型更新（11 个程序）。
单元测试 `tests/wb_gate/run.sh <work-dir>`（FP=1 配置，3 万拍随机，每个端口独立随机偏移 1..最大偏移、含冲刷，对拍模型 `WbBusy` 的忙位环语义，7.1 万次拒绝：0 不一致）。还没做的：忙位环按最长偏移取整，FP=0 配置下比较大（2^5 位 × 端口数），综合时可以再收。
