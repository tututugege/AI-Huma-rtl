---
module: dispatch
area: backend
rtl: rtl/backend/dispatch
spec: dispatch*
status: green
lockstep: trace 回放 + back_top 整程序 68/68
mutants: 16/17（1 等价）
note: 
---

# dispatch 设计笔记

> **更新（2026-11-12，rv64 / 现状）**：`dispatch` 把 uop 的 `is_word` 位原样带到发射队列；PC 哈希（`pc[13:2] ^ pc[25:14]`，LSU 访存推测用）取 PC 低位，不受 XLEN 影响。ROB 项号在紧凑 ROB 下是连续项号（见 `rob.md`）；分发被 `rob2dis_free`（空闲项数）限制。

## 1. 对应的 C++
- `back-end/Dispatch.cpp`、`back-end/include/Dispatch.h`，类 `Dispatch`；BackTop 调用顺序：`comb_begin` → `comb_alloc` → `comb_wake` → `comb_dispatch` →（ROB/LSU/ISU 阶段）→ `comb_fire` → `comb_pipeline` → `seq`。
- 输入：`ren2dis`（valid + 27 个 uop 字段）、`rob2dis`（ready/empty/stall/enq_idx/rob_flag）、`iss2dis.ready_num[5]`、`lsu2dis`（stq_tail/flag/free、ldq_free、ldq_alloc_idx/valid[8]）、`prf_awake`(4)、`iss_awake`(15)、`rob_bcast.flush`、`dec_bcast.{mispred,clear_mask}`。
- 输出：`dis2ren.ready`、`dis2rob`（valid/dis_fire/uop）、`dis2iss.req[5][8]`、`dis2lsu`（STQ 8 口、LDQ 8 口）。
- 不翻译：tma/dbg/perf（性能计数器代码只写统计）。ren2dis 的 `expect_mask/cplt_mask/src2_areg` 在 C++ 里被覆盖或从不读取，故不进 spec。

## 2. 硬件结构
```
ren2dis ─▶ [inst_stage: inst_q/valid_q ×8] ──┬─▶ lsu_alloc (STQ/LDQ 分配, rob_valid)
                                            ├─▶ wake_match + src_busy (busy_table 读, 同拍唤醒, 组内 RAW)
 busy_table[128] ◀─ set(fire) / clear(wake) ├─▶ decompose ×8 (每 IQ 至多 1 个 uop)
                                            ├─▶ iq_alloc (每 IQ 前缀计数, 容量检查, 端口号)
                                            ├─▶ fire_ctl (dis_fire, dis2ren.ready)
                                            └─▶ iq_req / lsu_req (仅 fire 的车道驱动请求口)
```
- `dis_pkg`：常量、`dis_inst_t/dis_iss_uop_t/dis_res_t/dis_class_t`、枚举、分类函数。（文件名取 `dis_pkg` 以保证 replay/lint 按字典序先编译包。）
- `dispatch`：只做端口打包/拆包。`dispatch_core`：连线。
- `dispatch_inst_stage`：8 条 128 位级寄存器（含全部字段）+ valid；flush/mispred 清 valid、ready 时收新组、否则保留未 fire 的并刷新 busy、两路都清 clear_mask。
- `dispatch_lsu_alloc`：前缀 popcount 得到车道前面有几条 load / store（rank）；store 授予条件 rank<stq_free，位置 = tail + rank（flag 带进位）；load 授予条件 rank<ldq_free 且 ldq_alloc_valid[rank]，ldq_idx = ldq_alloc_idx[rank]。只按本车道 rank 判断：更老车道失败时本车道也不可能 fire（见 fire_ctl），不需要 C++ 的“失败后不再递增计数”前缀逻辑。
- `dispatch_wake_match`：16 个源 preg 对 19 个唤醒口的 CAM。`dispatch_src_busy`：busy = src_en & ((table & !woken) | 更老有效车道写同 preg)，对所有车道统一计算。
- `dispatch_busy_table`：128 位，`busy_d = set | (busy_q & ~clear)`。
- `dispatch_decompose`：每车道一个，产出“每个 IQ 的 uop + has_iq + expect_mask”（因为每条指令对同一 IQ 至多 1 个 uop，省去 C++ 的 k 下标）。
- `dispatch_iq_alloc`：每 IQ 一个“older lanes 的 uop 数”前缀 popcount 作为端口号；容量 = used < ready_num（8 口宽度限制被 8 个车道蕴含，删除）。
- `dispatch_fire_ctl`：见 3。`dispatch_iq_req`/`dispatch_lsu_req`：每个端口 one-hot 选中拥有该端口且 fire 的车道，用 `ttg_onehot_mux` 取数据。

C++ → 硬件：`dispatch_cache/dispatch_success_flags/stq_port_owner/ldq_port_owner/iq_usage` 都变成上述前缀计数与 one-hot；`comb_fire` 的“撤销 IQ 请求”不再存在——只有 fire 的车道才驱动请求（结果等价）。

## 3. 一拍内的数据流
1. 寄存器级 inst_q → rob_idx = {enq_idx[3:0], 车道号}；LSU 分配（见上）。
2. busy（table、唤醒 CAM、组内 RAW）→ decompose（每车道每 IQ 一个 uop + expect_mask）→ iq_alloc（端口号、fit）。
3. fire_ctl：C++ 的顺序标志 pre_stall/pre_fire 并行化——“此前没有 stall”意味着此前所有有效车道都已 fire，故 pre_fire = 前面有有效车道。`fire_ideal[i] = valid & lsu_ok & fit & rob_ready & !flush & !serialize`；`stop_here[i] = valid & (!fire_ideal | AMO | WFI)`；`dis_fire[i] = fire_ideal[i] & !(older stop)`；`ready = !(|stop_here)`。CSR/AMO 要求 ROB 空且无更老有效车道。
4. iq_req/lsu_req：只有 fire 的车道驱动请求（C++ 先写请求再回滚，结果等价）；busy_table 清除唤醒后置位 fire 车道的 dest_preg。
5. inst_stage：`valid_d = !kill & (ready ? ren_valid : valid & !fire)`；负载 = ready ? 新组 : 刷新 busy 的保留负载，无效槽不做任何特殊处理。

## 4. 与 C++ 的差异点和隐含依赖（06 等价性原则）
**消费者核对（参考模型读取点）**
- `dis2rob.uop[i]`：仅 `Rob::comb_fire` 在 `dis_fire[i]` 为真时读取 → 全部字段 `when dis2rob_dis_fire`。
- `dis2iss.req[q][w].uop`：仅 `Isu::comb_enq` 在 `req.valid` 为真时读取（`from_dis_iss_uop`）→ `when dis2iss_req_valid`。
- `dis2lsu.*`：`RealLsu::comb_dis2lsu` 仅在 `alloc_req[k]` / `ldq_alloc_req[k]` 为真时读取 → payload（含 br_mask）`when` 对应 req。
- `dis2ren.ready`、`dis_fire`、两个 alloc_req：严格比较。

**放宽**：上述全部 payload 改 `when`；RTL 里原先为对齐无效时的 0 / 残留值所做的屏蔽已删除：`expect_mask` 不再按“被处理且放得下”屏蔽、`brk_before` 删除、LSU 拒绝车道不再保留旧 busy、`dis2lsu.br_mask` 在 req=0 时由 AND-OR 选择器自然给 0（不比较）、inst_stage 无效槽不再有 kill/hold 优先级（kill 只清 valid）。`stq_idx/stq_flag/ldq_idx` 对非访存指令仍为 0，因为它们进入 dis2iss/ROB 的比较负载且 spec 无法按指令类型放宽。

**删除字段**：`dis2rob.valid`（无消费者，仅内部）；`dis2rob.uop.{mispred,br_taken,flush_pipe,cplt_mask}`（Dispatch 恒 0，ROB 入队时自己覆盖/忽略）；`dis2rob.uop.br_mask`、`ldq_idx`（`RobStoredInst::from_dis_rob_inst` 不拷贝）；输入 `ren2dis.uop.{expect_mask,cplt_mask,src2_areg}`（被覆盖/不读）；tma/dbg。
**删除的冗余检查**：dispatch_width(=8) 与 MAX_*_DISPATCH_WIDTH 比较（恒真）、STQ 端口数比较、`dispatch_success_flags` 残留值、`min(rank, stq_free)`、LDQ 的 first_set 前缀。
**不复刻**：`dispatch_success_flags` 在 `break` 之后的残留值（不可观察）；perf 块。
**仍与 C++ 一致的隐含行为**：AMO 同时是 load 与 store；held 指令的 busy 重新带入“更老车道写同 preg ⇒ busy”（照搬；注意此版对 LSU 被拒绝车道也统一计算，全部 trace 通过）；`rob2dis.enq_idx` 7 位 IO 字段实为 4 位行指针，top 对位 6:4 局部 `lint_off UNUSEDSIGNAL`。无 deviation。

## 5. 验证
- spec：`spec/dispatch.io`（简化后 114 行）。
- trace：61 个 gate 测试各 8000 拍 + dhrystone/coremark 各 60000 拍 + 3 个随机 trace（`tests/dispatch/rand_trace.cpp`，驱动参考类 Dispatch，各 30000 拍），共 66 个，全部 PASS。随机 trace 补到了真实程序覆盖不到的：每个 IQ 的 ready_num<需求（IQ 满）、SFENCE_VMA、紧张的 STQ/LDQ、flush/mispred 风暴、全部 AMO 种类。
- 变异（严格比较字段首个失败，trace/字段/cycle）：M1 CSR/AMO 不看更老 fire：atomic-boundary，dis2rob_dis_fire[4]，101；M2 STQ 回绕进位：coremark，dis2rob_uop_stq_flag[1]，1338；M3 组内 RAW：add-longlong，dis2iss_req_uop_src1_busy，74；M4 IQ 容量 `<=`：rand_a，dis2rob_dis_fire[3]，9；M6 WFI 不独占：rand_a，dis2ren_ready，4；M12 STQ 授予 `<=`：matmul_fpu，dis2rob_dis_fire[4]，164；另有 M5/M7/M8/M10/M11/M13/M14/M15/M16/M18 均被抓。没抓到：M9（LDQ 授予 `<=`：被冗余的 ldq_alloc_valid 屏蔽，等价）。M17 因 lint 未使用信号构建失败，不计。有效变异 17 个，抓到 16 个。
- 简化前后行数：RTL 1334 → 1268 行（主要减少在 lsu_alloc/iq_alloc/inst_stage/src_busy 的逻辑；端口声明占 top 的大部分）；spec 119 → 114 行（字段 114 → 107 个）；trace 每拍约 2440 B → 2328 B。
