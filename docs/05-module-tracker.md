# 05 模块清单与进度

> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 改对应的 `docs/modules/<模块>.md` 的头部（front-matter），再重新生成。
> RTL 行数、文件数、spec 数/字段数是脚本实测值；状态、锁步、变异是模块笔记里人工填写并经协调者复核的值。
> 状态：`green` = lint 干净 + 整程序锁步全部通过 + 变异被抓到（存活者已判定）+ 独立复核；`partial` = 有已知缺口，见备注。
> 待办见总仓库 [docs/TODO.md](../../docs/TODO.md)。参考模型提交：`2f31e8d`。

## 后端

| 模块 | 状态 | RTL（文件/行） | spec（个/字段） | 整程序锁步 | 变异 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| [back_top](modules/back_top.md) | green | 3/2020 | 1/96 | 68/68（整程序） | 集成层 11/18 杀死，7 待判定 | 后端整体，含 lsu |
| [csr](modules/csr.md) | green | 10/665 | 2/38 | 68/68 | 15/15（6 仅随机） |  |
| [dispatch](modules/dispatch.md) | green | 13/1265 | 1/105 | trace 回放 + back_top 整程序 68/68 | 16/17（1 等价） |  |
| [exu_ctrl](modules/exu_ctrl.md) | green | 13/1373 | 1/157 | trace 回放 + back_top 整程序 68/68 | 11/11（2 仅随机） |  |
| [exu_int](modules/exu_int.md) | green | 24/1348 | 7/88 | trace 回放 + back_top 整程序 68/68 | 47/47（11 仅随机） | 整数 FU |
| [fpu](modules/fpu.md) | green | 22/1179 | 1/21 | trace 回放 + back_top 整程序 68/68 + softfloat 差分 | 33/35（2 等价） | 手写，非网表 |
| [idu](modules/idu.md) | green | 11/812 | 1/46 | 68/68 | 9/9 |  |
| [isu](modules/isu.md) | green | 10/948 | 1/60 | trace 回放 + back_top 整程序 68/68 | 16/17（1 等价） | trace 需重录 |
| [lsu](modules/lsu.md) | partial | 33/3260 | 1/111 | lsu 68/68；随机 12/12；back_top 冒烟 8/8（整程序 68 未重跑） | 重构后新 127 个变异体已建好（tests/lsu/mut_lsu.py），仅跑了前 14 个（10 杀死、4 筛选集存活待判），其余未跑；原 10 个存活变异体仍未结案 | 已手写重构（表项模块 + 队列操作链，无生成文件）；变异检查被协调者叫停 |
| [pre_idu_queue](modules/pre_idu_queue.md) | green | 7/583 | 1/48 | 68/68 | 18/18（5 仅随机） | 含 FTQ 与指令缓冲；3 个冗余限定输出待删 |
| [prf](modules/prf.md) | green | 7/498 | 1/71 | 68/68 (整程序) | 10/10（6 仅随机） | Prf 寄存器堆+旁路+唤醒 |
| [ren](modules/ren.md) | green | 12/967 | 1/66 | 68/68 | 12/12（5 仅随机） | 需重录 trace（src1_areg 输出） |
| [rob](modules/rob.md) | green | 12/1110 | 1/88 | trace 回放 + back_top 整程序 68/68 | 10/11（1 等价） |  |
| [tlb_mmu](modules/tlb_mmu.md) | green | 7/639 | 1/41 | 68/68 (DTLB+ITLB) | 34/34（20 仅随机） | ITLB 经 icache 验证 |

## 前端

| 模块 | 状态 | RTL（文件/行） | spec（个/字段） | 整程序锁步 | 变异 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| [bpu](modules/bpu.md) | green | 22/2026 | 6/90 | 68/68，独立复核 408/408 | 38/38（13 仅随机） | TAGE/BTB/历史/RAS/更新队列 |
| [front_basic](modules/front_basic.md) | green | 13/768 | 8/119 | 68/68 | 34/34（10 仅生成 trace） | 预译码、4 个 FIFO、front_ctrl |
| [front_top](modules/front_top.md) | green | 7/1402 | 2/159 | 68/68（front_top、core_top） | 30 个中 24 杀死，3 等价，3 覆盖缺口 | 前端顶层 + 前后端联调 core_top |
| [icache](modules/icache.md) | green | 12/1075 | 4/135 | 68/68×4 spec | 33 个中 28 杀死，5 等价 | 含 ITLB |

## 访存子系统

| 模块 | 状态 | RTL（文件/行） | spec（个/字段） | 整程序锁步 | 变异 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| [axi_cpu_port_adapter](modules/axi_cpu_port_adapter.md) | green | 2/149 | 1/14 | 68/68（16 tick） | 20/20 |  |
| [dcache](modules/dcache.md) | green | 14/1835 | 1/34 | 68/68（16 tick 锁步） | 37 个中 33 杀死，4 等价 | DCache+MSHR+WB+响应锁存 |
| [mem_route](modules/mem_route.md) | green | 4/341 | 1/51 | 68/68（16 tick） | 31 个中 28 杀死，3 等价 |  |
| [peripheral_axi](modules/peripheral_axi.md) | green | 3/247 | 1/33 | 68/68 | 26 个中 24 杀死，2 等价 | 真实程序几乎不走该路径 |
| [ptw_walk](modules/ptw_walk.md) | green | 4/389 | 1/21 | 68/68 | 29 个中 28 杀死，1 等价 | 只翻默认配置下活着的部分 |

## 整核（前后端 + 访存）

| 模块 | 状态 | RTL（文件/行） | spec（个/字段） | 整程序锁步 | 变异 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| [soc_top](modules/soc_top.md) | green | 3/755 | 1/96 | 闭环（RTL 整核）周期数与参考一致：65 个程序（≤23 万周期）全部相等 | 未跑 | core_top + mem_top；测试平台 tb/soc（Verilator）+ 参考的 SimDDR/PhysMemory/PeripheralModel |

合计：268 个 RTL 文件，25654 行（不含 `rtl/common` 与 `ttg_cfg_pkg`）。
