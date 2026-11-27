---
module: soc_top
area: core
rtl: rtl/core/soc_top/soc_top.sv
model: trace-model SimCpu.cpp / include/SimCpu.h（`SimCpu::cycle`：核 + `MemSubsystem` + `AxiSubsystem` 的整体调度；不是单个调度单元）
status: 整核周期与 trace-model 逐个相等（`core_tb` + `fm_gate.sh` 77/77 PASS，0 周期差；26 窗 Linux PT/UP 全等）
depth: 仅顶层连线（见 core_top / mem_top）
---

# soc_top 设计文档

## 1. 职责

整核闭环的最外层：一个 `core_top`（核，见 core_top.md）加一个 `mem_top`（访存子系统：`mem_route`、`ptw_walk`、`dcache`、`peripheral_axi`、`axi_subsys`、`axi_cpu_port_adapter`），两者按端口名连接。`mem_top` 的端口名与 `core_top` 的存储侧端口同名、方向相反，所以 `soc_top` 只写了 `core_top u_core (.clk(clk_cpu), .*)` 和 `mem_top #(.PF_EN(PF_EN)) u_mem (.clk, .*)` 两个实例，其余全是为 `.*` 声明的同名连线。

边界之外（留在测试平台 `tb/core` → `core_tb`）：DDR 从设备（`d_*` 端口，AXI AR / R / AW / W / B）、外设模型（`env_*` 端口：`env_modeled`、`env_rdata` 入，`env_rd_en / addr / func3` 出）、物理内存、中断源（`interrupt_inject_*` 输入）、时钟与复位。逐条退休流（`rob_commit_*`、`rob_bcast_*`、`out_mispred`、`out_redirect_pc`、`ftq_commit_info_resp_pc`、`out_commit_entry_uop_diag_val`）从 `core_top` 直接导出，给测试平台的函数模型逐条对比。真实流片向 SoC 顶层与全套片上 AXI4/外设由 `chip_top` + `tb/soc`（`soc_tb`）独立承载（见 [chip_top.md](chip_top.md)），两者职责正交：`core_tb` 守护核+存储微架构与三仓逐拍对齐，`soc_tb` 守护全片 AXI4 互联与真实外设集成。

模型对应：`SimCpu::cycle` 同时驱动核、`MemSubsystem` 和 `AxiSubsystem`；RTL 把"核"和"访存 + AXI"分成两个子树，由 `soc_top` 拼起来。`DDR`、`MMIO`、`PhysMemory`、`PeripheralModel` 在模型里是 `SimCpu` 的成员，在 RTL 里是测试平台（用的是模型同源的源码，`tb/core/platform`）。

## 2. 配置

| 量 | 值 | 来源 |
| --- | --- | --- |
| 参数 `PF_EN` | 1（L1D 数据预取器 h1，EXP-009） | `soc_top.sv` 参数，传给 `mem_top` → `dcache` |
| 时钟 | `clk`（访存域的 tick 时钟）、`clk_cpu`（核时钟） | 端口；测试平台在每个 CPU 周期的 tick 0 给 `clk_cpu` 一个脉冲（`tb/soc/soc_tb.cpp`），现行 `AXI_SUBSYSTEM_FREQ_DIV = 1`，即每个 `clk` 沿都同时给 `clk_cpu` 脉冲 |
| 数据宽度 | `XLEN_BITS = 64` | `ttg_cfg_pkg` |
| 提交宽度 | `COMMIT_WIDTH = 8` | `ttg_cfg_pkg` |
| DDR 数据拍 | 256 位，AXI id 6 位 | `d_rdata`、`d_rid` 位宽 |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`clk_cpu`、`rst_n` | 时钟与复位 |
| 入 | `interrupt_inject_{external, supervisor_external, timer}_irq_pending` 与 `_valid` | 外部注入的中断（测试平台的外设模型给） |
| 入 | `env_modeled`、`env_rdata` | 外设模型：该 MMIO 地址是否被模型承接、读数据 |
| 入 | `d_arready`、`d_rvalid / d_rid / d_rdata`、`d_awready`、`d_wready`、`d_bvalid / d_bid / d_bresp` | DDR 从口输出 |
| 出 | `env_rd_en / env_rd_addr / env_rd_func3` | 对外设模型的读请求 |
| 出 | `d_arvalid / id / addr / len`、`d_awvalid / id / addr / len`、`d_wvalid / data / strb / last`、`d_rready`、`d_bready` | DDR 主口 |
| 出 | `phase0` | 访存域的"CPU 周期第 0 个 tick"（现行恒为 1） |
| 出 | 退休流和重定向 | 见上；给测试平台逐条对比 |

PMU 事件总线（`core_top` 里的 `pmu_ev_inc`）**没有**出现在 `soc_top` 的端口上，测试平台通过 `tb/soc/pmu_public.vlt` 声明的 public 变量按层次名读（`soc_top__DOT__u_core__DOT__pmu_ev_inc`，`tb/soc/soc_tb.cpp`）。

## 4. 结构

```
 clk_cpu ─► core_top (u_core) ◄──── 同名端口（.*）────► mem_top (u_mem) ◄── clk
                │ 退休流 / 重定向                           │ env_* ↔ 外设模型      │ d_* ↔ DDR 从口
                ▼                                           ▼                       ▼
            测试平台：逐条对比、外设 / 物理内存 / DDR / 中断
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `soc_top.sv` | 147 | 端口、为 `.*` 声明的 71 根同名连线、两个实例 |

`soc_top.sv` 是手工维护的（文件头：2026-11 以前由 `tools/gen_soc_top.py` 生成，生成器和规格已删除）。没有寄存器和逻辑。

## 5. 一拍内的数据流

没有自己的逻辑。测试平台每个 CPU 周期做的事（`tb/soc/soc_tb.cpp`）：DDR 从口输出 → RTL → RTL 主口输出 → DDR 输入 → DDR `seq` → 时钟沿（`clk = 1`，tick 0 时 `clk_cpu = 1`）→ tick 0 之后外设模型 `tick()` 并更新下一周期的中断输入。外设读（`env_*`）的 `env_modeled` 变化后会再求值一次，让 `env_rd_en` 稳定（`soc_tb.cpp` 的注释）。与模型的顺序对应：`SimCpu::cycle` 先 `icache_port_regs_seq`，随后组合各阶段，最后各部件 `seq`。

## 6. 关键路径与深度

depth 待测（由协调者补）。本模块只有连线，没有逻辑；整芯片的关键路径在 `core_top` 与 `mem_top` 的子模块里（见各自文档）。跨 `core_top` / `mem_top` 的组合路径（核的 LSU 请求 → `mem_route` → `dcache`，DCache 响应 → LSU）具体深度没有读到，留给 mem_top 一侧的文档。未综合验证。

## 7. 与模型的差异和取舍

- 双时钟：RTL 有 `clk` 和 `clk_cpu`，原 16 倍频方案遗留；现行 1 tick / 周期时两者同沿。模型没有时钟的概念，一个 `SimCpu::cycle` 就是一个 CPU 周期（`AxiSubsystem` 的 tick 数 = `CONFIG_AXI_SUBSYSTEM_FREQ_DIV` = 1）。
- 外设：模型的 `PeripheralModel` 在 `MemSubsystem` 里；RTL 的 `peripheral_axi` 只管请求侧，设备在测试平台（`env_*`）。
- 没有 `restore_pc`（从快速模式切回）和检查点恢复入口：测试平台用 `ckpt2image.py` / `ckpt2stub.py` 把检查点变成镜像和启动桩（见 `scripts/linux_segments_cmp.sh`）。
- `mem_top.sv`、`mem_axi.sv`、适配器的文件头注释仍写"16 倍频 / 16 tick"，现行配置不是（`TICKS = AXI_SUBSYSTEM_FREQ_DIV = 1`，`phase0` 恒 1），只记录，没有改。

未核对（继承自旧文档）：旧文档里的"集成时的非显然规则"（DCache 的 LSU 请求只在 tick 0 进入、ICache 响应加一级 `cpu_en` 寄存器、外设响应有保持寄存器、读口 1 / 写口 0 直连常量等）是 16 tick 时代的结论，本次只对着 `mem_top.sv` / `mem_axi.sv` 看到了其中一部分的代码（`cpu_en(phase0)`、`m_rd_size[1] = 8'd63`、`m_wr_strb[0] = '1`、`m_wr_resp_ready[0] = 1'b1`），没有逐条核对；"空闲 tick 跳过"（测试平台加速）在 16 tick 下才有意义，现行配置下没有用到。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh <core_tb> <outdir>`：77 个程序，每条提交对比函数模型（`SOC_FM=1` 构建）；周期对 `scripts/ref_cycles.txt`（模型同配置生成）。构建：`SOC_FM=1 CORE_OUT=<绝对路径> bash tb/core/build.sh`。
- **SVA 断言与覆盖（`SOC_SVA=1`）**：`sva/sva_axi_ddr.sv` 通过 `bind` 挂载至 `soc_top`（零综合污染），检查外部 DDR AXI4 主口 AR/AW/W 通道 `valid` 稳定性规则，并带 5 个通道握手 cover（AR/AW/W/R/B；`programs/directed/llc_ddr_wb.S` 已打通 AW/W/B 92 次）。
- **构建与运行期验证开关**：`tb/core/build.sh` 支持 `SOC_ASSERT=1`、`SOC_SVA=1`、`SOC_XINIT_UNIQUE=1`、`SOC_COV=1|all`（默认全关）；运行期支持 `SOC_TB_FM_STRICT=1`（MMIO/跨字 store + 18 架构 CSR + 特权级对比）与 `SOC_TB_COV_OUT`。
- **Lint**：`scripts/lint_chip.sh`（以 `soc_top` 为顶，整芯片 Verilator `-Wall`）。
- **冒烟**：`scripts/soc_smoke.sh`（周期对 `scripts/ref_cycles.txt`）、`scripts/cmp_trace_model.sh`（整程序周期与提交数对模型）。
- **Linux 启动门禁**：`scripts/build_soc64_linux.sh`（rv64 测试平台，逐条对比，默认 4 个仿真线程）、`scripts/linux_gate.sh`（全程）、`scripts/linux_segments_cmp.sh`（并行窗口）。
- **与模型对齐诊断**：`scripts/align_check.sh`、`scripts/pmu_parity.sh`（见 pmu.md）。
- 没有 `soc_top` 自己的模块级测试：它没有逻辑。

## 9. 参数与开关速查

`PF_EN`（`soc_top` 参数，默认 1）；测试平台环境变量 `SOC_TB_FM`、`SOC_TB_SEMIHOST`、`SOC_TB_PMU`、`SOC_TB_LOG` 等（见 `tb/core/core_tb.cpp`）；构建开关 `SOC_FM`、`SOC_XLEN`、`CORE_VOPT`/`SOC_VOPT`（`tb/core/build.sh`）。

## 10. 变更记录

- 2026-11-26：测试台目录由 `tb/soc/`（`soc_tb`）更名为 `tb/core/`（`core_tb`），将 `tb/soc/`（`soc_tb`）让给真实全片 SoC `chip_top`；`soc_top` 端口与行为 100% 不变（`EXT_MMIO_EN=0`、`software_irq=0`），`fm_gate.sh` 77/77 PASS（0 周期差）。
- 旧版文档（第 1~5 节的"锁步 / mutants / 16 tick 规则"）按 16 倍频方案写成，已按现行配置重写。
