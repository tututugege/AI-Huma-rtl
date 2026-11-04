# 07 路线图与未完成事项

> 模块级进度见 [05-module-tracker.md](05-module-tracker.md)（自动生成）。本文件是**人工维护**的待办清单：每条写清"为什么、做到什么算完"，做完删除并在 git 历史里留痕。

## 里程碑

| 里程碑 | 状态 | 验收 |
| --- | --- | --- |
| M1 后端整体 `back_top`（含 LSU）整程序锁步 | 完成 | 68 个程序逐拍一致 |
| M2 前端各块 + `front_top` + 前后端联调 `core_top` | 完成 | 68 个程序逐拍一致（边界为存储侧口、退休流） |
| M3 访存 CPU 域 + DCache 域（16 倍频） | 完成 | 各模块 68 个程序 16 tick 锁步一致 |
| M4 AXI 互连 + LLC | 完成 | 同上 |
| M5 整核闭环：RTL 核 + RTL 访存 + testbench（DDR/MMIO）对照参考模型周期数 | 基本完成 | 65 个程序周期数逐一相等；`memory-stress`（154 万周期）等 3 个未跑，见 modules/soc_top.md |
| M6 质量：断言、覆盖率、定向/随机测试、清理 | 未开始 | 见下 |

## M4/M5 的已知事项

- 三份录制补丁（memsys / memcpu / axi）改同一批参考模型文件，按 memsys → memcpu → axi 顺序合入共享 `refsim_tap`；`scripts/refsim_setup.sh` 需要把它们并入。
- 16 tick 锁步壳目前有三份：`scripts/lockstep_ticks.sh`（dcache）、`tb/memcpu/axi_shell.cpp`（memcpu）、axi 自带；合并为一份通用的。
- core_top 接访存子系统后做整核锁步（边界改为 testbench 一侧的 DDR/MMIO 口）。

## M6 质量待办

1. **断言**：目前 RTL 里几乎没有 assert。规范：clocked `assert property`，包在 `ifndef SYNTHESIS`；每个设计笔记 §4 里的"不复刻/不可达/假设"都要有对应断言；锁步构建默认带 `--assert`，并抓取 `%Error`（断言触发后进程会提前 `$stop`，插件仍打印 PASS，需另外检查）。
2. **覆盖率**：Verilator toggle coverage（line 覆盖对 assign 风格 RTL 无意义），每模块出报告，入库的是汇总数字。
3. **大量短测试**：定向短程序（每个只覆盖一个事件，秒级）+ 受约束的随机指令生成器；先补当前已知缺口：
   - back_top 集成层存活变异体 7 个（`glue_mxr_sum_swap`、`exu_flush_mask_mul`、`exu_mul_func3`、`const_src1_busy`、`const_dis2rob_mispred`、`swap_06_ren2dis_uop_src1_busy`、`swap_09_rob_commit_commit_entry_uop_amo_op`）：逐个判定等价或补测试。
   - front_top 3 个覆盖缺口：RET 判定 `imm≠0`、SFENCE.VMA 后取指、冲刷拍与存储侧请求同拍。
   - peripheral AXI 路径、PTW 超级页与各类 PTE 故障、MSHR_HIT/FULL 路由响应：真实程序基本不走。
4. **去复位的存储器用随机初值验证**：锁步用 `--x-initial 0`，去掉复位的阵列在仿真里看不出来；需要 `--x-initial unique` + 运行时随机复位参数。
5. **RealLsu 手写重构**：3 个脚本生成的 SSA 展开文件（约 890 行）改手写结构，状态数组不散开；顺带补足 25 个变异里存活的 10 个（M05 M07 M08 M15 M16 M17 M18 M20 M21 M24）。
6. **整数组次态残留**：`isu_iq_store`、`rob_store`、`dispatch`、`idu` 里是否还有整数组次态写法，未核实（grep 不完整）。
7. ~~**清理 tma 边带**~~（已完成 2026-11-04；同时删除后端集成里 7 个被常量绑死的字段：Rob 的 dis2rob mispred/br_taken/flush_pipe、exu2rob page_fault_inst/flush_pipe，Dispatch 的 ren2dis src1/src2_busy，以及不含 LSU 的 `back_top_nolsu`）：从 Idu/Ren/Dispatch/Rob 与 back_top 删除 `tma_mem_commit_is_load/store`（只服务模拟器记账，见 06 §8）。
8. **PMU 单独设计**：需要先确定事件列表（待用户选择），硬件友好的计数，独立于逐拍对照（06 §8）。
9. 小项：PreIduQueue 删 3 个冗余限定输出并重录；Ren/Isu trace 重录；`make cfg` 导出 `GLOBAL_IQ_CONFIG`、端口能力表、MUL/DIV 实例数、前端常量；`mutcheck.sh` 区分"无法构建"与"存活"；端口样板由 spec 生成；`front_stall` 在 core_top 里写死为 0（BPU 更新队列会满时必须接回）。

## 已知的开放疑点

见 [deviations.md](deviations.md)（S-1…）和各模块笔记 §4。

## 验证提速策略（2026-11-04 起生效）
锁步和变异检查太慢是最大的效率问题。约定：
- **日常门禁只跑"冒烟集"**：8 个短程序 × ≤5 万拍、1 路并行（改完 RTL 先过这个）。
- **全量 68 程序锁步、变异检查只在里程碑、机器空闲时跑**（夜间/无其他重任务），由协调者统一触发，agent 不自行跑全量。
- **变异检查不是门禁**（用户决定，2026-11-04）：默认不跑，笔记里记"未跑"；需要时由协调者在机器空闲时批量跑。已有的存活变异体清单（back_top 7 个、front_top 3 个、LLC 4 个、互连 3 个、LSU 原 10 个）作为"未判定"待办保留。

## AXI/LLC 遗留（agent 汇报）
- LLC RTL 未实现 bypass 写和部分行写 miss（`bad` 断言会在出现时触发；68 个程序和默认配置从不出现）；互连本身已验证。
- `axi_subsys` 装配顶 lint：4 个未用信号 + `axi_llc.in_w` 的 UNOPTFLAT（互连↔LLC 经结构体的组合环，需确认是误报还是真环）；暂未加入 lint.sh。
- 变异存活：互连 6/12/18、LLC 9/10/13/14；LLC 程序级变异在读 victim 队列深度修改后未重跑。
- 合并两份 16 tick 锁步壳（`lockstep_ticks.sh` 与 `lockstep_ticks_axi.sh`）。
