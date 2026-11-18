---
module: axi_cpu_port_adapter
area: memsys
rtl: rtl/memsys/axi_cpu_port_adapter
model: 无对应的类。作用最接近 SimCpu.cpp 的 `icache_port_regs_seq`（把 `axi.interconnect.read_ports[MASTER_ICACHE]` 在周期开头拷成寄存的 `icache_axi_q`）；原 16 tick 方案里的 `capture / accumulate / restore_axi_cpu_boundary_state` 在 trace-model-tlbports 里已不存在
status: 整核周期与模型逐个相等（最近一次提交 60ed422 的提交信息记 fm_gate 67/67、周期等于 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；本次写文档没有重跑）
depth: 9 层（axi_cpu_port_adapter，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# axi_cpu_port_adapter 设计文档

## 1. 职责

三个"非 DCache"的 AXI 主口通道（0 = ICache 读，1 = 外设读，2 = 外设写）从互连（跑快时钟，每 tick 一个 `clk` 沿）到 CPU（每个 CPU 周期的第 0 个 tick 才动作）的**折叠与寄存**：互连每个 tick 都有这些口的 `ready`、`accepted`、响应，CPU 只在下一个 CPU 周期看到一个"整周期的视图"。规则（`axi_cpu_port_chan.sv` 头注释）：

- `ready`：整周期所有 tick 的 OR；
- `accepted`：整周期粘滞（任一 tick 接收过就算），`id` 取最后一次接收的 tick 的 id（只有 `accepted` 为真时可观察）；
- 响应 `valid / id`：取周期最后一个 tick 的响应；如果它属于本周期内刚接收的请求（同 id），则隐藏；
- 响应 `resp_ready`：取 tick 0 时主口给的 ready，在"响应在后面的 tick 里才出现"或"响应被隐藏"时撤回。

视图在周期最后一个 tick（`phase_last`）寄存，整个下一周期保持。

注意：现行配置 `AXI_SUBSYSTEM_FREQ_DIV = 1`（`ttg_cfg_pkg`），一个周期只有一个 tick，`mem_top` 里 `phase0 = phase_last = 1`（`mem_top.sv`），上面的"整周期折叠"退化成"把互连这一拍的值寄存一拍"。16 tick 的情形在 RTL 里保留着，但模型和测试平台的默认都不再用它（`tb/soc/soc_tb.cpp` 的 `kTicks` 从 `CONFIG_AXI_SUBSYSTEM_FREQ_DIV` 取）。

## 2. 配置

| 量 | 值 | 来源 |
| --- | --- | --- |
| 通道数 `AX_NCH` | 3（读 ICache、读外设、写外设） | `memcpu_pkg.sv` |
| id 位宽 `AX_ID_W` | 4（ICache 4 位；外设的 id 恒 0，写通道的 accepted id 不导出，`EXPORT_ID = (c != 2)`） | `memcpu_pkg.sv`、`axi_cpu_port_adapter.sv` |
| tick 数 | 由 `mem_top` 的 `TICKS = AXI_SUBSYSTEM_FREQ_DIV` 决定，现为 1 | `mem_top.sv`、`ttg_cfg_pkg.sv` |

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `phase0`、`phase_last` | CPU 周期的第一个 / 最后一个 tick |
| 入 | `raw_ready / raw_accepted / raw_accepted_id / raw_resp_valid / raw_resp_id / raw_resp_ready [3]` | 互连当拍的值（`mem_axi.sv` 里：`raw_ready` 来自互连的 `m_rd0_req_ready`、`m_rd3_req_ready`、`m_wr1_req_ready`；`raw_accepted` 来自"本 tick 接收"`m_rd_acc_new`、`m_wr_acc_new`；`raw_resp_ready` 是主口自己给的 `resp_ready`） |
| 出 | `cpu_ready / cpu_accepted / cpu_accepted_id / cpu_resp_valid / cpu_resp_id / cpu_resp_ready [3]` | 寄存后的视图，给 ICache 和外设口 |

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `axi_cpu_port_adapter.sv` | 47 | 实例化 3 个通道 |
| `axi_cpu_port_chan.sv` | 102 | 一个通道：整周期累加器 + 周期末寄存的视图 |

状态（每通道）：累加器 `ready_acc_q`、`acc_q`、`acc_id_q`、`resp0_valid_q`、`resp0_id_q`、`resp0_ready_q`（tick 0 的响应与 ready）；视图寄存器 `view_*_q`（6 组，只在 `phase_last` 更新）。

## 5. 一拍内的数据流

1. 累加：`phase0` 时累加器装当拍的原始值，否则与前面的 tick 合并（`ready` 取 OR，`accepted` 取 OR，`acc_id` 在有接收的 tick 更新）；
2. 视图的两个判断：`hide_resp = acc_n & raw_resp_valid & (raw_resp_id == acc_id_n)`（响应属于本周期刚接收的请求）；`resp_is_new = raw_resp_valid & 非(tick 0 时已是同 id 的有效响应)`；
3. `phase_last` 时寄存视图：`view_resp_valid = raw_resp_valid & !hide_resp`，`view_resp_ready = tick 0 的 resp_ready & !(resp_is_new | hide_resp)`，其他取累加值。

在 tick 数为 1 时：累加器每拍被装成当拍原始值，`resp_is_new` 恒为假，视图 = 原始值寄存一拍，只在"当拍接收的请求的 id 与当拍响应的 id 相同"时隐藏响应。互连的 id 冲突检查（`axi_ic_rd`）阻止了同 id 的请求在响应还没取走时被接收，所以该隐藏条件在 1 tick 下不会触发（从代码推断，未验证）。

## 6. 关键路径与深度

单模块综合深度 **9 层**（axi_cpu_port_adapter；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\g_chan[0].u_chan.resp0_id_q [2]` 到 `\g_chan[0].u_chan.view_resp_ready_q`。。从代码读出的：全是 1 位或 4 位的比较和选择，没有长链；`hide_resp` 的 4 位 id 比较是最长的一段。未综合验证。

## 7. 与模型的差异和取舍

- 模型里没有这个模块。现行配置（1 tick）下，它对应 `SimCpu::cycle` 开头的 `icache_port_regs_seq`（`icache_axi_q = axi.interconnect.read_ports[MASTER_ICACHE]`，周期开头拷一份寄存的端口）和 ICache 读这份拷贝；**外设两个口在模型里是否也读寄存的拷贝，本次没有核对**。
- `hide_resp` / `resp_is_new` 的整周期逻辑是原 16 tick 方案（模型当时的 `restore_axi_cpu_boundary_state` 等）的复刻，在 `FREQ_DIV = 1` 下没有作用。
- `phase0` / `phase_last` 是端口，由 `mem_top` 在 tick 数为 1 时接常量 1；综合时整周期累加逻辑被常量折掉（`mem_top.sv` 里的 generate）。

未核对（继承自旧文档）：16 tick 时各规则（OR、粘滞、最后一个 tick 的响应、隐藏）与旧模型 `capture / accumulate / restore_axi_cpu_boundary_state` 的逐项对应，只读了 RTL 注释，没有对着旧模型源码。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序（周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`）。ICache 的每一次取行都经过这个模块，周期逐个相等说明 1 tick 下的行为与模型一致。
- **Lint**：`scripts/lint_chip.sh`。
- **没有模块级的测试**。16 tick 配置（`AXI_SUBSYSTEM_FREQ_DIV = 16`）现在没有任何门禁在跑；**待补**：要么删掉 16 tick 的逻辑，要么补一个 tick 数 > 1 的回归（模型 `CONFIG_AXI_SUBSYSTEM_FREQ_DIV` 能改，但 RTL 的 `mem_top` 相位计数器是 4 位，`soc_tb.cpp` 有 `kTicks <= 16` 的静态断言）。

## 9. 参数与开关速查

`AXI_SUBSYSTEM_FREQ_DIV`（`ttg_cfg_pkg`，模型 `CONFIG_AXI_SUBSYSTEM_FREQ_DIV`）；`AX_NCH`、`AX_ID_W`（`memcpu_pkg`）；通道参数 `EXPORT_ID`。

## 10. 变更记录

- 本分支（`261bd67..HEAD`）未改动本目录；更早：见 git 历史。
