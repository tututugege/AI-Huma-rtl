# bpu 设计笔记（分支预测单元）

分析与边界见 `docs/analysis/bpu-boundary.md`（子部件、状态规模、死代码清单、录制方案）。本文是 RTL 设计笔记：硬件结构、一拍数据流、与 C++ 的差异、放宽/删除/不复刻清单、验证。

## 1. 对应的 C++

- `front-end/BPU/BPU.h`（`BPU_TOP`）、`dir_predictor/TAGE_top.h`（`TAGE_TOP`）、`target_predictor/BTB_top.h`（`BTB_TOP`）、`type_predictor/TypePredictor.h`；前端调用见 `front_top.cpp` S4（`bpu_seq_read` → `bpu_comb_calc`，`front_seq_write` 里 `bpu_seq_write`）。
- 输入（顶层）：`BPU_TOP::InputPayload`；输出：`OutputPayload`。字段取舍见 `spec/bpu.io` 文件头与 §4。
- RTL 只翻译默认配置下生效的部分：`ENABLE_TAGE_SC_L=0`、`ENABLE_TAGE_LOOP_PRED=0`、`ENABLE_TAGE_SC_LITE=0`、`ENABLE_TAGE_SC_PATH=0`、`FRONTEND_DISABLE_2AHEAD`（NLP/2-ahead/mini-flush）、`SRAM_DELAY_ENABLE` 未定义。死代码清单与依据见 analysis §4。

## 2. 硬件结构

```
 refetch/addr/icache_ready ─► bpu_ctrl ──► lane_pc[8], lane_valid[8], going_to_do_pred, pc_q ◄── next_pc
                                  │
   lane_pc ──► bpu_type (8bank×512×2) ──► lane_type[8]
                                  │
   per bank b: pred_req/bank_pc/type ─┬─► bpu_tage (8 bank: base+4×{tag,cnt,useful}, LSFR, reset_cnt, use_alt)
                                      └─► bpu_btb  (8 bank: 4-way BTB, BHT, TC, TC-pre, tc_mode)
   commit lanes ──► bpu_uq (8 bank × 1 entry) ──► TAGE/BTB update ports (next cycle)
   commit lanes + lane info ──► bpu_hist (Spec/Arch GHR+FH, RAS) ──► fh ──► bpu_tage ;  ras_top ──► bpu_pred
   bpu_pred: first taken lane -> next_pc = RET&&ras ? ras_top : btb target, else boundary
```

| 模块 | 职责 | 关键状态 |
| --- | --- | --- |
| `bpu` | 端口适配 + 连线（无逻辑）| — |
| `bpu_ctrl` | `pred_base`、边界、8 个 lane 的 pc/有效、`going_to_do_pred`、取指 pc 寄存器 | `pc_q` |
| `bpu_type` (+`bpu_type_lane`) | 类型预测：8 预测 lane + 8 更新 lane | 两个 `bpu_mem`（每路一个），4096×16b |
| `bpu_tage` (+`_bank/_pred/_upd`) | 8 bank TAGE | 每 bank：`base`1024×2b，4×{tag 8b,cnt 3b,useful 2b}×1024，LSFR 4b，`reset_cnt` 24b，`use_alt` 4b |
| `bpu_btb` (+`_bank/_pred/_upd/_pkg`) | 8 bank BTB | 每 bank：4 路 256×44b，BHT 128×8b，TC/TC-pre 2 路 128×46b，`tc_mode` 128×3b |
| `bpu_hist` (+`_stage/_step`, `bpu_ras`, `bpu_ras_step`) | Spec/Arch GHR(119b)/FH(12 个 ≤11b)、RAS(2×32×32b) | 见分析 §3.5 |
| `bpu_uq` | 提交更新队列（单项寄存器）| 每 bank `{valid, 142b}` |
| `bpu_pred` | lane 的 taken/元数据选择、下一取指地址 | — |
| `bpu_mem` | 寄存器堆式阵列原语（N 异步读口、N 同步写口，后口覆盖前口）| — |

`bpu_mem` 说明：规范要求 `*_q/*_d` 两段式，但 TAGE/BTB/类型表合计 ~10^6 位，`mem_d` 全拷贝每拍会让仿真慢两个数量级，所以阵列用"写使能/地址/数据 + 同步写"的存储原语（always_ff 只含复位循环与 `mem_q[addr] <= data`），写使能/地址/数据全部来自 always_comb。这是**有意的偏离**，已在 §4 登记。

## 3. 一拍内的数据流

C++ 的 `bpu_comb_calc` 是 pre-read → data-read → post-read → submodule-read → core-comb；因为所有存储"读旧值、沿上写"，RTL 就是一次组合求值：

1. `bpu_ctrl`：`base = refetch ? refetch_address : pc_q`；`boundary`；`lane_pc/lane_valid`；`going_to_do_pred = icache_read_ready || refetch`。
2. `bpu_type`：8 个预测 lane 读表得 `lane_type`（同拍的 8 个更新 lane 读同一旧表，写在沿上，后 lane 覆盖）。
3. 每个 bank 的请求：第 i 个 lane 落在 `pc_i[4:2]` 号 bank（一个取指组 8 个 lane 恰好覆盖 8 个 bank），`bank_pc = pc_i >> 3`，`type` 为该 lane 的类型。
4. TAGE：`idx/tag` 由 Spec FH 与 bank pc 得到 → 读表 → provider/alt；BTB：BTB 组、BHT→TC 索引→TC/TC-pre/mode → 目标。
5. `bpu_pred`：`lane_taken`、元数据、第一个 taken lane 的目标（RET 且 RAS 非空取栈顶）→ `next_pc`。
6. `bpu_hist` 用 `lane_taken/lane_type` 与本拍提交 lane 更新 Spec/Arch 历史与 RAS；`bpu_uq` 收下本拍提交 lane（每 bank 第一条）并在下一拍作为 TAGE/BTB 更新输入。
7. 沿上：`pc_q`、所有阵列、历史、RAS、队列寄存器、TAGE 的 LSFR/`reset_cnt`/`use_alt` 更新。

没有 stale 读、没有同拍多次求值/累加（C++ 只有一次 `bpu_comb_calc`）。更新与预测同拍时预测读旧值（无旁路），与 C++ `seq_write` 在拍末的语义一致。

## 4. 与 C++ 的差异、放宽、删除、不复刻

### 4.1 隐含依赖 / 偏差登记（均无功能偏差）
1. **更新队列 Q_DEPTH=2 → 每 bank 单项寄存器**：C++ 每拍先弹后压，占用恒 ≤1（`bpu_boundary.md` §3.6，cov `qmax=1`；归纳：弹后 count ≤ 0，压入最多 1）；"同拍同 bank 多条只收第一条"的丢弃规则**保留**。`q_wr/rd_ptr`、`count`、`update_queue_full` 不建。
2. **`bank_pc = pc>>3` 与 BTB 未命中目标 `bank_pc+4`**：C++ 的怪行为但改变取指地址（预测为跳转而 BTB 未命中时），**按位复刻**（`bpu_btb_pred`：`pc_plus4 = bank_pc + 4`）。
3. **BHT 是 8 位**（`bht_hist_t = wire7_t = uint8_t`），所有 BHT 运算按 8 位截断（`bpu_btb_pkg`）。
4. **TAGE 表复位全 0，tag=0 与 hash 出的 tag 0 命中**：存储复位为 0 即可复现。
5. **RAS 用环形缓冲实现**（基指针 + count）：C++ 是移位数组；只读 `[0,count)`，二者等价（分析 §3.5）。`push` 满栈覆盖最老、`pop` 只减计数不清数据。
6. **GHR 只存 119 位**：`FH` 更新只读 `GHR[ghr_length-1]`（最大 118），TAGE 不读 GHR（`ghr_in` 只被 SC-L 读）。
7. **`reset_cnt` 24 位**：C++ 是 32 位，只读 bit 0..23。
8. **`bpu_mem`**（§2）。

### 4.2 放宽（spec 的 `when`）及消费者核对（顶层 `bpu.io`）
| 信号 | `when` | 消费者核对 |
| --- | --- | --- |
| `fetch_address` | `icache_read_valid` | 唯一读取点 `front_top.cpp:1429`（`normal_write_enable = icache_read_valid && bpu_can_run && !reset` 保护）；`1475` 的旁路读取在 `FRONTEND_ENABLE_FETCH_TO_ICACHE_BYPASS` 未定义下 `can_bypass_fetch_to_icache=false`，死 |
| `predict_next_fetch_address`、`out_pred_dir/alt_pred/pcpn/altpcpn/tage_tags/tage_idxs` | `ptab_write_enable` | 只经 `front_ptab_write_comb`（748–786），函数开头 `if (!ptab_can_write) return;`，`ptab_can_write = PTAB_write_enable && …` |
| 子 spec `bpu_type.pred_type` | `pred_valid` | BPU 只在 `do_pred_on_this_pc` 的 lane 读 `pred_type`；无效 lane C++ 置 NONCTL（RTL 同样置，只是不比较）|
| 子 spec `bpu_btb.pred_target` | `pred_req` | `btb_pred_out_valid=pred_req`，BPU 读 `pred_target` 前判 `btb_valid` |
| 子 spec `bpu_hist.ras_top` | `ras_has` | 读取点 `bpu_predict_main_comb` 先判 `ras_has_entry_snapshot` |

`bpu_tage` 与 `bpu_uq` 的输出在"无请求/队列空"时**与 C++ 一样清零并严格比较**（没有 `when`），因为 `when` 要求同维度，而零门控只是几个与门。

### 4.3 删除的字段 / 状态
- **输入**：`in_altpcpn`（存进队列，`tage_update_comb` 从不读 `altpcpn`）、`in_sc_*`、`in_loop_*`（恒 0）、TAGE 子 spec 的 `ghr_in/path_in/sc_*/loop_*`、32 位 bank pc（只用 `[11:2]`）。
- **输出**：`out_sc_*`、`out_loop_*`（恒 0，集成层把 PTAB 的 sc/loop 接 0）、`update_queue_full`（恒 0，`front.out.commit_stall=0`）、`two_ahead_*`、`mini_flush_*`、`out_pred_base_pc`（== `fetch_address`，C++ 有 assert）。
- **状态**：NLP 表与 `nlp_*`/`saved_2ahead_*`/`saved_mini_flush_*`、`PATH`、`Spec/Arch_GHR[119..255]`、TAGE 的 `sc_ctr_table`、所有 `*_latch`/`state`/`do_*_latch`/`tage_done/btb_done`、`sram_delay_*`/`sram_prng_state`（**默认配置下不存在随机行为**，任务书说的"BTB PRNG 按位复刻"在这份配置里无对象；TAGE 的随机来源是 4 位 LSFR，已复刻）、`pc_can_send_to_icache`（恒 1）、BTB 的 `type_idx`/`BTB_TYPE_ENTRY_NUM`（无存储）。

### 4.4 选择不复刻的 C++ 行为
1. 所有"子模块状态机"（`S_IDLE/S_STAGE2/*_WAIT_DATA`）、流水 latch 与 done 信号：C++ 每拍写回 `S_IDLE`/0，无读者。
2. SRAM 延迟模型。
3. `assert(out_pred_base_pc == fetch_address)` 等自检。
4. NLP / 2-ahead / mini-flush 整套（`ENABLE_2AHEAD` 未定义）。
5. `refetch` 拍的预测结果：无副作用、输出被 `icache_read_valid/PTAB_write_enable` 屏蔽（RTL 仍按 `refetch_address` 作 base 计算，保持子部件录制一致，只是顶层不比较）。

### 4.5 提醒集成者
- BPU 每拍恰好求值一次，包括 `icache_read_ready=0`（被反压）的拍：此时不预测，但提交更新照常进队/更新历史。
- `icache_read_ready` 的真实含义是"fetch_addr FIFO 未满且 `bpu_can_run`"。
- `icache_read_valid = !refetch`（`pc_can_send_to_icache` 恒 1）。
- 顶层端口比 C++ 少：`in_altpcpn`、`in_sc/loop_*`、输出 `sc/loop`、`update_queue_full`；集成层把 PTAB 的 `sc_*/loop_*` 接 0、`commit_stall` 接 0。
- 提交的 8 个 lane 与 `bpu_uq` 的丢弃规则：同拍同 bank 的后续 lane 不更新 TAGE/BTB，但**类型预测器与历史/RAS 看到全部 8 个 lane**。

## 5. 验证

见下节表格（`docs/analysis/bpu-boundary.md` §6 为录制边界）。

### 5.1 spec（字段数）
`bpu` 23、`bpu_type` 6、`bpu_btb` 9、`bpu_tage` 17、`bpu_hist` 14、`bpu_uq` 21（含输入输出；顶层输入 13 项、输出 10 项）。全部有 `@` 表达式，可录制/可锁步。

RESULTS_PLACEHOLDER
