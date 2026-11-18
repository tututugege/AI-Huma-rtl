---
module: peripheral_axi
area: memsys
rtl: rtl/memsys/peripheral_axi
model: trace-model MemSubSystem/PeripheralAxi.cpp、include/PeripheralAxi.h（调度单元 `mem_subsystem.peripheral_axi_`，类 `PeripheralAxi`，阶段 `comb_commit_store`、`comb`）；设备本体是同目录的 `PeripheralModel`（它是 `PeripheralAxi` 的子模块，不单独调度）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 10 层（peripheral_axi，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# peripheral_axi 设计文档

## 1. 职责

不经过数据缓存的访问（MMIO，即访问外设的读写）的发起单元。LSU 判断某次 load / store 是外设访问（`is_mmio`）后，把请求交给它；它一次只处理一个请求，走两条路之一：

1. **环境建模的设备**（由测试平台里的设备模型回答，如定时器）：当拍接受请求，读数据由环境给（`env_rdata`），下一拍给出响应；
2. **其余地址**：在 AXI 读 / 写主口（EXTRA 口，见 mem_top.md）上发一次单字访问（旁路 LLC），等 AXI 响应后给出响应。

响应只有一拍有效（`resp_is_mmio` 为 1 的那一拍），空闲时 `resp_ready` 为 1。

模型是两个阶段：`comb_commit_store`（把本拍提交的设备 store 应用到设备模型）和 `comb`（请求 / 响应 / AXI 信号）；状态更新在 `seq`。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| 数据字 | 请求 / 响应数据 `XLEN_BITS = 64`；AXI 通路是单个 32 位字 | `ttg_cfg_pkg`、`peripheral_axi_fmt.sv` |
| AXI 访问大小 | `total_size = 字节数 - 1`，2 位，取值 0、1、3（1、2、4 字节） | `PA_SIZE_W`（`memcpu_pkg`） |
| 字节使能 | 4 位 | `axi_wr_req_wstrb` |
| AXI id | 0（EXTRA 口，`mem_axi` 里写死） | `mem_axi.sv` |
| 状态更新时机 | 只在 `cpu_en`（= `phase0`，现行配置恒为 1） | |

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `req_is_mmio`、`req_wen`、`req_addr`、`req_wdata`、`req_func3` | LSU 的外设请求：地址、写使能、写数据（64 位）、访问类型 func3 |
| 入 | `env_modeled`、`env_rdata` | 该地址是否是环境建模的设备；若是，读数据（64 位，已按 func3 扩展） |
| 入 | `axi_rd_req_accepted`、`axi_rd_resp_valid`、`axi_rd_resp_data[31:0]` | AXI 读口：请求被接受、响应及数据字 |
| 入 | `axi_wr_req_accepted`、`axi_wr_resp_valid` | AXI 写口 |
| 出 | `resp_ready`、`resp_is_mmio`、`resp_rdata` | 给 LSU：空闲；响应有效；读数据 |
| 出 | `axi_rd_req_valid/addr/size`、`axi_rd_resp_ready` | AXI 读请求 |
| 出 | `axi_wr_req_valid/addr/size/wstrb/wdata`、`axi_wr_resp_ready` | AXI 写请求 |
| 出 | `env_rd_en`、`env_rd_addr`、`env_rd_func3` | 向环境要读数据（只在"接受请求且是环境设备的读"那一拍为 1） |

响应给 LSU 之前，`mem_top` 还有一级保持寄存器（`hold_*`，对应模型里 `mmio_resp_d` 寄存器，`SimCpu.cpp` 中 `peripheral_resp` 指向 `back.lsu->mmio_resp_d`），所以 LSU 比本模块的响应晚一拍看到。

## 4. 结构

```
 peripheral_axi (顶层：端口适配)
   ├ peripheral_axi_fmt : 与访问大小有关的格式化（组合）：AXI 大小、字节使能、写数据截断、读数据符号 / 零扩展
   └ peripheral_axi_ctl : 状态机（空闲 / 发请求 / 等响应 / 响应一拍）和寄存器
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `peripheral_axi.sv` | 55 | 顶层 |
| `peripheral_axi_ctl.sv` | 143 | 状态机 |
| `peripheral_axi_fmt.sv` | 41 | 格式化 |

状态：`busy_q`（AXI 访问进行中）、`write_q`、`accepted_q`（AXI 请求已被接受，等响应）、`resp_valid_q`（响应这一拍有效）、`addr_q`（32 位）、`wdata_q`、`rdata_q`（各 64 位）、`func3_q`。

## 5. 一拍内的数据流

输出全部来自寄存器状态（除 `env_rd_*` 和 AXI 请求的有效位随状态组合得出）。

1. **空闲** = `!busy_q && !resp_valid_q`，此时 `resp_ready = 1`，可以接受请求：`accept = idle && req_is_mmio`；
   - `env_modeled`：本拍 `env_rd_en`（若是读）；下一拍 `resp_valid_q = 1`，`rdata` = 读数据（写则 0）；
   - 否则：`busy_q = 1`，`accepted_q = 0`；
   两种情况都锁存地址、写数据、func3、写标志；
2. **发请求** = `busy_q && !accepted_q`：对应的 AXI 读或写请求有效，大小、字节使能、写数据由 `peripheral_axi_fmt` 按锁存的 func3 给出（`func3[1:0]`：0 → 1 字节、1 → 2 字节、其余 → 4 字节，写数据取低 32 位）；`axi_*_req_accepted` 到来后 `accepted_q = 1`；
3. **等响应** = `busy_q && accepted_q`：`axi_*_resp_ready = 1`；响应到来后 `busy_q = 0`、`resp_valid_q = 1`，读数据 = 响应字按 func3 扩展（写则 0）；
4. **响应一拍**：`resp_valid_q` 只持续一拍，这一拍不接受新请求。

读数据扩展（`peripheral_axi_fmt`）：`func3` 为 0（lb）、1（lh）符号扩展，4（lbu）、5（lhu）、6（lwu）零扩展，其余（lw 以及 ld 的低字）符号扩展到 64 位。

## 6. 关键路径与深度

单模块综合深度 **10 层**（peripheral_axi；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_ctl.func3_q [1]` 到 `\u_ctl.rdata_q [40]`。从代码读出的，未综合验证：很浅。最长的链是 `env_modeled`（来自环境）→ `local_serve` / `axi_issue` → 状态次态；`req_is_mmio` → `accept`；读数据格式化是 6 选 1 的扩展。AXI 的 `accepted` / `resp_valid` 输入直接进状态次态。

## 7. 与模型的差异和取舍

- **设备本体不在 RTL 里**：模型里 `PeripheralModel`（定时器、中断控制器等设备）是 `PeripheralAxi` 的子模块，读数据由 `read_load64` 直接给出；RTL 只保留握手，设备由测试台里的 C++ `PeripheralModel` 扮演，经 `env_modeled / env_rdata / env_rd_en` 接入（`tb/soc/soc_tb.cpp`：每拍用 `PeripheralModel::is_modeled_mmio(addr)` 驱动 `env_modeled`，`env_rd_en` 时调用 `read_mmio`）；
- **提交时的设备 store**：模型的 `comb_commit_store`（`on_commit_store`：每个提交的设备 store 作用到设备）在 RTL 里没有对应逻辑，由测试台在提交时调用 `periph.on_commit_store`（`soc_tb.cpp`，`sd` 按两个字写）；设备中断线（模型 `out.csr_interrupt_inject`）在 RTL 里怎么接入，本次没有核对；
- **读数据高 32 位**：模型的 `extract_read_data` 返回 32 位值再放进 64 位的 `rdata`（高 32 位为 0）；RTL 的格式化对 lb / lh / lw 做符号扩展到 64 位。只影响走 AXI 的（非环境设备的）有符号小读；环境设备的读数据在两边都由设备模型 / 测试台按 func3 扩展。没有核对 LSU 是否会再次扩展，因此不能断言一致；
- 模型的 `req_id` 是 8 位恒 0，RTL 的 AXI id 在 `mem_axi` 里写死为 0；
- 模型的 `bypass` 标志（旁路 LLC）在 RTL 的 `mem_axi` 里由 `m_rd_bypass[3] = phase0`、`m_wr_bypass[1] = phase0` 给出，不在本模块里。

未核对（继承自旧文档）：无，旧文档内容未带入。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序（周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`），与外设直接相关的有 `timer-mmio`（读写定时器，走环境建模设备路径）；`timer-interrupt-mask`、`interrupt-vectored` 等中断程序依赖设备产生的中断，但它们是否发出 MMIO 访问没有核对。走 AXI 的非建模地址路径（AXI 读 / 写 EXTRA 口）在这些程序里是否出现也没有核对。
- **定向程序**：`tests/rv64/mmio64.c`（8 字节 ld / sd 访问定时器，`mtimecmp` 往返，64 位 `mtime`，`lw / lwu / lh` 视图）；构建与运行方式没有脚本入口（`scripts/` 里没有引用它），本次没有运行。
- **Linux 整核门禁**：`scripts/linux_gate.sh`（串口、定时器、中断都走这条路径；逐提交对拍功能模型的设备读检查）。
- **Lint**：`scripts/lint_chip.sh`。
- **没有 peripheral_axi 的模块级测试**。**待补**：与模型 `PeripheralAxi` 并排的随机测试（随机请求序列、随机 AXI 接受 / 响应延迟、两种访问路径、各种 func3），并核对读数据高位的差异。

## 9. 参数与开关速查

`XLEN_BITS`（`ttg_cfg_pkg`）；`PA_SIZE_W`（`memcpu_pkg`）。无其他开关。

## 10. 变更记录

本分支未改动（`git log 261bd67..HEAD -- rtl/memsys/peripheral_axi` 为空），更早：`f0bd79d` rv64 step 6：8 字节 MMIO（ld / sd）；`4e954d7` ROB 紧凑（EXP-028）清理批次；`2d78026` 初次引入。
