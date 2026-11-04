# 00 范围与已定决策

## 目标

把参考模型翻译为 SystemVerilog RTL，**每个模块**都与参考模型在**每一拍**的所有边界信号一致，最终整核闭环运行与参考模型周期数一致。

## 参考模型

- 仓库：`tututugege/simulator`，锁定提交见 `tututugege-trace/baseline.lock`（`commit=2f31e8d`）。
- 本地路径：`$BASELINE_SRC`（见 `scripts/env.sh`，默认 `<AI-Huma>/../llm4trace/third_party/tututugege/baseline-sim/src`）。
- **参考模型是只读的**。需要加录制钩子时，在单独分支/副本里加，钩子只读取信号，不得改变任何行为（周期数必须与未加钩子时完全一致）。
- 配置（宽度、深度、位宽）以参考模型 `include/config.h` 为唯一来源，由 `make cfg` 生成 `rtl/common/ttg_cfg_pkg.sv`，**RTL 里不允许手写这些数字**。

## 已定决策

| 项目 | 决定 | 理由 |
| --- | --- | --- |
| 语言 | SystemVerilog（IEEE 1800-2017 子集，见规范） | 用户指定 |
| 仿真器 | Verilator 5.x，`-Wall` 全部警告视为错误 | 本机已有；逐拍对照需要快 |
| 时钟/复位 | 单时钟 `clk`，同步低有效复位 `rst_n` | 与参考模型 `init()` + 每拍 `comb()/seq()` 一一对应 |
| 对照方式 | trace 回放（开环）：参考模型录制模块端口，RTL 回放并逐拍比较输出 | 模块可独立验证、可重复、可自动定位首个分歧周期；集成后再做闭环 |
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
