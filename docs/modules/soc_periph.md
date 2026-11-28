---
module: soc_periph
area: soc
rtl: rtl/soc/soc_bootrom/, rtl/soc/soc_clint/, rtl/soc/soc_plic/, rtl/soc/soc_uart/, rtl/soc/soc_sysctrl/, rtl/soc/soc_sram/
model: 取代 tb/core 中 C++ PeripheralModel 的真实可综合 RTL 外设集合
status: v1 全部通过 svlint + Verilator -Wall 及 soc_gate.sh 全套定向测试实测（含外部 rxd/16B FIFO、外部 ext_irq 优先级与 S-mode seip、sw_rst_req 软复位转 SRAM 启动、boot_mode=10 park）
depth: bootrom 27 / sram 23 / clint 26 / plic 72 / uart 20 / sysctrl 11 层（eda-05 Yosys `SYNTH_ABC="strash;balance;map"`，2026-11-26）
---

# SoC 片上外设设计文档（v1 + Full-AXI4 内存从口）

## 1. 职责

`soc_bootrom` 与 `soc_sram` 采用原生 **64-bit Full-AXI4 突发从接口**（支持 FIXED/INCR/WRAP 突发、1 拍/字流式吞吐、`ARID->RID`、`AWID->BID`、`RLAST` 及独立 AW/W 接收）；`soc_clint`/`soc_plic`/`soc_uart`/`soc_sysctrl` 采用 **64-bit AXI4-Lite 从接口**（经 `soc_axi_to_lite` 接入，保留精确字节地址 `s_araddr`/`s_awaddr` 以区分同 64-bit 字内的读副作用寄存器，如 UART RBR 与 PLIC Claim）。

### 1.1 `soc_bootrom`（`0x0000_0000`, 4 KiB）

只读可综合 RV64 BootROM（写请求返回 `SLVERR`）。上电读取 `SysCtrl.BOOT_STAT` (`0x1F00_0008`)：
- `boot_mode == 2'b00`：`a0 = mhartid`、`a1 = 0x83e0_0000`（兼容 OpenSBI + `linux_j.bin` DTB），跳转 `0x8000_0000`（DDR）。
- `boot_mode == 2'b01`：`a0 = mhartid`，跳转 `0x3000_0000`（片上 64 KiB SRAM）。
- `boot_mode == 2'b1x`：进入 `wfi; j -4` 安全等待循环（为 v2 Flash/JTAG 启动预留）。

### 1.2 `soc_clint`（`0x1FD0_E000` 与 `0x0200_0000`）

支持 32/64 位字节选通读写，由 `soc_crg` 跨时钟域同步后的 `rtc_tick` 驱动 64 位 `mtime`：
- AI-Huma Linux DTB 映射（`0x1FD0_E000`）：`+0x00 mtime`、`+0x08 mtimecmp`、`+0x10 msip`、`+0x18 rtc_cfg`（bit0 置 1 可切为核频计数）。
- 标准 SiFive CLINT 映射（`0x0200_0000`）：`+0x0000 msip`、`+0x4000 mtimecmp`、`+0xBFF8 mtime`。
- 输出：`mtip = (mtime_q >= mtimecmp_q)`、`msip = msip_q`。

### 1.3 `soc_plic`（`0x0C00_0000`, 64 MiB）

标准 RISC-V PLIC，支持 `PLIC_NUM_SRC = 8` 路电平中断源（ID `1..8`，ID 1 为 UART，ID `2..8` 为 `ext_irq[6:0]`）与 2 个上下文（Context 0 = M-mode `meip`，Context 1 = S-mode `seip`）：
- `0x000004..0x000020`：源 1..8 优先级（3-bit，0 禁用，1..7 递增）；
- `0x001000`：Pending 位图（RO）；
- `0x002000` / `0x002080`：Context 0 / 1 使能位图；
- `0x200000` / `0x200004`：Context 0 阈值 / Claim-Complete（精确匹配 `s_araddr == 0x200004` 才置 claimed）；
- `0x201000` / `0x201004`：Context 1 阈值 / Claim-Complete。

### 1.4 `soc_uart`（`0x1000_0000`, 4 KiB）

真实可综合 NS16550A（1 字节寄存器间隔，与 Linux `earlycon=uart8250,mmio,0x10000000` 与 `ns16550a` 驱动兼容）：
- 子模块：`soc_uart_tx.sv`（16× 过采样 8N1 串行发送）、`soc_uart_rx.sv`（2-FF 同步 + 下降沿检测 + 位中点采样 8N1 接收）、`soc_uart.sv`（寄存器与 16B TX/RX FIFO）。
- 寄存器：`+0 RBR/THR/DLL`、`+1 IER/DLM`、`+2 IIR/FCR`、`+3 LCR`（复位 `0x03` = 8N1）、`+4 MCR`（bit4 = 内部串口回环）、`+5 LSR`（DR/THRE/TEMT）、`+6 MSR`（`0xB0`）、`+7 SCR`。
- 复位分频 `divisor = 1`（16 拍/bit），软件可通过 DLAB 编程任意 16-bit 波特率分频；支持 RX Data Ready 与 TX Holding Empty 中断输出至 PLIC IRQ 1。

### 1.5 `soc_sysctrl`（`0x1F00_0000`, 4 KiB）

- `+0x00 CHIP_ID` (RO)：`64'h0001_0000_4855_4D41`（`"HUMA"` Rev 1.0）；
- `+0x08 BOOT_STAT` (RO)：`{62'd0, boot_mode}`；
- `+0x10 RST_CTL` (WO)：写入 `32'h5A5A_0001` 触发 4 拍 `sw_rst_req` 软复位脉冲；
- `+0x18 CORE_CTL` (RW)：芯片 bring-up 控制位（复位 `64'd1`）；
- `+0x20 / +0x28 SCRATCH0 / SCRATCH1` (RW)：64 位暂存寄存器；
- `+0x30 UPTIME` (RO)：64 位自由运行周期计数器。

### 1.6 `soc_sram`（`0x3000_0000`, 64 KiB）

8192 × 64-bit 单口同步 1RW SRAM（通过 `ttg_sram_1rw #(.TAG("SOC_SRAM_64KB"))` 例化，综合通过 `SYNTH_TSMC28_SRAM` 平铺映射 16 颗 `512x72` 真实 28nm HS LVT 宏；8-bit 字节写掩码），用于无 DDR 阶段裸机启动与代码/数据暂存，可同时接受 LSU 读写与 ICache 取指执行。它是全芯片唯一设 `INIT_SWEEP = 0` 的 SRAM 包装：复位里不清零（[common.md](common.md) 4.1 节），所以内容在 `sw_rst_req` 软复位后保持不变。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| 地址映射 | 见 [chip_top.md](chip_top.md) 第 2 节 | `soc_pkg`：`ADDR_*`、`SLV_*` |
| PLIC 中断源 | 8（ID 1 = UART，2..8 = `ext_irq[6:0]`），2 个上下文 | `soc_pkg::PLIC_NUM_SRC = 8`（UART 接 ID 1 是 `chip_top` 的连线，没有常量） |
| 片上 SRAM | 8192 × 64 位 = 64 KiB | `soc_sram` 参数 `WORDS = 8192` |
| AXI id 位宽 | `ID_W = 8`（`soc_bootrom`、`soc_sram`；`chip_top` 传 `OC_ID_W`） | 模块参数 |

## 3. 接口

- `soc_bootrom`、`soc_sram`：64 位 Full-AXI4 从口（AR / R / AW / W / B），接 Tier-2 互联；
- `soc_clint`、`soc_plic`、`soc_uart`、`soc_sysctrl`：64 位 AXI4-Lite 从口（保留精确字节地址 `s_araddr` / `s_awaddr`），经 `soc_axi_to_lite` 接入；
- 旁路信号：`soc_clint` 出 `mtip`、`msip`，入 `rtc_tick`；`soc_plic` 入 `irq_src[PLIC_NUM_SRC]`、出 `meip`、`seip`；`soc_uart` 出 `uart_txd`、入 `uart_rxd`、出 `irq_out`；`soc_sysctrl` 入 `boot_mode`、出 `sw_rst_req`、`core_ctl_out`。

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | ---: | --- |
| `soc_bootrom/soc_bootrom.sv` | 172 | 只读 BootROM（ZSBL）与 AXI4 突发读 |
| `soc_sram/soc_sram.sv` | 231 | 64 KiB 片上 SRAM（`ttg_sram_1rw`，`INIT_SWEEP = 0`）与 AXI4 突发读写 |
| `soc_clint/soc_clint.sv` | 168 | `mtime` / `mtimecmp` / `msip`，双地址映射 |
| `soc_plic/soc_plic.sv` | 227 | 优先级、挂起、使能、阈值、Claim / Complete |
| `soc_uart/soc_uart.sv` | 217 | NS16550A 寄存器与 16 字节收发 FIFO |
| `soc_uart/soc_uart_tx.sv` | 70 | 8N1 发送移位 |
| `soc_uart/soc_uart_rx.sv` | 117 | 8N1 接收（2 级同步 + 位中点采样） |
| `soc_sysctrl/soc_sysctrl.sv` | 165 | Chip ID、启动模式、软复位、暂存、计时 |

## 5. 一拍内的数据流

各外设是寄存器堆加简单状态机：AXI 请求在握手当拍译码地址，读数据下一拍返回；中断输出（`mtip`、`meip`、`seip`、UART 中断）由寄存器组合得出。细节见第 1 节各小节。

## 6. 关键路径与深度

| 模块 | Cells | 逻辑深度（层） |
| --- | ---: | ---: |
| `soc_bootrom` | 765 | 27 |
| `soc_sram`（含 `ttg_sram_1rw`） | 1,901 | 23 |
| `soc_clint` | 1,580 | 26 |
| `soc_plic` | 1,170 | 72 |
| `soc_uart` | 1,023 | 20 |
| `soc_sysctrl` | 1,345 | 11 |

## 7. 与模型的差异和取舍

取代的是 `tb/core` 测试台里的 C++ `PeripheralModel`，但只用在 `chip_top` / `tb/soc`；`soc_top` / `core_tb` 仍用 C++ 外设模型并与 trace-model 逐拍对齐。外设本身不与模型比周期。

## 8. 验证

- **门禁**：`bash scripts/soc_gate.sh`（`tb/soc/soc_tb`，`DDR_DATA_W = 64 / 128`）：`soc_smoke`（BootROM ABI、SysCtrl、SRAM 数据与取指执行、CLINT 双地址与 `mtip / msip`）、`soc_uart_fifo`（非 1 分频、外部 `uart_rxd`、16 字节 FIFO）、`soc_plic_ext`（外部 `ext_irq` 多源优先级、阈值、S 态 `seip`）、`soc_reset_boot`（`sw_rst_req` 软复位转 SRAM 启动）、`boot_mode = 10` 停驻；可选 `--linux`。
- **Lint**：svlint、`scripts/lint_soc.sh`、`scripts/lint_chip.sh`。

## 9. 参数与开关速查

`soc_bootrom` / `soc_sram` 的 `ID_W`；`soc_sram` 的 `WORDS`；`soc_pkg` 的地址与 `PLIC_NUM_SRC`。无开关。

## 10. 变更记录

- 2026-11-29 清理 D：去重：`soc_clint` 与 `soc_sysctrl` 各一份的 `apply_strb`（按字节写 64 位寄存器）合为 `soc_axi_pkg::axi4_apply_strb`，函数体不变（周期不变）。
- 2026-11-28 清理：`soc_pkg` 删无引用的 `NSLV_MMIO`、`IRQ_UART` 和与 `soc_axi_pkg::AXI4_RESP_*` 重复的 `AXI_RESP_*`（`soc_uart` / `soc_clint` / `soc_sysctrl` / `soc_plic` 改用 `soc_axi_pkg::AXI4_RESP_OKAY`），`soc_decode_slave` 改用 `ADDR_*` 常量的高位比较（同一组比较，结果不变）；删各外设 `unused_*` 汇点外不起作用的 `UNUSEDSIGNAL` 豁免（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`）：`soc_sram` 的 `ttg_sram_1rw` 设 `INIT_SWEEP = 0`（软件 RAM，复位不清零，73761fa）；文档按 TEMPLATE 十节重排。
- 2026-11-26（`5fa54e2`）：新增 v1 片上外设。
- 2026-11-29 清理：`soc_pkg` 删包级 `lint_off UNUSEDPARAM` 豁免（`scripts/lint.sh` 改为只编所需的包，包常量是否未用只在整芯片 lint 判定，见 `docs/01-rtl-coding-standard.md` 8.5；整芯片 lint 普通 / `-DSYNTHESIS` 下无死常量）（周期不变）。
