---
module: axi_subsys
area: memsys
rtl: rtl/memsys/axi_subsys
model: trace-model AxiSubsystem.cpp、include/AxiSubsystem.h（调度单元 `axi`，类 `AxiSubsystem`；阶段 `comb_begin`、`comb_outputs`、`comb_inputs`、`seq`）
status: 整核周期与模型逐个相等（最近一次提交 60ed422 的提交信息记 fm_gate 67/67、周期等于 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；本次写文档没有重跑）
depth: 353 层（axi_subsys（含互连和 LLC），单模块综合，2026-11-20，`SYNTH_ABC="strash;balance;map"`，生成门代理，见 09-synthesis-report 第 12 节）
---

# axi_subsys 设计文档

## 1. 职责

整个 AXI 互连 + LLC 子系统的 RTL 顶层：把 `axi_interconnect`（互连核心，见 axi_interconnect.md）和 `axi_llc`（最后一级缓存，见 axi_llc.md）按端口一一连起来，对外只露出两组边界：访存子系统的 **4 个读主口、2 个写主口**，和 **DDR 从口**（AXI 的 AR / R / AW / W / B 通道）。本模块没有状态、没有逻辑，只有连线。DDR 和 MMIO 的模型不在 RTL 里，留在测试平台（`tb/soc/platform`）。它被 `rtl/memsys/mem_top/mem_axi.sv` 实例化（`u_axi`）。

模型对应：`AxiSubsystem` 是模型的一个调度单元，里面有互连（`AXI_Interconnect interconnect`）、DDR（`SimDDR ddr`）、MMIO 总线（`MMIO_Bus_AXI4 mmio`）和 UART。LLC 的数据通路在互连里，LLC 的行表在 `MemSubsystem`（`llc_*`），由 `SimCpu::init` 绑定。RTL 的划分不同：互连、LLC（含行表）是两个模块，DDR / MMIO / UART 在 RTL 之外。

## 2. 配置

无自己的参数。几何与深度见 axi_interconnect.md、axi_llc.md；宏 `AXI_LLC_MSHR`（默认 8）在两个子模块的包里各有一份默认，必须一致；`AXI_SUBSYSTEM_FREQ_DIV` 不在这里使用，`phase0` 由 `mem_top` 给。

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n`、`phase0` | 时钟、复位、CPU 周期的第 0 个 tick（`FREQ_DIV = 1` 时恒 1） |
| 入 | `m_rd_valid / addr / size / id / bypass / resp_ready [4]`、`m_wr_valid / addr / data(512) / strb(64) / size / id / bypass / resp_ready [2]` | 主口请求 |
| 入 | `d_arready`、`d_rvalid / d_rid(6) / d_rdata(256)`、`d_awready`、`d_wready`、`d_bvalid / d_bid(6) / d_bresp` | DDR 从口输出 |
| 出 | `m_rd_resp_valid / id / data [4]`、`m_wr_resp_valid / id / resp [2]` | 主口响应 |
| 出 | `m_rd_accepted / _id`、`m_rd_acc_new / _id`、`m_wr_accepted`、`m_wr_acc_new` | 已接收标志（口径见 axi_interconnect.md 5.7） |
| 出 | `m_rd0_req_ready`、`m_rd3_req_ready`、`m_wr1_req_ready` | 读 0（ICache）、读 3（外设）、写 1（外设）的 `req.ready` |
| 出 | `d_arvalid / id / addr / len`、`d_awvalid / id / addr / len`、`d_wvalid / data(256) / strb(32) / last`、`d_rready`、`d_bready` | DDR 主口 |

与模型的端口对应：这些就是模型 `read_ports[]` / `write_ports[]`（互连的主口）和 `axi_ddr_io` 的字段，`m_*` 是主口，`d_*` 是 DDR 一侧。

## 4. 结构

```
 m_rd[4] / m_wr[2] ─► axi_interconnect (u_ic) ◄──── li_* / lo_* / hz_* ────► axi_llc (u_llc)
                          │
                          └─► d_* ─► DDR 从口（测试平台）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `axi_subsys.sv` | 290 | 端口声明 + 两个实例 + 内部连线 |

内部连线：互连的 `li_rd_* / li_wr_*`（送给 LLC 的请求，前缀 `up_`）接 LLC 的 `up_*` 输入；LLC 的 `up_*_req_ready / resp_*` 接互连的 `lo_*`；互连的 `li_mem_*`（DDR 侧的响应与 ready）接 LLC 的 `mem_*` 输入；LLC 的 `mem_*_req_*` 接互连的 `lo_mem_*`；LLC 的 `hz_lookup_* / hz_rresp_* / hz_mshr_*` 接互连的同名 `hz_*`。LLC 的 `hz_wctx_*`、`hz_wresp_*` 没有接收方，在顶层用 `unused_hz` 吃掉。

## 5. 一拍内的数据流

纯组合连线，没有自己的一拍内顺序。模型里 `AxiSubsystem` 的求值顺序（`comb_outputs`：先 LLC 查表输出，再 DDR / MMIO 的输出，再互连的输出；`comb_inputs`：互连的输入，再 DDR / MMIO 的输入；`seq`：先 LLC 行表更新，再互连，再从设备）在 RTL 里没有对应物：两个子模块每拍各更新一次。两者之间的依赖（从代码读出）是：互连的台（寄存器）→ `li_*` → LLC 的接收判断 → `lo_*_ready` → 互连台的弹出，起点是寄存器，没有看到组合环（没有用工具检查）。

## 6. 关键路径与深度

单模块综合深度 **238 层**（axi_subsys（含互连和 LLC）；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_llc.u_core.u_mshr.g_ent[6].u_ent.bypass_q` 到 `\u_llc.u_core.u_resolve.u_line.data [8191]`。本模块自己没有逻辑；跨两个子模块的最长链是"互连台 → LLC 读接收 → `up_rd_req_ready` → 互连台的弹出 / 抢占 / 派发 / 捕获"（见 axi_interconnect.md、axi_llc.md 第 6 节），综合时需要把两个模块放在一起才能量到。未综合验证。

## 7. 与模型的差异和取舍

- 没有 MMIO 从口和 UART：模型的 `AxiSubsystem` 里有 `mmio` 和 `uart`（`mmio.add_device(UART_ADDR_BASE, ...)`），RTL 的 DDR 从口之外没有第二个从口；
- 没有 DDR 模型：`d_*` 是端口，DDR 时序在测试平台的 `SimDDR`（模型的 `sim_ddr`）里；
- 模型的 `sync_uart_from_backing`（从 checkpoint 恢复 UART 寄存器）是仿真辅助，RTL 没有；
- 模型的 LLC 行表在 `MemSubsystem` 里，RTL 在 `axi_llc_tables` 里。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序（周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`），`scripts/lint_chip.sh`，Linux 启动门禁（`scripts/build_soc64_linux.sh`、`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`）。
- **没有模块级的测试**：旧体系有一个整体锁步 spec（`axi_subsys.io`，主口 + DDR 从口），已随 `spec/` 退役。**待补**：见 axi_interconnect.md、axi_llc.md 的"待补"（随机驱动主口，与模型的 `AxiSubsystem` 逐 tick 对拍；对拍时 DDR 一侧用同一个 `SimDDR`）。

## 9. 参数与开关速查

宏 `AXI_LLC_MSHR`、`AXI_LLC_SETS`、`AXI_LLC_WAYS`（见两个子模块）；无其他。

## 10. 变更记录

- 本分支（`261bd67..HEAD`）未改动本目录；更早：见 git 历史。
