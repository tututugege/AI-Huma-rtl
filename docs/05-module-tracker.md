# 05 模块清单

> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 每个原子模块一份设计文档 `docs/modules/<模块>.md`，格式见 [modules/TEMPLATE.md](modules/TEMPLATE.md)，开发流程见总仓库 [docs/WORKFLOW.md](../../docs/WORKFLOW.md) 第 7 节（先写文档再改 RTL，提交前核对）。
> 文件数、行数是实测值；深度来自各文档头部的 `depth:`（单模块综合的结构深度，生成门代理，不是时序；`待测` = 还没量过）。待办见总仓库 [docs/TODO.md](../../docs/TODO.md)。

## 后端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [back_top](modules/back_top.md) | 5/1429 | 142 层 |
| [csr](modules/csr.md) | 10/738 | 29 层 |
| [dispatch](modules/dispatch.md) | 12/1267 | 57 层 |
| [exu_ctrl](modules/exu_ctrl.md) | 12/1303 | 17 层 |
| [exu_fu](modules/exu_fu.md) | 25/3230 | 98 层 |
| [ftq_ibuf](modules/ftq_ibuf.md) | 8/1047 | TSMC 28nm DC |
| [idu](modules/idu.md) | 4/517 | **19 层 / 6,595 cells** |
| [isu](modules/isu.md) | 14/2758 | **61 层 / 1,033,276 cells** |
| [lsu](modules/lsu.md) | 29/4879 | TSMC 28nm HPC+ DC (`ssg0p81v125c`, `0.50ns`)：单模块 `lsu` WNS `−0.39 ns` |
| [prf](modules/prf.md) | 7/681 | 25 层 |
| [ren](modules/ren.md) | 19/2141 | 91 层 |
| [rob](modules/rob.md) | 6/1004 | 65 层 |
| [tlb_mmu](modules/tlb_mmu.md) | 7/841 | TSMC 28nm HPC+ DC `tlb_mmu_bb` WNS `−0.03 ns` |

## 前端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [bpu](modules/bpu.md) | 19/3624 | Tier 1 TSMC28 LVT + PrimeTime STA：`bpu` `WNS -1.75 ns` |
| [front_ctrl](modules/front_ctrl.md) | 1/53 | 5 层 |
| [front_fifos](modules/front_fifos.md) | 1/76 | 13 层 |
| [front_top](modules/front_top.md) | 3/564 | Tier 1 |
| [icache](modules/icache.md) | 13/1694 | Tier 1 TSMC 28nm (Yosys+PrimeTime STA, clk=0.65ns, eda-07): icache 77 层 / Total 490,495.9 / WNS -1.24ns (Fmax_T1 0.529 GHz, pt_timing_reg2reg -1.18ns / 0.546 GHz)；front_top 64 层 / Total 2,682,267.5 / WNS -1.82ns (Fmax_T1 0.405 GHz，瓶颈已移出 u_icache) |
| [predecode](modules/predecode.md) | 1/302 | 27 层 |

## 访存子系统

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [axi_cpu_port_adapter](modules/axi_cpu_port_adapter.md) | 2/150 | 9 层 |
| [axi_interconnect](modules/axi_interconnect.md) | 9/1264 | 53 层 |
| [axi_llc](modules/axi_llc.md) | 24/3534 | `axi_llc_bop` **75 层** |
| [axi_subsys](modules/axi_subsys.md) | 1/304 | 353 层 |
| [dcache](modules/dcache.md) | 18/3314 | `dcache_mshr` **99 层** |
| [dcache_pf](modules/dcache_pf.md) | 1/185 | 75 层 |
| [mem_route](modules/mem_route.md) | 4/382 | 9 层 |
| [mem_top](modules/mem_top.md) | 5/1126 | 待测 |
| [peripheral_axi](modules/peripheral_axi.md) | 3/239 | 10 层 |
| [ptw_walk](modules/ptw_walk.md) | 5/772 | 44 层 |

## 整核、PMU 与公共代码

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [common](modules/common.md) | 12/1031 | 待测 |
| [core_top](modules/core_top.md) | 4/857 | 待测 |
| [pmu](modules/pmu.md) | 3/364 | 90 层 |
| [soc_top](modules/soc_top.md) | 1/191 | 仅顶层连线 |

## 全片 SoC 与 AXI4 互联

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [chip_top](modules/chip_top.md) | 17/3331 | soc_xbar 75 层 |
| [soc_axi](modules/soc_axi.md) | 12/2881 | 75 层 |
| [soc_periph](modules/soc_periph.md) | 8/1367 | bootrom 27 / sram 23 / clint 26 / plic 72 / uart 20 / sysctrl 11 层 |

合计（各文档的目录有重叠时会重复计数）：325 个文件，49440 行。
