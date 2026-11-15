# RV32 从 main 删除（2026-11-16）

**做了什么**：main 只维护 rv64gc（`XLEN=64`、`FP=1`、`RVC=1`）。rv32 的整套代码、测试、基线、镜像脚本保留在四个仓库（总仓库、function-model、rtl、trace-model）各自的本地分支 **`rv32-legacy`**（指向删除前的 main）；要回到 rv32：总仓库 `git checkout rv32-legacy && git submodule update`。

**为什么**：每次改动都要拖着 rv32 回归（`fm_gate` 64/65、RVC=0/1、`ref_cycles` 表、build32/soc32、rv32 RVC=1 的问题），而 rv32 已不再是主线（见 EXPLORATION / LOG 里的 rv64 迁移）。

## 各仓库的改动

| 仓库 | 改动 |
|---|---|
| function-model | `XLEN` 默认 64（Makefile、`include/xlen.h`、`include/api/refcpu_api.h`、`scripts/build_spike.sh`）；删除 Sv32 页表遍历、rv32 `fsd` 两次写字的路径、`tests/rv32`、`linux/ttg.dts`、`linux/ttg_c.dts`；README 改为只描述 rv64。源码里零星的 `XLEN==32` 条件表达式保留（死代码，不再测试）。`scripts/spec/`、`scripts/wl/`（rv32imab 的 SPEC/负载流程，数据在 `spec-rv32imab`）**没动**，仍是 rv32 流程，等 rv64 版本替换。 |
| trace-model | `XLEN` 默认 64（Makefile、`config.h`）；`scripts/build_tests.sh` / `build_rvc_tests.sh` / `run_gate_c.sh` 默认 `riscv64 rv64ima lp64 medany`；删除 4 个 Sv32 分页测试（`baremetal/vm-*`）和 `build_vm_tests.sh`、rv32 预编译 ELF、rv32 工具链的 `compile_commands.json`、`fence-i-dcache-test`、legacy-LSU 基线；`bitmanip-boundary` 补了 rv64 的 `rev8` 编码（原先写死 rv32）；基线 `baseline.csv` / `baseline_nopf.csv` / `baseline_c.csv` 在 rv64 上重新生成（62 / 62 / 67 个程序，全部 difftest Success）。 |
| rtl | 提交的 `ttg_cfg_pkg.sv` 改为 rv64gc（`gen_cfg.sh` 默认 `-DXLEN=64 -DRVC=1 -DFP=1`）；`tb/soc/build.sh` 不再为 rv64 生成副本（`SOC_XLEN` 废弃）；`programs/directed/*.S`、`programs/big/` 的 dhrystone / coremark 重建为 rv64；`memspec_vio.S` 补了 rv64 的地址零扩展；删除 rv32 的 `programs/extra/*.bin`；`ref_cycles.txt`（67 个程序）、`ref_cycles_nopf.txt`、`ref_cycles_nomemspec.txt` 用 rv64gc 的 trace-model 重新生成；`fm_gate.sh` / `soc_smoke.sh` / `progs*.txt` 去掉 `vm/`、`extra/`；`fp_chain`、`fp_dpi`、`build_dcache_tests.sh` 默认 rv64；`bpu_ub_look.sv` 的 `e_tgt` 加 `lint_off`（rv64 下高位不用，`lint_chip` 0 警告）。 |
| 总仓库 | `scripts/gate_all.sh` 去掉 `vm/`；`docs/WORKFLOW.md`、`README.md`、`docs/TODO.md` 里的 rv32 门禁说明改掉。 |

## 验证（2026-11-16，本机）

- function-model：默认 `make`（rv64）通过，rv64 Linux 从镜像启动到 `rv64 login:`。
- trace-model：`run_gate.sh` 62 / 62、`PF_ENABLE=0` 62 / 62、`run_gate_c.sh`（RVC=1）67 / 67，周期等于新基线。
- rtl：`fm_gate.sh` **67 / 67** 逐条提交对 function-model 一致，周期与 trace-model 零处不同；`lint_chip.sh` 0 警告；单元测试见下。
- 没有重跑 rv64 Linux 回归：RTL 配置包与之前 `SOC_XLEN=64` 流程在构建目录里生成的那份完全相同（同样的 `-DXLEN=64 -DRVC=1 -DFP=1`，`config.h` 数值未改），RTL 行为没有变化。

## 没做 / 留给后面

- 源码里的 `#if XLEN==32` / Sv32 / rv32 的 RTL 分支（`rvc_expand.sv` 的 `c.jal`/`c.flw`、PTW 的 Sv32 路径、`XLEN_BITS==32` 的位宽表达式等）还在；彻底删除要重做一遍 rv64 Linux 回归与周期一致性，没有一起做。
- `scripts/spec/`、`scripts/wl/`、`scripts/dse/`、`scripts/pf/`、`scripts/pmu/spec_tma.sh` 里的默认数据目录仍是 `spec-rv32imab`，rv64 的检查点流程替换后再改。
- 旧文档里引用 rv32 周期数的历史记录（EXPLORATION、MAIN_RECORDS、LOG）不改。
