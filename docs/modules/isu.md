# isu 设计笔记

## 1. 对应的 C++
- `back-end/Isu.cpp`（`Isu`：comb_begin/ready/awake/calc_latency_next/enq/issue/flush/seq）、`include/Isu.h`、`include/IssueQueue.h`（`IssueQueue`，5 个实例 IQ_INT/LD/STA/STD/BR，配置见 `config.h` 的 `GLOBAL_IQ_CONFIG`、`GLOBAL_ISSUE_PORT_CONFIG`）。
- BackTop 调用顺序（`BackTop::comb`）：`isu.comb_begin` → `comb_ready` → … → `comb_issue` → … → `comb_awake` → `comb_calc_latency_next` → … → `comb_enq` → … → `comb_flush`；`seq` 在时钟沿。
- 输入（边界）：`dis2iss.req[IQ][8].{valid,uop}`、`prf_awake.wake[4]`、`exe2iss.fu_ready_mask[22]`、`rob_bcast.flush`、`dec_bcast.{mispred,br_mask,clear_mask}`。
- 输出：`iss2dis.ready_num[5]`（读者：`Dispatch::comb_alloc/comb_dispatch`）、`iss2prf.iss_entry[22]`（读者：`Prf::comb_req_ftq/comb_read`）、`iss_awake.wake[15]`（读者：`Dispatch::is_preg_woken/comb_wake`）。
- 配置（config.h）：IQ_INT 128 项、6 口（口 0..5，全部 ALU；口 0 另有 MUL+CSR，口 1 DIV+FP，口 2 MUL，口 3 DIV）；IQ_LD 64 项 4 口（6..9）；IQ_STA 64/4（10..13）；IQ_STD 64/4（14..17）；IQ_BR 64/4（18..21）；每队列入队宽 8。**调度策略 `ISSUE_SCHEDULE_POLICY = IQ_SLOT_PRIORITY`（槽号小者优先）**，`ROB_OLDEST_FIRST` 分支是死代码（常量未选中），不翻译 —— 因此“年龄”就是槽号，不需要年龄矩阵。

## 2. 硬件结构
```
 dis2iss[q][w] ─► isu_iq[q] (x5, 参数: SIZE / DW / NP / 端口能力)
                    ├ isu_alloc_chain : 第 k 个有效请求 -> 第 k 个空闲槽 (入队，槽号小者先)
                    ├ isu_iq_store    : valid / uop / wait1 / wait2 寄存器，入队写、唤醒清 wait、flush、clear
                    └ isu_iq_select   : ready -> 逐端口优先选择(链式 first_set，前面端口选走的槽被排除)
 isu_wake_src  : 15 条唤醒通道 = prf_awake(4) | MUL 末级(2) | DIV 计数槽(2) | FP 计数槽(1) | 快速唤醒(6)
   ├ isu_wake_iter x2 (DIV、FP 倒计时槽)   ├ isu_wake_mul (MUL 移位管线)
 isu_wake_bus  : 15 通道 -> 128 位 preg 位图，供 5 个 IQ（含入队时的“叠加唤醒”）查表
 isu (top)     : 端口适配 + 把 IQ 的授予拼到 22 个物理端口
```
- 状态：每 IQ `valid_q[SIZE]`、`uop_q[SIZE]`（isu_uop_t：除 dbg 与 src*_busy 外的全部字段）、`wait1_q/wait2_q[SIZE]`（= `src_en & src_busy`，即“还在等这个源”）。延迟唤醒：MUL `valid/dest_preg/br_mask [DEPTH=1][2]`，DIV `valid/countdown/dest_preg/br_mask [2]`，FP 同 `[1]`。无计数器寄存器：IQ 空闲数 = SIZE − popcount(valid_q)。
- 读写端口：每 IQ 存储每槽 1 个写端口（8 路入队独热 AND-OR 选一）、`NP` 个读端口（选出槽的 uop 独热 AND-OR）。
- C++ → 硬件对应：
  | C++ | RTL |
  | --- | --- |
  | `entry/entry_1`、`count` | `valid_q/uop_q`、`popcount(valid_q)` |
  | `wake_matrix_src1/2`（preg→槽位图）、`comb_wakeup` 的 while/ctz | 128 位唤醒位图 + 每槽按 `src_preg` 查表（等价于 CAM，见第 4 节核对） |
  | `schedule()`、`ready_indices`、`inst_issued` | `isu_iq_select` 的逐端口链式 `ttg_first_set` |
  | `enqueue()` 扫描第一个空槽 | `isu_alloc_chain`（逐请求链式 first_set，无效请求不消耗） |
  | `mul_wake_pipe` / `div_wake_slots` / `fp_wake_slots` | `isu_wake_mul` / `isu_wake_iter` |
  | `alloc_iter_slot`、`alloc_mul_stage0` | 同一个 `isu_alloc_chain`（第 k 个请求 -> 第 k 个空闲槽） |
  | `fast_ch_map`、`*_base` | `isu_pkg` 里按端口能力静态计算的通道号 |

## 3. 一拍内的数据流
1. **选择**（只读寄存器状态）：`ready[i] = valid_q[i] & ~wait1_q[i] & ~wait2_q[i]`；端口 p（IQ 内顺序）在 `ready & 能力匹配(p) & ~已被前面端口选走` 里取最低槽。选中即“占用”，即使后面因 `fu_ready_mask` 不满足/`issue_block` 而不授予，该槽也不会被后面端口再选（与 C++ 一致）。授予 = 选中 & `fu_ready_mask[phys][op]` & `~(flush | mispred)`。授予槽 valid 清零。`iss2prf` = 选中槽的 uop（来自寄存器，不含本拍唤醒/clear）。
2. **延迟/快速唤醒**：由授予生成（本拍发射的 MUL/DIV/FP 进入 `*_1` 状态；单周期 ALU 类授予直接快速唤醒）。唤醒通道输出由**当前**寄存器状态（倒计时 0 / MUL 末级）+ 本拍授予（快速）+ `prf_awake` 组成，位置固定：`[0..3]` load，`[4..5]` MUL 槽，`[6..7]` DIV 槽，`[8]` FP 槽，`[9..14]` ALU 端口 0..5。
3. **唤醒**：15 个通道合成 preg 位图；每槽 `wait_d = wait_q & ~bitmap[src_preg]`；本拍授予的槽虽已选出，其寄存器状态不受本拍唤醒影响（C++ 先 issue 后 awake）。
4. **入队**：空闲 = `~(valid_q & ~授予)`（本拍刚发射的槽可被同拍入队复用，C++ `commit_issue` 先于 `enq`）；请求 w 的 uop 先按位图叠加唤醒（`apply_wakeup_to_uop`），写入 `wait = en & busy & ~位图[preg]`。
5. **flush**（对入队后的状态）：`flush_all` 清空所有 valid 与延迟唤醒；否则若 `mispred`，`uop.br_mask & br_mask != 0`（用清除**前**的掩码）者无效，延迟唤醒槽同样；之后所有存活项 `br_mask &= ~clear_mask`（`clear_mask` 与 flush 无关，两种情况都作用）。
6. **ready_num** = `SIZE − popcount(valid_q)`（寄存器值，C++ `comb_ready` 在 issue/enq 之前读）。
- 无 stale 读、无同拍双写：`Isu` 各阶段读的都是“寄存器值”或“已算好的本拍值”，数据流单向，无需 `_hold_q`。

## 4. 与 C++ 的差异点、放宽、删除、不复刻
**消费者核对（06）：**
- `iss2prf.iss_entry[p].uop.*`：读取点 `Prf::comb_req_ftq`（`if (!valid) continue`）、`Prf::comb_read`（`if (!valid) continue`），其他处只读 `iss_entry[].valid`（`Isu::comb_awake/comb_calc_latency_next` 先判 valid）。→ spec 用 `when iss2prf_iss_entry_valid`，RTL 无效口负载为 0（AND-OR 自然得到）。不为“无效口保持旧值”做任何结构（C++ 每拍 `issue_grants` 清零后只写有效口，本来也没有残留；`out.iss2prf->iss_entry[i].uop` 在 valid=0 时是上一拍残留，未被读）。
- `iss_awake.wake[ch].preg`：读取点 `Dispatch::is_preg_woken`（`valid &&`）、`Dispatch::comb_wake`（`if valid`）、`Isu::apply_wakeup_to_uop`（`if !valid continue`）、`IssueQueue::comb_wakeup`（`if !wake_valid continue`）。→ `when iss_awake_wake_valid`。
- `iss2dis.ready_num`：读者 `Dispatch`（`iq_usage >= ready_num` 比较），严格比较。宽度 `IQ_READY_NUM_WIDTH`=8（128 需要 8 位）。
- `dis2iss.req[].uop.*`：只在 `valid` 时读（`Isu::comb_enq`），无效请求的负载 RTL 不看。

**删除的字段/结构：**
- `dbg`（`DebugMeta`）全部不翻译；`std::getenv("CT")` 的 `printf` 调试不翻译。
- `exe2iss` 只用 `fu_ready_mask`；`rob_bcast` 只用 `flush`；`dec_bcast` 只用 `mispred/br_mask/clear_mask`。
- `IssueQueue::out.free_slots` 只有 comb_ready 那一次有意义；`comb_enq/issue/flush` 末尾对它的重写无人读。`Isu::port_attributes`、`ctx` 无人用。
- `wake_matrix_src1/2`：软件加速结构，行为等价于对每个有效、`src_en & busy & src_preg==wake_preg` 的槽清 busy。逐项核对其等价性：位在入队时仅当 `src_en & busy`（叠加本拍唤醒后）置位；唤醒时整行清零（所有等该 preg 的槽同时被唤醒）；发射/flush_br 清自己的位、flush_all 清全部；故位图 == {valid & en & busy & preg==行号}，没有残留位。RTL 用 CAM 式查表实现同一语义。
- `busy` 位与 `en` 合并为 `wait`（`ready` 判断 `(!en || !busy)`；busy 在 en=0 时无人读，iss2prf 不带 busy）。
- `ROB_OLDEST_FIRST` 排序分支（配置选 `IQ_SLOT_PRIORITY`，该分支不可达）。
- 快速唤醒判断里的 `op != UOP_LOAD && op != UOP_STA`：有快速通道的端口（ALU 能力端口 0..5）因能力掩码不可能发射 LOAD/STA，不可达，不复刻。
- 延迟唤醒分配的静态剪枝：端口 p 授予的 op 必然属于其能力掩码，故 MUL（DIV/FP）分配请求只来自能力含 MUL（DIV/FP）的端口。
- `Assert(!out.iss2prf->iss_entry[phys_port].valid)`、各 `Assert(ok …槽位不足/collision)`、`Assert(success …队列溢出)`、`decode_uop_type` 的 `op<MAX_UOP_TYPE` 检查：不可达，不复刻；溢出时 RTL 的行为是丢掉多出的请求（trace 未出现，随机生成器也只生成合法激励）。

**参考模型疑点（均按参考模型实现，不登记偏差）：**
1. `comb_calc_latency_next` 的 FP/DIV 槽：`countdown==0` 的槽在当拍广播后立刻释放，同拍新发射的 DIV/FP 可复用该槽；RTL 同样（空闲 = `!(valid && countdown>0)`）。
2. 延迟唤醒广播使用当前拍状态，不受本拍 mispred 影响（被错误路径杀掉的 MUL/DIV 也会照常广播一次唤醒，直到下一拍槽才被杀）；RTL 同。
3. 延迟唤醒的各个“槽位不足”`Assert` 在 NDEBUG 的 refsim 里是空操作；真实程序里没触发（RTL 里有一条时钟采样的 `assert property` 同样跑 73 个真实 trace 未触发）。
4. MUL 延迟管线深度 = `MUL_MAX_LATENCY-1` = 1：此时“按 br_mask 杀死/清除”对 MUL 管线是空操作（新入管线的 uop 只在发射拍产生，而发射拍若有 mispred 则 `issue_block` 已阻止发射；末级条目在下一拍就离开）。RTL 保留通用（深度>1 才有意义）的逻辑，但在本配置下**该杀死逻辑不可被任何 trace 观察到**（变异 M10 为等价变异），已在报告中说明。
5. FP 由 Dispatch 路由到 IQ_INT（`Dispatch.cpp` decompose：`out_uops[0].uop.op = UOP_FP; iq_id = IQ_INT`），INT 口 1 有 FP 能力；真实 trace（zfinx*/matmul_fpu）覆盖。

## 5. 验证
- spec：`spec/isu.io`，60 个字段名（含 `[5][8]`、`[22]` 数组，展开后每拍输入 1572 B/输出 805 B）。
- trace：61 个 gate 测试（8000 拍）+ progs.txt 的 12 个（dhrystone/coremark/coremark10 各 100000 拍，vm 4 个，float/sha/cjpeg/linear_alg/parser 各 30000 拍）共 73 个，669k 条有效记录；另 4 个随机 trace（`tests/isu/run_rand.sh`，每个 30000 拍）。`tests/isu/cov.cpp` 统计覆盖。
- 随机生成器 `tests/isu/rand_trace.cpp`：直接驱动参考 `Isu` 类（不定义 NDEBUG，参考模型的 Assert 全开作自检），按 BackTop 的阶段顺序调用。合法性约束与依据：每队列有效入队数 <= `ready_num`（Dispatch 的背压规则）；队列只收其支持的 op（`GLOBAL_IQ_CONFIG`，FP 进 IQ_INT，同 Dispatch）；`fu_ready_mask` 位限于端口能力，DIV/FP 位只在参考模型延迟唤醒槽不会溢出时给出（保守跟踪在途计数，模拟迭代单元忙）；入队与 flush/mispred/clear 同拍允许（Isu 边界上合法，参考模型对其有确定行为）。覆盖：IQ_INT/LD/STA/STD/BR 满（free==0）各数千拍、入队恰好占满、入队与 flush/mispred 同拍、mispred&flush 同拍、同拍 >=5 个唤醒、MUL/DIV/FP 延迟唤醒。
- 真实程序没覆盖到的：IQ_INT/STA/STD/BR 满（真实程序最多 LD 队列满 49 拍）、入队与 flush/mispred 同拍（Dispatch 在这些拍不入队）、mispred 与 flush 同拍 —— 均由随机 trace 覆盖。MUL 管线 kill 逻辑在本配置下不可观察（见第 4 节第 4 条）。
- 变异检查（`scripts/mutcheck.sh`，trace：dhrystone coremark matmul_fpu prime vm_pagefault_test rand_a rand_b；失败字段@记录号，括号内为首个抓到的真实程序）：

| # | 变异 | 抓到 |
| --- | --- | --- |
| M1 | select：后面的端口可重复选同一槽（去掉 taken 排除） | iss2prf_iss_entry_valid @35（dhrystone） |
| M2 | src1 唤醒查 src2 的 preg | iss2prf_iss_entry_valid @78（dhrystone） |
| M3 | DIV/FP 槽在 countdown==0 当拍不释放 | iss_awake_wake_valid @143（prime） |
| M4 | 同拍发射腾出的槽不能被入队复用 | iss2prf_..._src2_preg @82（dhrystone） |
| M5 | FP 当作单周期（快速唤醒） | iss_awake_wake_valid @292（matmul_fpu） |
| M6 | fmul 延迟 +1 | iss_awake_wake_valid @292（matmul_fpu） |
| M7 | clear_mask 不作用于 IQ 项 | iss2prf_..._br_mask @226（dhrystone） |
| M8 | 8 路入队都取同一空槽 | iss2dis_ready_num @77（dhrystone） |
| M9 | mispred 不阻止发射 | iss2prf_iss_entry_valid @136（dhrystone） |
| M11 | DIV 倒计时少 1 | iss_awake_wake_valid @1813（dhrystone） |
| M12 | 分支 kill 用清除后的掩码 | iss2dis_ready_num @317（dhrystone） |
| M13 | 入队不叠加本拍唤醒 | **仅随机**：rand_a @10（Dispatch 已先叠加，真实程序不暴露） |
| M14 | 授予只看 fu_ready 任一位而非 op 位 | iss2prf_iss_entry_valid @1891（dhrystone） |
| M15 | 全局 flush 不清旧 IQ 项 | iss2dis_ready_num @22892（vm_pagefault_test）；rand_a @7 |
| M16 | 全局 flush 不清 DIV/FP 唤醒槽 | **仅随机**：rand_a @33 |
| M17 | DIV/FP 槽不被 br_mask 杀死 | iss_awake_wake_valid @1831（dhrystone） |
| M10 | MUL 管线不被 mispred 杀死 | **存活，等价变异**（深度 1，见第 4 节） |
