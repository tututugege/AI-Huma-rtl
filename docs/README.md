# rtl 文档目录

rtl 是 AI-Huma 的 SystemVerilog 实现。正确性 = 整核逐条提交与 function-model 一致；周期数与 trace-model 比较（合入 main 时同一配置下逐个相等）。
全项目的规则、流程、记录和待办在总仓库 `docs/`（[导航](../../docs/GUIDE.md)），这里只放 rtl 自己的文档。

## 现行文档

| 文档 | 内容 | 什么时候看 |
| --- | --- | --- |
| [00-scope-and-decisions.md](00-scope-and-decisions.md) | 范围、参考、已定的技术决策 | 第一次接触 rtl |
| [01-rtl-coding-standard.md](01-rtl-coding-standard.md) | RTL 编码规范（`scripts/lint.sh` 检查） | 写 RTL 前 |
| [04-cpp-to-rtl-mapping.md](04-cpp-to-rtl-mapping.md) | C++ 构造到 SV 的写法对照 | 照着 trace-model 写新逻辑时 |
| [05-module-tracker.md](05-module-tracker.md) | 模块进度表（**自动生成**，`make tracker`，来源是各模块笔记头部） | 查某个模块的状态 |
| [06-equivalence-policy.md](06-equivalence-policy.md) | 正确性原则：现行门禁是什么、不比较什么 | 所有人 |
| [08-risk-register.md](08-risk-register.md) | 风险登记簿：验证缺口、变异存活、未验证项（只记风险，待办在总仓库 `docs/TODO.md`） | 改动前后、评估可信度 |
| [09-synthesis-report.md](09-synthesis-report.md) | 综合（面积代理）方法和逐模块数字；第 9 节是第 3 批配置后的对比 | 评估面积 |
| [modules/](modules/) | 每个模块的设计笔记（[模板](modules/TEMPLATE.md)）。**“验证”一节多是 2026-11-04 之前旧体系的结果**，现行验证看 06 和总仓库 LOG | 写/改该模块 |
| [analysis/](analysis/README.md) | 翻译阶段的边界与结构分析（设计内容仍可参考） | 深入某个区域 |
| [deviations.md](deviations.md) | 旧体系下与旧参考模型的差异登记（不再新增；S 编号仍被引用） | 查某个 S 编号 |
| [../scripts/README.md](../scripts/README.md) | 脚本索引（lint、门禁、综合、闭环） | 跑东西之前 |

## 历史文档（[history/](history/)，已退役，只供查阅）

逐模块锁步、trace 回放、变异检查体系在 2026-11-04 随旧参考模型退役（代码在标签 `legacy-reference`）。相关文档：
`02-development-flow.md`（逐模块开发流程）、`03-harness.md`（逐拍对照 harness）、`07-roadmap.md`（翻译阶段的里程碑和待办，仍有效的条目已并入总仓库 `docs/TODO.md`）、
`AGENT_BRIEF.md`（翻译任务书）、`analysis/*-record-hook.*`（参考模型录制点）。

## 常用命令

```bash
make cfg                                    # 从 trace-model/include/config.h 生成 rtl/common/ttg_cfg_pkg.sv（不要手改）
bash scripts/lint.sh                        # 编码规范 + verilator -Wall（按目录）
bash scripts/lint_chip.sh                   # 整芯片 -Wall（CFG=<包> 用别的配置检查）
SOC_FM=1 SOC_OUT=$PWD/build/soc_fm bash tb/soc/build.sh     # 带 function-model 逐条对比的整核测试平台
bash scripts/fm_gate.sh $PWD/build/soc_fm/obj/soc_tb $PWD/build/gate   # 69 个程序门禁，并报告与 trace-model 周期不同的个数
bash scripts/synth_cfg.sh <标签> <配置包> <模块...>                      # 综合对比
make tracker                                # 由 docs/modules/*.md 头部重新生成 05 进度表
```

## 目录结构

```
docs/        本目录（history/ 为退役文档）
rtl/         所有 RTL（common/ backend/ frontend/ memsys/ core/），说明见 rtl/README.md
spec/        模块接口规格 <module>.io（tools/gen_backtop.py 由它生成 back_top.sv / exu.sv）
harness/     tools/（gen_cfg_pkg、iogen、svlint）及旧回放器源码
tb/soc/      整核测试平台（SimDDR、外设模型、function-model 逐条对比）
tools/       生成器：gen_backtop、dimmap（字面尺寸 → 配置参数）、pack_bits、gen_soc_probe、gen_soc_top
tests/       fpu、common 原语等专项测试；selftest/ 是旧 harness 自检
scripts/     索引见 scripts/README.md
programs/    缩短版 dhrystone/coremark 及源码（programs/big）
build/       构建产物（不入库）
```

测试程序二进制取自 `~/personal/AI-Huma/trace-model/build/{tests,vm}`；Linux 镜像在 `~/personal/AI-Huma-data/linux/`（生成方法见 function-model `linux/README.md`）。
