---
module: isu
area: backend
rtl: rtl/backend/isu
model: trace-model back-end/Isu.cpp、back-end/include/Isu.h、back-end/include/IssueQueue.h（调度单元 `back.isu`，类 `Isu`，阶段 `comb_issue`）
status: 整核周期与模型逐个相等（`fm_gate` 69/69 PASS、0 周期偏差，Linux 26/26 窗 PT/UP 100% 全等）
depth: **61 层 / 1,033,276 cells**（Yosys `strash;balance;map`）；**TSMC 28nm HPC+ DC (`ssg0p81v125c`, `0.50ns`)：WNS `−0.23 ns`（`1.37 GHz`，纯组合 `0.64 ns`），面积 `598,408 µm²`（`IQ_BR` 翻倍至 64 后较 `main` `608,221 µm²` 反降 −1.6%）**
---

# isu 设计文档

> **2026-11-28 `rtl/iss-rr`（Wall #2 + Wall #5，合入 EXP-072 主线）**：
> - 适配 **ISS → RR → EX/LSU** 两拍及 L1 推测唤醒（`lf=7`）：`isu_iq_store` 新增每槽 `spec_t1_q` / `spec_rr_q`（1 拍 RR 停泊与取消恢复）、4 路 LSU L1 推测取消与基于既有 `byp*_q` + 2-bit `mul_byp*_q` 的 1 级 ALU 孙代 `fast_cancel_raw` 取消；`isu_wake_src` 新增 `fast_spec_q[ALU_NUM]` 并导出 `fast_cancel_valid/preg`；`isu_wake_mul` / `isu_wake_iter` / `isu_wb_gate` / `isu_fp_gate` 与 `isu.sv` 中的 `div_busy_eff` / `fdiv_cnt_eff`（及提前 2 拍 `exe2iss_div_wb_in2`）均支持基于 `spec_mask` 与 `lsu2iss_cancel_valid` 的取消/预留回滚；`isu_iq` 并行输出预译码独热 `grant_wb_cls1h` 直驱静态 `genvar` `isu_wb_gate`（取代 `wb_class` 重译码）；`lsu2iss_wake` 扩至 14 路（`3*LSU_LDU_COUNT + 2`）；
> - **Wall #5（0 周期变化）**：`isu_iq` 将每拍 `ttg_popcount(slot_valid)` 替换为寄存计数器 `used_q` / `ready_num_q`（仅 `flush_br` 拍切至寄存态 `popcount(slot_surv_br)`；附带仿真 `used_q == used_chk` SVA 断言），彻底切断 `dispatch → isu_alloc_chain → popcount → ready_num` 组合长链。

> **2026-11-26 `rtl/area-opt` 按队列定制载荷 + 统一命名**：
> - 6 个发射队列改用统一枚举 `IQ_INT0 / IQ_MEM / IQ_STD / IQ_BR / IQ_FP / IQ_INT1`，并按需裁剪每队列载荷与 `imm` 位宽（剔除各队列无关字段与死开关），发射队列总寄存器位宽净降 **−37.9%**，零周期变化。

## 1. 职责

发射单元：6 个发射队列（INT0、INT1、内存（load 和 STA 合并）、STD、BR、FP）加一张唤醒网络。每拍做四件事：

1. 把分派来的 uop 放进队列（`dis2iss`），入队时叠加本拍已经发生的唤醒；
2. 每个发射口按能力从就绪、且在这个口上完成周期还空着的槽里选一个（最老优先或最低槽优先，见 5.1；完成周期的检查在选择之前，EXP-046），经过 FP 写口闸（`isu_fp_gate`）后发出（`iss2prf`），并预留它的完成周期；
3. 汇总唤醒通道（`iss_awake`，`WAKE_NUM = MAX_WAKEUP_PORTS = 21` 路）：PRF 写回的 load 唤醒、MUL / DIV / FP 的延迟唤醒、ALU 的快速唤醒；LSU 的 load 唤醒和取消另外直接进各队列；
4. 处理 flush、误预测杀死、分支掩码清除。

模型对应一个调度单元 `back.isu`（`Isu::comb_issue`，内部阶段 `ready → issue → awake → calc_latency_next → enq → flush`）。RTL 的子模块边界是为综合和复用划的，模型里没有对应的类。

## 2. 配置（`ttg_cfg_pkg` / `isu_pkg`，现行默认）

执行单元共 **19 个**，`ISSUE_WIDTH = 19`，所有发射口号与物理执行单元一一对应：

| 执行单元 | 个数 | 口号 | 能做什么 | 所属队列 |
| --- | --- | --- | --- | --- |
| ALU 类 | 6 | 0、1、4 / 2、3、5 | 都能做 ALU；0：+MUL +CSR；1：+DIV；2：+MUL +I2F；3：+I2F | 0、1、4 属 INT0，2、3、5 属 INT1 |
| load 专用 AGU | 2 | 6、7 | LOAD | 内存队列 |
| load 与 STA 共用 AGU | 2 | 8、9 | LOAD 或 STA，同一拍各做一条，**load 优先** | 内存队列 |
| STA 专用 AGU | 1 | 10 | STA | 内存队列 |
| STD | 3 | 11、12、13 | STD | STD |
| BR | 2 | 14、15 | BR | BR |
| FP | 3 | 16、17：FMA+FMISC；18：FDIV+FMISC | FP | FP |

内存队列直接管理 `NP = LSU_AGU_COUNT = 5` 个物理 AGU 口（`IQ_AGU_PORT_BASE = 6`）：口 6、7 只服务 load，口 8、9 共享（优先填 load，空余再服务 STA），口 10 只服务 STA，同拍最多发 5 条。

| 队列 | 槽数 | 入队 lane | 口数 | 备注 |
| --- | --- | --- | --- | --- |
| INT0（q0） | 32（`IQ_INT_SIZE`） | 4（`IQ_INT_ENQ_WIDTH`） | 3 | 两个整数队列各管三个口；CSR 进 INT0，I2F 进 INT1（口 2、3 有 I2F 能力） |
| INT1（q5） | 32 | 4 | 3 | |
| 内存（q1，load + STA 合并） | 64（`IQ_MEM_SIZE`） | 6（`IQ_MEM_ENQ_WIDTH`） | 5（2 LD + 2 共享 + 1 STA） | load 挑最老 + 其余最低槽（至多 4 条）分配口 0..3；STA 挑最老 + 其余最低槽（至多 3 条）从高口往低（口 4、3、2）分配未被 load 占用的口 |
| STD（q2） | 16 | 4 | 3 | |
| BR（q3） | 64 | 5 | 2 | 方案 C（`rob_ptr` 冲刷）解除 31 在飞分支上限后扩容至 64 |
| FP（q4） | 32 | 4 | 3 | F/D 总是有 |

其他：槽分配只看寄存的 valid 位；`MUL_MAX_LATENCY = 3`、`DIV_MAX_LATENCY = 17`；`WAKE_NUM = MAX_WAKEUP_PORTS = 21`；`TAG_NUM = 352`；`FPW_CH = 8`。

## 3. 接口

信号组按模型的 `in` / `out` 端口命名：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dis2iss_req_valid / _uop_* [IQ_NUM][8]` | 分派的 uop，按队列、按 lane；`src{1,2,3}_busy` 是入队时"还在等这个源" |
| 入 | `lsu2iss_wake_valid/preg [3*LDU + 2]`、`lsu2iss_cancel_valid/preg [LDU]` | LSU 的 load 唤醒（`[0..LDU-1]` L1 推测、`[LDU..2*LDU-1]` L3 直发、`[2*LDU..3*LDU-1]` L2b STLF/L2a fallback、`[3*LDU..3*LDU+1]` WBP `64→2` one-hot，`LSU_W_N = 14`）和 L1 推测唤醒取消 |
| 入 | `prf_awake_wake_valid/preg` | PRF 写回口的 load 唤醒 |
| 入 | `exe2iss_div_wb_in2` | 1-bit，EXU 口 1 的 DIV 提前 2 拍写回通告，本拍屏蔽口 1 ALU 发射 |
| 入 | `rob_bcast_flush`、`dec_bcast_{mispred, redirect_rob_idx/flag}` | 全局 flush、误预测及重定指向标 |
| 出 | `iss2dis_ready_num [IQ_NUM]` | 每个队列还能收几个：`min(空闲槽数, 入队 lane 数)`，寄存态 `ready_num_q` |
| 出 | `iss2prf_valid / uop / src{1,2}_byp / spec_mask [ISSUE_WIDTH]` | 19 个发射口的发射结果与 L1 推测掩码（进 `iss_rr_reg`） |
| 出 | `iss_awake_wake_valid/preg [WAKE_NUM]`、`iss_awake_cancel_valid/preg [ALU_NUM]` | 唤醒广播与 6 路 1 周期 ALU 孙代取消 |

## 4. 结构

```
 dis2iss[q][w] ─► isu_iq[q]（每个队列一个实例，参数：SIZE / DW / NP / QID / AGE_EN）
                    ├ isu_alloc_chain : 第 k 个有效请求 -> 第 k 个空闲槽（并行秩匹配）
                    ├ isu_iq_store    : 每槽 valid / uop / wait1..3 寄存器；入队、唤醒、取消、发射清除、flush
                    ├ isu_age_matrix  : 年龄矩阵（只在 AGE_EN 的内存队列）
                    └ isu_iq_select   : 每口按能力选一个槽（最老优先或最低槽优先，MEM 直接 5 口映射）
 isu_wake_src : 唤醒通道 = prf_awake | MUL 管线末级 | DIV 晚唤醒（exe2iss_div_wake_*） | ALU 快速唤醒 | FP 倒计时槽
 isu_wb_gate  : 完成周期预留（EXP-035）：按口移位忙表，叠加 DIV busy 与 FDIV 倒计时阻塞信号生成 cls_free
 isu_fp_gate  : FP 写口限制（EXP-032，`FP_WB_PORTS = 2`，闸与忙表更新按 2 个写口写死）
 isu (top)    : 端口适配，本地维护 div_busy_q（口 1）与 fdiv_cnt_q（口 18）阻塞迭代单元重复发射，汇总三道闸并拼接 19 个物理口
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `isu_pkg.sv` | 309 | 队列、口（`IQ_AGU_PORT_BASE` 等）、能力表；uop 结构；完成类与偏移；`cls_blockable`（含 DIV/FDIV 可阻塞类）与 `cls_wb_blockable`（单 `wb_gate` 测验用） |
| `isu.sv` | 416 | 顶层：端口适配、`div_busy_q` / `fdiv_cnt_q` 跟踪及误预测杀死、门控 `cls_free` 传入 `isu_iq` |
| `isu_iq.sv` | 481 | 一个发射队列（含入队寄存的完成类位 `slot_cls_q`、Port 0/2 `src1_is_pc` 过滤、`port_ok`；不再有 `SH_*` 与 `fu_ready` 反压） |
| `isu_iq_store.sv` | 631 | 按 IQ 类型参数化裁剪的槽存储与次态 |
| `isu_iq_select.sv` | 140 | 每口的选择（MEM 5 口直接由 load/STA 候选归约与共享优先复用） |
| `isu_alloc_chain.sv` | 45 | 入队分配 |
| `isu_age_matrix.sv` | 35 | 内存队列年龄矩阵 |
| `isu_wake_src.sv`、`isu_wake_mul.sv`、`isu_wake_iter.sv`、`isu_wake_compact.sv`、`isu_wake_bus.sv` | 218、98、91、36、30 | 唤醒网络 |
| `isu_wb_gate.sv`、`isu_fp_gate.sv` | 85、169 | 完成周期预留、FP 写口限制 |

状态：各队列 `valid_q / uop_q / wait*_q`；MUL 唤醒管线；DIV/FP 倒计时；内存队列年龄矩阵；`isu_wb_gate` 移位忙表；`isu_fp_gate` 计数环；以及 `isu.sv` 内的迭代单元占用寄存器：`div_busy_q`（+ `rob_idx/flag`，+ `spec_mask`，由口 1 授予 DIV 置 1，`exe2iss_div_wb_in2`、flush、误预测杀死或 L1 推测取消时清 0）与 `fdiv_cnt_q`（5 位，+ `rob_idx/flag`，由 `grant[18]` 载入操作延迟、每拍减 1）。

## 5. 一拍内的数据流

### 5.1 选择与发射（只读寄存器）

1. `slot_ready = valid & !wait1 & !wait2 & !wait3`。
2. `isu.sv` 把 `isu_wb_gate` 的 `cls_free` 同本地 `div_busy_q`（口 1 阻塞 DIV 类，即 `wb_class` 2、3）、`exe2iss_div_wb_in2`（DIV 提前 2 拍的写回预告，这拍口 1 的所有类都不放行，`isu.sv` 的 `iss_cls_free = wb_cls_free && !exe2iss_div_wb_in2`）与 `fdiv_cnt_q != 0`（口 18 阻塞 FDIV / FSQRT 类 4..7）组合成 `iss_cls_free`；`isu_iq` 内由 `port_ok[p][i]` 直接屏蔽会碰撞写回或忙碌的槽。
3. 取法：普通口取候选最低槽；内存队列中 load 挑最老 + 其余最低槽占用口 0..3（物理 AGU 0..3），STA 挑最老 + 其余最低槽按 `4, 3, 2` 顺序填入未被 load 占用的口。
4. `cand_valid[p] = 有选中 & !issue_block`、`grant_valid[p] = cand_valid & fp_ok[p]`（不再有 `fu_ready` 过滤，被闸拒绝时本拍不发射）。
5. 授予后按完成类预留写回周期与 FP 写口，并于时钟沿更新 `div_busy_q` 与 `fdiv_cnt_q`。

### 5.2 唤醒

授予生成延迟唤醒请求（MUL 进管线、DIV / FP 进倒计时槽，下拍起可见）和快速唤醒（6 路单周期 ALU 授予直接在本拍广播，仅整数域）。为压缩 `select → grant → wakeup` 关键环路深度，唤醒网络按**数据域**与**快慢路径**拆分：

1. **慢速唤醒**（全部来自寄存输出：PRF 写回 load 4 路（`LSU_LOAD_WB_WIDTH`）、MUL 2 路（`MUL_UNITS`）、DIV 1 路（`DIV_UNITS`）、FP 延迟唤醒 25 路（`FP_RAW_N = FP_REQ_UNITS × 5`，`FP_REQ_UNITS = 5` 个有 FP 能力的口：2、3、16、17、18）、LSU 14 路（L1 推测 4 + L3 4 + L2b/L2a 4 + WBP `64→2` 2），`SLOW_INT_N = 46` / `SLOW_FP_N = 43`，`isu.sv`）：在拍初即稳定，由 `isu_wake_bus` 分别生成整数域 `woken_slow_int[PRF_NUM]`（256 位）和浮点域 `woken_slow_fp[FPRF_NUM]`（96 位），与 `select → grant` 并行；
2. **快速唤醒**（6 路 ALU 授予，`fast_valid[FAST_UNITS]` / `fast_preg[FAST_UNITS]` 低 `INT_W = 8` 位）：不经 `TAG_NUM` 位位图展开，直接广播至监听整数域的队列槽位，在槽内用 6 路 8 位并行比较（CAM）生成 `fast_hit`，与慢速唤醒结果单级相与更新 `wait_d`；
3. **按队列裁剪源与域**：INT0/INT1/BR 仅整数域且无 `src3`；MEM 仅整数域且仅 `src1`（无 `src2`/`src3`）；STD 无 `src3`（`src1` 整数域、`src2` 双域）；FP 仅浮点域（3 源，完全不接 6 路快速唤醒）。本拍授予的槽的寄存器状态不受本拍唤醒影响（模型先 issue 后 awake）。

### 5.3 入队

`isu_alloc_chain`：每个槽数自己前面有几个空闲槽（log 深度的饱和前缀计数），每个请求数自己前面有几个有效请求，秩相等的配对。空闲只看寄存的 `valid`（不等本拍发射腾出的槽）。入队的 uop 先叠加本拍的 `woken`（`wait = en & busy & ~woken[preg]`）。

### 5.4 flush

`flush_all` 清所有 valid 和延迟唤醒；`flush_br = mispred & !flush`：比 `flush_rob_idx/flag`（被预测错的分支）更年轻的项被杀（`isu_rob_younger`，9 位 `{rob_flag, rob_idx}` 循环年龄比较；本拍入队的也同样检查）。`issue_block = rob_flush | mispred` 阻止本拍发射。

### 5.5 ready_num

由寄存计数器 `used_q`（与 `used_d` 同步计算并打一拍至 `ready_num_q`）给出 `min(SIZE - used_q, 入队 lane 数)`。正常拍 `used_d` 按 `used_q + popcount(enq_valid) - popcount(grant_free) - popcount(slot_rr_ret)` 更新，不经过 `isu_alloc_chain` 和 64 位 `slot_valid_d` 归约；`flush_br` 拍切到基于 `slot_q` 存活掩码 `slot_surv_br` 的 `popcount`。

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
- 调度策略：内存队列每种能力的第一个口取最老、其余取最低槽（`isu_iq` 参数 `AGE_EN = (q == IQ_MEM)`，带年龄矩阵）；其他队列取最低槽。模型里原来的选择开关 `CFG_ISSUE_OLDEST_FIRST` / `CFG_ISSUE_OLDEST_QUEUES` 已删除，固定为同一策略；
- 快速唤醒里的 `op != UOP_LOAD && op != UOP_STA`（模型 `Isu.cpp:242`）：RTL 不判。每个口只选自己能力范围内的槽，而有快速通道的口 0..5 的能力掩码里没有 `UOP_LOAD`（第 3 位）和 `UOP_STA`（第 4 位），这两种 uop 不可能在这些口被授予。

- EXP-046：模型的 `ISS_REF_*` / `ISS_LOST_*` PMU 事件只在模型里。模型的忙表仍是 64 项环（`WbBusy`），RTL 是按口长度的移位寄存器，行为相同（`tests/wb_gate` 对照）。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- `countdown == 0` 的 DIV / FP 槽在当拍广播后立刻释放，同拍新发射的可以复用；
- 延迟唤醒广播用当前拍状态，不受本拍误预测影响（被错误路径杀掉的 MUL / DIV 也会广播一次）；
- 溢出时 RTL 丢掉多出的请求，不报错（分派受 `ready_num` 流控，不会发生）。

配置相关的有意差异：RTL 只有现行这一种配置（load 与 STA 合并成一个内存队列，没有独立的 STA 队列）；两个 INT 队列、内存队列的最老优先、不等本拍发射的槽分配、共用 AGU 在模型里是编译期开关（`CFG_INT_CLUSTERS`、`CFG_IQ_SAME_CYCLE_REUSE`、`CFG_LSU_AGU_SHARED`；`CFG_MEM_MERGE`、`CFG_ISSUE_OLDEST_FIRST/QUEUES` 已删），这些开关在模型里的默认值就是 RTL 配置，参考周期用默认配置的模型生成。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`lint_chip` & `lint_soc` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 全通；Linux 26/26 窗对齐；SPEC06 INT 386/386 `geomean +0.144%`（`ISS_REF_AGU` 由 `130,716.5` 降至 `0`）。
- **EXP-046（`exp/wb-presel`）**：`tests/wb_gate`（`run.sh <工作目录>`）：`wrap.sv` 把忙表和 `isu_pkg` 的类表（偏移、每口服务的类）一起导出，`check.py` 随机 3 万拍对照模型的 `WbBusy`，同时检查 `port_ok`（2026-11-28 起 `isu_wb_gate` 不再输出它，由 `wrap.sv` 从 `cls_1h` 与 `cls_free` 自己算）和每口每类的 `cls_free`：0 不一致；植入错误（类 0 的 `cls_free` 恒 1）后 24140 拍不一致。原来的测试驱动的是已删除的 `off` 输入，在 main 上编译不过，这次一并改写。整核：`fm_gate` 67/67 逐条对函数模型无不一致，周期对模型（trace-model `exp/wb-port` `60aa7e8` 的 `CFG_WB_PRESEL=1`，合入版里这是唯一行为，RVC=1 构建，程序用 `build_tests.sh` 的 rv64ima 版）67/67 相等（合入 `exp/llc-plru` 后的集成分支，参考周期 `scripts/ref_cycles.txt` 用 `LSU_PIPE_NOWD=1` 生成；早先记录的"crc32 RTL 2196 / 模型 2199"是生成参考时没关模型的 LDQ / STQ 看门狗造成的误判，`tm_cycles.sh` 现在默认关掉它）。

- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）：77/77 通过（最近一次 rtl 73761fa，2026-11-28），周期逐个相等。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **`tests/isu_iq_select`**（fe-2ahead 新增）：`run.sh [向量数，默认 200000]` 用 Verilator 编 `eq_top.sv`，对 `IQ_NUM = 6` 个队列各按 `isu.sv` 实际用的参数（`SIZE`、口数、`AGE_EN`）实例化现行 `isu_iq_select` 和改写前的副本 `isu_iq_select_ref.sv`，随机 `slot_ready` / `port_ok` / 年龄矩阵逐拍比较选择结果，输出 PASS 或第一个不一致。用于验证去掉 UNOPTFLAT 的每口生成块改写（见第 10 节 2026-11-28）。
- **`tests/fp_gate`**：`run.sh <工作目录>` 用 Verilator 编 `isu_fp_gate`（`-DFP=1` 生成的 `ttg_cfg_pkg`），`check.py` 对照参考的 FP 写口预留。
- 分配链、年龄矩阵没有单独测试，靠整核周期逐拍相等和 Linux 启动。旧体系的 trace 回放 + 随机 trace + 变异检查（spec/、`tests/isu`）已随 `spec/` 一起退役，旧的变异表在本文件的 git 历史里（`git log -- docs/modules/isu.md`）。

## 9. 参数与开关速查

`IQ_INT_SIZE`、`IQ_INT_ENQ_WIDTH`、`IQ_MEM_SIZE`、`IQ_MEM_ENQ_WIDTH`、`LSU_AGU_SHARED`、`IQ_STD_*`、`IQ_BR_*`、`FP_IQ_*`、`FP_WB_PORTS`（`isu_pkg`，EXP-032）。LSU 推测唤醒与取消总是开（原 `LP_L2[3]`，已删除）。`ttg_cfg_pkg.sv` 由 `make cfg`（`harness/tools/gen_cfg_pkg.py`，从 trace-model `include/config.h`）生成，不手改。

## 10. 变更记录

- 2026-11-28 清理：删 `FP_EN`（F/D 总是有：`isu_pkg` 各 `FP_EN ?` 分支、`isu.sv` 的 `g_no_fp_wake_bus` / `g_no_gate` / `g_no_fdiv_occ`、`isu_iq` / `isu_iq_store` / `isu_wake_src` 的 `FP_EN` 条件）；删永不读的 FP free2 链（`isu_iq` 的 `fp_free2_cls` 输入、`sf2`、`slot_fpc_bits` 最高位、`grant_fp_f2`，`isu.sv` 的 `grant_fp_f2_all` / `c_f2`，`isu_fp_gate` 的 `cand_f2` 输入；`fp_free2_cls` 改为 `isu_fp_gate` 内部的 8..10 类）；`isu_fp_gate` 删参数 `P` 及 `P != 2` 的 `g_gen_p` / `g_upd_gen` 分支和 `same_slot`；`isu_wb_gate` 删输出 `port_ok`（`isu.sv` 的 `wb_port_ok` 不读）；`isu_wake_iter` 只剩单请求（删 `NREQ`、`req_lane`、`wake_lane`、每槽 `lane_q`）；`isu_pkg` 删未用的 `wb_offset`、`FP_SLOTS`；`isu_wake_src` 头注释改为 21 个唤醒通道；删不抑制任何告警的 lint 豁免（`isu.sv` 3 处、`isu_fp_gate` / `isu_iq` / `isu_iq_select` 各 1 处，以去掉豁免后整树 lint 普通 / `-DSYNTHESIS` 均无新告警为准）（周期不变）。
- 2026-11-28（文档核对，无 RTL 变化）：`WAKE_NUM = 21`、`TAG_NUM = 352`、慢速唤醒 `SLOW_FP_N = 43`（DIV 1 路、FP 25 路）与 256 位位图、快速唤醒 8 位比较；`exe2iss_div_wb_in2` 替换 `div_wb_next`；按 ROB 号的误预测冲刷代替分支掩码；模型已删的 `CFG_ISSUE_OLDEST_*`；文件表补行数；第 8 节加 `tests/isu_iq_select`、`tests/fp_gate`；`ttg_cfg_pkg` 为生成文件；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/fe-2ahead`，0 周期变化）：消除整核 Verilator `UNOPTFLAT`：`isu_iq_store` 每槽的 `rr_active / rr_cancelled / rr_retired` 从读 `issue_clear`（本拍授权）的 `always_comb` 里拆成独立 `assign`（`slot_ready` 经选择 → 授权 → `issue_clear` 的假环）；`isu_iq_select` 串行选择的 `taken` / `sel_onehot` 改成每端口生成块信号（`g_port[p].oh`、`taken_c`），后端口只读前端口。新增 `tests/isu_iq_select/run.sh`：与改前版本（`isu_iq_select_ref.sv`）按 6 个队列的实际参数逐拍对拍，20 万组 PASS，断开 taken 链的变异第一批即报错。

- 2026-11-28（`rtl/exu-clean`，EXP-072）：去除 `exe2iss_fu_ready_mask` 输入，在 `isu.sv` 内增加确定性 `div_busy_q`（port 1，`exe2iss_div_wb_next` 前 1 拍让路 ALU 写回）与 `fdiv_cnt_q` 占槽；`isu_iq_select.sv` 将逻辑 7 槽合并负载在选口侧直接复用至 `NP = LSU_AGU_COUNT = 5` 物理 AGU 口（`ISSUE_WIDTH = 19`）。Tier 1（`Yosys+PT`，`0.50 ns`）实测：**总面积 `526,654.30 → 512,886.19 µm²`（−2.61%）**、**`Seq 29,106 → 28,331`（−775 FF）**、`WNS_r2r −0.38 → −0.39 ns`（`TNS_r2r −5,794.05 → −5,647.62` 改善）、总 `WNS −0.48 ns`（`in->out` `lsu2iss_cancel_preg[18] -> iss2prf_uop[1312]`）。

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
