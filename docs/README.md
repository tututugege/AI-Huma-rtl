# tututugege-rtl 文档目录

目标：把 tututugege 的 RTL 风格 C++ 乱序核（参考模型）逐模块翻译成 SystemVerilog，并与参考模型**逐拍对照**通过。

| 文档 | 内容 | 谁必须读 |
| --- | --- | --- |
| [00-scope-and-decisions.md](00-scope-and-decisions.md) | 范围、参考模型版本、已定的技术决策 | 所有人 |
| [01-rtl-coding-standard.md](01-rtl-coding-standard.md) | RTL 编码规范（强制，工具检查） | 写 RTL 的人 |
| [02-development-flow.md](02-development-flow.md) | 单个模块从接口规格到"绿"的完整流程和验收标准 | 所有人 |
| [03-harness.md](03-harness.md) | 逐拍对照 harness：架构、trace 格式、使用方法、自检 | 所有人 |
| [04-cpp-to-rtl-mapping.md](04-cpp-to-rtl-mapping.md) | C++ 构造到 SV 构造的翻译规则；隐含依赖、求值顺序怎么处理 | 写 RTL 的人 |
| [05-module-tracker.md](05-module-tracker.md) | 模块进度表（**自动生成**，来源是各模块笔记头部） | 所有人 |
| [06-equivalence-policy.md](06-equivalence-policy.md) | 等价性原则：什么必须一致、什么不复刻（总原则在第 0 节） | 所有人 |
| [07-roadmap.md](07-roadmap.md) | 里程碑与未完成事项（人工维护） | 所有人 |
| [AGENT_BRIEF.md](AGENT_BRIEF.md) | 给 agent 的任务书（含补充条款） | 派任务的人 |
| [modules/](modules/) | 每个模块的设计笔记（头部 front-matter 供生成进度表） | 写/评审该模块的人 |
| [analysis/](analysis/README.md) | 边界分析、录制点补丁、覆盖数据 | 做新区域的人 |
| [deviations.md](deviations.md) | RTL 与参考模型的所有已批准偏差（默认为空） | 评审人 |

## 一分钟上手

```bash
make selftest          # 验证 harness 本身：干净 RTL 通过、植入的 bug 全部被抓到
make lint              # 编码规范 + verilator -Wall
make tracker           # 由 docs/modules/*.md 头部重新生成 05 进度表
make cfg               # 从参考模型 config.h 重新生成 rtl/common/ttg_cfg_pkg.sv
bash scripts/replay.sh <module> [trace...]   # 构建并回放某个模块
```

## 目录结构

```
docs/        本目录
rtl/         所有 RTL（common/ backend/ frontend/ memsys/ core/），说明见 rtl/README.md
spec/        每个模块的接口规格 <module>.io（harness 的输入，也是接口的唯一定义）
harness/     include/（trace 格式 + C++ 录制端）src/（通用回放器）tools/（iogen、svlint、gen_cfg_pkg）
tests/       selftest/（harness 自检）以及各模块的专项测试
scripts/     索引见 scripts/README.md
traces/      参考模型录制的逐拍 trace（不入库）
build/       构建产物（不入库）
```
