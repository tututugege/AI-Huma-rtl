---
module: ren
area: backend
rtl: rtl/backend/ren
model: trace-model back-end/Ren.cpp、back-end/include/Ren.h（调度单元 `back.rename`，类 `Ren`，阶段 `comb_rename`、`comb_fire`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 111 层（ren，单模块综合，2026-11-20，`SYNTH_ABC="strash;balance;map"`，生成门代理，见 09-synthesis-report 第 12 节）
---

# ren 设计文档

## 1. 职责

重命名（rename）：把译码出来的指令里的架构寄存器号换成物理寄存器号，并维护恢复所需的全部状态。分两个寄存器域，整数（x0..x31 加一个 AMO 暂存寄存器）和浮点（f0..f31，F/D），每个域各有：推测 RAT（寄存器别名表，当前最新映射）、架构 RAT（已提交的映射）、空闲表、每个分支标签一份的恢复点。每拍：

1. 从空闲表给需要目的寄存器的指令分配物理寄存器（按序，不够就卡住自己和更年轻的指令）；
2. 查源寄存器和旧目的寄存器的映射；同一组里比自己老的指令写了同一个架构寄存器，就取那条指令的新目的寄存器（最近的老写者优先）；
3. 移动消除（move elimination）：`addi rd, rs, 0` 这类 move 不分配新寄存器，目的寄存器直接等于源寄存器，指令在 ROB 里分派时就算完成（`me_elim`，不再有 uop）；
4. 分派握手：发给分派的那些 lane 被接收（`fire`）后，才推进 RAT 和空闲表，并在每个分支处记下恢复点；
5. 退休（commit）：ROB 退休的指令更新架构 RAT，并把旧目的寄存器还给空闲表（带移动消除时，要等没有任何架构寄存器再引用它）；
6. 恢复：全局冲刷时回到架构 RAT 和已提交的空闲表头；分支误预测时回到该分支的恢复点。

模型对应一个调度单元 `back.rename`（`Ren::comb_rename`：分配和重命名；`Ren::comb_fire`：握手）。RTL 的子模块边界是为综合划的，模型里没有对应的类。

## 2. 配置（`ttg_cfg_pkg` / `ren_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| lane 数 | 8 | `DECODE_WIDTH` |
| 退休宽度 | 8 | `COMMIT_WIDTH` |
| 整数架构寄存器 | 32 个，外加 1 个 AMO 暂存（RAT 共 33 项） | `ARF_NUM = 32`，`ren_pkg::RAT_NUM = ARF_NUM + 1` |
| 整数物理寄存器 | 128（标号 0..127；初始空闲 128 - 33 = 95 个） | `PRF_NUM = 128` |
| 浮点架构 / 物理寄存器 | 32 / 96（标号从 128 起；初始空闲 96 - 32 = 64 个） | `FP_ARF_NUM = 32`、`FPRF_NUM = 96`、`FP_TAG_BASE = 128` |
| 分支标签 | 32 个（标签 0 表示"不是分支"，不使用），每个标签一份恢复点 | `MAX_BR_NUM = 32`、`BR_TAG_WIDTH = 5` |
| 移动消除 | 开；每个物理寄存器被架构 RAT 引用的次数上限 7 | `MOVE_ELIM = 1`、`MOVE_ELIM_MAX_REFS = 7`，计数宽度 `ren_pkg::CNT_W = 3` |

AMO 暂存寄存器：IDU 把"丢弃结果的读改写 AMO"的目的寄存器号改成 32（`idu_ctrl_decode.sv` 输出段，对应模型 `Idu::decode` 末尾），所以 RAT 要多一项。

## 3. 接口

信号组按模型的 `in` / `out` 命名；顶层 `ren.sv` 只做平铺端口和结构体的互转（`ren_core` 是真正的实现）。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dec2ren_valid[8]`、`dec2ren_uop_*[8]` | 译码后的指令（`ren_pkg::ren_inst_t`：架构寄存器号、`br_id`、`br_mask`、FP 域标志…） |
| 入 | `dec_bcast_{mispred, br_id, clear_mask}` | 分支误预测、被预测错的分支标签、已解决分支的掩码 |
| 入 | `dis2ren_ready` | 分派接受这一组 |
| 入 | `rob_bcast_flush`、`rob_bcast_interrupt` | 全局冲刷（`FLUSH_REG` 后晚一拍，docs/FLUSH_REG.md）；带中断退休的指令不提交映射 |
| 入 | `rob_commit_commit_entry_*[8]` | 退休的指令：`dest_en`、`dest_areg`、`dest_preg`、`old_dest_preg`、`me_elim`、`dest_fp`、异常标志、类型 |
| 出 | `ren2dec_ready` | 这一组被接收（空）或还有 lane 没发出 |
| 出 | `ren2dis_valid[8]`、`ren2dis_uop_*[8]` | 重命名后的指令（`dest_preg`、`src1/2/3_preg`、`old_dest_preg`、`me_elim`…）；`src1_areg` 要继续带，ROB 经退休端口交给前端 BPU |

`is_rvc` 和 `mdp` 不经过 IDU 和 ren，见 dispatch.md / pre_idu_queue.md。

## 4. 结构

```
 dec2ren ─► ren_inst_pipe（8 lane 输入寄存器）─► inst[8]
   ├ ren_elim_sel   : 哪些 move 被消除
   ├ ren_alloc_sel  : 窗口（空闲表头起 8 项）按序分给要寄存器的 lane
   ├ ren_rat        : 推测 RAT 读（8 lane × 3 个读口）、每 lane 之后的快照、架构 RAT
   ├ ren_dep_check  : 同组 RAW / WAW 旁路（最近的老写者优先）
   ├ ren_fp         : 浮点域（RAT + 空闲表 + 恢复点 + 组内旁路），ren_core 只留握手
   ├ ren_handshake  : 第一个要寄存器却拿不到的 lane 起，之后全部卡住；fire、ren2dec.ready
   ├ ren_commit_filter / ren_rank / ren_arch_cnt / ren_free_list : 退休侧
   └ ren_ckpt       : 每个分支标签一份（RAT 快照 + 空闲表头）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ren_pkg.sv` | 174 | 结构体、move 形状判断 `ren_is_move_shape`、复位值函数 |
| `ren.sv` | 194 | 顶层：端口适配 |
| `ren_core.sv` | 248 | 连接各子块；整数域的握手与输出拼装 |
| `ren_inst_pipe.sv` | 53 | 输入寄存器 |
| `ren_alloc_sel.sv` | 45 | 分配：8 个"取最先请求者"串起来，第 k 个请求者拿窗口第 k 项（整数域和浮点域共用） |
| `ren_handshake.sv` | 42 | 按序卡住与 fire |
| `ren_rat.sv` | 113 | 推测 / 架构 RAT；每个 lane 之后的快照 |
| `ren_dep_check.sv` | 74 | 整数域的同组旁路 |
| `ren_elim_sel.sv` | 58 | 移动消除的判定 |
| `ren_arch_cnt.sv` | 73 | 每个整数物理寄存器的"被架构 RAT 引用次数" |
| `ren_commit_filter.sv` | 38 | 哪些退休项算"退休一个目的寄存器" |
| `ren_rank.sv` | 27 | 选中的退休槽的序号和总数（空闲表写偏移） |
| `ren_free_list.sv` | 105 | 整数空闲表（环，3 个指针） |
| `ren_ckpt.sv` | 59 | 分支恢复点表 |
| `ren_last_write.sv` | 31 | "同一拍多个写者，编号大的赢"的优先选择，多处复用 |
| `ren_fp.sv`、`ren_fp_dep.sv`、`ren_fp_free_list.sv` | 135、42、89 | 浮点域 |

状态（整数域）：输入寄存器（8 lane）；推测 RAT 和架构 RAT（各 `RAT_NUM` 项 × 8 位）；空闲表 `list_q[PRF_NUM]` 和三个指针 `head`（推测分配）、`head_commit`（最老未提交的分配）、`tail`（还回来的旧寄存器追加处）；`arch_cnt` 128 个计数器（复位时前 33 个为 1）；恢复点表 `entry_q[MAX_BR_NUM]`，每项一份 RAT 快照加一个空闲表头。浮点域同样一套（RAT 32 项，环 `FPRF_NUM` 个，不是 2 的幂，指针按 `fp_ptr_add` 显式回绕；没有移动消除，没有计数器）。

## 5. 一拍内的数据流

### 5.1 重命名（只读寄存器）

1. **移动消除**（`ren_elim_sel`，对应模型 `elim_refs_ok`）：move 形状（`addi rd, rs, 0`，rd、rs 都不是 x0）且：本组里比自己老的有效指令没有写它的源架构寄存器（旁路命中则不消除），且 `推测 RAT 中等于它源物理寄存器的项数 + 本组里比自己老且有目的寄存器的指令数 + 1 <= MOVE_ELIM_MAX_REFS`。老的写者每个至多多一个引用，所以不必看它们写什么。
2. **分配**（`ren_alloc_sel`）：要整数寄存器的 lane（有效、有目的寄存器、不是浮点、没被消除）按序排队；第 k 个请求者拿窗口第 k 项，且要 `k < free_count` 才算拿到。浮点域同样（`ren_fp` 里再用一份 `ren_alloc_sel`）。
3. **按序卡住**（`ren_handshake`）：整数域和浮点域的请求合在一起，第一个请求却没拿到的 lane 起（含它）全部 `ren2dis_valid = 0`；没有目的寄存器的指令只受这个卡住的影响。
4. **查表和旁路**：每个 lane 查 3 个读口（目的、src1、src2）；`ren_dep_check` 对比自己老的有效、有目的寄存器的 lane，同一个架构寄存器号就换成那个 lane 的目的物理寄存器（新分配的，被消除的 move 则是它旁路后的源），最近的老写者赢；x0 不会被写（译码器不给 x0 置 `dest_en`）。浮点域有 4 个读口（src1、src2、src3、旧目的），旁路在 `ren_fp_dep`，f0 是真寄存器。
5. 被消除的 move：`dest_preg = src1_preg`（旁路后的），不占空闲表。

### 5.2 握手与推进（寄存器次态）

- `fire[i] = ren2dis_valid[i] & dis2ren_ready`；`ren2dec_ready = 所有有效 lane 都 fire & !冲刷 & !误预测`。
- fire 的指令：推测 RAT 写目的寄存器（同一拍多个写者，最年轻的赢）；空闲表头 `head` 前进已分配的个数（`ttg_popcount`）；fire 的分支（`BR` 或 `JALR`；JAL 不占标签）把"本指令重命名之后"的 RAT 快照和空闲表头写进它的标签（`ren_rat` 的 `snapshot[i]` 是 lane 0..i 全部写完后的 RAT）。
- 输入寄存器：冲刷或误预测清空；`ren2dec_ready` 时换成译码的新组；否则保留没 fire 的 lane。每拍从所有 lane 的 `br_mask` 去掉 `clear_mask`。

### 5.3 退休（commit）

- `ren_commit_filter`：一个退休槽"退休一个目的寄存器"，当且仅当：有效、`dest_en`、没有异常（缺页、非法指令、ecall）、本拍没有中断（`rob_interrupt`）。这样的槽才更新架构 RAT 和还旧寄存器。出了异常或被中断带走的指令就像没提交过。
- 整数域：`arch_cnt[dest_preg]++`，`arch_cnt[old_dest_preg]--`；某个槽的 `old_dest_preg` 在"这个槽及前面所有槽处理完"之后计数为 0，就把它还回空闲表（`ren_arch_cnt`：每个槽并行数前面的增减，不串行）。还回的位置是 `tail + 本槽在"要还的槽"里的序号`（`ren_rank`）。`head_commit` 前进"退休且真的分配过寄存器的槽数"（被消除的 move 没分配，不算）。
- 浮点域：没有移动消除，每个退休的浮点目的寄存器直接还旧寄存器，`ren_fp_free_list` 同理。

### 5.4 恢复

优先级：全局冲刷 > 误预测 > 正常。

- 冲刷：推测 RAT := 架构 RAT（含这一拍的退休写入）；`head := head_commit`（含这一拍的前进）；输入寄存器清空。
- 误预测：推测 RAT := 被预测错的分支标签的恢复点（读的是旧值）；`head := 该标签记下的空闲表头`；`tail` 不回滚，正常追加（模型里是"回滚到本拍寄存器的 tail，丢掉本拍的还寄存器"；同拍既退休又误预测是不可达状态，模型对此有断言，RTL 不复刻）。

## 6. 关键路径与深度

单模块综合深度 **110 层**（ren；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_core.u_pipe.inst_q [771]` 到 `\u_core.g_fp.u_fp.u_ckpt.entry_q [8182]`。

从代码读出的长组合链（未综合验证）：

| 链 | 经过 |
| --- | --- |
| 分配 | `ren_alloc_sel` 的 8 级"取最先请求者"串联（`remain[k+1] = remain[k] & ~grant[k]`）→ 窗口选择 → `alloc_reg` → `ren_dep_check` 的最近老写者选择 → `ren2dis_uop`（再进分派的 busy 和 fire） |
| 握手 | `alloc_valid` → `ren_handshake` 的第一个失败者 → `ren2dis_valid` → `fire`（`& dis2ren_ready`）→ `ren2dec_ready`（再进 IDU 的 fire，见 idu.md）→ 推进的 RAT / 空闲表 / 快照 |
| 移动消除 | 推测 RAT 读 → 33 项和 src1 比较 → popcount → 加法和比较 → `elim`（再进分配请求，所以是分配链的前缀） |
| 退休 | 8 个退休槽两两比较物理寄存器号 → popcount 加减 → `arch_cnt` 查表 → `free` → `ren_rank` → 空闲表每项的"写位置比较" → `list_d` |
| 快照 | 每个 lane、每个 RAT 项上，lane 0..i 的最后写者选择 → 恢复点表（8 个 lane 同拍写同一标签时编号大的赢） |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `Assert`（空闲表空时分配、`br_id` 越界、同拍退休和误预测、FP 空闲表守恒 `fp_freelist_sanity`）、PMU（`g_pmu_back.ren_no_preg`）、污点表 `msd::taint` 的清除（trace 模型专用）、`dbg`；
- 误预测时 `tail` 的回滚（见 5.4）。

RTL 与模型的实现差别（行为等价）：

- 模型对每个 lane 顺序执行；RTL 把"同一拍多个写者，编号大的赢"写成 `ren_last_write` 的优先选择，把"空闲表前 k 项给第 k 个请求者"写成 `ren_alloc_sel` 的串联取最先；
- 空闲表指针：整数域环大小 `PRF_NUM` 是 2 的幂，指针按位宽自然回绕；浮点域 `FPRF_NUM = 96` 不是，要显式回绕。标签是 8 位（FP 从 128 起），环位置是 7 位（`ren_free_list` 的 `PW`）；
- `ren_ckpt` 的恢复点表对 `MAX_BR_NUM = 32` 个标签都有存储，标签 0 从不被写（IDU 不给分支分配标签 0）。

已发现、未改动的点：

- `ren.sv`、`ren_pkg.sv` 文件头注释里的"reference model commit 2f31e8d"已过时；
- `ren_pkg` 的 `ITYPE_ADD` 等常量和 `ren_is_move_shape` 里的指令类型编号手写了一份（与 `dis_pkg`、`rob_pkg`、`idu_ctrl_decode` 各有一份 `InstType` 编码），没有共用；

**未核对（继承自旧文档）**：无（旧文档的内容全部没有采用）。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）：67/67 通过，周期逐个相等。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**。旧体系（`spec/` 的 trace 回放、随机 trace、变异检查）已退役；`tests/` 里没有针对 ren 的测试。目前正确性靠整核周期逐拍相等和 Linux 启动。**待补**：给移动消除的判定、空闲表和 `arch_cnt` 的释放逻辑补新旧并排的随机测试，改深度时用；最好有一个覆盖"同拍退休、冲刷、误预测"的专门用例（模型里这是断言，RTL 里没有）。

## 9. 参数与开关速查

`DECODE_WIDTH`、`COMMIT_WIDTH`、`ARF_NUM`、`PRF_NUM`、`FPRF_NUM`、`FP_ARF_NUM`、`FP_TAG_BASE`、`MAX_BR_NUM`、`MOVE_ELIM`、`MOVE_ELIM_MAX_REFS`。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 10. 变更记录

`git log --oneline 261bd67..HEAD -- rtl/backend/ren`：本分支没有对本模块的提交；FLUSH_REG（`803692f`）只改了 `back_top` 的连线，使 `rob_bcast_flush` 到本模块晚一拍。更早：见 git 历史。
