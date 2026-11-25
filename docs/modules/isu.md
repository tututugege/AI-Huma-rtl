---
module: isu
area: backend
rtl: rtl/backend/isu
model: trace-model back-end/Isu.cpp、back-end/include/Isu.h、back-end/include/IssueQueue.h（调度单元 `back.isu`，类 `Isu`，阶段 `comb_issue`）
status: 整核周期与模型逐个相等（`fm_gate` 69/69 PASS、0 周期偏差，Linux 26/26 窗 PT/UP 100% 全等）
depth: **61 层 / 1,033,276 cells**（Yosys `strash;balance;map`）；**TSMC 28nm HPC+ DC (`ssg0p81v125c`, `0.50ns`)：WNS `−0.23 ns`（`1.37 GHz`，纯组合 `0.64 ns`），面积 `598,408 µm²`（`IQ_BR` 翻倍至 64 后较 `main` `608,221 µm²` 反降 −1.6%）**
---

# isu 设计文档

## 1. 职责

发射单元：6 个发射队列（INT0、INT1、内存（load 和 STA 合并）、STD、BR、FP）加一张唤醒网络。每拍做四件事：

1. 把分派来的 uop 放进队列（`dis2iss`），入队时叠加本拍已经发生的唤醒；
2. 每个发射口按能力从就绪、且在这个口上完成周期还空着的槽里选一个（最老优先或最低槽优先，见 5.1；完成周期的检查在选择之前，EXP-046），经过 FU 就绪、FP 写口两道闸后发出（`iss2prf`），并预留它的完成周期；
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
| INT0（q0） | 32（`IQ_INT_SIZE`） | 4（`IQ_INT_ENQ_WIDTH`） | 3 | 两个整数队列各管三个口；CSR 进 INT0，I2F 进 INT1（口 2、3 有 I2F 能力） |
| INT1（q5） | 32 | 4 | 3 | |
| 内存（q1，load + STA 合并） | 64（`IQ_MEM_SIZE`） | 6（`IQ_MEM_ENQ_WIDTH`） | 7（4 load + 3 STA） | 每种能力的第一个口取最老的就绪 uop，其余口取最低槽；STA 口 11、12 与 load 口 8、9 共用 AGU（`LSU_AGU_SHARED = 2`，load 优先） |
| STD（q2） | 16 | 4 | 3 | |
| BR（q3） | 64 | 5 | 2 | 方案 C（`rob_ptr` 冲刷）解除 31 在飞分支上限后扩容至 64 |
| FP（q4） | 32 | 4 | 3 | 仅 F/D（`FPRF_NUM != 0`） |

其他：槽分配只看寄存的 valid 位，不等本拍发射腾出的槽；`MUL_MAX_LATENCY = 3`、`DIV_MAX_LATENCY = 32`；`WAKE_NUM = MAX_WAKEUP_PORTS = 22`；`TAG_NUM = 224`（preg 个数）；`FPW_CH = 8` 路 FP 延迟唤醒通道。

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
 isu_wb_gate  : 完成周期预留（EXP-035）：每个口一个按"距今几拍"索引的移位忙表（EXP-046），给选择输出每个完成类"空着"的位
 isu_fp_gate  : FP 写口限制（EXP-032，`FP_WB_PORTS = 2`）
 isu (top)    : 端口平铺 <-> 结构体，三道闸合并，把各队列的发射结果拼到 21 个物理口
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `isu_pkg.sv` | 314 | 队列、口、能力表；uop 结构；完成类（`wb_class` / 独热形式 `cls_hit`，11 类）与完成偏移；每口的忙表长度 `port_max_off`、会被占的类 `cls_blockable`；唤醒通道布局 |
| `isu.sv` | 319 | 顶层：端口适配，闸（`fp_ok`；完成周期在选择里已经查过）合成 `gate_ok`，把忙表的 `cls_free` 发给各队列，实例化各队列和唤醒网络 |
| `isu_iq.sv` | 177 | 一个发射队列（含入队时寄存的完成类位 `slot_cls_q` 和选择前的完成周期掩码 `port_ok`） |
| `isu_iq_store.sv` | 98 | 槽存储与次态 |
| `isu_iq_select.sv` | 65 | 每口的选择 |
| `isu_alloc_chain.sv` | 57 | 入队分配（也用于延迟唤醒槽分配） |
| `isu_age_matrix.sv` | 35 | 内存队列的年龄矩阵 |
| `isu_wake_src/mul/iter/compact/bus.sv` | 140/90/92/45/27 | 唤醒 |
| `isu_wb_gate.sv`、`isu_fp_gate.sv` | 64、105 | 完成周期预留、FP 写口限制 |

状态：每个队列每槽一组 `valid_q`、`uop_q`（`isu_uop_t`，29 个字段）、`wait1_q/wait2_q/wait3_q`；MUL 唤醒管线（深度 `MUL_MAX_LATENCY - 1 = 2`）；DIV / FP 倒计时槽（FP 24 槽）；年龄矩阵 `m_q[64][64]`（只有内存队列）；`isu_wb_gate` 每个口一个 `port_max_off(p) - 1` 位的移位忙表（现行配置：口 0、2、18、19 各 2 位，口 1、3 各 32 位，口 20 23 位，其余口 0 位，共 95 位；main 原来是 21 × 64 位的环加 6 位拍号）；`isu_fp_gate` 的计数环。

## 5. 一拍内的数据流

### 5.1 选择与发射（只读寄存器）

1. `slot_ready = valid & !wait1 & !wait2 & !wait3`（取消的唤醒 `cancel_v` 先让槽重新变成"在等"）。
2. 每口 p 的候选 = `slot_ready & 能力匹配(p) & port_ok(p) & ~已被前面且能力重叠的口选走的槽`。`port_ok(p)[i]`（EXP-046）：槽 i 的 uop 在口 p 上的完成周期还空着。只看口 p 上"会被占"的完成类（`cls_blockable`：口上存在偏移更长的类；一个口按拍发射，完成周期只能被更早发射、偏移更长的 uop 占住，所以每个口偏移最长的类、单类口的所有类永远空着，编译期恒 1）；槽的类在入队时算好（`cls_hit`），只存本队列各口上会被占的那几类（`QBLK`：INT 队列、FP 队列各几位，内存 / STD / BR 队列没有），选择时 `blocked = slot_cls_q[i][类] & ~cls_free[p][类]`，两边都是寄存器；第一版每拍从 `uop_q.op` 解码，深度多 5 层。被挡的槽不进候选，下一个就绪槽拿到这个口（原来是选中后再被闸拒绝，这个口这拍空着）。只有"能力重叠"的口之间才串联（load 口和 STA 口互相独立，同类口成一条链）。
3. 取法：普通口取候选里最低的槽（`ttg_first_set`）；内存队列里"每种能力的第一个口"（`first_of_cap`）取最老的候选，即没有更老候选的那个槽（用年龄矩阵 `older[i][j]`）。
4. `cand_valid[p] = 有选中 & !issue_block & (fu_ready[p] 含该 uop 的操作类)`；`grant_valid[p] = cand_valid & gate_ok[p]`，共享 AGU 的 STA 口还要求对应 load 口这拍没有发。
5. 选中的槽即使没被授予（FU 忙、被闸挡住）也算被占用，下游口不再选它。

闸（`isu.sv`）：完成周期由选择保证（`isu_wb_gate` 的 `port_ok` 只给单元测试用）；`fp_ok`（FP 写口数没超 `FP_WB_PORTS`，只对会写 FP 寄存器的候选）、共享 AGU（合并配置下由内存队列自己处理）。授予后按完成类预留：忙表 `busy_q[k]` 表示"距今 k 拍"的完成周期已被占，每拍整体下移一位，偏移为 o 的授予在下一拍置位 `o - 1`；flush 清空。行为与模型的 64 项环（`WbBusy`）相同。

### 5.2 唤醒

授予生成延迟唤醒请求（MUL 进管线、DIV / FP 进倒计时槽，下拍起可见）和快速唤醒（6 路单周期 ALU 授予直接在本拍广播，仅整数域）。为压缩 `select → grant → wakeup` 关键环路深度，唤醒网络按**数据域**与**快慢路径**拆分：

1. **慢速唤醒**（全部来自寄存输出：PRF 写回 load 4 路、MUL 2 路、DIV 2 路、FP 倒计时 8 路、LSU L3 4 路）：在拍初即稳定，由 `isu_wake_bus` 分别生成整数域 `woken_slow_int[PRF_NUM]`（128 位）和浮点域 `woken_slow_fp[FPRF_NUM]`（96 位），与 `select → grant` 并行；
2. **快速唤醒**（6 路 ALU 授予，`fast_valid[FAST_UNITS]` / `fast_preg[FAST_UNITS]` 低 7 位）：不经 224 位位图展开，直接广播至监听整数域的队列槽位，在槽内用 6 路 7 位并行比较（CAM）生成 `fast_hit`，与慢速唤醒结果单级相与更新 `wait_d`；
3. **按队列裁剪源与域**：INT0/INT1/BR 仅整数域且无 `src3`；MEM 仅整数域且仅 `src1`（无 `src2`/`src3`）；STD 无 `src3`（`src1` 整数域、`src2` 双域）；FP 仅浮点域（3 源，完全不接 6 路快速唤醒）。本拍授予的槽的寄存器状态不受本拍唤醒影响（模型先 issue 后 awake）。

### 5.3 入队

`isu_alloc_chain`：每个槽数自己前面有几个空闲槽（log 深度的饱和前缀计数），每个请求数自己前面有几个有效请求，秩相等的配对。空闲只看寄存的 `valid`（不等本拍发射腾出的槽）。入队的 uop 先叠加本拍的 `woken`（`wait = en & busy & ~woken[preg]`）。

### 5.4 flush

`flush_all` 清所有 valid 和延迟唤醒；`flush_br = mispred & !flush`：`uop.br_mask & flush_br_mask != 0`（用清除前的掩码）的项被杀；之后所有存活项 `br_mask &= ~clear_mask`。`issue_block = rob_flush | mispred` 阻止本拍发射。

### 5.5 ready_num

`SIZE - popcount(valid_q)`，再取 `min(·, 入队 lane 数)`，用寄存值。

## 6. 关键路径与深度

单模块（`synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`）：main `isu` **88 层**，约 95.7 万单元。EXP-046（2026-11-19）：只改忙表（移位寄存器）945,443 单元、88 层；加上选择前查完成周期（入队时寄存类位）948,874 单元、89 层（第一版每拍解码类：1,015,056 单元、100 层；第二版去掉解码但仍每拍解码 `uop_q.op`：948,366、93 层）。main 的最长路径：

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
| 分配不再等本拍的发射结果 | `0e82d3f` | 原来由 `IQ_SAME_CYCLE_REUSE` 开关选，2026-11-18 开关删除，直接写成 `free = ~slot_valid`（模型里仍有 `CFG_IQ_SAME_CYCLE_REUSE`） |
| 完成类闸 | `ff11fc3` | 完成周期预留和 FP 写口闸按"完成类"（11 类，偏移是类的常量）查表，不再先解码被选 uop |
| FP 闸无链 | `871437e` | 一个候选能否拿到写口只看前面候选的授予 |
| 选择只在能力重叠的口之间串联 | `isu_iq_select.sv` 现行写法 | load 口和 STA 口各选各的 |
| 忙表改成每口移位寄存器、偏移最长的类恒空 | `exp/wb-presel`（EXP-046） | 单元 −1.2%，深度不变 |
| 选择前查完成周期用入队时寄存的类位 | `exp/wb-presel`（EXP-046） | 不在选择路径上解码操作码 |
| INT 队列并行选择 | `1db84c7`，**已回退** `ad24170` | 稀有操作类各取最低槽的做法改变了调度，周期对不上，不采用 |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `dbg` 调试元数据、`getenv` 调试输出；`Assert` 类检查（队列溢出、延迟唤醒槽不足、端口冲突）：RTL 里只保留了分配溢出的仿真断言（`isu_alloc_chain`，`ifndef SYNTHESIS`）；
- `wake_matrix_src1/2/3`（preg→槽位图，`IssueQueue.h`）是模型的软件加速结构，RTL 用 `TAG_NUM` 位的唤醒位图 + 每槽按 `src_preg` 查表，行为等价；
- `busy` 与 `en` 合并成 `wait`；
- 调度策略：模型有三种（`CFG_ISSUE_OLDEST_FIRST`：0 最低槽优先、1 所有队列最老优先（`ROB_OLDEST_FIRST`）、2 每种能力的第一个口取最老，其余最低槽；`CFG_ISSUE_OLDEST_QUEUES` 选适用的队列）。RTL 只实现 0 和 2，且 2 只用于内存队列（`MEM_AGE`，对应模型 `CFG_ISSUE_OLDEST_FIRST=2`、`CFG_ISSUE_OLDEST_QUEUES=2`）；策略 1 不实现；
- 快速唤醒里的 `op != UOP_LOAD && op != UOP_STA`（模型 `Isu.cpp:242`）：RTL 不判。每个口只选自己能力范围内的槽，而有快速通道的口 0..5 的能力掩码里没有 `UOP_LOAD`（第 3 位）和 `UOP_STA`（第 4 位），这两种 uop 不可能在这些口被授予。

- EXP-046：模型的 `ISS_REF_*` / `ISS_LOST_*` PMU 事件只在模型里。模型的忙表仍是 64 项环（`WbBusy`），RTL 是按口长度的移位寄存器，行为相同（`tests/wb_gate` 对照）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- `countdown == 0` 的 DIV / FP 槽在当拍广播后立刻释放，同拍新发射的可以复用；
- 延迟唤醒广播用当前拍状态，不受本拍误预测影响（被错误路径杀掉的 MUL / DIV 也会广播一次）；
- 溢出时 RTL 丢掉多出的请求，不报错（分派受 `ready_num` 流控，不会发生）。

配置相关的有意差异：RTL 只有现行这一种配置（load 与 STA 合并成一个内存队列，没有独立的 STA 队列）；两个 INT 队列、内存队列的最老优先、不等本拍发射的槽分配、共用 AGU 在模型里是编译期开关（`CFG_INT_CLUSTERS`、`CFG_ISSUE_OLDEST_FIRST/QUEUES`、`CFG_IQ_SAME_CYCLE_REUSE`、`CFG_AGU_SHARED`；`CFG_MEM_MERGE` 已删），RTL 的参考周期用这些开关同配置的模型生成。

## 8. 验证

- **EXP-046（`exp/wb-presel`）**：`tests/wb_gate`（`run.sh <工作目录>`）：`wrap.sv` 把忙表和 `isu_pkg` 的类表（偏移、每口服务的类）一起导出，`check.py` 随机 3 万拍对照模型的 `WbBusy`，同时检查 `port_ok` 和每口每类的 `cls_free`：0 不一致；植入错误（类 0 的 `cls_free` 恒 1）后 24140 拍不一致。原来的测试驱动的是已删除的 `off` 输入，在 main 上编译不过，这次一并改写。整核：`fm_gate` 67/67 逐条对函数模型无不一致，周期对模型（trace-model `exp/wb-port` `60aa7e8` 的 `CFG_WB_PRESEL=1`，合入版里这是唯一行为，RVC=1 构建，程序用 `build_tests.sh` 的 rv64ima 版）67/67 相等（合入 `exp/llc-plru` 后的集成分支，参考周期 `scripts/ref_cycles.txt` 用 `LSU_PIPE_NOWD=1` 生成；早先记录的"crc32 RTL 2196 / 模型 2199"是生成参考时没关模型的 LDQ / STQ 看门狗造成的误判，`tm_cycles.sh` 现在默认关掉它）。

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）：67/67 通过，周期逐个相等。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧体系的 trace 回放 + 随机 trace + 变异检查（spec/、`tests/isu`）已随 `spec/` 一起退役，旧的变异表在本文件的 git 历史里（`git log -- docs/modules/isu.md`）。目前 isu 的正确性靠整核周期逐拍相等和 Linux 启动来保证。**待补**：给分配链、选择、年龄矩阵各补一个"新旧并排"的随机测试（像 `lp_ovl` 那样），在后续改深度时用。

## 9. 参数与开关速查

`IQ_INT_SIZE`、`IQ_INT_ENQ_WIDTH`、`IQ_MEM_SIZE`、`IQ_MEM_ENQ_WIDTH`、`LSU_AGU_SHARED`、`IQ_STD_*`、`IQ_BR_*`、`FP_IQ_*`、`FP_WB_PORTS`（`isu_pkg`，EXP-032）；`LP_L2[3]`（LSU 推测唤醒）。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 10. 变更记录

- 2026-11-25（`isu_pkg`/`isu_fp_gate` FDIV/FSQRT 写口预留晚 1 拍修复）：迭代式 FP 单元（类 4..7 `FDIV`/`FSQRT`）实际写回周期为 `wb_cls_off(c) = lat + 1`，但 `fp_cls_lat(4..7)`（及模型 `Isu.cpp` `fp_wb_busy_.try_reserve(lat)`）此前误用 `lat`（早 1 拍），导致 `fdiv.d` 与 2 条流水线 FP 指令在真实写回拍冲突并触发 `[FPWB] 3 FP-unit register writes in one cycle` 丢弃 `fdiv.d` 结果（由 SPEC06 RTL `403.gcc/sp27` 检出）。同步修复 `isu_pkg.sv` `fp_cls_lat` 返回 `wb_cls_off(c)`、`isu_fp_gate.sv` `DEPTH = FP_FSQRT_D_LAT + 1` 以及模型 `Isu.cpp` 改传 `off`。
- 2026-11-25（`isu_fp_gate` 跨类同延迟写回冲突修复）：2026-11-21 `g_fast_p2` 按类预结合 `cls_ok` 时 `hit_c[j]` 仅匹配同类 `cand_cls_1h[j][c]`，漏算了不同类但同延迟的跨类冲突（类 9 `FMISC` 与类 10 `I2F` 均为 2 拍），导致 2×`I2F` + 1×`FMISC` 同拍发射时放行第 3 路写回、`prf.sv` `[FPWB]` 丢弃第 3 路结果（由官方 `riscv-tests` `rv64uf-move`/`rv64ud-move` 检出）。修复为 `hit_c[j]` 匹配所有满足 `fp_cls_lat(c2) == fp_cls_lat(c)` 的前序口，不增加关键路径级数。
- 2026-11-25（`rtl/rob-ptr-bpu`，方案 C 9-bit `rob_ptr` 冲刷 + `IQ_BR=64`）：删除 `br_mask` / `clear_mask` 改为 9-bit `{rob_flag, rob_idx}` 循环年龄冲刷，并将 `IQ_BR_SIZE` 由 32 扩至 64；Yosys **61 层 / 1,033,276 cells**；TSMC 28nm DC **WNS `−0.23 ns`（`1.37 GHz`，与 `main` 完全持平）/ 面积 `598,408 µm²`（较 `main` `608,221 µm²` 反降 −1.6%）**；`lint_chip` 0、`fm_gate` 69/69（0 周期差）、Linux 26/26 窗 PT/UP 100% 全等。
- 2026-11-23（`rtl/ld-wake`，EXP-060）：配合 `LP_L2[3]=1` 开启 L2 推测唤醒与下拍取消，删除 `isu.sv` 中 `u_cancel_int`/`u_cancel_fp` 两张 256/96-bit 位图解码器，改为将 4 路 `lsu2iss_cancel_{valid,preg}` 直连至 `isu_iq`/`isu_iq_store` 做 4 路 9-bit 直接比较（`match_cancel`），`eda-08` Yosys：`isu` **60 层 / 1,079,759 单元**（+10 层，远低于 `ren` 91 层与 `lsu` 101 层）；`fm_gate` 69/69 PASS 0 周期差，Linux 26 窗 100% 全等。
- 2026-11-21（`rtl/onehot-mux-tree`，`isu` 深度 89 → **50 层**，零周期变化）：新增公共原语 `ttg_pick_k.sv`（温度计编码 Kogge-Stone 并行前 K 选口）并改写 `ttg_onehot_mux`/`ttg_popcount` 为堆式平衡树（4 个公共原语均带 `` `ifdef SYNTHESIS `` 仿真快速路径）；`isu_alloc_chain`、`isu_wake_compact`、`isu_iq_select`（`IQ_MEM` LD/STA 组）统一复用 `ttg_pick_k`；`isu_iq` 入队寄存 `slot_op_q`/`slot_cap_q`/`slot_fpw_q`/`slot_fp_cls_q`、并行评估 `fu_ready` 与 `isu_fp_gate` 的 `sf1/sf2`；`isu_wake_src` FP 延迟唤醒拆 5 组 `NREQ=1` 私有槽，内部位图直读未压缩 `fp_raw_*`，快速唤醒直连 `cand_valid`；`isu_fp_gate` `busy_q` 改 packed 并解耦次态更新、按类预结合 `cls_ok`；`isu_iq_store` 静态裁剪 `HAS_CANCEL=HAS_SPEC_WAKE` 并行化分支 kill。`eda-08` Yosys：`isu` **50 层 / 931,747 单元**（剩余唯一 50 层路径为 `IQ_INT1` 3 口选口 → `dest_preg` 读出 → 7-bit CAM 唤醒核心环路）。
- 2026-11-21（`rtl/be-wake-byp-opt`，后端阶段一瘦身）：唤醒网络按数据域（Int 128b / FP 96b）与快慢路径拆分（慢速寄存唤醒经分域 `isu_wake_bus`，6 路 ALU 快速唤醒直连整数域槽位 7-bit CAM）；各队列按实际源操作数裁剪死 `wait` 位（非 FP 队列去 `wait3`，MEM 队列去 `wait2`）；零周期变化。
- 2026-11-19（`exp/wb-presel`，EXP-046）：完成周期的检查移到选择之前（合入时删掉了探索用的开关 `WB_PRESEL`，模型的 `CFG_WB_PRESEL` 同时删掉）；`isu_wb_gate` 的忙表从 21 × 64 位环 + 拍号改成每口按需长度的移位寄存器，偏移最长的类编译期恒空；`tests/wb_gate` 改为按完成类驱动并检查 `cls_free`。

- 2026-11-17/18（exp/agu-share）：两个 INT 队列、合并内存队列与年龄选择、共享 AGU、并行分配、完成类闸、FP 闸去链、不等本拍发射的槽分配（见第 6 节表）；全局 flush 晚一拍到达（docs/FLUSH_REG.md）。
- 2026-11-12：rv64（`is_word`、*W 除法延迟减半）；F/D（FP 队列、延迟唤醒槽、FP 写口闸，EXP-031..036）。
- 更早：见 git 历史。
- 2026-11-18：删除只剩一种取值的开关 `INT_CLUSTERS`、`MEM_AGE`、`IQ_SAME_CYCLE_REUSE`（`isu_pkg`、`isu.sv`、`isu_iq.sv` 里直接写成唯一取值）。
