# 06 正确性原则（现行 rv64gc 标准）

> 历史锁步/trace 回放体系已于 2026-11-04 退役（见 `legacy-reference` 标签）；`rv32` 已归档至 `rv32-legacy` 分支。本文件只保留当前 `main`（`rv64gc` + `Sv39`）的有效规则。

## 1. 现行正确性标准

1. **架构正确性 = 逐条提交与 `function-model` 一致**（核测试平台 `tb/core` 的 `core_tb`，`SOC_FM=1` 构建、`SOC_TB_FM=1` 运行）：
   - 默认模式比较每条提交的 PC、整数/浮点目的寄存器、RAM store 地址与数据、设备 load 计数；
   - **严格模式（`SOC_TB_FM_STRICT=1`）**额外比较 MMIO/跨字 store 数据以及每次提交周期边界的 `privilege` + 18 个架构 CSR（含 `fcsr`）；
   - `function-model` 本身通过 `Spike`（`--diff`）对拍验证（详见 `rtl/tools/fuzz/README.md` 与 `docs/SERVER.md`）。
2. **周期数是性能与对齐指标**：
   - `scripts/ref_cycles.txt` 为当前默认配置下 `trace-model` 的参考周期（模型默认配置 = RTL 配置，无需任何环境变量）；
   - **合入 `main` 时**要求 `fm_gate.sh` 全部程序逐条对比 0 不一致、SVA 0 报错、且周期与 `ref_cycles.txt` 逐个相等。
3. **现行整机与合规门禁**：
   - **基础门禁**：`scripts/fm_gate.sh`（程序列表以 `scripts/ref_cycles.txt` 为准，支持 `SOC_SVA=1`、`SOC_XINIT_UNIQUE=1`、`SOC_TB_FM_STRICT=1`）；
   - **随机上电值检查（可用，是否列为合入门禁未定）**：`SOC_XINIT_UNIQUE=1`（可加 `CORE_VOPT=-DSYNTHESIS`）构建，运行时设 `SOC_TB_RAND_INIT=<种子>`，`fm_gate.sh` 结果和周期应与全零上电相同（2026-11-28 种子 7 / 11 / 12345 都是 77/77、0 周期差，见 `docs/modules/common.md`）；
   - **官方 ISA 合规**：`scripts/riscv_tests_gate.sh`（RV64 官方 `ui`/`um`/`ua`/`uf`/`ud`/`uc`/`uzba`/`uzbb`/`uzbc`/`uzbs`，跳过不支持的非对齐 `rv64ui-ma_data`）；
   - **随机压力（Fuzzer）**：`tools/fuzz/fuzz_run.py`（支持 `--tb` 对拍 RTL 与 `--spike-fm` 对拍 Spike，配合 `minimize.py` 自动缩减）；
   - **Linux 回归**：开发期跑 `scripts/linux_segments_cmp.sh`（26 窗并行对拍 + PT/UP 指纹），合入前跑 `scripts/linux_gate.sh`（从复位全程到 `rv64 login:`）。
4. **模块级测试**：
   - 算术/原语单元保留独立对拍：`scripts/mul_check.sh`、`scripts/div_check.sh`、`scripts/fp_synth_check.sh`、`tests/common_prims/run.sh`；
   - 改写过的组合模块的新旧对拍：`tests/isu_iq_select/run.sh`（`isu_iq_select` 对改前版本逐拍比较）、`tests/ren_elim_sel/run.sh`（`ren_elim_sel` 对 C++ 参考模型随机比较）；FP 相关：`tests/fp_chain`、`tests/fp_decode`、`tests/fp_dpi`、`tests/fp_gate` 下的 `run.sh`；
   - 组合逻辑降深度改写须配新旧等价测试或 Yosys 形式等价（CEC）。

## 2. 已知可解释的周期微差规律

- **错路取指读到被修改数据区**：`trace-model` 读功能内存最新值，RTL 经 LLC/DDR 读未同步旧值，可能产生 1~2 拍周期差（不属硬件 bug）。
- **变延迟 Early-out DIV 错路操作数**：wrong-path 上模型无真实脏操作数（固定 2 拍），RTL 用寄存器堆脏值算 `clz`（2..17 拍），极少数错路 DIV 可能在写回仲裁差 1 拍。

## 3. 定位分歧工具

- `scripts/align_check.sh <prog.bin> [core_tb] [trace-model]`：对比每区间 PMU 一级事件与 BPU `PT`/`UP` 指纹（`DRILL=1` 自动下钻窗口）；
- `scripts/first_diff.sh`：定位第一处提交 PC/周期分歧；
- `SOC_TB_VCD=<起>:<止>:<文件>` + `scripts/vcd_query.py`：按需抓局部波形。

## 4. `ifdef SYNTHESIS` 两套写法的形式等价（2026-11-28）

有些模块给综合和仿真各写了一份实现：综合用并行结构，仿真用更快的循环写法。用 `-DSYNTHESIS` 编的测试平台跑的是前者，平时的 `fm_gate` 跑的是后者，所以要单独证明两者等价。其余三十多处 `` `ifndef SYNTHESIS `` 只包着断言、`_chk` 检查信号和 `dbg_` 计数，不驱动功能信号，不在此列。

**方法**：yosys-slang 读两遍（它默认就定义了 `SYNTHESIS`，读仿真写法要加 `-U SYNTHESIS`），`miter -equiv` 拼成比较电路，`setundef -zero`（X 当 0，同 Verilator 的 `--x-assign 0`）后写成 AIGER，交给 ABC `iprove` 证明。每次都用一个故意改错的副本确认能抓出反例。不要加 `-ignore_gold_x`：仿真写法里动态下标产生的 X 会让比较电路被优化成常数，改错的副本也会通过。

**已证明等价**（本机，ABC 证明阶段 ≤ 150 MB）：

| 模块 | 参数 | 说明 |
|---|---|---|
| `ttg_first_set` | N = 4 / 16 / 64 | |
| `ttg_onehot_mux` | N × W = 16 × 64、64 × 64 | |
| `ttg_popcount` | N = 8 / 16 / 64 / 128 | N = 128 证明 35 s |
| `ttg_pick_k` | N / K = 16 / 2、32 / 4、64 / 8 | 64 / 8 读入要 `--unroll-limit` 加大，yosys 0.9 GB，证明 136 s |
| `front_head_fix` | 整个模块 | 13 万个与门，证明 5 s（2026-11-28 版本；11-29 清理 C 只删了恒 0 的 `bnd_vec` 及多段输出，两套写法所在的 `scan_starts` 没改，未重证） |
| `bpu_hist_vec` | MAX_SYM = 1 / 2 | **只在 `sym_n ≤ MAX_SYM` 时等价**，超出时两种写法不同。现在 `bpu_spec.sv` 的三个实例都是 MAX_SYM = 1、`sym_n = {3'd0, en}`，前提由构造保证，不需要 SVA（2026-11-29 清理 C 删掉 EXP-051 双符号恢复后，原 `hr_push_n ≤ 2` 断言和唯一的 MAX_SYM = 2 实例 `u_r1_ck` 一并去掉；MAX_SYM = 2 的证明结果仍有效，只是没有实例用它）。仿真写法展开成门级网表时 yosys 峰值 8.8 GB / 16.6 GB（证明本身 ≤ 105 MB）。 |

只证了上表的参数，没有逐个核对每个实例的实际参数。

**没有做形式验证**（错了 difftest / 单元对拍很容易抓出，决定不证）：

- `mul_core`（Radix-4 Booth 对 `a * b`，两级流水）：ABC `dprove` 71 s 后 UNDECIDED，64 位乘法器等价超出开源工具能力；由 `scripts/mul_check.sh` 和 `fm_gate` 覆盖。
- `div_core`（迭代 Radix-16 对行为写法）：未尝试，比乘法器更难；由 `scripts/div_check.sh` 覆盖。
- `fp_core`、`fp_pipe_unit`、`fp_div_unit`：仿真写法是 C 的 DPI 函数（softfloat），不是 RTL，不能用这套工具比；由 `scripts/fp_synth_check.sh` 和 `fm_gate`（`-DSYNTHESIS` 或 `FPU_REAL` 构建）覆盖。
- `soc_axi_checker`：验证用的 AXI 协议检查器，不是设计逻辑，不需要。
