---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
model: trace-model front-end/BPU/BPU_pipe.h、BPU.h、BPU_configs.h（调度单元 `front.core.bpu_pipe`，类 `BpuPipe`，阶段 `comb_front`，决定函数 `decide` 在 `front.core.ctrl` 的 `control` 阶段里先算）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 待测（由协调者补）；子块已测的数字见第 6 节
---

# bpu 设计文档（流水化分支预测单元）

背景、模型侧设计和早期的综合 / 性能数字见 [../analysis/bpu-pipe-rtl.md](../analysis/bpu-pipe-rtl.md)（那份是分支时期的记录，其中的综合表和若干位宽已经过时，本文以现行代码为准）。

## 1. 职责

每拍预测一个取指块（从某个 pc 起、至多 16 个槽、不跨 64 字节缓存行，即 `block_bnd`），三级流水（S0、S1、S2）：

1. **S0**：用块的起点 pc 在 uBTB（小而快的表）里查，得到"猜测"：这个块里有没有预测跳的分支、跳到哪、往全局历史里推什么、对返回地址栈（RAS）做什么。按猜测更新投机历史和投机 RAS，下一拍从猜测的目标继续；块的起点地址同时写进取指地址队列，让 I-Cache 去取；
2. **S1**：这个块的 16 个槽并行读主预测器的阵列（分支类型表、TAGE、BTB、间接目标表 ITT）；同时用更大的 L1 表再查一次，如果它命中且与 S0 的猜测不同，就用 L1 的结果覆盖（损失 1 拍）；
3. **S2**：在读出的数据上比较、选择，得到最终预测（每槽方向、第一个预测跳的槽、目标、历史位、RAS 操作），写进 PTAB；与块带来的猜测不同就"覆盖"：作废 S1 里更年轻的块，从最终预测的目标重新开始（损失 2 拍）；
4. **修复**：后端分支误预测、预译码冲刷时，把投机历史和 RAS 恢复到出错那个块之前的检查点，再推上那个块的正确结果；
5. **训练**：提交流（每拍至多 8 条）训练 uBTB / L1（经块跟踪器和训练队列）、更新队列训练类型表 / TAGE / BTB / ITT，同时推进"提交态"的历史和 RAS（出错时作为恢复的后备）。

模型里是一个调度单元 `front.core.bpu_pipe`（`BpuPipe::comb_front`），S2 的决定 `decide` 只读寄存器，由 `front.core.ctrl` 先算出（`pipe_dec`），再交给 BPU 和取指地址队列。RTL 的子模块边界是为综合和复用划的，模型里没有对应的类。

## 2. 配置（`bpu_pkg` / `bpu_stage_pkg` / `ttg_cfg_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| 块 / 槽 | 16 个槽（2 字节），32 字节；bank = `pc[4:1]`，共 16 个 bank | `FETCH_WIDTH`、`NBANK`、`BANK_W = 4` |
| uBTB（S0） | 32 组 × 4 路 = 128 项 | `UB_SET_W = 5`、`UB_WAYS = 4` |
| L1 表（S1） | 256 组 × 2 路 = 512 项 | `L1_SET_W = 8`、`L1_WAYS = 2` |
| uBTB / L1 项 | 83 位：有效 1、标签 10、类型 3、槽 4、计数器 2、目标槽地址 62、16 位标志 1 | `ub_ent_t`，`UB_TAG_W`、`UB_SLOT_W`、`UB_TGT_W = XLEN - 2` |
| 类型表（每 bank） | 512 组 × 2 路；项 = 有效 1、标签 8、类型 3、年龄 2、16 位标志 1 | `TP_SET_W = 9`、`TP_WAYS`、`TP_TAG_W`、`tp_entry_t` |
| TAGE（每 bank） | 基础表 1024 项 × 2 位；4 张带标签表各 1024 项（标签 8、计数 3、useful 2）；历史长度 8 / 13 / 32 / 119 | `T_BASE_W = 10`、`T_IDX_W = 10`、`T_TAG_W = 8`、`TN = 4`、`ghr_len()` |
| BTB（每 bank） | 256 组 × 4 路；项 = useful 3、有效 1、标签 8、目标 `XLEN` | `B_IDX_W = 8`、`B_WAYS = 4`、`B_TAG_W = 8`、`btb_ent_t` |
| ITT（每 bank，间接目标表） | 3 张表 × 64 项，复用 TAGE 第 1、2、3 张表（历史 13 / 32 / 119）的索引低 6 位和标签；项 = 有效 1、标签 8、置信 2、useful 1、目标 `XLEN` | `NITT = 3`、`ITT_IDX_W = 6`、`ITT_TBL`、`itt_ent_t` |
| 全局历史 | 256 位环 + 8 位头指针 + 12 个折叠历史（3 种 × 4 张表，每个至多 11 位）；一个跳转推 3 位符号 | `HR_BITS = 256`、`HR_PTR_W`、`FH_K = 3`、`FH_W = 11`、`HSYM_W = 3` |
| 历史检查点 | 140 位（头指针 8 + 折叠历史 132） | `HHCK_W` |
| 提交态 RAS | 32 项环形栈 | `RAS_DEPTH = 32` |
| 投机 RAS | 64 槽只追加队列（栈值 + 指向下一项的链接）+ 读 / 写指针（各 6 位）+ 深度（6 位） | `RASQ_N = 64`、`rptr_t` |
| RAS 检查点 | 指针 18 位（`tosr`、`tosw`、`cnt`）随块走到后端；栈顶值只在 BPU 内（`ras_ck_t.top`，64 位） | `RCK_W = 18` |
| 随块走的修复记录 | 纪元 8 位 + 检查点 158 位 = `BCK_W` 166 | `EPOCH_W = 8`、`HCK_W` |
| 更新队列 | 8 项，每拍至多写 2 组（2 个"领头"），4 个块 bank（32 字节窗口） | `UQ_DEPTH = 8`、`UQ_PORTS = 2`、`NBB = 4` |
| uBTB 训练队列 | 4 项 | `TQ_DEPTH = 4` |
| PDCKPT 队列 | 32 项 | `PQ_DEPTH = 32` |
| 提交口数 | 8 | `NCOMMIT = COMMIT_WIDTH` |
| PTAB 信用 | `ptab_size + 在途块数 >= PTAB_SIZE - 1` 则 S0 不发射 | `PTAB_SIZE = 16`（`bpu_ctl`） |
| 快速路径 | `FE_RFAST` 位 0 = 重定向那一拍 S0 就按新 pc 发射；`FE_BFAST = 0` | `ttg_cfg_pkg` |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `refetch`、`refetch_address`、`refetch_pd` | 全局重取指及地址；`refetch_pd` = 这次重取指来自预译码检查器 |
| 入 | `icache_read_ready`、`ptab_size` | 取指地址队列未满且 BPU 可走（`bpu_icache_read_ready`）；PTAB 当前占用 |
| 入 | `rf_valid / rf_ck / rf_epoch / rf_type / rf_pc / rf_is_rvc` | 后端分支误预测带回的修复记录 |
| 入 | `pd_valid / flush / hv / hbits / ras_op / ras_val / nb_valid / nb_pc` | 上一拍预译码检查的结果（`front_pd_info`，寄存一拍）：是否检查过一个块、是否冲刷、修正后的块推什么、"预测跳但不是分支"的 pc |
| 入 | `upd_valid / base_pc / actual_dir / upd_is_rvc / br_type / target / pred_dir / alt_pred / pcpn / tags / idxs [NCOMMIT]` | 提交流训练包 |
| 出 | `icache_read_valid`、`fetch_address` | S0 发射的块（`s0_go`、`s0_base`），写取指地址队列 |
| 出 | `override_valid`、`override_squash` | S2 覆盖；`squash = ovr & S1 有块`，前端据此丢取指地址队列最年轻项 |
| 出 | `ptab_write_enable`、`ptab_base_pc`、`predict_next_fetch_address`、`out_pred_dir / alt_pred / pcpn / tage_tags / tage_idxs [16]`、`out_ck`、`out_epoch` | S2 写 PTAB 的内容；`out_ck = {RAS 指针, 历史检查点}` |
| 出 | `commit_upd_free`、`commit_tq_free` | 更新队列、训练队列的空闲项数（拍初），给紧凑 ROB 做提交信用 |

## 4. 结构

```
 pc_q ─► [S0] bpu_stage0（16 个 bank 的 TAGE 索引记录）、bpu_ubtb.s0（uBTB 查表 -> 猜测 g0）
              bpu_cmd（下一 pc、投机历史 / RAS 命令）、bpu_spec（投机 + 提交态 历史 / RAS）
        r0 (S1 块: base, g0, 检查点) + r0_tix ─► [S1] bpu_banks 读阵列（类型 / TAGE / BTB / ITT） + bpu_ubtb.s1（L1 查表 -> g1）
        r1 (S2 块) + r1_raw ─► [S2] bpu_banks.TAGE 选择 -> bpu_main_sel（每槽类型 / 方向 / 目标、第一个 taken -> fin）
 bpu_ctl（refetch / ovr / l1_ov / issue 的优先级）   bpu_pdq（PDCKPT 记录）   bpu_updq + bpu_updq_sched（更新队列）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `bpu.sv` | 276 | 顶层：阶段寄存器 `pc_q`、`r0_q`、`r1_q`、`r0_tix_q`、`r1_tix_q`、`r1_raw_q`、`epoch_q`，子模块连线；FAST 时 S0 看的是重定向后的 pc 和状态 |
| `bpu_pkg.sv` / `bpu_stage_pkg.sv` / `bpu_btb_pkg.sv` | 108 / 289 / 35 | 常量、类型、历史环和 RAS 的推进函数、索引 / 哈希函数 |
| `bpu_stage0.sv` | 30 | 对 16 个 bank 算 TAGE 索引记录（`tage_index`：索引 = 折叠历史0 ^ bank pc，标签 = 折叠历史1 ^ 折叠历史2 ^ bank pc） |
| `bpu_ubtb.sv` | 95 | uBTB（S0）、L1（S1）、训练路径（块跟踪器 → 训练队列 → 一次读改写两个表） |
| `bpu_ub_tab.sv` / `bpu_ub_look.sv` / `bpu_ub_rmw.sv` / `bpu_ub_tq.sv` | 39 / 83 / 83 / 54 | 表存储（一个查表口、一个训练读口、一个带路掩码的写口）；查表；读改写；训练队列 |
| `bpu_ub_track_ser.sv` | 224 | 提交序块跟踪器（RVC=1 版，现行） |
| `bpu_ub_track.sv` | 186 | 提交序块跟踪器的并行版，只在 `RVC_ENABLE == 0` 时例化，现行配置不用 |
| `bpu_banks.sv` | 111 | 16 个 bank 的主预测器阵列：类型表、TAGE、BTB / ITT；S1 读、S2 TAGE 选择、更新写口 |
| `bpu_type.sv` / `bpu_type_lane.sv` | 73 / 56 | 类型表（两路，每 bank 一条更新通道）；一个 bank 的命中 / 选择 / 替换 / 更新组合逻辑 |
| `bpu_tage_bank.sv` / `bpu_tage_pred.sv` / `bpu_tage_upd.sv` | 180 / 49 / 157 | 一个 TAGE bank：阵列与 LSFR、复位计数器、use-alt 计数器；S2 选择（提供者 / 备选 / 弱提供者用备选）；更新决定 |
| `bpu_btb_bank.sv` / `bpu_btb_sel.sv` / `bpu_btb_upd.sv` | 98 / 50 / 116 | 一个 bank 的 BTB + ITT 阵列；目标选择（间接跳转先 ITT 最长历史命中，再 BTB，否则顺序）；更新 |
| `bpu_mem.sv` | 47 | 寄存器堆式阵列（异步读、同步写、多读口多写口），读到的是拍初内容 |
| `bpu_main_sel.sv` / `bpu_main_lane.sv` | 109 / 44 | S2：逐槽的类型、方向、目标，第一个 taken 槽，下一 pc、历史位、RAS 操作 |
| `bpu_ctl.sv` | 75 | 本拍的决定：`d_valid`、`ovr`、`squash`、`l1_ov`、`issue`、`fast`、`s0_go`、`pd_restore`、`rep_ok` |
| `bpu_cmd.sv` | 164 | 本拍对投机历史 / RAS 的命令（保持 / 推 / 取检查点再推 / 取提交态再推）和下一 pc |
| `bpu_spec.sv` / `bpu_hist_vec.sv` | 266 / 80 | 投机和提交态历史与 RAS；一次推入 n 位历史的并行网络 |
| `bpu_pdq.sv` | 61 | PDCKPT 记录队列 |
| `bpu_updq.sv` / `bpu_updq_sched.sv` | 139 / 87 | 更新队列；写调度 |

状态：`pc_q`；S1、S2 的块寄存器（`valid`、`base`、猜测 `g`、检查点 `ck`）；S1 / S2 的索引记录（16 个 bank）；S2 的阵列读数据（16 个 bank 的类型 2 路、TAGE、BTB 4 路、ITT 3 张）；`epoch_q`；阵列（uBTB 128 项、L1 512 项、类型表 16 × 1024 项、TAGE 16 × (1024 + 4 × 1024) 项、BTB 16 × 1024 项、ITT 16 × 3 × 64 项）；投机 / 提交历史（各 256 位环 + 头 + 折叠历史）；投机 RAS 队列（64 槽 × (64 位 + 6 位链接)）和指针、提交态 RAS（32 × 64 位 + 指针）；更新队列 8 项；训练队列 4 项和块跟踪器的寄存器（`tr_v`、`tr_expect`、`tr_start`、一位表示余量的独热 `tr_rem`、`tr_cond`）；PDCKPT 队列 32 项（每项一个检查点：历史 140 位 + RAS 18 位指针 + 栈顶 64 位）。

### uBTB / L1 的查表（`bpu_ub_look`）

每路并行算：标签是否匹配（项有效、标签 = 块起点字地址 `>>5`（uBTB）或 `>>8`（L1））；"槽在块内"（槽偏移 × 2 < 块长，块长 = 块终点 - 起点，只取低 8 位比较）；是否预测跳（条件分支要计数器 ≥ 2，其余类型无条件）。候选里**槽最低**的路获胜，同槽取路号小的，成对比较，再一次选择。猜测：命中且有候选则 `taken`，下一 pc = 返回类型且 RAS 非空则 RAS 栈顶，否则 `{块起点高 32 位, 项里的目标槽地址低 32 位 << 1}`；历史位 = `hsym_of(分支 pc, 下一 pc)`（pc 与目标的 XOR 折叠成 3 位）；调用（CALL / ICALL）压栈，值 = 分支 pc + 指令长度；返回弹栈。没有候选则下一 pc = 块终点，不推历史。

### 块跟踪器与训练（`bpu_ub_track_ser`、`bpu_ub_tq`、`bpu_ub_rmw`）

提交流按提交序重建"每条指令属于哪个取指块"，每个提交口至多产生一个训练事件：taken（跳转，块在此结束，下一块从目标开始）、fall-through（块顺序走到终点，且块里有过条件分支）、预测 taken 实际 not taken（块在 pc + 指令长度重新开始）。RVC 下一个块终点可能落在一条 32 位指令中间，下一块仍从块终点开始，但后一提交口还是它的续接（`tr_expect` = 下一 pc），所以块起点依赖前一口的结果，只能按口串行；现行写法（`7551dd0`）把串行的状态改成"到块终点的余量"（一个小数，独热存），完整地址只放在寄存器里，每口的块起点是几个局部值的选择，口间传递的只剩 8 位量。

事件进训练队列（4 项，每拍弹队首，满了丢新事件），队首事件对 uBTB 和 L1 各做一次读改写（`bpu_ub_rmw`）：块里槽号小于事件槽的条件分支路的计数器减 1（fall-through 事件是全部条件分支路，预测 taken 实际 not taken 的事件含事件槽本身；事件槽自己那一路不减）；taken 事件找槽相同的路更新（条件分支计数器加 1，其他类型置 3），没有就分配（先无效路，否则计数器最小的路），新项的计数器：条件分支 2、其他 3。

### 更新队列（`bpu_updq`、`bpu_updq_sched`）

提交口里的控制指令（类型非 `BR_NONCTL`）按序进更新队列（8 项，满了丢）。每拍调度两个"领头"写：领头 1 = 最老的、块 bank 不被 S1 正在读的块占用的项，同一个 32 字节窗口且 TAGE 索引相同、槽 bank 不冲突的更年轻项合并进同一次写；领头 2 = 剩下的最老的、块 bank 空闲且与领头 1 不同、槽 bank 不被组 1 用的项，同样合并。被调度的项离开队列，同拍出现在槽 bank 的写口上（每个 bank 一个写口）。保留的项保持顺序，新项接在后面；位置用"前缀计数"算（`47f4a7d`）：保留项的新位置 = 它前面的保留项个数。

### 主预测器（`bpu_banks` 及其下）

S1：每个 bank 用 S0 记录好的索引读自己的阵列，读出的原始数据寄存进 S2。S2：TAGE 每 bank 选提供者（命中的最高表）和备选（次高命中表），弱提供者按 use-alt 计数器用备选；类型表按标签选类型，未命中是 `BR_NONCTL`；某槽预测跳 = 类型非 NONCTL 且（RET / CALL / ICALL / IDIRECT / JAL，或 TAGE 预测跳）；目标：间接跳转用 ITT 最长历史命中的表，其余用 BTB 命中，未命中用顺序（该槽 pc + 指令长度）；RET 且检查点里 RAS 非空则用栈顶。第一个 taken 槽给出 `fin`：下一 pc、历史位、RAS 操作。更新：只有条件分支训练 TAGE；所有控制指令训练类型表和 BTB；间接跳转还训练 ITT。预译码发现"预测跳但不是分支"时，`nb_pc` 清类型表里对应项（该 bank 的更新通道必须空闲）。

## 5. 一拍内的数据流

优先级 **refetch > S2 覆盖（ovr） > L1 覆盖（l1_ov） > S0 发射**（`bpu_ctl`）。

1. **S2 决定**：`d_valid = r1.valid & !refetch`；`ovr = d_valid & pred_differs(fin, r1.g)`（比较下一 pc、是否 taken、历史位、RAS 操作和压栈值）；`squash = ovr & r0.valid`。`d_valid` 时块写 PTAB（`ptab_write_enable`），其检查点进 PDCKPT 队列。
2. **S1 的 L1 比较**：`l1_ov = !refetch & !ovr & r0.valid & g1.hit & pred_differs(g1, r0.g)`；成立时 `r1_d.g = g1`，S0 本拍不发射，投机状态恢复到 S1 块的检查点再推 g1。
3. **S0 发射**：`issue = !refetch & !ovr & !l1_ov & icache_read_ready & !ptab_stall`；`ptab_stall = icache_read_ready & (ptab_size + r0.valid + r1.valid >= PTAB_SIZE - 1)`（在途的块算占用，PTAB 不会溢出）。FAST（`FE_RFAST` 位 0）时重定向那一拍也发射：`fast = icache_read_ready & refetch`，不看 `ptab_stall`；这一拍 S0 查的是重定向后的 pc、用恢复之后的历史和 RAS（`s0_base = pc1`、`spec1_*`），所以重取指没有额外的一拍。
4. **修复（refetch 时）**：`pd_restore = refetch & refetch_pd & pd_valid & pd_flush & pdq_have`：取 PDCKPT 队首的检查点，再推修正后块的历史符号 / RAS 操作；否则 `rep_ok = refetch & rf_valid & rf_epoch == epoch_q`：取后端带回的检查点（历史 + RAS 指针），再推这条分支自己的结果（条件分支：目标不是顺序下一 pc 才推，符号 `hsym_of(rf_pc, refetch_address)`；类型 CALL / ICALL 压栈 `rf_pc + 指令长度`，RET 弹栈）；否则（没有记录或纪元不符）装载提交态历史和由提交态栈重建的 RAS，纪元加 1。
5. **投机状态命令**（`bpu_cmd` → `bpu_spec`）：一拍恰好一个命令，模式 HOLD / PUSH / CK / ARCH；FAST 时 S0 的推入是在命令之后的第二步（`h2_*`、`r2_*`）。下一 pc：refetch 取重定向地址，ovr 取 `fin.next`，l1_ov 取 `g1.next`，发射取 `g0.next`。
6. **阶段寄存器**：`r0 ← {s0_go, s0_base, g0, s0_ck}`；`r1 ← r0`，有效位 `r0.valid & !refetch & !ovr`，`l1_ov` 时 `g ← g1`；`r1_raw ← S1 读数据`；索引记录随块移动。
7. **提交侧**（与上面并行）：`bpu_spec` 把提交的跳转符号（每拍至多 8 个 × 3 位）一次压进提交态历史（`bpu_hist_vec`），提交的 CALL / ICALL / RET 推弹提交态 RAS；更新队列、块跟踪器如上。

## 6. 关键路径与深度

`depth: 待测（由协调者补）`。已测的单模块数字（通用门级代理，层数）：

| 模块 | 层数 | 说明 |
| --- | --- | --- |
| `bpu_ub_track_ser` | 97 | 改写前 528 |
| `bpu_updq` | 90 | |
| `bpu_ub_look` | 29 | 改写前 75 |
| `bpu_spec` | 91 | 含 `bpu_hist_vec` |
| `bpu_cmd` | 24 | |
| `front_top`（整个前端） | 132 | **uBTB 查表改写之前**；路径在 BPU 内：S1 阶段寄存器 → uBTB 查表 → override / 发射判定 → 投机历史更新 |

从代码读出的，未综合验证：BPU 里有两个"环"。一个是 S0 环：`pc_q`（或 FAST 时的 `pc1`，它本身是 `refetch / ovr / l1_ov` 的选择）→ `bpu_ub_look` → `g0` → `bpu_cmd`（`h2_*` 推入、`pc_d`）→ `bpu_spec` 的次态。另一个是 S1/S2 决定：`r0_q / r1_q`、阶段读数据 → `bpu_main_sel`（16 路并行的类型 / 方向 / 目标 + 第一个 taken 的 `first_set` + 64 位目标选择）→ `fin` → `pred_differs` → `ovr` → 回到 `r1_d`、`pc_d`、投机历史命令、取指地址队列的 `fa_drop_tail`。前端整体 132 层的那条路径属于第一个环的前身。`bpu_spec` 的 91 层主要是并行压入 24 位历史和两份 RAS 的读改写。

深度相关的改动（均不改变周期，每次都有 fm_gate 67/67 周期相等和 lint 0）：

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| `bpu_ub_track_ser` 低深度改写 | `7551dd0` | 528 → 97；串行状态用"到块终点的余量"（独热）代替 64 位地址，地址比较只用车道输入和 `tr_expect`，块起点是局部值的选择 |
| `bpu_updq` 用前缀计数压缩 | `47f4a7d` | 保留项新位置 = 前面的保留项数，不再用运行下标；深度 90 |
| `bpu_ub_look` 低深度查表 | `2c76ba2` | 75 → 29；每路并行算候选和结果，槽最低者成对比较后一次选择 |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `FE_PAIR`（一拍取两块，默认关）整套：第二块的查表、`b2`、`pair` 字段、`rec2`；
- uBTB / L1 项里的 `nd_t`、`nd_nt`、`taken` 字段（taken 路径历史下无用）：RTL 的项没有；
- 类型表项里的 2 位置信计数器（只被从不使用的输出读）：RTL 不存；
- SC-L / 循环预测器：没有，TAGE 的提供者恒"被使用"；
- 模型的 `rec_[256]`（按块序号存修复记录）：RTL 把检查点随块带到后端 FTQ，块在途期间两者等价（序号与 pc 的校验在 RTL 里按构造恒成立）；
- 调试输出（`hp`、`HP_TRACE`）、PMU 的 `pmu_l1_ovr / pmu_ptab_stall`、`warm_commit` 一族（快速预热回放）、`dump_hist`：RTL 不含；
- PDCKPT 队列：模型 `PQ = 64`，RTL `PQ_DEPTH = 32`；溢出时 RTL 静默丢新记录（`bpu_pdq` 的 `do_push` 条件）。占用不会超过 PTAB 项数加在途块数（≤ 18）这一点是旧文档的说法，见下面的未核对。

RTL 与模型保持一致的细节：

- 投机 RAS 是只追加队列：压栈写新槽并记下它下面那项的链接，弹栈只移动读指针，所以检查点只需保存指针，恢复精确（环形栈在"弹出后错误路径压栈"时会覆盖栈顶下面的项）；
- 纪元：每次把投机历史整体换成提交态（`refetch & !pd_restore & !rep_ok`）就加 1，之前发出的检查点因此失效（历史环被重新定基），修复记录的纪元不符就退回提交态；
- 一个块的检查点是"这个块 S0 推入之前"的状态，覆盖 / 修复时先恢复到它再推新结果。

两处需要注意（代码里看到的，没有改）：

- `bpu_ub_look` 查表的目标：uBTB / L1 项里存 62 位目标槽地址，但查表只用低 32 位（`32'(tgt) << 1`），高 32 位取自块起点（`(base & ~32'hffffffff) | ...`）；模型 `ub_expand` 是 `t << SLOT_SHIFT`，保留完整目标，其注释写明"跳到另一个 4 GiB 区域（内核 ↔ 用户）也能精确预测"。这个差异在 `2c76ba2` 之前就存在（旧写法同样）。跨 4 GiB 区域的跳转，S0 / L1 的猜测目标在 RTL 里会落在块起点所在的 4 GiB 区域里；它是否会让 RTL 周期偏离模型没有分析，列入报告，没有改；
- `bpu_pkg.sv` 里 `NLANE` 的注释还写着 "(8)"，现值是 16（`FETCH_WIDTH`）；`bpu_pkg.sv` 头注释说"ttg_cfg_pkg 不导出 BPU 专用宏"，所以 `TN`、`T_IDX_W` 等是手工写的，与 `frontend_feature_config.h` 的一致性靠 `docs/analysis/tools/widths.cpp` 检查，本轮没有重跑。

`FE_BFAST != 0` 的分支（`bpu_cmd`、`bpu_ctl`、`bpu_spec`、`fetch_addr_fifo` 的 `WR_AFTER_DROP`）在现行配置下不会被综合进来，模型里该开关也已删除（`BPU_pipe.h` 注释），这些代码没有被任何门禁覆盖。

未核对（继承自旧文档 docs/analysis/bpu-pipe-rtl.md 与旧 bpu.md）：

- PDCKPT 队列"实际占用不超过 PTAB 16 + 在途 2"；
- 模型与零气泡设计的性能对比（coremark 慢 16–18 %、30 点 SPEC 几何平均 +1.9 % 等）和第 4 节的综合单元 / 层数表：是分支时期的数字，本轮没有复现，大部分已被后来的改写取代；
- "没有跑 Linux"：当时的状态，现在 Linux 门禁在用，见下节。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`：67/67 通过，周期逐个相等。预测错一次就会改变取指时序，所以周期逐个相等对 BPU 是很强的检验。`itt-dispatch`（间接跳转表，ITT 路径）、`coremark`、`dhrystone`、`recursion`、`quick-sort`、`switch` 等分支密集的程序在内。
- **指纹**：`scripts/align_check.sh` / `align_check.py`：模型和 RTL 各自按 bin 记 PT（写 PTAB 的块：基址、预测下一地址、方向掩码）和 UP（更新队列写预测表的项）的计数和哈希，指出第一个分歧的区间和事件（RTL 侧 `tb/soc/fpr.h`，模型侧 `front-end/BPU/fpr.h`）。这是 BPU 的"逐事件"检查，比周期更早发现差异。
- **Linux**：`scripts/linux_gate.sh`（整机，每区间 PMU 一级事件相同）、`scripts/linux_segments_cmp.sh`（检查点窗口，PT / UP 指纹相同）。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有 BPU 的模块级独立测试**。深度改写的等价性用的是"新旧模块随机并排"：`bpu_ub_track_ser` 3000 万拍（含 150 万 fall-through、1000 万预测 taken 实际 not taken、8200 万 taken 事件）、`bpu_updq` 2000 万拍（故意在满队列截断里种一个错，3.8M 拍时被抓到）、`bpu_ub_look` 3000 万个用例（种的两个错：平局规则 1.1M、边界比较 0.67M 时被抓到），`front_fetch_buf` 的起点扫描对每个有效前缀穷举；**这些测试台在草稿目录里，不在仓库里**。**待补**：把它们收进 `tb/`（`bpu_ub_track_ser`、`bpu_updq`、`bpu_ub_look` 各一个"新旧并排"随机测试），后续改深度时直接用；`bpu_spec` / `bpu_hist_vec`（对逐位推入函数的随机对拍，旧文档说做过）也要补回来。

## 9. 参数与开关速查

`bpu_stage_pkg`：`UB_WAYS`、`UB_SET_W`、`L1_WAYS`、`L1_SET_W`、`UB_TAG_W`、`HSYM_W`、`HR_BITS`、`NBB`、`UQ_DEPTH`、`UQ_PORTS`、`TQ_DEPTH`、`PQ_DEPTH`、`NITT`、`ITT_IDX_W`、`ITT_TBL`、`EPOCH_W`；`bpu_pkg`：`TP_*`、`TN`、`T_IDX_W`、`T_TAG_W`、`T_BASE_W`、`B_*`、`RAS_DEPTH`、`RASQ_N`；`ttg_cfg_pkg`：`FE_RFAST`、`FE_BFAST`、`RVC_ENABLE`、`FETCH_WIDTH`、`COMMIT_WIDTH`、`PTAB_SIZE`、`XLEN_BITS`。模型侧这些是固定设计（`BPU_pipe.h` 的 `constexpr`），没有运行期开关。

## 10. 变更记录

- 2026-11-17/18（exp/agu-share）：`7551dd0` 块跟踪器低深度重写；`47f4a7d` 更新队列压缩；`2c76ba2` uBTB 查表低深度；`4eb8f0e` 取指地址队列在 push 后一拍才弹出（与 BPU 末级覆盖解耦，见 front_fifos.md）。
- 2026-11-12：流水化 BPU（S0 / S1 / S2）合入 main（旧文档的说法），ITT 改为每 bank 3 张表 × 64 项（EXP-025）；检查点加宽到 158 位（`docs/analysis/bpu-pipe-rtl.md` 第 5 节，2026-11-15）。
- 更早：见 git 历史。
