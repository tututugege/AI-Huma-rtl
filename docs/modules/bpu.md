---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
spec: bpu*
status: green
lockstep: 68/68，独立复核 408/408
mutants: 38/38（13 仅随机）
note: TAGE/BTB/历史/RAS/更新队列
---

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

1. `bpu_ctrl`：`base = pc_q`（C++ 在 refetch 拍用 `refetch_address`，见 §4.4 第 5 条）；`boundary`；`lane_pc/lane_valid`；`going_to_do_pred = icache_read_ready`（C++：`|| refetch`）。
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
5. `refetch` 拍的预测：C++ 在 refetch 拍强制 `going_to_do_pred` 并以 `refetch_address` 为 base 预测。该预测**不可观察**：`fetch_address` / PTAB 载荷分别被 `icache_read_valid = !refetch`、`PTAB_write_enable` 屏蔽，查询无副作用（读表不改状态；LSFR/`reset_cnt`/`use_alt` 只在更新时变），Spec 历史/RAS 被 refetch 覆盖。RTL 因此用 `pc_q` 作 base、`going_to_do_pred = icache_read_ready`（只影响 refetch 拍的内部量）。注意：由此 `bpu_type/bpu_hist` 等子 spec 的 refetch 拍输入与顶层 RTL 内部信号不同，但各子模块自己的锁步是用 C++ 录到的输入驱动的，不受影响。

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

### 5.2 整程序实时锁步（主验证）
`REFSIM=…/refsim_tap bash scripts/lockstep_multi.sh bpu bpu_type bpu_btb bpu_tage bpu_hist bpu_uq`：6 个 spec 在同一遍参考模拟里同时逐拍比对（RTL 编成插件挂进参考模拟器，BPU 状态从复位开始连续学习）。

| 程序集 | 个数 | 每个 spec 比对拍数 | 结果 |
| --- | --- | --- | --- |
| 61 个 gate 测试 | 61 | 91 ~ 1,541,195（合计 2,060,221）| 全 PASS |
| vm 测试（asid / pagefault / sum_fetch / sfence_perm）| 4 | 68,737 / 29,412 / 2,694 / 38,695 | 全 PASS |
| dhrystone（跑完）| 1 | 3,911,612 | PASS |
| coremark（上限 400 万拍）| 1 | 4,000,000 | PASS |
| float_test / coremark10 | 2 | 2,005 / 976,652 | PASS |
| sha-test / cjpeg / linear_alg / parser-125k（上限 400 万拍）| 4 | 各 4,000,000 | PASS |
| **合计** | **73** | **27,090,028**（每个 spec）| **73 × 6 spec 全 PASS，0 失配** |

以上是最终 RTL（含"丢弃 conf、忽略 refetch 拍预测"两处简化之后）的结果：68 个标准程序 × 6 spec = 408 条 PASS，另 5 个大程序（coremark10、sha-test、cjpeg、linear_alg、parser-125k）× 6 spec = 30 条 PASS，0 失配（共 73 程序、每个 spec 27,090,028 拍）。简化之前的 RTL 版本也各跑过一遍同样的程序集（全 PASS）。另用 `scripts/record.sh bpu` 录 trace + `scripts/replay.sh` 回放（dhrystone 2 万拍）确认录制/回放路径可用。

### 5.3 随机更新流（补覆盖，顶层 `bpu.io`）
`tests/bpu/rand_trace.cpp`（`bash tests/bpu/run_rand.sh <拍数> <种子>…`）：直接驱动**真实的参考类 `BPU_TOP`**（调用方式同 `front_top.cpp`：`bpu_seq_read; bpu_comb_calc; bpu_seq_write`），
把同一输入序列和参考输出写成 trace，用回放器验证 RTL。**激励合法性依据**：
- `br_type∈0..5`、`pcpn/altpcpn∈0..4`、pc 4 字节对齐；`sc_*/loop_*` 输入恒 0（BPU 从不输出非 0，真实后端发不出非 0）。更新元数据（`pred_dir/alt_pred/pcpn/tags/idxs`）要么取自 BPU 自己刚输出的预测（"真实模式"：软件后端把已预测的取指组留在飞行队列里，按序提交，类型/目标/方向由一个静态合成程序决定），要么完全随机（"压力模式"；C++ 对任意值都能算，idx 按位宽截断）。
- `refetch` 配任意 4 字节对齐地址：池内地址、跨 32B 组/64B 行的地址、接近 2^32 的地址（C++ 与 RTL 都 32 位回绕）；无效提交 lane 的负载填垃圾（模型必须忽略）。
- 5 个阶段（每 3000 拍切换）：真实 / 压力（小 pc 池、随机元数据、稠密提交 → 同 bank 丢弃、类型表冲突）/ 调用返回密集（RAS 深度超过 32）/ refetch 密集 / 真实 + 反压。
- **构造冲突池**：BTB 的 `pw=(k<<8)|(c^k)`（同组多 tag，超过 4 路，触发 victim/useful 替换）；类型表 `pw=(j<<9)|s`（同组多 tag，超过 2 路）。真实程序碰不到这两类替换。
- 覆盖（每 10 万拍）：预测 ~5.2 万拍、refetch ~2.4 万、被同 bank 丢弃的提交 lane ~5 万、TAGE 更新 ~7.5 万（分配 ~2.2 万，`useful` 清行 ~40 次，use-alt 写 ~1.6 千）、BTB 更新 ~26 万、TC 写 ~1.1 万、`tc_mode` 写 ~3 千、RAS Spec/Arch 都满到 32（Spec 满的拍数 ~3.3 万）。
- 结果：种子 1、11、21、22（20k/100k/100k/100k 拍）、31、32、33（各 20 万拍）全部 PASS（共 ~87 万拍）。

### 5.4 变异检查
38 个变异分布在所有子部件：类型预测器 6、BTB 8、TAGE 9、历史/RAS 6、更新队列 3、控制/组合 6。三档验证：
(1) dhrystone 前 30 万拍整程序锁步（用对应子 spec，顶层变异用顶层 spec）；(2) 前一档没抓到的再用 coremark 150 万拍；(3) 随机流（3 个种子 × 10 万拍，顶层 spec）。

**38 个变异里：dhrystone 锁步抓到 20，coremark 再抓到 5，随机流抓到 38（全部）；只靠随机流（构造冲突/满深度/反压）才能抓到的 13 个**：
类型表的替换/清除/age（5）、BTB 的 victim 并列选择与 `useful` 饱和与 IDIRECT 的 useful 初值（3）、`tc_mode` 阈值与递减下限（2）、BHT 目标签名（1）、hash 的第三项折叠（1）、RAS 满栈写槽（1）。
真实程序的工作集小，BTB/类型表不会"同组装满再替换"，RAS 不会深于 4（见分析 §8），这些只能靠构造激励。
变异记录工具：`tests/bpu/mutants.txt`、`mut.sh`（锁步）、`run_mut.sh`、`run_mut_replay.sh`（trace 回放）。

| # | 子部件 | 文件 | 变异 | dhrystone 30 万拍锁步 | coremark 150 万拍锁步（仅复测前者未抓到的）| 随机流（3×10 万拍）|
| --- | --- | --- | --- | --- | --- | --- |
| 1 | bpu_type | `bpu_type_lane.sv` | `(way_entry[1].age < way_entry[0].age) ? 1'b1 : 1'b0` → `(way_entry[1].age <= way_entry[0].age) ? 1'b1 : 1'b0` | 未抓到 | 未抓到 | 抓到 out_tage_tags[0][0]@371 |
| 2 | bpu_type | `bpu_type_lane.sv` | `upd_we        = (actual_type != BR_NONCTL) \|\| hit;` → `upd_we        = (actual_type != BR_NONCTL);` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@173 |
| 3 | bpu_type | `bpu_type.sv` | `upd_tag[l]  = upd_pc[l][5 + TP_SET_W +: TP_TAG_W];` → `upd_tag[l]  = upd_pc[l][4 + TP_SET_W +: TP_TAG_W];` | 未抓到 | 抓到 pred_type[1]@226 | 抓到 out_tage_tags[0][1]@63 |
| 4 | bpu_type | `bpu_type_lane.sv` | `old_age + 2'd1) : 2'd1;` → `old_age + 2'd1) : 2'd0;` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@1460 |
| 5 | bpu_type | `bpu_type_lane.sv` | `(old_age == 2'd3) ? 2'd3 : old_age` → `(old_age == 2'd2) ? 2'd2 : old_age` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@3503 |
| 6 | bpu_type | `bpu_type_lane.sv` | `if (actual_type == BR_NONCTL) upd_entry = '0;` → `if (actual_type == BR_NONCTL) upd_entry = upd_entry;` | 未抓到 | 未抓到 | 抓到 out_pred_dir[5]@9073 |
| 7 | bpu_btb | `bpu_pkg.sv` | `if (3 * w < 32) m = m ^ (x >> (3 * w));` → `if (3 * w < 24) m = m ^ (x >> (3 * w));` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@173 |
| 8 | bpu_btb | `bpu_btb_upd.sv` | `if (btb_set[w].useful <= btb_set[victim].useful) victim = 2'(...` → `if (btb_set[w].useful < btb_set[victim].useful) victim = 2'(w);` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@3342 |
| 9 | bpu_btb | `bpu_btb_pkg.sv` | `if (correct) return (cur == 3'd7) ? 3'd7 : cur + 3'd1;` → `if (correct) return (cur == 3'd6) ? 3'd6 : cur + 3'd1;` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@2911 |
| 10 | bpu_btb | `bpu_btb_pkg.sv` | `TC_MODE_BIAS = 3'd3` → `TC_MODE_BIAS = 3'd4` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@20418 |
| 11 | bpu_btb | `bpu_btb_pred.sv` | `pc_plus4 = pc + 32'd4;` → `pc_plus4 = {pc[28:0], 3'b000} + 32'd4;` | 抓到 pred_target[2]@1 | — | 抓到 predict_next_fetch_address@89 |
| 12 | bpu_btb | `bpu_btb_pkg.sv` | `(t ^ (t >> 11) ^ (t >> 19)) ^ SALT_BHT_UPD` → `(t ^ (t >> 11)) ^ SALT_BHT_UPD` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@4561 |
| 13 | bpu_btb | `bpu_btb_upd.sv` | `btb_wdata.useful = (upd_br_type == BR_IDIRECT) ? 3'd0 :` → `btb_wdata.useful = (upd_br_type == BR_IDIRECT) ? 3'd1 :` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@30154 |
| 14 | bpu_btb | `bpu_btb_upd.sv` | `(tc_mode_old > 3'd0) ? tc_mode_old - 3'd1 : 3'd0` → `(tc_mode_old > 3'd1) ? tc_mode_old - 3'd1 : 3'd1` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@19621 |
| 15 | bpu_tage | `bpu_tage_pred.sv` | `idx[i] = fh[0][i][T_IDX_W-1:0] ^ pc_idx;` → `idx[i] = fh[1][i][T_IDX_W-1:0] ^ pc_idx;` | 抓到 idx_out[0][1]@355 | — | 抓到 out_tage_idxs[0][1]@16 |
| 16 | bpu_tage | `bpu_tage_pred.sv` | `match[i] = (rd_tag[i] == tag[i]);` → `match[i] = (rd_tag[i][6:0] == tag[i][6:0]);` | 抓到 pcpn_out[0]@294 | — | 抓到 out_pcpn[3]@215 |
| 17 | bpu_tage | `bpu_tage_upd.sv` | `cnt_wdata[i] = real_dir ? ((rd_cnt[i] == 3'd7) ? 3'd7 : rd_cn...` → `cnt_wdata[i] = real_dir ? ((rd_cnt[i] == 3'd6) ? 3'd6 : rd_cn...` | 未抓到 | 抓到 alt_pred_out[2]@8922 | 抓到 out_pred_dir[4]@24439 |
| 18 | bpu_tage | `bpu_tage_upd.sv` | `(lsfr_rand == 2'd0 \|\| lsfr_rand == 2'd3)` → `(lsfr_rand == 2'd0)` | 抓到 pcpn_out[1]@657 | — | 抓到 out_pcpn[5]@1022 |
| 19 | bpu_tage | `bpu_tage_pred.sv` | `prefer_alt    = (use_alt_ctr <= 4'd8);` → `prefer_alt    = (use_alt_ctr < 4'd8);` | 未抓到 | 抓到 pred_out[1]@3046 | 抓到 out_pred_dir[7]@4316 |
| 20 | bpu_tage | `bpu_tage_upd.sv` | `{reset_row_useful[i][1], 1'b0}` → `{reset_row_useful[i][0], 1'b0}` | 未抓到 | 抓到 pcpn_out[2]@130207 | 抓到 out_pcpn[6]@26799 |
| 21 | bpu_tage | `bpu_tage_upd.sv` | `lsfr_next = {lsfr[2:0], lsfr[0] ^ lsfr[3]};` → `lsfr_next = {lsfr[2:0], lsfr[1] ^ lsfr[3]};` | 抓到 pcpn_out[1]@657 | — | 抓到 out_pred_dir[5]@1130 |
| 22 | bpu_tage | `bpu_tage_upd.sv` | `cnt_wdata[i]    = real_dir ? 3'd4 : 3'd3;` → `cnt_wdata[i]    = real_dir ? 3'd4 : 3'd2;` | 抓到 pred_out[1]@1414 | — | 抓到 out_pred_dir[7]@1690 |
| 23 | bpu_tage | `bpu_tage_bank.sv` | `use_alt_q   <= 4'd7;` → `use_alt_q   <= 4'd8;` | 未抓到 | 抓到 pred_out[1]@3046 | 抓到 out_pred_dir[7]@4316 |
| 24 | bpu_uq | `bpu_uq.sv` | `(base_pc[l][BANK_W + 1:2] == BANK_W'(b))` → `(base_pc[l][BANK_W:1] == BANK_W'(b))` | 抓到 q_valid[1]@37 | — | 抓到 predict_next_fetch_address@60 |
| 25 | bpu_uq | `bpu_uq.sv` | `.req(lane_to_bank), .onehot(first_lane)` → `.req(lane_to_bank & 8'h7F), .onehot(first_lane)` | 抓到 q_valid[6]@86 | — | 抓到 predict_next_fetch_address@174 |
| 26 | bpu_uq | `bpu_uq.sv` | `tage_en[b]   = valid_q && (head_q.br_type == BR_DIRECT);` → `tage_en[b]   = valid_q;` | 抓到 tage_en[0]@19 | — | 抓到 out_alt_pred[7]@101 |
| 27 | bpu_hist | `bpu_hist_step.sv` | `localparam int SH = G % L;` → `localparam int SH = (G + 1) % L;` | 抓到 fh[0][0]@355 | — | 抓到 out_tage_tags[0][0]@16 |
| 28 | bpu_hist | `bpu_hist.sv` | `arch_mispred[l] = arch_apply[l] && (pred_dir[l] != actual_dir...` → `arch_mispred[l] = arch_apply[l] && (pred_dir[l] == actual_dir...` | 抓到 fh[0][0]@229 | — | 抓到 out_tage_tags[0][1]@21 |
| 29 | bpu_hist | `bpu_hist.sv` | `before_taken[l] = (l == 0) ? 1'b0 : \|(taken_lane & ((NLANE'(1...` → `before_taken[l] = 1'b0;` | 抓到 fh[0][0]@828 | — | 抓到 out_tage_tags[0][0]@94 |
| 30 | bpu_hist | `bpu_ras_step.sv` | `wr_slot    = full ? base : base + count[RAS_PTR_W-1:0];` → `wr_slot    = full ? base + RAS_PTR_W'(1) : base + count[RAS_P...` | 未抓到 | 未抓到 | 抓到 predict_next_fetch_address@3036 |
| 31 | bpu_hist | `bpu_ras.sv` | `if (refetch) spec_stk_d[j] = arch_stk_d[j];` → `` | 抓到 ras_top@87 | — | 抓到 predict_next_fetch_address@72 |
| 32 | bpu_hist | `bpu_ras_step.sv` | `else if (pop && count != '0) count_next = count - RAS_CNT_W'(...` → `else if (pop) count_next = count - RAS_CNT_W'(1);` | 抓到 ras_has@349 | — | 抓到 predict_next_fetch_address@364 |
| 33 | bpu | `bpu_ctrl.sv` | `localparam logic [31:0] LINE_MASK = ~32'(ICACHE_LINE_SIZE - 1);` → `localparam logic [31:0] LINE_MASK = ~32'(GROUP_BYTES - 1);` | 抓到 predict_next_fetch_address@13 | — | 抓到 predict_next_fetch_address@4 |
| 34 | bpu | `bpu_ctrl.sv` | `lane_valid[i] = (lane_pc[i] < boundary);` → `lane_valid[i] = (lane_pc[i] <= boundary);` | 抓到 out_pcpn[7]@14 | — | 抓到 out_pcpn[3]@5 |
| 35 | bpu | `bpu_ctrl.sv` | `ptab_write_enable = going_to_do_pred && !refetch;` → `ptab_write_enable = going_to_do_pred;` | 抓到 ptab_write_enable@12 | — | 抓到 ptab_write_enable@2 |
| 36 | bpu | `bpu_pred.sv` | `lane_target[i] = (lane_type[i] == BR_RET && ras_has) ? ras_to...` → `lane_target[i] = (lane_type[i] == BR_RET && ras_has) ? ras_to...` | 抓到 predict_next_fetch_address@260 | — | 抓到 predict_next_fetch_address@72 |
| 37 | bpu | `bpu_pred.sv` | `assign next_pc = any_taken ? first_target : boundary;` → `assign next_pc = any_taken ? first_target : boundary + 32'd4;` | 抓到 predict_next_fetch_address@1 | — | 抓到 predict_next_fetch_address@1 |
| 38 | bpu | `bpu.sv` | `tage_pred_pc_idx[b] = bank_pc[b][T_BASE_W + 1:2];` → `tage_pred_pc_idx[b] = bank_pc[b][T_BASE_W:1];` | 抓到 out_pcpn[4]@1 | — | 抓到 out_pcpn[4]@1 |

**发现的无效/等价**：
- 变异"类型预测器 `conf` 饱和值"在所有三档里都无法被抓到，追查发现 `conf` 只被 `pred_confident` 读而 BPU 不读 → **`conf` 是死状态，已从 RTL 删除**（条目 14 位）。
- 变异"BTB 索引 hash 的 salt 常数"是**等价变异**（XOR 常数只是索引重命名，任何激励都抓不到），已换成"去掉 hash 的第三折叠项"。
- 变异"`going_to_do_pred = ready \|\| refetch` 去掉 `\|\| refetch`"在随机流里抓不到，追查发现 refetch 拍的预测**不可观察**（输出被 `icache_read_valid/PTAB_write_enable` 屏蔽、查询无副作用、Spec 被 refetch 覆盖）→ RTL 采纳该简化（C++ 的 `\|\| refetch` 与"refetch 拍用 `refetch_address` 作 base"都不翻译，§4.4 第 5 条）。

### 5.5 lint
`bash scripts/lint.sh rtl/frontend/bpu` 干净（svlint S1–S12 + `verilator -Wall`，含 UNOPTFLAT）。文件 ≤400 行（最大 190）、`always_comb` ≤60 行、无 break/while、无层次引用。
