# BPU（`BPU_TOP`）内部结构、边界与翻译方案（分析报告）

> 基线：参考模型 `baseline-sim/src/front-end/BPU/`（`BPU.h` 2068 行、`TAGE_top.h` 1893、`BTB_top.h` 1432、`TypePredictor.h` 434、`BPU_configs.h` 261），
> 前端调用方在 `front_top.cpp`。所有行号指未加钩子的原版。标注 **[已验证]** 的结论来自 `tests/bpu/cov.cpp`（读 `g_bpu_top` 的探针插件，
> dhrystone 前 100 万拍，见 §8）；其余是读代码得出。本文取代 `frontend-boundary.md` §4.6 里"未核实"的各项。

## 0. 摘要

1. **默认配置下真正生效的是**：8 个 bank 的 TAGE（基础表 + 4 张带 tag 的表，无 SC/loop）、8 个 bank 的 BTB（4 路 BTB + BHT + 间接跳转 TC/TC-pre/mode）、
   一个类型预测器（`TypePredictor`，8 bank × 512 组 × 2 路）、RAS（Spec/Arch 两份，深度 32）、Spec/Arch 两份全局历史（GHR + 3×4 折叠历史 FH）、
   提交更新队列（8 bank），以及把它们粘起来的"取指组预测"（取第一条预测跳转的目标）。
2. **死代码很多**（§4）：NLP/2-ahead/mini-flush（`FRONTEND_DISABLE_2AHEAD`）、TAGE 的 SC-L/SC-Lite/loop/path、各子模块的"状态机"
   （`S_IDLE/S_STAGE2/…` 恒回 `S_IDLE`，所有 `*_latch` 流水寄存器恒 0）、SRAM 延迟与 `sram_prng_state`（**不存在随机行为**，见 §4.3）、
   `pc_can_send_to_icache`（恒 1）、`update_queue_full`（恒 0）、PTAB 里的 SC/loop 元数据（恒 0）。
3. **BTB 的"未命中目标"是 `bank_pc + 4`，不是 `pc + 4`**（`BTB_top.h:btb_pred_output_comb`：`in.pc` 是 `pred_pc` = `pc >> 3`）。这是参考模型的怪行为，
   但会影响取指地址（预测为跳转但 BTB 未命中时，下一取指地址 = `(pc>>3)+4`，随后被 predecode checker 冲刷纠正），**有意义，必须按位复刻**。
4. **更新队列 Q_DEPTH=2 实为单级流水寄存器**（§3.6，[已验证] `qmax=1`）：每拍每个 bank 先弹出再压入，计数恒 ≤1；
   但**同拍多条提交落在同一 bank 时只有第一条被收下，其余丢弃**（`bank_enqueued`，真实程序里每 100 万拍 4 万次）——这是有意义的有损行为，必须复刻。
5. BPU 内部的 `Spec_*` 状态在 `refetch` 拍被 `Arch_*` 覆盖（含本拍提交对 Arch 的更新），误预测的条件分支提交会提前把 Spec 修成"该分支之后的 Arch"（§3.5）。
6. 录制：BPU 在 `front_top.cpp` 里是 `static BPU_TOP bpu_instance`，但 `g_bpu_top` 全局指针可读（插件 `private`=`public`），且每拍的子模块输入输出大多保存在
   `cpu.front.update_req_->bpu_seq_txn.req`（`tage_in[b]/btb_in[b]/type_in/tage_req[b].out_regs/btb_req[b].out_regs`）里，**可以录到每个子部件的边界**（§6）。
7. RTL 计划：`bpu`（顶层）= `bpu_ctrl`（取指组/bank 映射/下一地址）+ `bpu_type` + `bpu_btb`（8 bank）+ `bpu_tage`（8 bank）+ `bpu_hist`（GHR/FH/RAS）+ `bpu_uq`（更新队列）；
   每个子部件有独立 spec，可单独整程序锁步，便于二分（§6、§7）。

## 1. 配置核实（只翻译默认配置下生效的部分）

读 `config/frontend_feature_config.h` 与 `include/config.h`（`refsim_tap` 源码与基线逐字相同，构建带 `-DNDEBUG`）：

| 开关 | 值 | 含义 / 后果 |
| --- | --- | --- |
| `BPU_BANK_NUM` | 8 | bank = `pc[4:2]`；`FETCH_WIDTH=COMMIT_WIDTH=8`，一个取指组的 8 个 lane 落在 8 个不同 bank（连续 8 个字） |
| `ENABLE_BPU_RAS` | 定义 | RAS 生效；`RAS_DEPTH=32` |
| `SPECULATIVE_ON` | 定义 | TAGE 用 **Spec** 折叠历史预测 |
| `FRONTEND_DISABLE_2AHEAD` | 定义 | `ENABLE_2AHEAD` 不定义 → NLP、2-ahead、mini-flush 全死 |
| `ENABLE_TAGE_SC_L` / `ENABLE_TAGE_SC_PATH` / `ENABLE_TAGE_LOOP_PRED` / `ENABLE_TAGE_SC_LITE` | 0 | SC-L、loop、path 历史、SC-Lite 全死；`sc_*`、`loop_*` 输出恒 0 |
| `ENABLE_TAGE_USE_ALT_ON_NA` | 1 | use-alt 计数器生效（`TAGE_USE_ALT_CTR_BITS=4`，初值 7，阈值 8） |
| `ENABLE_BTB_ALIAS_HASH` | 1 | BTB/BHT/TC 用 hash 索引（§3.3） |
| `ENABLE_INDIRECT_BTB_FALLBACK/TRAIN`、`ENABLE_TC_TARGET_SIGNATURE` | 1 | 间接跳转：TC 未命中回退 BTB；IDIRECT 也训练 BTB；BHT 对 IDIRECT 用目标签名更新 |
| `SRAM_DELAY_ENABLE` | 未定义 | SRAM 延迟模型死（`sram_*` 恒 0，`sram_prng_state` 恒不变） |
| TAGE | `TN_MAX=4`，`TN_ENTRY_NUM=1024`(idx 10b)，`TAGE_TAG_WIDTH=8`，`BASE_ENTRY_NUM=1024`，`GHR_LENGTH=256`；`ghr_length={8,13,32,119}`，`fh_length={{8,11,11,11},{8,8,8,8},{7,7,7,7}}` | |
| BTB | `BTB_ENTRY_NUM=256`(idx 8b)，`BTB_TAG_LEN=8`，`BTB_WAY_NUM=4`，`BHT_ENTRY_NUM=128`，`TC_ENTRY_NUM=128`，`TC_WAY_NUM=2`，`TC_TAG_LEN=10`；`BTB_TYPE_ENTRY_NUM=4096` **只有索引计算，没有对应存储，死** | |
| 类型预测 | `TYPE_PRED_ENTRY_NUM=1024`，2 路 → 512 组/bank，tag 8b，conf 2b，age 2b | |
| 更新队列 | `Q_DEPTH=2`，每 bank 一队 | |

## 2. 与前端的接口

调用：`front_top.cpp` S4（1370–1389）：`bpu_instance.bpu_seq_read(inp, rd); bpu_comb_calc(inp, rd, out, req);`，结果 `req` 存进 `bpu_seq_txn`，
`front_seq_write` 里无条件 `bpu_seq_write(inp, req, reset)`。**每拍恰好调用一次，包括 BPU 被反压（`icache_read_ready=0`）的拍**。`reset` 只在 `FrontTop::init()` 出现。

### 2.1 InputPayload（`BPU.h:115-143`）

| 字段 | 来源 | 是否使用（默认配置）|
| --- | --- | --- |
| `refetch`、`refetch_address` | `global_refetch`、`refetch_address`（前端 `front_ctrl`）| 是 |
| `icache_read_ready` | `!fa_full_q && bpu_can_run`（名字有误导：不是 icache ready，是 fetch_addr FIFO 未满）| 是 |
| `in_upd_valid[8]`、`in_update_base_pc[8]`、`in_actual_dir[8]`、`in_actual_br_type[8]`、`in_actual_targets[8]`、`in_pred_dir[8]` | 后端提交（`back2front`）| 是 |
| `in_alt_pred/pcpn/altpcpn[8]`、`in_tage_tags/idxs[8][4]` | 后端回传的 PTAB 元数据 | 是（TAGE 更新）|
| `in_sc_*`、`in_loop_*` | 回传的 PTAB 元数据，**恒 0**（BPU 从不输出非 0，`cov` 里 `sc_nonzero=0`）| **否**，不进 spec |

### 2.2 OutputPayload（`BPU.h:145-178`）与消费者

| 字段 | 消费者（`front_top.cpp`）| 处理 |
| --- | --- | --- |
| `icache_read_valid` | S5 `normal_write_enable`（1411）→ fetch_addr FIFO 写；`front_ctrl` | 严格比较。`= pc_can_send(恒1) && !refetch` |
| `fetch_address` | fetch_addr FIFO 写数据（1429）；旁路路径死 | `when icache_read_valid`（FIFO 写使能含它）|
| `PTAB_write_enable` | PTAB 写（1706）、`front_ctrl` | 严格。`= going_to_do_pred && !refetch` |
| `predict_next_fetch_address`、`out_pred_dir/alt_pred/pcpn/altpcpn/tage_tags/tage_idxs[8..]`、`out_pred_base_pc` | 只经 `front_ptab_write_comb`（748–786）写入 PTAB，且受 `ptab_can_write = PTAB_write_enable & …` 保护 | `when PTAB_write_enable`。`out_pred_base_pc == fetch_address`（C++ 有 assert），RTL 只输出 `fetch_address`；**PTAB 写入时 `!refetch`，故 `fetch_address = pc_reg`** |
| `out_sc_*`、`out_loop_*` | 同上 | 恒 0，**不进 spec**（集成层把 PTAB 的 sc/loop 接 0）|
| `update_queue_full` | `front.out.commit_stall`（1859）| **恒 0**（`BPU.h:1428` 写死 false）；不进 spec，集成层 `commit_stall=0` |
| `two_ahead_*`、`mini_flush_*` | 2-ahead 死路径 | 不进 spec |

## 3. 内部结构与一拍内数据流

C++ 的 `bpu_comb_calc` 一拍内按固定顺序求值（`BPU.h:2000–2060`）：

```
bpu_pre_read_req_comb  → bpu_data_seq_read → bpu_post_read_req_comb → bpu_submodule_seq_read → bpu_core_comb_calc
  (pred_base_pc, 取指组,    (RAS 栈顶, 更新队列    (组装 TAGE/BTB/类型       (各子模块"读存储")      (类型预测 → bind → TAGE/BTB comb →
   lane/bank 映射,           读出, NLP 读[死])      预测与更新请求)                                  predict_main → hist → queue → pc 更新)
   going_to_do_pred/upd)
```

**所有存储都是"读旧值、时钟沿写"**：同拍的预测读不看同拍更新写（没有旁路）；每个状态数组一个写者（更新）。RTL 即 寄存器堆式阵列：异步读、同步写。

### 3.1 取指组与 bank 映射（`bpu_pre_read_req_comb`）

```
pred_base_pc = refetch ? refetch_address : pc_reg
boundary     = ((base & ~63) != ((base+32) & ~63)) ? ((base+32) & ~63) : base+32          (32 位回绕)
lane i: pc_i = base + 4i;  do_pred[i] = pc_i < boundary (无符号);  bank_sel[i] = pc_i[4:2]
going_to_do_pred = pc_can_send(恒1) && (icache_read_ready || refetch)
going_to_do_upd[b] = (q_count[b] != 0)
```
bank 的"bank pc"= `pc >> 3`（`bank_pc_comb`：`BPU_BANK_NUM=8` → 右移 3，**不是**右移 2）。TAGE/BTB 的 `pred_pc` 就是这个 29 位量，其内部再 `>>2`
（所以索引用 `pc[31:5]`，并非 `pc[31:2]`）。每个 bank 最多一个 lane（8 个 lane = 8 个连续字 = 8 个不同 bank），`pred_req_sent` 冲突检查恒不触发。

### 3.2 类型预测器（`TypePredictor.h`，`bpu_type`）

- 存储 `table[8 bank][512 set][2 way]`，C++ 条目 `{valid, tag[8], type[3], conf[2], age[2]}`（16 位），复位全 0。**`conf` 是死状态**（唯一读者是 `pred_confident` 输出，BPU 不读；变异检查中"conf 饱和值"变异无法被任何输出抓到，由此发现），RTL 条目只存 14 位。
- **预测**（8 路，lane i 有效时）：`bank=pc[4:2]`，`set=(pc>>5)&511`，`tag=(pc>>14)&255`；两路里第一个 `valid && tag==` 命中者给出 `type`，未命中 `BR_NONCTL(4)`。
- **更新**（8 个提交 lane，**直接用本拍 `in_upd_*`，不经更新队列**，读旧表）：命中→改写该路，未命中→选空路（第一个 `!valid`），否则 `age` 最小路（并列取低路）；
  `actual==NONCTL`：命中则**清空该条（写全 0）**，未命中不写；否则 `type` 相同则 `conf/age` 饱和加 1，不同则 `type=actual, conf=1, age=1`。
  多个 lane 写同一槽：**后面的 lane 覆盖前面的**（顺序写 `table[...]`），每个 lane 的新值都由旧表算出。
- BR 类型编码：`DIRECT=0 CALL=1 RET=2 IDIRECT=3 NONCTL=4 JAL=5`。

### 3.3 BTB（`BTB_top.h`，每 bank 一个，`bpu_btb`）

存储：`btb[4 way][256]{tag8, bta32, valid, useful3}`；`bht[128]`（**8 位**，因 `bht_hist_t=wire7_t=uint8_t`，所有 BHT 运算按 8 位截断）；
`tc[2][128]` 与 `tc_pre[2][128]`（各 `{target32, tag10, valid, useful3}`）；`tc_mode[128]`（3 位，初值 2）。
索引（全部 32 位无符号，`pw = pred_pc>>2`）：`hash(x,mask,w,salt)=(x ^ x>>w ^ x>>2w ^ x>>3w（仅当 kw<32） ^ salt) & mask`；
`btb_idx=hash(pw,255,8,0x9e3779b9)`，`btb_tag=(pw>>8)&255`，`bht_idx=hash(pw,127,7,0x6a5d39e1)`，
`tc_idx=hash(pw ^ hm ^ (b>>19),127,7,0x51ed270b)`，`hm=b^(b>>7)^(b>>13)^(b<<9)`（`b`=BHT 值），`tc_tag=hash(pw,1023,10,0x3c6ef372)`。
- **预测**（`pred_req`）：读 BTB 组、`bht[bht_idx]`→算 `tc_idx`→读 `tc`/`tc_pre` 组与 `tc_mode`；`hit`=第一个 `valid&&tag==`；
  `pred_target`：`IDIRECT`：`tc_pre` 命中且（`tc` 未命中 或 `tc_mode>=3`）→`tc_pre` 目标；否则 `tc` 命中→`tc` 目标；否则 BTB 命中→`bta`；否则 `pred_pc+4`；
  `DIRECT/CALL/JAL/RET`：BTB 命中→`bta`，否则 **`pred_pc+4`（`pred_pc` 为 bank pc！）**；`NONCTL`：`pred_pc+4`。`btb_pred_out_valid=pred_req`。
- **更新**（`upd_valid`，来自更新队列）：`type!=NONCTL` → 写 `bht[bht_idx]=next_bht`（`IDIRECT`：`(h^(h<<5)^(h>>2)) ^ (t^t>>11^t>>19) ^ 0x9e3779b9`，`t=target>>2`，截 8 位；其余 `(h<<1)|dir` 截 8 位）；
  `dir && writes_btb(DIRECT/CALL/RET/JAL/IDIRECT)` → 写 BTB：`way = hit ? hit_way : victim`（victim = 第一个空路，否则 `useful` 最小路取低者），
  `useful = IDIRECT ? 0 : (hit ? useful±1(饱和 0..7, 目标相同则+1) : 1)`；`dir && IDIRECT` → 写 `tc`（写索引用 `next_bht`）与 `tc_pre`（用旧 `bht` 索引），
  各自 命中路/victim 路，`useful`：命中 ±1，未命中 `INDIRECT_TC_INIT_USEFUL=1`；若 "`tc` 在旧索引处是否正确" ≠ "`tc_pre` 是否正确" 则 `tc_mode` 按 `tc_pre` 正确与否 ±1（饱和 0..6）。

### 3.4 TAGE（`TAGE_top.h`，每 bank 一个，`bpu_tage`）

存储：`base[1024]`(2b)、`tag/cnt/useful[4][1024]`(8/3/2b)，复位全 0（**`tag=0` 与 hash 出的 0 tag 会"命中"，需复刻**）；`LSFR[4]`(复位 `0001`，`LSFR[3]=1`)、`reset_cnt`、`use_alt_ctr`(4b，初值 7)。
- **预测**（`pred_req`，`pc` = bank pc）：`idx[i]=(FH0[i] ^ (pc>>2)) & 1023`，`tag[i]=(FH1[i]^FH2[i]^(pc>>2)) & 255`（FH 为 BPU 的 Spec 折叠历史，4 个 bank 共用）；
  `pcpn`=最高的 tag 命中表（无则 4），`altpcpn`=次高；`alt_pred = altpcpn<4 ? cnt[altpcpn]>=4 : base>=2`；`pred = pcpn<4 ? cnt[pcpn]>=4 : base>=2`，
  并且 `cnt[pcpn]==3 && useful[pcpn]==0 && use_alt_ctr<=8` 时 `pred=alt_pred`。输出 `pred/alt_pred/pcpn/altpcpn/tag[4]/idx[4]`，`pred_out_valid=pred_req`。
- **更新**（`update_en`，仅 `br_type==DIRECT` 的队列项）：读 `base`、`cnt/useful[idx_in[i]]`；provider（`pcpn<4`）：`useful` 按 `pred_in==real_dir` 等规则 ±1，`cnt` ±1（3b 饱和），use-alt 计数器按 provider/alt 谁对 ±1（饱和 0..15）；
  无 provider：`base` ±1（2b 饱和）；**`pred_in!=real_dir` 且 `pcpn<=2||pcpn==4`**：分配——从 `pcpn+1`（无 provider 则 0）起找第一个/第二个 `useful==0` 的表 j,k：
  无空表→这些表 `useful` 全部 -1；有空表→目标 = `(k 存在 && lsfr_rand%3==0) ? k : j`，写 `tag=tag_in[t]`、`cnt = real_dir?4:3`、`useful=0`。`lsfr_rand` 为**更新后** LSFR 的 `{next[0],next[1]}`（`%3==0` 即 0 或 3）。
  每次更新：LSFR 前移一位（`next[0]=b0^b3`，其余右移）、`reset_cnt++`；**周期性清 useful**：`reset_cnt[10:0]==0` 时对 4 张表各清一行（行 = `reset_cnt[20:11]`，`reset_cnt[23]` ? 只保留 bit0 : 只保留 bit1；
  若该表本次更新已写同一行的 `useful` 则跳过）。
- 注：`reset_cnt` 在 C++ 是 32 位，只读 bit 0..23，所以 RTL 用 24 位即等价。

### 3.5 历史与 RAS（`bpu_hist_comb`，`bpu_hist`）

状态：`Spec/Arch_GHR[256]`、`FH[3][4]`（`<=11` 位）、`PATH`（死）、`Spec/Arch_ras_stack[32]+count`。**GHR 只需低 119 位**（`FH` 更新只读 `GHR[ghr_len-1]`，最大 118）。
- FH 一步更新（`val`=旧值，`len`=`fh_length[k][i]`）：`val = ((val<<1)&mask(len)) | (new_hist ^ val[len-1])`，再 `^= GHR_old[ghr_len[i]-1] << (ghr_len[i] % len)`；GHR 同时 `<<1 | new_hist`。
- **Spec 预测更新**（`going_to_do_pred && !refetch`）：按 lane 顺序，对 `do_pred` 的 lane：类型 `DIRECT` → 用 `final_pred_dir` 做一步更新；**遇到第一个 `final_pred_dir` 为真的 lane 停止**（无论类型）。
  RAS：同一个"第一个 taken lane"：`CALL` → push `pc_i+4`，`RET` → pop。
- **Arch 提交更新**：8 个提交 lane 顺序：`DIRECT` → 用 `actual_dir` 做一步 Arch 更新；若 `pred_dir != actual_dir`，把 **Spec** 置为该步之后的值（**后面误预测的 lane 覆盖前面**）；`CALL` push `pc+4`、`RET` pop（Arch RAS）。
- **`refetch`**：`Spec_* = Arch_*`（用**本拍提交后**的 Arch），优先级最高。
- RAS：`push`：`count<32` → `stack[count++]=v`，满则整栈下移丢最老再放栈顶；`pop`：`count>0` → `count--`（**不清数据**）。栈顶 `stack[count-1]`（`count=0` 无）。
  RAS 栈顶读：`refetch ? Arch : Spec`。RTL 用**环形缓冲**（基指针 + count）等价实现（只读 `[0,count)`，移位与回绕不可区分）。

### 3.6 更新队列（`bpu_queue_comb`，`bpu_uq`）

每 bank 的队列：每拍**先弹**（`count>0` → 弹出队首并作为本拍 TAGE/BTB 的更新输入），**再压**：8 个提交 lane 中，对 `in_upd_valid` 的 lane 按顺序，若该 bank 本拍已压过 或 弹后 `count>=Q_DEPTH` 则**丢弃**，否则压入。
因为每拍都弹，`count` 恒 ≤1 [已验证 `qmax=1`]：**队列 = 每 bank 一个 valid+payload 寄存器**（写入拍的下一拍用于更新），`Q_DEPTH=2` 的满条件不可达，`update_queue_full` 恒 0。
条目内容 = 提交 lane 的 `{base_pc, dir, br_type, target, pred_dir, alt_pred, pcpn, altpcpn, tags[4], idxs[4]}`（`sc/loop` 死）。`base_pc` 只用于 `bank_pc = base_pc>>3`（29 位）。
TAGE 更新输入仅当 `br_type==DIRECT`；BTB 更新输入对任意类型给出（`NONCTL` 时无写）。

### 3.7 主预测与下一取指地址（`bpu_predict_main_comb`、`bpu_core_comb_calc`）

lane i（`going_to_do_pred && do_pred[i]`）：`p_type`=类型预测器输出；`pred_taken`= `NONCTL?0 : (RET/CALL/IDIRECT/JAL)?1 : tage.pred_out`（`DIRECT`）。
输出 `out_pred_dir=pred_taken`、`out_alt_pred=tage.alt_pred`、`pcpn/altpcpn/tags/idxs` 来自该 lane 所在 bank 的 TAGE（`tage_valid=btb_valid=1`，因为 `pred_req` 恒为真）。非 `do_pred` 的 lane 全 0。
下一地址 `next = boundary`；**第一个 `pred_taken` 的 lane**：`next = (p_type==RET && ras_count>0) ? ras_top : btb.pred_target`。
`pc_reg_next = refetch ? refetch_address : going_to_do_pred ? next : pc_reg`。`predict_next_fetch_address = next`。

## 4. 默认配置下的死代码清单（不翻译）

| 死代码 | 依据 |
| --- | --- |
| NLP 表、`nlp_*`、`saved_2ahead_*`、`saved_mini_flush_*`、`two_ahead_*`、`mini_flush_*`、`BpuNlpCombIn/Out`、`nlp_s1/s2_*` | `ENABLE_2AHEAD` 未定义（`FRONTEND_DISABLE_2AHEAD`）；`bpu_nlp_comb` 里 `#ifdef ENABLE_2AHEAD` 整段不编译；输出被置 false |
| `S_IDLE/S_WORKING/S_REFEATCH` 状态、`do_pred_latch`、`do_upd_latch`、`tage_done/btb_done`、`pred_base_pc_fired`、`tage_calc_*_latch`、`btb_*_latch`、`*_result_valid_latch` | `bpu_core_comb_calc` 每拍写 `*_next=false/0/本拍值`，**没有任何读者**（`bpu_seq_read` 复制到 `rd` 后只被 snapshot 使用）|
| TAGE/BTB 子模块的 `state`、`do_*_latch`、`pred_calc_*_latch`、`upd_*_latch`、`upd_calc_*_latch`、`S_STAGE2/WAIT_DATA` 分支 | 子模块 `comb` 一开头 `req.next_state = S_IDLE` 且不写任何 latch；`tage_gen_index_comb/btb_gen_index_*` 的 `read_pred(S_STAGE2)` 分支不可达，`table_r/mem_*` 只被不可达分支或无人使用的字段读取 |
| `sram_delay_*`、`sram_prng_state`（TAGE `0x13579bdf`，BTB `0x2468ace1`）、`xorshift32_comb` | `SRAM_DELAY_ENABLE` 未定义；`*_prng_state_next = rd.sram_prng_state` 恒不变，xorshift 函数无调用点。**任务书提到的"BTB PRNG 必须按位复刻"在默认配置下不存在随机行为**（TAGE 分配用的是 4 位 LSFR，已复刻）|
| TAGE：`sc_ctr_table`、SC-Lite、`scl_*`、`loop_*`、`path_in`、`ghr_in`、`pred_sc_*` | `ENABLE_TAGE_SC_L/SC_LITE/LOOP_PRED/SC_PATH=0`。`ghr_in` 只被 SC-L 读；`sc_used_in/loop_used_in` 恒 0（`provider_used` 恒真）|
| BTB：`btb_type_idx`、`type_idx`、`r_type`、`sram_*`、BTB `tc_idx` 第一次 `gen_index_pre` | `BTB_TYPE_ENTRY_NUM` 无存储；其余无人读 |
| 类型预测器 `pred_hit/pred_confident` 输出，条目 `conf` | BPU 只读 `pred_type`；`conf` 只被 `pred_confident` 读 |
| `pc_can_send_to_icache` | 复位 true，唯一写入是写 true；[已验证] 全程恒 1，`icache_read_valid = !refetch` |
| `update_queue_full`、队列 `count>=Q_DEPTH`、`q_wr/rd_ptr`、`PATH` | 见 §3.6；`PATH` 只被 SC-L 路径读 |
| `Arch/Spec_GHR` 的 119..255 位 | FH 更新只读到 `GHR[118]`（TAGE 不读 GHR，见上）|
| `refetch` 拍的预测结果 | `fetch_address` 受 `icache_read_valid=!refetch` 保护，PTAB 写受 `PTAB_write_enable` 保护；预测本身**没有副作用**（读不改状态；Spec 被 refetch 覆盖）。RTL 仍按 C++ 用 `refetch_address` 作 base 计算（保持子部件录制一致），只是输出 `when` |

## 5. 状态规模

| 部件 | 数组 | 大小 | 读口 | 写口 |
| --- | --- | --- | --- | --- |
| 类型预测 | `table[8][512][2]×14b`（`conf` 死，不存）| 115 Kb | 16（8 预测 + 8 更新）| 8（后 lane 覆盖）|
| BTB（×8） | `btb tag/bta/valid/useful[4][256]` | 45 Kb | 2（预测/更新）| 1 |
| | `bht[128]×8b`，`tc/tc_pre[2][128]×46b`，`tc_mode[128]×3b` | 24 Kb | 预测 1 + 更新 2（含两次间接读）| 各 1 |
| TAGE（×8） | `base[1024]×2b`，`tag/cnt/useful[4][1024]` | 55 Kb | 预测 1 + 更新 1（`useful` 另有清行读 1）| 各 1（`useful` 2：更新+清行）|
| 历史 | `GHR[119]` ×2（Spec/Arch）、`FH[3][4]` ×2、RAS `32×32b`+count ×2 | ~3 Kb | — | Arch 最多 8 次/拍 |
| 更新队列 | 每 bank 一个 `{valid, 145b}` | 1.2 Kb | — | 1 |

## 6. 边界与录制方案

整程序实时锁步为主（BPU 是长期学习的状态机，trace 窗口覆盖不足）。每个子部件都可录，`@` 表达式如下（`R=cpu.front.update_req_->bpu_seq_txn.req`，`I=…inp`，`T=TTG_FT.bpu_out`）：

| spec | 输入 | 输出 |
| --- | --- | --- |
| `bpu`（顶层）| `I.*`（去掉 sc/loop）| `T.*`（见 §2.2）|
| `bpu_type` | `R.type_in.*` | `pred_type[i]` = `R.btb_in[R.this_pc_bank_sel[i]].pred_type_in`（BPU 把类型预测结果绑进 BTB 输入，`when pred_valid`）|
| `bpu_btb`（8 bank 数组）| `R.btb_in[b].*` | `R.btb_req[b].out_regs.{pred_target}`（`when pred_req`）|
| `bpu_tage`（8 bank 数组）| `R.tage_in[b].*`（`pred_pc/update` 取索引位；`fh_in` 共用）| `R.tage_req[b].out_regs.*`（`when pred_req`）|
| `bpu_hist` | 提交 lane（`I`）、`R.do_pred_on_this_pc/do_pred_for_this_pc/final_pred_dir/going_to_do_pred`、lane 类型（同 `bpu_type` 输出）| `fh[3][4]`=`R.tage_in[0].fh_in`（Spec FH 起拍值）；RAS 栈顶经 `g_bpu_top`（`refetch?Arch:Spec`）|
| `bpu_uq` | 提交 lane（`I`）| 每 bank 的 `R.btb_in[b].upd_*` 与 `R.tage_in[b].{update_en,…}`（队列出口，即下一拍的更新输入）|

`bpu_seq_txn.req` 是 `UpdateRequest`，保存了 `tage_in/btb_in/type_in/tage_req/btb_req/do_pred_*`，插件可直接读。`g_bpu_top`（extern 全局）可读 `Spec_RAS/Arch_RAS` 等状态。
`tests/bpu/cov.cpp` 用同样方式做覆盖探针。

## 7. RTL 模块划分与翻译顺序

```
rtl/frontend/bpu/
  bpu_pkg.sv          常量、br_type 编码、hash/bank 函数
  bpu_mem.sv          寄存器堆式阵列原语：M 个异步读口、N 个同步写口（后口覆盖前口），复位置初值
  bpu_type.sv  + bpu_type_lane.sv    类型预测（预测 lane / 更新 lane）
  bpu_btb.sv   + bpu_btb_bank.sv, bpu_btb_index.sv, bpu_btb_pred.sv, bpu_btb_upd.sv   8 bank BTB
  bpu_tage.sv  + bpu_tage_bank.sv, bpu_tage_pred.sv, bpu_tage_upd.sv                  8 bank TAGE
  bpu_hist.sv  + bpu_hist_step.sv, bpu_ras.sv                                         GHR/FH/RAS
  bpu_uq.sv                                                                           更新队列（8 bank 流水寄存器）
  bpu_ctrl.sv                                                                         取指组/bank 映射/下一地址/pc 寄存器
  bpu.sv                                                                              顶层端口适配 + 连线
```
顺序：①类型预测 ②BTB ③TAGE（三者都是"阵列 + 纯组合"，可独立整程序锁步）④hist+RAS ⑤更新队列 ⑥顶层。每步先过自己的 spec 的整程序锁步，再进下一步。

## 8. 覆盖（`tests/bpu/cov.cpp`，dhrystone 前 100 万拍，**[已验证]**）

`refetch=5369`，`going_to_do_pred=421104`，反压拍（`icache_read_ready=0`）578896，`upd_lane=841517`（其中类型 `0/1/2/3/4/5` = 75035/35887/36041/162/686570/7822），
被"同 bank 丢弃"的提交 lane 41043，`qmax=1`，`pc_can_send=0` 的拍数 0，`sc_nonzero=0`，RAS Spec 最深 4、Arch 最深 3（**真实程序碰不到 32 深度溢出**），
IDIRECT taken 162，`tc_write=162`，`tc_mode_write=30`，TAGE 每 bank 更新 2715–15426 次、`useful` 清行事件 2–8 次，`reset_cnt[23]`（msb 模式）从未置位，
Spec≠Arch GHR 的拍数 947354。**盲区**（需随机流补）：RAS 满/溢出、`btb/tc` 全路满的 victim 选择、`useful` 饱和、`reset_cnt[23]=1`、同拍多提交 lane 同 pc（类型预测器同槽覆盖）、
`refetch` 与更新/误预测不同拍、非 2 的幂边角（地址回绕、`boundary` 跨 4 GB）。

## 9. 风险与待决

- 体量：6000 行 C++；RTL 预计 4–5 千行。阵列都是 SRAM 式，用 `bpu_mem`（同步写、异步读）而不是 `mem_d` 全拷贝（8 bank × 10^5 位，全拷贝会让 Verilator 慢 100 倍）。
- `bank_pc = pc>>3` 与 BTB miss 目标 `bank_pc+4` 是 C++ 的怪行为但有意义，复刻并登记 `docs/modules/bpu.md`。
- 随机流生成器直接驱动参考 `BPU_TOP` 类；合法性约束见 `docs/modules/bpu.md`（更新必须是"曾预测过的 PC"？——C++ 并不要求，TAGE 元数据任意值都能算，因此约束只需保证类型/索引在位宽内）。
