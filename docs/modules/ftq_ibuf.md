---
module: ftq_ibuf
area: backend
rtl: rtl/backend/ftq_ibuf
model: trace-model back-end/PreIduQueue.cpp、back-end/InstructionBuffer.cpp、back-end/include/PreIduQueue.h、back-end/include/InstructionBuffer.h、back-end/include/FTQ.h（调度单元 `back.pre`，类 `PreIduQueue`，阶段 `comb_accept_front`、`comb_commit_info`）
status: 整核周期与模型逐个相等（EXP-070 Unified FTQ-64：吸收前端 `fetch_addr_fifo`/`ptab`/`front2back_fifo`；fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: TSMC 28nm DC（EXP-069 `ftq_ibuf_bb` 243,191 µm² / reg2reg 1.72 GHz）；Yosys 门代理 39 层（2026-11-18，当时的 `pre_idu_queue`）；EXP-070 后未重测，见第 6 节
---

# ftq_ibuf 设计文档（原 `pre_idu_queue`）

## 1. 职责

前端和后端之间的缓冲，由两部分组成：

- **统一 FTQ**（Unified FTQ-64，取指目标队列）：每个取指块一项，从 BPU 的 S0 分配，到块里最后一条指令退休才释放。前端的取指地址排队、S2 预测、预译码结果和后端要读的 pc / 预测 / 训练元数据都存在这里（EXP-070 吸收了原前端的 `fetch_addr_fifo`、`ptab`、`front2back_fifo`）；
- **指令缓冲 `ibuf`**：64 项环形缓冲，前端送来的取指组按序压紧写入，每拍把最老的 8 条发给 IDU。

每拍做的事：

1. FTQ 指针：S0 分配（`bpu_ptr`）、S2 覆盖丢尾（0..2 项）、IFU 取走（`ifu_ptr`）、S2 写预测（`s2_ptr`）、预译码写回（`pd_ptr`，冲刷时回滚其后的项）、退休释放（`comm_ptr`）、误预测恢复、全局冲刷；
2. 接收取指组：`ibuf` 放得下整组就接收（`ftq2front_ready / fire`），其中的有效指令按序压进 `ibuf`，每条带 `ftq_idx`（前端给的块号）、`ftq_offset`（槽号）、`ftq_is_last`；
3. 发出：`ibuf` 最老的 8 条给 IDU；`ibuf` 为空时本拍接收的组直接发出（旁路）；IDU 消耗的前缀从 `ibuf` 弹出；
4. 读口：EXU / PRF 的 pc（4 口）、ROB 队头 pc（1 口）、退休 8 口（pc、预测、`next_pc`、训练元数据）、分派 8 口（pc、`is_rvc`、load 等待表下标 `mdp`）、误预测修复（块号、分支类别）。

模型对应：调度单元 `back.pre`（类 `PreIduQueue`，`back-end/PreIduQueue.cpp`、`InstructionBuffer.cpp`、`include/FTQ.h`）。

## 2. 配置（`ttg_cfg_pkg` / `ftq_ibuf_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| 前端每拍最多送的指令数 | 16 | `BACKEND_FETCH_WIDTH` |
| 发给 IDU 的组宽 | 8 | `DECODE_WIDTH` |
| 指令缓冲项数 | 64 | `IDU_INST_BUFFER_SIZE` |
| FTQ 项数 | 64（2 的幂，有展开期检查） | `FTQ_SIZE`，`FTQ_IDX_WIDTH = 6` |
| FTQ 项内槽下标 | 4 位 | `FTQ_OFFSET_WIDTH` |
| FTQ 满 | `bpu_ptr - comm_ptr >= FTQ_SIZE - 1` 或 `bpu_ptr - ifu_ptr >= 15` | `ftq_ptr.sv`（15 是字面量） |
| PRF / ROB pc 读口 | 4 / 1 | `FTQ_PRF_PC_PORT_NUM`、`FTQ_ROB_PC_PORT_NUM` |
| 退休读口 | 8 | `COMMIT_WIDTH` |
| 块号 / `pcpn` | 10 / 3 位 | `ftq_ibuf_pkg::BLK_ID_W`、`PCPN_W` |
| 训练元数据 | 每项 74 位：块号 10 + 16 槽 ×（`alt_pred` 1 + `pcpn` 3） | `ftq_meta_entry_t` |
| pc 存储项 `ftq_pc_ent_t` | 按字段 161 位：`pc0` 64、`carry` 1、`pred_taken` 16、`is_rvc` 16、`next_pc` 64 | `ftq_pc.sv` |
| 等待表下标 `mdp` | `pc[SLOT_SHIFT +: 6] ^ pc[SLOT_SHIFT + 6 +: 6]` | `LSU_MDP_BITS = 6`、`SLOT_SHIFT = 1` |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n` | `rst_n` 也驱动 `ftq_meta` SRAM 的复位清零（[common.md](common.md) 4.1 节） |
| 入 | `front2ftq_{valid, inst, page_fault_inst, pf_inst_hi}[16]`、`front2ftq_ftq_idx` | 前端检查完的取指组（`core_front2back` 输出） |
| 入 | `fe2ftq_s0`、`fe2ftq_s2`、`fe2ftq_pd` | 前端对 FTQ 的三组写请求（见 [front_top.md](front_top.md)） |
| 入 | `idu_consume_fire[8]` | IDU 消耗了哪些 |
| 入 | `br_redirect_{mispred, ftq_idx, ftq_offset, pc}` | 寄存后的误预测（`back_top` 的 `back_br_redirect`） |
| 入 | `rob_bcast_flush` | 全局冲刷 |
| 入 | `rob_commit_{valid, uop_ftq_idx, uop_ftq_offset, uop_ftq_is_last}[8]` | 退休 |
| 入 | `ftq_prf_pc_req_{ftq_idx, ftq_offset}[4]`、`ftq_rob_pc_req_{ftq_idx, ftq_offset}[1]`（没有 valid：每拍都读）、`ftq_dis_req_{ftq_idx, ftq_offset}[8]` | 读请求 |
| 出 | `ftq2fe`（`ftq_fe_view_t`） | 给前端的寄存视图（`ftq_full`、`ifu_empty`、`ifu_cnt_sat`、`s2_empty`、`ifu_addr`、`ifu_next_set_idx`、`pd_*` 等） |
| 出 | `ftq2front_ready`、`ftq2front_fire[16]` | 前端握手 |
| 出 | `ibuf2idu_valid[8]`、`ibuf2idu_entry[8]`（`ib_entry_t`） | 发给 IDU |
| 出 | `ftq_prf_pc_resp_*`（pc、预测方向、`is_rvc`、`next_pc`）、`ftq_rob_pc_resp_*`（pc、`is_rvc`） | 读响应 |
| 出 | `ftq_commit_info_resp_{valid, pc, next_pc, pred_taken, is_rvc, alt_pred, pcpn, blk_id}[8]` | 退休读 |
| 出 | `ftq_dis_resp_{mdp, pc, is_rvc}[8]` | 分派读 |
| 出 | `out_rf_blk`、`out_rf_type` | 误预测修复：出错分支所在块的块号和槽的分支类别 |
| 出 | `ftq_head_out` | `comm_ptr` |

## 4. 结构

```
 fe2ftq_s0/s2/pd ─► ftq_ptr  : comm / pd / s2 / ifu / bpu 五个指针、空块标记、满 / 空标志
                 ─► ftq_pc   : 8-bank pc / 预测存储；前端寄存视图；EXU 4 口、ROB+退休窗口、分派窗口
                 ─► ftq_meta : 8 × (8 × 74b) 同步 1R1W SRAM，训练元数据，按 next_comm_ptr 预读
                 ─► ftq_bpu  : 块号（S2 写）+ 槽类别（PD 写），误预测修复读
 front2ftq ─► ftq_ibuf_ctrl（握手、序号、块尾、弹出数）─► ibuf（64 项环形缓冲，空时旁路）─► ibuf2idu
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ftq_ibuf.sv` | 287 | 顶层：端口适配、写请求门控（冲刷 / 误预测那拍不写）、`mdp` 哈希、`ftq2fe` 组装 |
| `ftq_ibuf_ctrl.sv` | 65 | 握手、块内序号（`lane_rank`）、块尾、IDU 消耗前缀、`flush_prev_q` |
| `ftq_ibuf_pkg.sv` | 56 | 位宽常量、`FTQ_PC_BANKS = 8` 与窗口判定 `ftq_in_window`（`idu` / `rob_core` 共用）、`ftq_meta_t`、`ftq_meta_entry_t`、`ib_entry_t` |
| `ibuf.sv` | 116 | 指令环形缓冲、旁路 |
| `ftq_ptr.sv` | 188 | 五个指针、空块标记 `empty_blk_q`、满 / 空标志、断言 |
| `ftq_pc.sv` | 218 | pc / 预测存储（8 bank × 8 行）、四个写者、各读口 |
| `ftq_meta.sv` | 78 | 训练元数据 SRAM（8 个 `ttg_sram_1r1w`，`WRITE_FIRST`） |
| `ftq_bpu.sv` | 39 | 块号与槽类别 |

状态：五个指针和 64 位空块标记；`bank_q[8][8]`（`ftq_pc_ent_t`）；`ftq_meta` 的 SRAM；`ftq_bpu` 的 `id_q[64]`、`kind_q[64]`；`ibuf` 的 `head_q`、`tail_q`、`count_q`、`entry_q[64]`（`ib_entry_t`：指令 32、缺页 1、`pf_inst_hi` 1、`ftq_idx` 6、`ftq_offset` 4、`ftq_is_last` 1）；`flush_prev_q`。

## 5. 一拍内的数据流

### 5.1 FTQ 指针（`ftq_ptr`）

优先级：冲刷 > 误预测 > 正常。

- 冲刷：五个指针和空块标记清零；
- 误预测：`pd / s2 / ifu / bpu` 指针都回到 `br_redirect_ftq_idx + 1`，之后的空块标记清掉；`ftq_pc` 同拍把出错项的 `next_pc` 改成重定向地址；
- 正常：S0 先丢尾（`drop_n = min(drop_tail_n, bpu_ptr - ifu_ptr)`）再分配；`ifu_ptr += ifu_pop`；`s2_ptr += s2 写`；`pd_ptr += pd_fire`，预译码冲刷时 `bpu / ifu / s2` 都回到新的 `pd_ptr`；退休：本拍最后一个 `ftq_is_last` 的项之后就是新的 `comm_ptr`，若它是预译码标为空的块（`empty_blk`）且还没到 `pd_ptr` 就再跳一项。

前端看到的 `ftq_full`、`ifu_empty`、`ifu_cnt_sat`、`s2_empty` 都由寄存的指针算出。

### 5.2 接收、发出、弹出（`ftq_ibuf_ctrl`、`ibuf`）

- `ready = !br_redirect_mispred & !flush_prev_q & (组内有效数 <= ibuf 空闲数)`；`fire = front_valid & ready`；`flush_prev_q` 是上一拍的 `rob_bcast_flush`；
- 写入：第 i 个有效 lane 写在 `tail + lane_rank[i]`；
- 发出：`ibuf` 非空时是 `entry_q[head + i]`（`i < count`），为空时是本拍接收组里序号为 i 的那条（独热选择）；
- 弹出数 = `idu_consume_fire` 的前缀 1 的个数；冲刷或误预测时清空（`queue_clear`）。

### 5.3 读口（`ftq_pc`、`ftq_meta`、`ftq_bpu`）

- 槽 i 的 pc 由 `{pc0, carry}` 重建：`i == 0` 时是 `pc0`，否则 `pc0 + (i + carry) << SLOT_SHIFT`（`ent_pc`；携带块的 `pc0` = 基址 - 2）；槽的 `next_pc` 直接是该项的 `next_pc`；
- EXU 4 口是随机读；ROB 队头和退休 8 口共用以 `comm_ptr` 为起点的 8 bank 窗口；分派 8 口共用以 `dis_idx[0]` 为起点的窗口；
- 训练元数据 SRAM 每拍按 `next_comm_ptr` 预读 8 项窗口，退休那拍按退休指令自己的 `(ftq_idx, ftq_offset)` 取；
- 误预测修复：`rd_blk = blk_id`，`rd_type = kind[offset]`。

## 6. 关键路径与深度

| 日期 / 口径 | 结果 |
| --- | --- |
| EXP-069，TSMC 28nm HPC+ DC（`ftq_ibuf_bb`） | 243,191 µm²，reg2reg 1.72 GHz（统一 FTQ 之前） |
| 2026-11-26（`rtl/area-opt`）DC | 约 211k µm²（`pre_idu_queue` 1,684,992 µm² 降 87.5%） |
| 2026-11-18，Yosys 门代理（`SYNTH_ABC="strash;balance;map"`） | 39 层（当时的 `pre_idu_queue`） |

EXP-070 统一 FTQ 之后没有单模块重测。从代码读出、未综合验证的链：前端有效位 → `lane_rank`（popcount）→ `ready` → `fire` → `ibuf` 写；`idu_consume_fire` 前缀 → 弹出数 → `head_d / count_d`；退休 `ftq_is_last` → `comm_ptr_d` → `ftq_meta` 预读地址。

## 7. 与模型的差异和取舍

- 模型缓冲项里的 `uop_id`、`pc`、`is_rvc`：RTL 不存，需要时向 FTQ 读；
- `ftq_pc` 存紧凑的 `{pc0, carry}` 而不是每槽 pc；
- 训练元数据放在同步 SRAM（`ftq_meta`），靠 `next_comm_ptr` 提前一拍读；模型是寄存器数组随时可读；
- `bpu_ptr` 在顶层没有输出（接 `bpu_ptr_unused`）。

未核对：误预测修复用块号 + 槽类别的方式与模型 `ftq_blk_id` 等字段是否在所有情况下等价，只靠整核周期相等。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，周期对 `scripts/ref_cycles.txt` 逐个相等。
- **仿真断言**：`ftq_ptr` 里两条：FTQ 满时不分配；`comm_ptr` 不停在空块上；`FTQ_SIZE` 非 2 的幂的展开期错误。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**。**待补**：`ftq_ptr`（恢复、丢尾、空块跳过）与模型的随机对拍；`ibuf`（旁路与弹出）的随机测试。

## 9. 参数与开关速查

无开关。常量：`BACKEND_FETCH_WIDTH`、`DECODE_WIDTH`、`COMMIT_WIDTH`、`IDU_INST_BUFFER_SIZE`、`FTQ_SIZE`、`FTQ_IDX_WIDTH`、`FTQ_OFFSET_WIDTH`、`FTQ_PRF_PC_PORT_NUM`、`FTQ_ROB_PC_PORT_NUM`、`LSU_MDP_BITS`、`SLOT_SHIFT`（`ttg_cfg_pkg`）；`BLK_ID_W`、`PCPN_W`（`ftq_ibuf_pkg`）。

## 10. 变更记录

- 2026-11-29 清理 E（前端视图）：`ftq_fe_view_t` / `ftq_ptr` / `ftq_pc` 改名 `fa_empty` → `ifu_empty`、`fa_cnt_sat` → `ifu_cnt_sat`、`fa_cnt` → `ifu_cnt`、`ifu_next_fa_idx` → `ifu_next_set_idx`（只改名字，周期不变）。
- 2026-11-29 清理 E：改名 `rob_commit_commit_entry_*` → `rob_commit_*`（如 `rob_commit_valid`、`rob_commit_uop_type`）；`ftq_{rob,prf}_pc_req_req_*` / `_resp_resp_*` → `ftq_{rob,prf}_pc_req_*` / `_resp_*`（只改名字，周期不变）。
- 2026-11-29 清理 D：去重——`ftq_ibuf_pkg` 新增 `FTQ_PC_BANKS = 8`（`ftq_pc` 的 `NB` 改为引用它）和 `ftq_in_window(idx, base)`（`idu` 与 `rob_core` 各写了一份的 8 项窗口检查，原为字面量位切片 `[FTQ_IDX_WIDTH-1:3]`）（周期不变）。
- 2026-11-29 清理 C：删 EXP-051 2-taken 双块残留（EXP-070 起不再产生，S0 / S2 写入的 `is_pair` 恒 0）：`ftq_pc` 删 `base_b / fa_pair_v / b_len / is_pair / a_len` 字段、`s0_pair` / `s2_is_pair` 入口与 `ifu_pair / ifu_next_b_idx / pd_is_pair / pd_base_b / pd_a_len` 出口、`ent_pc` / 分派 pc 的 B 块分支、`ent_next_pc`（只在双块不连续时才不返回 `next_pc`）；由此只剩它读的 `nslots` 字段、`pd_nslots` 入口和 `mispred_off` 入口一并删除（`ftq_pc_ent_t` 240 → 161 位）；`ftq_meta` / `ftq_meta_entry_t` 删 `is_pair / a_len`（SRAM 79 → 74 位），`ftq_bpu` 删 `is_pair / a_len`（`id_q` 只存块号），两处 `blk_id + 1` 的 B 块选择随之删除；`ftq_ibuf.sv` 删相应连线和 `ftq2fe` 字段（周期不变）。
- 2026-11-28 清理：删 `ftq_prf_pc_req_req_valid` / `ftq_rob_pc_req_req_valid` 输入与 `ftq_prf_pc_resp_resp_valid` / `ftq_rob_pc_resp_resp_valid` 输出（响应 valid 只是请求 valid 的回传，`back_top` 无人读）；`mdp` 不再读 `LSU_MEMSPEC`（写死开，删 `g_off`）；`ftq_ibuf_pkg` 删未用的 `FTQ_COUNT_W`、`COMMIT_CNT_W`；删不抑制任何告警的 lint 豁免（`ftq_ibuf.sv` 2 处、`ftq_meta.sv` 1 处、`ftq_pc.sv` 2 处，以去掉豁免后整树 lint 普通 / `-DSYNTHESIS` 均无新告警为准）（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`）：文档按现行 RTL 重写（第 1–9 节；旧正文描述的是 EXP-070 之前 / 删除分支标签之前的结构）。
- 2026-11-26（`rtl/area-opt`）：`pre_idu_queue` 改名 `ftq_ibuf`；`ftq_pc` 将 `slot_pc_q[64][16]`（65,536 FFs）压缩为 `{pc0, base_b, carry, is_pair, a_len}`（8,576 FFs，**−86.9%**）并在误预测时回填 `next_pc`/`nslots`；`ftq_pc`/`ftq_meta` 按 `idx[2:0]` 组织为 8-bank 连续读窗（Commit+ROB 共用 1 组 `8×8:1`、Dispatch 共用 1 组 `8×8:1` 32b PC），配合 `isu`/`prf`/`trace-model` 将 PC-ALU 限制在 Port 0 & Port 2，全随机 `64:1` FTQ 读口由 25 个降至 **4 个**（2 PC-ALU + 2 BRU）。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`pre_idu_ftq_pc` 新增 `nslots_q` 与双块不连续 `rd_next_pc` / `dis_pc`；`pre_idu_ftq_bpu` 删除 168 位 `bpu_ck`，改为按精确 `idu_br_latch_ftq_offset` 直接索引 `{blk_id[16], kind[16]}` 输出 `out_rf_blk`/`out_rf_type`。Yosys 综合 `pre_idu_queue` 137,578 单元 / 38 层（原 123,508 / 39）；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗检查点对齐。
- `git log --oneline 261bd67..HEAD -- rtl/backend/pre_idu_queue`：本分支没有对本模块的提交；FLUSH_REG（`803692f`）只改了 `back_top` 的连线，使 `rob_bcast_flush` 到本模块晚一拍。更早：见 git 历史。

更早的升级说明（原文保留，未按现行 RTL 逐条核对；与第 1–9 节冲突时以正文为准）：

**EXP-070 Unified FTQ-64（统一前端/后端 FTQ）升级**：
- 原前端独立的 `fetch_addr_fifo`、`ptab` 与 `front2back_fifo` 全部撤销并统一合入 `ftq_ibuf` 的 64 项 FTQ（`ftq_ptr` 新增 BPU 写指针、ICache 取指读指针、Predecode 校验读指针与后端提交头指针四指针协调，同步支持 BPU S2/S3 override 丢弃尾项）；
- `ftq_pc` / `ftq_meta` / `ftq_bpu` 在 BPU 预测期直接写入、取指/预译码期回填并供后端 PRF/ROB/提交/误预测恢复读取，彻底消除原 `ptab_bypass` 与 `f2b` 双重缓冲开销。

**2026-11-26 `rtl/area-opt` 重命名、8-Bank 窗与接口统一**：
- 模块由 `pre_idu_queue` 正式重命名为 `ftq_ibuf`（端口同步统一为 `front2ftq_*`、`ftq2front_*`、`ibuf2idu_*`），删除全部已固化参数开关；
- `ftq_pc`（64 项 × 134b 紧凑基址+偏移）与 `ftq_meta` 改为 8-Bank 布局共享 8:1 提交/分派窗，PRF PC 读口收敛为 2 个 PC-ALU 口 + 2 个 BRU 口（共 4 口）；TSMC 28nm DC 综合面积由原 `pre_idu_queue` `1,684,992 µm²` 降至约 `211k µm²`（**−87.5%**）。

**EXP-053 前端结构清理（Phase 1 + P2-2）升级**：
- 删除 `pre_idu_ftq_meta` / `pre_idu_pkg` 中不再使用的死线 `tage_idx[1..3]`、`tage_tag` 及 `ftq_commit_info_resp_valid_t`，仅保留 10-bit `blk_id`；
- `ib_entry_t` 与 `pre_issue_entries` 新增显式 1-bit `pf_inst_hi`，直通送给 `idu -> ren -> dis -> rob`（替代原 `inst` 编码搭便车）；单元数净减 **4.5%**，深度维持 38 层。

**EXP-051 里程碑 B 升级**：
1. `pre_idu_ftq_pc` 新增 `nslots_q[FTQ_SIZE]`：当 `pred_taken_q[idx][off] && off+1 < nslots_q[idx] && slot_pc_q[idx][off+1] != slot_pc_q[idx][off] + ilen` 时，`rd_next_pc` 返回 `slot_pc_q[idx][off+1]`（Block A 跳转后同组内续接 Block B）；`dis_pc[p]` 直接读 `slot_pc_q[dis_idx[p]][dis_off[p]]`（兼容不连续双块 PC）；
2. `pre_idu_ftq_bpu` 删除原 168 位 `bpu_ck` 存储，仅存 `{blk_id[16], kind[16]}`；误预测恢复直接按 4 位 `idu_br_latch_ftq_offset`（由 `prf -> exu_ctrl -> idu_br_latch` 透传）索引 `rec.blk_id[rd_offset]` 与 `rec.kind[rd_offset]`，彻底消除同 PC 在 Block A 与 Block B 中重复出现时的 PC 扫描歧义并省去 16×64b 比较器，输出 `out_rf_blk[9:0]` 与 `out_rf_type[2:0]` 供 BPU 内部 `rec_q[256]` 修复。
