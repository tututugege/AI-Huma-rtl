---
module: pmu
area: core
rtl: rtl/pmu（pmu.sv、pmu_ev_core.sv、pmu_ev_pkg.sv）
model: trace-model include/pmu_events.def（事件表，唯一来源）、back-end/include/Pmu.h、back-end/Pmu.cpp、back-end/PmuSample.cpp（`BackTop::pmu_sample`，打开 `PMU=1` 才工作）。模型没有 CSR 侧
status: 事件总线（tier 1，18 个事件）与模型逐事件相等（scripts/pmu_parity.sh；本次没有重跑）；计数器块 `pmu.sv` 没有接进核（CSR 侧未接线）
depth: 90 层（pmu，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# pmu 设计文档

## 1. 职责

性能监测单元（EXP-013）。分三块：

1. **事件总线**：`ev_inc[PMU_NUM_EV-1:0][PMU_INC_W-1:0]`，第 i 条通道是事件 i 本周期的增量（一个小整数）。事件表由模型的 `include/pmu_events.def` 定义，RTL 的 `pmu_ev_pkg.sv` 由 `scripts/gen_pmu_pkg.py` 从它生成（事件 id = 在表里的位置），所以同一个事件在模型、RTL 和分析脚本里 id 相同；
2. **事件产生**（`pmu_ev_core`）：从提交槽、冲刷 / 重定向信号和分派槽，在核里（`core_top`）算出"tier 1"事件的增量，其余通道恒为 0；
3. **计数器块**（`pmu`）：2 个固定 64 位计数器（`mcycle`、`minstret`）加 `NUM_HPM`（默认 8）个可编程 64 位计数器（每个 = 一个事件选择寄存器 + 66 选 1 的增量选择 + 64 位加法器），`mcountinhibit`、`mcounteren`，通过标准的机器态计数器 CSR 读写。没有溢出中断（计数器 64 位）。

**CSR 侧没有接线**：`pmu` 模块在 `rtl/` 里没有被任何模块实例化（`grep` 只在 `rtl/pmu` 自己里找到），`csr_*` 端口无人驱动，计数器还不能被软件读到；目前真正在用的是事件总线，测试平台按层次名读 `core_top` 里的 `pmu_ev_inc`（`tb/soc/pmu_public.vlt`），与模型逐事件对比。`rtl/README.md` 也写着"tier 1，CSR 未接"。

## 2. 配置（`pmu_ev_pkg`、`pmu` 参数）

| 量 | 值 | 来源 |
| --- | --- | --- |
| 事件数 `PMU_NUM_EV` | 66 | `pmu_ev_pkg.sv`（生成） |
| 增量位宽 `PMU_INC_W` | 8（所有事件里最宽的增量，`OCC_ROB` 8 位） | 同上 |
| 每事件增量位宽 `PMU_EV_W[]` | 见生成文件 | 同上；模型 `pmu_events.def` 的第三列 |
| 事件选择 | `mhpmevent[7:0]` = 事件 id + 1，0 = 不计数 | `pmu.sv`（`hpm_event_q == 8'(e + 1)`） |
| 可编程计数器数 `NUM_HPM` | 8（参数，至多 29） | `pmu.sv` |
| 提交宽度 `COMMIT_W` | 8（`pmu_ev_core` 参数，`core_top` 传 `COMMIT_WIDTH`） | `core_top.sv` |

模型事件表共 85 项，其中 19 项标了 `// model-only`（`SLOT_FE_OTHER_NOPREG`、`SLOT_FE_OTHER_NOBRTAG` 和 17 个 `FEO_*` 前端交付拆分事件），生成器跳过它们（`gen_pmu_pkg.py`）；要求"带 RTL 通道的事件在表里排在前面，model-only 的只能排在表尾"（生成器有断言），所以 RTL 的 66 个 id 与模型的前 66 个 id 一致。

## 3. 接口

`pmu`（计数器块）：

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `ev_inc[PMU_NUM_EV][PMU_INC_W]` | 事件总线 |
| 入 | `csr_addr[11:0]`、`csr_wen`、`csr_wdata[31:0]`、`csr_prv_m` | CSR 口：地址、写使能（提交 CSR 指令的那一拍）、写数据、当前是否机器态 |
| 出 | `csr_hit`、`csr_rdata[31:0]`、`csr_illegal` | 地址是否属于本块、读数据、是否非法（→ 非法指令异常） |

`pmu_ev_core`（事件产生）：

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `commit_valid[COMMIT_W]`、`commit_type[COMMIT_W]`、`interrupt` | 退休流；`interrupt` 为真的周期里提交槽不算退休 |
| 入 | `flush`、`exception`、`redirect` | `rob_bcast_flush`、`rob_bcast_exception`、`out_mispred`（冲刷也会让它为真） |
| 入 | `slot_valid`、`slot_fire` | 分派级每个槽有无指令、有无分派（来自 `back_top` 的 `pmu_slot_valid`、`dis2rob_dis_fire`） |
| 出 | `ev_inc` | 事件总线 |

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `pmu_ev_pkg.sv` | 88 | 生成：事件 id、每事件位宽（已提交；改事件表后重新生成：`python3 scripts/gen_pmu_pkg.py <pmu_events.def>`） |
| `pmu_ev_core.sv` | 121 | tier 1 事件的产生；分派槽的自顶向下分类 |
| `pmu.sv` | 155 | 计数器、CSR 译码与读写 |

`scripts/gen_pmu_pkg.py` 同时写 `tests/pmu/pmu_ev_widths.inc`。该脚本的默认输入路径是 `../trace-model/include/pmu_events.def`（环境变量 `PMU_EVENTS_DEF` 可改）。

状态：`pmu_ev_core`：`recovering_q`、`recov_flush_q`（冲刷 / 误预测之后"重填中"的标志，各 1 位）；`pmu`：`cnt_q[2+NUM_HPM]`（64 位）、`hpm_event_q[NUM_HPM]`（8 位）、`inhibit_q`、`counteren_q`。

**tier 1（RTL 上有数的事件）共 18 个**，id 与名字：

| 组 | 事件 |
| --- | --- |
| 周期 / 退休 | `CYCLES`(0)、`INSTRET`(1)、`COMMIT_LOAD`(2)、`COMMIT_STORE`(3)、`COMMIT_BRANCH`(4)、`COMMIT_JUMP`(5)、`CYC_COMMIT_ZERO`(10)、`CYC_COMMIT_FULL`(11) |
| 分派槽（自顶向下第一层） | `SLOT_FIRE`(12)、`SLOT_KILLED`(13)、`SLOT_FE_EMPTY`(14)、`SLOT_FE_RECOV_MISPRED`(15)、`SLOT_FE_RECOV_FLUSH`(16)、`SLOT_BE`(20) |
| 流 | `BR_MISPRED`(31)、`FLUSH_EXCEPTION`(32)、`FLUSH_OTHER`(33)、`CYC_RECOVERING`(34) |

这与 `scripts/pmu_parity.sh` 里的 `T1` 列表一致。其余 48 条通道（`COMMIT_RET`、`COMMIT_MISPRED_*`、前端 / ICache / ITLB 事件、L1D、预取、占用、发射队列的空间 / 宽度 / 占用事件等）在 RTL 上恒为 0，只有模型在数（`pmu_events.def` 文件头："The other events need new ports (dispatch, ICache, DCache, LSU) and are only in the trace-model for now"）。

## 5. 一拍内的数据流

### 5.1 `pmu_ev_core`

- **退休类**：`retire[i] = commit_valid[i] & !interrupt`；`load` = 类型为 LOAD 或 AMO，`store` = STORE 或 AMO（AMO 同时算 load 和 store）；`branch` = BR；`jump` = JAL 或 JALR；各用 `ttg_popcount` 数槽；`CYC_COMMIT_ZERO` = 本拍退休 0 条，`CYC_COMMIT_FULL` = 退休 `COMMIT_W` 条。类型编码是 `pmu_ev_core` 里的常量（JAL 1、JALR 2、BR 4、LOAD 5、STORE 6、AMO 18），与 `dis_pkg.sv` 的指令类型枚举 `inst_type_e` 的编号一致（NOP 0、JAL 1、JALR 2、BR 4、LOAD 5、STORE 6、AMO 18）。
- **流类**：`BR_MISPRED = redirect & !flush`；`FLUSH_EXCEPTION = flush & exception`；`FLUSH_OTHER = flush & !exception`。
- **分派槽**（每槽恰好落入一类）：`kill = redirect`；`blocked[i]` = 非 kill 且（前一槽已 blocked，或本槽有效但没分派）——从第一个有效但没分派的槽起往后都算后端停顿；`killed` = 有效、未分派、且本拍是 kill；`empty` = 其余未分派的槽；`FIRE` = 分派的槽数。`recovering_q`：kill 后置位，直到再有槽有效（`|slot_valid`）才清；`recov_flush_q` 记是冲刷还是误预测。重填期间的空槽数记到 `SLOT_FE_RECOV_FLUSH` 或 `SLOT_FE_RECOV_MISPRED`（`recov_now = recovering_q | kill`）；`CYC_RECOVERING = recovering_q`。恒等式 `slots = FIRE + FE_EMPTY + BE + KILLED` 每拍成立（`pmu_events.def` 文件头说由模型 `PMU=1` 检查）。

### 5.2 `pmu`

- 增量选择：`inc[0] = ev_inc[CYCLES]`、`inc[1] = ev_inc[INSTRET]`，第 k 个可编程计数器取 `hpm_event_q[k] == id + 1` 的那条通道；
- 次态：计数器未被 `mcountinhibit` 对应位禁止就加 `inc`；机器态写 CSR 时：写 `mcounteren` / `mcountinhibit`（只改在用的位：bit 0 = CY、bit 2 = IR、bit 3+k = HPM k，bit 1 保留）、写 `mhpmevent3+k`（低 8 位）、写 `mcycle` / `minstret` / `mhpmcounter3+k` 的低或高 32 位（`…H`）——写入优先于本拍的增量；
- 读：机器态可读所有；用户态只能读 `cycle`、`instret`、`hpmcounter3+k` 及其 `H` 影子，且要 `mcounteren` 对应位为 1，影子只读（写则非法）；其他 PMU 地址在非机器态为非法。

地址（`pmu.sv` 常量）：`mcounteren` 0x306、`mcountinhibit` 0x320、`mhpmevent3` 0x323..、`mcycle` 0xB00、`minstret` 0xB02、`mhpmcounter3` 0xB03..、`mcycleh` 0xB80 等、用户影子 0xC00 / 0xC02 / 0xC03.. 和 0xC80...

## 6. 关键路径与深度

单模块综合深度 **90 层**（pmu；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。从代码读出的、未综合验证的链：

- `pmu_ev_core`：`blocked` 是 8 槽的串行 OR 链（`blocked[i]` 依赖 `blocked[i-1]`），之后 `ttg_popcount`（8 位串行加法）→ `ev_inc`；这是纯 PMU 逻辑，起点是分派和 ROB 的输出；
- `pmu`：每个可编程计数器是 66 选 1（用 `==` 比较生成的 AND-OR，66 项）+ 64 位加法；CSR 读口是对计数器的多路选择。因为没有接进核，当前不在任何关键路径上。

## 7. 与模型的差异和取舍

- 模型的事件向量（`PmuVec`，`uint16_t v[PMU_NUM]`）与 RTL 的事件总线含义相同；模型另有 RTL 不实现的分析层（每 PC 的画像、直方图、时间序列、`PMU_INTERVAL`、`PMU_PCPROF`，`Pmu.h` 的第二层）和 19 个 model-only 事件；
- 模型在后端采样（`BackTop::pmu_sample`，`SimCpu::cycle` 在所有组合阶段之后调），RTL 在 `core_top` 里用 `pmu_ev_core` 即时产生；
- 模型没有 CSR 侧（模型源码里搜不到 `mcountinhibit`、`mhpmcounter`、`mcycle` 这些 CSR），所以 `pmu.sv` 的 CSR 行为没有模型参照，只有 `tests/pmu` 里自带的 C++ 参考实现；
- tier 1 以外的事件 RTL 上恒为 0，由 `pmu_events.def` 里的 `// model-only` 标记（只有表尾的 19 项）和文件头的 tier 1 列表区分，但"有 id 却没接线"的 48 条在生成的包里看不出来。

## 8. 验证

- **事件总线对模型**：`scripts/pmu_parity.sh <prog.bin> [soc_tb] [trace-model simulator]`：RTL 测试平台（`SOC_TB_PMU=1`）与模型（`PMU=1`）逐事件总数对比 tier 1 的 18 个事件，必须相等。脚本默认的模型路径是 `../trace-model-pmu/...`（旧的 PMU 工作树）。
- **时间序列对齐**：`scripts/align_check.sh` / `scripts/align_check.py`、`scripts/drill_pmu.sh`：每隔 `IV` 个周期的各事件增量对比；`scripts/linux_gate.sh` 在 Linux 全程里用它（tier 1，每个区间）。
- **计数器块的随机测试**：`tests/pmu/run.sh`（Verilator 编 `pmu.sv`，`tests/pmu/pmu_tb.cpp` 与 C++ 参考实现逐周期比较 `csr_hit / csr_rdata / csr_illegal` 和最后的计数器；`PMU_TB_MUTATE=1` 故意破坏参考实现来检查测试本身能失败）。**这个测试目前过时**：`pmu_tb.cpp` 里 `NUM_EV = 52`，而 `pmu_ev_widths.inc`（生成）有 66 个宽度、`pmu` 的事件总线是 66 条通道，数组初始化项数不一致，`ev_inc` 的打包也按 52 条；需要把 `NUM_EV` 与生成的包对齐才能再用（本次没有运行，没有验证它现在能否编译）。
- **整核门禁**：`scripts/fm_gate.sh`、`scripts/lint_chip.sh`（事件总线在 `core_top` 里，随整核编进去）。
- **待补**：把 `pmu` 接进 CSR 单元之后，需要一个核内的软件可见测试（读 `cycle` / `instret`、写 `mhpmevent`）；`tests/pmu` 的 `NUM_EV` 对齐。
- **未核对（继承自旧文档）**：旧文档里"RTL tier 1 与模型逐事件相等"的具体数字；`scripts/pmu_parity.sh` 只比较 tier 1。

## 9. 参数与开关速查

`NUM_HPM`（`pmu` 参数，默认 8）、`COMMIT_W`、`TYPE_W`（`pmu_ev_core` 参数）；`PMU_NUM_EV`、`PMU_INC_W`、`PMU_EV_W[]`（`pmu_ev_pkg`，生成）；模型侧环境变量 `PMU=1`、`PMU_OUT`、`PMU_INTERVAL`、`PMU_PCPROF`；测试平台环境变量 `SOC_TB_PMU=1`（打印事件总数）、`SOC_TB_PMU_IV`（时间序列间隔）；重新生成包：`python3 scripts/gen_pmu_pkg.py [pmu_events.def]`。

## 10. 变更记录

- 本分支（`261bd67..HEAD`）：
  - `60ed422`：`pmu_ev_pkg.sv` 按模型的 `pmu_events.def` 重新生成。发射队列事件的 LD / STA 改成 MEM（`SLOT_BE_IQ_SPACE_LD / _STA` → `_MEM`，`SLOT_BE_IQ_WIDTH_LD / _STA` → `_MEM`，`OCC_IQ_LD / _STA` → `OCC_IQ_MEM`），新增 FP 队列事件（`SLOT_BE_IQ_SPACE_FP`、`SLOT_BE_IQ_WIDTH_FP`、`OCC_IQ_FP`）。事件总数仍为 66。**id 52..65 重新排布**：原来 52 = `SPACE_LD`、53 = `SPACE_STA`……现在 52 = `SPACE_MEM`、53 = `SPACE_STD`、54 = `SPACE_BR`、55 = `SPACE_FP`、56 = `WIDTH_INT`（不变）、57 = `WIDTH_MEM`、58 = `WIDTH_STD`、59 = `WIDTH_BR`、60 = `WIDTH_FP`、61 = `OCC_IQ_INT`（不变）、62 = `OCC_IQ_MEM`、63 = `OCC_IQ_STD`、64 = `OCC_IQ_BR`、65 = `OCC_IQ_FP`。id 0..51 不变，tier 1 不受影响。
  - `121324c`：`tests/pmu/pmu_ev_widths.inc` 跟着重新生成。
- 更早：见 git 历史（`b5a299a` 建立）。
