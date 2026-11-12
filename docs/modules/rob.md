---
module: rob
area: backend
rtl: rtl/backend/rob
spec: rob*
status: green
lockstep: trace 回放 + back_top 整程序 68/68
mutants: 10/11（1 等价）
note: 默认是紧凑 ROB（ROB_COMPACT=1，rob_core_cpt）；行式 ROB（rob_core）保留为 ROB_COMPACT=0
---

# rob 设计笔记

> **更新（2026-11-12）**：默认配置是**紧凑 ROB**（EXP-028，`ROB_COMPACT = 1`，`rob_core_cpt.sv`，见下面的 2.1 节），下文第 2、3、4 节描述的结构（按行分配、`rob_ptr` / `rob_commit_ctrl` / `rob_head_info` / `rob_store` / `rob_branch_recovery`）是 `ROB_COMPACT = 0` 的行式 ROB（`rob_core.sv`）。第 5 节验证数据是旧体系（trace 回放、变异）的历史结果。rv64：`rob_pkg` 的 `ROB_XLEN = XLEN_BITS`（原名 `XLEN`，与 `-DXLEN` 宏重名而改），`bcast_pc` / `bcast_trap_val` / `diag_val` / `imm` 随 XLEN 加宽；写回口数是 `ISSUE_WIDTH`（18，不是下文旧文写的 22）。`TTG_EBREAK_TRAP`（Linux 需要）把 ebreak 变成断点异常（`rob_pkg::EBREAK_TRAP`）。

## 1. 对应的 C++
- 文件/类：`back-end/Rob.cpp`、`back-end/include/Rob.h`，`class Rob`（`comb_begin/ready/ftq_pc_req/commit/complete/branch/fire/flush` + `seq`）。
- BackTop 调用顺序（决定 RTL 里"后写者赢"的优先级）：
  `comb_begin → comb_ready → comb_ftq_pc_req → comb_commit → comb_complete → comb_branch → comb_fire → comb_flush → seq`。
- 输入（spec `in`）：
  - `dec_bcast.{mispred,redirect_rob_idx}`；`csr2rob.interrupt_req`；`lsu2rob.committed_store_pending`；`in.front_stall`；
  - `ftq_rob_pc_resp.resp[0].{valid,pc}`；
  - `dis2rob.dis_fire[8]` 与 `dis2rob.uop[8].*`（23 个字段，见 spec）；
  - `exu2rob.entry[ISSUE_WIDTH].{valid,uop.{diag_val,result,rob_idx,mispred,br_taken,page_fault_*,op,flush_pipe}}`。
- 输出（spec `out`）：`rob2dis.{stall,empty,ready,enq_idx,rob_flag}`、`rob2csr.{commit,interrupt_resp}`、
  `rob_commit.commit_entry[8].{valid,uop.*}`、`commit_extra[8].{src1_areg,imm}`（前端 BPU 训练用，`rv_simu_mmu_v2.cpp:1407`）、
  `rob_bcast.*`、`ftq_rob_pc_req.req[0].*`。
- 不翻译（已从 spec 删除）：`dbg.*`、`rob2dis.tma.*` 与 `lsu2rob.tma.miss_mask`（仅 Dispatch 的 TMA 性能归因使用）、`tma.is_cache_miss`（全仓库只被清零，从不置位）、
  `is_atomic/func3`（只用于 Assert 对齐检查）、`dis2rob.valid/br_mask/ldq_idx/cplt_mask`（Rob 不读）、deadlock 计数 `stall_cycle`、所有 `Assert`/日志。

## 2. 硬件结构

```
 dis2rob ─┐                                   ┌────────────── rob_store ───────────────┐
 exu2rob ─┼─ rob_wb_decode ─ wb_ev[ISSUE_WIDTH] ──────▶│ 8 bank x 16 line  rob_entry (valid+uop) │── head line (8 bank)
 dec_bcast┼─ rob_branch_recovery ─ clr/mark ─▶│  每个 entry: 事件按端口升序折叠          │      │
 flush ───┘                                   └────────────────────────────────────────┘      ▼
        ▲                                                      rob_head_info ── stall / ftq_pc_req / head_*
        │ deq_adv / enq / recover / flush                      rob_commit_ctrl ─ commit valid、single/group、interrupt_fire、deq_adv
     rob_ptr (enq/deq ptr + flag, empty/full)                   rob_trap_ctrl  ─ rob_bcast.{flush,exception,...}、rob2csr.commit、pc/trap_val hold
```

子模块（`rtl/backend/rob/`）：
| 文件 | 职责 |
| --- | --- |
| `pkg/rob_pkg.sv` | 类型（`rob_entry_t`、`rob_wb_t`、`rob_event_t`）、InstType/UopType 编码、分类函数 |
| `rob.sv` | 顶层，仅端口适配（平铺端口 ↔ 内部 struct 数组） |
| `rob_core.sv` | 行式 ROB（`ROB_COMPACT=0`）：连接各子模块 |
| `rob_core_cpt.sv` | **紧凑 ROB（默认）**：单文件实现指针、提交窗口、额度、分支回退，复用 `rob_entry`/`rob_wb_decode`/`rob_trap_ctrl` |
| `rob_ptr.sv`（仅行式） | 头尾指针 + 回绕 flag，空/满；flush/误预测回退/入队/出队的次态 |
| `rob_wb_decode.sv` | 每个 EXU 写回口 → 事件（完成位、diag_val 来源、page fault 置位、flush_pipe、分支结果） |
| `rob_entry.sv` | 单个 ROB 槽：valid + uop；次态优先级 flush > 入队 > 分支回退清除 > 提交清除；uop 为 入队覆盖 > ftq_is_last > 写回事件 |
| `rob_store.sv`（仅行式） | 8x16 槽阵列（generate）+ 队头行读出（one-hot mux） |
| `rob_branch_recovery.sv`（仅行式） | 由 `redirect_rob_idx` 与旧 enq_ptr 得到"重定向点之后到旧尾"的清除掩码 |
| `rob_head_info.sv`（仅行式） | 队头行的 stall、FTQ PC 请求、head_valid/incomplete 广播 |
| `rob_commit_ctrl.sv`（仅行式） | 提交仲裁：组提交 / 单提交 / 进度单提交 / 中断触发，出队推进 |
| `rob_trap_ctrl.sv` | 单提交指令的 flush/异常/ecall/mret/… 译码（优先级为 one-hot），无寄存器 |

### 2.1 紧凑 ROB（`rob_core_cpt`，默认）

`rob.sv` 里按 `ROB_COMPACT` generate 选 `rob_core_cpt`（`g_cpt`）或 `rob_core`（`g_line`）。紧凑 ROB 的存储不变（`ROB_BANK_NUM = 8` 个 bank × `ROB_LINE_NUM = 16` 行，共 `ROB_NUM = 128` 项，`rob_entry`、`rob_wb_decode`、`rob_trap_ctrl` 复用），区别在分配和提交：

- **按项分配**：`rob_idx` 是环形位置（`ROB_IDX_WIDTH = 7`），项 `e` 在 bank `e % 8`、行 `e / 8`；一个分发组不再占一整行，一个分发组的各条指令占连续的项。状态只有 `head_q`、`hflag_q`（队头回绕标志）、`count_q`（有效项数）。`rob2dis_enq_idx` 是队尾**项号**（行式是行号），`rob2dis_free`（新增输出）是空闲项数，`rob2dis_ready = count != ROB_NUM`。
- **提交窗口**：最老的 8 项（bank 经 `hb_oh_q` 旋转成窗口槽序，窗口可跨 head 行和下一行）。队头是 flush 类 / fence / WFI 指令或有中断时，队头**单独**提交（`single_commit`，`rob_trap_ctrl` 译码 flush/异常）；否则提交窗口里"已完成、不含上述指令"的**最长前缀**（`prefix`），并受 BPU 提交额度限制：窗口里的控制流指令数不能超过 BPU 更新队列的空闲项（`bpu_upd_free` 减去上一拍已提交的），取指块结尾数不能超过 uBTB 训练队列的空闲项（`bpu_tq_free`）；队头那一条不受额度限制。`front_stall` 只拦队头以外的槽。
- **分支回退**：`keep = (redirect_rob_idx - head) + 1`，保留到分支为止的项，队尾移到分支之后一项（`mark_last` 标记分支项）。
- `rob` 新增输入 `bpu_upd_free[3:0]`、`bpu_tq_free[3:0]`（行式下接入但不用）和输出 `rob2dis_free`（行式下为 `ROB_NUM`）。关闭紧凑模式：`bash scripts/gen_cfg.sh -DCFG_ROB_COMPACT=0`（RTL 周期随之要换成行式的参考表）。
- 已知问题（总仓库 `docs/TODO.md`）：分支密集短循环被额度卡住；PMU 把 ROB 空闲项数挡住记成 `SLOT_BE_SERIAL`；`rob` 最长路径比行式深约 5 级（53 对 46）。

下面的"状态"是行式 ROB 的：
- `valid_q[8][16]`、`uop_q[8][16]`（`rob_entry_t`；完成状态存成 `pend_mask = expect & ~cplt`，为 0 即完成）：每个槽 1 个写端口（次态逻辑见 rob_entry），读：队头行 8 槽 16:1 mux。
- `enq_ptr_q/deq_ptr_q[4]`、`enq_flag_q/deq_flag_q`。

C++ → 硬件对应：
| C++ | 硬件 |
| --- | --- |
| `entry[bank][line]` / `entry_1` | `rob_entry` 的 `_q` / `_d` |
| `group_commit_mask[]` + `group_has_head` | `hv`（队头行 valid 向量），`has_head = |hv` |
| "第一个 valid 的 bank"（`for + break`） | `ttg_first_set(hv)` one-hot |
| `single_idx` | 上述 one-hot（单提交总是对第一个 valid 槽） |
| `while (ptr != enq_ptr)` 清除多行 | 环形距离比较：`dist(start,L) < dist(start,enq_ptr)` |
| 逐端口 `for (i<ISSUE_WIDTH)` 顺序写 entry_1 | `rob_wb_decode` 先生成每口事件，槽内按端口升序折叠（后口覆盖前口，与 C++ 顺序一致） |
| `if-else if` 链（ecall/mret/…） | one-hot 优先级向量 `ttg_first_set` |

## 3. 一拍内的数据流
1. `rob_ptr`/`rob_store` 给出当前状态；`rob_store` 读出队头行（valid、uop）。
2. 组合输出（只依赖状态）：`rob2dis.{ready,empty,enq_idx,rob_flag}`、`stall`、`ftq_pc_req`、`head_*`。
3. `rob_commit_ctrl`（输入：队头行、`dec_bcast.mispred`、`front_stall`、`interrupt_req`、`committed_store_pending`、empty）
   → `commit_valid[8]`、`single_commit`、`interrupt_fire`、`deq_advance`。
   - `commit = !empty && !mispred && !(has_head && front_stall) && 所有 valid 槽 complete`，再被 fence 门控（`!int && 首 valid 是 fence 类 && committed_store_pending`）清零；
   - `single = !mispred && has_head && (int || (有特殊指令 && 首 valid complete)) && !fence门控`；
   - 进度单提交（`!commit && !single && !int && !mispred`，首 valid 已 complete 且不是 flush 类）。
   - 组提交清掉整行并推进 deq；单提交只清首 valid 槽，当该行再无 valid 才推进 deq。
4. `rob_trap_ctrl`：单提交的 uop + `ftq_pc_resp.pc` → `flush/exception/ecall/...`；优先级链 `interrupt > ecall > mret > sret > pf_store > pf_load > pf_inst > illegal > ebreak > wfi > csr > sfence > fence_i > flush_pipe`。
5. `rob_wb_decode` + `rob_branch_recovery` + 入队：写进各槽次态。同一槽优先级（对应 C++ 调用顺序）：
   valid：`flush(清) > 入队(置) > 分支回退(清) > 提交(清)`；uop：`入队(整体覆盖) > ftq_is_last(分支) > 写回事件 > 保持`。
6. 指针次态：`flush(全 0) > 入队推进（基于分支回退后的 tail） > 分支回退 > 保持`；deq：`flush(0) > advance`。

## 4. 与 C++ 的差异点、消费者核对、放宽/删除/不复刻（依 docs/06）

### 4.1 放宽为 `when`（消费者核对）
- `rob_commit.commit_entry[i].uop.*`、`commit_extra.*`：读取点 Ren.cpp:270、Lsu RealLsu.cpp:1064、PreIduQueue.cpp:256/294、rv_simu_mmu_v2.cpp commit_sync/1369 均先判 `commit_entry[i].valid` → `when commit_entry_valid`。
- `rob_bcast.pc`：Csr.cpp:179/236（mepc/sepc，仅 MTrap/STrap）、BackTop.cpp:354（仅 `rob_bcast.flush`）→ `when rob_bcast_flush`。RTL 直接输出 `ftq_resp.pc`，**不再建保持寄存器**。
- `rob_bcast.trap_val`：Csr.cpp:228/230/290 仅在 page fault / illegal 时读 → `when rob_bcast_trap_val_valid`（新增的 RTL 输出，= 四个 cause 之一；spec 里用等价 C++ 表达式录制，因为 `when` 只能挂单个 1 位字段）。
- `rob_bcast.head_rob_idx` / `head_incomplete_rob_idx`：MemUtils.h:125-128 仅在对应 `_valid` 为真时读 → `when`。
- `ftq_rob_pc_req.req[0].ftq_idx/ftq_offset`：PreIduQueue 的 ftq_lookup_rob 只在 `req.valid` 时用 → `when req_valid`。

### 4.2 从 spec/RTL 删除
- 输入 `ftq_rob_pc_resp.resp[0].valid`：只出现在 `Assert`；`dis2rob.uop.tma.is_ret`、`tma.mem_commit_is_load`、输出 `commit.uop.tma.is_ret/is_load`：只被 perf 统计（rv_simu commit_sync 的 ret 统计）和对齐 Assert 使用；
  输出 `commit.uop.flush_pipe`：commit 路径无消费者（Ren/LSU/Pre/TB 均不读）。
- `rob2dis.tma.*`、`lsu2rob.tma.miss_mask`（Dispatch 的 TMA 性能归因）、`dbg.*`、`is_atomic/func3`（仅 Assert）、`tma.is_cache_miss`（全仓库从不置位）、`dis2rob.valid/br_mask/ldq_idx/cplt_mask`（Rob 不读）。
- 内部：`expect_mask/cplt_mask` 两个 3 位寄存器合并成一个 `pend_mask`（`cplt_mask==expect_mask` ⇔ `pend==0`，cplt 超出 expect 的情形只会触发 C++ Assert）。
- 保留 `tma.mem_commit_is_store`：TB `commit_sync` 用它决定是否把 store 写进内存子系统（功能性）。

### 4.3 选择不复刻
- `rob_bcast.pc/trap_val` 的"跨拍保持"（C++ 因 `rob_bcast` 整拍不清而残留）：消费者都受 flush/cause 保护（见 4.1），不是真状态。
- 写回到无效槽、重复完成位、完成位越界、`stall_cycle` 死锁计数、对齐 Assert：均为 Assert/调试路径，不建逻辑。
- `comb_fire` 在同拍 `comb_branch` 回退后再 `LOOP_INC(enq_ptr_1)` 时 `enq_flag_1 = !enq_flag`（旧 flag）的覆盖：RTL 用回退后的 flag（`!enq_flag_rec`）。仅在"同拍 mispred 回退且入队且回绕"时才有差别；Dispatch 在 mispred 拍不会入队（真实 trace 4252 次 mispred 无一次同拍入队），随机 trace 也不构造该情形，不可达。
- `rob_idx/rob_flag` 仍按 Dispatch 给的值存储（C++ 并未保证它们等于槽位置），不做"由位置推导"。

### 4.4 隐含依赖与保留的怪异行为
1. **exu2rob 不是 stale 读**：`Exu::comb_begin` 清 valid，`comb_fu2exu_collect`（经 `comb_exec`）在 `Rob::comb_complete` 之前写入，之后不再改；录制值即 Rob 所见，无需 `_hold_q`。BackTop 注释里的 "Known issue" 只在诊断开关 `CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN=1` 下存在。
2. **BackTop 在 Rob 之后覆盖 `rob_commit.commit_entry[i].uop.diag_val`**（BackTop.cpp:368，flush 时写 `redirect_pc`）：不是 Rob 行为，Rob 边界取 Rob 自己的值（spec 的 `@` 读 `bt.rob->entry[i][deq_ptr].uop.diag_val`）。闭环时该覆盖要放在 Rob 之外。
3. `rob2dis.enq_idx` 是行号（`enq_ptr`，0..15），7 位高位补 0（Rob.cpp:488）。
4. `comb_branch` 的 flag 翻转按字面实现：`if (enq_ptr_1 > enq_ptr) enq_flag_1 = !enq_flag`（Rob.cpp:643），这是真状态（影响 empty/full）。
5. STA 写回带 fault 时：`if (page_fault_store) page_fault_load = false`（Rob.cpp:611）按字面保留（AMO 的 LD 口报 load fault、STA 口报 store fault 时可达；随机 trace 命中，去掉该行会被 `commit.uop.page_fault_load` 抓到）。
6. 单提交总是作用于队头行第一个有效槽；中断（`csr2rob.interrupt_req`）在队头行有有效槽时无条件走单提交。
7. 写回端口→完成位映射 `rob_port_cplt_bit`：ALU/LD → G0，STA/BR → G1，STD → G2（util.h:88）。
8. 同拍多个端口写同一槽时按端口升序"后者覆盖"（diag_val、br 结果），与 C++ 顺序一致（槽内 for 折叠，无 break）。

## 5. 验证
- spec：`spec/rob.io`（94 个字段；简化前 99）。
- 简化前后：RTL 约 1142 行 → 1112 行（含 220 行纯端口适配的顶层和 190 行 package）；去掉的是 2 个 32 位保持寄存器、tma/flush_pipe 三个输出、cplt/expect 拆分。与 C++ 的 921 行相比，逻辑部分（不含顶层端口适配与 package）约 700 行，且无 break/while/stale 状态。
- trace：61 个 gate 测试（≤30000 拍）、dhrystone、coremark（各 100000 拍）+ 6 条受约束随机 `rand0-5`（`tb/rob/gen_rand.cpp`，直接驱动参考 Rob 类，`bash tb/rob/build_gen.sh run`，每条 40000 拍），共 69 条、641,732 条记录，全部 PASS。
- 覆盖（输入统计，真实程序+随机）：flush、exception、interrupt、ecall/mret/sret、fence_i（真实）、sfence_vma、page_fault_inst/load/store、illegal、flush_pipe 写回、front_stall、committed_store_pending、满/空/回绕、mispred（含 redirect 行为 15 与 flag 翻转）、组提交 8 路、单提交、fence 门控等均出现。
  **未覆盖**：mispred 与入队同拍（Dispatch 不会这样做）、mispred 与 flush 同拍（真实与随机均不构造）、写回命中无效槽、重复完成位（均为 C++ Assert 路径）。
- 变异（均由严格比较字段抓到，首个失败）：
  - `rob_ptr` 回退 flag 条件 `>` 改 `>=` → dhrystone cycle 60 `rob2dis_rob_flag`
  - 去掉 front_stall 背压 → rand0 cycle 129 `rob_commit_commit_entry_valid[6]`
  - cause 优先级 illegal 与 csr 互换 → rand0 cycle 8552 `rob2csr_commit`
  - STD 端口完成组改 G1 → dhrystone cycle 83 `rob_commit_commit_entry_valid[1]`
  - 去掉 STA fault 清 pf_load → rand0 cycle 11514 `..._page_fault_load[5]`
  - 去掉 fence 门控 → rand0 cycle 58 `rob_commit_commit_entry_valid[4]`
  - 清除范围 `<` 改 `<=` → dhrystone cycle 887 `rob_commit_commit_entry_valid[2]`
  - 中断/特殊指令单提交不等首槽完成 → dhrystone cycle 15 `rob2csr_commit`
  - flush 不清 valid → rand0 cycle 36 `rob2dis_stall`
  - trap_val 不区分 pf_inst（用 diag_val）→ rand0 cycle 476 `rob_bcast_trap_val`
  - 存活（等价于不可达）：入队与分支回退对 valid 的优先级互换（mispred 与入队不同拍，见上）。
