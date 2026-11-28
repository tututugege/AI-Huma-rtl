---
module: front_fifos
area: frontend
rtl: rtl/frontend/inst_fifo.sv（原通用队列 front_fifo.sv 于 2026-11-28 并入 inst_fifo；原 fetch_addr_fifo.sv / ptab.sv / front2back_fifo.sv 已于 EXP-070 合入 Unified FTQ-64 删除）
model: trace-model front-end/front_fifo_ports.h、front-end/front_top.cpp（调度单元 `front.core.inst_port`，类 `InstPort`；原 `fa_port`/`ptab_port`/`f2b_port` 已并入后端统一 FTQ `back.pre`）
status: 整核周期与模型逐个相等（EXP-070 Unified FTQ-64 后只留 `inst_fifo`；fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: 13 层（2026-11-18，测的是已删除的 fetch_addr_fifo；inst_fifo 未重测，`SYNTH_ABC="strash;balance;map"`）
---

# front_fifos 设计文档

## 1. 职责

前端现在只剩一个队列：指令队列 `inst_fifo`，放 I-Cache 回来、还没做预译码检查的取指组（一个已合并好的 16 槽半字窗口）。写的一方是 I-Cache 的 F1 响应（`front_fetch_buf`），读的一方是预译码检查（`front_pred_path` 的 `front_head_fix` / `predecode_checker`）。取指地址、预测结果、送后端的缓冲都在统一 FTQ 里（[ftq_ibuf.md](ftq_ibuf.md)）；原来的 `fetch_addr_fifo`、`ptab`、`front2back_fifo` 已在 EXP-070 删除。

`inst_fifo` 是一读一写环形队列，条目是打包结构体 `inst_fifo_entry_t`（原来的通用队列 `front_fifo` 只有它一个使用者，2026-11-28 并入）。

模型对应：`InstPort`（调度单元 `front.core.inst_port`）里的 `FrontFifo` 存储；头修正、展开、预译码在 RTL 里属于 `front_head_fix`，见 [predecode.md](predecode.md)。

## 2. 配置（`ttg_cfg_pkg` / `front_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 深度 | 16 | `INSTRUCTION_FIFO_SIZE`（`ttg_cfg_pkg`）→ `INST_FIFO_DEPTH`（`front_pkg`） |
| "满"阈值 | 16 | 等于深度（`full = count >= INST_FIFO_DEPTH`） |
| 条目 `inst_fifo_entry_t` | 按字段相加 371 位（没有用 `$bits` 在综合里核对） | `front_pkg` |
| 清空来源 | 全局 refetch（`global_refetch`，含预译码冲刷） | `front_fetch_buf.sv` |

条目字段（`front_pkg::inst_fifo_entry_t`）：`is_straddle` 1、`single_word` 1、`tail_ok` 1、`base` 64、`valid` 16、`pf` 16、`half` 16×16、`up16` 16。写入前 `front_fetch_buf` 已把 A 块（本次取指）和 B 块（同页下一行从半字 0 起，跨行 2-Fetch）合并成一个窗口：槽 `[0, a_len)` 取 A，槽 `[a_len, a_len + b_n)` 取 B（`is_straddle`，B 未命中时这些槽无效）；`valid` 是前缀；无效 / 缺页槽的 `half` 是 NOP 的低半 `0x0013`；`up16` 是最后一个有效槽之上的半字（缺页组为 0）；`tail_ok` = `pc[5:0] == 32` 且 B 命中（槽 15 之上的半字是真的，`up16` = B 的半字 0）；`single_word` = 非缓存的单字回答。槽 i 的 32 位窗口在 `front_head_fix` 里拼：槽 i+1 有效时 `{half[i+1], half[i]}`，否则 `{0, half[i]}`。

## 3. 接口

`inst_fifo`（无参数，深度取 `front_pkg::INST_FIFO_DEPTH`）：

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n` | |
| 入 | `refetch` | 清空 |
| 入 | `rd_en` / `wr_en` / `wr_entry` | 读（弹出队首，空时无效）、写、写数据 |
| 出 | `rd_entry` | 队首（拍初的队首，不含本拍写入；只在 `!empty` 时有意义） |
| 出 | `full` / `empty` / `size` | 拍初状态：`full = count >= INST_FIFO_DEPTH` |

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `inst_fifo.sv` | 76 | 指令队列：读写指针、计数、溢出断言（仿真） |

状态：读指针、写指针、计数（复位清零）；`INST_FIFO_DEPTH × $bits(inst_fifo_entry_t)` 的存储（不复位，只有读写指针之间的项会被当作有效数据读）。

## 5. 一拍内的数据流

`inst_fifo` 一拍内的顺序：清空 → 写 → 弹出：

- `pop = rd_en & !refetch & !empty`；
- `count_d = (refetch ? 0 : count) + wr_en - pop`；`wr_ptr_d = wr_ptr + wr_en`；`rd_ptr_d = refetch ? wr_ptr : rd_ptr + pop`；
- 写落在 `wr_ptr` 槽。

`inst_fifo` 的使用（`front_fetch_buf`）：写使能 `ic_read_complete & !global_refetch & !full`；读使能 `predecode_can_run`（[front_ctrl.md](front_ctrl.md)）。指令队列不会溢出靠的是 `front_ctrl` 的 `inst_fifo_room`：IFU 只在"占用 + I-Cache 在途取指数 < 深度"时发新请求。

## 6. 关键路径与深度

单模块综合深度 **13 层**（2026-11-18 测的是已删除的 `fetch_addr_fifo`；`inst_fifo` 更浅，没有单独重测；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。队列本身是存储读 + 指针加法；值得看的是读口后面接的 `front_head_fix` 和检查器（`rdata = mem_q[rd_ptr_q]`，16 项 × 371 位的选择），见 [predecode.md](predecode.md)。

## 7. 与模型的差异和取舍

- 模型的读口"空队列同拍写则返回写入项"：RTL 的 `inst_fifo` 没有旁路，读使能要求非空；
- 模型的 `*_full / *_empty` 锁存：RTL 不建，由拍初计数算出；
- 溢出时模型 `fatal` 退出，RTL 只有仿真断言（`ifndef SYNTHESIS`）；
- 原通用队列 `front_fifo` 的 `drop_tail`、`BYPASS`、`next_rdata`、`head_fresh`、`FULL_AT`（服务已删除的取指地址队列和 PTAB）2026-11-28 随并入删除。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，周期对 `scripts/ref_cycles.txt` 逐个相等。
- **仿真断言**：`inst_fifo` 的溢出断言；深度非 2 的幂的展开期错误。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **等价测试**：`tests/fe_clean_f/run.sh chain`（清理 F 前后的取指链 `icache_resp → front_fetch_buf → inst_fifo → front_head_fix` 随机对拍，100 万拍，见 [predecode.md](predecode.md) 第 8 节）。
- **没有模块级的独立测试**。**待补**：`inst_fifo` 与参考队列的随机对拍。

## 9. 参数与开关速查

`INSTRUCTION_FIFO_SIZE`（`ttg_cfg_pkg`）；`INST_FIFO_DEPTH`（`front_pkg`）。`inst_fifo` 无参数。

## 10. 变更记录

- 2026-11-29 清理 F：A/B 跨行合并移到队列前（`front_fetch_buf`），条目从 `raw_a` + `raw_b` 两组半字（+`a_len`、`b_actual_n`、`up16_a`、`up16_b`、`b_ok`）改为一个合并好的窗口 `half[16]` + `up16` + `tail_ok`，`base_a / valid_a / pf_a / single_word_a` 改名 `base / valid / pf / single_word`，条目 652 → 371 位（16 项共省 4,496 个触发器）（周期不变）。
- 2026-11-29 清理 E：改名 `inst_fifo_entry_t.is_pair` → `is_straddle`（同页跨行 B 块，不是旧的 2-taken 双块）（只改名字，周期不变）。
- 2026-11-29 清理 C：删 EXP-051 2-taken 双块残留（EXP-070 起不再产生）：`inst_fifo_entry_t.base_b`（64 位）删除，唯一读者 `front_head_fix` 的 `pair_discontinuity` 恒为 0（跨行 B 块恒为 A 的下一行），条目 716 → 652 位（周期不变）。
- 2026-11-28 清理：删 `front_fifo` 的死功能（`drop_tail` 恒 0、`BYPASS` 恒 0、`FULL_AT` 恒等于深度、`next_rdata` / `head_fresh`（`fresh_v_q` / `fresh_slot_q`）无读者），把剩下的队列并入 `inst_fifo.sv`；删 `inst_fifo` 无读者的 `rd_valid` 输出与 `front_pkg::INST_FIFO_FULL_AT`（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`）：文档按现行 RTL 重写（第 1–9 节；旧正文描述的是 EXP-070 之前 / 删除分支标签之前的结构）。
- 2026-11-18（exp/agu-share）：`front_fifo` 加 `head_fresh`，取指地址队列在 push 后一拍才弹出 `4eb8f0e`。
- 更早：见 git 历史。

更早的升级说明（原文保留，未按现行 RTL 逐条核对；与第 1–9 节冲突时以正文为准）：

**EXP-070 Unified FTQ-64 升级**：
- 彻底删除前端独立的 `fetch_addr_fifo.sv`、`ptab.sv` 与 `front2back_fifo.sv`，取指地址排队、预测元数据暂存与后端提交追踪全部收口至 `rtl/backend/ftq_ibuf/` 的 64 项统一 FTQ（彻底消除 `ptab_bypass` 跨模块关键路径）；
- 前端仅保留 `inst_fifo.sv`（16 项原始 16b 半字流 FIFO，由 `front_fifo.sv` 实现）；并在 `off6 == 32` 同页双取指场景复用 `b_ok` 字段传递 `up16_a`（零新增条目位宽）。

**EXP-053 前端结构清理（Phase 1 + P2-2）升级**：
- `inst_fifo_entry_t` 改为存储紧凑原始 16b 半字流与最小元数据（省去 16 槽展开指令、双份预译码类型/目标及 `start_a`/`start_b`）；
- `ptab` 与 `front2back_fifo` 删除死线 `tage_idx` / `tage_tag`，`front2back_fifo` 新增每槽显式 1-bit `pf_inst_hi`。
