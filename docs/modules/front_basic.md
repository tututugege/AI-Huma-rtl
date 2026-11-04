---
module: front_basic
area: frontend
rtl: rtl/frontend/*.sv
spec: predecode* sequential_next_pc fetch_addr_fifo inst_fifo ptab front2back_fifo front_ctrl
status: green
lockstep: 68/68
mutants: 34/34（10 仅生成 trace）
note: 预译码、4 个 FIFO、front_ctrl
---

# front_basic 设计笔记（前端基础模块）

覆盖 8 个可回放模块（RTL 放 `rtl/frontend/`，spec 放 `spec/<模块>.io`，同名顶层）：

| 模块（spec 名） | 作用 | 参考 C++ |
| --- | --- | --- |
| `predecode` | 8 lane 预译码（jal / 条件分支 / jalr / 其他 + 直接目标）| `front-end/predecode.cpp` `predecode_comb`；`front_top.cpp:1624-1640` |
| `sequential_next_pc` | 取指组顺序下一 pc（有效前缀 + 行内截断）| `front_top.cpp:78-96` |
| `predecode_checker` | 用预译码结果校正 BPU 预测、产生 flush | `front-end/predecode_checker.cpp` |
| `fetch_addr_fifo` / `inst_fifo` / `ptab` / `front2back_fifo` | 4 个 FIFO 实例（同一个参数化队列 `front_fifo`）| `front-end/fifo/*.cpp` |
| `front_ctrl` | 全局 refetch、FIFO 读写使能、BPU 门控、f2b 输出旁路、predecode flush、`predecode_refetch` 寄存器 | `front_top.cpp` `front_comb_calc` S1/S2/S4/S5/S9–S12/S14 控制部分 |

分析依据：`docs/analysis/frontend-boundary.md`（步骤表 S0–S15、死代码清单）与 `frontend-record-hook.md`（tap 录制）。参考模型基线 2f31e8d，录制用 `refsim_tap`（带前端 tap，周期数与原版一致）。

## 1. 对应的 C++

### 1.1 predecode / sequential_next_pc / predecode_checker
- 纯组合函数。`predecode_comb(inst, pc)`：`inst==0||INST_NOP` 直接 NON_BRANCH（这两个值的 opcode 本来就不是 jal/jalr/branch，所以 RTL 不需要这个特判）；opcode 为 jal → type 3，目标 `pc+sext(J-imm)`；branch(0x63) → type 1，目标 `pc+sext(B-imm)`；jalr → type 2，目标 0；其余 → type 0，目标 0。
- 前端在 `inst_valid[i]==0` 的 lane 不调用 predecode，直接写 `NON_BRANCH/0`（1631–1634）。RTL 把 `inst_valid` 作为 `predecode` 的输入，无效 lane 在模块内强制为 NON_BRANCH/0；lane i 的 pc = `fetch_pc + 4*i`，所以输入是 `fetch_pc`（标量）而不是 8 个 pc。
- `sequential_next_pc`：`CONFIG_FRONT_VALID_PREFIX_SEQ_NEXT=1`；有效前缀长度 `p`（第一个无效 lane 的下标，全有效为 8），`next = fetch_pc + 4p`，若跨 64B 行则截到行首。
- `predecode_checker_comb`：逐 lane 校正方向（NON_BRANCH→0；DIRECT_JUMP_NO_JAL→BPU 方向；JAL/JALR→1），取第一个 taken lane：若其 type 是 DIRECT_JUMP_NO_JAL 或 JAL 则下一地址用其目标，JALR 保持 BPU 的地址；没有 taken → `seq_next_pc`；`flush = (BPU 地址 != 校正地址)`。`default:` 分支的 `exit(1)` 在 2 位 type 下不可达。

### 1.2 FIFO（4 个实例）
- C++ 里每个 FIFO 一拍内"读调用 + 写调用 + `accumulate_*_req`"，`front_seq_write` 按 `clear → push → pop` 一次性应用（`fifo/*.cpp` `seq_write`）。当前配置下读调用的 `write_enable` 恒 0、写调用的 `read_enable` 恒 0，所以空队列写穿（`do_read = read_enable && (has_data || do_write)` 里的 `|| do_write`）从未触发（死代码，见 frontend-boundary.md §3.1/§3.4），等价于标准 1R1W 队列：读口看到**起拍**队首。
- 真实规格（以 `tools/widths.cpp` 与 `frontend_feature_config.h:336-345` 为准，`FIFO_RTL_TEMPLATE_MAPPING.md` 已过时）：

| 实例 | 深度 | 条目位宽（RTL）| C++ 条目位宽 | refetch（清空）来源 | `full` 阈值 | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `fetch_addr_fifo` | 16 | 32 | 32 | `global_refetch` | `size>=15` | BPU 取指地址 |
| `inst_fifo` | 16 | 576 | 832 | `global_refetch` | `size==16`（结构上不可达）| 不存 8×pc 调试字段 |
| `ptab` | 16 | 2152 | 2378 | `global_refetch` | `size>=15` | 不存恒 0 的 `need_mini_flush/dummy_entry`；base_pc 8×32 → 1×32 |
| `front2back_fifo` | 32 | 2424 | 2648 | **仅后端** `in.refetch` | `size==32` | base_pc 8×32 → 1×32 |

- 8 个 `*_full_latch/*_empty_latch` 是对应 FIFO 当前 size 的纯函数（分析 agent 已在 73 程序 126 万拍验证 0 不一致）。RTL 不建这 8 个寄存器：`front_fifo` 的 `full/empty` 输出由起拍 `count_q` 比较得到。
- 读口无效（`rd_valid=0`）时的 `rd_*` 数据：C++ 返回全 0，RTL 返回读指针指向的槽（无意义）。见 §4。

### 1.3 front_ctrl
- 输入/输出清单见 `spec/front_ctrl.io`。C++ 位置：`front_global_control_comb`（636–645）、`front_read_enable_comb`（647–668）、`front_read_stage_input_comb`（670–695，只是把 reset/refetch/read_enable 分发给 4 个 FIFO，RTL 里就是连线）、`front_bpu_control_comb`（697–746）、`front_comb_calc` S5（1405–1437）、S9（1705–1730）、S10（1733–1763）、S11（1766–1816）、S12（1818–1838）、S14（输出 `FIFO_valid`）。

## 2. 硬件结构

```
 be_refetch/addr ─┐                       ┌─ predecode_refetch_q (1) ─┐
                  ├─ front_refetch_ctrl ──┤  predecode_refetch_addr_q │──► global_refetch, refetch_address
 do_predecode_flush, flush_addr ─────────▶└───────────────────────────┘
 4×(full,empty), icache_ready, be_fifo_read_enable, bpu_*, checker_flush_enable
        └──────────────────────────────▶ front_ctrl_enables (纯组合) ──► fa_rd_en, predecode_can_run, bpu_can_run,
                                                                       bpu_icache_read_ready, fa/ptab/f2b_wr_en,
                                                                       f2b_use_bypass, front_out_valid, do_predecode_flush

 front_fifo #(DEPTH, W, FULL_AT)：mem_q[DEPTH][W] + rd_ptr_q + wr_ptr_q + count_q（环形缓冲）
 fetch_addr_fifo / inst_fifo / ptab / front2back_fifo：端口适配（平铺端口 ↔ packed struct 条目）+ 一个 front_fifo 实例
 predecode = 8 × predecode_lane；predecode_checker = first_set + 独热 mux；sequential_next_pc = first_set + onehot_to_idx
```

- **`front_fifo`**：读指针/写指针/计数器三个寄存器 + `DEPTH×W` 存储。一拍：`rd_valid = rd_en & ~clear & ~empty`；`clear` 时 `rd_ptr := wr_ptr`、计数清零（push 随后落在 `wr_ptr` 槽，即新队首）；`wr_ptr += wr_en`；`rd_ptr += rd_valid`；`count = (clear?0:count) + wr_en − rd_valid`。存储按"写使能 = wr_en 且槽号 == wr_ptr"逐槽更新。`DEPTH` 必须是 2 的幂（指针自然回绕，编译期 `$error` 检查）。运行期断言：不得在满队列（clear 之后）push（C++ 在 `seq_write` 里 `exit(1)`）。
- **条目 struct**（`front_pkg.sv`）：`inst_fifo_entry_t`、`pred_meta_t`（PTAB 与 front2back 共用的预测元数据）、`ptab_entry_t`、`f2b_fifo_entry_t`。端口名与 spec 一致（`wr_*`/`rd_*`，数组按 spec 维度）。
- **`front_ctrl`**：状态只有 `predecode_refetch`（1 位）与 `predecode_refetch_address`（32 位）。`global_refetch = be_refetch | predecode_refetch_q`；`refetch_address = be_refetch ? be_refetch_address : predecode_refetch_address_q`（后端优先）。其余全是组合：

```
fa_rd_en          = icache_ready & ~fa_empty & ~global_refetch
predecode_can_run = ~inst_empty & ~ptab_empty & ~f2b_full & ~global_refetch      (= inst/PTAB 读使能)
bpu_can_run       = ~(fa_full | ptab_full) | global_refetch
bpu_icache_read_ready = ~fa_full & bpu_can_run
fa_wr_en          = bpu_icache_read_valid & bpu_can_run
ptab_wr_en        = bpu_ptab_write_enable & ~ptab_full & ~global_refetch
do_predecode_flush= predecode_can_run & checker_flush_enable
f2b_use_bypass    = be_fifo_read_enable & f2b_empty & predecode_can_run
f2b_wr_en         = predecode_can_run & ~f2b_use_bypass
front_out_valid   = (be_fifo_read_enable & ~be_refetch & ~f2b_empty) | f2b_use_bypass
次态: predecode_refetch_q <= do_predecode_flush ; predecode_refetch_address_q <= checker_flush_address
```

## 3. 一拍内的数据流
- FIFO：读口（组合）= 起拍队首；写入与指针更新在时钟沿（clear→push→pop）。`rd_valid` 是组合输出（取决于 `clear`、`rd_en`、`count_q`），没有 stale 读、没有同拍覆盖、没有组合环。
- front_ctrl：`global_refetch` 来自寄存器与 `be_refetch`；使能全部依赖起拍 full/empty 标志 → 无环。`do_predecode_flush` 依赖 `checker_flush_enable`（checker 的组合输出，在集成时来自 FIFO 队首 → checker），而 checker 的输入依赖 `predecode_can_run` 的 FIFO 读 —— 集成时是 front_ctrl（`predecode_can_run`）→ FIFO 读使能 → FIFO 队首 → checker → `checker_flush_enable` → front_ctrl（`do_predecode_flush`）：这在 front_ctrl 内部不成环（`predecode_can_run` 不依赖 `checker_flush_enable`），集成层要注意 `do_predecode_flush` 只进寄存器和 icache invalidate。
- 与 C++ 的"两次调用 + accumulate"的对应：读调用 = 本拍组合读口；写调用 = 本拍 `wr_en/wdata`；`accumulate` 的"重复 push/pop 则 exit(1)"在 RTL 里天然不可能（每个 FIFO 一个 `wr_en`、一个 `rd_en`）。

## 4. 与 C++ 的差异点、放宽、删除、不复刻

### 4.1 隐含依赖 / 偏差
- **无偏差**（有意义输出逐拍一致，见下）。登记给协调者的几条"等价化简"都在 §4.2/§4.4，且各有穷举/随机回放证明。
- `front_ctrl`：`bpu_icache_read_ready` 的名字有误导（它是"fetch_addr FIFO 没满"，不是 icache ready）——沿用 C++ 的信号含义，没有改名以便和参考模型对照。

### 4.2 放宽（spec 里的 `when`）及消费者核对
| 信号 | `when` | 消费者核对 |
| --- | --- | --- |
| `fetch_addr_fifo.rd_fetch_address` | `rd_valid` | 唯一读取点 `front_top.cpp:1469-1471`：`saved_fetch_addr_fifo_out_0.read_valid ? ... fetch_address`（先判 `read_valid`）；2-ahead/slot1 读取点是死代码 |
| `inst_fifo.rd_*` | `rd_valid` | `saved_fifo_out` 只在 `if (predecode_can_run)`（1733，checker 与 front2back 条目）和 `if (front2back_can_write)`（1793，`front2back_can_write` 含 `predecode_can_run`）里读；而 `predecode_can_run == inst_fifo_read_enable`，`rd_valid` = `rd_en & ~refetch & ~empty`：`predecode_can_run=1` 时 `~inst_empty` 已保证 `rd_valid=1` |
| `ptab.rd_*` | `rd_valid` | 同上（`saved_ptab_out` 与 `saved_fifo_out` 同被 `predecode_can_run` 保护；`saved_ptab_out.dummy_entry` 恒 0）。PTAB 读口无效时 C++ 输出全 0，无人读 |
| `front2back_fifo.rd_*` | `rd_valid` | 读取点：front 输出 mux（`front_output_comb`）：`saved.valid ? FIFO 队首 : (bypass ? 旁路条目 : saved)`，`saved` 无效时是 C++ 的全 0 `front2back_FIFO_out`。该 mux **不在本批模块内**；下游 `back.in.valid[j] = no_taken & FIFO_valid & inst_valid[j]`（`rv_simu_mmu_v2.cpp:1224-1226`），其余 `back.in.*` 逐字段直拷，是否被 Pre-IDU 在 `valid=0` 时读取由 Pre-IDU 的 spec 负责（该 spec 里 `front2pre_*` 目前是严格比较的）。**集成层（`front_core`）构造 `front.out` 时，FIFO_valid=0 且无旁路的拍必须决定这些字段的取值（全 0 或任意）并核对 Pre-IDU 的消费**，我没有替他们放宽 |
| `front_ctrl.refetch_address` | `global_refetch` | 消费者：BPU `refetch ? refetch_address : ...`（`BPU.h:820`）、`if (inp.refetch) req.pc_reg_next = inp.refetch_address`（1779）、2-ahead 目标 `in.refetch ? refetch_address+32 : ...`（1159，目标字段 2-ahead 死）。均受 `refetch` 保护。RTL 因此不再在无 flush 时把 `predecode_refetch_address` 清 0（C++ 清 0），而是每拍无条件装载 `checker_flush_address` |

### 4.3 删除的字段 / 状态
- **8 个 full/empty latch 寄存器**：见 §1.2，改为 `f(size)`。
- **instruction FIFO 条目的 8×pc[]**：C++ 注释写明 "ONLY FOR DEBUG"，唯一读取点是 `front_top.cpp:1737-1742` 的 `exit(1)` 自检（`saved_fifo_out.pc[i] != saved_ptab_out.predict_base_pc[i]`），不翻译；RTL 无此字段（`inst_fifo` 条目 576 位而非 832 位）。
- **PTAB/front2back 的 `predict_base_pc[1..7]`**：`front_ptab_write_comb`（`front_top.cpp:766`）写入 `base_pc[i] = out_pred_base_pc + 4*i`，front2back 条目原样拷贝 PTAB 队首，所以 lane i = lane0 + 4i（32 位回绕）是**构造性恒等式**。额外用一次性 spec `tests/front_basic/ptab_lanes.io` + `check_lanes.py` 在真实程序 5 个（dhrystone/coremark/vm_pagefault/vm_sum_fetch/cjpeg 各 4 万拍）上核对 PTAB 写/读、f2b 写/读、`front.out.pc[]` 共 295,713 个有效条目，0 违例。RTL 只存 lane 0（每个 PTAB/f2b 条目省 224 位）；spec 端口也只有标量 `wr_predict_base_pc`/`rd_predict_base_pc`，下游集成层按 `base+4i` 自行展开 8 个 lane。
- **PTAB 的 `need_mini_flush`、`dummy_entry`**：恒 0（死代码）。
- **`reset` 输入**（FIFO、front_ctrl）：C++ `global_reset = front.in.reset` 只在 `FrontTop::init()` 里为 1（录制窗口内恒 0，分析 §8.2/§8.3），RTL 的 `rst_n` 复位所有状态等价；相应的 `& !global_reset` 项都不建。
- **front_ctrl 里的冗余项**（逐条由 `gen_ctrl.cpp` 里的"逐字转写 C++ + 13 位输入穷举"回放证明等价）：
  1. `front2back_can_write = predecode_can_run & ~f2b_full & ~reset` —— `predecode_can_run` 已含 `~f2b_full`，所以 `== predecode_can_run`；
  2. bypass 条件里的 `~saved_front2back.valid` —— `f2b_empty=1` 时队列无队首，`saved.valid` 必为 0，冗余；
  3. 死代码路径：slot1、mini flush、2-ahead、`fetch→icache` 旁路、`icache→predecode` 旁路、dummy PTAB 项（frontend-boundary.md §3.4）。
- 不进 spec 的 C++ 输出：`bpu_stall`（只用于 `bpu_can_run`）、`f2b_can_write`（等于 `predecode_can_run`）、`commit_stall`（BPU 的 `update_queue_full` 直通，集成层连线）、4 个 FIFO 的 `clear`（= `global_refetch`，f2b 为 `be_refetch`，纯连线）、`front2back_read_enable`（= `be_fifo_read_enable` 直通）。

### 4.4 选择不复刻的 C++ 行为
1. FIFO 空队列写穿（`do_read = read_enable && (has_data || do_write)`）：当前配置下读调用 `write_enable=0` → 从未触发（`fifo_*_pop_when_empty_at_start`、`fifo_fa_write_through_would_be_needed` 全 0）。
2. FIFO 读无效时输出全 0 / 保持残留（`rd_*` 的 `when`）。
3. `predecode_refetch_address` 在无 flush 时清 0（RTL 无条件装载，只在 `refetch` 时有意义）。
4. 所有 `exit(1)` 自检（`accumulate_*` 重复 push/pop、FIFO 溢出/下溢、`fifo.pc != ptab.pc`、`predecode_type` default 分支）：溢出改为运行期断言，其余不可达/调试。
5. 统计/调试（`front_stats`、`front_deadlock_snapshot`、`DEBUG_LOG`、`FRONTEND_HOST_PROFILE_SCOPE`）。
6. `predecode_comb` 里 `inst==0 || inst==INST_NOP` 的特判（opcode 译码已等价）。
7. `sequential_next_pc` 的 `CONFIG_FRONT_VALID_PREFIX_SEQ_NEXT==0` 分支（宏默认 1，整条 `#else` 不编译）。

### 4.5 需要提醒集成者的点
- `front_fifo` 的 `full/empty` 是**起拍**标志，正是 C++ 8 个 latch 的语义（`front_seq_read` 读回的是上一拍 `front_state_req.next_*`，即上一拍结束时的 size）。在 FIFO 的 `wr_en`/`rd_en` 由 `front_ctrl` 给出、`full/empty` 回送 `front_ctrl` 时，没有组合环（`full/empty` 只依赖 `count_q`）。
- `front2back_fifo` 的 `refetch` 只接后端 `in.refetch`，**不是** `global_refetch`（predecode refetch 不清 f2b）。
- `predecode_can_run` 同时就是 inst FIFO 读使能和 PTAB 读使能；`fa_rd_en` 是 fetch_addr FIFO 读使能；`f2b` 读使能 = `be_fifo_read_enable`。
- **SC-L / loop 元数据在默认配置下恒 0**：PTAB 条目 2152 位里 `sc_*`（每 lane 1+1+16+128=146 位）和 `loop_*`（每 lane 3+16+16=35 位）共 8×181=1448 位在默认配置（`ENABLE_TAGE_SC_L=0`、`ENABLE_TAGE_LOOP_PRED=0`）下恒为 0，front2back 同理。RTL 照原宽度保留（这两个开关是配置宏，BPU 翻译时才能决定是否参数化成零宽；删掉它们属于 BPU 层的决定，且 spec 端口会变）。若 BPU 以后固定这两个开关，PTAB/f2b 条目可缩 67%（PTAB 704 位、f2b ~976 位）。
- 配置常量（FIFO 深度、元数据位宽）在 `rtl/frontend/front_pkg.sv`，因为 `ttg_cfg_pkg`（`make cfg`）目前不导出前端专有宏（`FRONT2BACK_FIFO_SIZE`、`TAGE_*_WIDTH`…）。建议协调者让 `make cfg` 导出这些宏并用 `static_assert` 式检查对照（报告里已列为建议）。

## 5. 验证
### 5.1 spec（155 个字段）
`predecode` 5、`sequential_next_pc` 3、`predecode_checker` 8、`fetch_addr_fifo` 8、`inst_fifo` 18、`ptab` 40、`front2back_fifo` 46、`front_ctrl` 27（15 输入 + 12 输出）。全部有 `@` 表达式，可录制。FIFO 的 `rd_*` 都带 `when rd_valid`；`front_ctrl.refetch_address` 带 `when global_refetch`；其余严格比较。

### 5.2 trace
- **真实程序**：`bash scripts/record_all.sh <模块>`（`REFSIM=…/refsim_tap`），73 个程序（61 gate + dhrystone/coremark/coremark10 + 4 vm + float/sha/cjpeg/linear_alg/parser）。拍数上限：6 个窄模块 `GATE_CYCLES=30000`（progs.txt 里的程序 3 万~10 万拍）；`ptab`/`front2back_fifo` 端口很宽（776/870 B/拍），`GATE_CYCLES=8000`。每个模块 73 条 trace，非复位记录数：窄模块 763,068，`ptab`/`front2back_fifo` 669,446。
- **生成的 trace**（`tests/front_basic/`，`run_pure.sh`、`run_fifo.sh`，golden = 参考 C++，见 §5.4）：
  - `predecode`：2 条×201,399（定向：128 个 opcode×各 lane 有效/无效、`inst[31:7]` 每一位单独置位的 jal/branch/jalr 与 pc 极值、随机含 pc 回绕/未对齐）；
  - `sequential_next_pc`：1 条 212,288（穷举 256 种有效模式 × 行内 16 个偏移 × 3 个地址 + 随机，含跨行与 2^32 回绕）；
  - `predecode_checker`：2 条×300,576（定向：每个首个 taken lane 位置 × type × dir；随机，50% 令 BPU 地址恰等于校正地址以覆盖 flush=0）；
  - `front_ctrl`：2 条×140,960（**13 个 1 位输入穷举 × `predecode_refetch` 寄存器的 0/1 两种取值**，各用设置拍强制寄存器状态；+ 10 万随机拍带随机地址）；
  - 4 个 FIFO：各 3 条×60,000（约束随机，见 §5.4）。
- 回放结果（全部 PASS）：`predecode` 75 条 1,166,091 记录；`sequential_next_pc` 74 条 975,578；`predecode_checker` 75 条 1,364,445；`front_ctrl` 75 条 1,045,213；`fetch_addr_fifo`/`inst_fifo` 76 条 943,296；`ptab`/`front2back_fifo` 76 条 849,674（记录数含每条 trace 开头 3 个复位拍）。

### 5.3 覆盖（`tests/front_basic/cov.py`；真实 = 73 个程序，生成 = 随机/穷举）
| 事件 | 真实程序 | 生成的 trace |
| --- | --- | --- |
| FIFO 起拍 `full` 标志 | fetch_addr **0 拍**、inst **0 拍**（结构上不可达）；ptab 225,631 拍；f2b 223,354 拍 | 全部 4 个都出现（fetch 45,195 拍、inst 40,765、ptab 39,919、f2b 29,302）|
| 最大队列深度 | fetch 14/16、inst 15/16、ptab 15/16、f2b 32/32 | 全部满深度（16/16/16/32）|
| clear 时非空 | 14,826 / 12,800 / 15,283 / 669 | 4,310 / 4,166 / 4,546 / 4,034 |
| **clear 同拍 push** | **0**（BPU 在 refetch 拍不发请求）| 3,785 / 3,703 / 3,910 / 3,505 |
| 空队列上 `rd_en`（f2b 读空）| f2b 315,495；其余 0（读使能已含 `~empty`）| 23~27k |
| ptab / f2b 的 SC-L 与 loop 元数据（`sc_used/sc_pred/sc_sum/sc_idx/loop_used/hit/pred/idx/tag`）| **取值恒 0**：默认配置 `ENABLE_TAGE_SC_L=0`、`ENABLE_TAGE_LOOP_PRED=0`（`frontend_feature_config.h:130,142`），实测 20 个程序抽样的 PTAB 写入里 `sc_idx`（195 万个值）、`sc_sum`、`loop_idx` 全为 0 | 满位宽随机 |
| `front2back` `page_fault_inst` | 8000 拍窗口内恒 0 | 随机 |
| front_ctrl 各输出 | `do_predecode_flush` 4,479、`global_refetch` 16,116（后端 11,837 + predecode）、`f2b_use_bypass` 299,008、`bpu_can_run=0` 253,121 拍…；`fa_full` 恒 0 | 13 位输入全组合 × 寄存器 0/1，全部输出都出现 0 和 1 |
| predecode（有效 lane：type 0/1/2/3）| 2,371,613 / 381,784 / 68,337 / 163,664；无效 lane 3,119,146；负立即数 jal/branch 271,173 lane | 808,523 / 614,568 / 321,594 / 615,801 |
| predecode_checker | flush 4,479；首个 taken lane 0..7 × type 1/2/3 全部出现；无 taken 499,451 | flush 209,975 拍，同上全部出现 |
| sequential_next_pc | 有效前缀 0..8 全出现（前缀 8 共 293,430）；**行内截断分支（`& line_mask`）0 次**（icache 返回的组已截在行内，截断恒为空操作，**未证明**，故 RTL 保留）| 33,277 次；256 种有效模式含非前缀型 |

**真实程序覆盖不到、只靠生成 trace 的路径**：FIFO 满（fetch_addr、inst）、clear 与 push 同拍、f2b/ptab 元数据里的 SC/loop 位、page fault 位、`sequential_next_pc` 跨行截断、`predecode` 无效 lane 的 jal 门控（P3；真实程序里无效 lane 的指令字从不是 jal/分支）、`front_ctrl` 的 `fa_full`、`ptab_full & !be_refetch` 的写抑制组合等。其中 "FIFO 满、clear+push" 在参考模型里**本来就不会发生**（死代码/不可达），随机补的是 RTL 的完备性而非真实行为。

### 5.4 随机/穷举激励的约束与 golden
- **纯函数**（`gen_predecode.cpp`、`gen_checker.cpp`）：golden 直接调用参考模型的 `predecode_comb`、`predecode_checker_comb`（链接 `predecode.cpp`、`predecode_checker.cpp`）；`sequential_next_pc` 是 `front_top.cpp` 里的 static 函数，golden 里是逐字拷贝（19 行）。无任何输入约束（纯组合）。
- **FIFO**（`gen_fifo.cpp`）：golden = 通用队列（每个 `wr_*` 与对应 `rd_*` 配对，满位宽随机载荷）；**同时用真实参考 FIFO 类**（`fifo/*.cpp`，按 `front_top.cpp` 协议：读调用 → `accumulate` → 写调用 → `seq_write`）对每个 FIFO 的 control + 一个 tag 字段做逐拍锁步比较（`rd_valid`、队首 tag、size），分歧则生成器直接退出，所以生成的 trace 同时验证了 golden 队列等价于真实 C++ 类。约束：不向满队列（clear 之后）push（C++ 在 `seq_write` 里 `exit(1)`，也是 RTL 的断言）。流量模式每 50~400 拍切换：填满、排空、均衡、1 进 1 出、只写不读；clear 概率 0%/1%/8% 三档，clear 与 push/rd_en 同拍随机。
- **front_ctrl**（`gen_ctrl.cpp`）：golden = **逐字转写** `front_*_comb` 与 `front_comb_calc` S1/S2/S4/S5/S9/S10/S11/S14（`global_reset=0`，已编译掉的路径删去；`saved_front2back.valid` 用 FIFO 的 `do_read` 规则算出，不是常量），所以 RTL 里的化简（§4.3 的 1、2）是被回放证明的，不是靠读代码。

### 5.5 变异检查（`tests/front_basic/mut.sh`，每个变异 = 对 `rtl/` 副本改一处，要求回放失败）
34 个变异**全部被抓到**（34/34 被生成/穷举 trace 抓到；其中 24 个同时被真实程序抓到，**10 个只靠生成的 trace**：P3、S1、C4、F2、F4、F5、F9、K5、K6、K9）。"真实"栏 = 先试 dhrystone/coremark/smc-div/vm_pagefault_test，再试全部 73 个程序。

| # | 变异 | 真实程序（第一个失配）| 生成 trace（第一个失配）|
| --- | --- | --- | --- |
| P1 | B 型立即数 bit11 异或 `inst[31]` | dhrystone@225 `predecode_target_address[1]` | rand_a@741 `…target_address[7]` |
| P2 | jalr 也算目标 `pc+imm` | dhrystone@54 `…target_address[0]` | rand_a@771 |
| P3 | jal 判定不看 `inst_valid` | **未抓到** | rand_a@836 `predecode_type[7]` |
| P4 | lane pc 步长 4→2 | dhrystone@72 `…target_address[4]` | rand_a@739 |
| P5 | J 型立即数符号扩展丢失 | dhrystone@239 `…target_address[3]` | rand_a@837 |
| S1 | 跨行不截断 | **未抓到** | rand_a@192 `seq_next_pc` |
| S2 | 最后一个 lane 总当无效 | dhrystone@72 `seq_next_pc` | rand_a@12243 |
| S3 | 全有效前缀当 7 | dhrystone@72 | rand_a@12243 |
| S4 | 行比较用组末 pc | dhrystone@86 | rand_a@7 |
| C1 | jalr 也用目标 | dhrystone@55 `predict_next_fetch_address_corrected` | rand_a@6 |
| C2 | DIRECT_JUMP 方向取反 | dhrystone@130 `predict_dir_corrected[6]` | rand_a@3 |
| C3 | 无 taken 时地址异或 4 | dhrystone@3 `…corrected` | rand_a@153 |
| C4 | flush 比较忽略低 2 位 | **未抓到** | rand_a@194 `predecode_flush_enable` |
| C5 | JALR 方向取 `predict_dir` | dhrystone@55 `predict_dir_corrected[0]` | rand_a@4 |
| F1 | clear 不重置读指针 | dhrystone@16 `rd_fetch_address` | rand_1@9 |
| F2 | `rd_valid` 不看 clear | **未抓到** | rand_1@81 `rd_valid` |
| F3 | clear 不清计数 | dhrystone@15 `empty` | rand_1@12 |
| F4 | clear 抑制同拍 push | **未抓到** | rand_1@9 `rd_fetch_address` |
| F5 | `full` 阈值 `>=`→`>` | **未抓到** | rand_1@56 `full` |
| F6（ptab）| 读口取 `rd_ptr+rd_valid` | dhrystone@13 `rd_predict_next_fetch_address` | rand_1@15 |
| F7（f2b）| 写指针掩码错（回绕错）| dhrystone@1932 `rd_tage_idx[0][3]` | rand_1@6 |
| F8（inst）| target 地址 lane 反序写入 | dhrystone@73 `rd_predecode_target_address[1]` | rand_1@6 |
| F9（ptab）| `sc_idx` 表序反 | **未抓到** | rand_1@15 `rd_sc_idx[0][0]` |
| F10（f2b）| `base_pc` +4 | dhrystone@1932 `rd_predict_base_pc` | rand_1@4 |
| K1 | refetch 地址选择反（predecode 优先）| dhrystone@3186 `refetch_address` | exh_a@12 |
| K2 | 旁路不看 `f2b_empty` | dhrystone@1932 `f2b_wr_en` | exh_a@14 |
| K3 | `bpu_can_run` 不含 `global_refetch` | dhrystone@62 | exh_a@47 |
| K4 | `fa_wr_en` 不含 `bpu_can_run` | dhrystone@61 `fa_wr_en` | exh_a@5164 |
| K5 | `ptab_wr_en` 不看 `!ptab_full` | **未抓到** | exh_a@10564 `ptab_wr_en` |
| K6 | `do_predecode_flush` 不看 `predecode_can_run` | **未抓到** | exh_a@20487 `do_predecode_flush` |
| K7 | `predecode_can_run` 用 `be_refetch` 代替 `global_refetch` | dhrystone@74 | exh_a@7 |
| K8 | `front_out_valid` 的队首有效不看后端 refetch（用 `be_refetch & can_run`）| dhrystone@1948 `front_out_valid` | exh_a@19 |
| K9 | `bpu_icache_read_ready` 不看 `!fa_full` | **未抓到** | exh_a@47 |
| K10 | 次态 predecode refetch 地址异或 2 | dhrystone@14 `refetch_address` | exh_a@7 |

注：FIFO 变异 F1–F5 作用在共享的 `front_fifo.sv`，经 `fetch_addr_fifo` 的 spec 回放；其余 FIFO 变异经 `inst_fifo`/`ptab`/`front2back_fifo`。因为 4 个实例是同一个 `front_fifo`，F1–F5 对所有实例等价。

### 5.6 复现
```bash
export REFSIM=$RTL_ROOT/refsim_tap
GATE_CYCLES=30000 bash scripts/record_all.sh <predecode|sequential_next_pc|predecode_checker|front_ctrl|fetch_addr_fifo|inst_fifo>
GATE_CYCLES=8000  bash scripts/record_all.sh <ptab|front2back_fifo>     # record_all 会清空 traces/<mod>/，先做 record 再做下面两步
bash tests/front_basic/run_pure.sh      # predecode / sequential_next_pc / predecode_checker / front_ctrl 的 golden trace
bash tests/front_basic/run_fifo.sh      # 4 个 FIFO 的约束随机 trace（锁步对照真实参考 FIFO 类）
bash scripts/replay.sh <模块>            # 全部回放；bash scripts/lint.sh
bash tests/front_basic/mut.sh            # 34 个变异
python3 tests/front_basic/cov.py <模块> --real|--rand
```
一次性检查（不是模块）：`tests/front_basic/ptab_lanes.io` + `check_lanes.py`（base_pc 恒等式，需 `bash scripts/record.sh tests/front_basic/ptab_lanes.io <程序>`）。

