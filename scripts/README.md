# scripts/ 索引

| 类别 | 脚本 | 作用 |
| --- | --- | --- |
| 路径配置 | `env.sh`、`ttg_env.py` | 所有脚本共用的位置（`RTL_ROOT`、`AI_HUMA_ROOT`、`TTG_PROGS`、`TTG_BIG`、`TM`），全部由所在位置推出，可由环境变量覆盖 |
| 构建/检查 | `lint.sh`、`rtl_files.sh`、`gen_cfg.sh`、`gen_pmu_pkg.py`、`gen_tracker.py` | 规范检查（目录级，`rtl/` 下每个模块目录单独编译）、RTL 文件序（配置包 → 其他 `*_pkg.sv` → 其余）、配置包（`make cfg`，rv32 默认）、PMU 事件包（`rtl/pmu/pmu_ev_pkg.sv`，来自 trace-model `pmu_events.def`）、进度表生成 |
| 整芯片检查 | `lint_chip.sh` | 以 `soc_top` 为顶的 Verilator `-Wall`（`lint.sh` 只按目录查），打印告警数，0 为通过；`CFG=<包>` 用别的配置包检查而不安装（rv64 检查：用 `gen_cfg_pkg.py` 加 `-DXLEN=64` 生成包再传入，或用一个 `XLEN_BITS = 64` 的副本）。改参数前先用它找写死的位宽 |
| 综合对比 | `synth_cfg.sh <标签> <配置包> <模块...>`、`synth_module.sh`、`synth_depth.sh` | 在指定配置包下逐模块综合（与 docs/09 同设置），结果在 `build/synth_<标签>/`，结束后恢复原配置包；`synth_depth.sh` 另给逻辑级数代理。需要 yosys + yosys-slang，rv64 没有综合过 |
| 整核闭环（周期） | `soc_smoke.sh`、`cmp_trace_model.sh`、`first_diff.sh/.py`、`tm_cycles.sh` | 整核 RTL 跑程序，周期/指令数与 trace-model 对比（**性能指标，不是门禁**）；`first_diff` 在同一程序上对出第一处周期/PC 分歧；`tm_cycles.sh <trace-model 二进制>` 在 `ref_cycles.txt` 的程序上重新生成周期表（配置变化后用；记得给模型设 `LSU_PIPE_NOWD=1`） |
| 程序表 | `progs.txt`、`progs_smoke.txt`、`ref_cycles.txt` | 程序列表；`ref_cycles.txt` 是 trace-model 在当前配置下的周期数（gate 基线 + dhrystone/coremark + `directed/`），RTL 应与之逐个相等；配置改变时随 `make cfg` 一起更新。`ref_cycles_*.txt` 其他文件是旧配置（分级 LSU 之前、无预取、无 memspec）的历史表，不再重新生成 |
| 正确性门禁 | `fm_gate.sh <soc_tb> <输出目录>`；测试平台用 `SOC_FM=1 SOC_OUT=<绝对路径> bash tb/soc/build.sh` 构建 | `ref_cycles.txt` 里 69 个程序（rv32）逐条提交对比 function-model（见 `docs/modules/soc_top.md`），输出 `summary.txt`，并报告与 `ref_cycles.txt` 周期不同的个数；**store 数据不在对比范围内，改动访存/外设路径时还要对比串口输出** |
| Linux | `linux_segments.sh <soc_tb> <检查点目录> <输出目录> [每段周期]` | Linux 检查点段并行逐条对比（冷启动微结构，周期不比）；整机从复位启动见仓库根 `README.md`（`SOC_TB_SEMIHOST=1`，构建加 `SOC_VOPT="--threads 4 -DTTG_EBREAK_TRAP"`） |
| 其他 | `build_dcache_tests.sh`、`pmu_parity.sh`、`fe_refs/` | 定向 DCache 覆盖程序的构建（`tests/dcache` 需要 Homebrew LLVM riscv32）；PMU 一级事件 RTL 对 trace-model 的逐事件总数对比；前端参考数据 |

**rv64**：`fm_gate.sh`、`soc_smoke.sh` 只针对默认 rv32 的程序表；rv64 用 `SOC_XLEN=64 SOC_FM=1 FMLIB=<XLEN=64 的 librefcpu.a> SOC_OUT=<dir> bash tb/soc/build.sh` 构建测试平台后手工跑 rv64 程序（`FMLIB` 必须是 function-model 的 `XLEN=64` 构建）。

逐模块锁步、trace 录制/回放、变异检查和旧参考模型副本已退役：脚本在标签 `legacy-reference`（rtl 仓库）里。
