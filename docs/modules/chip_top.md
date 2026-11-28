---
module: chip_top
area: soc
rtl: rtl/soc/chip_top/chip_top.sv, rtl/soc/soc_pkg/soc_pkg.sv, rtl/soc/soc_crg/, rtl/soc/soc_axi/, rtl/soc/soc_xbar/
model: 无直接对应的 C++ 单模块（真实流片向 SoC 顶层外壳；核内子系统仍与 trace-model 逐拍对齐，由 soc_top + tb/core/core_tb 守护）
status: 真实双层 Full-AXI4 互联与流片向 SoC 闭环已建立（支持 DDR_DATA_W=64/128/256 + 在线 ARM IHI 0022E AXI4 协议检查 + soc_gate.sh 一键门禁）
depth: soc_xbar 75 层（100,853 cells）；全部片上外设 ≤72 层（eda-05 Yosys 2026-11-26）
---

# chip_top 设计文档（SoC + Real AXI4）

## 1. 职责

面向未来流片与 FPGA 原型的真实芯片顶层。将 `core_top` 与 `mem_top #(.EXT_MMIO_EN(1'b1))` 封装为核子系统，并在外层接入全套真实可综合片上基础设施：
- **时钟/复位管理（`soc_crg`）**：2-FF 异步复位同步释放（`soc_rst_sync`），支持 `por_rst_n`、`ext_ndmreset`（为 v2 JTAG Debug Module 预留）、`sw_rst_req` 复位合并及 DFT `dft_test_mode`/`dft_scan_en` 旁路钩子；同步释放后再经 `ttg_rst_sweep` 保持 `SRAM_SWEEP_CYCLES`（4100）拍，让所有 SRAM 包装在复位里把阵列清成初值（`common.md` 4.1 节；软复位同样重新清零，`soc_sram` 不清；DFT 测试模式旁路展宽）；将慢速异步 `clk_rtc` 边沿经 3-FF CDC（`soc_cdc_pulse`）转为 `clk_core` 域单拍 `rtc_tick`。
- **真实双层 Full-AXI4 互连（`soc_axi` + `soc_xbar`，详见 [soc_axi.md](soc_axi.md)）**：
  - **Tier-1（256-bit System AXI4 Crossbar）**：核 LLC 出口经 5 通道寄存器切片（`soc_axi_reg_slice`）隔离时序后进入 1M×2S 交叉开关（支持 16 读在途）。`S0`（DDR）经可参数化多在途位宽转换器（`soc_axi_downsizer`，256b → `DDR_DATA_W` = 64/128/256b）与输出 `soc_axi_reg_slice` 直出芯片引脚；`S1`（片上空间）经 256b→64b `soc_axi_downsizer` 进入 Tier-2（支持 LLC 对片上 SRAM/BootROM 的读写突发）。
  - **Tier-2（64-bit On-Chip AXI4 Crossbar）**：2M（M0 = 核独立 64b Full-AXI4 MMIO，彻底绕开 LLC；M1 = Tier-1 片上通路）× 3S（原生 Full-AXI4 突发 `soc_bootrom`、原生 Full-AXI4 突发 64 KiB `soc_sram`、`soc_axi_to_lite` 外设桥）+ 内置多拍突发 `DECERR` 从口。
  - 读写通道完全独立、AW/W 通道完全解耦（零死锁）、内置 ARM IHI 0022E 在线协议检查器（`soc_axi_checker`，仿真使能）。
- **真实片上外设**（详见 [soc_periph.md](soc_periph.md)）：`soc_bootrom`、`soc_sram`、`soc_clint`、`soc_plic`、`soc_uart`、`soc_sysctrl`。

原 `soc_top` 与 `tb/core`（`core_tb`）保持 100% 端口与行为不变，用于守护三仓逐拍周期对齐（`fm_gate` / SPEC06 / Linux 26 窗）。`chip_top` 使用 `tb/soc`（`soc_tb`），不向芯片引脚暴露任何仿真作弊端口（无 `env_*`、无 `interrupt_inject_*`、无 `rob_commit_*`）。**双测试台分工约定**：`core_tb`（`soc_top`）专职核+Cache 微架构研发与三仓逐拍锁步；`soc_tb`（`chip_top`）专职流片向全片 SoC 集成、ARM IHI 0022E AXI4 协议合规与真实片上外设验证，不将片上 `soc_xbar`/外设回灌到 `core_tb` 或 `trace-model`。

## 2. 配置与地址映射（`soc_pkg`、`chip_top` 参数）

| Slave ID | 地址范围 | 容量 | 模块 | 接口类型 | 说明 |
|---|---|---|---|---|---|
| `SLV_BOOTROM` (1) | `0x0000_0000 .. 0x0000_0FFF` | 4 KiB | `soc_bootrom` | 64b Full-AXI4 | 只读 RV64 ZSBL，支持 FIXED/INCR/WRAP 突发，写回 `SLVERR` |
| `SLV_CLINT` (2) | `0x0200_0000 .. 0x0200_FFFF` 及 `0x1FD0_E000 .. 0x1FD0_EFFF` | 64 KiB / 4 KiB | `soc_clint` | 64b AXI4-Lite | 双地址映射，兼容标准 SiFive CLINT 与 `ttg64gc.dts` |
| `SLV_PLIC` (3) | `0x0C00_0000 .. 0x0FFF_FFFF` | 64 MiB | `soc_plic` | 64b AXI4-Lite | 标准 RISC-V PLIC（`PLIC_NUM_SRC=8`，Context 0=M / 1=S） |
| `SLV_UART` (4) | `0x1000_0000 .. 0x1000_0FFF` | 4 KiB | `soc_uart` | 64b AXI4-Lite | 真可综合 NS16550A（16B TX/RX FIFO、真串口移位、PLIC IRQ 1） |
| `SLV_SYSCTRL` (5) | `0x1F00_0000 .. 0x1F00_0FFF` | 4 KiB | `soc_sysctrl` | 64b AXI4-Lite | Chip ID `"HUMA"`、版本、`boot_mode`、软复位、scratchpad、uptime |
| `SLV_SRAM` (6) | `0x3000_0000 .. 0x3000_FFFF` | 64 KiB | `soc_sram` | 64b Full-AXI4 | 片上 1RW SRAM（8192×64b），支持读写突发与 1 拍/字流式传输 |
| `SLV_DDR` (0) | `0x8000_0000 .. 0xFFFF_FFFF` | 2 GiB | 外部 DDR 口 | Full-AXI4 (`DDR_DATA_W`) | 默认 64-bit（每 64B 缓存行 = 8 拍 INCR 突发），可选 128/256-bit |
| `SLV_ERR` (7) | 其余未映射空间 | — | `soc_axi_xbar` | Full-AXI4 DECERR | 完整吞吐多拍突发并返回 `DECERR (2'b11)` + 匹配 ID/`RLAST` |

## 3. 接口（芯片引脚级）

| 方向 | 信号组 | 含义 |
|---|---|---|
| 入 | `clk_core`、`clk_rtc`、`por_rst_n`、`dft_test_mode`、`dft_scan_en` | 核主时钟、慢速 RTC 参考时钟、上电复位、DFT 旁路 |
| 入 | `boot_mode [1:0]` | 启动模式引脚：`00` DDR 直启、`01` 片上 SRAM 启动、`1x` 安全等待 |
| 入/出 | `uart_rxd`、`uart_txd` | 真 8N1 异步串行口 |
| 入 | `ext_irq [PLIC_NUM_SRC-2:0]` | 外部中断引脚（接入 PLIC IRQ 2..8；IRQ 1 为片上 UART） |
| 入/出 | `ddr_ar*`、`ddr_r*`、`ddr_aw*`、`ddr_w*`、`ddr_b*` | 完整 ARM IHI 0022E AXI4 外部主存主口（默认 64-bit 数据宽度，含 `id/len/size/burst/lock/cache/prot/qos/region/rlast/rresp/wlast/bresp`，输出经 5 通道寄存器切片隔离） |

## 4. 结构

```
 por_rst_n / sw_rst_req / ext_ndmreset(恒 0) ─► soc_crg ─► sys_rst_n（同步释放 + ttg_rst_sweep 展宽）、rtc_tick
 core_top (u_core) ◄─ .* ─► mem_top #(.EXT_MMIO_EN(1)) (u_mem) ─ LLC 256b / MMIO 64b ─► soc_xbar (u_xbar, 见 soc_axi.md)
                                                                    ├─► DDR 引脚（DDR_DATA_W）
                                                                    └─► soc_bootrom / soc_sram / soc_clint / soc_plic / soc_uart / soc_sysctrl（见 soc_periph.md）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `soc/chip_top/chip_top.sv` | 317 | 芯片顶层：`soc_crg`、`core_top`、`mem_top`、`soc_xbar` 与六个外设的例化和连线；`OC_ID_W = DDR_ID_W + 1` |
| `soc/soc_pkg/soc_pkg.sv` | 53 | 从口编号 `SLV_*`、地址 `ADDR_*`、`PLIC_NUM_SRC = 8`、`IRQ_UART = 1`、AXI 响应码 |
| `soc/soc_crg/soc_crg.sv` | 45 | 复位合并（`por_rst_n & ~ext_ndmreset & ~sw_rst_req`，DFT 测试模式只看 `por_rst_n`）、同步释放、`ttg_rst_sweep` 展宽、RTC 脉冲 |
| `soc/soc_crg/soc_rst_sync.sv` | 22 | 2 级触发器的异步置位、同步释放 |
| `soc/soc_crg/soc_cdc_pulse.sv` | 23 | `clk_rtc` 上升沿同步成 `clk_core` 的一拍脉冲 |

`soc_axi` / `soc_xbar` 见 [soc_axi.md](soc_axi.md)，外设见 [soc_periph.md](soc_periph.md)。

## 5. 一拍内的数据流

`chip_top` 自己没有逻辑，只有连线。复位链：`raw_sys_rst_n` → `soc_rst_sync`（2 拍同步释放）→ `ttg_rst_sweep`（再保持 `SRAM_SWEEP_CYCLES` = 4100 拍，SRAM 在复位里清零，见 [common.md](common.md) 4.1 节；DFT 测试模式下旁路展宽）→ `sys_rst_n`。软复位（`soc_sysctrl` 的 `sw_rst_req`）同样走这条链，所以也会重新清零（`soc_sram` 设 `INIT_SWEEP = 0`，内容保留）。

## 6. 关键路径与深度

`soc_xbar` 75 层（100,853 单元）；片上外设都 ≤ 72 层（见 [soc_periph.md](soc_periph.md) 第 7 节）。eda-05 Yosys，`SYNTH_ABC="strash;balance;map"`，2026-11-26。`chip_top` 整体没有单独综合。

## 7. 与模型的差异和取舍

模型里没有对应物：trace-model 的外设是 C++ `PeripheralModel`，与 RTL 的逐拍对齐由 `soc_top` + `tb/core/core_tb` 守护（[soc_top.md](soc_top.md)）。`chip_top` 只在 `tb/soc/soc_tb` 里跑定向测试和 Linux，不与模型比周期。`ext_ndmreset` 端口在 `chip_top` 里接常 0（为将来的 JTAG Debug Module 预留）。

## 8. 验证

- **一键回归门禁**：`bash scripts/soc_gate.sh`（可选 `--linux` 加跑 `linux_j.bin`）。
- **Lint**：`scripts/lint.sh`、`scripts/lint_soc.sh`、`scripts/lint_chip.sh` 全部 0 警告/0 错误。
- **AXI4 协议与压力单测**：`tb/axi_unit/build.sh`（开启 `--assert`）5 项测试全 PASS，0 `soc_axi_checker` 错误。
- **芯片级仿真（`tb/soc/soc_tb`）**：默认 `DDR_DATA_W=64` 与 `DDR_DATA_W=128`（均开启 `--assert`）实测全套定向测试（`soc_smoke`、`soc_uart_fifo` 外部 `uart_rxd` 与非 1 分频/16B FIFO 突发、`soc_plic_ext` 外部 `ext_irq` 多源优先级仲裁与 S-mode `seip`、`soc_reset_boot` `sw_rst_req` 软复位切 `boot_mode=01` SRAM 启动、`boot_mode=10` park）及真实 `linux_j.bin`（OpenSBI v1.2 → `Linux version`）。
- **回归保护**：原 `soc_top` + `tb/core/core_tb` `scripts/fm_gate.sh` 77/77 PASS，0 周期差异。

## 9. 参数与开关速查

- `chip_top` 参数：`PF_EN`（默认 `1'b1`）、`DDR_DATA_W`（默认 `64`，可选 `64`/`128`/`256`）、`DDR_ID_W`（默认 `7`）。
- `tb/soc/build.sh` 参数：`DDR_DATA_W=64|128|256`、`SOC_VOPT="--threads 8"`、`SOC_OUT=<dir>`。
- `soc_tb` 参数：`--boot-mode`、`--max-cycles`、`--rtc-div`、`--uart-div`、`--stop-str`、`--fail-str`、`--uart-rx`、`--uart-rx-on-str`、`--ext-irq-on-str`、`--boot-mode-on-str`、`--expect-silent`。

## 10. 变更记录

- 2026-11-28（`rtl/fe-2ahead`）：`soc_crg` 在同步释放后经 `ttg_rst_sweep` 展宽 `SRAM_SWEEP_CYCLES` 拍（SRAM 复位清零，DFT 测试模式旁路）；文档按 TEMPLATE 十节重排（新增结构、数据流、深度、与模型的差异、变更记录）。
- 2026-11-26：新增 `chip_top`（双层 Full-AXI4 互联、可综合外设、`tb/soc/soc_tb`、`scripts/soc_gate.sh`，`5fa54e2`）。
