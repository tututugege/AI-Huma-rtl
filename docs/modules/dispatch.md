---
module: dispatch
area: backend
rtl: rtl/backend/dispatch
model: trace-model back-end/Dispatch.cpp、back-end/include/Dispatch.h（调度单元 `back.dis`，类 `Dispatch`，阶段 `comb_alloc`、`comb_dispatch`）
status: 整核周期与模型逐个相等（EXP-060，`fm_gate` 69/69 PASS、0 周期偏差，Linux 26 窗 100% 全等）
depth: 57 层（`rtl/ld-wake`，212,064 单元，开启 `LP_L2[3]` 取消向量与 30 路唤醒，深度 0 增长、面积 +5.9%）（dispatch，单模块综合，2026-11-23，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 10 节）
---

# dispatch 设计文档

> **2026-11-28 `rtl/iss-rr`（Wall #2 + Wall #5）**：
> - `dis_pkg::NUM_LSU_WAKE` 扩至 `3 * LSU_LDU_COUNT + 2 = 14` 路，并新增 `iss_awake_cancel[ALU_NUM]`（6 路 1 周期 ALU 孙代取消）与 `lsu2iss_cancel[4]` 共同并入 `cancel_v` 恢复忙表；
> - **Wall #5（0 周期变化）**：`dispatch_iq_alloc` 直接导出未截断前向占用位置 `used_pos[NUM_SLOTS][IQ_NUM]`（防止 `IQ_MEM` 多条 AMO 绕回冲突），`dispatch_iq_req` 据此仅用 `inst_valid` 与 `used_pos` 选择 `req_uop`，将 `dis_fire` 从 8:1 数据选择器树剥离，仅用于门控 `req_valid`；同时移除冗余 `dispatch_wake_match`，`dispatch_src_busy` 仅读取 `busy_table | cancel_v` 与组内 RAW（同拍唤醒由 `dispatch_busy_table` 为滞留/下拍指令清忙位、由 `isu_iq` 在入队口叠加至已分派 uop，消除 LSU/EXU 唤醒经 Dispatch 再绕回 IQ 入队的跨模块组合长链）。

## 1. 职责

分派：重命名之后、进发射队列之前的一级寄存器。每拍对这一级里的 8 条指令（每条占一个 lane）做：

1. 分配资源：每条指令的 ROB 位置（`rob_idx`、`rob_flag`）、load 的 LDQ 项、load / store 的 STQ 位置；
2. 拆成微操作（uop）：一条指令拆成最多每种一个的 uop，种类 `K_INT / K_LD / K_STA / K_STD / K_BR / K_FP`（例：store 拆成 STA 和 STD，JAL / JALR 拆成 INT（算 pc + 4）和 BR（跳转），AMO 读改写拆成 LD、STA、STD）；
3. 把 uop 映射到 6 个发射队列（INT0、内存（load 和 STA 合并）、STD、BR、FP、INT1），按队列的剩余空间和入队 lane 数决定这条指令能不能整条放下；
4. 算源寄存器的"还在等"位（`src*_busy`）：查忙表、叠加本拍的唤醒、本组里比自己老的指令写了同一个物理寄存器的也算在等；
5. 决定哪些 lane 本拍分派（`dis_fire`），并把 ROB 入队、发射队列入队（`dis2iss`）、LSU 的 LDQ / STQ 分配（`dis2lsu`）、对重命名的反压（`dis2ren.ready`）同时发出。

模型对应一个调度单元 `back.dis`，内部两个阶段：`comb_alloc`（资源分配，输入 LSU 和 ROB 的状态）和 `comb_dispatch`（拆分、busy、fire、请求）。RTL 的子模块边界是为综合划的，模型里没有对应的类。

## 2. 配置（`ttg_cfg_pkg` / `dis_pkg`，现行默认）

| 项 | 值 | 常量 |
| --- | --- | --- |
| lane 数 | 8 | `DECODE_WIDTH`（`dis_pkg::NUM_SLOTS`） |
| 发射队列 | 6 个：INT0 = 0、内存 = 1、STD = 2、BR = 3、FP = 4、INT1 = 5 | `dis_pkg::IQ_NUM = 6`，`IQ_INT/IQ_MEM/IQ_STD/IQ_BR/IQ_FP/IQ_INT1` |
| 每队列请求口数 | 8 | `MAX_IQ_DISPATCH_WIDTH`（`IQ_PORTS`） |
| uop 种类 | 6 | `dis_pkg::K_NUM`：`K_INT/K_LD/K_STA/K_STD/K_BR/K_FP` |
| STQ / LDQ 分配口 | 各 8 | `MAX_STQ_DISPATCH_WIDTH`、`MAX_LDQ_DISPATCH_WIDTH` |
| STQ / LDQ 项数 | 各 64 | `STQ_SIZE`、`LDQ_SIZE` |
| 忙表 | 352 位（每个物理寄存器标号一位；整数 0..255，FP 从 256 起） | `TAG_NUM = 352`（`PRF_NUM + FPRF_NUM`）、`FP_TAG_BASE = 256` |
| 唤醒通道数 | `3*LSU_LDU_COUNT + 2 = 14` 路 LSU 唤醒（L1 推测 4 + L3 直发 4 + L2b STLF/L2a fallback 4 + WBP `64→2` one-hot 2）；加上 `iss_awake`（`MAX_WAKEUP_PORTS`）与 6 路 `iss_awake_cancel` 共同组成唤醒/取消输入 | `dis_pkg::NUM_LSU_WAKE = 3 * LSU_LDU_COUNT + 2`，`NUM_WAKE = MAX_WAKEUP_PORTS + NUM_LSU_WAKE` |
| 完成组 | G0 = INT / LD / FP，G1 = BR / STA，G2 = STD | `dis_pkg::CPLT_G0/1/2` |

uop 种类到队列的映射（`dispatch_core.sv` 里的 `has_iq`；模型 `route_iq`，`include/util.h`）：

| uop 种类 | 去哪个队列 |
| --- | --- |
| `K_INT` | CSR 类（`UOP_CSR`）进 INT0；整数转浮点（`UOP_I2F`）进 INT1；其余按这条指令 `rob_idx` 的最低位：偶数进 INT0，奇数进 INT1 |
| `K_LD`、`K_STA` | **都进内存队列**；AMO 读改写同时有 LD 和 STA，一条指令向内存队列送两个 uop |
| `K_STD` | STD 队列 |
| `K_BR` | BR 队列 |
| `K_FP` | FP 队列（FMA、FDIV、FMISC；仅 `FPRF_NUM != 0`） |

被消除的 move（`me_elim`，见 ren.md）一个 uop 也没有，它不进任何队列，在 ROB 里的完成组要求为空（`expect_mask = 0`），分派时就算完成。

## 3. 接口

信号组按模型的 `in` / `out` 命名；顶层 `dispatch.sv` 只做平铺端口和结构体互转。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `ren2dis_valid[8]`、`ren2dis_uop_*[8]` | 重命名后的指令（含 `dest_preg`、`src*_preg`、`old_dest_preg`、`me_elim`、FP 标志…）；`is_rvc`、`mdp`（等待表下标）**不是**重命名送来的，见下 |
| 入 | `rob2dis_{ready, empty, stall, enq_idx, free, rob_flag}` | ROB 的状态：不满、空、队头 8 槽里有冲刷类、尾部位置、空闲项数、环绕标志 |
| 入 | `iss2dis_ready_num[IQ_NUM]` | 每个队列还能收几个（`min(空闲槽, 入队 lane 数)`，寄存值，见 isu.md） |
| 入 | `lsu2dis_{stq_tail, stq_tail_flag, stq_free, ldq_free, ldq_alloc_idx[8], ldq_alloc_valid[8]}` | LSU 的 STQ 尾、空闲数、LDQ 空闲项的编号 |
| 入 | `prf_awake_*`、`iss_awake_*`、`iss_awake_cancel_*`、`lsu2iss_wake_*`、`lsu2iss_cancel_*` | 唤醒（`MAX_WAKEUP_PORTS` + `NUM_LSU_WAKE=14` 路：L1 推测 4 + L3 直发 4 + L2b STLF/L2a fallback 4 + WBP `64→2` 2）；取消输入含 `lsu2iss_cancel`（4 路 L1 取消）与 `iss_awake_cancel`（6 路 ALU 孙代取消） |
| 入 | `rob_bcast_flush`、`dec_bcast_mispred` | 全局冲刷（`FLUSH_REG` 后晚一拍，docs/FLUSH_REG.md）、误预测 |
| 出 | `dis2ren_ready` | 重命名可以送下一组 |
| 出 | `dis2rob_dis_fire[8]`、`dis2rob_uop_*[8]` | 本拍分派的 lane 和写进 ROB 的字段（含 `rob_idx`、`expect_mask`、`fs_need`） |
| 出 | `dis2iss_req_valid / _uop_* [IQ_NUM][8]` | 每个队列的 8 个请求口 |
| 出 | `dis2lsu_*`、`dis2lsu_ldq_*` | LSU 的 STQ / LDQ 分配请求（`alloc_req`、`rob_idx / rob_flag`，load 另带 `ldq_idx`、`mdp`、`pc`） |
| 出 | `pmu_slot_valid[8]` | PMU：这一级每个 lane 是否有指令 |

`is_rvc` 和 `mdp`：RTL 的 `back_top` 把重命名送出的 `ftq_idx / ftq_offset` 接到 `ftq_ibuf` 的 `ftq_dis_req_*` 读口，读回 `is_rvc`、`mdp` 和 `pc`（load 的 pc 哈希，`LSU_MEMSPEC` 用，`LSU_MDP_BITS = 6`），再接进 `ren2dis_uop_is_rvc / _mdp / _pc`。模型里这两项随指令一路带过来。

## 4. 结构

```
 ren2dis ─► dispatch_inst_stage（8 lane 的寄存器：本级的输入）
              │
              ├─► dispatch_lsu_alloc  : load / store 的 LDQ / STQ 项和请求口（按序秩）
              ├─ rob_idx = 尾 + 有效 lane 的序号
              ├─► dispatch_src_busy   : busy_table | cancel_v + 组内 RAW ─► busy1/2/3
              ├─► dispatch_decompose × 8 : 一条指令 ─► 每种 uop 一个 + expect_mask
              ├─► dispatch_iq_alloc   : 每队列的请求口号、整条指令是否放得下（fit）
              ├─► dispatch_fire_ctl   : dis_fire、dis2ren_ready
              ├─► dispatch_iq_req     : 按口号把 uop 送到队列的请求口（只送已 fire 的）
              ├─► dispatch_lsu_req    : 已 fire 的 load / store 向 LSU 发请求
              └─► dispatch_busy_table : 忙表（置位：fire 的目的寄存器；清除：唤醒）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `dis_pkg.sv` | 209 | 队列号、uop 种类、指令 / uop 结构体、指令分类函数 `dis_classify` |
| `dispatch.sv` | 182 | 顶层：端口适配；合并 `NUM_WAKE = 35` 路唤醒；由 4 路 L1 推测取消与 6 路 ALU 孙代取消生成取消向量 `cancel_v`；`fs_need`（F/D） |
| `dispatch_core.sv` | 254 | 把下面的子块连起来；`rob_idx` 编号；uop 到队列的映射（`has_iq`） |
| `dispatch_inst_stage.sv` | 60 | 输入寄存器，见下 |
| `dispatch_decompose.sv` | 142 | 一条指令拆成 uop；`expect_mask` |
| `dispatch_lsu_alloc.sv` | 79 | LDQ / STQ 分配 |
| `dispatch_src_busy.sv` | 53 | busy 位计算（`busy_table | cancel_v` + 组内 RAW） |
| `dispatch_wake_match.sv` | 29 | 唤醒号与源寄存器号的比较；现在没有任何模块实例化它（死代码，留待删除） |
| `dispatch_busy_table.sv` | 47 | 忙表 |
| `dispatch_iq_alloc.sv`、`dispatch_iq_req.sv` | 49、52 | 队列请求口号与 fit；请求口的数据选择 |
| `dispatch_fire_ctl.sv` | 71 | 哪些 lane 分派，`dis2ren.ready` |
| `dispatch_lsu_req.sv` | 65 | 发给 LSU 的分配请求 |

状态：`dispatch_inst_stage` 的 `valid_q[8]`、`inst_q[8]`（`dis_inst_t`）；忙表 `busy_q[TAG_NUM]`（352 位）。其余都是组合逻辑。

输入寄存器 `dispatch_inst_stage`：分派 ready 时（`dis2ren_ready`）整组换成重命名送来的新组；没 ready 时保留没 fire 的 lane（下一拍直接重新查 `busy_table`）；冲刷或误预测（`kill = rob_flush | dec_mispred`）清所有 valid。

## 5. 一拍内的数据流

### 5.1 资源分配（`comb_alloc`）

- `rob_idx = rob2dis_enq_idx + 本 lane 前面的有效 lane 数`，`rob_flag = rob_flag ^ 进位`。有效 lane 指寄存器里有指令的（不看能不能 fire，与模型的 `rob_k++` 一致）；
- store：`stq_idx = stq_tail + 前面的 store 类 lane 数`；load 记下"它前面最后一个 store"的 STQ 位置（用于判断 store→load 顺序），也是 `stq_tail + 前面的 store 数`；
- load：取 LSU 给的第 k 个空闲 LDQ 项（k = 前面的 load 类 lane 数）；store 和 load 能不能分到，只比 `秩 < 空闲数`（`stq_free`、`ldq_free`）；
- load 类 = LOAD 和除 SC 外的 AMO；store 类 = STORE 和除 LR 外的 AMO。

### 5.2 busy 位

`busy = en & ((忙表[preg]) | 本组里比我老的有效 lane 写了同一个 preg)`；"写了寄存器"指 `dest_en` 且（目的寄存器不是 x0 或是 FP 寄存器），并且不是被消除的 move（它没有自己的寄存器）。忙表在读口上先和 `cancel_v` 相或（推测唤醒被取消的寄存器重新变忙）；同拍唤醒不在此重复做 CAM，而是在 `isu_iq` 入队侧 `enq_wait` 与 `dispatch_busy_table` 中叠加。

### 5.3 拆分与入队

- 每个 lane 用 `dispatch_decompose` 得到它每种 uop 和 `expect_mask`；STORE：STA 只用 src1，STD 只用 src2；AMO：LD 不用 src2，STA 的 `dest_en` 只在 SC 时为 1（SC 的 0 / 1 结果走 STA 的写回），STD 标 `is_atomic`、读改写的 STD 的数据源是 load 的目的寄存器（SWAP 不用等它）；JAL / JALR 的 INT uop 立即数是指令长度（压缩指令 2，否则 4），不读源寄存器；
- `expect_mask`：有 INT / LD / FP uop 则含 G0，有 BR / STA 则含 G1，有 STD 则含 G2；SC 固定为 G0 | G2；
- `dispatch_iq_alloc`：每个队列，这个 lane 前面所有有效 lane 已经占了 `used` 个口，本 lane 要放 `cnt`（0、1，内存队列最多 2）个，`used + cnt <= ready_num[q]` 才算该队列放得下；各队列都放得下才 `fit`。`ready_num` 已经取过入队 lane 数的上限（isu.md），所以不再单独比较入队宽度；
- `dispatch_iq_req`：口号 = `used`；只有 fire 的 lane 才驱动请求口，所以不需要"撤回"。

### 5.4 fire

lane i 可以分派的条件（`dispatch_fire_ctl`）：寄存器里有指令、LSU 项够（`lsu_ok`）、队列放得下（`fit`）、ROB 不满（`rob_ready`）、ROB 空闲项数大于它前面有效 lane 数、没有全局冲刷（`rob_flush | dec_mispred | rob2dis_stall`）、不被串行化挡住。**串行化**：CSR 类（CSR、MRET、ECALL、EBREAK）和 AMO 要求 ROB 为空且前面没有有效 lane（它们独占）。此外前面任何一个有效 lane 没能 fire 就挡住所有更年轻的 lane（顺序分派）；AMO 或 WFI 一旦 fire，它之后的 lane 本拍也不能 fire。`dis2ren_ready` = 没有任何 lane 构成"停止点"（没能 fire 的有效 lane，或 AMO / WFI）。

### 5.5 忙表

`busy_d = 本拍 fire 的目的寄存器置位 | ((busy | cancel_v) & ~本拍所有唤醒)`：置位优先于清除（模型先清后置）。被消除的 move 的目的寄存器不置位。

## 6. 关键路径与深度

单模块综合深度 **56 层**（dispatch；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_core.u_inst_stage.inst_q [1863]` 到 `\u_core.u_busy_table.busy_q [222]`。

从代码读出的长组合链（未综合验证）：

| 链 | 经过 |
| --- | --- |
| 分派判决 | 唤醒比较（24 个源 × `NUM_WAKE = 35` 路）→ busy 位 →（busy 只进队列数据，不进 fire）；fire 本身：`lsu_ok`（秩 < 空闲数，`ttg_popcount` 秩）、`fit`（每 lane 对 6 个队列各自前缀数 + 比较）、`rob_fit`（前缀数 + 比较）→ `fire_ideal` → 与"前面有 lane 不能 fire"的或 → `dis_fire` |
| fire 之后 | `dis_fire` → ① `dispatch_iq_req`（每个请求口 8 选 1 的 uop 选择，两套：第一个 uop 和 AMO 的第二个）→ `dis2iss`；② `dispatch_lsu_req` → `dis2lsu`；③ 忙表置位 → 次态；④ `dis2ren_ready`（再进重命名的 fire 和 IDU 的 fire 链）→ 各级输入寄存器的 `ready ? new : held` |
| 分配 | `rob2dis_enq_idx` 加有效 lane 秩 → `rob_idx`；经 busy / `dis2iss` 的 uop 字段送到队列入队（isu 入队再叠加本拍唤醒） |

已经做过的降深度改动：`64a908e` load 授予只看空闲数（`ldq_free`），选择器的串行链只产生下标；STQ 指针在冲刷 / 误预测那一拍用寄存的计数和 `br_mask`（该拍不分配），lane 之前的请求数用 popcount。`fire` 本身写成并行形式（"没有停止点则前面的有效 lane 都已 fire"，`dispatch_fire_ctl.sv` 注释），不是模型里的串行标志。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `dbg`、`ROBTR` / `DISTR` 调试输出、`Assert`、PMU 的 `iq_blk` / `fit_` / `pmu_slots`（RTL 只输出 `pmu_slot_valid`）；
- 模型里 uop 在 `uop_pool` 里单独占一项（`make_dis_iss_uop` 分配 `id`），RTL 里 uop 是直接带字段的结构体；
- 模型 `comb_alloc` 对"load 超过内存队列入队宽度"单独检查，RTL 由 `fit` 的 `used + cnt <= ready_num`（已含入队宽度上限）一并处理；
- 忙表的唤醒通道数两边相同：模型 `WAKE_CH_ALL = MAX_WAKEUP_PORTS + LSU_EARLY_WAKE_PORTS = 21 + 14`（`back-end/include/IO.h`），RTL `dis_pkg::NUM_WAKE = MAX_WAKEUP_PORTS + NUM_LSU_WAKE = 35`（`iss_awake` 21 路 + `lsu2iss_wake` 14 路；PRF 的 load 唤醒已经包含在 `iss_awake` 里，不再另接）。

已发现、未改动的点：

- 上一条的重复唤醒口（4 路）可以去掉；
- `dispatch_lsu_alloc` 的输入 `ldq_alloc_valid` 不被使用（注释写明：授予只看 `ldq_free`），模型里是 `lsu.ldq_alloc_valid[loads]` 参与判断；两者在现行 LSU 下等价，但 RTL 没有检查；
- `dispatch.sv` 里 `rob2dis_enq_idx` 的注释写"4 位行指针"，是已删除的行式 ROB 的说法，现在它是 7 位的尾位置；
- `dis_pkg` 里 `UOP_TYPE_W` 的注释写"18 个 UopType 值"，`uop_op_e` 实际有 21 个值（宽度同为 5 位）。

RTL 与模型保持一致的细节（读模型时容易误判）：

- 一个 lane 的 uop 放不下任何一个队列，整条指令都不分派，不会只放一半；
- 只有 fire 的 lane 才占请求口，所以没有"撤回"；
- 没有 fire 的 lane 保留在寄存器里，busy 位用本拍唤醒刷新；
- INT 队列的选择看的是**这条指令**的 `rob_idx` 最低位，不是 lane 号（两者通常不同：`rob_idx` 是尾位置加有效 lane 数）。

**未核对（继承自旧文档）**：无（旧文档的内容全部没有采用）。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`（`scripts/regen_refs.sh` 由模型默认配置生成）：77/77 通过（最近一次 rtl 73761fa，2026-11-28），周期逐个相等。
- **PMU**：`scripts/pmu_parity.sh`（一级事件含 `SLOT_FIRE`、`SLOT_KILL`）；本模块只输出 `pmu_slot_valid`。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧体系（`spec/` 的 trace 回放和变异检查）已退役。**待补**：给 `dispatch_decompose`（对照模型 `decompose_inst`）和 `dispatch_iq_alloc` / `dispatch_fire_ctl`（对照模型的串行 `comb_dispatch`）各补一个新旧并排的随机测试；目前正确性靠整核周期逐拍相等和 Linux 启动。

## 9. 参数与开关速查

`DECODE_WIDTH`、`MAX_IQ_DISPATCH_WIDTH`、`MAX_STQ_DISPATCH_WIDTH`、`MAX_LDQ_DISPATCH_WIDTH`、`STQ_SIZE`、`LDQ_SIZE`、`TAG_NUM`、`FPRF_NUM`（FP 队列和 FP uop 是否存在）、`LSU_MEMSPEC` / `LSU_MDP_BITS`（`mdp`）。取消向量 `cancel_v` 总是生成（原 `LP_L2[3]` 条件已随 `LP_L2` 删除）。`ttg_cfg_pkg.sv` 由 `make cfg`（`harness/tools/gen_cfg_pkg.py`，从 trace-model `include/config.h`）生成，不手改。

## 10. 变更记录

- 2026-11-28（文档核对，无 RTL 变化）：忙表 `TAG_NUM = 352` / `FP_TAG_BASE = 256`；`NUM_WAKE = 35`，与模型 `WAKE_CH_ALL` 一致；去掉分支掩码相关描述；`is_rvc / mdp / pc` 来自 `ftq_ibuf`；文件表行数并补 `dispatch_wake_match.sv`（未实例化）；`ttg_cfg_pkg` 为生成文件；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
`git log --oneline 261bd67..HEAD -- rtl/backend/dispatch`：

- `2e6acb6`：去掉空的 STA 队列和 `MEM_MERGE = 0` 的路径，现为 6 个队列（INT、MEM、STD、BR、FP、INT1）；`dispatch_decompose` 按种类拆分，`dispatch_core` 把种类映射到队列。
- `64a908e`：load 授予只看空闲数；冲刷 / 误预测那拍的 STQ 指针更新用寄存值；lane 之前的请求数用 popcount。
- `6d7ed85`：两个 INT 队列（CSR 进 INT0、I2F 进 INT1、其余按 `rob_idx` 奇偶）；2026-11-18 删掉 `INT_CLUSTERS` 开关，分流直接写成唯一做法。
- `237738c`：load 和 STA 合并进一个内存队列（`dispatch_iq_alloc`、`dispatch_iq_req` 按队列计数和放置，AMO 向内存队列送两个）。
- 更早：见 git 历史。
- 2026-11-23（`rtl/ld-wake`，EXP-060）：随 `LP_L2[3]=1` 启用 `g_cancel` 取消向量与 30 路唤醒；`eda-08` Yosys：`dispatch` **57 层**（较 EXP-059 57 层 0 增长）/ 212,064 单元（+5.9%）；`fm_gate` 69/69 PASS 0 周期差，Linux 26 窗 100% 全等。
- 2026-11-18：删除 `ROB_COMPACT == 0`（行式 ROB）的分支：`dispatch_core` 里 `rob_idx` 按行编号的写法、`dispatch_fire_ctl` 里 `rob_fit` 恒真的写法，以及 `dis_pkg` 里只给它们用的 `ROB_BANK_W`、`ROB_LINE_W`。
