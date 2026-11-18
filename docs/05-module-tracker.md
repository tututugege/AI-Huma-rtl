# 05 模块清单

> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 每个原子模块一份设计文档 `docs/modules/<模块>.md`，格式见 [modules/TEMPLATE.md](modules/TEMPLATE.md)，开发流程见总仓库 [docs/WORKFLOW.md](../../docs/WORKFLOW.md) 第 7 节（先写文档再改 RTL，提交前核对）。
> 文件数、行数是实测值；深度来自各文档头部的 `depth:`（单模块综合的结构深度，生成门代理，不是时序；`待测` = 还没量过）。待办见总仓库 [docs/TODO.md](../../docs/TODO.md)。

## 后端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [back_top](modules/back_top.md) | 3/2420 | 待测 |
| [csr](modules/csr.md) | 10/742 | 29 层 |
| [dispatch](modules/dispatch.md) | 13/1514 | 56 层 |
| [exu_ctrl](modules/exu_ctrl.md) | 14/1689 | 17 层 |
| [exu_fu](modules/exu_fu.md) | 26/1782 | 73 层 |
| [idu](modules/idu.md) | 11/938 | 67 层 |
| [isu](modules/isu.md) | 14/1535 | 88 层 |
| [lsu](modules/lsu.md) | 33/4785 | 100 层 |
| [pre_idu_queue](modules/pre_idu_queue.md) | 8/734 | 39 层 |
| [prf](modules/prf.md) | 8/728 | 36 层 |
| [ren](modules/ren.md) | 18/1600 | 110 层 |
| [rob](modules/rob.md) | 6/998 | 62 层 |
| [tlb_mmu](modules/tlb_mmu.md) | 7/674 | 51 层 |

## 前端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [bpu](modules/bpu.md) | 31/3464 | 待测 |
| [front_ctrl](modules/front_ctrl.md) | 1/59 | 5 层 |
| [front_fifos](modules/front_fifos.md) | 1/108 | 13 层 |
| [front_top](modules/front_top.md) | 3/760 | 待测 |
| [icache](modules/icache.md) | 12/1116 | 69 层 |
| [predecode](modules/predecode.md) | 1/30 | 29 层 |

## 访存子系统

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [axi_cpu_port_adapter](modules/axi_cpu_port_adapter.md) | 2/149 | 9 层 |
| [axi_interconnect](modules/axi_interconnect.md) | 9/1227 | 37 层 |
| [axi_llc](modules/axi_llc.md) | 19/2286 | 238 层 |
| [axi_subsys](modules/axi_subsys.md) | 1/290 | 238 层 |
| [dcache](modules/dcache.md) | 15/2383 | 待测 |
| [dcache_pf](modules/dcache_pf.md) | 1/214 | 74 层 |
| [mem_route](modules/mem_route.md) | 4/366 | 9 层 |
| [mem_top](modules/mem_top.md) | 3/686 | 待测 |
| [peripheral_axi](modules/peripheral_axi.md) | 3/239 | 10 层 |
| [ptw_walk](modules/ptw_walk.md) | 4/406 | 47 层 |

## 整核、PMU 与公共代码

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [common](modules/common.md) | 6/303 | 待测 |
| [core_top](modules/core_top.md) | 4/1017 | 待测 |
| [pmu](modules/pmu.md) | 3/364 | 90 层 |
| [soc_top](modules/soc_top.md) | 1/147 | 待测 |

合计（各文档的目录有重叠时会重复计数）：295 个文件，35753 行。
