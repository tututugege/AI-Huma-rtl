# 06 正确性原则（现行 rv64gc 标准）

> 历史锁步/trace 回放体系已于 2026-11-04 退役（见 `legacy-reference` 标签）；`rv32` 已归档至 `rv32-legacy` 分支。本文件只保留当前 `main`（`rv64gc` + `Sv39`）的有效规则。

## 1. 现行正确性标准

1. **架构正确性 = 逐条提交与 `function-model` 一致**（`tb/soc`，`SOC_FM=1` 构建、`SOC_TB_FM=1` 运行）：
   - 默认模式比较每条提交的 PC、整数/浮点目的寄存器、RAM store 地址与数据、设备 load 计数；
   - **严格模式（`SOC_TB_FM_STRICT=1`）**额外比较 MMIO/跨字 store 数据以及每次提交周期边界的 `privilege` + 18 个架构 CSR（含 `fcsr`）；
   - `function-model` 本身通过 `Spike`（`--diff`）对拍验证（详见 `rtl/tools/fuzz/README.md` 与 `docs/SERVER.md`）。
2. **周期数是性能与对齐指标**：
   - `scripts/ref_cycles.txt` 为当前默认配置下 `trace-model` 的参考周期（模型默认配置 = RTL 配置，无需任何环境变量）；
   - **合入 `main` 时**要求 `fm_gate.sh` 全部程序逐条对比 0 不一致、SVA 0 报错、且周期与 `ref_cycles.txt` 逐个相等。
3. **现行整机与合规门禁**：
   - **基础门禁**：`scripts/fm_gate.sh`（程序列表以 `scripts/ref_cycles.txt` 为准，支持 `SOC_SVA=1`、`SOC_XINIT_UNIQUE=1`、`SOC_TB_FM_STRICT=1`）；
   - **官方 ISA 合规**：`scripts/riscv_tests_gate.sh`（RV64 官方 `ui`/`um`/`ua`/`uf`/`ud`/`uc`/`uzba`/`uzbb`/`uzbc`/`uzbs`，跳过不支持的非对齐 `rv64ui-ma_data`）；
   - **随机压力（Fuzzer）**：`tools/fuzz/fuzz_run.py`（支持 `--tb` 对拍 RTL 与 `--spike-fm` 对拍 Spike，配合 `minimize.py` 自动缩减）；
   - **Linux 回归**：开发期跑 `scripts/linux_segments_cmp.sh`（26 窗并行对拍 + PT/UP 指纹），合入前跑 `scripts/linux_gate.sh`（从复位全程到 `rv64 login:`）。
4. **模块级测试**：
   - 算术/原语单元保留独立对拍：`scripts/mul_check.sh`、`scripts/div_check.sh`、`scripts/fp_synth_check.sh`、`tests/common_prims/run.sh`；
   - 组合逻辑降深度改写须配新旧等价测试或 Yosys 形式等价（CEC）。

## 2. 已知可解释的周期微差规律

- **错路取指读到被修改数据区**：`trace-model` 读功能内存最新值，RTL 经 LLC/DDR 读未同步旧值，可能产生 1~2 拍周期差（不属硬件 bug）。
- **变延迟 Early-out DIV 错路操作数**：wrong-path 上模型无真实脏操作数（固定 2 拍），RTL 用寄存器堆脏值算 `clz`（2..17 拍），极少数错路 DIV 可能在写回仲裁差 1 拍。

## 3. 定位分歧工具

- `scripts/align_check.sh <prog.bin> [soc_tb] [trace-model]`：对比每区间 PMU 一级事件与 BPU `PT`/`UP` 指纹（`DRILL=1` 自动下钻窗口）；
- `scripts/first_diff.sh`：定位第一处提交 PC/周期分歧；
- `SOC_TB_VCD=<起>:<止>:<文件>` + `scripts/vcd_query.py`：按需抓局部波形。
