# 05 模块清单

> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 每个原子模块一份设计文档 `docs/modules/<模块>.md`，格式见 [modules/TEMPLATE.md](modules/TEMPLATE.md)，开发流程见总仓库 [docs/WORKFLOW.md](../../docs/WORKFLOW.md) 第 7 节（先写文档再改 RTL，提交前核对）。
> 文件数、行数是实测值；深度来自各文档头部的 `depth:`（单模块综合的结构深度，生成门代理，不是时序；`待测` = 还没量过）。待办见总仓库 [docs/TODO.md](../../docs/TODO.md)。

## 后端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [back_top](modules/back_top.md) | 3/2443 | 142 层 |
| [csr](modules/csr.md) | 10/742 | 29 层 |
| [dispatch](modules/dispatch.md) | 13/1542 | 56 层 |
| [exu_ctrl](modules/exu_ctrl.md) | 14/1652 | 17 层 |
| [exu_fu](modules/exu_fu.md) | 26/1782 | 73 层 |
| [idu](modules/idu.md) | 11/970 | 66 层 |
| [isu](modules/isu.md) | 14/2339 | 89 层 |
| [lsu](modules/lsu.md) | 33/4886 | 101 层 |
| [pre_idu_queue](modules/pre_idu_queue.md) | 8/742 | 38 层 |
| [prf](modules/prf.md) | 8/839 | 25 层 |
| [ren](modules/ren.md) | 18/1720 | 91 层 |
| [rob](modules/rob.md) | 6/1003 | 64 层 |
| [tlb_mmu](modules/tlb_mmu.md) | 7/759 | 61 层 |

## 前端

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [bpu](modules/bpu.md) | 16/3218 | 197 层 |
| [front_ctrl](modules/front_ctrl.md) | 1/59 | 5 层 |
| [front_fifos](modules/front_fifos.md) | 1/108 | 13 层 |
| [front_top](modules/front_top.md) | 3/740 | 216 层 |
| [icache](modules/icache.md) | 13/1786 | 114 层 |
| [predecode](modules/predecode.md) | 1/29 | 27 层 |

## 访存子系统

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [axi_cpu_port_adapter](modules/axi_cpu_port_adapter.md) | 2/150 | 9 层 |
| [axi_interconnect](modules/axi_interconnect.md) | 9/1245 | 53 层 |
| [axi_llc](modules/axi_llc.md) | 20/2606 | 350 层 |
| [axi_subsys](modules/axi_subsys.md) | 1/299 | 353 层 |
| [dcache](modules/dcache.md) | 18/3118 | 123 层 |
| [dcache_pf](modules/dcache_pf.md) | 1/169 | 384 层 |
| [mem_route](modules/mem_route.md) | 4/382 | 9 层 |
| [mem_top](modules/mem_top.md) | 3/689 | 待测 |
| [peripheral_axi](modules/peripheral_axi.md) | 3/239 | 10 层 |
| [ptw_walk](modules/ptw_walk.md) | 4/406 | 47 层 |

## 整核、PMU 与公共代码

| 模块 | RTL（文件/行） | 深度 |
| --- | --- | --- |
| [common](modules/common.md) | 7/434 | 待测 |
| [core_top](modules/core_top.md) | 4/1005 | 待测 |
| [pmu](modules/pmu.md) | 3/364 | 90 层 |
| [soc_top](modules/soc_top.md) | 1/153 | 待测 |

合计（各文档的目录有重叠时会重复计数）：286 个文件，38618 行。
