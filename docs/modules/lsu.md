---
module: lsu
area: backend
rtl: rtl/backend/lsu
model: trace-model back-end/Lsu/RealLsuPipe.cpp、LsuPipeOutputs.cpp、LsuPipeWriteback.cpp、LsuPipeTranslate.cpp、LsuPipeRequests.cpp、LsuPipeInternal.h、include/RealLsu.h、include/RealLsuPipe.h（调度单元 `back.lsu`，类 `RealLsu`，阶段 `comb_outputs / comb_writeback / comb_translate / comb_requests / comb_commit_store`）
status: 最近一次改 LSU 的提交（312e6f8）的说明写 fm_gate 67/67、周期等于参考表；本次写文档没有重跑（见第 8 节）
depth: 101 层（lsu，单模块综合，2026-11-20，`SYNTH_ABC="strash;balance;map"`，生成门代理，见 09-synthesis-report 第 12 节）
---

# lsu 设计文档

## 1. 职责

访存单元：4 条 load 流水线、3 个 STA 口、3 个 STD 口，一个 64 项的 load 队列（LDQ）和一个 64 项的 store 队列（STQ）。每拍做这些事：

1. 接收分派（`dis2lsu_*`）：给 load 分配 LDQ 项（LDQ 的空项号告诉分派），给 store 分配 STQ 项（STQ 是环，分派用 `lsu2dis_stq_tail / _free`）；
2. 接收 EXU 的地址结果（AGU，`exe2lsu_ldu_req_* / exe2lsu_sta_req_*`）和 store 数据（`exe2lsu_sdu_req_*`），查 DTLB（`lsu2mmu_*` / `mmu2lsu_*`），对 STQ 做部分地址 CAM（store 到 load 的转发和相关性检查），向 DCache 发 load 读请求；
3. 处理 DCache 响应、store 到 load 转发的确认、等待事件（等 STA 地址、等 STD 数据、等 DCache 填充）的 load 的"停车 / 唤醒 / 重放"，load 写回（`lsu2exe_wb_req_*`），以及对 load 的消费者的唤醒（`lsu2iss_wake_*`）；
4. 管理 store 的生命周期：STA / STD 到齐后向 ROB 报完成（`lsu2exe_sta_wb_req_*`），ROB 提交后进入写缓冲，合并同一缓存行的两个 store，经 DCache store 口写出，响应回来后退休；
5. MMIO（未缓存）load 和 store 走唯一的"未缓存单元"，LR / SC 用一个预约寄存器；
6. 访存相关性推测（`LSU_MEMSPEC = 1`）：load 可以越过地址未知的老 store，事后检查，违例时让 ROB 冲刷；
7. 处理 flush、误预测杀死、分支掩码清除。

模型对应一个调度单元 `back.lsu`（`RealLsu`），阶段 `comb_outputs → comb_writeback → comb_translate → comb_requests`，另有 `comb_commit_store`（给外设模型看已提交 store，只在模型里有）。DTLB 在模型里是 LSU 的子模块（`dtlb`，在 `comb_translate` 里调用），RTL 里是独立模块 `tlb_mmu`，见 [tlb_mmu.md](tlb_mmu.md)。

**现行设计。** `lsu.sv` 只实例化 `lsu_pipe`（里面是 `lp_core` 和 `lp_*`，称"分级流水 LSU"，就是本文描述的设计）。原来的旧 LSU（`lsu_core` 和 30 个 `lsu_*` 子模块，由 `LSU_PIPE = 0` 选择）在共用 AGU 的配置下已经不能编译，2026-11-18 连同 `LSU_PIPE` 常量一起删除（见第 10 节）。

## 2. 配置（`ttg_cfg_pkg` / `lp_pkg`，现行默认）

| 名字 | 值 | 含义 |
| --- | --- | --- |
| `XLEN_BITS` | 64 | 数据字宽；物理地址在 LSU 里是 32 位 |
| `LDQ_SIZE` / `STQ_SIZE` | 64 / 64 | 队列项数；下标宽 `LDQ_IDX_WIDTH` / `STQ_IDX_WIDTH` = 6 |
| `LSU_LDU_COUNT`（`NLD`） | 4 | load 流水线条数 = DCache load 口数 = load 写回口数（`LSU_LOAD_WB_WIDTH` = 4） |
| `LSU_STA_COUNT`（`NST`） | 3 | STA 口数（地址 + DTLB）；也是 DCache store 口数、STA 写回口数 |
| `LSU_SDU_COUNT`（`NSD`） | 3 | STD（store 数据）写口数 |
| `LSU_AGU_PHYS` | 5 | 物理 AGU 数 = DTLB 口数（见下） |
| `LSU_AGU_SHARED`（`NM`） | 2 | 共用 AGU 数：2 个 AGU 既能做 load 地址也能做 STA 地址（load 优先） |
| `MAX_LDQ_DISPATCH_WIDTH`（`NDIS`） | 8 | 每拍最多分配的 LDQ / STQ 项数 |
| `COMMIT_WIDTH`（`NCM`） | 8 | ROB 每拍提交口数 |
| `NRP` | 4 | load 重放寄存器个数（模型 `CFG_LSU_PIPE_RP`） |
| `NDR` | 2（`min(NST, 2)`） | 写缓冲每拍最多发出的 store 请求数，只用 DCache store 口 0、1（模型 `CFG_LSU_PIPE_DRAIN`） |
| `NWB` / 每项 store 数 | 4 / 2 | 写缓冲项数、每项最多两个 store（`lp_pkg`；模型 `CFG_LSU_PIPE_WBUF` 4、`_WBMAX` 2） |
| `NINS`（`lp_wbuf`） | 4 | 写缓冲每拍最多插入的已提交 store 数（模型 `CFG_LSU_PIPE_WBINS` 4） |
| `NRET` | 4 | STQ 每拍最多从队首退休的 store 数 |
| `EPW` / `RWW` | 4 / 3 | 每个 LDQ 项的请求代号位宽、重放倒计时位宽 |
| `LSU_PEPLAY_WAIT_CYCLES`（`RWAIT`） | 4 | MSHR_HIT / MSHR_FULL 类重放的等待拍数 |
| `LSU_MEMSPEC`（`MS`） | 1 | 访存相关性推测开 |
| `LSU_MDP_BITS` / `LSU_MDP_CLR` | 6 / 2000 | 等待表索引位宽（64 项 × 1 位）/ 清零周期 |
| `LP_CUT` | 262143（18 位全 1） | 关键路径切点掩码，见第 9 节 |
| `LP_L2` | 1907 | 另一组切点 / 功能位，见第 9 节 |
| `DCACHE_OFFSET_BITS` / `LINEW` | 6 / 26 | 缓存行 64 B；行号位宽 `32 - 6` |
| `DST_STRB_W` / `DST_L2_W` | 9 / 75 | store 请求的字节使能位宽（`XLEN/8 + 1`，多出的一位只用于冲突检查）/ 第二个 store 字的位宽 |

**AGU 与口的对应**（`lp_l1`：`NM = 2`、`NL = NLD - NM = 2`、`NS = NST - NM = 1`、`NPH = NLD + NS = 5`）：物理口 0、1 只给 load；口 2、3 共用（load 槽 2、3 和 STA 槽 1、2）；口 4 只给 STA（STA 槽 0）。函数 `st_phys(k)`：STA 槽 `k < NS` 在口 `NLD + k`，其余在口 `NL + (k - NS)`。与 [isu.md](isu.md) 里的口号对应：load 口 6、7 = 物理口 0、1；共用的 load 口 8、9 与 STA 口 11、12 = 物理口 2、3；STA 口 10 = 物理口 4。

**load 队列项状态**（`lp_ld_st_t`，4 位）：

| 状态 | 含义 |
| --- | --- |
| `LS_EMPTY` | 空 |
| `LS_ALLOC` | 分派时分配，等 AGU 地址 |
| `LS_PIPE` | 在 L1 / L2 流水线里，或在重放寄存器里 |
| `LS_DCW` | DCache 读请求已发，等响应 |
| `LS_RPW` | 停车：原因在 `rcause`，等待条件在 `rwait` / `blk` |
| `LS_RDY` | 可以进重放寄存器 |
| `LS_WBP` | 结果已有，等 load 写回口 |
| `LS_MMW` | MMIO load，等它成为最老的指令 |
| `LS_MMR` | MMIO load 在总线上 |
| `LS_WB3` | 在 L2 已决定直接完成，在 L3 寄存器里，下一拍写回 |
| `LS_SPD` | 访存推测：已写回（消费者已被唤醒）但越过了地址未知的老 store，ROB 完成被推迟 |

**停车原因**（`lp_rc_t`，`rcause`）：`RC_TLB`（DTLB 没命中，等 `rwait` 拍后重试）、`RC_ADDR`（挡住它的老 store 还没有地址，等那个 store 的 STA 事件）、`RC_HOLD`（部分重叠或未决的 SC，等那个 store 退休或 SC 判决）、`RC_DATA`（store 盖住 load 但数据还没到，等 STD 写入，`rwait` 里借用来放 load 在 store 数据里的字节偏移）、`RC_DC`（DCache 回了冲突 / MSHR 命中 / MSHR 满，倒计时或等填充）。

## 3. 接口

端口按模型的 `in` / `out` 结构命名，数组形式的端口是把结构展开成平铺端口（`lsu_pipe.sv` 把它们打包进 `lp_*_t` 结构再接 `lp_core`）。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dis2lsu_alloc_req / _br_mask / _rob_idx / _rob_flag [DECODE_WIDTH]` | store 分配（STQ 项号由 LSU 自己的 tail 决定，分派不给号） |
| 入 | `dis2lsu_ldq_alloc_req / _ldq_idx / _br_mask / _rob_idx / _rob_flag / _mdp [DECODE_WIDTH]` | load 分配（LDQ 项号由分派从 `lsu2dis_ldq_alloc_*` 里取）；`_mdp` 是 load PC 的等待表索引（在 `pre_idu_queue` 里算好：`pc[S +: B] ^ pc[S+B +: B]`，`S = SLOT_SHIFT`、`B = LSU_MDP_BITS`，与模型 `MemDepPred::idx` 同） |
| 入 | `exe2lsu_ldu_req_valid / _occ / _uop_* [LSU_LDU_COUNT]` | load 的 AGU 结果；`_occ` 是 AGU 槽寄存器里有 uop（flush / 误预测杀死之前），重放的槽和口分配看它 |
| 入 | `exe2lsu_sta_req_valid / _occ / _uop_* [LSU_STA_COUNT]` | STA 的 AGU 结果，`_occ` 同上；`is_atomic && amo_op == SC` 标成 SC |
| 入 | `exe2lsu_sdu_req_valid / _uop_* [LSU_SDU_COUNT]` | STD（store 数据），带 STQ 项号和 ROB 号 |
| 入 | `rob_commit_commit_entry_valid / _uop_type / _uop_amo_op / _uop_stq_idx [COMMIT_WIDTH]` | ROB 提交口：type 6 是 store，18 是 AMO（`amo_op != LR` 的算 store） |
| 入 | `rob_bcast_flush`、`dec_bcast_{mispred, br_mask, clear_mask}` | 全局 flush（经 `FLUSH_REG` 已晚一拍，见 docs/FLUSH_REG.md）、误预测、分支掩码 |
| 入 | `rob_flush_now` | 本拍 ROB 刚做出的 flush 决定（不晚一拍）：只用来限定本拍提交的 store（带 flush 提交的 store 不能写出） |
| 入 | `rob_bcast_head_valid / _rob_idx`、`rob_bcast_head_incomplete_valid / _rob_idx` | ROB 头 / 头部未完成指令，MMIO load 判断"自己是最老的未完成指令" |
| 入 | `mmu2lsu_resp_valid / _paddr / _result / _entry_idx [LSU_AGU_PHYS]` | DTLB 响应（同拍组合返回），`_result`：0 未命中、1 命中、2 缺页 |
| 入 | `dcache2lsu_load_resps_valid / _req_id / _data / _replay [LSU_LDU_COUNT]` | DCache load 响应；`_replay`：0 HIT、1 CONFLICT、2 MSHR_HIT、3 MSHR_FULL；`req_id[31]` 为 1 的响应不是 LSU 的（`mem_route_req.sv` 在口 3 上插入 I-cache 回填和页表遍历的请求，用这一位标记） |
| 入 | `dcache2lsu_store_resps_valid / _req_id / _replay [LSU_STA_COUNT]` | DCache store 响应，`req_id` = 领头 store 的 STQ 项号 |
| 入 | `dcache2lsu_mshr_fill / _fill_line` | MSHR 填充事件（唤醒等填充的 load / store） |
| 入 | `dcache2lsu_load_retry_busy / store_retry_busy` | DCache 每个口一位寄存器位：该口有隐藏的重试占着，LSU 这拍不能在该口发请求 |
| 入 | `peripheral_resp_is_mmio / _ready / _mmio_rdata` | 外设响应 / 外设可接收请求 / 读数据 |
| 出 | `lsu2dis_stq_tail / _tail_flag / _stq_free [6:0] / _ldq_free [6:0]` | STQ 尾和空闲数、LDQ 空闲数 |
| 出 | `lsu2dis_ldq_alloc_valid / _idx [DECODE_WIDTH]` | 最低的 8 个空 LDQ 项（分派的 load 按序取） |
| 出 | `lsu2rob_committed_store_pending` | `ccount != 0`（有已提交未退休的 store） |
| 出 | `lsu2iss_wake_valid / _wake_preg [2*LSU_LDU_COUNT]`、`lsu2iss_cancel_valid / _cancel_preg [LSU_LDU_COUNT]` | load 消费者的唤醒与取消：`[p]` 是 L2 推测唤醒，`[LDU+p]` 是 L3 寄存器写回的唤醒；现行配置 `LP_L2[3] = 0`，推测唤醒和取消恒为 0 |
| 出 | `lsu2exe_wb_req_* [LSU_LOAD_WB_WIDTH]` | load（和 SC）的写回：`valid`、`result`、`diag_val`（= vaddr）、`dest_preg`、`br_mask`、`rob_idx`、`dest_en`、`page_fault_load / _store`、`rob_defer`（推测：ROB 完成推迟）、`flush_pipe`（推测违例的最终写回）、`is_w`（`func3[1:0] == 2`，flw 数据要 NaN-box） |
| 出 | `lsu2exe_sta_wb_req_* [LSU_STA_COUNT]` | STA 完成（给 ROB）：`valid`、`result` = `diag_val` = vaddr、`br_mask`、`rob_idx`、`page_fault_store` |
| 出 | `lsu2dcache_load_ports_valid / _addr / _req_id [30:0] / _replay [LSU_LDU_COUNT]` | DCache load 请求；`req_id = {epoch[3:0], ldq[5:0]}`；`replay` = 该 LDQ 项上一次 DCache 响应不是 HIT（EXP-009 的过滤位，`lp_core` 的 `g_rpl`） |
| 出 | `lsu2dcache_store_ports_valid / _addr / _data / _strb / _l2 / _req_id [LSU_STA_COUNT]` | DCache store 请求；`_l2` 是同一行的第二个 store（`{strb, 字下标, 数据}`，strb 为 0 表示没有）；`req_id` 6 位 = 领头 store 的 STQ 项号 |
| 出 | `lsu2mmu_req_valid / _vaddr / _entry_idx / _is_store [LSU_AGU_PHYS]` | DTLB 请求，每个物理口一个，访问类型随请求走 |
| 出 | `peripheral_req_is_mmio / _wen / _mmio_addr / _mmio_wdata / _mmio_fun3` | MMIO 请求 |

模型里 `lsu2rob.tma.miss_mask`（TMA 统计用）RTL 没有对应端口。

## 4. 结构

```
 lsu ── lsu_pipe（端口打包成 lp_*_t 结构）── lp_core
                                              ├ L1：lp_l1（槽形成、DTLB 请求 / 响应） → lp_l1b（lp_cam ×4：部分地址 CAM，DCache 读请求，L1/L2 寄存器 pl12）
                                              ├ L2 / L3：lp_l2（每口的决定、STLF 确认）、lp_l3（L3 寄存器）、lp_wake（唤醒消费者）、lp_wb（写回口分配）
                                              ├ lp_ldq → lp_ldq_ent ×64（LDQ 表项状态机；lp_wk：停车 load 的唤醒；lp_ent_ms：推测）
                                              ├ lp_stq → lp_stq_ent ×64（STQ 表项状态机）、lp_ptr（STQ 指针、提交接受、退休）
                                              ├ lp_rp：重放寄存器（4 个 load、1 个 STA）
                                              ├ lp_ms / lp_mdp：访存推测的 STQ 视图和等待表
                                              ├ lp_drain → lp_wbuf → lp_wbstep ×4：已提交 store 的写缓冲和排空；MMIO store
                                              ├ lp_unc：未缓存单元；lp_rsv（+ lsu_lrsc）：LR / SC 预约
                                              └ lp_out：给分派 / ROB 的视图
```

文件表（33 个文件，行数为 `wc -l`）：`lsu.sv`、`lsu_pipe.sv`、29 个 `lp_*.sv`、`lsu_lrsc.sv`、`lsu_pkg.sv`（现在只用到其中的 `OW`、`SW`、`extract_data`、`store_strb`、`align_store_data`、`is_mmio_addr`，其余是旧 LSU 留下的类型和函数，已没人用）。

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `lsu.sv` | 136 | 顶层：只有端口和一个 `lsu_pipe` 实例 |
| `lsu_pipe.sv` | 248 | 平铺端口 ↔ `lp_*_t` 结构，实例化 `lp_core` |
| `lp_pkg.sv` | 395 | 常量（`NLD`…、`LP_CUT`、`LP_L2`）、LDQ 状态和各种结构类型、范围关系函数（`rel12 / rel32`）、STLF 确认函数 `stlf_confirm`、环旋转函数 |
| `lp_core.sv` | 433 | 连线：把下面各模块接起来；L2 / DCache 响应的写回选择；STA / STD 事件寄存（STAEV_REG） |
| `lp_l1.sv` | 313 | L1 槽形成：新 load / STA 占自己 AGU 的槽和 DTLB 口，重放按空闲槽 / 口分配；DTLB 请求（按物理口）和响应（按槽）；`pf_any` |
| `lp_l1b.sv` | 92 | 4 个 CAM 实例、DCache 读请求（`l1_launch`）、L1/L2 寄存器 `pl12_q` |
| `lp_cam.sv` | 76 | 一个 load 槽的部分地址 CAM：64 个比较器，结果是最年轻的可能冲突的老 store |
| `lp_ovl.sv` | 57 | 两个访问区间是否重叠（对数深度，W = 12 或 32） |
| `lp_l2.sv` | 89 | 每个 load 口的 L2 决定（读候选 store 的寄存器项做 STLF 确认），转发数据 |
| `lp_l3.sv` | 58 | L3 寄存器：L2 的直接完成晚一拍写回 |
| `lp_wake.sv` | 77 | 对 load 消费者的唤醒和（推测唤醒的）取消 |
| `lp_wk.sv` | 92 | 一个停车 load 的唤醒判断（事件 + STLF 确认） |
| `lp_ldq.sv` | 214 | LDQ 阵列：把各口事件译码成每项事件；MMIO load 挑选；MSHR_FULL 唤醒限额；各种向量视图；DCache 响应按（项号, epoch）匹配，同项旧请求的过期响应不会遮住当前请求的响应 |
| `lp_ldq_ent.sv` | 369 | 一个 LDQ 项：状态链（按模型阶段顺序施加事件）和字段 |
| `lp_ent_ms.sv` | 78 | 一个 LDQ 项的推测逻辑：SPD 推迟 / 释放、STA 到达时的违例检查 |
| `lp_ms.sv` | 66 | 推测用的 STQ 视图：最老的地址未知 store、本拍 STA 到达视图、每个 L1 槽能否越过未知 store、分派的等待表位 |
| `lp_mdp.sv` | 68 | 等待表（预测器）：查、训练、定期清零 |
| `lp_stq.sv` | 135 | STQ 阵列：事件译码、MSHR_FULL 唤醒限额、写缓冲的"已处理"位 |
| `lp_stq_ent.sv` | 269 | 一个 STQ 项：提交、DCache 响应、STD / STA 到达、DTLB 结果、排空资格 |
| `lp_ptr.sv` | 228 | STQ 指针（head、count、ccount）：提交接受、分配槽位、flush / 误预测截断、退休、各种窗口向量 |
| `lp_wb.sv` | 236 | 写回口分配：load 直接完成 > SC > WBP load；STA 完成；LR / SC 预约效果 |
| `lp_rp.sv` | 111 | 重放寄存器：4 个 load 重放寄存器（轮转 find-first 填充）、1 个 STA 重放寄存器 |
| `lp_out.sv` | 45 | 给分派 / ROB 的视图：空 LDQ 项、STQ 尾 / 空闲数 |
| `lp_drain.sv` | 56 | 已提交 store 的排空：写缓冲实例 + MMIO store（队首且为 MMIO） |
| `lp_wbuf.sv` | 245 | 写缓冲：决定哪些项发、插入已提交 store、领头 store 的响应 |
| `lp_wbstep.sv` | 82 | 写缓冲插入的一步（一个 store：跳过 / 并入 / 新开一项） |
| `lp_unc.sv` | 82 | 未缓存单元（同时只有一个 MMIO 请求） |
| `lp_rsv.sv` | 52 | LR / SC 预约的更新次序（LR 直接写回 → SC 清 → LR 由 WBP 写回），实例化 `lsu_lrsc` |
| `lp_ffs.sv`、`lp_ffs_p.sv`、`lp_pickn.sv` | 30、23、28 | 基元：find-first-set（`lp_ffs` 与 `LP_L2[9]` 相关）、带前缀或输出的 find-first、取最低 K 个置位 |
| `lsu_lrsc.sv` | 33 | LR / SC 预约寄存器（有效位、32 位地址、br_mask） |
| `lsu_pkg.sv` | 282 | 类型和函数；现在只用上面列出的几个，其余是旧 LSU 留下的 |

29 个 `lp_*` 共 4098 行，`lsu.sv` + `lsu_pipe.sv` 384 行，`lsu_lrsc` + `lsu_pkg` 315 行，合计 4797 行。

状态：LDQ 每项一个状态（4 位）和 `lp_ldq_t` 的字段（`rob_idx / rob_flag / br_mask / dest_preg / func3 / vaddr / pa_v / paddr / mmio / pf / lrsc / result / snap_idx / snap_flag / rcause / blk / rwait / rtype / epoch / spec / vio / second / wait_b / mdp`，其中 `snap_idx / snap_flag` 是分派时 STQ 的尾，即"比这个 load 老的 store 到哪里为止"）；STQ 每项 `lp_stq_t`（`va_v / pa_v / data_v / pf / mmio / lrsc / sc_pass / suppress / trp / wbp / wbd / cmt / iss / mmw / done` 各 1 位，加 `vaddr / paddr / data / func3 / dest_preg / rob_idx / rob_flag / br_mask / rtype / rwait`）；STQ 指针 `head_q / head_flag_q / count_q / ccount_q`；`pl12_q [4]`（L1/L2 寄存器）；L3 寄存器；`rp_v_q / rp_ldq_q [4]` 与 `rp_ptr_q`（轮转指针）；`srp_v_q / srp_stq_q` 与 `srp_ptr_q`；STA / STD 事件寄存；写缓冲 `ent_q [4]` 和年龄矩阵 `lt_q`；未缓存单元；LR / SC 预约；等待表 `tab_q [64]`、`trn_q [64]`、清零计时器。

## 5. 一拍内的数据流

### 5.1 阶段与模块的对应

模型一拍里按固定顺序调用各阶段，后面的阶段看到前面阶段的写（`pnxt`），RTL 是并行的组合逻辑，次序体现在 LDQ / STQ 表项内部的"状态链"里：`lp_ldq_ent` 按模型的顺序依次施加事件（MMIO 响应 → L2 决定与 DCache 响应 → 写回释放 → AGU 到达 → DTLB 结果 → MMIO 发射 → 分配 → flush 杀死 → 发射计 epoch → 唤醒 → 重放寄存器挑选）。RTL 源文件注释里用 P1…P14 编号这些步骤（编号来自旧文档 docs/analysis/lsu-pipe.md 第 2 节的表），本文用模型的函数名：

| 模型阶段（函数） | 做什么 | RTL |
| --- | --- | --- |
| `comb_outputs`（`cal / lsu2dis / lsu2rob`） | 拍首视图：空项、STQ 尾、`committed_store_pending`；清 L1/L2、L3 寄存器；等待表的训练和写入 | `lp_out`；`lp_mdp` |
| `comb_writeback`（`stq_commit / mmio_in / dcache2lsu / lsu2exe`） | ROB 提交的 store 记为已提交；MMIO 响应；DCache load / store 响应、L2 决定（STLF 确认）、停车 / 重放；load 与 STA 写回 | `lp_ptr`（`cm_go`）、`lp_stq_ent`；`lp_unc`、`lp_ldq_ent`；`lp_l2`、`lp_l3`、`lp_ldq_ent`、`lp_stq_ent`；`lp_wb` |
| `comb_translate`（`exe2lsu / tlb / stlf`） | STD 写入、STA / load 地址到达、DTLB 请求与响应、部分地址 CAM、MMIO load 发射 | `lp_stq_ent`、`lp_ldq_ent`；`lp_l1`、`tlb_mmu`；`lp_l1b` / `lp_cam`；`lp_ldq` 的 MMIO 挑选 |
| `comb_requests`（`dis2lsu / flush / lsu2dcache / mmio_out / check`） | 分配；flush / 误预测 / 掩码清除；DCache 读请求与 L1/L2 寄存器；store 排空；MMIO 请求；STQ 退休、停车 load 的唤醒、重放寄存器填充 | `lp_ptr`、`lp_stq`、`lp_ldq`；各模块的 flush 输入；`lp_l1b`；`lp_drain`；`lp_unc`；`lp_ptr`、`lp_wk`、`lp_rp` |

### 5.2 load 流水线：L1

1. **AGU 结果到达（L1 的第一步）**：新 load 的 AGU 结果必须同时满足"LDQ 项号对得上、`rob_idx / rob_flag` 与该项登记的相同"才被接受（`lp_ldq_ent` 里的 `ag_acc`，每项自己比较，接受后项状态置 `LS_PIPE`，写入 vaddr、dest、func3、`snap_idx / snap_flag`、LR 标记）。
2. **槽和 DTLB 口**（`lp_l1`）：L1 槽 k 就是 AGU 口 k，新 load 在自己的槽、占自己的 DTLB 口，不按接受与否压缩。重放寄存器里的 load 找空闲的槽（该 AGU 槽寄存器里没有 uop，`occ` 为 0）；重放需要 DTLB（`rp_pipe && !pa_v`：项还在 PIPE 且物理地址未知）时还要占一个 load 能用的空闲 DTLB 口（口 0..3 里没有被新请求占用的），没有就继续留在重放寄存器里。这个分配是一条走过 4 个重放寄存器的短链，用温度计码计数器（`sr_t / pr_t / ut_t`）实现：第 j 个要 DTLB 的重放拿第 j 个空闲口。STA 重放寄存器拿 STA 能用的最低空闲口（口 2、3、4 中未被新请求和 load 重放占用的）和最低的空闲 STA 槽。占用用 `occ`（flush / 误预测杀死之前），所以分配不依赖接受检查和 flush。
3. **DTLB 请求按口建**：口 q 的请求是该口 AGU 的新请求，或拿了该口的重放（`mmu_req_valid / _vaddr / _idx / _st`），请求带自己的类型（load 或 store）。响应按槽取回：槽 k 读它所用口的响应，`resp_ok = valid && entry_idx == 槽的 ldq`；命中 → LDQ 项写 `pa_v / paddr / mmio`；缺页 → 写 `pf`、`result = vaddr`；其他 → 未命中（`TLB_MISS`）。已知物理地址的重放（`need_tlb = 0`）直接用 LDQ 里存的 paddr / mmio。
4. **部分地址 CAM**（`lp_l1b` 里每个槽一个 `lp_cam`，64 个比较器，每个用 `lp_ovl`）：候选 store = 在 load 之前（`snap` 与 `head` 在 2N 标号环上的距离，被 `count` 截断）、没被取消（`suppress`）、且（地址未知且 load 不能越过它，或地址已知且重叠，重叠用页内偏移 + 大小比较）。重放且物理地址已知时，对已有物理地址的 store 改用 32 位全地址比较（读重放登记的 paddr）。取最年轻的候选（旋转到以 head 为 0 号，反向 find-first）：`cand_v / cand`。越过的地址未知 store 中比候选更年轻的存在时 `unk = 1`，写入 LDQ 项的 `spec`。本拍到达的 STA 的地址通过 STQ 项的视图 `cv_va / cv_voff / cv_f3` 旁路进 CAM。
5. **DCache 读请求**：`l1_launch = 槽有效 && 地址可用（命中或已知） && !mmio && !cand_v && !load_retry_busy[口]`；`dcl_req_valid = l1_launch && 该 LDQ 项在 flush / 误预测之后仍存活`（`pipe8_sel`）；`req_id = {epoch_nx, ldq}`，每次发请求 epoch 加 1，之后只接受 epoch 相同的响应。`dcblk = 命中 && !mmio && !cand_v && load_retry_busy`：不发请求，L2 按冲突停车。
6. **L1/L2 寄存器 `pl12_q[k]`**：`v`（槽有效且项存活）、`ldq`、`epoch`、`tlb`（0 命中 / 1 未命中 / 2 缺页）、`mmio`、`cand_v / cand`、`dcblk`；RTL 额外带 `paddr / voff / func3`，L2 不再读 LDQ。

### 5.3 load 流水线：L2 与 L3

1. **L2 决定**（`lp_l2`，每口一个，要求 LDQ 项仍是 `LS_PIPE` 且 epoch 相同，否则这个结果被丢弃）：缺页 → `L2_WBD`（直接完成，带缺页）；`TLB_MISS` → 停车 `RC_TLB`；`mmio` → `LS_MMW`；无候选 且 `dcblk` → 停车 `RC_DC`（等待 0）；无候选 → `LS_DCW`（等本拍或之后的 DCache 响应）；有候选 → 读候选 store 的**寄存器项**做 STLF 确认（用全物理地址）：store 已没了 / 被取消 / 地址不重叠 → `LS_RDY`（重放，此时完整比较会排除它）；还没有地址（无 va，或有 va 没有 pa 且页内偏移无法证明不重叠） → 停车 `RC_ADDR(blk = cand)`；部分重叠、或未决的 SC → `RC_HOLD`；盖住但数据没到 → `RC_DATA`；盖住且数据在 → `L2_WBD`，转发数据 = `extract_data(store 数据, 偏移, func3)`。
2. **DCache 响应**（`dcl_valid && !req_id[31]`，按 `req_id` 的低 6 位找 LDQ 项，要求项处在 `LS_DCW` 且 epoch 相同）：HIT → 直接完成（数据按 LDQ 项的 paddr 偏移和 func3 从响应里取）；该口本拍已被 L2 的直接完成占用时改为 `LS_WBP`；CONFLICT / MSHR_HIT / MSHR_FULL → 停车 `RC_DC`，等待拍数 `replay_wait`（MSHR_HIT 和 MSHR_FULL 为 `RWAIT = 4`，CONFLICT 为 0）。
3. **L3 寄存器**（`LP_L2[0] = 1`，`lp_l3`）：直接完成不在 L2 同拍写回，进 L3 寄存器（项状态 `LS_WB3`），下一拍由 `lp_wb` 分配写回口、释放 LDQ 项、更新 LR 预约；被杀的 load 因为项不再是 `LS_WB3` 而丢掉。
4. **写回口分配**（`lp_wb`）：load 口 p 上依次是：口 p 自己的直接完成（来自 L3 寄存器）、SC 结果（占空闲口，口号升序）、WBP 的 load（LDQ 号最低的优先，占剩下的口）。`LP_L2[6]` 限制每拍最多一个 SC 完成。写回内容来自 LDQ 项（`rob_idx / dest_preg / br_mask / vaddr`；缺页的 load 不写目的寄存器、`result = vaddr`）；LR 写回时把物理地址写进预约。
5. **对消费者的唤醒**（`lp_wake`，`LP_L2[1] = 1`）：从 L3 寄存器写回的 load 在发出写回请求的同一拍唤醒消费者（`lsu2iss_wake_valid[LDU + p]`），条件：目的寄存器非 0、不是缺页、不是第二遍写回（`second`）、没有 flush、没被误预测杀死。WBP 写回的 load 不经过这里（isu 的唤醒网络另有 PRF 写回口一侧的 load 唤醒 `prf_awake_*`，见 isu.md 第 3 节，本文没有核对它的来源）。推测唤醒（`LP_L2[3]`）和取消在现行配置下关闭，代码保留。

### 5.4 停车、唤醒和重放

1. **唤醒事件**：本拍的 STA 到达 / DTLB 结果（`ev_sta`）、STD 写入（`ev_data`）、STQ 退休（`ev_ret`）、SC 判决（`ev_sc`）。STA / STD 事件（模型 `CFG_LSU_STAEV_REG`）和广播视图（`sta_info`：STQ 项在本拍 DTLB 结果和 STD 之后的 `va_v / voff / func3 / pa_v / paddr / data_v / hold_sc / suppress / data`）先进寄存器，停车的 load 晚一拍被唤醒；退休、SC 事件和"项是否存活"的判断不晚。
2. **每项的唤醒**（`lp_wk`，每个 LDQ 项一个）：`RC_ADDR` 在 `ev_sta || ev_ret` 时对阻挡它的 store 做同样的 STLF 确认：不重叠 → `LS_RDY`；部分重叠 → 改成 `RC_HOLD`；数据没到 → 改成 `RC_DATA`；可以转发 → `LS_WBP` 并把转发值存入 `result`；仍无地址 → 不动。`RC_HOLD`：store 退休或 SC 判决 → `LS_RDY`。`RC_DATA`：STD 写入该 store → `LS_WBP`（值从那个 STD 口取）；store 先退休 → `LS_RDY`。`RC_TLB` / `RC_DC`：`rwait` 每拍减 1，减到 0 → `LS_RDY`；`RC_DC` 还可被填充事件提前唤醒：`MSHR_HIT` 且填充行号等于 load 的行号；`MSHR_FULL` 在填充事件拍，只让最低的 `NLD` 个候选（拍首已停车的）被唤醒。`LP_L2[8]` 打开：本拍刚在 L2 停车的 load 的唤醒按口（4 个单元）算，不再串在 L2 决定之后每项算一遍（等价，不改周期）。
3. **重放寄存器**（`lp_rp`）：`LS_RDY` 的项（现行 `LP_CUT[2] = 1`：只看拍首寄存的 RDY 位，本拍刚被唤醒的项下一拍才被挑；关掉该位则本拍唤醒的也算）按轮转指针 `rp_ptr_q` 旋转后用 find-first 挑最低的 4 个，第 j 个空闲的重放寄存器拿第 j 个；被挑中的项当拍进入 `LS_PIPE`，号码存进寄存器，指针 = 最后一个被挑中的号 + 1。下一拍寄存器里的 load 被 L1 的空闲槽消费（`rp_cons`），该项已死则清除。轮转是为了防止两个总在页表遍历上失败的 load 占满重放寄存器，让遍历的拥有者饿死（模型 `docs/LSU_PIPE.md` 第 4.3 节）。重放与新 load 没有优先级，新 load 先占槽。
4. **STA 重放寄存器**：STQ 项在 DTLB 未命中时置 `trp`；`lp_rp` 在这些项（且存活）里也用轮转指针（`srp_ptr_q`）找"不小于指针的第一个，否则全体第一个"，装进 `srp`，下一拍拿到空闲 STA 槽和口就重新请求 DTLB（只有仍有 `va_v && !pa_v && !pf` 的才请求）。

### 5.5 STQ：分配、STD / STA、提交、退休

1. **分配**（`lp_ptr`）：第 i 个 store 请求落在 `head + count + (它前面的请求数)`（前面的请求数是 popcount），表项被整体改写；`count` 增加。
2. **STD**：STD 口 k 写入"STQ 项号相同且 `rob_idx / rob_flag` 与登记相同"的项（`sd_hit`），置 `data_v`；若物理地址已有，置 `wbp`（STA 完成待发）。
3. **STA**：同样要求 ROB 号匹配才接受（`sa_acc`），写 `va_v / vaddr / func3 / lrsc / dest_preg`、清 `pa_v / paddr / trp`，本拍就进入 CAM 视图（旁路）。DTLB 结果：命中 → `pa_v / paddr / mmio`（数据已到则 `wbp`）；缺页 → `pf`，`wbp`（不带数据完成）；未命中 → `trp`。
4. **STA 完成**（`lp_wb`）：`wbp && alive` 的非 SC 项里取最老的 3 个（从 head 起旋转后取最低 3 个），经 `lsu2exe_sta_wb_req_*` 报给 EXU / ROB，置 `wbd`；SC 项走空闲的 load 写回口，结果 0（预约有效且地址相同，成功）或 1，缺页时 `result = vaddr`。
5. **提交接受**（`lp_ptr`，`LP_CUT[6]`）：提交口里的 store（type 6，或 type 18 且 `amo_op != LR`）：同一个提交组里的 store 在 STQ 里是连续的，所以只要第一个 store 的 STQ 号等于提交指针 `head + ccount`，并且组里每个 store 的 `wbd` 都已置位（前缀），就都接受，`ccount` 增加（上限 64）。被接受的项置 `cmt`；如果同拍有 flush 决定（`rob_flush_now`）或是失败的 SC，则同时 `suppress + done`（不写出）。
6. **退休**（`lp_ptr`）：队首起最多 4 个 `done` 的 store 离队（`LP_CUT[1]` 打开：只看拍首寄存的 `done`、`ccount`、`count`），`head` 前进，`count`、`ccount` 减少，产生 `ev_ret`。
7. **缺页 store**：随 ROB 的 flush 提交，被 `rob_flush_now` 变成 `suppress + done`，不会写出。

### 5.6 已提交 store 的排空（写缓冲）

1. **资格**（`lp_stq_ent` 的 `d_elig / d_rdy`）：`win13` 窗口内（只看拍首已提交的，`LP_CUT[13]`）、已提交、未 `done`、未在途（`iss`）、不在 MMIO 总线上。`rwait` 每拍倒数（所有符合条件的项同时倒），`d_rdy = rwait <= 1`。MSHR 填充事件把 `MSHR_HIT`（同行）或 `MSHR_FULL`（从 head 起最老的 3 个）的 store 的等待清零；`MSHR_FULL` 的清零排空要晚一拍才看到（`LP_CUT[4]`）。
2. **写缓冲**（`lp_wbuf`，`NWB = 4` 项，每项最多 2 个同一缓存行（`paddr[31:6]`）的 store，第一个是领头者，第二个是跟随者）：
   - **发送决定只读寄存器**：项有效、尚未发出、里面所有 store 都 `d_rdy`、没有被更老的有效项按字节重叠挡住（只比项与项之间），则候选；候选按年龄（年龄矩阵 `lt_q`）依次拿空闲的 DCache store 口（口 0、1 里没有 `store_retry_busy` 的，`NDR = 2`）。请求带领头 store 的地址、对齐后的数据、字节使能和 `req_id = 领头 store 的 STQ 号`；有跟随者时 `req_l2` 带第二个 store。发送时 STQ 项置 `iss`，跟随者记下 `mf / ml`（跟随的是哪个领头者），领头者的响应就是它的响应。
   - **插入在发送决定之后**：已提交且还没被缓冲处理过的 store（`cmt && !wbi`）取最老的 4 个（`NINS`），依次由 4 级 `lp_wbstep` 处理：MMIO 或已 `done` 的直接标为已处理，不进缓冲；能并入"本拍刚新开的那一项"（同一行、可合并（不是 LR / SC）、该项还没有第二个 store）就并入；否则在空闲项里新开一项；缓冲满则本批停止，后面的 store 留在 STQ 里等。（并入寄存的、拍首已有的尾项这条路径被去掉了，因为它依赖较晚的发送决定，对应模型 `CFG_LSU_WBMERGE_REG = 1`。）
   - **响应**：领头者的响应 HIT → 项释放，STQ 里领头者和跟随者变 `done`；其他 → 项变回"等待"，store 按 `rtype` 设等待拍数后重发。
3. **MMIO store**（`lp_drain`）：只有队首、`d_elig`、是 MMIO 且未缓存单元空闲时，拿未缓存单元，STQ 项置 `mmw`。

### 5.7 访存相关性推测

1. **越过未知地址的 store**：load 在 L1 的 CAM 里可以越过"地址未知的老 store"，条件（`lp_ms` 的 `spec_ok`）：不是 LR、不是第二遍、等待表位为 0。越过时 LDQ 项记 `spec`。
2. **第一次写回推迟 ROB 完成**：`spec` 的 load 写回时（任一条路径；非缺页、非 MMIO、非 LR、非第二遍）写回照常发出（消费者拿到值），但带 `rob_defer`（ROB 不把它记为完成），LDQ 项不释放，进 `LS_SPD`（如果已知违例则进 `LS_RDY`、`second`）。
3. **释放**：`LS_SPD` 的项在"没有比它老的地址未知 store"（`unk_any` 为 0，或它的 older 数不超过最老未知 store 的 rank）时回到 `LS_WBP`，做第二次写回（`second`，释放 ROB 完成；若 `vio` 则带 `flush_pipe`，ROB 把它当作一条要冲刷后续的指令）。
4. **违例检查**（`lp_ent_ms`）：每个 `spec` 且未违例的项（状态在 PIPE / DCW / WBP / WB3 / SPD / RPW）与本拍到达的每个 STA 比较：STA 的 STQ 号在 load 的 older 范围内（rank 小于 older 数）且页内偏移 + 大小重叠 → `vio`；已在 `LS_SPD` 的转 `LS_RDY` 并置 `second`（重新执行，不再推测）。违例的 load 在 `trn_q` 里被标记。
5. **等待表**（`lp_mdp`）：64 项 × 1 位，分派时按 load PC 的索引读（置位的 load 不越过未知 store）；违例的 load 在寄存器里标记，每拍最低的一个仍存活的被标记项写入表（违例后两拍写入）；每隔 `LSU_MDP_CLR = 2000` 拍，在下一次有 load 分派的那拍把表清零（那拍的读已看到清零后的表，那拍的训练保留）。

### 5.8 MMIO 与 LR / SC

1. **未缓存单元**（`lp_unc`）：同时只有一个 MMIO 请求。MMIO load：LDQ 项在 `LS_MMW`（拍首已在该状态）、是 ROB 里最老的未完成指令（`rb_hi_*` 优先，否则 `rb_head_*`）、它的 STQ 快照等于 STQ 头（前面没有未退休的 store）、单元空闲 → 拿单元，项变 `LS_MMR`；外设响应到达（`peripheral_resp_is_mmio && 单元有效`）→ 数据进 `result`，项变 `LS_WBP`（该拍就可以被写回，`LP_CUT[17]`）。MMIO store：见 5.6。请求输出 `peripheral_req_is_mmio = periph_ready && valid`。flush 只保留还在窗口内且在总线上的 store；误预测杀死对应的 load（项已空）或窗口外的 store。
2. **LR / SC**（`lp_rsv` + `lsu_lrsc`）：一个预约寄存器（有效、32 位物理地址、br_mask）。LR 写回时（L3 路径或 WBP 路径）置位，地址 = LDQ 项的 paddr；任何 SC 完成都清；任何 load 或 store 缺页（`pf_any`）清；误预测且 br_mask 命中清；`clear_mask` 清掉 br_mask 里的位。SC 的成功判定取拍首寄存的预约（地址相等且有效）；失败的 SC 被 `suppress`，不写出。

### 5.9 flush、误预测、掩码清除

- `rb_flush`（已晚一拍）：所有 LDQ 项清空；STQ 的 `count` 保留 `min(ccount, count)`（已提交的 store 必须写出）；重放寄存器里的死项清除；未缓存单元只保留还在窗口且在总线上的 MMIO store。**本拍刚做出的** flush 决定（`rob_flush_now`）只用于上面 5.5 第 5 点。
- `dec_bcast_mispred`（不晚）：LDQ 里 `br_mask & dec_br_mask != 0` 的项清空；STQ 在第一个命中的项处截断（已提交的不会被截，因为提交的 store 都比任何还没解决的分支老）；预约、重放寄存器同样处理。
- `clear_mask`：所有存活项的 `br_mask &= ~clear_mask`。
- 被杀的 load 在 L1 / L2 里的结果由"项不再是期望状态"或 epoch 不符丢弃；残留的 DCache 响应同样靠 epoch 过滤。

## 6. 关键路径与深度

单模块综合（通用门代理，`SYNTH_ABC` 的结构深度，提交 312e6f8 说明里是 no-dc2 代理）：`lsu` **100 层**。最长路径（协调者给的实测）：LDQ 项状态 → L1 重放分配（`rp_need → rp_ok` 这条走过 4 个重放寄存器的链）→ L1 的 CAM（`lp_cam`、`lp_ovl`）→ DCache 请求的 `req_id`。在最近几次修改之前，最长路径是另一条：LDQ / STQ 的提交窗口 → 写缓冲插入链（已被下表的 `lp_wbstep` 等改动去掉）。

从代码读出的其他长链（**未综合验证**）：

| 链 | 从代码读出的路径 |
| --- | --- |
| AGU → DTLB → STQ | EXU 的 AGU 结果 → 每口的 vaddr 选择（`lp_l1`）→ `tlb_mmu`（单模块 67 层）→ `tl_s` → `lp_stq_ent` 的 `paddr8 / wbp8` → `vw`；之后进 STAEV_REG 寄存器（链在这里被切断） |
| 停车 load 的唤醒 | 寄存的 `sta_info_w` → `lp_wk` 的 `stlf_confirm` → `ew` → `lp_ldq_ent` 的 `st9` → `rdy9` → `lp_rp` 的旋转 + 4 次 find-first → `rp_pick` → LDQ 状态 |
| L1 CAM | 槽的 `vaddr / func3`（经重放分配选出）→ 64 个 `lp_ovl` → `hit` → 旋转 + `lp_ffs_p` → `cand_v / cand` → `l1_launch` → `dcl_req_valid / req_id` |
| 提交与 STQ 窗口 | `cm_valid / cm_stq_idx` → `lp_ptr` 的 `cm_match` → `ccount_cm` → `count_flushed` → 各窗口向量；`LP_CUT` 的 B、R、12、15、13 位把这些链改成只读寄存器 |
| 写回 | `sq` → `lp_wb` 的 `lp_pickn` → 写回口选择 → `wb_result` |

本分支里降深度的改动（均不改变周期，周期等于对应的模型参考表）：

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| L1 槽 k 就是 AGU 口 k | `1597a66` | 重放按空闲槽 / 口分配，不再等接受检查（含 flush） |
| STAEV_REG | `c24861f` | STA / STD 事件和广播视图先进寄存器，切断"DTLB 结果 → STQ 更新 → 唤醒确认"的链 |
| 按 AGU 占用分配重放 | `e49618c` | 重放的槽 / 口分配看 `exe2lsu_*_req_occ`（flush / 误预测杀死之前） |
| load 授权按空闲数 | `64a908e` | 分派 / `lp_ptr`：load 授权只看空闲数，flush / 误预测周期的 STQ 指针更新用寄存的 `count` 和 `br_mask`，请求前缀数用 popcount |
| `lp_l1b` 的 CAM 读 `paddr_reg` | `0a522a6` | 全地址比较读重放登记的 paddr，去掉从 DTLB 响应到 CAM 的从未真正用到的结构路径 |
| `lp_ptr` / `lp_rp` | `7ddf8df` | 提交接受从"第一个命中提交指针的 store"出发；STA 重放挑选不旋转请求向量 |
| `lp_wbstep` | `ed53054` | 写缓冲只并入本拍新开的项（模型 `CFG_LSU_WBMERGE_REG`） |
| `lp_ovl` | `312e6f8` | load 的高位地址同时与 store 的高位和它的邻居（+1、-1，由 store 侧算好）比较，late 的 load 一侧没有前缀；`lsu` 106 → 100 |
| DTLB 口按物理口建请求、重放分配用温度计码 | `5433a62` | `lp_l1` 深度代理 56 → 46（该提交说明） |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- DCache 响应看门狗（`wd_t`，62 拍后重发）：RTL 没有，所以参考周期用 `LSU_PIPE_NOWD=1` 生成（`scripts/linux_gate.sh` 的 `TM_ENV` 默认值也是它）；RTL 靠 DCache 的 `*_retry_busy` 位避免饿死；
- `miss` 字段和 `lsu2rob.tma.miss_mask`（TMA 统计）；统计计数器、调试打印（`print_events`，RTL 有 tb 里的对应打印 `SOC_TB_LSUEVT`）；
- 访存推测的"陈旧值"功能路径（`MsData`、`ms_ldq_ / ms_stq_`、`atnt`、`cam_val`）：模型没有真实数据，要从功能模型的事实里补；RTL 数据是真的，不需要；
- `comb_commit_store`（给外设模型看已提交 store）：只在模型里；
- `MemDepPred` 的 PC 哈希在模型里由 LDQ 项的 `pc()` 算；RTL 在 `pre_idu_queue` 里算好随分配送进来（`dis2lsu_ldq_mdp`，表达式与模型 `MemDepPred::idx` 相同）；
- 模型里 `dis2lsu` 对 `stq_flag` 和 `count >= STQ_SIZE` 的检查（跳过分配）：RTL 没有，分派按 `lsu2dis_*` 给的尾和空闲数分配（依据是 docs/analysis/lsu-pipe.md 第 6 节，"不可达"这个判断本文没有重新验证）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- 违例检查包含停车（`LS_RPW`）的 load：停车的 load 被唤醒后直接从阻挡它的 store 转发，不再过一遍 CAM，所以会漏掉它越过的更年轻的 store，检查必须覆盖它；
- `rb_flush` 和 `FLUSH_REG`：LSU 里其他模块用晚一拍的 flush，store 提交限定用本拍的 `rob_flush_now`；
- 重放的槽和口分配看 AGU 的占用，不看接受结果，模型对应 `ExeLsuReqEntry::raw`。

配置相关：RTL 的参考周期表是 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`，它的首行说明累计的模型开关；其中与 LSU 有关的是 `CFG_AGU_SHARED=2`、`CFG_LSU_SLOT_FIXED=1`、`CFG_LSU_STAEV_REG=1`、`CFG_FLUSH_REG=1`、`CFG_LSU_WBMERGE_REG=1`（这几个在模型 `include/config.h` 里默认都是 0，所以用默认配置的模型生成的周期与 RTL 不同）。RTL 的 `LSU_AGU_SHARED` 等在包里是常量，不是可选路径；`ttg_cfg_pkg.sv` 的文件头写着由 `gen_cfg_pkg.py` 生成、不要手改，isu.md 里说它目前是手工编辑的、与生成的不同步，本文没有核对这一点。

在代码里看到的可疑点（只记录，没有改）：

- `lp_l1.sv` 文件头注释仍写"accepted AGU loads are compacted into the first load slots"，与现行的"槽 k = AGU 口 k"不符；
- `lp_pkg.sv` 的常量 `NDC`（"committed-store drain candidates"）没有任何地方使用；
- `lp_stq_ent.sv` 末尾 `ent_q.rwait <= dr_pick ? rw13 : rw13;` 两个分支相同；
- `lp_dis_st_t.func3` 恒为 0（`lsu_pipe.sv` 写 `'0`），STQ 项的 `func3` 在 STA 到达时才被真正写入；`lp_dis_ld_t.wait_b` 在 `lsu_pipe.sv` 里写 0，之后被 `lp_ms` 用等待表位覆盖；
- `lp_ffs.sv` 有两种实现（`LP_L2[9]`），但 `ttg_first_set` 本身已经是对数深度的前缀或（提交 1d8688e），两种现在等价，选择位多余；
- `lp_mdp.sv` 只有一个训练口，而 `RTL_MEMSPEC_NOTES.md` 写的是两个（该文件是分支记录，已过时）；
- `lsu_pipe.sv` 里端口列表中间的 `/* verilator lint_on UNUSEDSIGNAL */` 没有对应的 `lint_off`（在 `lsu.sv` 里 off / on 成对）；
- 模型里 `PLdq.illegal`（F/D 的非法 load）和写回的 `illegal_inst`、`is_mmio`：RTL 的 LSU 没有对应字段，F/D 非法指令在 RTL 里的处理在别处（`ren` / `dispatch` / `csr` 里有 `illegal`），本文没有核对 LSU 是否需要这一位；

未核对（继承自旧文档，或来自旧分析文档、本次没有在代码里验证）：

- DCache 一侧为分级 LSU 做的两处改动（隐藏重试口的 bank 授予顺序、`rty_valid_q` 输出）：来自 docs/analysis/lsu-pipe.md 第 3 节，本文只核对了 LSU 一侧使用 `*_retry_busy`；
- `LP_CUT` 中不属于模型七个冻结位（B、R、D、F、G、H、FM）的各位"周期等价、只为深度"：来自 `lp_pkg.sv` 注释和 lsu-pipe.md，本文逐位读了它们的位置，没有逐项证明等价；
- 旧文档 `docs/modules/lsu.md`（旧 LSU 的设计笔记）的全部内容没有采用。

## 8. 验证

- **整核门禁**：`scripts/fm_gate.sh <soc_tb> <outdir>`，67 个程序（`scripts/ref_cycles_memiq6_nr_int2_ev5.txt`），每个程序在 RTL SoC 上做逐条提交对功能模型的检查，周期对比参考表（模型同配置生成）。访存相关的程序有：`atomic-boundary`、`dcache-conflict-writeback`、`dcache-mshr-pressure`、`directed/memspec_addr / memspec_data / memspec_pf / memspec_vio`（`programs/directed/`，推测、缺页 load 的目的寄存器、违例重放）、`load-store-aligned`、`memory-boundary`、`memory-stress-small`、`pf-stress`、`stlf-overlap-boundary`、`timer-mmio`、`trap-precise-store`、`unalign`、`coremark`、`dhrystone`。最近一次改 LSU 的提交（312e6f8）的说明写 67/67、周期相等。本次没有重跑。
- **Lint**：`scripts/lint_chip.sh`（整芯片 Verilator -Wall），提交说明里写 0 告警；`scripts/lint.sh rtl/backend/lsu` 逐目录。
- **Linux**：`scripts/linux_gate.sh`（从复位启动，RTL 对模型，PMU 序列和 FM 检查，约 1.4 亿周期，用 `scripts/build_soc64_linux.sh` 的 4 线程 testbench）；`scripts/linux_segments_cmp.sh`（检查点窗口，RTL 对模型，较快的 Linux 门禁）。
- **定位工具**：testbench 的 `SOC_TB_LSUEVT=1` 打印每拍的 LSU 边界事件（写回、DCache 请求、DTLB 请求等，`tb/soc/soc_tb.cpp`），与模型的 `LSU_PIPE_EVT` 同格式；`scripts/first_diff.sh`（第一处提交 / 周期分歧）、`scripts/align_check.sh`（PMU 序列对齐）。
- **没有模块级的独立测试**：旧体系的 trace 回放 + 随机 trace + 变异检查已随 `spec/` 一起退役。`lp_ovl.sv` 文件头写着"对 `rel12 / rel32` 做过随机等价测试"（提交 312e6f8 的说明写 20M 向量），但这个测试不在仓库里（`tests/` 下没有）。**待补**：`lp_ovl`（新旧并排随机）、`lp_cam`（对模型 `stq_cam`）、`lp_wbuf` / `lp_wbstep`（对模型 `wb_insert`）、`lp_rp`（重放分配）各一个独立的随机测试，后续改深度时用；MMIO、LR / SC、缺页 store 的定向程序（`tests/rv64/mmio64.c` 是 rv64 MMIO 定向程序，但不在 fm_gate 的 67 个程序里，是否有脚本在跑它本文没有核对）。

## 9. 参数与开关速查

`LSU_MEMSPEC`、`LSU_MDP_BITS`、`LSU_MDP_CLR`、`LSU_AGU_SHARED`、`LSU_AGU_PHYS`、`LSU_PEPLAY_WAIT_CYCLES`、`LDQ_SIZE`、`STQ_SIZE`（`ttg_cfg_pkg`）；`LP_CUT`、`LP_L2`、`NRP`、`NDR`、`NRET`、`NWB`（`lp_pkg`）；`NINS`（`lp_wbuf`）。

**`LP_CUT`（262143 = 0 到 17 位全 1）**：18 个关键路径切点。名字取自 `lp_pkg.sv` 的注释和代码位置；模型把其中七个改变周期的切点冻结成固定行为（B、R、D、F、G、H、FM，模型的位号与 RTL 的位号不同），其余为 RTL 单独的切点。

| 位 | 名 | 作用（位于） |
| --- | --- | --- |
| 0 | B | 唤醒确认用拍首存活窗口去掉本拍退休（`lp_core` 的 `alive_post` 入参） |
| 1 | R | STQ 退休只读寄存的 `done / ccount / count`（`lp_ptr`） |
| 2 | D | 重放寄存器只挑拍首寄存的 RDY 位（`lp_ldq_ent` 的 `rdy9`） |
| 3 | F | WBP 写回只挑拍首寄存的 WBP 位（`lp_core` 的 `wbp_sel`） |
| 4 | G | 排空看不到本拍 MSHR_FULL 唤醒（`lp_stq_ent` 的 `rw5g`） |
| 5 | E1 | 重放寄存器的项状态检查用寄存值（`lp_core` 的 `rp_pipe`） |
| 6 | A | 提交接受的并行形式（`lp_ptr`） |
| 7 | E2 | 重放寄存器清除用 `dead_r`（`lp_rp` 的 `empty8` 入参） |
| 8 | C1 | 误预测不截已提交 store（`lp_ptr`） |
| 9 | C2 | 本拍提交的 store 没有重放等待（`lp_stq_ent`、`lp_ptr` 的 `win4`） |
| 10 | E3 | MMIO 发射用 `st3`（`lp_ldq_ent` 的 `mmw_ok`，被 `LP_L2[5]` 覆盖） |
| 11 | E4 | 唤醒作用于 `st3 && !dead_r`（`lp_ldq_ent` 的 `rpw_a`） |
| 12 | E5 | `alive_post` 不过计数链（`lp_ptr`） |
| 13 | H | 排空只看拍首已提交的 store（`lp_ptr` 的 `win13`、`lp_stq_ent`） |
| 14 | E6 | 未缓存单元的 load 空判断用 `dead_r`（`lp_core`） |
| 15 | E7 | `alive_fl` 不过计数链（`lp_ptr`） |
| 16 | E8 | epoch 和 `pipe8` 用 `~dead_r`（`lp_ldq_ent`、`lp_core`） |
| 17 | FM | 本拍 MMIO 响应的 load 本拍可写回（`lp_core` 的 `wbp_sel`） |

**`LP_L2`（1907 = 位 0、1、4、5、6、8、9、10 为 1）**：

| 位 | 名 | 现行 | 作用 |
| --- | --- | --- | --- |
| 0 | a | 1 | L3 寄存器：L2 的直接完成晚一拍写回 |
| 1 | a2 | 1 | 从 L3 寄存器写回的 load 在写回请求的同一拍唤醒消费者 |
| 3 | d | 0 | L2 推测唤醒，下一拍不是 HIT 则取消 |
| 4 | F | 1 | 本拍刚得到 MSHR_FULL 的 load 不被本拍的填充唤醒 |
| 5 | M | 1 | 本拍在 L2 变成 `LS_MMW` 的 MMIO load 晚一拍发射 |
| 6 | S | 1 | 每拍最多一个 SC 完成 |
| 8 | W | 1 | 本拍停车的 load 的唤醒按口算（等价） |
| 9 | P | 1 | `lp_ffs` 用对数深度的前缀或（等价；`ttg_first_set` 本来就是） |
| 10 | T | 1 | `lp_ptr` 误预测截断的第一个命中不带 count 掩码（等价） |
| 11 | R | 0 | STLF 确认的晚到 store 地址比较改用阈值形式（`rel12s / rel32s`） |

## 10. 变更记录

本分支（exp/agu-share，相对 261bd67）对 `rtl/backend/lsu` 的提交：

- 2026-11-18：`312e6f8` `lp_ovl` 高位比较改为与 store 及其邻居比较（`lsu` 106 → 100）；`ed53054` `lp_wbstep` 只并入本拍新开的项；`7ddf8df` `lp_ptr / lp_rp` 提交接受和 STA 重放挑选；`0a522a6` `lp_l1b` 的 CAM 读 `paddr_reg`；`803692f` FLUSH_REG（全局 flush 晚一拍到 LSU、DTLB 等，`rob_flush_now` 限定本拍的 store 提交，docs/FLUSH_REG.md）；`64a908e` 分派 / `lp_ptr` 的 load 授权按空闲数；`e49618c` 重放按 AGU 占用分配。
- 2026-11-17：`c24861f` STAEV_REG；`1597a66` L1 槽 k = AGU 口 k；`5433a62` `lp_l1` 的 DTLB 请求按物理口建、温度计码；`16de223` DTLB 每个物理 AGU 一个口（5 个），`lsu / lsu_pipe / lp_core / lp_l1` 带 `LSU_AGU_PHYS` 宽的请求 / 响应数组；`b9ae0d5` 共用 AGU（`LSU_AGU_SHARED = 2`）在发射级和 `lp_l1`。
- 更早：见 git 历史（分级 LSU 合入 2026-11-07，store 写缓冲 EXP-024，访存推测 EXP-018 / 019，rv64 等）。

- 2026-11-18：删除旧 LSU 和没用的东西：30 个 `lsu_*` 文件（2688 行）、`lsu.sv` 里 `LSU_PIPE = 0` 的分支和 `LSU_PIPE` 常量（`dcache_s1`、`back_top`、`tb/soc/build.sh` 里依赖它的地方改为无条件）、`lp_pkg::NDC`；`lp_stq_ent` 里 `dr_pick ? rw13 : rw13` 两边相同，简化成 `rw13`。整核周期不变（见提交说明）。
- 2026-11-18：删除只剩一种取值的 `LP_STAEV_REG`（STA / STD 事件寄存直接展开，`lp_core.sv` 里没有 `generate` 的另一支）和 `LSU_WAIT_MSHR_FILL`（`fill_en = fill_valid`）。
