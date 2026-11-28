---
module: rob
area: backend
rtl: rtl/backend/rob
model: trace-model back-end/Rob.cpp、back-end/include/Rob.h（调度单元 `back.rob`，类 `Rob`，阶段 `comb_commit`；`comb_redirect` 在 RTL 里不属于 ROB，见第 7 节）
status: 整核周期与模型逐个相等（`rtl/ren-ckpt-walk`：fm_gate 69/69 零偏差，剥离 `dest_preg`/`old_dest_preg`/`me_elim` 至 `ren_log`，新增 `ren2rob_walking` 暂停提交）
depth: 65 层 / 881,101 单元（rob，单模块综合，2026-11-23，`SYNTH_ABC="strash;balance;map"`，`ROB_NUM=256 / PRF_NUM=256`，较 897,972 单元降 −16,871 / −1.88%）
---

# rob 设计文档

> **2026-11-26 `rtl/area-opt` ROB 深度瘦身与时序/SRAM 优化**：
> - 删除 256 槽 64-bit `diag_val`、`mispred` 与 `src1_areg`/`imm`（改由 `ftq_commit_next_pc` 重建提交分支目标，压缩为 1-bit `is_ret`）；
> - 新增 8 组 `32×32b`（共 1 KiB）严格同步 1R1W SRAM（`ROB_INST_WORD`，随 `head_d` 预发起读，`WRITE_FIRST=1`），统一提供译码期 / `FS=Off` / 执行期非法指令（含浮点保留舍入模式）的 32-bit `mtval`；
> - `pf_load` / `pf_store` 异常虚地址追踪收敛为仅覆盖 7 个 LSU 访存口 + 当前寄存器的 3 级并行二叉树（`pick_older_trap`，替代原 29 级串行比较链）；
> - 中断拍（`rob_bcast_interrupt`）在 `core_back2front` 与 `trace-model` `Rob.cpp` 同步屏蔽未执行队头指令进入 BPU 训练。
>
> **EXP-053 P2-2 清理**：`rob_entry_t` 与 `dis2rob` 新增显式 1-bit `pf_inst_hi`；`rob_trap_ctrl` 计算取指缺页 `trap_val` 改为 `ftq_resp_pc + (pf_inst_hi ? 2 : 0)`，不再复用 `diag_val[1]`。

## 1. 职责

重排序缓冲（ROB）：按程序顺序保存所有已分派、尚未退休的指令，每拍做五件事：

1. 入队：分派来的指令（`dis2rob`，最多 8 条）依次放进尾部，`rob_idx` 是环上的位置；
2. 写回：EXU 的写回口（`exu2rob`，21 个口）把完成位、缺页 / 非法指令标志、分支结果、`diag_val`（访存地址或分支 pc 之类的诊断值）写进对应的槽；
3. 退休（commit）：从队头取"已全部完成的最长前缀"，每拍最多 8 条；冲刷类指令、fence、WFI 和被中断打断的那一条单独退休；
4. 分支误预测恢复：误预测的分支之后的槽全部作废，尾指针退回到该分支的下一条；
5. 全局冲刷：异常、xRET、CSR 写、sfence.vma、fence.i、访存顺序违例、中断由队头那条单独退休的指令触发，ROB 在同一拍清空自己，广播（`rob_bcast`）给其他模块。

现行的 ROB 是**紧凑 ROB**（`rob_core_cpt.sv`，EXP-028）：指令一条接一条占槽，不再每个分派组占一整行。模型里也只有这一种（`Rob.h` 的注释写明 compact）。原来的行式 ROB（一个分派组占一整行，`ROB_COMPACT = 0`）已在 2026-11-18 删除（见第 10 节）。

模型对应一个调度单元 `back.rob`（`Rob::comb_commit`）；另一个阶段 `comb_redirect`（前端重定向、向后端输出提交结果）在 RTL 里在 `back_top_glue`，不在 ROB 里。

## 2. 配置（`ttg_cfg_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| ROB 槽数 | 256 | `ROB_NUM` |
| 存储组织 | 8 个 bank × 32 行；`rob_idx` 的低 3 位是 bank，高 5 位是行 | `ROB_BANK_NUM = 8`、`ROB_LINE_NUM = 32`、`ROB_IDX_WIDTH = 8` |
| 入队宽度 | 8 | `DECODE_WIDTH` |
| 退休宽度 | 8 | `COMMIT_WIDTH` |
| 写回口 | 21（通道 0..20） | `ROB_WB_WIDTH` |
| 完成组 | 3 位，一个组一位：G0 = 整数 / load / FP，G1 = 分支 / STA，G2 = STD | `rob_pkg::CPLT_G0/1/2`、`CPLT_W = 3` |
| 数据宽度 | 64 | `XLEN_BITS`（`ROB_XLEN`） |

写回通道到完成组的映射（`rob_pkg::rob_port_cplt_bit`，用 `ROB_WB_*_BASE`）：通道 0..5（ALU）和 6..9（load）、18..20（FP）→ G0；通道 10..12（STA）和 16、17（BR）→ G1；通道 13..15（STD）→ G2。ISU/EXU 发射侧共有 5 个物理 AGU 口（`ISSUE_WIDTH = 19`），但 LSU 写回侧仍保持 4 load + 3 STA 共 7 个独立完成通道，所以 `ROB_WB_WIDTH = 21`。

一条指令要等哪几个完成组由分派算出（`dis2rob_uop_expect_mask`，见 dispatch.md）；槽里存的是"还没完成的组"`pend_mask = expect & ~已完成`，`pend_mask == 0` 就是完成。

## 3. 接口

信号组按模型的 `in` / `out` 命名；顶层 `rob.sv` 只做平铺端口和结构体的互转。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dec_bcast_mispred`、`dec_bcast_redirect_rob_idx`、`flush_pend` | 分支误预测和被预测错的分支的 `rob_idx`；`flush_pend` 是上一拍的全局冲刷（`FLUSH_REG`），它为 1 的那一拍屏蔽陈旧的误预测恢复（`dec_mispred_eff = mispred & !flush_pend`） |
| 入 | `csr2rob_interrupt_req`、`csr2rob_fs_off` | 中断请求；mstatus.FS 是否为 Off（F/D） |
| 入 | `lsu2rob_committed_store_pending` | 已提交但没写出去的 store 还有（fence 要等它清空） |
| 入 | `front_stall`、`bpu_upd_free[3:0]`、`bpu_tq_free[3:0]` | 退休信用：BPU 更新队列和 uBTB 训练队列的空闲项（寄存值），见 5.2 |
| 入 | `ftq_rob_pc_resp_resp_pc` | 队头指令的 pc（FTQ 读口，1 个） |
| 入 | `dis2rob_dis_fire[8]`、`dis2rob_uop_*[8]` | 分派的指令（23 个字段，含 `rob_idx`、`expect_mask`） |
| 入 | `exu2rob_entry_*[ROB_WB_WIDTH]` | 写回（21 通道）：`valid`、`rob_idx`、`diag_val`、`result`、`mispred`、`br_taken`、缺页标志、`rob_defer`、`flush_pipe`、`illegal`、`fflags`、`op` |
| 出 | `rob2dis_{stall, empty, ready, enq_idx, free, rob_flag}` | 给分派：队头 8 个槽里有冲刷类指令（`stall`）、空、不满、尾部位置、空闲项数、尾部的环绕标志 |
| 出 | `rob2csr_{commit, fflags, fs_dirty, interrupt_resp}` | CSR 指令退休、本拍正常退休指令的浮点异常标志累加、FS 变脏、中断被接受 |
| 出 | `rob_commit_commit_entry_*[8]`、`commit_extra_{src1_areg, imm}[8]` | 本拍退休的指令（槽 k 是第 k 老的），`commit_extra` 给前端 BPU 训练 |
| 出 | `rob_bcast_*` | 冲刷和原因（flush、mret、sret、ecall、breakpoint、exception、fence、fence_i、三种缺页、illegal、interrupt）、`trap_val`、`pc`、队头的 `rob_idx` 与最老未完成项的 `rob_idx` |
| 出 | `ftq_rob_pc_req_*` | 向 FTQ 要队头指令的 pc |

`rob_bcast_flush` 是 ROB 这一拍自己的决定；其他模块拿到的是 `back_top` 里寄存一拍之后的 `rob_flush_q`（docs/FLUSH_REG.md）。限定"本拍提交"的信号（`rob_bcast_interrupt`）不晚一拍。

## 4. 结构

```
 dis2rob ─► bank_we / bank_line（按 rob_idx 低 3 位分到 bank）─► rob_entry[bank][line]（8 × 16 个槽）
 exu2rob ─► rob_wb_decode（每口一个事件 rob_event_t）─► 每个 rob_entry 比较 rob_idx，按口序应用
 rob_entry 读出：每个 bank 用一热的 head_oh_q / use_next_q 从 16 行里选一行 ─► 再按 hb_oh_q 旋转成"窗口槽 0..7"（第 k 老）
 窗口 ─► ok[k]（完成、非冲刷类、信用够）─► prefix（热码）─► commit_valid
        └► rob_trap_ctrl（队头单独退休时：原因优先级、trap_val、flush）
 rob_core_cpt : head_q / hflag_q / count_q、prev_ctl_q / prev_blk_q；次态 = flush > 误预测恢复 > 退休 + 入队
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `rob.sv` | 203 | 顶层：平铺端口 <-> 结构体，实例化 `rob_core_cpt`；F/D 的 fflags / fs_dirty 累加 |
| `rob_core_cpt.sv` | 473 | 紧凑 ROB 的核心：窗口读出、退休判决、入队、误预测恢复、指针次态；8 个 bank 的指令字 SRAM（`ROB_INST_WORD`，给非法指令的 `mtval`） |
| `rob_entry.sv` | 62 | 一个槽（valid + `rob_entry_t`）的次态：写回、标记最后一条、入队、清除 |
| `rob_wb_decode.sv` | 20 | 每个写回口翻成事件 `rob_event_t`（写哪个字段、置哪个完成位） |
| `rob_trap_ctrl.sv` | 89 | 队头单独退休时的冲刷、异常原因（12 个候选里取最先的）、`trap_val`、`pc` |
| `pkg/rob_pkg.sv` | 212 | 槽结构 `rob_entry_t`、写回结构、指令分类函数、完成组、事件应用函数 |

紧凑核的几点：

- **窗口**：最老的 8 条（`count_q` 条里的前 8 个）组成提交窗口。第 b 个 bank 存的是窗口槽 `(b - head) mod 8`，在队头所在行或下一行，所以先用 `head_oh_q`（队头所在行的一热）/ `use_next_q`（该 bank 读下一行）从 16 行里选，再用 `hb_oh_q`（队头所在 bank 的一热）旋转成"第 k 老"的顺序。这三个一热量是寄存的，随 `head_d` 同拍更新，下一拍直接用，不再对 `head_q` 译码。
- **退休判决**（5.2）：队头是冲刷类（`rob_is_flush_inst`）、fence、WFI，或者有中断，就只退这一条；否则取窗口里"完成、不是上述三类、信用够"的最长前缀。
- **入队**：分派已经把 `rob_idx` 编成 `尾 + 有效项的序号`；第 b 个 bank 接收 `rob_idx[2:0] == b` 的那条（8 个连续位置里每个 bank 至多一条）。
- **误预测恢复**：`keep = 被预测错的分支相对队头的偏移 + 1`；偏移大于这个的槽 `valid` 清零，分支那一条的 `ftq_is_last` 置 1（同一取指块里它后面的指令都已作废）；`count` 变成 `keep`。

状态：`head_q`（`ROB_IDX_WIDTH = 8` 位）、`hflag_q`（队头环绕标志）、`count_q`（9 位，0..`ROB_NUM` = 256）、`prev_ctl_q` / `prev_blk_q`（上一拍退休的控制流指令数 / 取指块尾数，各 4 位）、三个寄存的一热视图；槽存储 `ROB_NUM = 256` 个，每槽 `1 + ROB_ENTRY_W` 位（`rob_entry_t` 的各字段见 `rob_pkg.sv`）。槽的 `valid` 有复位，其余内容复位为 0。指令字 SRAM（`ttg_sram_1r1w`，8 个 bank × `ROB_LINE_NUM = 32` 行 × 32 位）在复位期间由 SRAM 外壳逐地址写 `INIT_VAL` 清零（见 common.md 4.1）。

## 5. 一拍内的数据流

### 5.1 写回（`rob_entry`，所有槽并行）

每个槽拿 21 个写回口的事件逐个比较 `rob_idx == 本槽编号`，命中则按口序（0 到 20）依次应用，后面的口覆盖前面的（对应模型 `for i < ISSUE_WIDTH`）：

- 完成位：`pend_mask &= ~cplt_bit`；`rob_defer` 的写回（LSU 推测 load 的第一次写回）不改任何内容，完成位由第二次写回置；
- 访存口（load 口和 STA 口）：`diag_val` 写成地址；有缺页则 `diag_val` 改成 `result`（缺页时 `result` 里放的是 tval），并累计 `pf_load` / `pf_store`；STA 口缺页而槽里已有 `pf_store` 时撤销 `pf_load`（AMO）；
- 分支（`op` 是 JUMP 或 BR）：写 `mispred`、`br_taken`、`diag_val`；
- 其他标志只累积：`flush_pipe`（访存顺序违例，退休时冲刷更年轻的）、`illegal_inst`（含 F/D：写回时 mstatus.FS 为 Off 而这条指令需要 FP）、`fflags`。

`valid` 的次态按"退休清除 → 分支清除 → 入队置位 → 冲刷清除"，后者覆盖前者（`rob_entry` 里的写法）。

### 5.2 退休（`rob_core_cpt`，只读寄存器）

1. 窗口槽 k 的"在窗口内" `w_in[k] = count_q > k`；`w_complete`、`w_flush`、`w_fence`、`w_wfi` 由 `rob_pkg` 的分类函数得到。
2. 单独退休：`h_alone = 队头是冲刷类 | fence | WFI`；`interrupt_fire = !误预测 & 非空 & 有中断请求`；`single_commit = 中断 | (!误预测 & 非空 & 无中断 & h_alone & 队头已完成 & !(fence 且还有已提交 store 未写出))`。
3. 成组退休：`ok[k] = w_in & w_complete & 非冲刷类 & 非 fence & 非 WFI & !(front_stall 且 k > 0)`；对 k > 0，如果它是控制流指令（BR / JAL / JALR），且比它老的控制流条数 ≥ `upd_free`，则 `ok[k] = 0`；如果它是取指块的最后一条（`ftq_is_last`），且比它老的块尾条数 ≥ `tq_free`，也为 0。其中 `upd_free = bpu_upd_free - prev_ctl_q`、`tq_free = bpu_tq_free - prev_blk_q`（BPU 队列的寄存占用，减去上一拍退休、这拍才到队列的条数），每个槽自己并行数"比我老的有几条"，不串行累加。最老的一条不受信用限制（保证前进）。`prefix[k]` = `ok[0..k]` 全 1，`commit_valid = single_commit ? 只有槽 0 : (group_go ? prefix : 0)`。
4. 冲刷：`rob_trap_ctrl` 在 `single_commit` 时判断队头是否冲刷类（含中断），在 12 个候选原因（中断、ecall、mret、sret、store 缺页、load 缺页、取指缺页、非法指令、CSR、sfence、fence.i、断点）里取优先级最高的一个，产生 `flush`、`exception`、各原因位、`trap_val`（取指缺页用 `ftq_resp_pc + (pf_inst_hi ? 2 : 0)` 以正确上报 RVC 跨 4KB 页 32 位指令第二半字的缺页 `stval`，断点用队头 pc，其余用 `diag_val`）、`rob2csr_commit`（CSR 指令）。
5. 其他输出：`rob2dis_stall = 窗口里有冲刷类`；`bcast_head_incomplete_*` = 窗口里最老的未完成项；`ftq_req` 用槽 0 的 `ftq_idx / ftq_offset`。

### 5.3 次态

优先级：冲刷 > 误预测恢复 > 退休 + 入队。`commit_valid` 是热码（前缀），所以退休条数用"一热的 n"从 `head + j`、`count - j`（j = 0..8，由寄存值预先算好）里选，不做加法；`count_d = (恢复 ? keep : count - n) + m_fire`，`m_fire` 是本拍入队条数（`dis_fire & rob2dis_ready`）。冲刷时 `head`、`count`、环绕标志清零。

`rob2dis_enq_idx = (head + count) 的低 ROB_IDX_WIDTH = 8 位`，`rob2dis_free = ROB_NUM - count`，用的都是寄存值：这一拍退休腾出的槽下一拍才能分配。

## 6. 关键路径与深度

协调者给出的单模块综合数：`rob` **62 层**（通用门代理；本文作者未复测，也不知道最长路径的逐段分布：**待测**，由协调者补）。

从代码读出的长组合链（未综合验证）：

| 链 | 经过 |
| --- | --- |
| 退休判决 | 寄存的一热视图 → 每 bank 16 选 1 → 旋转 8 选 1 → 取出的槽译码（`itype` 比较、`pend_mask == 0`）→ `ok[k]`（含"比我老的控制流条数"与 `upd_free` 的比较）→ `prefix` 与链 → `commit_valid` |
| 退休之后 | `commit_valid` → ① `bank_clr` → 各槽 `valid_d`；② 一热 n → `head_d` / `count_d` → 下一拍的三个一热视图；③ `ctl_c / blk_c` → `prev_ctl_q` |
| 冲刷 | 窗口槽 0 的分类 → `single_commit` → `rob_trap_ctrl` 的优先级选择 → `flush_w` → 清所有槽的 `valid`、`head`、`count`，同时出 `rob_bcast_flush`（docs/FLUSH_REG.md 记录过这条是整核最长路径之一，约 29 层，该数是 FLUSH_REG 时的整核测量，不是本模块的） |
| 写回 | 21 个口的 `rob_idx` 与槽号比较 → 按口序应用（`rob_apply_event` 逐口覆盖）→ `uop_d`；每个槽都有一份 |
| 最老未完成项 | 窗口 8 槽上一条 `found` 优先链 → `head_q + k` |

已经做过的降深度改动：退休信用的"比我老的几条"并行计数（不串行）；`commit_valid` 热码 → 退休条数一热选择；队头的三个一热视图寄存；`FLUSH_REG` 让其他模块晚一拍看到冲刷（见变更记录）。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `dbg` 调试元数据、`ROBTR` 调试输出、`Assert` 检查（完成位重复、溢出、`rob_idx` 编号不一致等）、`stall_cycle` 的死锁看门狗、`is_mmio`、PMU 取最老未完成项（`pmu_head_incomplete`）、`tma.*` 归因；
- `Rob::comb_redirect`（前端重定向 pc、`pend_` 寄存、`report_commit`）：在 `back_top_glue`；
- `rob_bcast_d`（模型里为 `FLUSH_REG` 另备的一份延迟广播）：RTL 里由 `back_top` 的 `rob_flush_q` 等寄存器承担，ROB 自己只输出这一拍的决定。

RTL 里有、模型里没有的（模型从 trace / 函数模型取得这些，RTL 得自己算）：

- F/D 的 FS 状态：`fs_need`（分派给出，浮点指令 / 浮点访存 / fflags、frm、fcsr 的 CSR）和写回时的 `fs_off` 合成 `illegal_inst`；本拍正常退休指令的 `fflags` 累加和 `fs_dirty`（`rob.sv` 末尾）。模型的 `Rob.cpp` 里只有 `tbhook::fs_dirty_at_commit`（来自函数模型的事实）。

已发现、未改动的点：

- `rob.sv` 把写回的 `pf_inst` 固定为 0（"后端没有写它的口，取指缺页来自前端"），`rob_make_event` 里 `ev.pf_inst` 因此恒为 0，是死路径；模型 `Rob::complete` 里还有 `page_fault_inst |= wb.page_fault_inst`；
- `rob_pkg` 里 `UOP_TYPE_COUNT = 17` 的注释写着"F/D 还不在 RTL 里"，已过时（`dis_pkg` 的 `uop_op_e` 有 21 个值，宽度同为 5 位）；
- `rob.sv` 的端口注释、`rob_trap_ctrl` 的 `single_uop` 注释还写"head line"，是已删除的行式 ROB 的说法；

与模型保持一致的细节（读模型时容易误判）：

- 退休信用用的是寄存值减上一拍退休数，不是组合地看 BPU 队列；
- 队头为 fence 时要等已提交 store 写完（`committed_store_pending`）才退休；
- 带中断退休的指令也出现在 `rob_commit` 里，但 `rob_bcast_interrupt` 为 1，rename 据此不把它提交进架构映射；
- `FLUSH_REG` 下，冲刷挂起的那一拍 ROB 已空，陈旧的误预测不能再去恢复（`flush_pend`）。

**未核对（继承自旧文档）**：无（旧文档的内容全部没有采用）。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`lint_chip` & `lint_soc` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 全通；Linux 26/26 窗对齐。
- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）：77/77 通过（最近一次 rtl 73761fa，2026-11-28），周期逐个相等。测试台从 `u_rob` 的提交端口取提交（`tb/soc/soc_tb.cpp` 里读 `u_rob` 的 `rob_commit_*`）。
- **PMU**：`scripts/pmu_parity.sh` 比较 RTL 与模型的一级事件总数（含 `COMMIT_*`、`CYC_COMMIT_*`、`BR_MISPRED`、`FLUSH_*`），与 ROB 的提交行为直接相关。
- **SVA 断言与覆盖（`SOC_SVA=1`）**：`sva/sva_rob.sv` 通过 `bind` 挂载至 `rob_core_cpt`（零综合污染），检查 `count_q <= ROB_NUM`、`rob2dis_empty`/`rob2dis_free` 一致性、`head_oh_q`/`hb_oh_q` one-hot、`commit_valid` 连续前缀、flush/异常/中断单发射约束，并带 5 个功能 cover（ROB 满、8 宽提交、flush、mispred、异步中断）。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧体系的 trace 回放和变异检查已随 `spec/` 退役，目前 ROB 靠整核逐拍周期相等和 Linux 启动保证。**待补**：（1）给紧凑核的退休判决（信用、前缀、单独退休）补一个新旧并排的随机测试，改深度时用；（2）行式 ROB 要么删除，要么补一次门禁。

## 9. 参数与开关速查

`ROB_NUM`、`ROB_BANK_NUM`、`ROB_LINE_NUM`、`COMMIT_WIDTH`、`DECODE_WIDTH`、`ROB_WB_WIDTH`、`ROB_WB_*_BASE`（写回通道到完成组）、`rob_pkg::EBREAK_TRAP`（默认 1，将 `ebreak` 变为断点异常；仅在定义 `-DTTG_NO_EBREAK_TRAP` 时回退为旧的仅冲刷行为）。

## 10. 变更记录

- 2026-11-28（rtl 73761fa，SRAM 复位清扫）：`rob_core_cpt` 的 8 个 `ROB_INST_WORD` 指令字 SRAM 实例接上 `rst_n`；复位期间 `ttg_sram_1r1w` 逐地址写 `INIT_VAL`，`ttg_rst_sweep` 把复位拉长 `SRAM_SWEEP_CYCLES = 4100` 拍，不再依赖上电值（common.md 4.1）；0 周期变化，`fm_gate` 77/77。同日文档核对：`ROB_NUM = 256` 下的指针 / 计数位宽、文件行数、门禁参考改为 `scripts/ref_cycles.txt`。
- 2026-11-28（`rtl/exu-clean`，EXP-072）：同步真 5 物理 AGU / 5 写回通道映射（`rob_pkg`、`rob.sv`、`rob_core_cpt.sv`、`rob_entry.sv`、`rob_wb_decode.sv`）；TSMC 28nm HPC+ DC `rob_bb`（`0.50 ns`）：`WNS −0.16 ns`（vs 旧 `−0.15`）、逻辑级数 **`42 → 34`（−19.0%）**、**`TNS −452 → −239.47`（−47.0%）**、面积 `121,413.43 → 123,159.29 µm²`（`+1.44%`）；通过 `lint` 0、strict+SVA `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 与 Linux 26/26 窗对齐。

- 2026-11-17/18（exp/agu-share）：`803692f` FLUSH_REG：ROB 在决定冲刷的那一拍清空自己，不等其他模块；新增输入 `flush_pend` 屏蔽陈旧的误预测恢复；限定本拍提交的信号（中断）不晚一拍。
- 更早（`git log -- rtl/backend/rob`）：`4e954d7`（2026-11-11）紧凑 ROB（EXP-028，当时默认 `ROB_COMPACT = 0`，现为 1）；`a2657ea`（2026-11-12）`ROB_XLEN`；`a946972`、`3791f11`（2026-11-12）F/D（FP 写回口、fflags、FS 脏、FS = Off 非法）。
- 2026-11-26（`rtl/area-opt`）：ROB 彻底瘦身——引入单个 73-bit 统一 `oldest_trap` 寄存器（覆盖 `pf_load`/`pf_store` 缺页虚址与译码期/`FS=Off` 非法指令字），删除 `rob_entry_t` 中的 `diag_val[63:0]`、`imm[31:0]`、`src1_areg[5:0]`、`func7[6:0]`、`rob_idx[7:0]`、`mispred` 并以 1-bit `is_ret` 与 1-bit `is_amo_lr` 替代，每项位宽由 166 bit 压至 **50 bit（−69.9%）**；分支目标改由 FTQ `ftq_commit_info_resp_next_pc` 在 `back_top_glue` 重建；`commit_extra_imm`/`commit_extra_src1_areg` 简化为 `commit_extra_is_ret`；零周期变化。
- 2026-11-18：删除行式 ROB：`rob_core`、`rob_ptr`、`rob_commit_ctrl`、`rob_head_info`、`rob_head_class`、`rob_store`、`rob_branch_recovery`（7 个文件，688 行）、`rob.sv` 里 `ROB_COMPACT` 选核的分支、分派里 `ROB_COMPACT == 0` 的分支（`dispatch_core`、`dispatch_fire_ctl`）、`ROB_COMPACT` 常量。整核周期不变（见提交说明）。
