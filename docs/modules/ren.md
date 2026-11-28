---
module: ren
area: backend
rtl: rtl/backend/ren
model: trace-model back-end/Ren.cpp、back-end/include/Ren.h（调度单元 `back.rename`，类 `Ren`，阶段 `comb_rename`、`comb_fire`）
status: 整核周期与模型逐个相等（EXP-062：`ren_log` T-1 拍预寄存读窗 `rd_slot_q[0..7]` 0 周期变化，rv64gc Linux 26/26 窗 PT/UP 逐拍全等）
depth: 91 层（Yosys 156,986 cells）；**TSMC 28nm HPC+ DC `ssg0p81v125c` `0.50ns`（EXP-062）：`WNS -0.45→-0.36 ns`、`1.05→1.16 GHz`、`49→48 lvl`、面积 `144,365 um²`（见 09-synthesis-report 第 15 节）**
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
| 整数物理寄存器 | 256（标号 0..255；初始空闲 256 - 33 = 223 个） | `PRF_NUM = 256` |
| 浮点架构 / 物理寄存器 | 32 / 96（标号从 256 起；初始空闲 96 - 32 = 64 个；总编号宽 9 位） | `FP_ARF_NUM = 32`、`FPRF_NUM = 96`、`FP_TAG_BASE = 256`、`PRF_IDX_WIDTH = 9` |
| 分支标签 | 32 个（标签 0 表示"不是分支"，不使用），每个标签一份恢复点 | `MAX_BR_NUM = 32`、`BR_TAG_WIDTH = 5` |
| 移动消除 | 总是开（RTL 不读 `MOVE_ELIM`）；引用次数不设上限（一个物理寄存器最多被 `RAT_NUM = 33` 项引用，计数不会溢出） | 计数宽度 `ren_pkg::CNT_W = $clog2(RAT_NUM + 1) = 6`。`ttg_cfg_pkg` 里仍有 `MOVE_ELIM_MAX_REFS = 7`（从模型生成），RTL 不再使用（EXP-065 删除上限） |

AMO 暂存寄存器：IDU 把"丢弃结果的读改写 AMO"的目的寄存器号改成 32（`idu_ctrl_decode.sv` 输出段，对应模型 `Idu::decode` 末尾），所以 RAT 要多一项。

## 3. 接口

信号组按模型的 `in` / `out` 命名；顶层 `ren.sv` 只做平铺端口和结构体的互转（`ren_core` 是真正的实现）。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dec2ren_valid[8]`、`dec2ren_uop[8]`（`ren_pkg::ren_inst_t`） | 译码后的指令（架构寄存器号、指令类型、FP 域标志…；没有分支标签和分支掩码） |
| 入 | `dec_bcast_mispred`、`dec_bcast_redirect_rob_idx` | 分支误预测和被预测错的分支的 ROB 号（恢复时查检查点 / 前向 Walk 的终点） |
| 入 | `dis2ren_ready` | 分派接受这一组 |
| 入 | `rob_bcast_flush`、`rob_bcast_interrupt` | 全局冲刷（`FLUSH_REG` 后晚一拍，docs/FLUSH_REG.md）；带中断退休的指令不提交映射 |
| 入 | `rob_commit_commit_entry_*[8]` | 退休的指令：`dest_en`、`dest_areg`、`dest_preg`、`old_dest_preg`、`me_elim`、`dest_fp`、异常标志、类型 |
| 出 | `ren2dec_ready` | 这一组被接收（空）或还有 lane 没发出 |
| 出 | `ren2dis_valid[8]`、`ren2dis_uop_*[8]` | 重命名后的指令（`dest_preg`、`src1/2/3_preg`、`old_dest_preg`、`me_elim`…）；`src1_areg` 要继续带，ROB 经退休端口交给前端 BPU |

`is_rvc` 和 `mdp` 不经过 IDU 和 ren，见 dispatch.md / ftq_ibuf.md。

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
   └ ren_ckpt       : 稀疏检查点，`REN_CKPT_NUM = 4` 项（RAT 快照 + 空闲表头），由 ren_ckpt_ctl 管理
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ren_pkg.sv` | 143 | 结构体、move 形状判断 `ren_is_move_shape`、复位值函数 |
| `ren.sv` | 52 | 顶层：端口适配 |
| `ren_core.sv` | 329 | 连接各子块；整数域的握手与输出拼装 |
| `ren_inst_pipe.sv` | 135 | 输入寄存器与 S1 预译码级（RAT 读写地址一热码、move 形状、同组 RAW/WAW 命中矩阵） |
| `ren_alloc_sel.sv` | 45 | 分配：8 个"取最先请求者"串起来，第 k 个请求者拿窗口第 k 项（整数域和浮点域共用） |
| `ren_handshake.sv` | 47 | 按序卡住与 fire |
| `ren_rat.sv` | 180 | 推测 / 架构 RAT（读写都用 S1 预译码的一热地址） |
| `ren_dep_check.sv` | 80 | 整数域的同组旁路 |
| `ren_elim_sel.sv` | 88 | 移动消除的判定（3 级指针跳跃） |
| `ren_arch_cnt.sv` | 73 | 每个整数物理寄存器的"被架构 RAT 引用次数" |
| `ren_commit_filter.sv` | 38 | 哪些退休项算"退休一个目的寄存器" |
| `ren_rank.sv` | 27 | 选中的退休槽的序号和总数（空闲表写偏移） |
| `ren_free_list.sv` | 177 | 空闲表（8 bank 1R1W 环，3 个指针），按参数 `NUM / RESV / TAG_BASE / PORT_W` 一份给整数域（默认）、一份给浮点域（`ren_fp`） |
| `ren_ckpt.sv` | 50 | 稀疏检查点存储（`REN_CKPT_NUM = 4` 项） |
| `ren_ckpt_ctl.sv` | 282 | 检查点 FIFO 控制（分支间距 ≥ `REN_CKPT_INTERVAL = 32` 才分配）、误预测恢复与 8 宽前向 Walk 状态机 |
| `ren_log.sv` | 140 | 本地按 ROB 号索引的重命名日志（`ROB_NUM = 256` 项，8 bank × `ROB_LINE_NUM = 32` 行，1R1W），存 `dest_preg` / `old_dest_preg` / 是否被消除，供 Walk 与退休回收 |
| `ren_last_write.sv` | 31 | "同一拍多个写者，编号大的赢"的优先选择，多处复用 |
| `ren_fp.sv`、`ren_fp_dep.sv` | 187、42 | 浮点域 |

状态（整数域）：输入寄存器（8 lane）；推测 RAT 和架构 RAT（各 `RAT_NUM` 项 × `$clog2(PRF_NUM) = 8` 位，只存整数域号）；空闲表 `bank_q[8][PRF_NUM/8]` 和三个指针 `head`（推测分配）、`head_commit`（最老未提交的分配）、`tail`（还回来的旧寄存器追加处）；`arch_cnt` `PRF_NUM = 256` 个 6 位计数器（复位时前 33 个为 1）；检查点表 `entry_q[REN_CKPT_NUM]`（4 项），每项一份 RAT 快照加一个空闲表头；重命名日志 `ren_log`（256 项）。浮点域同样一套（RAT 32 项，环 `FPRF_NUM` 个，不是 2 的幂，指针按 `fp_ptr_add` 显式回绕；没有移动消除，没有计数器）。

## 5. 一拍内的数据流

### 5.1 重命名（只读寄存器）

1. **移动消除**（`ren_elim_sel`，对应模型 `elim_refs_ok`）：move 形状（`addi rd, rs, 0`，含 IDU 规范化后的 `c.mv` / `add rd, x0, rs2`，rd、rs 都不是 x0）分两种情形：
   - **组内 1-hop 生产链消除**：本组里比自己老的有效整数指令写了 `src1_areg` 时，取最近老写者 `j`；若 `j` 未被消除，则允许消除，目的物理寄存器直接取旁路后的 `src1_preg`；若 `j` 本身被消除则不消除（只允许 1 跳）；
   - **无更老写者**：本组里没有更老的整数写者时总是消除（引用数没有上限，`arch_cnt` 是 6 位，最多 33 个引用，不会溢出）。判定只用 S1 预译码的 `raw_hit_src1`，不读推测 RAT。
   RTL 复用公共原语库（`ttg_first_set`、`ttg_onehot_to_idx`、`ttg_onehot_mux`、`ttg_popcount`）将 7 级组内旁路链改写为 3 级 Kogge-Stone 并行指针跳跃网络（`st_const / st_cval / st_inv / st_ptr`），（EXP-065 起不再有 33 路 `spec_rat` 计数）。
2. **分配**（`ren_alloc_sel`）：要整数寄存器的 lane（有效、有目的寄存器、不是浮点、没被消除）按序排队；第 k 个请求者拿窗口第 k 项，且要 `k < free_count` 才算拿到（复用 `ttg_pick_k` 与 `ttg_onehot_mux`）。浮点域同样（`ren_fp` 里再用一份 `ren_alloc_sel`）。
3. **按序卡住**（`ren_handshake`）：整数域和浮点域的请求合在一起，第一个请求却没拿到的 lane 起（含它）全部 `ren2dis_valid = 0`；没有目的寄存器的指令只受这个卡住的影响。
4. **查表和旁路**：每个 lane 查 3 个读口（目的、src1、src2）；`ren_dep_check` 采用两级无递推并行旁路（复用 `ttg_first_set`、`ttg_onehot_mux` 与 `ren_last_write`）：第一级利用 1-hop 消除不变式（被消除 move 的最近老写者必未被消除）直接从 `alloc_reg[0..i-1]` 与 `src1_normal[i]` 并行算出全部 `dest_of[0..7]`（打破 7 级假串行链），第二级再从 `dest_of` 并行旁路 `old_dest / src1 / src2`（`src1` 复用第一级 `ttg_first_set` 独热码）。浮点域有 4 个读口（src1、src2、src3、旧目的），旁路在 `ren_fp_dep`，f0 是真寄存器。
5. 被消除的 move：`dest_preg = src1_preg`（旁路后的），不占空闲表。

### 5.2 握手与推进（寄存器次态）

- `fire[i] = ren2dis_valid[i] & dis2ren_ready`；`ren2dec_ready = 所有有效 lane 都 fire & !冲刷 & !误预测`。
- `ren_rat` 的 `snapshot[0..7]` 按 `alloc_cand`（`inst_valid & dest_en & ~dest_fp`，不依赖 `fire`）预计算，分支检查点在 `fire[i]` 成立时直接锁存 `snapshot[i]`（前缀性保证 `0..i` 全部 fire），将 `ren_handshake` 移出 `ren_ckpt` 关键路径；正常次态 `spec_d` 与空闲表头 `head_next` 均通过 `ren_last_write` 按 `fire` 末位直接选通对应快照/表头。
- 输入寄存器：冲刷或误预测清空；`ren2dec_ready` 时换成译码的新组；否则保留没 fire 的 lane。

### 5.3 退休（commit）

- `ren_commit_filter`：一个退休槽"退休一个目的寄存器"，当且仅当：有效、`dest_en`、没有异常（缺页、非法指令、ecall）、本拍没有中断（`rob_interrupt`）。这样的槽才更新架构 RAT 和还旧寄存器。出了异常或被中断带走的指令就像没提交过。
- 整数域：`arch_cnt[dest_preg]++`，`arch_cnt[old_dest_preg]--`；某个槽的 `old_dest_preg` 在"这个槽及前面所有槽处理完"之后计数为 0，就把它还回空闲表（`ren_arch_cnt`：每个槽并行数前面的增减，不串行）。还回的位置是 `tail + 本槽在"要还的槽"里的序号`（`ren_rank`）。`head_commit` 前进"退休且真的分配过寄存器的槽数"（被消除的 move 没分配，不算）。
- 浮点域：没有移动消除，每个退休的浮点目的寄存器直接还旧寄存器，浮点域的 `ren_free_list` 实例同理（`head_commit` 按 `reclaim_total` 前进）。

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
- 空闲表指针：整数域环大小 `PRF_NUM` 是 2 的幂，指针按位宽自然回绕；浮点域 `FPRF_NUM = 96` 不是，要显式回绕。物理寄存器号是 `PRF_IDX_WIDTH = 9` 位（FP 从 `FP_TAG_BASE = 256` 起），整数环位置是 `$clog2(PRF_NUM) = 8` 位（`ren_free_list` 的 `PW`）；`ren_log` 里只存 8 位低位加 1 位 `dest_fp`；
- 检查点是稀疏的：只有 `REN_CKPT_NUM = 4` 项，不是每个分支标签（`MAX_BR_NUM = 32`）一份；误预测命中检查点时 0 拍恢复，否则从最近检查点或架构 RAT 用 `ren_log` 前向 Walk（Walk 期间 `ren2rob_walking` 暂停 ROB 提交）。

已发现、未改动的点：

- `ren.sv`、`ren_pkg.sv` 文件头注释里的"reference model commit 2f31e8d"已过时；

**未核对（继承自旧文档）**：无（旧文档的内容全部没有采用）。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）：77/77 通过（最近一次 rtl 73761fa，2026-11-28），周期逐个相等。
- **SVA 断言与覆盖（`SOC_SVA=1`）**：`sva/sva_ren.sv` 通过 `bind` 挂载至 `ren_core`（零综合污染），检查 `free_count <= PRF_NUM`、`walk_active` 期间禁止普通 rename `fire`、`alloc_valid -> alloc_req`，并带 5 个功能 cover（满 8 宽 fire、forward walk、移动消除、flush、mispred）。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **模块级测试 `tests/ren_elim_sel/`**：`run.sh [向量数]` 用 Verilator 编 `ren_elim_sel`，`tb_ren_elim_sel.cpp` 按定义写的 C++ 参考（`elim[i] = cand[i] && (没有更老写者 || !elim[最近老写者])`）逐向量对比，默认 200 万个向量，偏向长的组内 move 链；输出 PASS 或第一个不一致。fe-2ahead 去掉 UNOPTFLAT 的改写（每级指针跳跃各用一组信号）用它验证。
- 其余子块没有模块级测试，靠整核周期逐拍相等和 Linux 启动。旧体系（`spec/` 的 trace 回放、随机 trace、变异检查）已退役。**待补**：给空闲表和 `arch_cnt` 的释放逻辑补新旧并排的随机测试，改深度时用；最好有一个覆盖"同拍退休、冲刷、误预测"的专门用例（模型里这是断言，RTL 里没有）。

## 9. 参数与开关速查

`DECODE_WIDTH`、`COMMIT_WIDTH`、`ARF_NUM`、`PRF_NUM`、`FPRF_NUM`、`FP_ARF_NUM`、`FP_TAG_BASE`、`MAX_BR_NUM`、`REN_CKPT_NUM`、`REN_CKPT_INTERVAL`（`MOVE_ELIM_MAX_REFS` 仍在包里但 RTL 不用）。`ttg_cfg_pkg.sv` 由 `make cfg`（`harness/tools/gen_cfg_pkg.py`，从 trace-model `include/config.h`）生成，不手改。

## 10. 变更记录

- 2026-11-29 清理 D：去重——`ren_free_list` 与 `ren_fp_free_list` 合并为一个参数化模块（`NUM`：环大小，2 的幂时自然回绕，否则模 `NUM`；`RESV`：复位时被架构 RAT 占用的个数；`TAG_BASE`：库里存本域局部号、读出加回；`PORT_W`：环位置端口宽度），`ren_fp` 以 `#(.NUM(FPN), .RESV(FP_ARF_NUM), .TAG_BASE(FP_TAG_BASE), .PORT_W(FP_PTR_W))` 实例化并把 `free_total` 同时接 `reclaim_total` / `alloc_commit_total`，`ren_fp_free_list.sv` 不再被引用；新增 `tests/ren_free_list/run.sh`：合并模块两种参数与改前两个模块的副本逐拍对拍（随机输入，100 万拍 PASS，删掉浮点域行回绕的变异第 22 拍即报错）；`ren_pkg` 删 `INST_TYPE_WIDTH`、`ITYPE_*` 副本，改用 `dis_pkg::INST_TYPE_W` / `INST_*`（数值相同；`ren` / `ren_core` / `ren_commit_filter` / `ren_inst_pipe` 同步）；`tests/ren_elim_sel/run.sh` 加 `dis_pkg.sv`（周期不变）。
- 2026-11-28 清理：移动消除写死开（`ren_core` 删 `g_no_elim` / `g_no_cnt`，不再读 `ttg_cfg_pkg::MOVE_ELIM`）；F/D 写死（删 `g_no_fp`，`ren_pkg::FPN = FPRF_NUM`）；`ren_ckpt_ctl` 删未用输出 `rd_base`（只用 `rd_base_next`）；`ren_pkg` 删未用的 `rat_identity`、`fp_rat_identity`、`free_list_init`、`fp_free_list_init`；删不抑制任何告警的 lint 豁免（`ren_elim_sel` / `ren_free_list` / `ren_log` 各 1 处、`ren_rat` 2 处；`unused_*` 汇本身 Verilator 不报，以去掉豁免后整树 lint 普通 / `-DSYNTHESIS` 均无新告警为准）（周期不变）。
- 2026-11-28（文档核对，无 RTL 变化）：移动消除不再有 `MOVE_ELIM_MAX_REFS` 上限（`CNT_W = 6`，EXP-065）；稀疏检查点 `REN_CKPT_NUM = 4`、`ren_log`、`ren_ckpt_ctl` 写进结构与文件表；`PRF_NUM = 256` 下的位宽；接口去掉 `br_id / br_mask / clear_mask`；第 8 节加 `tests/ren_elim_sel`；`ttg_cfg_pkg` 为生成文件；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/fe-2ahead`，0 周期变化）：`ren_elim_sel` 的指针跳跃各级改成各自的生成块信号（`g_st[s].c / v / inv / g_p.ptr`），第 `s+1` 级只读第 `s` 级，消除整核 Verilator `UNOPTFLAT`（原来 `[ST+1]` 下标的数组是一个信号，经动态下标形成假环）；最后一级不再算指针。`tests/ren_elim_sel/run.sh` 改写为按定义的 C++ 参考模型 200 万次随机对拍（原测试用的是旧端口，已编不过）：新、旧实现都 PASS，`^` 改成 `~^` 的变异第 0 组即报错。

- 2026-11-24（`rtl/timing-opt3`，EXP-064 第三轮 28nm DC 时序优化）：落地 2 级流水化重命名（`IDU → S1 → S2 → DISPATCH`，同步 `trace-model/back-end/Ren.{h,cpp}`）：① `ren_inst_pipe` 增加 S1 预译码级，将 RAT 24+8 路 5→33 one-hot 地址译码（`rd_oh_q` / `wr_oh_q`）、`move_shape_q`、`is_branch_q` 及同组 RAW/WAW 比较矩阵（`raw_hit_dest_q/src1_q/src2_q`）前移至 S1 并打拍入 S2；`ren_rat` 增 `PRE_OH=1` 直用预译码 one-hot，`ren_dep_check` 直用预译码命中矩阵，`ren_handshake` 拆分 `s2_take_new` 与 `ren2dec_ready = (s1_empty | s2_take_new) & ~flush & ~mispred`；② `ren_ckpt_ctl` 在静态槽位 `0..NK-1` 并行预计算 `slot_age/slot_ptr/slot_eq_br`，`ren_log` 将 8:1 旋转多路器移至 `bank_rd_q` 触发器之后，彻底清除原 Path #2（`ckpt_head_q → u_log/rd_slot_q`）；③ `ren_alloc_sel` 改用每路直接前缀 `ttg_popcount(0..7)` 替代 `ttg_pick_k(8,8)`。TSMC 28nm DC：`ren` **1.16 → 1.22 GHz**（WNS `−0.36 → −0.32 ns`，46→40 级，TNS `−5,375`，面积 `157.6k um²`；新顶路径为 S2 内 `ckpt_count_q → ckpt_wr_lane_oh → u_ckpt` 与 `rd_oh_q → ren_elim_sel → u_rat/spec_q`）；SPEC06 INT 386/386 `−1.07%`；`lint_chip` 0、`fm_gate` 69/69（0 周期差）。
- 2026-11-23（`rtl/ren-ckpt-walk`）：将 ROB 中的重命名字段（`dest_preg`/`old_dest_preg`/`me_elim`）抽离至 `ren` 本地 256×25b ROB 索引日志表 `ren_log`（8 bank × 32 行，1R1W），将 `ren_ckpt` 从 32 项×8 写口缩减为 `REN_CKPT_NUM=4` 项×1 写口 FIFO（`ren_ckpt_ctl` 控制，分支间距 ≥ `REN_CKPT_INTERVAL=32` 分配，误预测时命中检查点 0 拍恢复、未命中则回退至最近检查点或 `arch_rat` 并复用 `ren_rat` 8 宽写口前向 Walk，Walk 期间经 `ren2rob_walking` 暂停 ROB 提交）；同步将 `ren_free_list` / `ren_fp_free_list` 改为 8-bank 1R1W（8b/7b 域内窄位宽）、删除 `ren_rat` 的 8 份全量 `snapshot[0..7]` 改双口直算、`ren_ckpt_ctl` 预计算 `used_after/tail_after` 并将 `ckpt_wr_lane_oh` 提前至 `inst_valid`。`eda-08` Yosys：`ren` **586,315 → 156,986 cells（−73.22%）/ 91 层（与基线持平）**，`rob` **897,972 → 881,101 cells（−1.88%）/ 65 层**；`lint_chip` 0、`fm_gate` 69/69（0 周期偏差）。
- 2026-11-21（`rtl/move-elim-1hop`，EXP-052）：`ren_elim_sel` 新增组内 1-hop 生产链移动消除（并行根分解，避免串在 33 路 popcount 后），`ren_dep_check` 改为 `dest_of = elim[i] ? src1_preg[i] : alloc_reg[i]`；`ren_core` / `ren_fp` 的分支 `head_after` 改用 `alloc_req` 前缀并由 `ren_free_list` / `ren_fp_free_list` 按 `fire` 末位直接选通 `head_next`（移除握手后的 `popcount + 加法`）。`eda-08` Yosys 深度 **99 → 97 层**（`474,699 → 475,533` cells，+0.18%）；`tests/ren_elim_sel/run.sh` 100k 随机 0 不一致；`lint_chip` 0、`fm_gate` 68/68（0 周期偏差）。
- 2026-11-21（`rtl/onehot-mux-tree`）：`ren_alloc_sel` 从 8 级串行 `ttg_first_set` 链改用公共并行原语 `ttg_pick_k`，配合 `ttg_onehot_mux`/`ttg_popcount` 平衡树，`eda-08` Yosys 深度从 **111 → 99 层**（跌破 100 层红线，单元 `474,613 → 474,699`），零周期变化。
- `git log --oneline 261bd67..HEAD -- rtl/backend/ren`：本分支没有对本模块的提交；FLUSH_REG（`803692f`）只改了 `back_top` 的连线，使 `rob_bcast_flush` 到本模块晚一拍。更早：见 git 历史。
- 2026-11-25（`rtl/timing-opt4`，EXP-065 第四轮 28nm DC 时序优化）：① 取消 `MOVE_ELIM_MAX_REFS=7` 上限（保留 1-hop `!elim[producer]`，将 `CNT_W` 扩至 `$clog2(RAT_NUM + 1) = 6`，最大引用计数 33 永不溢出），彻底删除 `ren_elim_sel.sv` 中 264× 8-bit `spec_rat` 比较器与 8× 33-bit popcount，改为复用 S1 `raw_hit_src1_q` 与 3 级 Kogge-Stone 指针跳跃（连续 `assign` 消除 `ALWCOMBORDER`）；② `ren_rat.sv`/`ren_core.sv`/`ren_fp.sv` 将检查点写入流水化 1 拍（0 周期变化）；③ `ren_arch_cnt.sv` 简化归零判定（`n_dec >= n_inc && cnt_q == n_dec - n_inc`）并将 INT 空闲列表回收打 1 拍寄存（`free_q`/`reclaim_preg_q`，同步 `trace-model` `Ren.{h,cpp}`）。TSMC 28nm DC：`ren` **1.22 → 1.67 GHz（+36.9% / +450 MHz）**（WNS `−0.32 → −0.10 ns`，逻辑级数 `40 → 26` −35%，TNS `−5,375 → −1,330 ns` −75.3%，面积 `157.6k → 156.6k um²` −0.6%）；通过 `lint_chip` 0、`fm_gate` 69/69（0 周期差）与 Linux 26 窗对齐。
