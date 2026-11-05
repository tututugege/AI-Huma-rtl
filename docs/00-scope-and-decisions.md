# 00 范围与已定决策

## 目标

rtl 是 AI-Huma 自己的处理器实现。第一阶段（至 2026-11-04）把 tututugege 参考模型逐模块翻译成 SystemVerilog，每个模块每一拍与参考模型一致，作为起点；这个目标已经完成，对应体系退役（[history/](history/)、标签 `legacy-reference`）。

现在（2026-11-04 起）RTL 随项目自己的优化迭代：架构行为与 function-model 逐条提交一致是门禁，周期数、IPC 和面积是要优化的指标；架构改动先在 trace-model 上探索，合入 main 时两者同一配置下周期逐个相等（见 [06-equivalence-policy.md](06-equivalence-policy.md)、总仓库 `docs/WORKFLOW.md` 第 6 节）。

## 参考

- **架构参考**：`function-model`（逐条提交对比，见 [06](06-equivalence-policy.md)）。
- **性能参考**：`trace-model`；核参数的唯一来源是 `trace-model/include/config.h`，由 `make cfg` 生成 `rtl/common/ttg_cfg_pkg.sv`，RTL 里不允许手写这些常数。
- 最初的参考模型（`tututugege/simulator`，commit `2f31e8d`）已退役，rtl 不再依赖它的源码；历史脚本在标签 `legacy-reference`。

## 已定决策

| 项目 | 决定 | 理由 |
| --- | --- | --- |
| 语言 | SystemVerilog（IEEE 1800-2017 子集，见规范） | 用户指定 |
| 仿真器 | Verilator 5.x，`-Wall` 全部警告视为错误 | 本机已有；逐拍对照需要快 |
| 时钟/复位 | 单时钟 `clk`，同步低有效复位 `rst_n` | 与参考模型 `init()` + 每拍 `comb()/seq()` 一一对应 |
| 对照方式 | 整核测试平台逐条提交对比 function-model（`scripts/fm_gate.sh`）；周期与 trace-model 整程序比较。翻译阶段用的 trace 回放 / 模块锁步已退役（2026-11-04，[history/](history/)） | RTL 要自己迭代微架构，逐拍一致不再成立 |
| 对照粒度 | 模块边界的**每个**输出位，每拍；不允许只比提交流或周期数 | 用户要求"逐拍对照" |
| 综合性 | 写成可综合风格（见规范），但本阶段不做综合 | 避免以后重写 |

## 范围分级

| 级别 | 内容 | 形式 |
| --- | --- | --- |
| A：核 | 前端（BPU、ICache、FIFO 群）、后端（Idu/Ren/Dispatch/Isu/Exu/Prf/Rob/Csr/Lsu/TLB）| RTL，逐拍对照 |
| B：访存 | DCache、MSHR、PTW、write buffer、LLC、AXI interconnect | RTL，逐拍对照 |
| C：平台 | DDR 模型、MMIO/UART、PhysMemory、DMA、difftest、checkpoint | 留在 testbench（行为模型），不要求翻译；但其对核的时序必须与参考模型一致 |
| D：PMU / 性能统计 | `PerfCount.h`、TMA 归因 | **不翻译**；RTL 的 PMU 单独按硬件可实现性重新设计（见 06 第 8 节） |

> 范围 B/C 的边界（LLC 与 interconnect 是否做成 RTL、16 倍频 AXI 子系统如何处理）尚未最终决定，决定后写入本节。

## 非目标

- 综合、面积/频率优化、改进微架构。**RTL 的行为必须与参考模型逐拍相同，包括参考模型里"不合理"的行为**。想改行为，先走 `deviations.md` 的审批流程。

## 参考模型已退役（2026-11-04，用户决定）

原 tututugege/simulator 不再维护、也不再是验证对象。后果与处理：

- **整核闭环不再依赖它的源码**：`tb/soc/platform/` 收进了闭环测试平台用到的 19 个平台模型文件（SimDDR、PhysMemory、PeripheralModel 及头文件，约 300 KB，冻结）；`gen_cfg.sh` 也从那里取配置；4 个额外程序在 `programs/extra/`。
- **新的对照对象**：周期以 **trace-model** 为准（`scripts/cmp_trace_model.sh`、Linux 镜像逐周期对照），架构值以 **function-model** 为准。
- **模块级锁步变成冻结的回归工具**：`refsim`、`refsim_tap`、`refsim_axi`（本地、git 忽略）和 `traces/` 里已录好的 trace 仍可用来回归现有行为，但**不会再扩展**：trace-model 没有模块边界的录制钩子，也没有数据值（ALU/MUL/DIV/FP/PRF 的值都已删除），所以新增行为（例如 S-27 的 ebreak 断点异常）无法再用它验证。
- 旧参考副本和录制已删除（2026-11-04），不再重建。
