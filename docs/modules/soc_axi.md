---
module: soc_axi
area: soc
rtl: rtl/soc/soc_axi, rtl/soc/soc_xbar
model: 无（真实流片向 AXI4 片上互联，仅用于 chip_top；soc_top 保持原有 axi_subsys 逐拍对齐）
status: 全部模块 lint 0 警告；tb/axi_unit 5 项协议与随机压力测试全通过（0 checker 错误）；chip_top DDR_DATA_W=64/128 实测；eda-05 Yosys soc_xbar 100,853 cells / 75 层
depth: 75 层（100,853 cells，eda-05 Yosys `SYNTH_ABC="strash;balance;map"`，2026-11-26）
---

# soc_axi / soc_xbar 真实 AXI4 互联设计文档

## 1. 职责与拓扑

替换 v1 的简易地址分流器，提供符合 **ARM IHI 0022E（AMBA AXI4）** 规范的可综合双层片上互联、多在途位宽转换器、五通道寄存器切片、AXI4→AXI4-Lite 桥与在线协议检查器：

```
  Core LLC (256b) ──► soc_axi_reg_slice (256b, 时序隔离)
                           │
                           ▼
               [Tier-1 System AXI4 Crossbar]  (256b, 1M x 2S, 16 读在途)
                    ├── S0 (DDR, addr[31]==1) ──► soc_axi_downsizer (256b -> DDR_DATA_W)
                    │                                   └──► soc_axi_reg_slice ──► chip_top DDR 引脚
                    └── S1 (On-Chip, addr[31]==0) ──► soc_axi_downsizer (256b -> 64b)
                                                            │ (M1)
  Core LSU MMIO (64b Full-AXI4, Device-nGnRnE) ─────────────┼── (M0)
                                                            ▼
               [Tier-2 On-Chip AXI4 Crossbar] (64b, 2M x 3S + 内置 burst DECERR)
                    ├── S0: soc_bootrom (原生 64b Full-AXI4 burst 从口, 写回 SLVERR)
                    ├── S1: soc_sram    (原生 64b Full-AXI4 burst 1RW SRAM, 支持 LLC 读写与 ICache 取指)
                    └── S2: soc_axi_to_lite (Full-AXI4 -> 4x 64b AXI4-Lite 外设桥)
                                ├── P0: soc_clint   (0x1FD0_E000 & 0x0200_0000)
                                ├── P1: soc_plic    (0x0C00_0000)
                                ├── P2: soc_uart    (0x1000_0000)
                                └── P3: soc_sysctrl (0x1F00_0000)
```

## 2. 模块清单

| 文件 | 职责 |
| --- | --- |
| `rtl/soc/soc_axi/soc_axi_pkg.sv` | AXI4 常量（FIXED/INCR/WRAP、OKAY/SLVERR/DECERR、CACHE/PROT）、`axi4_next_addr` 地址生成、`axi4_merge_resp` |
| `rtl/soc/soc_axi/soc_axi_skid.sv` | 全吞吐 2 项 skid buffer，同时打断前向 `VALID/DATA` 与后向 `READY` 组合路径 |
| `rtl/soc/soc_axi/soc_axi_reg_slice.sv` | 完整 5 通道（AR/R/AW/W/B）AXI4 寄存器切片，用于 Core LLC 出口与芯片外部 DDR 引脚边界 |
| `rtl/soc/soc_axi/soc_axi_downsizer_rd.sv` | 多在途（默认 16 项）读位宽转换器，支持跨 ID 乱序/交织 R 拍拼装、同 ID 严格 FIFO、窄访问与 `RLAST` 生成 |
| `rtl/soc/soc_axi/soc_axi_downsizer.sv` | 完整读写位宽转换器（`S_DATA_W -> M_DATA_W`：256→64 / 256→128 / 256→256 零开销直通）；写侧独立 AW-to-W FIFO 与 B skid |
| `rtl/soc/soc_axi/soc_axi_xbar_rd.sv` | 参数化 `NM x NS` Full-AXI4 读交叉开关 + 内置多拍 `DECERR` 从口；同从口多在途 + 跨从口 §A5.3 保序栅栏 + 授权锁定保稳 |
| `rtl/soc/soc_axi/soc_axi_xbar_wr.sv` | 参数化 `NM x NS` Full-AXI4 写交叉开关 + 内置多拍 `DECERR` 从口；独立 AW/W skid + 主/从 W 序 FIFO（支持 AW 先、W 先、同时到达，零死锁、零 W 交织） |
| `rtl/soc/soc_axi/soc_axi_xbar.sv` | 读写通道完全独立的 Full-AXI4 Crossbar 顶层 |
| `rtl/soc/soc_axi/soc_axi_to_lite.sv` | 64-bit Full-AXI4 → 4 从口 AXI4-Lite 协议转换桥，读写通道独立，自动拆解 FIXED/INCR/WRAP 多拍突发 |
| `rtl/soc/soc_axi/soc_axi_checker.sv` | ARM IHI 0022E 在线 SVA 协议检查器（`ifndef SYNTHESIS`），检查复位清零、5 通道 `VALID`/payload 保持、突发合法性/4KiB 边界、`RLAST`/`WLAST` 拍数与 ID 匹配 |
| `rtl/soc/soc_xbar/soc_xbar_sys.sv` | Tier-1 256-bit 系统互联封装 + LLC/DDR 边界检查器 |
| `rtl/soc/soc_xbar/soc_xbar.sv` | 双层 SoC 互联顶层 + MMIO/SRAM 边界检查器 |

## 3. 核边界改进

- `rtl/memsys/axi_interconnect/axi_ic_aw.sv`：`o_bready` 解除对 `d_bid` 的组合依赖（单写在途，改为仿真断言检查 `d_bid == w_q.id`），对 `soc_top` 零周期变化。
- `rtl/memsys/mem_top/mem_mmio_axi.sv`：升级为完整 64-bit Full-AXI4 Master（输出真实 `ARSIZE/AWSIZE`、`ARCACHE/AWCACHE = Device-nGnRnE`、`ARBURST/AWBURST = INCR`、`ARLOCK/AWLOCK`、`ARQOS/AWQOS`、`ARREGION/AWREGION`、`WLAST`），保留低 3 位字节地址。

## 4. 验证

- **Lint**：`scripts/lint.sh rtl/soc/soc_axi rtl/soc/soc_xbar rtl/soc/soc_bootrom rtl/soc/soc_sram rtl/soc/chip_top rtl/memsys/mem_top rtl/memsys/axi_interconnect`、`scripts/lint_soc.sh`、`scripts/lint_chip.sh` 全部 0 警告/0 错误。
- **独立 AXI4 协议与随机压力测试**（[tb/axi_unit/build.sh](../../tb/axi_unit/build.sh)）：开启 `--assert` 与全边界 `soc_axi_checker`，实测 16 读在途乱序交织 R 拍、AW-before-W / W-before-AW / 同时到达、INCR/WRAP/FIXED 突发、LLC 256b→64b 读写 SRAM 与 DDR、BootROM `SLVERR`、未映射 `DECERR` 与 500 笔随机压力测试全部通过，0 协议错误。
- **整芯片验证**：`chip_top` 默认 `DDR_DATA_W=64`（每条 64B 缓存行对应真实 8 拍 AXI4 INCR 突发）及 `DDR_DATA_W=128`（4 拍突发）实测 `soc_smoke.bin` 与 OpenSBI/Linux 启动，0 `soc_axi_checker` 错误；`soc_top` 跑满 `fm_gate.sh` 69/69 PASS、0 周期差异。
