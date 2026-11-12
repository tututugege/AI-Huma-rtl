# rtl 文档目录

rtl 是 AI-Huma 的 SystemVerilog 实现，rv32imab 与 rv64imab 两种位宽（配置包 `XLEN_BITS`，2026-11-12 合入 rv64；rv64 的 F/D、C、SPEC 未做）。正确性 = 整核逐条提交与 function-model 一致；周期数与 trace-model 比较（合入 main 时同一配置下逐个相等）。
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
| [modules/](modules/) | 每个模块的设计笔记（[模板](modules/TEMPLATE.md)）。**“验证”一节多是 2026-11-04 之前旧体系的结果**，现行验证看 06 和总仓库 LOG；多数笔记写于 rv32、行式 ROB、旧 LSU 时期，各笔记顶部若有“更新”提示以它为准；**“验证”节里的 `tests/<模块>/`、`scripts/lockstep_*`、`mutcheck.sh`、`record.sh`、`tb/<模块>/` 等脚本已随旧体系删除（在标签 `legacy-reference`）** | 写/改该模块 |
| [analysis/](analysis/README.md) | 翻译阶段的边界与结构分析（rv32、旧参考模型时期，设计内容可参考，位宽、PC 宽度、ROB 与 LSU 细节以模块笔记和源码为准） | 深入某个区域 |
| [deviations.md](deviations.md) | 旧体系下与旧参考模型的差异登记（不再新增；S 编号仍被引用） | 查某个 S 编号 |
| [../scripts/README.md](../scripts/README.md) | 脚本索引（lint、门禁、综合、闭环） | 跑东西之前 |
| [../RTL_FE_NOTES.md](../RTL_FE_NOTES.md)、[../RTL_MEMSPEC_NOTES.md](../RTL_MEMSPEC_NOTES.md)、[../RTL_WBUF_NOTES.md](../RTL_WBUF_NOTES.md)、[../RTL_INTEG_NOTES.md](../RTL_INTEG_NOTES.md) | 前端快速路径、LSU 访存推测、store 写缓冲、集成记录（英文，各带更新提示） | 改 `front_*`/`bpu`、`lp_*` 时 |

## 历史文档（[history/](history/)，已退役，只供查阅）

逐模块锁步、trace 回放、变异检查体系在 2026-11-04 随旧参考模型退役（代码在标签 `legacy-reference`）。相关文档：
历史文档写于 rv32、逐拍锁步时期，其中的命令、路径和数字可能已过时，**不要照着执行**。
`02-development-flow.md`（逐模块开发流程）、`03-harness.md`（逐拍对照 harness）、`07-roadmap.md`（翻译阶段的里程碑和待办，仍有效的条目已并入总仓库 `docs/TODO.md`）、
`AGENT_BRIEF.md`（翻译任务书）、`analysis/*-record-hook.*`（参考模型录制点）。

## 常用命令

完整说明（rv32 / rv64 构建、跑 Linux、生成文件的注意事项）见仓库根 [../README.md](../README.md)，脚本见 [../scripts/README.md](../scripts/README.md)。

```bash
make cfg                                    # 从 trace-model/include/config.h 生成 rtl/common/ttg_cfg_pkg.sv（不要手改）
bash scripts/lint.sh                        # 编码规范 + verilator -Wall（按目录）
bash scripts/lint_chip.sh                   # 整芯片 -Wall（CFG=<包> 用别的配置检查）
SOC_FM=1 SOC_OUT=$PWD/build/soc_fm bash tb/soc/build.sh     # 带 function-model 逐条对比的整核测试平台（rv32）
SOC_XLEN=64 SOC_FM=1 FMLIB=<rv64 librefcpu.a> SOC_OUT=$PWD/build/soc64 bash tb/soc/build.sh   # rv64
bash scripts/fm_gate.sh $PWD/build/soc_fm/obj/soc_tb $PWD/build/gate   # 69 个程序门禁，并报告与 trace-model 周期不同的个数
bash scripts/synth_cfg.sh <标签> <配置包> <模块...>                      # 综合对比
make tracker                                # 由 docs/modules/*.md 头部重新生成 05 进度表
```

## 目录结构

```
docs/        本目录（history/ 为退役文档）
rtl/         所有 RTL（common/ backend/ frontend/ memsys/ core/ pmu/），说明见 rtl/README.md
spec/        模块接口规格 <module>.io（tools/gen_backtop.py 由它生成 back_top.sv / exu.sv；**这些生成文件为 rv64 手改过，重新生成会丢位宽**，见根 README）
harness/     tools/（gen_cfg_pkg 配置包生成器、iogen、svlint）、include/trace_format.h（测试平台用）
tb/soc/      整核测试平台（SimDDR、外设模型、function-model 逐条对比）
tools/       生成器：gen_backtop、dimmap（字面尺寸 → 配置参数）、pack_bits、gen_soc_probe、gen_soc_top
tests/       专项测试：common（原语）、dcache（定向程序）、pmu、rv64（`mmio64.c`，8 字节 MMIO）（`tests/fpu` 随 Zfinx 的 FPU 于 2026-11-12 删除）
scripts/     索引见 scripts/README.md
programs/    缩短版 dhrystone/coremark 及源码（programs/big）
build/       构建产物（不入库）
```

测试程序二进制取自 `~/personal/AI-Huma/trace-model/build/{tests,vm}`；Linux 镜像在 `~/personal/AI-Huma-data/linux/`（rv64 在 `linux_rv64/`）（生成方法见 function-model `linux/README.md`）。
