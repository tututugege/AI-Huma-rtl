---
module: soc_axi
area: soc
rtl: rtl/soc/soc_axi, rtl/soc/soc_xbar
model: 无（真实流片向 AXI4 片上互联，仅用于 chip_top；soc_top 保持原有 axi_subsys 逐拍对齐）
status: 全部模块 lint 0 警告；tb/axi_unit 5 项协议与随机压力测试全通过（0 checker 错误）；chip_top DDR_DATA_W=64/128 实测；eda-05 Yosys soc_xbar 100,853 cells / 75 层
depth: 75 层（100,853 cells，eda-05 Yosys `SYNTH_ABC="strash;balance;map"`，2026-11-26）
---

# soc_axi / soc_xbar 真实 AXI4 互联设计文档

## 1. 职责

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

## 2. 配置（`soc_xbar` / `soc_xbar_sys` 里的实例参数）

| 实例 | 参数 | 说明 |
| --- | --- | --- |
| Tier-1 `u_sys_xbar`（`soc_axi_xbar`） | `NM = 1`、`NS = 2`、`DATA_W = 256`、`MAX_RD = 16`、`MAX_WR = 4` | 系统互联：LLC → DDR / 片上 |
| `u_core_slice`、`u_ddr_slice`（`soc_axi_reg_slice`） | `DATA_W = 256` / `DDR_DATA_W` | LLC 出口、DDR 引脚的寄存器切片 |
| `u_ddr_down`（`soc_axi_downsizer`） | `S_DATA_W = 256`、`M_DATA_W = DDR_DATA_W`、`MAX_RD_OUT = 16`、`MAX_WR_OUT = 4` | 256 → 64 / 128 / 256 |
| `u_oc_down`（`soc_axi_downsizer`） | `S_DATA_W = 256`、`M_DATA_W = 64`、`MAX_RD_OUT = 8`、`MAX_WR_OUT = 4` | 进片上互联 |
| Tier-2 `u_oc_xbar`（`soc_axi_xbar`） | `NM = 2`、`NS = 3`、`DATA_W = 64`、`MAX_RD = 8`、`MAX_WR = 4` | MMIO + Tier-1 片上通路 → BootROM / SRAM / 外设桥 |
| `u_periph_bridge`（`soc_axi_to_lite`） | `NP = 4` | 四个 AXI4-Lite 外设 |
| id 位宽 | `DDR_ID_W = 7`（`chip_top` 参数），`OC_ID_W = DDR_ID_W + 1` | |

## 3. 接口

各模块都是标准 AXI4（AR / R / AW / W / B 五通道，ARM IHI 0022E）或 AXI4-Lite 端口，按参数化的 `DATA_W` / `ID_W` 展开；`soc_axi_xbar` 的主口另带地址译码结果 `m_ar_slv` / `m_aw_slv`（`SLV_W` 位，从口号或 DECERR）。芯片级引脚见 [chip_top.md](chip_top.md) 第 3 节。

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | ---: | --- |
| `rtl/soc/soc_axi/soc_axi_pkg.sv` | 89 | AXI4 常量（FIXED/INCR/WRAP、OKAY/SLVERR/DECERR、`NORM_NC_BUF` CACHE、PROT）、`axi4_next_addr` 地址生成、`axi4_merge_resp`、64 位寄存器按字节写 `axi4_apply_strb`（CLINT / SYSCTRL 共用）、位宽转换拆拍 `axi4_ds_sub_max` / `axi4_ds_m_len` / `axi4_ds_m_size`（两个 downsizer 共用，`m_off_w` 作参数） |
| `rtl/soc/soc_axi/soc_axi_skid.sv` | 82 | 全吞吐 2 项 skid buffer，同时打断前向 `VALID/DATA` 与后向 `READY` 组合路径 |
| `rtl/soc/soc_axi/soc_axi_reg_slice.sv` | 143 | 完整 5 通道（AR/R/AW/W/B）AXI4 寄存器切片，用于 Core LLC 出口与芯片外部 DDR 引脚边界 |
| `rtl/soc/soc_axi/soc_axi_downsizer_rd.sv` | 208 | 多在途（默认 16 项）读位宽转换器，支持跨 ID 乱序/交织 R 拍拼装、同 ID 严格 FIFO、窄访问与 `RLAST` 生成 |
| `rtl/soc/soc_axi/soc_axi_downsizer.sv` | 240 | 完整读写位宽转换器（`S_DATA_W -> M_DATA_W`：256→64 / 256→128 / 256→256 零开销直通）；写侧独立 AW-to-W FIFO 与 B skid |
| `rtl/soc/soc_axi/soc_axi_xbar_rd.sv` | 304 | 参数化 `NM x NS` Full-AXI4 读交叉开关 + 内置多拍 `DECERR` 从口；同从口多在途 + 跨从口 §A5.3 保序栅栏 + 授权锁定保稳 |
| `rtl/soc/soc_axi/soc_axi_xbar_wr.sv` | 396 | 参数化 `NM x NS` Full-AXI4 写交叉开关 + 内置多拍 `DECERR` 从口；独立 AW/W skid + 主/从 W 序 FIFO（支持 AW 先、W 先、同时到达，零死锁、零 W 交织） |
| `rtl/soc/soc_axi/soc_axi_xbar.sv` | 133 | 读写通道完全独立的 Full-AXI4 Crossbar 顶层 |
| `rtl/soc/soc_axi/soc_axi_to_lite.sv` | 313 | 64-bit Full-AXI4 → 4 从口 AXI4-Lite 协议转换桥，读写通道独立，自动拆解 FIXED/INCR/WRAP 多拍突发 |
| `rtl/soc/soc_axi/soc_axi_checker.sv` | 269 | ARM IHI 0022E 在线 SVA 协议检查器（`ifndef SYNTHESIS`），检查复位清零、5 通道 `VALID`/payload 保持、突发合法性/4KiB 边界、`RLAST`/`WLAST` 拍数与 ID 匹配 |
| `rtl/soc/soc_xbar/soc_xbar_sys.sv` | 343 | Tier-1 256-bit 系统互联封装 + LLC/DDR 边界检查器 |
| `rtl/soc/soc_xbar/soc_xbar.sv` | 361 | 双层 SoC 互联顶层 + MMIO/SRAM 边界检查器 |

## 5. 一拍内的数据流

各模块按 AXI 握手逐通道推进，没有跨通道的组合依赖（读写完全独立，AW / W 解耦）：寄存器切片和 skid 缓冲把 `VALID / DATA` 与 `READY` 两个方向都打断；交叉开关对同一从口允许多笔在途，跨从口按 §A5.3 保序（同 id 换从口时等前面的响应回来）；位宽转换器把一笔宽突发拆成多拍窄突发并在 R 侧拼回。

## 6. 关键路径与深度

`soc_xbar` 75 层 / 100,853 单元（eda-05 Yosys，`SYNTH_ABC="strash;balance;map"`，2026-11-26）。

## 7. 与模型的差异和取舍

模型里没有对应物：只用于 `chip_top`；`soc_top` / `core_tb` 的 DDR 侧仍是 `axi_subsys` 加测试台的 DDR 模型，与模型逐拍对齐（[axi_subsys.md](axi_subsys.md)）。

## 8. 验证

- **Lint**：`scripts/lint.sh rtl/soc/soc_axi rtl/soc/soc_xbar rtl/soc/soc_bootrom rtl/soc/soc_sram rtl/soc/chip_top rtl/memsys/mem_top rtl/memsys/axi_interconnect`、`scripts/lint_soc.sh`、`scripts/lint_chip.sh` 全部 0 警告/0 错误。
- **独立 AXI4 协议与随机压力测试**（[tb/axi_unit/build.sh](../../tb/axi_unit/build.sh)）：开启 `--assert` 与全边界 `soc_axi_checker`，实测 16 读在途乱序交织 R 拍、AW-before-W / W-before-AW / 同时到达、INCR/WRAP/FIXED 突发、LLC 256b→64b 读写 SRAM 与 DDR、BootROM `SLVERR`、未映射 `DECERR` 与 500 笔随机压力测试全部通过，0 协议错误。
- **整芯片验证**：`chip_top` 默认 `DDR_DATA_W=64`（每条 64B 缓存行对应真实 8 拍 AXI4 INCR 突发）及 `DDR_DATA_W=128`（4 拍突发）实测 `soc_smoke.bin` 与 OpenSBI/Linux 启动，0 `soc_axi_checker` 错误；`soc_top` 的 `fm_gate.sh` 77/77 PASS（周期对 `scripts/ref_cycles.txt`）。

## 9. 参数与开关速查

`chip_top` 参数 `DDR_DATA_W`（64 / 128 / 256）、`DDR_ID_W`；各模块参数见第 2 节；`soc_axi_checker` 只在 `ifndef SYNTHESIS` 下存在。

## 10. 变更记录

- 2026-11-29 清理 D：去重：`soc_axi_downsizer`（写侧）与 `soc_axi_downsizer_rd` 各有一份的 `calc_sub_max` / `calc_m_len` / `calc_m_size` 移入 `soc_axi_pkg`，改名 `axi4_ds_sub_max` / `axi4_ds_m_len` / `axi4_ds_m_size`，`M_OFF_W` 改为参数、`sub_max` 由调用处截到 `SUB_W`；`soc_clint` / `soc_sysctrl` 的 `apply_strb` 合为 `soc_axi_pkg::axi4_apply_strb`。函数体不变，新旧副本对拍（拆拍函数 4 组位宽全遍历、`apply_strb` 随机 100 万组）0 差（周期不变）。
- 2026-11-28 清理：删 `soc_axi_skid` / `soc_axi_reg_slice` 只取过 0 的 `BYPASS` 参数与 `g_bypass` 分支（skid 主体不再包在 `g_skid` 里）、`soc_axi_pkg` 无引用的 `AXI4_RESP_EXOKAY` / `AXI4_CACHE_DEV_NGNRNE` 与不起作用的 `UNUSEDSIGNAL` 豁免，以及 `soc_axi_*` / `soc_xbar*` 里 `unused_*` 汇点外不起作用的豁免（周期不变）。
- 2026-11-28（文档核对）：按 TEMPLATE 十节重排，文件表加行数，`soc_top` 门禁改为 77/77。
- 2026-11-26（`5fa54e2`）：新增 `soc_axi` / `soc_xbar`。同一轮对核边界的两处改动：

- `rtl/memsys/axi_interconnect/axi_ic_aw.sv`：`o_bready` 解除对 `d_bid` 的组合依赖（单写在途，改为仿真断言检查 `d_bid == w_q.id`），对 `soc_top` 零周期变化。
- `rtl/memsys/mem_top/mem_mmio_axi.sv`：升级为完整 64-bit Full-AXI4 Master（输出真实 `ARSIZE/AWSIZE`、`ARCACHE/AWCACHE = Device-nGnRnE`、`ARBURST/AWBURST = INCR`、`ARLOCK/AWLOCK`、`ARQOS/AWQOS`、`ARREGION/AWREGION`、`WLAST`），保留低 3 位字节地址。
- 2026-11-29 清理：`soc_axi_pkg` 删包级 `lint_off UNUSEDPARAM` 豁免（`scripts/lint.sh` 改为只编所需的包，包常量是否未用只在整芯片 lint 判定，见 `docs/01-rtl-coding-standard.md` 8.5；整芯片 lint 普通 / `-DSYNTHESIS` 下无死常量）（周期不变）。
