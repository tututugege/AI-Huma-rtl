# rtl

AI-Huma 乱序 RISC-V 核的 SystemVerilog 实现。起点是把 tututugege 模拟器逐模块翻译过来（2026-11-04 完成，前端、后端、访存子系统、整核）；现在随项目自己的优化迭代，核参数来自 trace-model 的 `config.h`（`make cfg`）。可以在 Verilator 里整核闭环运行（核 + 访存子系统 + DDR/外设模型）。

- 文档入口：[docs/README.md](docs/README.md)（范围、编码规范、模块设计笔记、风险登记簿）
- RTL 检查：`bash scripts/lint.sh`（按目录）、`bash scripts/lint_chip.sh`（整芯片）
- **正确性门禁**：逐条提交对比 function-model —— `SOC_FM=1 SOC_OUT=$PWD/build/soc_fm bash tb/soc/build.sh`，`bash scripts/fm_gate.sh $PWD/build/soc_fm/obj/soc_tb $PWD/build/gate`（见 [scripts/README.md](scripts/README.md)、[docs/modules/soc_top.md](docs/modules/soc_top.md)）
- 周期数、IPC 是**性能指标**：不再要求与原模型相等；合入 main 时同一配置下与 trace-model 逐个程序相等（`fm_gate.sh` 会报告差异）

翻译阶段的"逐拍锁步 / trace 回放 / 变异检查"体系完成使命后退役，代码在标签 `legacy-reference`，文档在 [docs/history/](docs/history/)。
