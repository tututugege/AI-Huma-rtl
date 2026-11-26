# 05 模块清单

> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 每个原子模块一份设计文档 `docs/modules/<模块>.md`，格式见 [modules/TEMPLATE.md](modules/TEMPLATE.md)，开发流程见总仓库 [docs/WORKFLOW.md](../../docs/WORKFLOW.md) 第 7 节（先写文档再改 RTL，提交前核对）。
> 文件数、行数是实测值；深度来自各文档头部的 `depth:`（单模块综合的结构深度，生成门代理，不是时序；`待测` = 还没量过）。待办见总仓库 [docs/TODO.md](../../docs/TODO.md)。

## 后端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [back_top](modules/back_top.md) | 4/1594 | 142 层 |
| [csr](modules/csr.md) | 10/742 | 29 层 |
| [dispatch](modules/dispatch.md) | 13/1325 | 57 层 |
| [exu_ctrl](modules/exu_ctrl.md) | 14/1534 | 17 层 |
| [exu_fu](modules/exu_fu.md) | 32/3612 | 98 层 |
| [ftq_ibuf](modules/ftq_ibuf.md) | 8/909 | 38 层 |
| [idu](modules/idu.md) | 4/510 | **19 层 / 6,595 cells** |
| [isu](modules/isu.md) | 14/2499 | **61 层 / 1,033,276 cells** |
| [lsu](modules/lsu.md) | 33/5216 | **TSMC 28nm HPC+ DC (`ssg0p81v125c`, `0.50ns`)：WNS `−0.39 ns` |
| [prf](modules/prf.md) | 8/790 | 25 层 |
| [ren](modules/ren.md) | 20/2334 | 91 层 |
| [rob](modules/rob.md) | 6/1051 | 65 层 |
| [tlb_mmu](modules/tlb_mmu.md) | 7/759 | 61 层 |

## 前端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [bpu](modules/bpu.md) | 18/4906 | 197 层 |
| [front_ctrl](modules/front_ctrl.md) | 1/59 | 5 层 |
| [front_fifos](modules/front_fifos.md) | 1/107 | 13 层 |
| [front_top](modules/front_top.md) | 3/755 | 216 层 |
| [icache](modules/icache.md) | 13/1843 | 114 层 |
| [predecode](modules/predecode.md) | 1/29 | 27 层 |

## 访存子系统

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [axi_cpu_port_adapter](modules/axi_cpu_port_adapter.md) | 2/150 | 9 层 |
| [axi_interconnect](modules/axi_interconnect.md) | 9/1256 | 53 层 |
| [axi_llc](modules/axi_llc.md) | 23/3520 | `axi_llc_bop` **75 层** |
| [axi_subsys](modules/axi_subsys.md) | 1/304 | 353 层 |
| [dcache](modules/dcache.md) | 18/3383 | `dcache_mshr` **99 层** |
| [dcache_pf](modules/dcache_pf.md) | 1/185 | 75 层 |
| [mem_route](modules/mem_route.md) | 4/382 | 9 层 |
| [mem_top](modules/mem_top.md) | 3/705 | 待测 |
| [peripheral_axi](modules/peripheral_axi.md) | 3/239 | 10 层 |
| [ptw_walk](modules/ptw_walk.md) | 5/786 | 44 层 |

## 整核、PMU 与公共代码

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [common](modules/common.md) | 9/586 | 待测 |
| [core_top](modules/core_top.md) | 4/1006 | 待测 |
| [pmu](modules/pmu.md) | 3/364 | 90 层 |
| [soc_top](modules/soc_top.md) | 1/153 | 待测 |

合计（各文档的目录有重叠时会重复计数）：296 个文件，43593 行。
