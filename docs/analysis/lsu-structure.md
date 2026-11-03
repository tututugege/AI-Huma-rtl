# LSU 结构分析：事件 → 更新规则表（重构依据）

本文先于重构 RTL 写成，来源：参考模型 `back-end/Lsu/RealLsu.cpp`（commit 2f31e8d）、旧 RTL（`rtl/backend/lsu/` 3211 行，其中
`lsu_core/lsu_state/lsu` 由 `tests/lsu/gen_core.py` 生成）。目的：把 C++ 在同一个 `nxt` 上顺序改写的 ~20 个 `comb_*` 阶段，
还原成"每个状态字段被哪些事件写、同拍多事件时谁优先"的规则表。新设计按这张表组织；评审也按这张表对照。
边界 `spec/lsu.io` 不变。

## 0. 一拍内的阶段顺序与"为什么还需要阶段视图"

C++ 一拍内阶段（`BackTop::comb`）：`B` stq_commit → `C` mmio_in → `D` dcache_ld 响应 → `E` dcache_st 响应 → `F` lsu2exe 写回 →
（EXU）→ `G` exe2lsu → `H` tlb_out →（MMU 组合应答）→ `I` tlb_in → `J` stlf → `K` dis2lsu 分配 → `L` flush/mispred/clear_mask →
`M` lsu2dcache_ldq → `N` lsu2dcache_stq → `O` mmio_out → `P` check(retire)。后一阶段读到前一阶段改过的值。

边界可见的"同拍穿越"路径有：AGU(G) → 向 MMU 发请求(H) → MMU 应答(I) → STLF 检查(J) → 向 DCache 发请求(M)，
**一个 load 可以在 AGU 到达的同一拍内走完这些状态并发出 DCache 请求**；DCache 命中响应(D) → 写回口(F) 同拍。
这些时序在锁步里是可观察的，所以组合深度不能砍。

结论：**每个表项的"状态"需要若干个阶段视图**（该项在阶段 X 之后的状态），因为队列窗口/限额逻辑（谁排在前 4 个、
finish 队列还剩几格）依赖其他表项在前一阶段之后的状态。旧 RTL 把这一点实现成"整个状态数组（17 个字段 × 64 项）+ 每阶段一份拷贝
`_v1.._v9`"。新设计只保留：

- **状态机字段**（4 位）的阶段视图，作为表项内部的优先级链，对外只导出被跨项逻辑读到的那几个视图（有名字：`st_rsp`、`st_agu`…）；
- **数据字段**不再有版本链：每个字段只在特定事件写，规则 = "写使能 + 写数据"（事件优先级即规则优先级）；
  同拍后续阶段要读到该写入值的，用一条旁路 `x_e = we ? wd : x_q`（每字段至多一条，不是链）。

## 1. LDQ 表项（`lsu_ldq_ent`，64 项，每项一个模块实例）

事件（按阶段顺序，同拍可以连续发生在同一项上）：

| 阶段 | 事件 | 条件（由跨项逻辑算出，表项只接收结果） |
| --- | --- | --- |
| C | `mm_rsp` | 外设返回 MMIO load 数据，`uncached.idx==e`，`finish.count<64`，且项为 `WaitMmioResp` |
| D | `dc_rsp` | DCache load 响应经 wait_dcache 槽/代号核对后落在本项，且项为 `WaitDcacheResp`（同拍两口落同一项只有前者生效） |
| F | `wb_go` | 本项在 finish 窗口里、状态为 `ReadyToWb/PageFault`、写回口未满 |
| G | `agu_go` | AGU 请求的 `rob_idx/rob_flag` 与本项一致（**不看状态**，与 C++ 一致） |
| I1 | `tr_go` | MMU 响应的 `{wait_idx,entry_idx}` 与 wait_mmu 槽一致，且本项为 `WaitTlb` |
| I2 | `tw_stlf/tw_fin/tw_retry` | wait_mmu 窗口内：`WaitSTLF` 被接收进 STLF 队列 / `WaitFinish` 被接收进 finish 队列 / `WaitTlbRetry` |
| J | `sf_chg` | STLF 窗口顺序扫描的结果（`sf_new` 为新状态，`sf_res_we` 为转发数据写入） |
| K | `al_go` | Dispatch 分配本项 |
| L | `flush` / `mispred` / `clear_mask` | 全局广播 |
| M | `iss_go` | wait_dcache 窗口里前 4 个可发的项 |

状态（`st`）转移，每个阶段一行；同拍内后一阶段在前一阶段的结果上继续（表项内部的优先级链就是这个顺序）：

| 阶段 | 当前状态 → 新状态 |
| --- | --- |
| C | `WaitMmioResp → ReadyToWb` |
| D | `WaitDcacheResp → ReadyToWb`（命中）/ `ReadyToIssue`（replay） |
| F | `ReadyToWb/PageFault → Empty` |
| G | 任意 → `WaitTlb` |
| I1 | `WaitTlb →` `WaitSTLF`（HIT）/ `WaitFinish`（PAGE_FAULT）/ `WaitTlbRetry`（MISS） |
| I2 | `WaitSTLF → CheckStlf`；`WaitFinish → PageFault`；`WaitTlbRetry → WaitTlb` |
| J | `CheckStlf →` `WaitMmioResp`（MMIO 可发）/ `CheckStlf`（重试，重新入 STLF 队列）/ `ReadyToIssue`（进 wait_dcache）/ `WaitDcache`（wait_dcache 满，跨拍保持）/ `ReadyToWb`（转发命中，进 finish）/ `WaitFinish`（finish 满，跨拍保持）；上一拍遗留的 `WaitDcache/WaitFinish` 同样在 J 里再试 |
| K | `Empty → Allocated` |
| L | `flush`：全部 → `Empty`；`mispred`：非 Empty 且 `br_mask & dec_br_mask != 0` → `Empty`（用 K 之后的 `br_mask`） |
| M | `ReadyToIssue → WaitDcacheResp` |

数据字段规则（每字段一行；"写者（优先级高→低）"在同拍多事件时给出覆盖顺序）：

| 字段 | 写者 | 读者（及读取时点） | 备注 |
| --- | --- | --- | --- |
| `rob_idx, rob_flag` | K | G 匹配、F 写回、J（MMIO 最老判断）：均用 K 之前的值 | 只在分配时写 |
| `br_mask` | K（分配值）、L（`clear_mask`：仅对**周期开始时非 Empty** 的项清位） | L 的 mispred 判断用 K 之后的值；F 写回用周期开始值 | K 先于 L；同拍分配的项不被 clear_mask 清 |
| `vaddr, dest, func3, snap_idx, snap_flag, lrsc` | G | F（周期开始值）、H（`vaddr` 用 G 之后）、J（`func3/snap` 用 G 之后）、D（`func3` 周期开始值） | 同拍多口命中同一项：口序大者优先（C++ 后写覆盖） |
| `paddr, mmio` | I1（仅 HIT） | D 唤醒/数据提取（周期开始值）、F 的 LR 预约地址（周期开始值）、J 与 M（I1 之后） | 旧 RTL 与 C++ 一样不在 G 里清 `paddr=0`：无人在 HIT 之前读（J 只看 CheckStlf 项，M 只看 ReadyToIssue 项） |
| `pf` | K 清零；I1 在 PAGE_FAULT 时置位 | F | I1 与 K 不会同拍落在同一项（K 只分配 Empty 项） |
| `result` | C（MMIO 数据）、D（命中数据）、J（转发数据）；三者互斥（要求的前态分别是 `WaitMmioResp/WaitDcacheResp/CheckStlf`） | F（C、D 之后的值） | PAGE_FAULT 不写 `result`：写回时 `pf ? vaddr : result`，C++ 的 `result=v_addr` 与 `diag_val=v_addr` 重复 |
| `replay` | K 复位 `HIT`；D 在 replay 响应时写 | D 的 MSHR 唤醒（D 响应之后） | 复位是随机轨迹发现的真实 bug 的修复（见 lsu.md §5） |

STLF/wait_dcache 的辅助槽（环形队列的槽，不是表项字段）：`wd_gen[slot]`（M 写：本次请求的代号）、`wd_wait[slot]`
（D 响应置 `4/0`，D 唤醒清 0，M 递减；**槽复用时保留旧值**，这是 C++ 可观察行为，保留）。

## 2. STQ 表项（`lsu_stq_ent`，64 项）

| 阶段 | 事件 | 状态转移 |
| --- | --- | --- |
| B | `cm_go`：ROB 提交口命中 `commit_ptr` | `WaitCommit → Committed`；`flush` 或（LR/SC 且 `!sc_pass`）→ `Done` 并置 `suppress` |
| C | `mm_rsp` | `WaitMmioResp → Done` |
| E | `dc_rsp` | `WaitDcacheResp → Done`（HIT，`wait=0`）/ `Committed`（replay：`replay` 类型、`wait=(MSHR_HIT\|MSHR_FULL)?4:0`）；E 之后 `wk_go` 清 `wait` |
| F | `wb_go`：mmu_done 窗口里 `Ready/PageFault` 被接收 | `→ WaitCommit`；SC 且非页错：`sc_pass=suppress反=cur预约命中`、`suppress=!sc_pass` |
| G | `std_go` | `data/data_valid` 置位；若 `paddr_valid && WaitData` → `Ready` 且入 mmu_done |
| G | `sta_go`（在 STD 之后处理） | `vaddr/func3/dest/lrsc` 写入，`paddr_valid=0`，`→ WaitTlb`（覆盖 STD 的 `Ready`） |
| I1 | `tr_go`（仅 `WaitTlb`） | HIT：`paddr/paddr_valid/mmio` 写入，`data_valid ? WaitDone : WaitData`；PAGE_FAULT：`pf=1,→ WaitDone`；MISS：`→ WaitTlbRetry` |
| I2 | wait_mmu_stq 窗口 | `WaitDone → PageFault/Ready`（`pf`，并入 mmu_done）；`WaitData`：只离开队列；`WaitTlbRetry → WaitTlb` |
| K | `al_go` | `→ Allocated`，复位 `data_valid/paddr_valid/pf/suppress/mmio/lrsc/sc_pass/replay/wait`，写 `br_mask/rob_idx/rob_flag` |
| L | `clear_mask` | 对**周期开始时**窗口 `[head,head+count)` 内的项清 `br_mask` 位（`flush/mispred` 只截断 `count`，不改表项） |
| N | `iss_go/sup_go/mm_go` | `Committed → WaitDcacheResp`（发 DCache）/ `Done`（`suppress`，`wait=0`）/ `WaitMmioResp`（仅窗口位 0）；候选项 `wait` 递减 |
| P | retire | 队首连续 `Done` 项出队（只动指针，不改表项） |

| 字段 | 写者 | 读者 |
| --- | --- | --- |
| `data` | G(STD) | J 转发、N 发 DCache、N 的 MMIO 写 |
| `data_valid` | K 清；G(STD) 置 | I1、J |
| `vaddr, func3, dest, lrsc` | G(STA) | H(`vaddr`，G 之后)、F、J(`func3`)、N |
| `paddr, mmio, paddr_valid` | I1；K 清 `paddr_valid/mmio`；G(STA) 清 `paddr_valid` | J、N、F(SC 判断) |
| `pf` | K 清、I1 置 | I2、F |
| `suppress` | K 清；B（`flush` 或 失败 SC）置；F（SC 判决，`!sc_pass`）写 | J、N |
| `sc_pass` | K 清；F（SC）写 | B、J |
| `replay, wait` | K 复位；E 写；E 唤醒清 `wait`；N 递减/清 | E 唤醒、N |
| `br_mask, rob_idx, rob_flag` | K；L(`clear_mask`) | G 匹配、F |

指针：`stq_head/head_flag/count/ccount` 由 `lsu_stq_ptr` 一个模块持有。`ccount` 规则链：B（接收的提交数）→ L（flush：`min(ccount,count)`；
mispred：不超过截断后的 `count`）→ P（减去退休数）；`count` 规则链：K（加分配数，`count+rank<64`）→ L → P。
`stq_commit = head + ccount` 不建寄存器（恒等式）。

## 3. 六个环形队列（`lsu_ring`）

队列项是"LDQ/STQ 序号"，允许中间有空洞，`count` 含空洞；窗口 = 队首起 `min(count, 20)` 个槽。
所有队列的操作都是同样几种，只是发生阶段不同。**同一个队列在一拍内的操作序列**（每个操作 = 先 `kill_slot`，再窗口 `kp`
（窗口内按 `keep` 失效并弹出队首连续无效项），再 `append`（在尾部按候选序压缩追加））：

| 队列 | 一拍内的操作序列（阶段） | 被谁读窗口 |
| --- | --- | --- |
| `wmld` wait_mmu_ldq | G append(AGU 命中) → I1 kill_slot(MMU 应答对应的非 WaitTlb 槽) → I2 kp → L | H、I2 |
| `wmst` wait_mmu_stq | G append(STA 命中) → I2 kp → L | H、I2 |
| `mdone` mmu_done_stq | F kp → G append(STD 就绪) → I2 append(WaitDone 的 STQ) → L | F |
| `finish` | C append(MMIO) → D append(wait_dcache 窗口里 ReadyToWb) → F kp → I2 append(PageFault) → J append(转发/遗留) → L | F |
| `stlf` | I2 append(CheckStlf) → J kp → J append(重试) → L | J |
| `wdc` wait_dcache | D kp → J append → L | D、M |

L = `flush`（`valid` 全清、`count=0`、`head` 不动）或 `mispred`（`valid` &= ~(对应 LDQ 项已 Empty / STQ 序号已不在截断窗口)）。
`append` 的各个候选的限额（`finish.count + rank < 64` 等）读的是**该阶段之前**队列的 `count`，所以每个操作之后的视图需要导出。
`tail = head + count` 在 `kp` 前后不变，追加槽号只由 `append` 推进，所以存储按槽写使能：
`idx[s]` 只在被追加时写；`valid` 位由 set/clear 两类事件决定。

## 4. 标量单元

| 单元 | 事件链 |
| --- | --- |
| `uncached`（MMIO 在途请求） | C：响应清 `valid`（load：`finish.count<64` 才清，**不看 LDQ 状态**；store：直接清）→ J：MMIO load 起占（第一个可发的）→ L：`flush` 只保留"仍在 `WaitMmioResp` 且序号仍在保留窗口的 store"；`mispred` 杀掉 LDQ 项已 Empty 的 load/不在截断窗口的 store → N：窗口位 0 的 MMIO store 起占（看的是 L 之后的 `valid`） |
| `lrsc`（LR/SC 预约） | F：SC 写回消耗预约（非页错）；LR 写回（非页错）设预约，同拍多个 LR 取窗口位置最大者；SC 的判决用**周期开始值** → I：页错 load/store 清预约 → L：`mispred` 且 `br_mask` 命中则清；`clear_mask` 清 `br_mask` 位 |
| `req_gen` | M：`+= 本拍发出的 DCache load 数` |

## 5. 同拍多事件优先级汇总（旧版本链还原结果）

- LDQ 状态：见 §1 阶段表（后阶段覆盖前阶段）。旧 `ld_st_v1..v9` 即这 9 个阶段视图，新设计里它们是 `lsu_ldq_ent` 内部的
  命名中间量（`st_rsp, st_wb, st_agu, st_tlb, st_win, st_sf, st_al, st_fl, st_nx`），不再是 64 项数组的整体拷贝。
- LDQ 数据字段：每字段**至多一个写阶段**（`result` 三写者互斥），旧 `ld_result_v1..v3`、`ld_paddr_v1` 等版本链消失。
- STQ 状态：B → C → E → F → G(STD) → G(STA) → I1 → I2 → K → N（见 §2）；旧 `st_st_v1..v8` 同理。
- STQ 数据字段：`suppress` 有三个写者（B、F、K 清零），顺序即阶段顺序；`wait` 有四个（K、E、E 唤醒、N）。
- 环形队列：见 §3。

## 6. 参数化

队列深度（`LDQ_SIZE/STQ_SIZE`）、端口数（`LSU_LDU_COUNT/LSU_STA_COUNT/LSU_SDU_COUNT/LSU_AGU_COUNT`）、窗口（`LSU_LOAD_WINDOW_WIDTH`）、
分配宽度（`MAX_*_DISPATCH_WIDTH`）、提交宽度全部引用 `ttg_cfg_pkg`。重构后不新增写死的数字（`lsu_pkg` 中 ROB/PRF 宽度改引用 cfg）。
