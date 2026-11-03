# 前端 RTL 模块边界与翻译方案（分析报告）

> 分析者：ana agent。基线：参考模型 `baseline-sim/src`（`tututugege-trace/baseline.lock` 的 `2f31e8d`）。
> 所有 C++ 行号均指**原版（未加钩子）** `front-end/front_top.cpp` 等文件；`rv_simu_mmu_v2.cpp`、`BackTop.cpp` 同。
> 标注 **[已验证]** 的结论来自本报告附带的实验（`tools/` 里的插件，73 个程序 × ≤10 万拍，见 §8 与 `data/`）；
> 标注 **[未核实]** 的是只读代码得出、未实验或未读完的部分。没有标注的是直接读代码得出的事实。

## 0. 摘要（先看这里）

1. 前端**不是**一个"一拍内多次调用"的混乱结构，而是：**寄存器 → 一次组合求值 → 寄存器**。`front_comb_calc`（1030–2011 行）里 4 个 FIFO 各有"先读后写两次调用"，
   其中第二次调用只是为了把第一次的出队结果和这拍的入队合并成同一份 `clear → push → pop` 请求（`accumulate_*_req`，940–1028 行）。**每个 FIFO 的净效果就是一个标准的 1R1W 队列，读先于写，没有空队列写穿**。
2. 参考模型里大量"看起来复杂"的路径在当前配置下是**死代码**（编译期常量或实测从未发生，已逐项列在 §3.4）：双请求 slot1、2-ahead/mini-flush/dummy PTAB 项、`icache→fetch FIFO` 旁路、`icache→predecode` 旁路、FIFO 内部写穿、instruction_FIFO"满"。真正活着的旁路只有 **front2back 输出旁路**（`can_bypass_front2back_to_output`）。
3. FIFO 家族的**真实规格与 `fifo/FIFO_RTL_TEMPLATE_MAPPING.md` 不符**（那份文档写的是深度 8、位宽 486/1141/1277，已过时）：当前 `fetch_addr` 16×32b，`instruction` 16×832b，`PTAB` 16×2378b（含 2 个恒 0 标志，有效 2376），`front2back` 32×2648b（§2.2，位宽由 `tools/widths.cpp` 实测）。
4. 8 个 `*_full_latch/*_empty_latch` 看似独立寄存器，**实为对应 FIFO 当前 size 的纯函数**（[已验证]，全程序 0 不一致），RTL 里不需要建这 8 个寄存器，用 size 比较即可（但 PTAB/fetch_addr 的 full 是 `size>=DEPTH-1`，instruction/front2back 是 `size==DEPTH`）。
5. 前端对后端的接口是**寄存后的** `front.back2front`（`SimCpu::back2front_comb`，1360 行起）：前端当拍的组合输入全部来自上一拍结束时的寄存器，没有从后端当拍组合到前端的路径。前端 → 后端输出 `front.out` 在 `back.comb()` 之前就算完了。
6. 真正需要**重构成数据流**的只有三处：(a) FIFO 的"两次调用 + 累加请求"→ 单次 `clear/push/pop` 语义；(b) **ICache 的 `icache_comb_calc` 内部把 comb 和 seq 熔合**，且在谓词预译码冲刷的那拍被**调用两次**（第二次是 `invalidate_req`），状态在一拍里推进两步（§3.5）；(c) predecode 冲刷 → 下一拍 refetch 这条延迟路径（`predecode_refetch` 寄存器）要显式建寄存器。其余都能机械翻译。
7. 建议模块划分：`predecode`、`predecode_checker`、`ttg_fifo`(参数化，4 个实例)、`front_ctrl`(含 `predecode_refetch` 寄存器和输出旁路)、`bpu`、`icache`(含 ITLB 胶合)。BPU 与 ICache 各自 ~6k 行，是前端的两个大块，**不在本报告细化到内部**（§4.6、§4.7 只给边界与风险）。
8. 录制：现有钩子（`back.comb()` 之后）只能读到 `front.in/out`、`FrontReadData`（FIFO 起拍状态快照 + 8 个锁存）、`FrontUpdateRequest`（4 个 FIFO 的最终 push/pop/clear 请求及入队数据、BPU 事务）。**读不到** icache 输出、BPU 输出、checker 输出、各种旁路/使能。已设计并验证了一个只读"前端录制抓手"（tap），补丁见 `frontend-record-hook.patch`，用法见 `frontend-record-hook.md`。**加钩子前后周期数、`front.out` 逐拍哈希完全一致**。

## 1. 前端在一个 CPU 周期里的位置

`SimCpu::cycle()`（`rv_simu_mmu_v2.cpp` 1059–1190）的调用顺序（和前端相关的）：

```
1065  back.in = front2back_hold                      # 顶层"前端→后端保持寄存器"，后端 stall 时保住上一拍的 payload
1080  front_comb_before_back()                       # ← 前端整个组合求值在这里，只调用一次 (1214–1340)
1089  axi_subsystem_comb_outputs ... mem_subsystem.comb_outputs   # AXI/DCache 当拍输出（在前端之后！）
1103  back.comb()                                    # 后端组合
        ───────── 录制钩子位置（ttg_rec::cycle）─────────
1125  back2front_comb()                              # 生成"下一拍的"前端输入 back2front_1 (1360 起)
1129  front2back_hold_comb()
1135  front.seq_write_bpu()  → front_seq_write()     # 前端所有时序更新（BPU、4 个 FIFO、锁存器、predecode_refetch）
1137  front.seq_back2front()                         # back2front = back2front_1（前端输入寄存器）
1141  front2back_hold_seq() ; ... back.seq() ...
```

`front_comb_before_back()`（1194–1340）做的事：

- `front.in = front.back2front`（上一拍寄存的后端→前端信号，包含 `refetch/refetch_address/itlb_flush/fence_i` 和提交更新信息 `back2front_valid/actual_*/tage_*...`），只保留 `reset`，`csr_status` 取当拍 CSR 输出（1216–1219）。
- `frontend_can_read = !back2front_stall || registered_refetch`（1214）。可读时：`FIFO_read_enable=true`，调 `seq_read_bpu(); comb_bpu();`，并把 `front.out` 搬进 `back.in.*`（1221–1262），其中 `back.in.valid[j] = no_taken && FIFO_valid && inst_valid[j]`（`no_taken` 在遇到第一个预测跳转后清零，1227–1262）。
  不可读（后端 `pre2front.ready==0`）时：`FIFO_read_enable=false`、`refetch=false`，**前端仍然调用 `comb_bpu()`**（1266–1272）：BPU、icache、FIFO 写侧照常推进，只是不出队。
- 因此前端每个 CPU 周期**恰好一次** `front_comb_calc`（外加 `FrontTop::init()` 里复位用的一次，见 §8.3：`tap_count = cycles + 1`）。
- 这两处（`no_taken` 截断、`front2back_hold`）属于 **前端↔后端胶合**，不在前端模块内；前端模块的输出边界取 `front.out`（`front_top_out`）。建议 `no_taken` 截断和 hold 寄存器归到 Pre-IDU 队列/后端侧模块（本报告不展开，[未核实] 它们与 `PreIduQueue.cpp` 的关系）。

> 时序含义：BPU/ICache/FIFO 在 AXI 当拍输出**之前**求值，ICache 读到的内存响应端口值是上一拍末尾留下的（见 §4.7）。

## 2. 状态清单（哪些是硬件寄存器）

### 2.1 前端顶层

| 状态 | C++ | 位宽 | 说明 |
| --- | --- | --- | --- |
| `predecode_refetch` / `predecode_refetch_address` | `front_top.cpp:25-26` | 1+32 | checker 判定冲刷 → **下一拍**触发 `global_refetch`（`front_state_req.next_predecode_refetch`，1829–1835）。真寄存器 |
| `*_full_latch` / `*_empty_latch` ×4 | `front_top.cpp:30-37` | 8×1 | **冗余**：= f(FIFO size)，见 §2.3 |
| `front_sim_time`、`front_stats`、`falcon_*`、`front_deadlock_snapshot` | `:27,42-52,72` | — | **统计/调试，不翻译**（`front_stats` 全部字段、`FRONTEND_HOST_PROFILE_SCOPE`、`front_dump_*` 都不进 RTL） |
| `front.back2front`/`back2front_stall` | `FrontTop.h` | ~3k | 前端输入寄存器（后端→前端，`seq_back2front` 更新）。属接口，不是前端内部状态 |

### 2.2 四个 FIFO（`fifo/*.cpp`；深度来自 `config/frontend_feature_config.h:336-345`）

| FIFO | 深度 | 条目位宽 | 入队写入点 | 出队（读）点 | 清空 | `full` 标志（给谁用） | 条目内容 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `fetch_address_FIFO` | 16 | 32 | BPU 取指地址（`front_top.cpp:1426-1437`） | → icache 请求（1247，1468–1472） | reset \| **全局 refetch** | `size>=15`：BPU 反压（`bpu_stall`，697–）| 取指 PC |
| `instruction_FIFO` | 16 | 832 | icache 返回组（1626–1658） | → predecode_checker 输入（1278） | reset \| 全局 refetch | `size==16`（**不可达**，§3.4）| 8×{指令32, page_fault1, inst_valid1, predecode_type2, predecode_target32}, seq_next_pc32（+8×pc32 仅供调试比对，**可不要**）|
| `PTAB` | 16 | 2378 | BPU 预测结果（1706–1730） | → checker / front2back 写（1283） | reset \| 全局 refetch | `size>=15`：BPU 反压（`ptab_full_latch`）| 8 lane×{pred_dir, base_pc32, alt_pred, altpcpn3, pcpn3, tage_idx 4×10, tage_tag 4×8, sc_used, sc_pred, sc_sum16, sc_idx 8×16, loop_used/hit/pred, loop_idx16, loop_tag16}, predict_next_fetch_address32（`need_mini_flush`、`dummy_entry` 恒 0）|
| `front2back_FIFO` | 32 | 2648 | predecode 通过后写入（1791–1815）| → 后端输出 `front.out`（1287）| reset \| **仅后端 refetch**（不含 predecode refetch）| `size==32`：`predecode_can_run_old` 的阻塞条件 | 8 lane×{指令32,pf,valid,pred_dir_corrected, base_pc32, 与 PTAB 相同的预测元数据}, predict_next_fetch_address_corrected32 |

位宽、深度由 `tools/widths.cpp` 用真实配置编译得出（TN_MAX=4，tage_idx 10b，tage_tag 8b，`BPU_SCL_META_IDX_BITS=16`，`BPU_LOOP_META_*_BITS=16`，`pcpn` 3b）。
**注意 `sc_idx`/`loop_idx`/`loop_tag` 是 16 位字段**，若实际取值范围更小，RTL 可否收窄需另行核实 [未核实]（按等价性原则 06 第 3 节，只能在确认无消费者读高位之后才能删位）。

### 2.3 8 个 latch 是 size 的函数 [已验证]

`front_state_req.next_*`（1841–1850）由 FIFO 经本拍所有操作后的 `size` 计算，`front_seq_read`（2016–2030）下一拍读回。tap 里同时记录了每拍起始的 `latch` 和 FIFO `size`，在 73 个程序 ≤10 万拍内比较 `latch == f(size)`：

- `fetch_addr`: `full = size>=15`，`empty = size==0`；`instruction`: `full = size==16`；`ptab`: `full = size>=15`；`front2back`: `full = size==32`。
- 全部 0 不一致。复位后初值（`full=0, empty=1`）与 size=0 一致。

**RTL 结论**：不单独建 latch 寄存器；`*_full`/`*_empty` 由 size 组合比较得到（或输出 `size`，上层比较）。

## 3. `front_comb_calc` 步骤表与数据流

### 3.1 FIFO 的"调用协议"（先理解这个，才看得懂步骤表）

每个 FIFO 提供 `*_comb_calc(in, rd, out, next_rd, step_req)`（例如 `fetch_address_FIFO.cpp:165-175`），其中：

- `rd` = 起拍快照（`size, head_valid, head_entry`），由 `*_seq_read` 在 `front_seq_read`（2016–）里读出；
- 每次调用产生一份 `step_req`（`clear/push_en/push_data/pop_en`）和输出 `out`，并按 `build_next_read_data` 算出 `next_rd`；
- `front_comb_calc` 里**调用者自己把 `rd = next_rd`**（例如 1250 行），这样"同拍第二次调用"看到的就是"第一次调用之后的状态"；
- 每次调用后用 `accumulate_*_req`（940–1028）把 `step_req` 合并进整拍的最终请求（`clear |=`，`push/pop` 若重复则 `exit(1)`——**等价于断言"每拍每 FIFO 至多一次 push、一次 pop"**）；
- `front_seq_write`（2055–）按 **`clear → push → pop`** 的顺序一次性应用（`fetch_address_FIFO.cpp:124-142`，PTAB 见 `PTAB.cpp:215-`）。

**一拍内对每个 FIFO 的调用，当前配置下恰为（[已验证]：5 个计数器全为 0）：**

| FIFO | 第 1 次调用（读） | 第 2 次调用（写） | 是否同一次调用既读又写 |
| --- | --- | --- | --- |
| fetch_addr | 1247：`read_enable = fetch_addr_fifo_read_enable_slot0`、`write_enable=false` | 1431：`write_enable=normal_write`、`read_enable=false`、`reset=refetch=false` | 否 |
| instruction | 1278：`read_enable = inst_fifo_read_enable`、`write_enable=false` | 1656：`write_enable=true`（icache 有数据）、`read_enable=false` | 否 |
| PTAB | 1283：`read_enable = ptab_read_enable`、`write_enable=false` | 1726：`ptab_can_write`、`read_enable=false` | 否 |
| front2back | 1287：`read_enable = front2back_read_enable` | 1811：`write_enable = front2back_can_write && !bypass`、`read_enable=false` | 否 |

所以 `*_FIFO_comb` 里的"空队列写穿"分支（`do_read = read_enable && (has_data_before_read || do_write)`，如 `fetch_address_FIFO.cpp:31`）**从未被激活**；每个 FIFO 的等价单步语义（读先于写）是：

```
clear       = reset | refetch                    (各 FIFO 的 refetch 来源不同，见 §2.2 表)
rd_valid    = rd_en & ~clear & (size > 0)        // 读口输出的是起拍队首，不是本拍新写入的
rdata       = head
size_next   = clear ? 0 : size ; size_next += wr_en ; size_next -= rd_valid
内容: clear → push(wdata if wr_en) → pop(head if rd_valid)    // fetch_addr 在 refetch 拍可 "清空后再入队" (实测从未发生, §8)
```

### 3.2 步骤表

下表按**求值顺序**列出 `front_comb_calc` 的每一步。"读"= 该步读取的状态/信号，"写"= 该步产生的信号或累加到的请求。"互斥/死"列标明恒假/互斥路径。行号为原版 `front_top.cpp`。

| # | 行号 | 步骤 | 读 | 写 | 互斥 / 死代码 |
| --- | --- | --- | --- | --- | --- |
| S0 | 1030–1112 | 序言：`rd = front_seq_read()` 快照；清零所有局部 IO；`front_sim_time/front_stats`（统计）| 全部 FIFO 起拍状态、8 latch、`predecode_refetch(+addr)` | 局部结构 | 统计不翻译 |
| S1 | 1117–1154；`front_global_control_comb` 636–645 | **全局控制**：`global_reset = in.reset`；`global_refetch = in.refetch(后端) \| predecode_refetch_q`；`refetch_address = backend ? in.refetch_address : predecode_refetch_address_q` | `in.reset/refetch/refetch_address`, `predecode_refetch_q(+addr)` | `global_reset`, `global_refetch`, `refetch_address` | 后端 refetch 优先于 predecode refetch（地址选择）。`in.reset` 在录制期恒 0（只在 init 调用里为 1）|
| S2 | 1156–1211；`front_read_enable_comb` 647–668 | **读使能**：①`icache_peek_ready()` 得 `icache_ready`（1168，**只读 icache 状态，不改状态**）；②`fetch_addr_fifo_read_enable_slot0 = icache_ready & !fa_empty_q & !reset & !refetch`；③`predecode_can_run_old = !inst_empty_q & !ptab_empty_q & !f2b_full_q & !reset & !refetch`，`inst_fifo_read_enable = ptab_read_enable = predecode_can_run_old`；④`front2back_read_enable = in.FIFO_read_enable` | 4 对 latch、`icache_ready`、`in.FIFO_read_enable` | 4 个读使能 | slot1：`#if FRONTEND_IDEAL_ICACHE_DUAL_REQ_ACTIVE`(=0) 恒 0；`assert(!slot1_candidate)` |
| S3 | 1213–1292；`front_read_stage_input_comb` 670–695 | **FIFO 读调用（第 1 次）**：给 4 个 FIFO 设 `reset/refetch/read_enable`（`front2back` 的 refetch 只取**后端** `in.refetch`，其余取 `global_refetch`），依次 `comb_calc` + `accumulate` + `rd=next_rd`；把输出存 `saved_fetch_addr_fifo_out_0`（1252）| FIFO 起拍状态、S2 使能 | `fa_out0`, `fifo_out`(inst 队首), `ptab_out`(队首), `front2back_fifo_out`(队首)；4 份请求（pop/clear）| 1255–1275 `slot1` 读：`#if` 死代码。读调用的 `write_enable` 都显式置 0 |
| S3' | 1295–1309 | 保存读结果：`saved_fifo_out = fifo_out`, `saved_ptab_out = ptab_out`, `saved_front2back_fifo_out`；初始化旁路变量 | — | 同名 saved_* | — |
| S4 | 1312–1403；`front_bpu_control_comb` 697–746 | **BPU 控制 + 调用**：`bpu_stall = fa_full_q \| ptab_full_q`；`bpu_can_run = !bpu_stall \| reset \| refetch`；`bpu_icache_ready = !fa_full_q`；`bpu_in = {back2front 更新信息, refetch=global_refetch, refetch_address, icache_read_ready = bpu_icache_ready && bpu_can_run}`；**无论是否 stall 都调用** `bpu_seq_read` + `bpu_comb_calc`（1384–1385）；其事务（`bpu_seq_txn`）在 seq 阶段 `bpu_seq_write` 无条件应用 | `fa_full_q`, `ptab_full_q`, `global_*`, `in.*` 更新信息（8 路提交）| `bpu_output`（取指地址/有效、PTAB 写使能与预测载荷、`update_queue_full`…）, `bpu_seq_txn` | in.reset 分支（1375–1383）：只在 init 调用。`mini_flush_*`/`two_ahead_*` 恒 0（§3.4）|
| S5 | 1405–1452 | **fetch_addr FIFO 写**：`normal_write_enable = bpu.icache_read_valid & bpu_can_run & !reset`；`can_bypass_fetch_to_icache`（恒 false）；写条件 `normal_write & !mini_flush_correct & !can_bypass` → 第 2 次调用写入 `bpu.fetch_address` | S3 的 `fa_rd`(已更新)、`bpu_output` | 请求 push | **1416–1421 旁路死**（宏 `FRONTEND_ENABLE_FETCH_TO_ICACHE_BYPASS` 全树未定义 → `#if !X` 为真 → 置 false）；1439–1452 `#ifdef ENABLE_2AHEAD` 死 |
| S6 | 1457–1526 | **icache 请求 + 求值**：`icache_in`（reset/refetch/itlb_flush/fence_i/csr_status）；请求选择 `saved_fetch_addr_fifo_out_0.read_valid ? fifo 地址 : (bypass ? bpu 地址 : 无请求)`；`icache_comb_calc(&icache_in,&icache_out)`（1504）——**内部同时执行 seq**（§3.5） | `fa_out0`, `global_*`, `in.itlb_flush/fence_i`, icache 内部状态 + 外部端口 | `icache_out`（`icache_read_complete`、`fetch_group[8]`、`page_fault_inst[8]`、`inst_valid[8]`、`fetch_pc`） | 1481–1494 `icache_read_valid_2`：`#if` 死 |
| S7 | 1528–1551 | `icache_slot0_data_valid = icache_out.icache_read_complete`；slot1 死（`assert(!slot1)`）| — | `icache_slot0_data_valid` | — |
| S8 | 1555–1700 | **instruction FIFO 写（含 predecode）**：`can_bypass_icache_to_predecode`（恒 false，**1557–1604 的整个 `if` 块死**）；`predecode_can_run = !saved_ptab_out.dummy_entry & inst_fifo_read_enable`（dummy 恒 0）；若 `!inst_fifo_full_for_write & icache_slot0_data_valid & !reset & !refetch`：对 8 lane 逐个 `predecode_comb`（有效 lane 才算，否则 `PREDECODE_NON_BRANCH/0`），`seq_next_pc = sequential_next_pc(...)`，调第 2 次写调用（1656）| `icache_out`, `rd.fifo_full_latch`, `fifo_rd`(已更新) | 请求 push(+熔断入口) | `inst_fifo_full_for_write`：不可达为真（instruction FIFO ≤15 项，§3.4）；slot1 写 1663–1700 死 |
| S9 | 1705–1730；`front_ptab_write_comb` 748–786 | **PTAB 写**：`ptab_can_write = bpu.PTAB_write_enable & !ptab_full_q & !reset & !refetch`，条目来自 `bpu_output.out_*`（`base_pc[i] = bpu.out_pred_base_pc + 4*i`）；第 2 次写调用（1726）| `bpu_output`, `ptab_full_q` | 请求 push | `need_mini_flush`、`push_dummy` 恒 0 |
| S10 | 1733–1763；`front_checker_input_comb` 788–801 | **predecode_checker**：仅在 `predecode_can_run` 时；先做**调试断言** `fifo.pc[i] != ptab.base_pc[i] → exit(1)`（1737–1742，**不翻译，但 RTL 可用断言**）；`predecode_checker_comb`（纯组合，见 `predecode_checker.cpp`）；`checker_out.predecode_flush_enable` → `do_predecode_flush`，冲刷地址 = `predict_next_fetch_address_corrected` | `saved_fifo_out`, `saved_ptab_out` | `checker_out`, `do_predecode_flush`, `predecode_flush_address` | — |
| S11 | 1766–1816；`front_front2back_write_comb` 803–879 | **front2back 写与输出旁路**：`front2back_can_write = predecode_can_run & !f2b_full_q & !reset`；`can_bypass_front2back_to_output = front2back_read_enable & f2b_empty_q & !saved_f2b.valid & front2back_can_write`（**活的旁路**）；旁路时不入队（`write_enable = can_write & !bypass`），输出改取本拍组出的条目（`bypass_front2back_fifo_out`）；条目 = {inst FIFO 队首, PTAB 队首, checker 修正后的 dir/next}，`pcpn/tage_*` 再按位宽屏蔽 | `saved_*`, `checker_out`, `f2b_*_q` | f2b 请求 push、`bypass_front2back_fifo_out`、`use_front2back_output_bypass` | `front2back_can_write` 不要求 `!global_refetch`，但 `predecode_can_run` 已含 `!refetch`；f2b 的 refetch 只看后端 `in.refetch` |
| S12 | 1818–1838 | **predecode 冲刷**：若 `do_predecode_flush`：`icache_comb_calc(invalidate_req=1)`（**第二次 icache 调用**，覆盖 `icache_out`，同样含内部 seq）；`next_predecode_refetch=1, addr=flush_addr`，否则 0 | `do_predecode_flush` | `predecode_refetch(_addr)` 次态 | — |
| S13 | 1840–1851 | **状态刷新**：由各 FIFO 最终 `size` 算 `next_*_full/empty`（8 latch 次态） | 4 个 `*_rd.size`（已累加所有操作） | `front_state_req.next_*` | 冗余，见 §2.3 |
| S14 | 1853–1861；`front_output_comb` 881–929 | **输出**：`out_src = saved_front2back.valid ? FIFO 队首 : (use_bypass ? bypass条目 : FIFO 队首[无效])`；扩展 lane（8..15）填 `INST_NOP/invalid`；`out.predict_next_fetch_address = corrected`；`commit_stall = bpu.update_queue_full` | S3/S11 | `front.out` | `use_bypass` 已含 `!saved.valid` 条件，故二者互斥 |
| S15 | 1862–2010 | 统计（`front_stats` bubble 分类 …）、`front_deadlock_snapshot`、`req.out_regs = out` | — | 无硬件意义 | **整段不翻译** |

### 3.3 数据流图（硬件视角：一拍的组合依赖）

```
                 (寄存器)                                                    (寄存器)
 back2front(in) ─┐          ┌─ predecode_refetch_q ─────────────┐
                 │          │                                    │
   in.reset ─────┤  S1 global_refetch/refetch_address ──────────┼──────────────────────────────┐
                 │          │                                    │                              │
 4×size ──► latches(=f(size)) ──► S2 read-enables ──► S3 FIFO 读 (队首) ───────────────┐          │
                                                                                      │          │
 fa_full_q,ptab_full_q ──► S4 bpu_stall/can_run ─► BPU(comb) ─► bpu_output             │          │
                                  ▲                                │                    │          │
                  (icache_ready:  │ S5: fa 写 = bpu.fetch_address  │ S9: PTAB 写        │          │
                   icache 状态)   │                                ▼                    │          │
 fa 队首(S3) ─────────────────────┼──► S6 icache(comb+seq) ─► icache_out(取回的组)       │          │
                                  │                                │                    │          │
                                  │            S8: predecode(8 lane) ──► inst FIFO 写   │          │
                                  │                                                     ▼          │
                 inst FIFO 队首(S3) ─┐                                          saved_fifo_out    │
                 PTAB 队首(S3) ──────┴──► S10 predecode_checker ──► checker_out ──► S11 f2b 条目  │
                                                │                                      │ │         │
                                                └► do_predecode_flush ─► S12 ─► predecode_refetch_q(次态)
                                                         └► icache 第 2 次调用 (invalidate)
 f2b 队首(S3) ──┬───────────────────────────────► S14 输出 mux ◄── 旁路条目 (S11) ───► front.out ──► 后端
                └ in.FIFO_read_enable ─► S2/S11 (旁路条件)
```

没有组合环：`S4` 只依赖起拍 latch；`S6` 依赖 S3 的 FIFO 队首与 icache 内部寄存器；`S10/S11/S14` 依赖 S3、S6/S8、S9 的结果。唯一的"长路径"是 FIFO 队首 → checker → f2b 条目 → 输出旁路 → 后端（同拍）。

### 3.4 死代码 / 恒定路径清单（带证据）

| 路径 | 为何死 | 证据 |
| --- | --- | --- |
| slot1 / 双请求（`icache_read_valid_2`、`fetch_addr_fifo_read_enable_slot1`、`icache_slot1_data_valid`、`can_write_slot1`）| `FRONTEND_IDEAL_ICACHE_DUAL_REQ_ACTIVE` = 0（需 `FRONTEND_ICACHE_MODE==1`，现为 0，`frontend_feature_config.h:296-329`）；另有 `assert(!slot1...)` | front_top.cpp 656–660, 1196, 1255–1275, 1481–1494, 1539–1546, 1663–1700 |
| 2-ahead / `mini_flush_*` / `two_ahead_*` / PTAB dummy 项 | `FRONTEND_DISABLE_2AHEAD` 已定义（`:285`）→ `ENABLE_2AHEAD` 不定义；`need_mini_flush`、`push_dummy_en`、`saved_ptab_out.dummy_entry` 全程恒 0 | 73 程序 ≈126 万拍内 `dead_bpu_mini_flush_req/correct`、`dead_bpu_two_ahead_valid`、`dead_ptab_dummy_*` 全部 0 次 [已验证]；front_top.cpp 1439–1452（`#ifdef`）|
| `fetch→icache` 旁路（`can_bypass_fetch_to_icache`）| `FRONTEND_ENABLE_FETCH_TO_ICACHE_BYPASS` 在整个源码树里**从未定义**（grep 无任何 `#define`），`#if !X` 为真，强制置 false | front_top.cpp 1416–1421；`ev_bypass_fetch_to_icache` 0 次 [已验证] |
| `icache→predecode` 旁路 | 同理 `FRONTEND_ENABLE_ICACHE_TO_PREDECODE_BYPASS` 未定义，1557–1563 强制 false，1564–1604 整块死 | 0 次 [已验证] |
| FIFO 内部"空队列写穿"（`do_read` 的 `|| do_write`）| 读调用 `write_enable=0`，写调用 `read_enable=0`（§3.1 表）| `fifo_*_pop_when_empty_at_start`、`fifo_fa_write_through_would_be_needed` 全 0 [已验证] |
| instruction FIFO 满 / `inst_fifo_full_for_write` 为真 / 写被丢弃 | 结构上不可达：PTAB 每项先于 inst FIFO 项出现，`ptab_size ≤ 15`（`bpu_stall` 在 `ptab_size≥15` 时阻止新入队）⇒ `inst_size ≤ ptab_size ≤ 15 < 16` | 每拍检查 `inst_size ≤ ptab_size`、`fa_size ≤ ptab_size`、`ptab_size ≤ 15`，73 程序 0 违例 [已验证]；`max_size_inst/ptab = 15` |
| fetch_addr FIFO 在 refetch 拍"清空后再入队" | BPU 在 refetch 拍不发取指请求 | `ev_fa_push_on_refetch_cycle`（`fa clear&&push`）0 次 [已验证]（但 RTL 仍按 `clear→push` 实现更安全）|
| `global_reset` 路径 | 录制窗口内 `in.reset` 恒 0（复位只发生在 `FrontTop::init()` 的 `step_bpu`，早于第一个钩子拍）| `tap_count = cycles+1` [已验证]；见 §8.3 |
| `fetch_addr_fifo_read_enable_slot1_candidate`、`predecode_can_run_old`/`(void)`、`refetch_write_enable`、`front_sim_time` | 无效果的中间量 | 读代码 |

### 3.5 ICache 与 BPU 的"调用语义"（影响 RTL 划分）

- **`icache_comb_calc` = comb + seq 熔合**（`icache/icache.cpp:258-349`）：函数里先 `instance->comb()`（314 行），再 `instance->seq()`（316 行），随后立即写 `data/tag/valid` 表（`data_table.seq(...)`，351–353 行），`icache_seq_write()`（360 行）是空函数。所以 **ICache 状态在 `icache_comb_calc` 被调用的那一刻就已更新**。
- 同一拍里 icache 被调用：`icache_peek_ready`（1 次，只算 `icache_read_ready`，不改状态，`ICacheTop.cpp:819-824`）；`icache_comb_calc`（1 次，请求/应答）；**若 `do_predecode_flush`，再 1 次** `icache_comb_calc(invalidate_req=1)`（前端 1822–1828）。第二次调用等价于**同一 CPU 周期内状态再推进一步**（`cancel_pending_req = refetch | invalidate_req | fence_i`，`ICacheTop.cpp:929`）。RTL 必须把这个"双步推进"合成一个单步次态函数（04 §3.2，**需评审**）。
  → 在 73 个程序里 `ev_checker_flush`（= 触发第二次调用的拍）共 4796 次 [已验证]，不罕见。
- ICache 的 `in`/`out` 指针指向 `front_comb_calc` 的**栈局部变量**（`ICacheTop::setIO` 保存指针）；因为 `icache_seq_write()` 为空且 seq 已在 comb 里执行，不会真的悬空读取。[未核实] 是否在别处用到保存的指针（`dump_debug_state` 例外）。
- **BPU**：`bpu_seq_read`/`bpu_comb_calc`/`bpu_seq_write` 三段分离，`bpu_seq_write` 在 `front_seq_write` 里统一应用（符合 comb/seq 规范）。注意 **BPU 被 stall 时也会求值并推进状态**，靠输入 `icache_read_ready=0` 自行不前进（1325–1330, 1384）。

## 4. 建议的 RTL 模块划分

### 4.1 总览

```
                      ┌───────────────────────── front_top (RTL 集成层，纯连线 + front_ctrl) ───────────────┐
 back2front 寄存器 ──►│  front_ctrl ──► bpu ──────────────► ttg_fifo[PTAB]   ┐                              │
 (reset,refetch,…)    │     │            ▲  (icache_ready? 否: !fa_full)     │                              │
                      │     │            │                  ttg_fifo[fetch_addr] ──► icache ──┐            │
                      │     │            │                                                    ▼            │
                      │     │            └── 更新信息(提交)               predecode×8 ──► ttg_fifo[inst]   │
                      │     │                                                  │                          │
                      │     └──► predecode_checker ◄── inst 队首 + PTAB 队首 ──┘                          │
                      │                  └──► ttg_fifo[front2back] ──► 输出 mux/旁路 ──► front.out ──► 后端 │
                      └──────────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 候选模块、边界信号、难度

难度：★ 机械翻译；★★ 需要重构但边界清晰；★★★ 大模块/需评审；★★★★ 巨大。"录制"列说明用什么 spec 与哪种钩子（见 `frontend-record-hook.md`）。

| 模块 | 内容 | 边界（输入 → 输出）| 难度 | 状态 | 录制 |
| --- | --- | --- | --- | --- | --- |
| **`predecode`**（8 lane，纯组合）| `predecode.cpp`：`inst,pc → type(2b), target(32b)` | `in: inst[8], pc[8]`（有效 lane 才有意义）→ `out: type[8], target[8]` | ★ | 无 | **随机即可全覆盖**（golden=C++ 函数，输入 40 位，可 100% 随机；也可穷举 opcode×立即数位）。真实程序录制：tap 里 `saved_fifo_out.predecode_*` 或 `icache_out`/`predecode`（需要时再加 tap，本报告未加） |
| **`predecode_checker`**（纯组合）| `predecode_checker.cpp` 全函数 | `in: predict_dir[8], predecode_type[8], predecode_target[8], seq_next_pc, predict_next_fetch_address → out: predict_dir_corrected[8], predict_next_fetch_address_corrected, predecode_flush_enable` | ★ | 无 | tap：`TTG_FT.checker_in/checker_out`（只在 `predecode_can_run` 为 1 的拍有效，用 `when`/或把 `predecode_can_run` 当输入使能）。随机可全覆盖 |
| **`sequential_next_pc`**（纯组合，`front_top.cpp:78-96`）| `fetch_pc, inst_valid[8] → seq_next_pc`（有效前缀长度 + 行内截断）| 写在 `front_top` 或单独小模块 | ★ | 无 | 随机 |
| **`ttg_fifo`**（参数化 1R1W，读先写后，`clear→push→pop`）| 4 个实例：`fetch_addr`(16×32)、`inst`(16×832)、`ptab`(16×2378)、`f2b`(32×2648) | `in: clear(reset|refetch), rd_en, wr_en, wdata → out: rd_valid, rdata, size`（`full/empty` 组合自 size）| ★ | 无 | 入队侧（`req.*_req`）tier-0 即可读；出队数据（`saved_*_out`）需要 tap。4 个 FIFO 的 spec 已写好并录制+自洽检查通过：`examples/{fetch_addr_fifo,inst_fifo,ptab,front2back_fifo}.io`，骨架相同 |
| **`front_ctrl`**（组合 + `predecode_refetch` 寄存器）| S1、S2、S4 的 `bpu_stall/can_run/icache_read_ready`、S5/S9 的写使能、S10 取 `do_predecode_flush`、S11 的 `front2back_can_write/旁路`、S14 输出 mux | 见 4.3 | ★★ | 隐含依赖：见下 | tap 已含全部使能（`TTG_FT.*_enable/*_can_write/use_*bypass/…`） |
| **`bpu`**（`BPU_TOP`）| TAGE-SC-L + Loop + BTB + TypePredictor + RAS + NLP + 更新队列(Q_DEPTH=2)，8 bank | `BPU_TOP::InputPayload`（`front_IO`… `BPU.h:115-143`）→ `OutputPayload`（`:145-178`）| ★★★★（~6k 行）| 无 | 输入 = `req.bpu_seq_txn.inp`（可直接读，无需 tap）；输出 = `TTG_FT.bpu_out`（tap）。BPU 可**脱离整核用随机更新流驱动**（§7）|
| **`icache`**（含 `ICacheTop` 胶合、ITLB 胶合、外部表模型）| `icache_module.cpp/ICacheTop.cpp/icache.cpp`，GenericTable（regfile/SRAM 表），AXI 读口、DCache 探针口、MMU/PTW 口 | `icache_in/out`（`front_IO.h:117-152`）+ 存储侧端口（`ReadMasterPort_t`、`ICacheMemPortReq/Resp`、`PtwMemPort/PtwWalkPort`）| ★★★★ | **双步次态合并**（§3.5）| tap 含主调用的 `icache_in/out`；**存储侧端口当前未抓**（需第二个 tap，§6 待办）|
| **`front_top`**（集成）| 把以上连起来；对外 `front_top_in/out` | 同 `front_top_in/out`（`front_IO.h:10-56`）| ★★ | — | `front.in/front.out` 直接读（tier-0）|

> 与 BPU 的粘合：`BPU_in`/`FrontBpuInputCombIn`（931–938）里 `refetch=global_refetch`、`icache_read_ready = !fa_full_q && bpu_can_run`——"icache_read_ready"这个名字有误导：它**不是** icache 的 ready，而是"fetch_addr FIFO 没满"。

### 4.3 `front_ctrl` 的边界信号（建议作为第一个"前端控制"spec 的字段）

输入（全部在起拍可得，无组合依赖链）：
`in.reset`, `in.refetch`, `in.refetch_address[32]`, `in.FIFO_read_enable`, `predecode_refetch_q`, `predecode_refetch_address_q[32]`, 4 个 FIFO 的 `size`（或 latch）, `icache_ready`（`icache_peek_ready`）, `bpu.icache_read_valid`, `bpu.PTAB_write_enable`, `bpu.update_queue_full`, `saved_fifo_out.valid/ptab.valid`（来自 FIFO 读）, `checker_out.predecode_flush_enable`, `checker_out.predict_next_fetch_address_corrected`, `saved_front2back.valid`。

输出：
`global_reset`, `global_refetch`, `refetch_address`, 4 个 FIFO 的 `clear/rd_en/wr_en`, `bpu_in.refetch/refetch_address/icache_read_ready`, `bpu_can_run`, `bpu_stall`, `predecode_can_run`, `ptab_can_write`, `front2back_can_write`, `can_bypass_front2back_to_output`, `do_predecode_flush`, 次态 `predecode_refetch(_addr)`, `commit_stall`。

纯组合（除 `predecode_refetch` 一个 33 位寄存器）；**输入只有十几位控制 + 少量地址，可穷举/随机**（§7）。

### 4.4 需要重构成真正数据流的 C++ 写法（对应 04 §3.2/§3.3）

| # | C++ 写法 | 位置 | RTL 写法 | 评审 |
| --- | --- | --- | --- | --- |
| R1 | FIFO 两次调用 + `rd = next_rd` 链式推进 + `accumulate_*` | 1247–1287, 1431, 1656, 1726, 1811；940–1028 | 每个 FIFO 一个 `ttg_fifo` 实例，一次 `clear/rd_en/wr_en`；`accumulate` 的"重复请求 exit"改为仿真断言 | 需要（04 §3.2 要求）|
| R2 | `saved_*` 变量在读调用与写调用之间"锁住"读结果 | 1295–1309 | 读结果就是 FIFO 的组合读口（起拍队首），天然在写之前 | 随 R1 |
| R3 | `predecode_can_run` 里 "bypass \|\| inst_fifo_read_enable" | 1606 | 化简为 `inst_fifo_read_enable`（bypass 死）；在 spec/笔记里写明来源 | 需要（登记死代码）|
| R4 | `icache_comb_calc` 熔合 comb+seq，并可被调用两次 | icache.cpp 258–349；front_top 1822–1828 | ICache 模块 = 单拍次态；把"第二次 invalidate 调用"合进同一次态函数（输入增加 `invalidate_req` 且与 refetch 同拍作用顺序固定）| **必须评审** |
| R5 | `predecode_refetch` 经 `front_state_req` 的"次态"传递 | 1829–1835, 2064–2075 | 显式 33 位寄存器 | 否 |
| R6 | 统计/调试（`front_stats`、`front_deadlock_snapshot`、`falcon_*`、`FRONTEND_HOST_PROFILE_SCOPE`、`DEBUG_LOG_*`、`dump_front_focus_*`、`exit(1)` 打印）| 全文件 | 不翻译；`exit(1)` 的检查改为 SV assert | 否 |
| R7 | `front_top_out` 的扩展 lane（8..15）| 906–912 | 常量 `INST_NOP/invalid` | 否 |
| R8 | 隐含依赖（04 §3.1）：前端内部**没有**读"更晚阶段写的上拍残留值"的路径——所有 `rd.*_snapshot` 都是真寄存器值；唯一的"上拍值"是 `front.back2front`（寄存器）| — | — | 已核对代码路径 [未做 `CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN` 实验，该开关只清后端 IO] |

### 4.5 FIFO 模块（最先做，规模最小，复用最多）

`ttg_fifo #(DEPTH, W)`：

- 端口：`clk, rst_n, clear, rd_en, wr_en, wdata[W], rd_valid, rdata[W], size`。`full/empty` 在模块外由 size 比较给出（因四个 FIFO 阈值不同）。
- 实现注意：C++ 用数组移位（`entries_[i-1]=entries_[i]`）；RTL 用环形缓冲读指针即可，行为等价（读口只能看队首）。
- 与 `fifo/FIFO_RTL_TEMPLATE_MAPPING.md` 不同的点：那份文档的"空队列写穿"和"PTAB dummy 第二次 push"在当前配置下都不会发生（§3.4），**不需要实现**，但 `ttg_fifo` 的 `rd_valid = rd_en & ~clear & size>0` 要与实验一致；若将来打开 2-ahead 才需要。
- 位宽：直接把 FIFO 条目做成 `packed struct`，`W` 来自 `ttg_cfg_pkg`（`TN_MAX`、`FETCH_WIDTH` 等已在 `config.h`）。**注意 `config.h`/`frontend_feature_config.h` 里还有 `INSTRUCTION_FIFO_SIZE/PTAB_SIZE/FETCH_ADDR_FIFO_SIZE/FRONT2BACK_FIFO_SIZE`、`BPU_SCL_META_*_BITS` 等前端专有宏，`make cfg` 目前是否导出它们 [未核实]。**

### 4.6 BPU（仅边界与风险，未细读内部）

- 输入 `InputPayload`：`refetch, refetch_address, icache_read_ready` + 8 路提交更新（`in_update_base_pc/in_upd_valid/in_actual_dir/in_actual_br_type/in_actual_targets/…/in_tage_*/in_sc_*/in_loop_*`）。输出 `OutputPayload`（取指地址/有效、PTAB 写使能与全部预测载荷、`update_queue_full`、2-ahead 字段[死]）。
- 子模块（同目录）：`dir_predictor/TAGE_top.h`(1893 行)、`target_predictor/BTB_top.h`(1432)、`type_predictor/TypePredictor.h`(434)、`BPU.h`(2068)、`BPU_configs.h`(261)。内部用 `bpu_seq_read/bpu_comb_calc/bpu_seq_write` 三段式，`BPU_TOP::ReadData`（180–260）和 `UpdateRequest`（280–345）可作为内部边界。
- **风险**：①体量最大；②`g_bpu_top` 全局指针（front_top.cpp:30 附近）供 TAGE 访问 BPU 的 GHR/FH，是**隐含全局依赖** [未核实具体读取点]；③BPU 的内部随机/LFSR 行为（`tage_lsfr_rand_t`）需确定性复现 [未核实]。
- 录制：输入 `req.bpu_seq_txn.inp`（tier-0）；输出 `TTG_FT.bpu_out`（tap，字段已全部复制）；**不要**从整核程序里指望覆盖 BPU 的边角，用 §7 的随机更新流。

### 4.7 ICache 簇（仅边界与风险，未细读内部）

- 模块 `icache_module_n::ICache`（`icache_module.h`）已是 RTL 风格：显式 `io.in / io.out / io.regs / io.table_write`，`comb_lookup_meta/comb_lookup_data/seq`。外加：`ICacheTop`（胶合：把 MMU/PTW/AXI 视图折进 `icache_module` 接口）、`GenericTable`（regfile 或 SRAM 延迟模型的 data/tag/valid 表，`tools/emit_generic_table_verilog.py` 已有 Verilog 生成器）、`ICacheCompactKernel.h`(2373 行)/`ICacheTopTrueGlueKernel.h`/`ICacheLookupMetaPackKernel.h`（看起来是生成的"内核"，**未核实其性质和等价性来源**）。
- 外部接口：前端侧 `icache_in/out`；存储侧 `axi_interconnect::ReadMasterPort_t`（`req.valid/addr/total_size/id/bypass`，`resp.ready` ← `accepted/ready/resp valid/id/data[16 words]`）、DCache 探针口（`ICacheMemPortReq{req_valid,req_addr}` / `ICacheMemPortResp{resp_valid,resp_retry,resp_miss,resp_data}`）、`TlbMmu`（ITLB，64 项）+ `PtwMemPort/PtwWalkPort`。
- 时序：icache 在 `axi_subsystem_comb_outputs` 之前求值，读到的端口值是**上一拍末的残留**；其请求输出（`comb_accept`）在本拍写入端口，供后面的 `axi_subsystem_comb_inputs`（1125 行前）使用。这是 ICache 与 AXI/MemSubsystem 之间的**跨拍握手**，边界设计时必须把"端口值在 icache 求值那一刻的快照"当作模块输入 [未核实具体哪些端口字段在 icache 求值时已是"新值"]。
- 状态：`icache` 是全局 `icache_module_n::ICache icache;`（icache.cpp:20），其 `io.in/out/regs` 在 hook 时可直接读（tier-0）但**反映的是最后一次 comb 调用**（predecode 冲刷拍里是第二次 invalidate 调用）；要拿第一次调用的值需要 icache 专用 tap（建议放进 `icache_comb_calc` 两处调用之后）。

### 4.8 建议的翻译顺序

| 顺序 | 任务 | 依赖 | 规模 | 难度 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 1 | `predecode` + `sequential_next_pc` + `predecode_checker` | 无 | 各 ~60 行 SV | ★ | 先出随机 golden 生成器（§7）验证，不依赖整核录制 |
| 2 | `ttg_fifo` + 4 个实例的 spec/回放 | 无（可与 1 并行）| ~80 行 SV + 4 份 spec | ★ | PTAB/f2b 的 spec 骨架见 `examples/ptab.io`；注意 spec 记录大（PTAB 776 B/拍）|
| 3 | `front_ctrl`（含 `predecode_refetch` 寄存器）| 1、2（接口）| ~150 行 | ★★ | 十几位控制输入，可穷举；再用 tap 全量回放 |
| 4 | `front_core` = 3 + 1 + 2 + 输出旁路，**BPU/ICache 当作 trace 输入** | 1–3 | 集成 ~300 行 | ★★ | 以 tap 的 `bpu_out`、`icache_out` 当输入、`icache_in/bpu_in` 当输出做开环回放：此时前端"除 BPU 与 ICache 之外"整体闭合 |
| 5 | `bpu` | — | ~数千行 | ★★★★ | 可从第 1 步起**并行**开工（独立边界）；建议再拆 TAGE/BTB/Type/RAS/NLP 子任务（需 BPU 细读）|
| 6 | `icache` 簇 | ITLB/AXI 口边界（需另一个 tap）| ~数千行 | ★★★★ | **R4 评审**必须先做；MMU/PTW/AXI 的边界要与 MemSubsystem 负责人对齐 |
| 7 | `front_top` 闭环 | 1–6 | 连线 | ★★ | 最后做；闭环对比 `front.out` 逐拍哈希 |

## 5. 隐含依赖表（本报告对 04 第 3 节表的补充登记）

| 模块 | 信号 | 类型 | 读取点 | 写入点 | RTL 处理 |
| --- | --- | --- | --- | --- | --- |
| front | `predecode_refetch(_addr)` | 3.1（跨拍寄存，显式）| S1（1117–）| S12 → `front_seq_write` 2064–2075 | 显式 33 位寄存器（真状态，非残留）|
| front | 8 个 full/empty latch | 冗余寄存 | S2/S4/S8/S9/S11 | S13 | 改为 `f(size)`，**已验证等价** |
| icache | 状态在一拍内被推进 1 次或 2 次 | 3.2（同拍多次求值）| S6、S12 | `icache_comb_calc` 内部 seq | 合并为单拍次态（R4）|
| front→back | `front2back_hold`（SimCpu 顶层寄存器）、`no_taken` 截断 | 顶层胶合 | `SimCpu::cycle` 1065；`front_comb_before_back` 1227–1262 | 1129/1141 | 不在前端模块内，登记给 Pre-IDU/顶层 |
| bpu | `g_bpu_top` 全局指针（TAGE 读 GHR/FH）| 全局隐含依赖 | TAGE_top.h [未核实] | front_top.cpp | BPU 翻译时处理 |
| back→front | `front.in` = 上一拍末的 `back2front`（含 `refetch`）| 寄存器输入 | S1 | `SimCpu::back2front_comb` 1360–1460 | 接口为寄存输入，无需特殊处理 |

## 6. 录制能力小结（细节见 `frontend-record-hook.md`）

| 需要的量 | 现有钩子（tier-0）能读？ | 加 tap 后 |
| --- | --- | --- |
| `front.in` / `front.out` | 是（`cpu.front.in/out`）| — |
| FIFO 起拍状态（size/队首）| 是（`cpu.front.read_data_->*_rd_snapshot`，私有成员，插件以 `private=public` 编译）| 也复制进 tap |
| FIFO 最终 push/pop/clear 请求与入队数据 | 是（`cpu.front.update_req_->*_req`）| 复制 |
| BPU 输入 | 是（`update_req_->bpu_seq_txn.inp`）| — |
| `icache_ready`、icache 请求与应答、BPU 输出、FIFO 读结果、checker 输入输出、各使能/旁路、冲刷、8 latch 与次态 | **否**（局部变量）| **是**（tap，本报告提供）|
| icache 存储侧端口（AXI/DCache 探针/PTW）| 否 | **否**（待办：icache 专用 tap）|
| BPU 内部状态 | 部分可经 `bpu_instance`（static，不可直接引用）| 否 |

## 7. 随机生成器可以驱动的类（对应问题 d 后半）

trace 文件格式与回放器不关心数据来源，所以"生成器 = 另一种录制器"：用 C++ golden 模型 + 随机输入直接写 `.trc`。

| 类 | 可随机化程度 | golden | 备注 |
| --- | --- | --- | --- |
| `predecode`、`sequential_next_pc`、`predecode_checker` | **完全随机/可穷举**（纯组合）| 参考模型函数本身 | 真实程序里 `PREDECODE_JALR` 目标、`jal predicted-not-taken`（`ev_checker_jal_predicted_not_taken` 4.4 万次）已覆盖，但立即数边界（符号位、页边界）靠随机 |
| `ttg_fifo` ×4 | **约束随机**：随机 push/pop/clear 序列，约束 = 不在满时 push、`clear` 与 `push` 的组合按 §3.1 | 4 个 FIFO 的 C++ `*_comb` + `seq_write`（或 `check_fifo_trace.py` 的 Python 模型）| 真实程序**覆盖不到** size==16/32 的 instruction/PTAB（结构不可达，不需要）；f2b 满在 18 个程序出现 |
| `front_ctrl` | 完全随机/穷举（十几位控制）| `front_*_comb` 小函数（636–929）| 同时覆盖 `reset`/`global_reset` 这些真实程序里没有的路径 |
| `bpu` | **随机更新流 + 随机取指地址**，约束 = 更新必须对应已预测的分支（否则 TAGE 元数据无意义，**[未核实]**）| `BPU_TOP` C++ 类（头文件库，可独立实例化；需提供 `g_bpu_top`）| 弥补 `update_queue_full`（真实程序 0 次）等盲区 |
| `icache` | 需要**环境模型**：随机地址 + 存储模型（随机延迟 AXI 读口）+ ITLB/PTW 模型 | `icache_module_n::ICache` + `ICacheTop` | 约束随机，难度高；真实程序只覆盖 MMU 关闭为主 |
| `front_core`（整合）| 不适合随机（需要 BPU/ICache 的相容输出）| — | 用整核录制 trace 回放 |

## 8. 覆盖盲区（真实程序下）——实测

方法：`tools/cov.cpp` 在 tap 上逐拍计数，73 个程序（61 个 gate 测试 + dhrystone/coremark/coremark10 + 4 个 vm 测试 + 5 个 extra baremetal）每个最多 10 万拍，合计 126.5 万拍；原始汇总见 `data/frontend_coverage_73prog_100kcyc.txt`（"#prog"=出现该事件的程序数，缺失的 key = 0 次）。同一次运行里 cov.cpp 还做了**独立 FIFO 模型一致性检查**：对每个 FIFO 用"提议的模块边界信号"驱动一个标准 FIFO 模型，核对读有效、队首标签、次态 full/empty、`pop_en`，以及 9 条结构不变量——**全部程序 0 次不一致**。

### 8.1 已被真实程序充分覆盖

| 事件 | 次数 / 程序数 | 说明 |
| --- | --- | --- |
| 后端 refetch | 14543 / 73 | |
| predecode 冲刷（checker flush → 下拍 refetch）| 4796 / 73 | |
| 后端与 predecode refetch **同拍** | 217 / 36 | 后端优先的地址选择 |
| BPU 反压（fa 满/PTAB 满）| 34 万 / 73（**全部是 PTAB 满**，`bpu_stall_fetch_addr_full` 0 次）| `fa` 的 full 标志**从未单独起作用**（fa≤ptab 恒成立）|
| f2b 输出旁路 | 60 万 / 73 | 活的旁路 |
| f2b 非旁路出队（FIFO 非空）| 20.7 万 / 22 | 只有 22/73 个程序的 f2b 曾非空 |
| f2b 满（32）| 33.9 万拍 / 18 | 反压 `predecode_can_run_old` |
| icache 缺失事件 / 缺失忙 / 未就绪 / 部分有效组 | 4142 / 3.3 万 / 6.2 万 / 30.2 万 | 全部 73 个程序都出现 |
| `fence_i` | 194 / **3 个程序**（smc-addi, smc-div, fence-i-self-modify）| 触发 icache 全清，样本少 |
| 后端 stall（`FIFO_read_enable=0`）| 36.6 万 / 73 | |

### 8.2 盲区（真实程序里**没有**或极少）

| 盲区 | 次数 | 原因 / 对策 |
| --- | --- | --- |
| `global_reset` / `in.reset` 路径 | 0（录制窗口内）| 复位只在 `init()`；harness 的 3 个复位拍不比较输出。RTL 复位值只能靠"复位后首拍行为"验证 + 随机 `front_ctrl` |
| `commit_stall`（BPU `update_queue_full`）| **0** | 提交更新队列(Q_DEPTH=2)从未满。需要 BPU 随机更新流 |
| fetch_addr FIFO"清空且同拍入队" | 0 | BPU 在 refetch 拍不发请求；RTL 仍实现 `clear→push` |
| `ev_itlb_*`（ITLB miss/fault/retry）| 仅 `vm_sum_fetch_test` 1 个程序（13 拍）| 靠 vm 测试，样本极少；需要 ICache 环境随机 |
| `itlb_flush` | 9 次 / 4 个程序 | 同上 |
| icache page fault 组 | 1 次 / 1 个程序 | 同上；`predecode_pagefault_group` 也只 1 次 |
| FIFO 满（instruction=16、PTAB=16）、写丢弃 | 0 | 结构不可达（§3.4），不需要覆盖 |
| 2-ahead / mini flush / dummy PTAB / slot1 / 两个旁路 / 写穿 | 0 | 死代码（§3.4）|
| 预测元数据的数值边界（`sc_idx/loop_idx/loop_tag` 高位、`tage_idx/tag` 全范围）| 未统计 [未核实] | FIFO 只是搬运；在 BPU 的随机驱动里覆盖 |
| `seq_next_pc` 跨行截断（`next_pc & line_mask` 分支）| 未单独统计 [未核实]；"部分有效组"30 万次间接覆盖 | 随机 `sequential_next_pc` 覆盖 |
| ICache 多路替换/随机替换（`replace_idx`）、AXI 反压/乱序、DCache 探针 retry | 未统计 [未核实] | ICache 环境随机 |

### 8.3 其它实测发现

- `tap_count == cycles + 1`（`cov/smc-div.txt`：`tap_count_last 8997` vs `cycles 8996`）：多出的一次是 `FrontTop::init()` 里的复位调用，说明前端复位在第一个钩子拍**之前**；harness 的 3 个复位拍对前端是"凭空"的，RTL 复位态必须 = `init()` 之后的态（BPU 复位 + FIFO 清空 + 锁存器 `full=0/empty=1` + `predecode_refetch=0`）。
- `ev_bpu_ptab_we_ne_icache_valid` 很大（34 万拍）但 `PTAB_write_enable == icache_read_valid && bpu_can_run` **每拍成立**（`inv_ptab_we_eq_issue` 0 违例）——BPU 在 stall 时输出里的 `icache_read_valid` 可以为 1 但不会写 PTAB/fa，所以 RTL 里 `can_run` 门控必须保留。
- `fa push == ptab push`（非 refetch 拍每拍成立）：fetch_addr FIFO 与 PTAB 严格同步入队。

## 9. 待核实 / 开放问题（汇总）

1. BPU 内部（TAGE/BTB/Type/RAS/NLP/更新队列）：边界之外的全部细节、`g_bpu_top` 使用点、LFSR 确定性。
2. ICache 簇内部：`*Kernel.h` 的性质；存储侧端口在 icache 求值时刻的"新/旧值"；DCache 探针 `resp_*` 的来源阶段；`ICacheTop` 保存的 `in/out` 指针别处是否被读。
3. 预测元数据位宽是否可收窄（`sc_idx` 16b ×8 等）。
4. `make cfg` 是否导出前端专有宏。
5. `front2back_hold`/`no_taken` 的归属（Pre-IDU 还是顶层胶合）。
6. 实验只覆盖默认 profile（`PROFILE=default`）；`small/medium/large` 配置下 FIFO 深度等可能不同（只确认了 `frontend_feature_config.h.default` 与当前文件相同）。
