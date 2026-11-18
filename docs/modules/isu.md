---
module: isu
area: backend
rtl: rtl/backend/isu
model: trace-model back-end/Isu.cpp、back-end/include/Isu.h、back-end/include/IssueQueue.h（调度单元 `back.isu`，类 `Isu`，阶段 `comb_issue`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 88 层（单模块综合，去掉 dc2 的结构深度；见第 6 节）
---

# isu 设计文档

## 1. 职责

发射单元：6 个发射队列（INT0、INT1、内存（load 和 STA 合并）、STD、BR、FP）加一张唤醒网络。每拍做四件事：

1. 把分派来的 uop 放进队列（`dis2iss`），入队时叠加本拍已经发生的唤醒；
2. 每个发射口按能力从就绪的槽里选一个（最老优先或最低槽优先，见 5.1），经过三道闸（FU 就绪、完成周期预留、FP 写口）后发出（`iss2prf`）；
3. 汇总唤醒通道（`iss_awake`，`WAKE_NUM = 22` 路）：PRF 写回的 load 唤醒、MUL / DIV / FP 的延迟唤醒、ALU 的快速唤醒；LSU 的 load 唤醒和取消另外直接进各队列；
4. 处理 flush、误预测杀死、分支掩码清除。

模型对应一个调度单元 `back.isu`（`Isu::comb_issue`，内部阶段 `ready → issue → awake → calc_latency_next → enq → flush`）。RTL 的子模块边界是为综合和复用划的，模型里没有对应的类。

## 2. 配置（`ttg_cfg_pkg` / `isu_pkg`，现行默认）

执行单元共 **19 个**，按单元列（"口号"是代码里 `iss2prf` 等数组的下标，`ISSUE_WIDTH = 21`，比 19 多 2 是因为共用的 2 个 AGU 在口号里出现了两次）：

| 执行单元 | 个数 | 口号 | 能做什么 | 所属队列 |
| --- | --- | --- | --- | --- |
| ALU 类 | 6 | 0、1、4 / 2、3、5 | 都能做 ALU；0：+MUL +CSR；1：+DIV；2：+MUL +I2F；3：+DIV +I2F | 0、1、4 属 INT0，2、3、5 属 INT1 |
| load 专用 AGU | 2 | 6、7 | LOAD | 内存队列 |
| load 与 STA 共用 AGU | 2 | load 口 8、9，也是 STA 口 11、12 | LOAD 或 STA，**同一拍只能做一个，load 优先** | 内存队列 |
| STA 专用 AGU | 1 | 10 | STA | 内存队列 |
| STD | 3 | 13、14、15 | STD | STD |
| BR | 2 | 16、17 | BR | BR |
| FP | 3 | 18、19：FMA+FMISC；20：FDIV+FMISC | FP | FP |

共用 AGU 的两套口号（load 8、9 与 STA 11、12）用同一个 PRF 读口、同一个 DTLB 口；内存队列同拍最多发 5 条。队列里仍按 7 个口分别选（口 6..9 只能发 LOAD，10..12 只能发 STA），共用时由 load 口抢先。

| 队列 | 槽数 | 入队 lane | 口数 | 备注 |
| --- | --- | --- | --- | --- |
| INT0（q0） | 32（`IQ_INT_SIZE`） | 4（`IQ_INT_ENQ_WIDTH`） | 3 | `INT_CLUSTERS = 2`：两个整数队列各管三个口；CSR 进 INT0，I2F 进 INT1（口 2、3 有 I2F 能力） |
| INT1（q5） | 32 | 4 | 3 | |
| 内存（q1，load + STA 合并） | 64（`IQ_MEM_SIZE`） | 6（`IQ_MEM_ENQ_WIDTH`） | 7（4 load + 3 STA） | `MEM_AGE = 1`：每种能力的第一个口取最老的就绪 uop，其余口取最低槽；STA 口 11、12 与 load 口 8、9 共用 AGU（`LSU_AGU_SHARED = 2`，load 优先） |
| STD（q2） | 16 | 4 | 3 | |
| BR（q3） | 32 | 5 | 2 | |
| FP（q4） | 32 | 4 | 3 | 仅 F/D（`FPRF_NUM != 0`） |

其他：`IQ_SAME_CYCLE_REUSE = 0`（槽分配只看寄存的 valid 位，不等本拍发射腾出的槽）；`MUL_MAX_LATENCY = 3`、`DIV_MAX_LATENCY = 32`；`WAKE_NUM = MAX_WAKEUP_PORTS = 22`；`TAG_NUM = 224`（preg 个数）；`FPW_CH = 8` 路 FP 延迟唤醒通道。

## 3. 接口

信号组按模型的 `in` / `out` 端口命名（`dis2iss_*`、`iss2prf_*` 是把模型的结构展开成平铺端口）：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dis2iss_req_valid / _uop_* [IQ_NUM][8]` | 分派的 uop，按队列、按 lane；`src{1,2,3}_busy` 是入队时"还在等这个源" |
| 入 | `lsu2iss_wake_valid/preg [2*LDU]`、`lsu2iss_cancel_valid/preg [LDU]` | LSU 的 load 唤醒（`[p]` 是 L2 推测唤醒，`[LDU+p]` 是 L3 寄存唤醒）和推测唤醒的取消；推测部分只在 `LP_L2[3]` 打开时存在 |
| 入 | `prf_awake_wake_valid/preg` | PRF 写回口的 load 唤醒 |
| 入 | `exe2iss_fu_ready_mask [ISSUE_WIDTH]` | 每个口当前 FU 能接受的操作类 |
| 入 | `rob_bcast_flush`、`dec_bcast_{mispred, br_mask, clear_mask}` | 全局 flush（`FLUSH_REG` 后已经晚一拍，见 docs/FLUSH_REG.md）、误预测、分支掩码 |
| 出 | `iss2dis_ready_num [IQ_NUM]` | 每个队列还能收几个：`min(空闲槽数, 入队 lane 数)`，用寄存的 valid 数 |
| 出 | `iss2prf_iss_entry_valid/uop_* [ISSUE_WIDTH]` | 21 个发射口的发射结果 |
| 出 | `iss_awake_wake_valid/preg [WAKE_NUM]` | 唤醒广播，给分派（`Dispatch::is_preg_woken`）使用 |

## 4. 结构

```
 dis2iss[q][w] ─► isu_iq[q]（每个队列一个实例，参数：SIZE / DW / NP / QID / SH_* / AGE_EN）
                    ├ isu_alloc_chain : 第 k 个有效请求 -> 第 k 个空闲槽（并行秩匹配）
                    ├ isu_iq_store    : 每槽 valid / uop / wait1..3 寄存器；入队、唤醒、取消、发射清除、flush、掩码清除
                    ├ isu_age_matrix  : 年龄矩阵（只在 AGE_EN 的内存队列）
                    └ isu_iq_select   : 每口按能力选一个槽（最老优先或最低槽优先）
 isu_wake_src : 唤醒通道 = prf_awake | MUL 管线末级 | DIV 倒计时槽 | ALU 快速唤醒 | FP 倒计时槽
   ├ isu_wake_mul（MUL 移位管线）  ├ isu_wake_iter（DIV、FP 倒计时槽）  └ isu_wake_compact（FP 槽按序压到 FPW_CH 路）
 isu_wake_bus : 全部通道 -> TAG_NUM 位的 preg 位图，供队列按 src_preg 查表（等价于模型的 preg->槽 位图矩阵）
 isu_wb_gate  : 完成周期预留（EXP-035，每个口一个环形忙表）
 isu_fp_gate  : FP 写口限制（EXP-032，`FP_WB_PORTS = 2`）
 isu (top)    : 端口平铺 <-> 结构体，三道闸合并，把各队列的发射结果拼到 21 个物理口
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `isu_pkg.sv` | 285 | 队列、口、能力表；uop 结构；完成类（`wb_class`，11 类）与完成偏移；唤醒通道布局 |
| `isu.sv` | 325 | 顶层：端口适配，三道闸（`wb_ok & fp_ok & agu_ok`）合成 `gate_ok`，实例化各队列和唤醒网络 |
| `isu_iq.sv` | 127 | 一个发射队列 |
| `isu_iq_store.sv` | 98 | 槽存储与次态 |
| `isu_iq_select.sv` | 64 | 每口的选择 |
| `isu_alloc_chain.sv` | 57 | 入队分配（也用于延迟唤醒槽分配） |
| `isu_age_matrix.sv` | 35 | 内存队列的年龄矩阵 |
| `isu_wake_src/mul/iter/compact/bus.sv` | 140/90/92/45/27 | 唤醒 |
| `isu_wb_gate.sv`、`isu_fp_gate.sv` | 60、105 | 完成周期预留、FP 写口限制 |

状态：每个队列每槽一组 `valid_q`、`uop_q`（`isu_uop_t`，29 个字段）、`wait1_q/wait2_q/wait3_q`；MUL 唤醒管线（深度 `MUL_MAX_LATENCY - 1 = 2`）；DIV / FP 倒计时槽（FP 24 槽）；年龄矩阵 `m_q[64][64]`（只有内存队列）；`isu_wb_gate` 每个口的忙表；`isu_fp_gate` 的计数环。

## 5. 一拍内的数据流

### 5.1 选择与发射（只读寄存器）

1. `slot_ready = valid & !wait1 & !wait2 & !wait3`（取消的唤醒 `cancel_v` 先让槽重新变成"在等"）。
2. 每口 p 的候选 = `slot_ready & 能力匹配(p) & ~已被前面且能力重叠的口选走的槽`。只有"能力重叠"的口之间才串联（load 口和 STA 口互相独立，同类口成一条链）。
3. 取法：普通口取候选里最低的槽（`ttg_first_set`）；内存队列里"每种能力的第一个口"（`first_of_cap`）取最老的候选，即没有更老候选的那个槽（用年龄矩阵 `older[i][j]`）。
4. `cand_valid[p] = 有选中 & !issue_block & (fu_ready[p] 含该 uop 的操作类)`；`grant_valid[p] = cand_valid & gate_ok[p]`，共享 AGU 的 STA 口还要求对应 load 口这拍没有发。
5. 选中的槽即使没被授予（FU 忙、被闸挡住）也算被占用，下游口不再选它。

三道闸（`isu.sv`）：`wb_ok`（该口的完成周期还空着，按完成类查寄存的忙表）、`fp_ok`（FP 写口数没超 `FP_WB_PORTS`，只对会写 FP 寄存器的候选）、`agu_ok`（合并配置下由内存队列自己处理）。

### 5.2 唤醒

授予生成延迟唤醒请求（MUL 进管线、DIV / FP 进倒计时槽，下拍起可见）和快速唤醒（单周期 ALU 授予直接在本拍广播）；各通道合成 preg 位图 `woken`，每槽 `wait_d = wait_q & ~woken[src_preg]`。本拍授予的槽的寄存器状态不受本拍唤醒影响（模型先 issue 后 awake）。

### 5.3 入队

`isu_alloc_chain`：每个槽数自己前面有几个空闲槽（log 深度的饱和前缀计数），每个请求数自己前面有几个有效请求，秩相等的配对。空闲只看寄存的 `valid`（`IQ_SAME_CYCLE_REUSE = 0`）。入队的 uop 先叠加本拍的 `woken`（`wait = en & busy & ~woken[preg]`）。

### 5.4 flush

`flush_all` 清所有 valid 和延迟唤醒；`flush_br = mispred & !flush`：`uop.br_mask & flush_br_mask != 0`（用清除前的掩码）的项被杀；之后所有存活项 `br_mask &= ~clear_mask`。`issue_block = rob_flush | mispred` 阻止本拍发射。

### 5.5 ready_num

`SIZE - popcount(valid_q)`，再取 `min(·, 入队 lane 数)`，用寄存值。

## 6. 关键路径与深度

单模块（`synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`）：`isu` **88 层**，约 95.7 万单元。最长路径：

| 层 | 内容 |
| --- | --- |
| 0 – 9 | INT1 队列某槽的 `uop_q` → 候选 `candidate`（能力匹配、就绪、被前面口选走） |
| 9 – 58 | 选择（`first_set` 前缀）→ 读出被选 uop → FU 就绪 / 闸 → `grant_valid` / `iss2prf_valid` |
| 58 – 72 | 授予 → 唤醒通道（快速唤醒、延迟唤醒请求）→ `woken` 位图 |
| 72 – 88 | `woken[src_preg]` 查表 → 内存队列槽 63 的 `wait3_d` |

也就是"选择 → 授予 → 唤醒 → 下一拍的就绪"这一整条环，是发射队列固有的关键环路。本轮降深度的改动（均不改变周期）：

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| 入队分配改成并行秩匹配 | `0593e8b` | 原来是 NREQ 个 find-first 串起来 |
| 年龄矩阵代替锦标赛比较 | `fae3f37` | 内存队列"最老优先"选择的深度 |
| `IQ_SAME_CYCLE_REUSE = 0` | `0e82d3f` | 分配不再等本拍的发射结果（模型同步加开关，`CFG_IQ_SAME_CYCLE_REUSE`） |
| 完成类闸 | `ff11fc3` | 完成周期预留和 FP 写口闸按"完成类"（11 类，偏移是类的常量）查表，不再先解码被选 uop |
| FP 闸无链 | `871437e` | 一个候选能否拿到写口只看前面候选的授予 |
| 选择只在能力重叠的口之间串联 | `isu_iq_select.sv` 现行写法 | load 口和 STA 口各选各的 |
| INT 队列并行选择 | `1db84c7`，**已回退** `ad24170` | 稀有操作类各取最低槽的做法改变了调度，周期对不上，不采用 |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `dbg` 调试元数据、`getenv` 调试输出；`Assert` 类检查（队列溢出、延迟唤醒槽不足、端口冲突）：RTL 里只保留了分配溢出的仿真断言（`isu_alloc_chain`，`ifndef SYNTHESIS`）；
- `wake_matrix_src1/2/3`（preg→槽位图，`IssueQueue.h`）是模型的软件加速结构，RTL 用 `TAG_NUM` 位的唤醒位图 + 每槽按 `src_preg` 查表，行为等价；
- `busy` 与 `en` 合并成 `wait`；
- 调度策略：模型有三种（`CFG_ISSUE_OLDEST_FIRST`：0 最低槽优先、1 所有队列最老优先（`ROB_OLDEST_FIRST`）、2 每种能力的第一个口取最老，其余最低槽；`CFG_ISSUE_OLDEST_QUEUES` 选适用的队列）。RTL 只实现 0 和 2，且 2 只用于内存队列（`MEM_AGE`，对应模型 `CFG_ISSUE_OLDEST_FIRST=2`、`CFG_ISSUE_OLDEST_QUEUES=2`）；策略 1 不实现；
- 快速唤醒里的 `op != UOP_LOAD && op != UOP_STA`（模型 `Isu.cpp:242`）：RTL 不判。每个口只选自己能力范围内的槽，而有快速通道的口 0..5 的能力掩码里没有 `UOP_LOAD`（第 3 位）和 `UOP_STA`（第 4 位），这两种 uop 不可能在这些口被授予。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- `countdown == 0` 的 DIV / FP 槽在当拍广播后立刻释放，同拍新发射的可以复用；
- 延迟唤醒广播用当前拍状态，不受本拍误预测影响（被错误路径杀掉的 MUL / DIV 也会广播一次）；
- 溢出时 RTL 丢掉多出的请求，不报错（分派受 `ready_num` 流控，不会发生）。

配置相关的有意差异：RTL 只有现行这一种配置（load 与 STA 合并成一个内存队列，没有独立的 STA 队列）；`INT_CLUSTERS = 2`、`MEM_AGE = 1`、`IQ_SAME_CYCLE_REUSE = 0`、`LSU_AGU_SHARED = 2` 在模型里是编译期开关（`CFG_INT_CLUSTERS`、`CFG_MEM_MERGE`、`CFG_ISSUE_OLDEST_FIRST/QUEUES`、`CFG_IQ_SAME_CYCLE_REUSE`、`CFG_AGU_SHARED`），RTL 的参考周期用这些开关同配置的模型生成。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）：67/67 通过，周期逐个相等。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧体系的 trace 回放 + 随机 trace + 变异检查（spec/、`tests/isu`）已随 `spec/` 一起退役，旧的变异表在本文件的 git 历史里（`git log -- docs/modules/isu.md`）。目前 isu 的正确性靠整核周期逐拍相等和 Linux 启动来保证。**待补**：给分配链、选择、年龄矩阵各补一个"新旧并排"的随机测试（像 `lp_ovl` 那样），在后续改深度时用。

## 9. 参数与开关速查

`INT_CLUSTERS`、`IQ_INT_SIZE`、`IQ_INT_ENQ_WIDTH`、`IQ_MEM_SIZE`、`IQ_MEM_ENQ_WIDTH`、`MEM_AGE`、`IQ_SAME_CYCLE_REUSE`、`LSU_AGU_SHARED`、`IQ_STD_*`、`IQ_BR_*`、`FP_IQ_*`、`FP_WB_PORTS`（`isu_pkg`，EXP-032）；`LP_L2[3]`（LSU 推测唤醒）。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 10. 变更记录

- 2026-11-17/18（exp/agu-share）：两个 INT 队列、合并内存队列与年龄选择、共享 AGU、并行分配、完成类闸、FP 闸去链、`IQ_SAME_CYCLE_REUSE = 0`（见第 6 节表）；全局 flush 晚一拍到达（docs/FLUSH_REG.md）。
- 2026-11-12：rv64（`is_word`、*W 除法延迟减半）；F/D（FP 队列、延迟唤醒槽、FP 写口闸，EXP-031..036）。
- 更早：见 git 历史。
