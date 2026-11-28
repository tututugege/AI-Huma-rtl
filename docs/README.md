# rtl 文档目录

rtl 是 AI-Huma 的 `rv64gc` + `Sv39` SystemVerilog 实现（含全套自研可综合 RV64FD FPU；rv32 归档在 `rv32-legacy` 分支）。正确性 = 整核逐条提交与 function-model 一致；周期数与 trace-model 比较（合入 main 时同一配置下逐个相等）。
全项目的规则、流程、记录和待办在总仓库 `docs/`（[导航](../../docs/GUIDE.md)），这里只放 rtl 自己的文档。

## 现行文档

| 文档 | 内容 | 什么时候看 |
| --- | --- | --- |
| [00-scope-and-decisions.md](00-scope-and-decisions.md) | 范围、参考、已定的技术决策 | 第一次接触 rtl |
| [01-rtl-coding-standard.md](01-rtl-coding-standard.md) | RTL 编码规范（`scripts/lint.sh` 检查） | 写 RTL 前 |
| [04-cpp-to-rtl-mapping.md](04-cpp-to-rtl-mapping.md) | C++ 构造到 SV 的写法对照 | 照着 trace-model 写新逻辑时 |
| [05-module-tracker.md](05-module-tracker.md) | 模块进度表（**自动生成**，`make tracker`，来源是各模块笔记头部） | 查某个模块的状态 |
| [06-equivalence-policy.md](06-equivalence-policy.md) | 正确性原则：现行门禁是什么、不比较什么 | 所有人 |
| [08-risk-register.md](08-risk-register.md) | 风险登记簿：验证缺口、架构限制、基础设施债（只记风险，待办在总仓库 `docs/TODO.md`） | 改动前后、评估可信度 |
| [09-synthesis-report.md](09-synthesis-report.md) | 综合（Yosys 代理、快速 PPA 各层、TSMC 28nm DC）方法和逐模块数字 | 评估面积与逻辑深度 |
| [modules/](modules/) | 每个模块的设计笔记（[模板](modules/TEMPLATE.md)，改动 RTL 前必须先更新，见总仓库 `WORKFLOW.md` 第 7 节） | 写/改该模块 |
| [deviations.md](deviations.md) | 旧体系下与旧参考模型的差异登记（不再新增；S 编号仍被引用） | 查某个 S 编号 |
| [../scripts/README.md](../scripts/README.md) | 脚本索引（lint、门禁、单元检查、综合、Linux 对齐） | 跑东西之前 |

## 常用命令

完整说明见仓库根 [../README.md](../README.md)，脚本见 [../scripts/README.md](../scripts/README.md)。

```bash
export PATH="$HOME/rv64spec/verilator_src/bin:$PATH"   # iprc-jump 必须用 Verilator 5.052
make cfg                                               # 从 trace-model/include/config.h 生成 rtl/common/ttg_cfg_pkg.sv（不要手改）
bash scripts/lint.sh && bash scripts/lint_chip.sh && bash scripts/lint_soc.sh
SOC_FM=1 CORE_OUT=$PWD/build/core_fm bash tb/core/build.sh
bash scripts/fm_gate.sh $PWD/build/core_fm/obj/core_tb $PWD/build/gate  # 77 个程序门禁，并报告与 trace-model 周期不同的个数
bash scripts/soc_gate.sh                               # 真实全片 SoC（chip_top）一键门禁（lint_soc + axi_unit + 6 项 soc_tb 测试）
bash scripts/mul_check.sh && bash scripts/div_check.sh && bash scripts/fp_synth_check.sh
make tracker                                           # 由 docs/modules/*.md 头部重新生成 05 进度表
```

## 目录结构

```
docs/        本目录（模块设计笔记在 modules/）
rtl/         所有 RTL（common/ backend/ frontend/ memsys/ core/ pmu/ soc/），说明见 rtl/README.md
harness/     tools/（gen_cfg_pkg 配置包生成器、svlint；iogen 读的 spec/ 已删除，iogen 不再使用）、include/trace_format.h（测试平台用）
tb/          核+存储测试平台（core/ → core_tb）、真实全片 SoC 测试平台（soc/ → soc_tb）、AXI4 单测（axi_unit/）及独立单元对拍（mul/、div/、fp_synth/、fp_dpi/、fe_clean_eq/）
tools/       gen_soc_probe、gen_skipmask（测试平台构建用）、ckpt2image、lint_back_top.sh、toplint.sh、fuzz/（RV64GC 随机 Fuzzer），说明见 tools/README.md
sva/         非侵入式 SVA bind 断言与覆盖框架（`SOC_SVA=1` 挂载，零综合污染）
tests/       专项测试：common/、common_prims/、dcache/、fp_chain/、fp_decode/、fp_dpi/、fp_gate/、isu_iq_select/、pmu/、ren_elim_sel/、rv64/、wb_gate/
scripts/     索引见 scripts/README.md
programs/    缩短版 dhrystone/coremark（programs/big）、定向短测试（programs/directed）与 SoC 裸机测试（programs/soc）
build/       构建产物（不入库）
```

测试程序默认由本仓库构建于 `build/progs/`；Linux 镜像本机位于 `~/rv64spec/linux_j.bin`，集群 26 窗检查点库位于 `/nfs_global/S/houruyao/linux_ckpt_rv64gc/`（详见总仓 [docs/SERVER.md](../../docs/SERVER.md)）。
