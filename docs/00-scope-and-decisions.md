# 00 范围与已定决策

## 目标

rtl 是 AI-Huma 自己的处理器实现。第一阶段（至 2026-11-04）把 tututugege 参考模型逐模块翻译成 SystemVerilog，每个模块每一拍与参考模型一致，作为起点；这个目标已经完成，对应体系退役（[history/](history/)、标签 `legacy-reference`）。

现在（2026-11-04 起）RTL 随项目自己的优化迭代（2026-11-12 起同时支持 rv32imab 与 rv64imab，配置包 `XLEN_BITS` 选择；rv64 的 F/D、C、SPEC 未做）：架构行为与 function-model 逐条提交一致是门禁，周期数、IPC 和面积是要优化的指标；架构改动先在 trace-model 上探索，合入 main 时两者同一配置下周期逐个相等（见 [06-equivalence-policy.md](06-equivalence-policy.md)、总仓库 `docs/WORKFLOW.md` 第 6 节）。

## 参考

- **架构参考**：`function-model`（逐条提交对比，见 [06](06-equivalence-policy.md)）。
- **性能参考**：`trace-model`；核参数的唯一来源是 `trace-model/include/config.h`，由 `make cfg` 生成 `rtl/common/ttg_cfg_pkg.sv`，RTL 里不允许手写这些常数。
- 最初的参考模型（`tututugege/simulator`，commit `2f31e8d`）已退役，rtl 不再依赖它的源码；历史脚本在标签 `legacy-reference`。

## 已定决策

| 项目 | 决定 | 理由 |
| --- | --- | --- |
| 语言 | SystemVerilog（IEEE 1800-2017 子集，见规范） | 用户指定 |
| 仿真器 | Verilator 5.x，`-Wall` 全部警告视为错误（`scripts/lint.sh`、`scripts/lint_chip.sh`） | 本机已有，速度够整核闭环 |
| 时钟/复位 | 单时钟 `clk`，同步低有效复位 `rst_n` | 简单、可综合 |
| 对照方式 | 整核测试平台逐条提交对比 function-model（`scripts/fm_gate.sh`、`tb/soc/fm_check.h`）；周期与 trace-model 整程序比较（`scripts/ref_cycles.txt`，合入 main 时逐个相等）。翻译阶段用的 trace 回放 / 模块锁步已退役（2026-11-04，[history/](history/)） | RTL 要自己迭代微架构，逐拍一致不再成立 |
| 位宽 | `XLEN_BITS`（32 默认 / 64）是配置包参数；物理地址始终 32 位（rv64 为 Sv39 虚拟地址 + 32 位物理地址）；dcache 行和 AXI 侧是 32 位字 | EXP-029：先在 trace-model 上验证，再迁移 RTL |
| 综合性 | 写成可综合风格（见规范）；有 yosys 通用门面积代理（[09](09-synthesis-report.md)），没有工艺库和时序 | 避免以后重写 |

## 范围分级

| 级别 | 内容 | 形式 |
| --- | --- | --- |
| A：核 | 前端（BPU、ICache、FIFO 群）、后端（Idu/Ren/Dispatch/Isu/Exu/Prf/Rob/Csr/Lsu/TLB） | RTL |
| B：访存 | DCache、MSHR、PTW、LLC、AXI interconnect（LSU 里的 store 写缓冲见 `RTL_WBUF_NOTES.md`） | RTL |
| C：平台 | DDR 模型（SimDDR + DRAMsim3）、MMIO/UART、PhysMemory、DMA | 留在 testbench（`tb/soc`，平台模型冻结在 `tb/soc/platform/`） |
| D：PMU | tier 1 事件总线 + 计数器块在 `rtl/pmu/`（EXP-013，软件不可见，CSR 未接）；trace-model 的 TMA 槽级归因不翻译 | 部分 RTL |

范围 B/C 的边界现状：AXI 子系统 / LLC / interconnect 都是 RTL（`rtl/memsys/`），默认不分频（`AXI_SUBSYSTEM_FREQ_DIV = 1`）；16 倍分频配置不再支持。

## 非目标

- 工艺库综合、时序签核（没有库和约束）。
- rv64 的 F/D、C 扩展和 SPEC rv64（见总仓库 `docs/TODO.md`）。

## 参考模型已退役（2026-11-04，用户决定）

原 tututugege/simulator 不再维护、也不再是验证对象。后果：

- **整核闭环不再依赖它的源码**：`tb/soc/platform/` 收进了闭环测试平台用到的平台模型文件（SimDDR、PhysMemory、PeripheralModel 及头文件，冻结）；`gen_cfg.sh` 从 trace-model 的 `config.h` 取配置；额外程序在 `programs/extra/`。
- **新的对照对象**：周期以 **trace-model** 为准，架构值以 **function-model** 为准。
- 旧的模块级锁步（`refsim*`、`traces/`）、`deviations.md` 的审批流程和相关脚本已退役，代码在标签 `legacy-reference`，不再重建。
