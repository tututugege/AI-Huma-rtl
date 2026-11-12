# 08 风险登记簿（2026-11-04 创建，2026-11-12 更新）

> 决定（用户，2026-11-04）：变异存活**不再要求清零**，短时间内跑不完；改为**如实记录所有潜在风险**。本文件就是这份记录。
> 来源：各模块笔记（`docs/modules/*.md`）、`07-roadmap.md`、`deviations.md`，以及 2026-11-04 当天清理/重构的验证记录。
> 约定：**[事实]** 来自笔记或实测；**[判断]** 是我的评估，没有实测支撑。风险等级（高/中/低）都是判断，用来排序，不是量化结论。
> 本文件不替代模块笔记；模块的细节以笔记为准。刷新方式：改完模块后同步更新对应条目，并在第 9 节追加一行变更。

> **2026-11-12 状态**：第 1–8 节保持 2026-11-04 的原文（旧体系：变异 / 锁步 / `refsim`），与现在不一致的条目在行内标了 **[2026-11-12]** 的更新；现行规则见 [06](06-equivalence-policy.md)。新增风险（rv64、紧凑 ROB、写缓冲、生成文件债务等）在第 10 节。

## 1 验证方法本身的限制（横向）

| # | 内容 | 等级 |
| --- | --- | --- |
| V-1 | **变异检查不是门禁**。多数模块的变异结果是历史值（见第 2 节），2026-11-04 的清理和重构之后**没有重跑**。`05-module-tracker.md` 里的变异列因此是**过期数据** | 中 |
| V-2 | 整程序锁步和闭环只覆盖现有程序：61 个 gate + 4 个 vm + dhrystone/coremark/float。大程序被截断（`BIG_CYCLES` 默认 30 万周期；smoke 只跑 6 万周期）。**没有跑过更长程序**，也没有 Linux 级负载。**[2026-11-12]** 现行门禁是 `fm_gate.sh` 69 个程序（rv32，逐条对比）+ rv64 的 53 个 cpu-tests（手工跑）+ Linux 从复位到登录（rv32 约 1.6 亿周期、rv64 约 1.3 亿周期，逐条对比 0 不一致）；SPEC 没有在 RTL 上跑过 | 中 |
| V-3 | 闭环（`tb/soc`）对 RTL 整核只比较**整程序周期数**和**提交数**，逐周期核边界 trace 比较只在少数程序上做过（add-longlong、vm_sum_fetch、几个中断程序）。其余程序周期数相等是强证据，但不等于每拍一致。**[2026-11-12]** 逐周期边界比较已退役，只比周期总数（`ref_cycles.txt`，69 个程序 0 处不同）和逐条提交 | 中 |
| V-4 | 闭环的"空闲 tick 跳过"（`tb/soc`）依赖一个**假设**：LLC 4 MB 数据数组只在控制状态变化时写入，因此不参与不动点比较。LLC 若出现读改写式原地更新，这个假设失效，闭环可能漏掉差异。这只影响测试平台，不影响 RTL | 低 |
| V-5 | 闭环测试平台读取 LSU 内部 `st_fld_q` 的位布局来触发 store 提交时的外设效果。**2026-11-05**：确实出过错——`BR_MASK_WIDTH` 64→32 后字段下移，外设收到错字节（串口乱码、中断不来），逐条对比没有报。现在偏移由 `gen_soc_probe.py` 从配置包推出（`kCfg_*`），参数变化会自动跟上；`stq_fld_t` 的**字段顺序**变了仍要手工同步 `soc_tb.cpp` | 低 |
| V-6 | 复位只验证了"全零输入 3 拍复位 + 从 init 状态起"。**checkpoint 恢复不在范围内**。去复位的数组（存储器风格）没有做过随机初值验证；Verilator 用 `--x-initial 0` 编译，会掩盖对初值的依赖 | 中 |
| V-7 | **从未做过综合**（yosys 把机器卡死后禁止运行）。"可综合风格"只由 lint 规则和写法保证，没有实测。面积、时序、存储器推断是否符合预期都是未知。**[2026-11-12]** 2026-11-05 起有 yosys 通用门综合的面积代理（[09](09-synthesis-report.md)、`synth_cfg.sh`、`synth_depth.sh` 的深度代理），受影响模块的逐次变化记在各 EXP 记录里；**仍然没有工艺库、时序约束、WNS**，rv64 没有综合过，整机推算停在旧配置 | **高** |
| V-8 | 与 trace-model 的对齐只做了**整程序周期数 + 指令数**（69 个程序一致，见 `scripts/cmp_trace_model.sh`）。**模块边界逐拍对照没做**。所用的 trace-model 二进制来自 `exp/frontdoor-ckpt` 分支，工作区还有未提交改动。**[2026-11-12]** 现在的参考是 trace-model main 在同一配置下（`LSU_PIPE_NOWD=1`）的周期表 `ref_cycles.txt` | 中 |
| V-9 | 参考模型本身只读且有已知缺陷：不支持未对齐访问（`load-store` 基线直接 `exit(-1)`），所以未对齐 `lw` 语义**无参考可对照**；`load-store-aligned` 只是替代品 | 低 |
| V-10 | **Linux 启动只对照到前 100 万条提交（约 24.7 万周期）**，之后的内核初始化、用户态没有在 RTL 上验证；完整启动在 RTL 上要 7 小时以上，需要检查点恢复。**[2026-11-12] 已过时：RTL 已从复位完整启动到登录（rv32 1.6 亿周期、rv64 1.3 亿周期，0 不一致），并有 13 段检查点并行检查（`linux_segments.sh`）。**ebreak 断点异常（S-27）只在这条路径上验证过，且只有 `TTG_EBREAK_TRAP` 构建 | 中 |
| V-11 | **参考模型已退役，模块级验证没有了活的对照对象**：`refsim*` 和 `traces/` 是冻结的本地副本（git 忽略、不在版本管理里，丢了无法重建，除非原参考源码还在）；今后新增的行为（如 S-27）只能靠整核闭环对 trace-model 的周期、以及 function-model 的架构值来验证；trace-model 没有模块边界录制钩子，也没有 ALU/MUL/DIV/FP/PRF 的数据值，所以这些数据通路模块没有等价的新对照 | **高** |
| V-12 | **逐条提交对比（新门禁）目前只比较提交 PC 和目的寄存器值**：store 地址/数据、CSR 写值、内存内容、异常 tval 等没有比较；设备读值和 CSR 计数器读值取 RTL 的，不经检验；**[2026-11-12]** 已在 Linux 全程和检查点段上跑过；`memory-stress` 已逐条对比（rv32 230.8 万周期）。store 地址/数据、CSR 写值、内存内容仍未比较（登记在 TODO）。 | 补 store/CSR/内存比较 | 中 |

## 2 变异存活与未判定

> 数据是各笔记里的历史值。"等价/不可达"是当时的判定，**不是本次重新确认的**。

| 模块 | 状态 [事实] | 风险说明 [判断] | 等级 |
| --- | --- | --- | --- |
| back_top（集成层） | 18 个里 11 杀死，**7 待判定**：`glue_mxr_sum_swap`、`exu_flush_mask_mul`、`exu_mul_func3`、`const_src1_busy`、`const_dis2rob_mispred`、`swap_06_ren2dis_uop_src1_busy`、`swap_09_rob_commit_commit_entry_uop_amo_op` | 集成层接线/胶水逻辑里有 7 处没有测试能区分对错，包括 MXR/SUM、AMO 操作码切片、乘法 flush 掩码。其中 `const_src1_busy`、`const_dis2rob_mispred`、`swap_06_*` 涉及的信号在 2026-11-04 已被删为常量，**很可能已不存在**，需要确认 | 中 |
| front_top / core | 30 个里 24 杀死，3 等价，**3 覆盖缺口**：icache `invalidate` 接 0；RET 判定去掉 `imm==0`；`itlb_flush` 接 `fence_i` | 三处都需要定向测试：非零偏移的 `jalr x0, imm(ra)`、SFENCE.VMA 之后取指翻译暴露陈旧 ITLB 项、冲刷拍与 AXI/DCache 探针同拍 | 中 |
| LSU | **约 113 个新变异体从未运行**；已跑 14 个中 10 杀死，**4 存活未判定**（`pkg.lh-lhu-swapped`、`pkg.checkaddr-next-word`、`pkg.checkaddr-prev-word`、`pkg.stq-alive-inclusive`）；**原 10 个存活变异体仍未结案**：M05 M07 M08 M15 M16 M17 M18 M20 M21 M24（MSHR_FULL 唤醒上限、ldq_free 回绕、suppress 老 store 不解除阻塞、退休窗口不限、跨字对齐 store 同址冲突等） | LSU 是验证覆盖最薄、结构最复杂的模块（手写重构后 3200+ 行）。`checkaddr` 跨字冲突在新旧结构上都存活，**说明是真实覆盖缺口** | **高** |
| axi_interconnect | 18 个里 15 杀死，**3 存活**：6（`seen` 陈旧请求保护）、12（写响应延迟线深度）、18（写响应弹出看同拍消费） | 笔记判定为协议上不可达（需要同一主口两个未决写），但没有测试证明 | 低 |
| axi_llc（重写前） | 16 个里 13 杀死；存活：9（程序级）、10、13、14、11（等价） | 已过时，见下一行 | — |
| axi_llc（重写后，2026-11-04） | **只跑了 7 个**（1 2 5 6 7 12 杀死）。**从未在重写后的 RTL 上重跑**：3 4 8 9 10 13 14 15 16 | LLC 整体重写 + 新增旁路写/部分行写，变异证据几乎为零；靠随机锁步 24+24 次 PASS 支撑 | 中 |
| rob / dispatch / idu / pre_idu_queue / ren | 变异结果是历史值（rob 10/11，1 等价；dispatch 16/17，1 等价等） | 2026-11-04 在这些模块上删过字段和逻辑（见第 6 节），变异集**未重跑**，可能有变异体已失去意义或新增了未覆盖路径 | 中 |
| 其余模块（csr、exu_*、fpu、isu、prf、tlb_mmu、bpu、icache、dcache 等） | 笔记中均为"全部杀死或存活已判定为等价" | 历史值；接口打包（第 6 节）之后未重跑 | 低 |

## 3 覆盖缺口（真实程序从未触发的路径）

| # | 内容 [事实] | 风险 [判断] | 等级 |
| --- | --- | --- | --- |
| C-1 | 外设 AXI 读口 3/写口 1、读口 2 在 68 个程序里**零次 valid**；只被随机流量覆盖 | 通用逻辑，随机下等价；真实 MMIO 路径靠 PeripheralModel 解决 | 低 |
| C-2 | 互连同行 hazard 判断（AR 被挂起写阻塞、AW 被未完成读阻塞、写捕获被同行读阻塞）在 4 种几何的 68 个程序里**一次都没有生效**，只被随机流量杀死 | 真实负载里这些 hazard 可能出现（更大/不同内存访问模式） | 中 |
| C-3 | BPU TAGE useful 清除（`deviations.md` S-26）：`reset_cnt[23]` 相关模式需要约 800 万次/bank 更新，**所有验证都没走到**，RTL 已实现但未验证 | 长程序（>数百万次分支）才会触发，与短程序周期数一致不能保证长程序一致 | **高** |
| C-4 | back_top 复位后的"跨拍保持寄存器"（`front2back_hold`、`peripheral_resp_hold`）在边界之外，其正确性不属于集成验证范围；difftest 直接观测的状态也未验证 | — | 低 |
| C-5 | 真实程序没覆盖：IQ_INT/STA/STD/BR 队列满、入队与 flush/mispred 同拍、Rob 中 mispred 与 flush 同拍、写回命中无效槽、重复完成位、Ren 的 areg>32 等（模块笔记各自列出，由随机 trace 补一部分） | 随机 trace 的约束基于 C++ 合法激励，合法性假设本身没有独立验证 | 中 |
| C-6 | CSR 槽被 MUL 抢占；FP 的 fsgnj/fmin/fmax/fclass 在 exu_ctrl 层的联动（FU 内部另有 softfloat 差分） | 低频事件 | 低 |
| C-7 | PTW 只翻了默认配置下活着的部分；其他 satp 模式、页大小组合未验证 | 若将来启用其他模式需要补 | 中 |

## 4 未实现路径（靠断言守护）

| # | 内容 [事实] | 等级 |
| --- | --- | --- |
| N-1 | LLC：prefetch、invalidate、direct-mapped/mode2、noalloc、MMIO、epoch/stale refill、perf/debug 等 C++ 路径**不实现**（配置关闭或从未请求），`bad` 断言在出现时触发 | 低 |
| N-2 | LLC 深度上界是实测值：读响应队列 4（C++ 32）、读 victim 队列 8、写队列 2、`r_pending` 8；超出由时钟断言触发，**未验证更深情形下的行为** | 中 |
| N-3 | LLC："owner victim 应答找到仍在分配的条目并置位"分支实现了但**命中次数为 0**，未验证；旁路写迟到 lookup 遇到同 tick 重填上下文的角落未观察到可区分效果 | 低 |
| N-4 | LLC `stall_lookup_on_table_busy` 从未触发；way 选择失败路径未验证 | 低 |
| N-5 | 外设写口、DMA、difftest、checkpoint 保存/恢复不在 RTL 范围（留在测试平台） | 低 |
| N-6 | PMU：**[2026-11-12]** 已有 tier 1（EXP-013，`rtl/pmu`：事件总线 + 计数器块，18 个事件，`scripts/pmu_parity.sh` 对 trace-model 逐事件核对）；**计数器没接 CSR，软件看不到**，TMA 槽级归因只在 trace-model | 中 |

## 5 未验证的程序与场景

- `memory-stress`（约 154 万周期）、`float_test` **从未在闭环（RTL 整核）里跑过**；闭环最长的是 22.7 万周期（coremark 2 次迭代）。dhrystone/coremark 是重建的缩短版本（64 次 / 2 次迭代），与 README 里的 3,911,612 周期不可比。
- 完整 68 个程序的整程序锁步，在 2026-11-04 的清理之后**没有重跑**；只跑了 smoke 子集（62 个，≤6 万周期）和 8 个程序×37 个模块的宽扫（2 万周期）。
- 16 tick 模块（DCache、`mem_route`、`ptw_walk`、`peripheral_axi`、adapter）接口打包之后只各跑了 6 个程序、8000 周期。
- `axi_subsys` 的 Verilator lint 被跳过（只做风格检查），原因是 `axi_llc.in_w` 的结构体粒度组合环（UNOPTFLAT）报警；LLC 重写后是否仍存在未单独确认。

## 6 2026-11-04 的改动及其验证（这些是"最近改过、证据最新"的区域）

| 改动 | 验证 | 没做的 |
| --- | --- | --- |
| 删除 TMA 边带、7 个常量绑死字段、`back_top_nolsu`、ROB `flush_pipe`（该路径参考模型从未置位，MMIO 靠"等到队头执行"） | lint；idu/rob/dispatch/back_top 62 个 smoke 程序锁步；Rob 6 条随机 trace；闭环 65 个程序周期数相等 | 变异重跑；68 程序整扫 |
| 删除 SC-L/loop 预测元数据（恒 0；PTAB/F2B/PreIduQueue 每条 1448 位） | lint；ptab/front2back_fifo/pre_idu_queue/front_top/back_top 62 个 smoke；pre_idu 4 条随机 trace；闭环 65 | 同上 |
| 边界数组尺寸改配置参数；1 位通道数组改打包向量（281 个信号名，`tools/pack_bits.py`） | lint；37 个模块×8 程序（2 万周期）锁步；5 个 16 tick 模块×6 程序；闭环 65 | 全部程序；变异 |
| LLC 硬件风格重写 + 旁路写/部分行写 miss/owner victim 应答 | 子代理：smoke 62、小几何 18、随机锁步 8 种子×3 几何×（axi_llc + axi_subsys）×（新旧写路径）；我独立复核：lint、闭环 65、1 个随机种子 | 见第 2 节 |
| 测试平台：空闲 tick 跳过、eval 次数优化、提交数口径校准（跳过中断槽） | 闭环 65；与 trace-model 63 程序周期/指令数一致 | — |
| 11 个未用 localparam 删除（`*_pkg`） | lint | — |

## 7 已知偏差

`docs/deviations.md` 有 26 条（S-01…S-26）。其中 S-26（TAGE useful 清除）标注**未验证**，见 C-3。其余条目是"有意复刻参考模型怪行为"或"有意简化"，以该文件为准，本文不复述。

## 8 结构/风格债务（不影响功能，影响可维护性）

- 平铺端口：全仓库约 5372 个端口，仍有 255 个 1 位非压缩数组、156 个字面量尺寸，主要在 `axi_llc`、`axi_interconnect`、`axi_subsys`、`mem_axi` 和以模块参数 `N` 定尺寸的 `*_bank`；`exu_ctrl` 159 个端口、`lsu` 113 个。
- `back_top.sv`、`exu.sv`（`tools/gen_backtop.py`）、`soc_top.sv`（`tools/gen_soc_top.py`）是生成文件，**但 2026-11-12 为 rv64 手改过位宽，生成器和 `spec/*.io` 没有同步，重新生成会丢 rv64 位宽**（见第 10 节 R-1）。
- 73 处 lint 豁免（均带原因）；`dcache_cover.sv`、15 条 `assert property` 等仿真专用内容在 RTL 目录里，**未逐个核实是否都有综合保护**。
- 绝对路径已统一由 `scripts/env.sh` / `scripts/ttg_env.py` 提供（2026-11-04，原来 58 个文件 245 处写死）；仅参考模型源码在 AI-Huma 之外，由 `BASELINE_SRC` 指定（默认相对 AI-Huma 的同级 `llm4trace/third_party/...`）。旧的 28 个 git worktree 已清理。
- 文档：`05-module-tracker.md` 的变异列过期（见 V-1）。

## 9 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-12 | 文档审计：新增第 10 节（rv64 / 紧凑 ROB / 写缓冲 / 分级 LSU 风险），V-2、V-3、V-7、V-8、V-10、V-12、N-6 和第 8 节生成文件条目更新 |
| 2026-11-06 | L1D 预取器 h1（EXP-009，`dcache_pf` 等，分支 `exp/l1d-prefetch`）：已验证 = 66 个程序逐条对比 + 周期与 trace-model 相等（预取开、关各一次）、lint 0；**未验证/未做**：`axi_llc` 读响应队列 RQD=8 在预取读流量下是否够用；带预取的 Linux 启动（进行中）；`no_fill` 项与 `MSHR_FULL` 唤醒的压力场景现在有定向测试 `pf-stress`（trace-model `tests/extra`，RTL 与 trace-model 周期相等，预取开 625,240 / 关 612,878，覆盖 MSHR 满、晋升、LLC-only 释放、页边界），但没有随机流量；`dcache`、`mshr`、`lsu_dc_req_ld` 的变异结果已过期；综合只有 yosys 通用门面积代理，无 WNS；`perf_replay` 位（LSU 重放）原来只喂 perf，现在影响行为，LSU 侧 `replay` 的产生点必须与 trace-model 同拍 |
| 2026-11-05 | 第 3 批面积配置进 main（上层 EXP-005）：V-5 记录了偏移出错的经过和现在的做法；`lsu_core` 的 store MMU 请求端口按 `NLD` 声明的错误已修（两者相等时不暴露）；V-12 的实例（store 数据错误没被逐条对比发现）见 V-5 |
| 2026-11-04 | 创建。依据：用户决定不再要求变异清零，改为记录风险 |

## 10 2026-11-12 新增风险（rv64 迁移、紧凑 ROB、写缓冲、分级 LSU）

| # | 内容 [事实] | 等级 |
| --- | --- | --- |
| R-1 | **生成文件与 rv64 脱节**：`back_top.sv`、`exu.sv`、`soc_top.sv` 为 rv64 手改，`tools/gen_backtop.py`、`gen_soc_top.py`、`spec/*.io` 未同步；重新生成会丢位宽。改这些接口前必须先回写生成器 | **高** |
| R-2 | rv64 只覆盖 RV64IMAB：**F/D（OP-FP 非法）、C、SPEC 都没做**；rv64 没有 `fm_gate.sh` 式的程序表（53 个 cpu-tests 手工跑，周期与模型 53/53 一致，需 `LSU_PIPE_NOWD=1`）；rv64 没有综合过、没有 `memory-stress` 之外的大数组回归 | 中 |
| R-3 | rv64 位宽集中在数据通路；dcache 的行/AXI 侧仍是 32 位字，物理地址 32 位（Sv39 的 PTE 只有 `ppn[19:0]` 到达物理地址）。物理地址超过 4 GiB 的配置**不支持** | 低 |
| R-4 | 紧凑 ROB（`ROB_COMPACT=1`，EXP-028）：行式 ROB 保留为 `ROB_COMPACT=0` 但**默认配置外没有回归**（周期表已换成紧凑 ROB 的）；`rob` 最长路径比行式深约 5 级；BPU 提交额度会卡住分支密集短循环（TODO） | 中 |
| R-5 | 分级 LSU（`LSU_PIPE=1`）是默认；旧 LSU（`LSU_PIPE=0`）原样保留，但**没有 `LSU_PIPE=0` 的周期表回归**（`ref_cycles_legacy_lsu*.txt` 是旧配置、没再生成），上面第 2 节 LSU 变异数据只对旧 LSU | 中 |
| R-6 | RTL 没有 LDQ/STQ 看门狗，trace-model 有 63 周期看门狗，所以对比周期时模型必须设 `LSU_PIPE_NOWD=1`；否则 store 重发会造成几十周期的假差异（`crc32`、`memory-stress` 的教训） | 低 |
| R-7 | store 写缓冲（EXP-024）：第一版有一次 Linux 段 s04 的 `sc.w` 不一致，原因没找到（现版本通过）；没有写缓冲的 PMU 事件 | 低 |
| R-8 | 0x87f00000 uncached 窗口已删（EXP-027）：老程序/老基线里依赖该窗口的数据作废；`peripheral_axi` 现在只服务 MMIO | 低 |
| R-9 | 综合：2026-11-05 之后的改动（紧凑 ROB、写缓冲、IQ 入队宽度、rv64）没有整机重做面积推算；见 [09](09-synthesis-report.md) | 中 |
