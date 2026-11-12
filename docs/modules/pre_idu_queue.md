---
module: pre_idu_queue
area: backend
rtl: rtl/backend/pre_idu_queue
spec: pre_idu_queue*
status: green
lockstep: 68/68
mutants: 18/18（5 仅随机）
note: 含 FTQ 与指令缓冲；3 个冗余限定输出待删
---

# pre_idu_queue 设计笔记

> **更新（2026-11-12，rv64 / 现状）**：FTQ 里存的 PC 是 `XLEN_BITS` 位（`pre_idu_ftq_pc`、`pre_idu_queue`），写缓冲/访存推测用的 PC 哈希由 FTQ 的 8 个额外读口给出（`RTL_MEMSPEC_NOTES.md`）。

## 1. 对应的 C++
- 文件/类：`back-end/PreIduQueue.cpp` `class PreIduQueue`（349 行）+ `back-end/InstructionBuffer.cpp`（39 行）+ `include/FTQ.h`（FTQEntry / FTQTrainMetaEntry）。baseline commit 2f31e8d。
- BackTop 调用点（顺序）：`comb_begin` → `comb_accept_front`（在 `idu->comb_branch` 之后、`rob->comb_commit` 之前）→ `comb_ftq_lookup_rob`（紧跟 `rob->comb_ftq_pc_req`）→ `comb_commit_info`（紧跟 `rob->comb_commit`）→ `comb_ftq_lookup_prf`（紧跟 `prf->comb_req_ftq`）→ `comb_fire`（`idu->comb_fire` 之后）→ `seq`。
- 输入：`bt.in`（FrontPreIO）、`idu_consume.fire[8]`、`idu->br_latch.{mispred,ftq_idx}`、`rob_bcast.flush`、`rob_commit.commit_entry[8].{valid, uop.ftq_idx/ftq_offset/ftq_is_last}`、`ftq_prf_pc_req`(10 口)、`ftq_rob_pc_req`(1 口)。
- 输出：`pre2front.{ready,fire[16]}`、`pre_issue.entries[8]`（给 Idu）、`ftq_prf_pc_resp`、`ftq_rob_pc_resp`、`ftq_commit_info.resp[8]`。

## 2. 硬件结构
```
 front2pre(16 lane) ─► pre_idu_ctrl ──ready/fire/alloc/rank/is_last──► pre2front
                         │  (flush_prev_q)          │push lanes
                         ▼                           ▼
   idu_consume.fire ─► ib_pop_cnt ──────────► pre_idu_ibuf (128 x 44b 环形) ──► pre_issue (8)
   rob_commit ───────► ftq_pop_cnt ─► pre_idu_ftq_ptr (tail 6b, count 7b)
                                         │ tail=alloc idx
                      alloc ────────────┬┴──────────────┐
                                  pre_idu_ftq_pc      pre_idu_ftq_meta
                       (64 x [16 slot pc, 16 pred, next_pc])   (64 x 16 x 260b)
                        19 读口: prf10 + rob1 + commit8         8 读口(commit)
```
- `pre_idu_ctrl`：accept 判定（ready = !mispred && !flush_prev && FTQ 有空 && IBuf 余量 ≥ 本组有效数）、fire、alloc、组内压缩序号 `lane_rank`（前面有几个有效 lane，popcount）、组内最后有效 lane、Idu 消费前缀数（前导 1 个数）、commit 的 `ftq_is_last` 个数。含唯一的隐藏状态 `flush_prev_q`。
- `pre_idu_ibuf`：环形缓冲。每个槽由满足 `push_en[i] && tail+rank[i]==j` 的 lane 写（rank 唯一 → 独热 mux）；读口 8 个，`head+i`；`valid` 由 count 推出，不存。
- `pre_idu_ftq_ptr`：tail / count。flush(tail=0,count=0) > recover(tail=idx+1, count-=tail-新tail) > alloc/pop。
- `pre_idu_ftq_pc`、`pre_idu_ftq_meta`：FTQ 存储，一个写口（alloc 时写 tail 项）+ 异步读口。
- C++ → 硬件对应：`ibuf/ibuf_1`、`ftq_*_1` 双份拷贝 → `_q/_d`；`ftq_valid[]`、`ftq_head`、`entry_valid` 删除；`push_entries[]` 静态数组+`push_count` → `lane_rank` 压缩写；commit 的 `train_meta_cursor` 链 → 直接用 commit 自带的 `ftq_idx` 读。

## 3. 一拍内的数据流
1. `comb_begin`：issue 组 = ibuf 当前状态的前 min(count,8) 项（仅用寄存器值）。
2. `comb_accept_front`：只用当前 count 寄存器（不含本拍 pop）：ready/fire/alloc；写 FTQ[tail]；本拍入队的 lane 暂存。
3. 三个 lookup 与 `comb_commit_info` 读的都是**寄存器内容**（`ftq_lookup_entries`、`ftq_train_meta_fifo` 非 `_1`），不看本拍 alloc 的写。
4. `comb_fire`：flush > mispred：清 ibuf、FTQ（flush: tail=0；mispred: 回收到 idx+1）；否则 ibuf 先 pop 再 push，FTQ 按 commit 的 is_last 个数 pop。flush/recover 时 FTQ 不 pop。
- 同一拍 alloc 与 pop：count = count + alloc − pop。

## 4. 与 C++ 的差异点和隐含依赖
### 4.1 隐含依赖（真实状态，已建成寄存器）
- **D1（04 §3.1 stale read）`rob_bcast.flush` 在 `comb_accept_front` 读到的是上一拍的值**：`Rob::comb_commit`（Rob.cpp:179-182，每拍先清零再置位）在 `comb_accept_front` 之后才运行，BackTop 里 `rob_bcast` 是跨拍保持的成员（`CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN=0`）。所以 ready 受**上一拍** flush 影响（flush 后第一拍 ready=0），而 `comb_fire`（BackTop 末尾）用**本拍** flush。RTL：`flush_prev_q <= rob_bcast_flush`，ready 用 `flush_prev_q`；ftq/ibuf 的清除用本拍 flush。后果：flush 当拍若 ready=1，则 fire 对前端为真、FTQ 写入、随后被 flush 清掉（RTL 同）。真实程序 trace 里"flush 后第一拍前端仍送有效指令"从未出现（前端被重定向），只有随机 trace 覆盖。
- `idu_br_latch.mispred` 是 Idu 寄存器（`br_latch`，seq 更新），一拍内值不变，不是 stale。

### 4.2 放宽（`when`）及消费者核对
| 字段 | 条件 | 读取点（核对） |
| --- | --- | --- |
| `pre_issue_entries_{inst,page_fault_inst,ftq_idx,ftq_offset,ftq_is_last}` | `pre_issue_entries_valid` | Idu.cpp:61/108 只用 entries[i] 且先判 valid（Idu 的 spec 已把这些作输入、valid 门控） |
| `ftq_prf_pc_resp_resp_{pc,pred_taken,next_pc}` | `ftq_prf_pc_resp_resp_valid` | Prf.cpp:123-127 `if (ftq_slot>=0 && resp.valid)` 才读；valid 即 req.valid（comb_ftq_lookup_prf 的 `resp = {}` 后仅 req.valid 时填充） |
| `ftq_rob_pc_resp_resp_pc` | `ftq_rob_pc_resp_resp_valid` | Rob.cpp:434-435（`Assert(resp[0].valid)` 之后读 pc） |
| `ftq_commit_info_resp_*` | 提交槽 valid（spec 专用限定输出 `ftq_commit_info_resp_valid[_t/_s]`，= `rob_commit_commit_entry_valid` 直通） | rv_simu_mmu_v2.cpp:742（commit_sync，perf）、:1371（back2front_comb，只在 `back2front_valid[i]=commit valid` 时读）。C++ 对无效槽 `resp = {}`，RTL 不清零。 |
- `when` 只能挂在输出上，且维度必须一致：为此 spec 里多了 3 个"限定输出"`ftq_commit_info_resp_valid`([8])、`_valid_t`([8][4])、`_valid_s`([8][8])，RTL 里只是 `rob_commit_commit_entry_valid` 的直通（集成时悬空）。`ftq_{prf,rob}_pc_resp_resp_valid` 是 C++ 真有的字段（= 请求 valid 直通）。

### 4.3 删除的字段 / 状态
| 删除项 | 理由（读取点核对） |
| --- | --- |
| `ftq_*_pc_resp.resp[].entry_valid`、`ftq_valid[]` 整个数组 | 全仓库无读取点（grep `entry_valid`：只有 BPU/AXI 里无关的同名量）；commit_info 里 `ftq_valid[idx]` 的门控对可达输入恒真（valid commit 的 FTQ 项必在队内：项只在 is_last 提交后 pop；recover 只丢比分支更年轻的块，其指令随 ROB 一起被杀） |
| `ftq_rob_pc_resp.resp[].{pred_taken,next_pc}` | Rob 只读 `.valid/.pc`（Rob.cpp:434-435 是唯一读取点） |
| `FTQTrainMetaEntry.mid_pred` | 从未被写入（"for future use"），也不在 `FtqCommitInfoResp` 里 |
| `InstructionBufferEntry.pc` | 唯一读取点是 Idu `decoded.dbg.pc = entry.pc`（调试字段，Idu.cpp:79/126）；Idu 的 spec 也不含 pc |
| `InstructionBufferEntry.valid` | 由 count 推出（i<count），不存 |
| `front2pre.front_stall`、`predict_next_fetch_address[1..15]` | PreIduQueue 只读 `predict_next_fetch_address[0]` |
| `ftq_head` | 只有 `ftq_pop` / commit cursor 用；FTQ 按索引查，pop 只需 count |
| perf 计数（`ctx->perf.*`）、Assert | 不翻译 |

### 4.4 选择不复刻的 C++ 行为
1. `ftq_pop` 的 `if (ftq_count_1 <= 0) break;` 夹紧：pop 数 > 队内项数不可达（每个 is_last 提交对应一个已分配项）。RTL 不夹紧。trace 未出现。
2. `ftq_recover` 的 `%` 规范化（负值回绕）：FTQ_SIZE=64 是 2 的幂，6 位自然回绕；加参数断言。
3. `InstructionBuffer::pop_front` 的 `actual = min(n, count)` 夹紧与 `entries[head_r] = {}` 清零：Idu 只会 fire 有效槽；清零无人读（valid 由 count 推出）。
4. `comb_commit_info` 的 `train_meta_cursor` 游标：C++ 内部 `Assert(ftq_idx == cursor)`，故游标值恒等于提交自带的 ftq_idx；游标在"最后一项之后"变无效只会影响其后的提交槽，而其后不可能还有有效提交。RTL 直接按 `ftq_idx` 读。
5. `ftq_alloc() < 0` 分支（ready 已保证有空位）不可达。
6. 无效 lane（`front2pre.valid[i]=0`）的 inst/pc 等：C++ 也写入 FTQ（slot_pc 等），RTL 同样整组写入（FTQ 槽 pc/meta 对无效 lane 也被存，保持与 C++ 完全一致；无人会读无效 lane 的项）。
7. 存储阵列（FTQ/ibuf）有复位到 0（规范要求寄存器全复位；与 C++ `init()` 一致）。

### 4.5 参考模型疑点（均按 C++ 实现，未登记偏差）
- `rob_bcast.flush` 的 stale 读（D1）：flush 之后第一拍 `ready` 依赖上一拍 flush，可能是有意的"flush 后停一拍"，也可能是调用顺序副作用；行为保持。
- `ftq_recover` 与 commit 同拍：`comb_fire` 在 recover 时跳过 pop。目前靠 Rob 在 mispred 拍不提交（Rob.cpp:218,274）避免丢失 pop；若以后 Rob 改变这一约束，FTQ 会泄漏表项。RTL 同 C++。

## 5. 验证
- spec：`spec/pre_idu_queue.io`，67 个字段（34 输入 + 33 输出；其中 25 个输出带 `when`）。
- trace：61 个 gate 测试 + dhrystone/coremark/coremark10 + 4 个 vm + float/sha/cjpeg/linear_alg/parser = 73 个程序，每程序 ≤10000 拍（`GATE_CYCLES=10000`），共 681,527 条记录；随机 4 条 × 60,003 = 240,012 条（`tests/pre_idu_queue/run_rand.sh`，无 `NDEBUG`，参考模型 Assert 全开）。
- 随机激励约束依据（见 `rand_trace.cpp` 文件头）：指令按 前端组→IBuf→Idu 前缀消费→"rob"队列→按序提交；提交槽携带指令取指时的 (ftq_idx, offset, is_last)（保证 commit 游标 Assert）；mispred 选在途指令 k，更年轻的离开、k 置 is_last（Rob::comb_branch），mispred 拍无提交（Rob.cpp:218/274）且 Idu 不 fire（Idu::comb_fire 提前返回）；flush 与头指令的单次提交同拍、Idu 不 fire；mispred 与 flush 不同拍。flush 值按 BackTop 顺序处理：accept_front 之前保持上一拍值，之后再写本拍值（D1）。
- 覆盖（真实程序）：flush 713 拍、mispred 11,035 拍、IBuf 满阻塞、FTQ 近满与 tail 回绕 5,251 次、组内多 is_last 提交（pop≥2：15,355 拍）。**真实程序覆盖不到**：flush 后第一拍前端仍送有效组（D1，仅随机）、sc_*/loop_*/page_fault_inst 非零（仅随机）、稀疏有效 lane（仅随机）。
- 变异表见下（`scratchpad/pre_idu_queue/mut.sh`）。

### 变异表（真实程序集 = dhrystone/coremark/trap-precise-store/interrupt-vectored/vm_pagefault_test/memory-stress/smc-div/illegal-instruction-trap；随机 = rand_a..d）
| # | 变异 | 真实程序 | 随机 |
| --- | --- | --- | --- |
| M1 | ready 用本拍 flush 而非上一拍（D1） | dhrystone 等 @17 `pre2front_ready` | rand_a@112、c@29、d@14 |
| M2 | FTQ 满判断 `<`→`<=` | dhrystone@3724 `pre2front_ready` | rand_d@234 |
| M3 | IBuf 余量 `<=`→`<` | dhrystone@1921 | rand_a@37 |
| M4 | 组内最后有效 lane 只看低 8 lane | **未抓到** | rand_a@2 `pre_issue_entries_ftq_is_last[7]` |
| M5 | recover 尾指针 idx+1→idx | 全部 @61 `pre2front_ready` | rand_b@19 `…ftq_idx[0]` |
| M6 | flush 不清 tail | @30 `pre_issue_entries_ftq_idx[0]` | rand_c@33 |
| M7 | recover 后 count 多 1 | dhrystone@967 `pre2front_ready` | rand_d@360 |
| M8 | mispred 不清 IBuf | dhrystone@227 `pre_issue_entries_valid[0]` | rand_b@17 |
| M9 | FTQ pop 数含无效槽 | @17 `pre2front_ready` | rand_a@2 |
| M10 | issue_valid `>`→`>=` | @1 | @1 |
| M11 | sc_idx 表序反 | **未抓到** | 全部 @4-7 `ftq_commit_info_resp_sc_idx` |
| M12 | next_pc 读索引错 | @57 `ftq_prf_pc_resp_resp_next_pc[0]` | @3 |
| M13 | pred_taken 读偏移错 | @57 | @4-9 |
| M14 | IBuf tail 回绕错 | **未抓到** | rand_a@16 `pre_issue_entries_inst[6]` |
| M15 | page_fault_inst 受 valid[0] 门控 | **未抓到** | rand_a@26 |
| M16 | loop_tag 混入 loop_idx | **未抓到** | rand_a@7 `ftq_commit_info_resp_loop_tag[0]` |
| M17 | ready 不看 mispred | @59 `pre2front_ready` | rand_b@16 |
| M18 | 无有效 lane 也 alloc | @12 `pre_issue_entries_ftq_idx[0]` | rand_a@7 |
共 18/18 被抓到；其中 **5 个只被随机 trace 抓到**（M4、M11、M14、M15、M16），1 个（M7 等多数）两边都能抓。
