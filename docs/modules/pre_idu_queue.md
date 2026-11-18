---
module: pre_idu_queue
area: backend
rtl: rtl/backend/pre_idu_queue
model: trace-model back-end/PreIduQueue.cpp、back-end/InstructionBuffer.cpp、back-end/include/PreIduQueue.h、back-end/include/InstructionBuffer.h、back-end/include/FTQ.h（调度单元 `back.pre`，类 `PreIduQueue`，阶段 `comb_accept_front`、`comb_commit_info`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 39 层（pre_idu_queue，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# pre_idu_queue 设计文档

## 1. 职责

前端和后端之间的缓冲：一个指令缓冲（InstructionBuffer，环形 FIFO）和一个 FTQ（取指目标队列，Fetch Target Queue：每个取指块一项，存这个块里每条指令的 pc 和预测信息，直到块里最后一条退休）。每拍：

1. 接收：前端每拍最多送来一个取指块（16 个 slot，`front2pre_valid` 标出有效的）；FTQ 有空项并且指令缓冲放得下整块，就接收（`pre2front.ready` / `fire`）：块写进 FTQ 的尾部，其中的有效指令按顺序压进指令缓冲；
2. 发出：把缓冲里最老的 8 条给 IDU（`pre_issue`）；缓冲为空时，本拍刚接收的块直接当作发出组（旁路）；IDU 消耗的前缀（`idu_consume.fire` 的连续 1）从缓冲弹出；
3. 回收 FTQ：退休的指令里每有一条"块里最后一条"（`ftq_is_last`），FTQ 头部释放一项；
4. 服务 FTQ 的读：PRF 的 8 个读口（ALU / BRU 的 pc）、ROB 的 1 个读口（队头 pc）、退休的 8 个读口（BPU 训练用的 pc、预测方向、TAGE 元数据）、分派的 8 个读口（`is_rvc` 和 load 的等待表下标 `mdp`）、误预测恢复读口（BPU 修复记录）；
5. 冲刷 / 误预测：全局冲刷清空缓冲和 FTQ，并且**下一拍**不接收；误预测（IDU 的 `br_latch`）清空缓冲，FTQ 里丢掉比出错分支所在块更年轻的块，当拍不接收。

模型对应一个调度单元 `back.pre`（`comb_accept_front`：接收和发出；`comb_commit_info`：退休信息）。RTL 的子模块边界是为综合划的，模型里没有对应的类。

## 2. 配置（`ttg_cfg_pkg` / `pre_idu_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| 前端每拍最多送的指令数（取指块 slot 数） | 16 | `BACKEND_FETCH_WIDTH`（`FETCH_WIDTH` 也是 16） |
| 发给 IDU 的组宽 | 8 | `DECODE_WIDTH` |
| 指令缓冲项数 | 64 | `IDU_INST_BUFFER_SIZE` |
| FTQ 项数 | 64（每项一个取指块） | `FTQ_SIZE`，`FTQ_IDX_WIDTH = 6` |
| FTQ 项内 slot 下标 | 4 位 | `FTQ_OFFSET_WIDTH` |
| FTQ 的 pc 读口 | PRF 8 + ROB 1 + 退休 8 = 17；另有分派的 8 个 `is_rvc` / `mdp` 读口 | `FTQ_PRF_PC_PORT_NUM`、`FTQ_ROB_PC_PORT_NUM`、`COMMIT_WIDTH`、`DECODE_WIDTH` |
| TAGE 元数据 | 每个 slot：4 张表的下标（各 10 位）和 tag（各 8 位）、`alt_pred` 1 位、`pcpn` 3 位 | `pre_idu_pkg`：`TAGE_N`、`TAGE_IDX_W`、`TAGE_TAG_W`、`PCPN_W` |
| 指令缓冲旁路 | 开（缓冲空时本拍接收的组直接发出） | `FE_RFAST = 15`，位 3（值 8）；`pre_idu_ibuf` 的参数 `BYPASS` |
| 等待表下标 | `pc` 的两段异或，各 6 位，从 `SLOT_SHIFT = 1` 起 | `LSU_MDP_BITS`、`SLOT_SHIFT`，仅 `LSU_MEMSPEC != 0` |

## 3. 接口

信号组按模型的 `in` / `out` 命名；顶层 `pre_idu_queue.sv` 只做端口和结构体互转并连接子块。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `front2pre_{valid, inst, pc, page_fault_inst, predict_dir, is_rvc}[16]`、`front2pre_predict_next_fetch_address` | 前端送来的取指块；`inst` 是已展开成 32 位的指令字（压缩指令在 `rtl/frontend/rvc_expand.sv` 展开） |
| 入 | `front2pre_{alt_pred, pcpn, tage_idx, tage_tag}`、`front2pre_bpu_ck`、`front2pre_slot_kind` | BPU 训练元数据（每 slot）和 BPU 修复记录（历史检查点、每 slot 的 BPU 类别） |
| 入 | `idu_consume_fire[8]`、`idu_br_latch_{mispred, ftq_idx, br_pc}` | IDU 消耗了哪些；误预测和出错分支的 FTQ 下标、pc |
| 入 | `rob_bcast_flush` | 全局冲刷（`FLUSH_REG` 后晚一拍，docs/FLUSH_REG.md） |
| 入 | `rob_commit_commit_entry_{valid, uop_ftq_idx, uop_ftq_offset, uop_ftq_is_last}[8]` | 退休的指令 |
| 入 | `ftq_prf_pc_req_*[8]`、`ftq_rob_pc_req_*[1]`、`ftq_dis_req_{ftq_idx, ftq_offset}[8]` | FTQ 读请求 |
| 出 | `pre2front_{ready, fire[16]}` | 前端的握手 |
| 出 | `pre_issue_entries_{valid, inst, page_fault_inst, ftq_idx, ftq_offset, ftq_is_last}[8]` | 发给 IDU 的最老 8 条 |
| 出 | `ftq_prf_pc_resp_*[8]`（pc、预测方向、`is_rvc`、`next_pc`）、`ftq_rob_pc_resp_*[1]`（pc、`is_rvc`） | FTQ 读响应；组合读寄存的 FTQ |
| 出 | `ftq_commit_info_resp_*[8]` | 退休指令的 pc、预测方向、`is_rvc`、`alt_pred`、`pcpn`、TAGE 下标和 tag |
| 出 | `ftq_dis_resp_{mdp, is_rvc}[8]` | 分派需要的 `is_rvc` 和 load 等待表下标 |
| 出 | `out_rf_{ck, epoch, type}` | 误预测修复用的 BPU 记录（按出错分支的 FTQ 下标和 pc 读） |

## 4. 结构

```
 front2pre ─► pre_idu_ctrl : ready / fire / alloc、块内有效指令的序号（lane_rank）、块尾 lane、弹出数
              ├► pre_idu_ibuf     : 64 项环形缓冲；写入按序号压紧；读最老 8 项；可旁路
              ├► pre_idu_ftq_ptr  : FTQ 的尾指针和占用数
              ├► pre_idu_ftq_pc   : 每项 16 个 slot 的 pc、预测方向、is_rvc、块的 next_pc；17 + 8 个读口
              ├► pre_idu_ftq_meta : 每项 16 个 slot 的 TAGE 元数据；8 个退休读口
              └► pre_idu_ftq_bpu  : 每项的 BPU 修复记录；1 个读口
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `pre_idu_queue.sv` | 254 | 顶层：端口适配；FTQ 读口的编号（PRF、ROB、退休）；分派读口的 `mdp` 哈希 |
| `pre_idu_ctrl.sv` | 79 | 握手和计数：`ready`、`fire`、`alloc`、块内序号、IDU 消耗前缀、FTQ 弹出数 |
| `pre_idu_ibuf.sv` | 126 | 环形缓冲、旁路 |
| `pre_idu_ftq_ptr.sv` | 63 | FTQ 的尾指针、占用数 |
| `pre_idu_ftq_pc.sv` | 70 | FTQ 的 pc 存储和读口 |
| `pre_idu_ftq_meta.sv` | 35 | FTQ 的训练元数据存储 |
| `pre_idu_ftq_bpu.sv` | 60 | FTQ 的 BPU 修复记录 |
| `pre_idu_pkg.sv` | 47 | 常量、元数据和缓冲项的结构体 |

状态：缓冲的 `head_q`、`tail_q`、`count_q`、`entry_q[64]`（每项 `ib_entry_t`：指令字 32 位、缺页 1 位、FTQ 下标 6 位、slot 下标 4 位、块尾 1 位）；FTQ 的 `tail_q`、`count_q`；FTQ 存储 `slot_pc_q[64][16]`、`pred_taken_q[64]`、`is_rvc_q[64]`、`next_pc_q[64]`、`meta_q[64][16]`、`rec_q[64]`；`flush_prev_q`（上一拍的冲刷）。存储类寄存器没有复位：一项只有在被分配后才会被读。

## 5. 一拍内的数据流

### 5.1 接收

`ready = !idu_br_latch_mispred & !flush_prev_q & (ftq_count < FTQ_SIZE) & (块内有效指令数 <= 缓冲空闲数)`；`fire = front_valid & ready`；`alloc = ready & 块内至少一条有效`。接收时：

- FTQ 项写在 `ftq_tail`：每 slot 的 pc、预测方向、`is_rvc`、块的 `predict_next_fetch_address`，另有 TAGE 元数据和 BPU 修复记录；
- 缓冲：块里第 j 条有效指令（序号 `lane_rank`）写在 `tail + j`；每条带 `ftq_idx = ftq_tail`、`ftq_offset` = 它在块里的 slot 下标、`ftq_is_last` = 块里最后一条有效指令。

`flush_prev_q` 是 `rob_bcast_flush` 的寄存值：冲刷后的下一拍不接收（模型 `q.flush_q`）。注意这个 `rob_bcast_flush` 本身已经是 `FLUSH_REG` 后的晚一拍信号，所以从 ROB 决定冲刷算起，是第 3 拍才重新接收。

### 5.2 发出和弹出

- 发出组：缓冲非空时是 `entry_q[head + i]`（`i < count` 才有效）；缓冲为空且旁路开时，是本拍接收的组（第 i 条有效指令作为发出组的第 i 条）。
- 弹出：`pop_cnt` = `idu_consume_fire` 的连续 1 的个数；`head += pop_cnt`，`tail += push_cnt`，`count += push_cnt - pop_cnt`。旁路时本拍接收的组仍然整个写进缓冲，再由 `head` 前进跳过被消耗的（效果等同模型的"跳过前 `pop_count` 条再压入"）。
- 冲刷或误预测：`head`、`tail`、`count` 清零（缓冲存储不清）。

### 5.3 FTQ 的回收与恢复

- `tail`、`count`：接收 `+1`；退休里每有一条 `ftq_is_last`，`count -= 1`（`ttg_popcount`）；
- 误预测：`tail := 出错分支的 ftq_idx + 1`，`count -= (旧 tail - 新 tail)`；
- 冲刷：`tail`、`count` 清零；
- 优先级：冲刷 > 误预测 > 正常；冲刷和误预测时不弹出。

### 5.4 读口

- PRF、ROB、退休的 pc 读：按各自请求的 `(ftq_idx, ftq_offset)` 从 `slot_pc_q` 等组合读寄存器（17 个读口，每口 64 项 × 16 slot 的选择）；`next_pc` 是块的预测下一个取指地址，与 slot 无关。
- 退休读 TAGE 元数据（`meta_q`）：按退休指令自己的 `ftq_idx` 和 `ftq_offset` 读。
- 分派读：`is_rvc_q[ftq_idx][ftq_offset]`；`mdp` 由 pc 算：`pc = slot 0 的 pc`（`ftq_offset` 为 0）或 `slot 1 的 pc + (ftq_offset - 1) << SLOT_SHIFT`（RVC 打开时，slot 0 可能是跨前一个块拼成的指令，pc 与其他 slot 不连续），`mdp = pc[SLOT_SHIFT +: 6] ^ pc[SLOT_SHIFT + 6 +: 6]`；这样每个读口只选一个 64 项的基址，不用 512 项的选择。
- 误预测修复读：`rec_q[idu_br_latch_ftq_idx]` 取历史检查点和各 slot 类别，再用出错分支 pc 与块基址的差找出它的 slot。

## 6. 关键路径与深度

单模块综合深度 **39 层**（pre_idu_queue；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\front2pre_valid [1]` 到 `\u_ibuf.buf_entry [351]`。

从代码读出的长组合链（未综合验证）：

| 链 | 经过 |
| --- | --- |
| 接收 | `br_latch.mispred`（寄存）、`flush_prev_q`（寄存）、`ftq_count`（寄存）、缓冲空闲数 + 前端有效数（popcount）→ `ready` → `fire` / `alloc` → FTQ 和缓冲的写使能；`ready` 对前端是组合输出 |
| 缓冲写 | 每个 lane 的 `tail + lane_rank` → 64 项里每项比较 16 个 lane → 写数据 16 选 1 → `entry_q` |
| 旁路发出 | `front_valid` → 每 lane 的序号（popcount）→ 发出组第 i 条的 16 选 1 → `pre_issue_entries_*` → IDU 译码（IDU 的 `consume_fire` 又回到这里的弹出） |
| 弹出 | `idu_consume_fire` → 连续 1 前缀（8 级串联与）→ popcount → `head_d` / `count_d` |
| FTQ 读 | 请求的 `(ftq_idx, ftq_offset)`（来自 PRF、ROB、退休）→ 64 × 16 的 pc 选择；分派读口 + `mdp` 哈希 |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `uop_alloc()` / `uop_id`、`pc`、`is_rvc`（缓冲项里的）：模型的 uop 池用的；RTL 缓冲项没有 pc 和 `is_rvc`（需要时向 FTQ 读）；
- FTQ 的 `head`、`ftq_valid[]`：模型有，RTL 只维护尾指针和占用数（"项只通过下标访问，头指针没有人读"，`pre_idu_ftq_ptr.sv` 注释）；`comb_commit_info` 里模型用游标从头走并断言与退休的 `ftq_idx` 相等，RTL 直接用退休指令自己的下标读，对所有可达的输入结果相同；`resp` 在模型里受 `ftq_valid[idx]` 限定，RTL 不限定（`resp.valid` 取退休的 valid）；
- 模型的 `FtqPc::next_pc` 里 `FE_PAIR` 一拍取两块的修正：`FE_PAIR` 只在模型里、默认关（`include/config.h` 注释），RTL 没有；
- 模型对 BPU 修复用 `ftq_blk_id` / `ftq_slot_pc` / `ftq_slot_rvc`（`BPA_REPAIR`）；RTL 存的是另一种形式的记录（历史检查点 `bck`、每 slot 类别 `kind`、块基址相对位置 `base_rel`，`pre_idu_ftq_bpu`），读出 `out_rf_{ck, epoch, type}`。两者是否在所有情况下等价，没有逐项核对，只靠整核周期相等间接保证（见下）；
- `ftq_commit_info_resp_valid_t` 是 8 × 4 个相同的副本（`resp_valid[i]` 的 4 份），是端口遗留。

RTL 与模型保持一致的细节（读模型时容易误判）：

- `pre2front.ready` 在误预测那一拍和冲刷的下一拍为 0，且那时 `fire` 也为 0；
- 一个块整体接收或整体不接收；
- 缓冲为空时本拍接收的组立刻可发（旁路），模型的 `push_bypass`；
- 退休读的 TAGE 元数据在退休那一拍读，FTQ 项要等块里最后一条退休后才释放。

已发现、未改动的点：

- `pre_idu_ctrl.sv` 的注释写"见 docs/modules/pre_idu_queue.md section 4"，那是旧文档的章节号；
- `pre_idu_ftq_pc` 对 17 个读口都是 64 × 16 项的完整选择（读 `slot_pc_q`），只有分派读口做了"基址 + 偏移"的省面积写法；

**未核对（继承自旧文档）**：无（旧文档的内容全部没有采用）。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）：67/67 通过，周期逐个相等。FTQ 记录是否正确，通过 BPU 训练（退休信息）和误预测修复对预测准确率和周期的影响间接检查。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**。旧体系（`spec/` 的 trace 回放、随机 trace、变异检查）已退役；`tests/` 里没有针对本模块的测试。**待补**：给缓冲（含旁路与弹出）、FTQ 指针（恢复、回收）各补一个新旧并排的随机测试；给 BPU 修复记录补一个与模型 `ftq_blk_id` 等逐项比较的测试。

## 9. 参数与开关速查

`BACKEND_FETCH_WIDTH`、`DECODE_WIDTH`、`COMMIT_WIDTH`、`IDU_INST_BUFFER_SIZE`（2 的幂）、`FTQ_SIZE`（2 的幂）、`FTQ_PRF_PC_PORT_NUM`、`FTQ_ROB_PC_PORT_NUM`、`FE_RFAST[3]`（缓冲旁路）、`LSU_MEMSPEC` / `LSU_MDP_BITS`（`mdp`）、`SLOT_SHIFT`、`RVC_ENABLE`。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 10. 变更记录

`git log --oneline 261bd67..HEAD -- rtl/backend/pre_idu_queue`：本分支没有对本模块的提交；FLUSH_REG（`803692f`）只改了 `back_top` 的连线，使 `rob_bcast_flush` 到本模块晚一拍。更早：见 git 历史。
