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

1. **S1 前端和重命名**：解码、`ren` 的 FP 域、`dispatch` 的域位和 `busy_table`。验收：用 `-DFP=1` 配置，整数程序 `soc_smoke` 56/56 不变（FP 字段全 0）。
2. **S2 发射**：`IQ_FP`、三源唤醒、FP 口和 I2F 能力、FP 唤醒通道。验收：同上。
3. **S3 FP 寄存器堆和运算单元（行为模型）**：`fprf`、`exu_ctrl` 的 FP FU；运算先用 **DPI 调 softfloat**（沿用 `mul_pipe` 的"行为计算 + 延迟线"做法），保证流水线本身与模型逐周期一致。验收：单个 `fadd`/`fmadd` 微程序与模型周期一致。
4. **S4 LSU**：FP load/store、STD 的 FP 数据。验收：`rv64uf/ud` 的 `ldst`。
5. **S5 CSR / ROB**：fflags 累积、FS/SD、fcsr、非法指令。验收：`rv32-fp-trap`、`rv32-fp`。
6. **S6 对拍和全量**：26 个 FP 程序（`scripts/fp_check.sh` 的集合）与模型逐周期一致、f 寄存器对拍通过；微基准的延迟一致。
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
