---
module: front_top
area: frontend
rtl: rtl/frontend/front_top（front_top.sv、front_fetch_buf.sv、front_pred_path.sv）
model: trace-model front-end/front_core.h 的 `FrontCore`（各调度单元 `front.core.*` 的连线 `FrontCore::FrontCore` 和阶段顺序 `FrontCore::comb`）；指令起点扫描对应 front-end/front_top.cpp 的 `InstPort::comb_write`（调度单元 `front.core.inst_port`）
status: 整核周期与模型逐个相等（EXP-070 Unified FTQ-64 + 2-Ahead BPU + 64 KiB 2 级 ICache；fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: Tier 1（Yosys + PrimeTime，clk=0.65 ns，eda-07，2026-11-28）64 级 / WNS −1.82 ns；Yosys 门代理 216 层（EXP-053，2026-11-21）；见第 6 节
---

# front_top 设计文档

## 1. 职责

前端的装配层：把 BPU、I-Cache（含 ITLB 和 FDIP 预取）、指令队列、预译码检查接成一个一拍求值一次的组合网络，状态全在子模块里。取指地址、预测结果和送后端的块信息不在前端排队，而是写进后端 `ftq_ibuf` 的 64 项统一 FTQ（[ftq_ibuf.md](ftq_ibuf.md)）：前端发出三组写请求（`fe2ftq_s0 / s2 / pd`），并读回 FTQ 的寄存视图（`ftq2fe`）。三个文件：

- `front_top.sv`：连线。`front_ctrl`、`icache`、`front_fetch_buf`、`front_pred_path`；组装 `fe2ftq_s0`（S0 分配、覆盖丢尾、IFU 弹出）；`refetch_pd = global_refetch & !be_refetch`；
- `front_fetch_buf.sv`：取指侧。IFU 读 FTQ 队首（`fa_rd_address = ftq2fe.ifu_addr`）、`inst_fifo_room`（占用 + I-Cache 在途 < 深度）、把 I-Cache 的 A 块和同页下一行 B 块的原始半字写进 `inst_fifo`（含 `up16_a / up16_b` 的选取）；
- `front_pred_path.sv`：预测侧。BPU、S2 写 FTQ（`fe2ftq_s2`）、FDIP 信号打一拍（切口 B1）、`front_head_fix`、`predecode_checker`、`front_slot_kind` ×16、第一个预测跳转之后截断、`front_pd_info`、RVC 携带寄存器 `lh_*`、预译码结果写 FTQ（`fe2ftq_pd`）、送后端的取指组。

模型对应：`front-end/front_core.h` 的 `FrontCore`（各调度单元 `front.core.*` 的连线和 `FrontCore::comb` 的阶段顺序）。RTL 的模块边界是为综合划的。本文不含 `rtl/core/core_top` 里的胶合（见 [core_top.md](core_top.md)）。

## 2. 配置（`ttg_cfg_pkg` / `front_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 取指组 | 16 个槽，每槽 2 字节，共 32 字节 | `FETCH_WIDTH = 16`、`SLOT_BYTES = 2`、`FETCH_BYTES = 32` |
| 压缩指令 | 开 | `RVC_ENABLE = 1` |
| 训练口数 | 8 | `COMMIT_WIDTH = 8`（BPU 里叫 `NCOMMIT`） |
| 指令队列 | 16 项 × `inst_fifo_entry_t`（按字段 716 位） | `INSTRUCTION_FIFO_SIZE`，见 [front_fifos.md](front_fifos.md) |
| 统一 FTQ | 64 项 | `FTQ_SIZE`、`FTQ_IDX_WIDTH = 6`（在 `ftq_ibuf`） |
| 块号 | 10 位 | `FTB_BLK_ID_W`（`bpu_types_pkg`） |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n` | `rst_n` 是 `soc_top` 展宽后的复位（SRAM 在复位里清零，见 [common.md](common.md) 4.1 节） |
| 入 | `be_refetch`、`be_refetch_address` | 后端重定向（寄存后的 back2front） |
| 入 | `be_rf_valid / _blk / _type / _pc / _is_rvc`、`be_next_rf_blk` | 后端误预测带回的修复信息（块号，BPU 用内部 `u_rf_rec` 恢复） |
| 入 | `itlb_flush`、`fence_i`、`fifo_read_enable` | SFENCE.VMA、FENCE.I、后端本拍收取指组 |
| 入 | `ftq2fe`（`ftq_fe_view_t`） | 统一 FTQ 的寄存视图：`ftq_full`、`fa_empty`、`fa_cnt_sat`、`s2_empty`、`ifu_addr`、`pd_idx / pd_base_pc / pd_is_pair / pd_base_b / pd_a_len / pd_pred_dir / pd_next_pc` 等 |
| 入 | `csr_status_*` | satp、特权级、mxr、sum、mprv、mpp，给 ITLB |
| 入 | `upd_valid`、`base_pc`、`actual_dir`、`upd_is_rvc`、`br_type`、`target`、`pred_dir`、`alt_pred`、`pcpn`、`blk_id`（各 `[NCOMMIT]`） | 提交流的 BPU 训练包 |
| 入 | `mem_*`、`dc_*`、`ptw_walk_*` | I-Cache 的存储侧响应 |
| 出 | `out_lane_valid`、`out_instructions`、`out_page_fault_inst`、`out_pf_inst_hi`、`out_ftq_idx` | 送后端的取指组（已在第一个预测跳转之后截断），后端由 `out_ftq_idx` 向 FTQ 查 pc 与预测 |
| 出 | `fe2ftq_s0`、`fe2ftq_s2`、`fe2ftq_pd` | 写统一 FTQ：S0 分配 / 丢尾 / IFU 弹出；S2 预测与训练元数据；预译码结果（修正后方向、`is_rvc`、`next_pc`、`nslots`、`slot_kind`、`carry`） |
| 出 | `mem_req_*`、`mem_resp_ready`、`dc_req_*`、`ptw_walk_req_*`、`ptw_walk_resp_consumed`、`ptw_walk_flush` | I-Cache 的存储侧请求 |
| 出 | `commit_upd_free`、`commit_tq_free` | BPU 训练队列的空闲项数，给 ROB 做提交信用 |

## 4. 结构

```
 front_top
   front_ctrl      : 全局 refetch、FTQ / inst_fifo 使能、BPU 门控、预译码冲刷        -> front_ctrl.md
   icache          : FTQ 队首地址 -> 取指组（F0 -> F1，含 ITLB、FDIP、同页下一行 B 块） -> icache.md
   front_fetch_buf : IFU 读口、inst_fifo_room、A/B 原始半字写 inst_fifo
   front_pred_path : bpu、S2 写 FTQ、FDIP 打拍、front_head_fix、predecode_checker、front_slot_kind x16、
                     截断、front_pd_info、携带寄存器 lh_*、预译码写 FTQ、送后端输出
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `front_top.sv` | 211 | 连线；`fe2ftq_s0`；`refetch_pd` |
| `front_fetch_buf.sv` | 110 | 取指侧：IFU 读口、`inst_fifo_room`、`inst_fifo` 写条目 |
| `front_pred_path.sv` | 326 | 预测侧：BPU、FDIP 打拍、头修正、检查器、截断、PD 信息、携带寄存器、FTQ 写请求 |

状态：`front_top`、`front_fetch_buf` 自己没有（队列状态在 `inst_fifo`）；`front_pred_path` 有携带寄存器 `lh_valid_q`（1）、`lh_pc_q`（64）、`lh_data_q`（16）和 FDIP 打拍寄存器 `fdip_s2_{en,va,clear}_q`。

## 5. 一拍内的数据流

1. 寄存器值：FTQ 视图 `ftq2fe`、`inst_fifo` 计数、`predecode_refetch_q`、携带寄存器、BPU、I-Cache 寄存器。`front_ctrl` 算 `global_refetch` 和各使能。
2. `fa_rd_en` 时 FTQ 队首地址 `ftq2fe.ifu_addr` 作为请求送 I-Cache（`fe2ftq_s0.ifu_pop` 让 `ifu_ptr` 前进）；I-Cache 的 F1 响应回来（A 块 16 槽 + 可能的 B 块）。
3. `front_fetch_buf`：`ic_read_complete & !global_refetch & !full` 时整组原始半字写进 `inst_fifo`。
4. BPU：S0 块经 `fa_wr_en` 分配 FTQ 项（`fe2ftq_s0.wr_en/addr/pair`），S2 覆盖经 `fa_drop_tail_n` 丢尾；S2 块经 `s2_wr_en` 写预测（`fe2ftq_s2`）。
5. `predecode_can_run` 时读 `inst_fifo` 队首：`front_head_fix` 选 A / A+B、单份展开与预译码、指令起点扫描、按 FTQ `pd_ptr` 项的 pc 截断、RVC 携带；`predecode_checker` 与 FTQ 里的预测比较；第一个修正后跳转之后截断（`pd_cut_valid`，前缀扫描）；`fe2ftq_pd` 把结果写回 FTQ；同一组直接作为 `out_*` 送后端。
6. `do_predecode_flush`：进 `predecode_refetch_q`（下一拍全局 refetch）、I-Cache 的 `invalidate`、`front_pd_info`、FTQ 的 `pd_flush`（回滚 `pd_ptr` 之后的项）。

没有组合环：`do_predecode_flush` 只进寄存器、I-Cache 次态和 FTQ 次态。

## 6. 关键路径与深度

| 日期 | 口径 | 结果 |
| --- | --- | --- |
| 2026-11-28 | Tier 1（Yosys + PrimeTime，`clk = 0.65 ns`，eda-07），64 KiB 2 级 ICache 之后 | 64 级，WNS −1.82 ns（0.405 GHz），第一关键路径在 BPU `u_ftb1.u_wrb → bk_addr`（详见 [icache.md](icache.md) 6.1） |
| 2026-11-21 | Yosys 门代理（`SYNTH_ABC="strash;balance;map"`），EXP-053 | 216 层，1,159,189 单元 |
| 2026-11-18 之前 | 同上 | 132 层（uBTB 查表改写之前）；更早 528 / 182 / 159 |

从代码读出、未综合验证的链：`inst_fifo` 队首 → `front_head_fix`（A/B 选择、起点扫描、携带组装）→ `predecode_checker`（第一个 taken、目标选择、与 FTQ 预测比较）→ `do_predecode_flush` / 截断 → `fe2ftq_pd`。

## 7. 与模型的差异和取舍

- PMU 前端分类（`FrontControl::finish` 的 `g_pmu_front.feo_*`）：RTL 前端里没有，RTL 只有一级事件（见 [pmu.md](pmu.md)）；
- 模型的 `ReadData` 快照、`front_state` 的 `d` 值、`*_full / *_empty` 锁存：RTL 由计数直接算；
- `front.in.reset`（模型只在 `FrontTop::init()` 一拍有效）：RTL 用 `rst_n`；
- `ftq2fe.ifu_next_fa_idx / ifu_next_b_idx / ifu_pair`、I-Cache 的 `fetch_upper_ok` 在顶层没有用（接 `unused_ok`）；
- 携带寄存器在后端重定向或复位时清；预译码冲刷时除非冲刷的那组自己产生了新的携带且续在其后，否则也等于被清（`lh_new_valid` 含 `!checker_flush_enable || corrected == lh_new_pc`）。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，周期对 `scripts/ref_cycles.txt`（模型默认配置 = RTL 配置）逐个相等；触及前端的有 `fence-i-self-modify`、`itt-dispatch`、`directed/fe_2taken_fdip`、各陷入 / 中断程序、`dhrystone / coremark`。
- **Linux**：`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`；前端 PT / UP 指纹 `scripts/align_check.sh` / `align_check.py`。
- **等价测试**：`tb/fe_clean_eq`（`front_head_fix` 起点扫描的综合 / 仿真两种写法，65,536 种压缩模式全枚举）。
- **Lint**：`scripts/lint_chip.sh` 0 告警。

## 9. 参数与开关速查

无开关。常量：`RVC_ENABLE`、`FETCH_WIDTH`、`FETCH_BYTES`、`SLOT_BYTES`、`COMMIT_WIDTH`、`INSTRUCTION_FIFO_SIZE`、`FTQ_SIZE`（`ttg_cfg_pkg`）；`INST_FIFO_DEPTH`、`KIND_W`（`front_pkg`）。

## 10. 变更记录

- 2026-11-28 清理：删 `front_ctrl` 无读者的 `bpu_can_run` 输出及其 `unused_ok` 汇点、`inst_fifo` 无读者的 `rd_valid`（`inst_rd_valid`）、`predecode_checker` 未用的 `clk / rst_n` 连线、`front_pred_path` 前缀扫描末级不用的 `p4` 与 `if (1'b0)` 静默写法、`front_fetch_buf` / `front_top` 不起作用的 `UNUSEDSIGNAL` 豁免，`front_fetch_buf` 的 `unused_hi` 汇点去掉其实有读者的 `ic_page_fault_inst[15:1]` / `b_fetch_group[*][31:16]`（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`）：文档按现行 RTL 重写（第 1–9 节；旧正文描述的是 EXP-070 之前 / 删除分支标签之前的结构）。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`fetch_addr_fifo` 与 `pend_pair_q` 携带 `FetchPair`；`front_fetch_buf` 实现双块融合与 `alt_a` 完整 A 兜底；`ptab` / `front2back_fifo` 用紧凑字段 `{is_pair, a_len, base_b}` 重建 16 槽 PC 并删除 166 位 `bpu_ck`；`front_top` 接入 ICache FDIP S2 信号。Yosys 综合 `front_top` `1,582,763` 单元 / `356` 层（最长路径 `u_pred_path.u_bpu.r1_q[1074] → u_pd.pd_ras_op2_q[1]`，已登记至 TODO）；通过 `lint_chip` 0、`fm_gate` 68/68（0 周期偏差）与 Linux 27 窗检查点对齐。
- 2026-11-17/18（exp/agu-share）：指令起点前缀扫描 `737e7a5`；取指地址队列 push 后一拍才弹出 `4eb8f0e`（模型 `CFG_FE_OVR_REG`，16 个 SPEC 点几何平均 IPC -0.82 %）；BPU 的三处深度改写 `7551dd0`、`47f4a7d`、`2c76ba2`（见 bpu.md）。
- 更早：见 git 历史。

更早的升级说明（原文保留，未按现行 RTL 逐条核对；与第 1–9 节冲突时以正文为准）：

**EXP-070（Unified FTQ-64 + Clean BPU v11 + 同页 2-Fetch + A1/A2/B1 时序切割）升级**：
1. **Unified FTQ-64 统一前端队列**：删除前端独立的 `fetch_addr_fifo`、`ptab` 与 `front2back_fifo`（仅留 `inst_fifo`），由后端 `ftq_ibuf` 的 64 项统一 FTQ 承载全部预测块地址与元数据，彻底消除 `ptab_bypass` 跨模块长链；
2. **1-Taken 同页 2-Fetch 与 `off6 == 32` `up16`**：在 1-Taken FTB 架构下，当块落在同 4KB 页下半部且无跳转冲突时，同拍读取连续相邻 32B 缓存行（`is_pair`），并在 `off6 == 32` 的 32-bit 分支跨 64B 边界处复用 `b_ok` 将 `raw_b[0]` 送入 `up16_a`（0 新增 `inst_fifo_entry_t` 位宽），消除跨行 32-bit Taken 分支的 Predecode Flush；
3. **Cut B1（寄存 `fdip_s2_{en,va,clear}`）**：在 `front_pred_path.sv` 将 BPU S2 的 FDIP 入队信号与 `global_refetch` 寄存 1 拍后再送入 `icache_fdip` 8 项去重 CAM，彻底斩断 `u_bpu → u_icache/u_fdip` 跨子系统关键路径；
4. **零黑盒真 SRAM**：`ttg_sram_1r1w` 在 `SYNTH_TSMC28_SRAM` 下全部映射为真实 TSMC 28nm 1RW SRAM 宏单元 + `WRITE_FIRST` 旁路 FF（≤1024b 小表走 FF）。

**EXP-053 前端结构清理（Phase 1 + Phase 2）升级**：
1. **紧凑原始半字 `inst_fifo_entry_t` 与单份展开预译码（Phase 1）**：`front_fetch_buf` 不再做双份展开/预译码与宽目标存储，`inst_fifo` 仅存原始 16b 半字流与精简元数据；单份 `rvc_expand` + `predecode` 与 4 轮 Kogge-Stone `start_a`/`start_b` 前缀扫描统一落在 `front_head_fix`（按实际 `s1_seq` 64B 行掩码对齐，兼容错路奇地址）；
2. **删死线与去补丁（Phase 1 + P2-2）**：删除全链路死信号 `tage_idx` / `tage_tag`；用显式 1-bit `pf_inst_hi` 替代原先经 `inst -> diag_val[1]` 搭便车传递跨页 RVC 第二半字取指缺页偏移；
3. **综合收益**：`front_top` 整块单元数由 1,582,763 降至 **1,159,189（−26.8%）**，组合深度由 356 层降至 **216 层（−39.3%）**。

**EXP-051 里程碑 B 升级**：
1. `fetch_addr_fifo` 与在途寄存器 `pend_pair_q` 携带 `FetchPair`（`valid, addr2, a_len, b_len`）；`front_fetch_buf` 在 ICache 响应同拍并行拼合 Block A 与 Block B（同时将完整 Block A 副本存入 `inst_fifo` 作 S2 覆写兜底），读端若 `has_alt_a && !ptab_is_pair` 无损恢复完整 Block A，避免 S2 覆写 A 时误切槽；
2. `ptab` 与 `front2back_fifo` 用紧凑字段 `{is_pair, a_len[3:0], base_b[63:0]}` 重建 16 槽 PC（无需存 16×64b），并删除原 166 位 `bpu_ck`（由 `out_tage_idx[*][0] = blk_id` 在 BPU 内部 `rec_q[256]` 直接修复）；
3. `front_top` 将 S2 确认信号（`ptab_wr_en`、`bpu_predict_next_fetch_address`、`bpu_override_valid`）接入 `icache` FDIP 队列。
