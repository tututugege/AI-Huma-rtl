---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
model: trace-model front-end/BPU/BpuFtb.h、BPU_pipe.h、BPU.h、BPU_configs.h（调度单元 `front.core.bpu_pipe`，类 `BpuPipe`，块级 1-Ahead A + 2-Ahead B 双跳预测 + S2 Block-TAGE/ITT，`fe2f_b4_it2_ah1k` + `BRQ_W=1`）
status: 整核周期与模型逐个相等（EXP-062：`bpu_spec` 3 级 Kogge-Stone RAS + 128b 线性 `arch_sr_q` 0 周期变化，rv64gc Linux 26/26 窗 PT/UP 逐拍全等）
depth: 197 层 / 410,093 单元（Yosys 整块 `bpu`）；**TSMC 28nm HPC+ DC `ssg0p81v125c` `0.50ns`（EXP-062）：`bpu_spec` `WNS -0.87→-0.66 ns`（`0.73→0.86 GHz`, `69→41 lvl`, `156,084 um²`），`bpu_eval` `-0.69 ns`（`0.84 GHz`, `69 lvl`），`bpu_ctl` `+0.10 ns`（`≥2.50 GHz`, `13 lvl`），见 09-synthesis-report 第 15 节**
---

# bpu 设计文档（块级 2-Taken + 1-Ahead A / 2-Ahead B 分支预测单元，EXP-051/052）

> **EXP-053 前端结构清理（Phase 1）优化**：
> - `bpu_eval.sv`：将 `ftb_eval_ent` 改为并行求值（并用 6 位差 `(6'(bnd[5:0]) - 6'(base[5:0])) >> 1` 加固错路奇地址 `nslots`）；
> - `bpu_hist_vec.sv` / `bpu_spec.sv`：彻底消除取模运算改为并行移位（`` `ifdef SYNTHESIS `` 综合走并行桶形移位、仿真走快速循环，经 `fe_clean_eq_tb` 20,000 次随机双路径验证 0 差异），收紧 `MAX_SYM`，并在 `bpu.sv` 中切断 `r1_q → ovr_a → spec_a → g0_b` 组合假路径；
> - 删除不再使用的死信号 `out_tage_idx[1..3]` / `out_tage_tag`；单模块面积 **−18.6%**（504k → 410k），组合深度 **−27.6%**（272 → 197 层）。

本版在里程碑 A（单块 1-ahead FTB `ah1_4k_a2k1k`）基础上，升级为 **每拍至多 2 个 taken 分支块（Block A + Block B）同拍预测** 的前端 BPU（Pareto 冠军 `fe2f_b4_it2_ah1k`）：
- S0 并行读 **1-Ahead A**（`aftb 2K×8` + `atage 1K×4×4` + `aitt 256×3`）与 **2-Ahead B**（`aftb2 1K×8` + `atage2 512×4×4` + `aitt2 256×3`），共享同一已寄存前驱键 `(key_base, key_fh)`，S0 零串行 SRAM 读；未命中回退双读口 uFTB（`ftb0`）；
- 严格 **No-Truncation（`NT=1`）** 与 **4-Bank 1R1W ICache 冲突过滤（`ic_pair_ok`）**：仅当 A 预测跳转、`a_len ∈ [1..15]`、`a_upper_ok`、PC 不连续、`lA == lB || (lA & 3) != (lB & 3)`、`b_len ≥ 2` 且 `(!b_truncated || gB.taken)` 时配对发射 Block B；
- S1 对 Main FTB / S2 Block-TAGE / S2 Block-ITT 增加第 2 读口以同拍查 B（仅 `r0.has_b` 有效时消费）；
- S2 先校验 A（`has_b` 时额外校 `taken`/`slot`）；若 `!ovr_a && has_b` 则校验 B 并输出 `ptab_is_pair / ptab_base_b / ptab_a_len`，向 `ftb_rec_[512]` 与内部 `rec_q[256]` 写入 2 条记录（`seq0` 标 `ah_kind=1`，`seq0+1` 标 `ah_kind=2`），`blk_seq += 2`；
- 全局历史环由 256b 拓宽至 **1024b**（`HR_BITS=1024`、`HR_PTR_W=10`）以匹配双块发射速率；
- 后端分支误预测修复改由 BPU 内部 256 项 `rec_q`（1R2W，按 `rf_blk[7:0]` 索引、`id`+`epoch` 校验）完成，彻底删除流经 PTAB / F2B / FTQ 的宽 `bpu_ck` 总线；
- 提交侧保持 **1-branch/cycle（`BRQ_W=1`）** 单读改写写口（实测较 `BRQ_W=2` 仅差 +0.03%），按 `rc.ah_kind` 分发更新 `aftb/atage/aitt` 或 `aftb2/atage2/aitt2`。

## 1. 职责

每拍预测一个取指块（从 `base` 起、至多 16 个 2B 槽、不跨 64B 缓存行，即 `block_bnd(base)`），保持与 `front_pred_path` 外部接口完全兼容，内部三级流水（S0、S1、S2）：

1. **S0（0 气泡主力预测）**：
   - 优先消费上一拍已提前读出并寄存的 **1-Ahead SRAM 数据**（`ah_pipe_q`，由上一拍块起点 `pc_{t-1}` 与历史 `H_{t-1}` 索引）：在 `aftb` 8 路中用 22 位组合标签 `(key_base, cur_base)` 匹配当前块 `s0_base`，结合 `atage`（4 表 × 1024 × 4 槽，复用 `aftb` 槽计数器作基表）与 `aitt`（3 表 × 256）及投机 RAS 给出 0 气泡强预测 `g0`；
   - 若 1-ahead 冷启动（重定向首拍）或未命中，无缝回退到小型 **uFTB**（`ftb0`，256 项 × 4 路，20b 压缩目标，`BR_RET` 走 RAS 不受目标宽度限制）；
   - 同时以已寄存的 `(s0_base, s0_fh)` 发起本拍的 1-ahead SRAM 读（结果寄存进 `ah_pipe_q` 供下一拍 S0 使用），并计算本块精确索引 `ftb_ix` 送入 S1；
   - 按 `g0` 更新投机历史与投机 RAS，下一拍从 `g0.next` 继续，同时将 `s0_base` 写入取指地址队列。
2. **S1（冷启动覆写与主阵列读）**：
   - 用 S0 寄存的 `(r0.base, r0.ftb_ix)` 读精确 PC 主阵列：**Main FTB**（`ftb1`，4096 项 × 4 路，4 槽/项、不交换槽位）、**S2 Block-TAGE**（`s2_tage`，4096 × 4 槽 × 4 表 + 基表，10-bit tag）、**Single Block-ITT**（`s2_itt`，3 表 × 256）；
   - 当且仅当 S0 未命中 1-ahead（`!r0.ah_hit`）且 `ftb1` 命中并与 `r0.g` 分歧时触发 S1 覆写（1 气泡），用 `ftb1` 猜测替换 `r0.g` 并从 `r0.ck` 修复投机历史/RAS；若 `r0.ah_hit == 1` 则跳过 S1 覆写（`FTB_AH_ONLY=1`）。
3. **S2（精确历史兜底与 PTAB 写入）**：
   - 用寄存的 `r1_raw_q`（Main FTB + 4-slot Block-TAGE + Single Block-ITT + RAS）算出最终预测 `fin`；
   - 将预测结果写入 PTAB，并把单调递增的 10 位块号 `blk_id` 写入 `out_tage_idxs[*][0]`（沿既有 PTAB → F2B → FTQ → B2F 通道透传回提交侧），同时将本块精确预测态元数据 `(base, fh, ah_v, ah_key_base, ah_key_fh)` 写入 `ftb_rec_[512]`（1R1W）；
   - 若 `fin` 与 `r1.g` 分歧则触发 S2 覆写（作废 S1 块，2 气泡），恢复 `r1.ck` 并推入 `fin`，且将 `ah_pipe_q` 恢复为 `r1`（若可用）或清零。
4. **修复**：预译码冲刷从 `bpu_pdq` 队首检查点修复（并用 `pd_base` 清假分支槽）；后端分支误预测按 `rf_epoch == epoch_q` 从 FTQ 返回的检查点修复；其余冲刷退回提交态并递增 `epoch_q`。重定向时清零 `ah_pipe_q`（首拍走 uFTB，次拍起 1-ahead 自动恢复）。
5. **训练**：提交侧 8 通道按序推进提交态历史与 RAS，并将有效控制指令（`br_type != BR_NONCTL`）压入 16 项 **1-branch/cycle 提交队列**（`bpu_ftb_brq`，永不反压 ROB：`commit_upd_free = commit_tq_free = 4'd15`）。每拍弹队首 1 条分支，用其透传回来的 `blk_id = idxs[i][0]` 经单读口读 `ftb_rec_[512]` 还原预测时刻 `(base, fh, ah_key_base, ah_key_fh)`，单次读改写更新 `ftb0` / `ftb1` / `s2_tage` / `s2_itt` / `aftb` / `atage` / `aitt`。

## 2. 配置（`bpu_types_pkg` / `bpu_stage_pkg` / `bpu_pkg` / `ttg_cfg_pkg`）

| 项 | 值 | 常量 |
| --- | --- | --- |
| 块 / 槽 | 16 个 2B 槽（32B 块，不跨 64B 行） | `FETCH_WIDTH = 16`、`SLOT_SHIFT = 1` |
| FTB 每项分支槽 | 4 槽（不交换槽位，含 1b `carried` 标记支持 RVC 跨块 4B 分支/CALL） | `FTB_SLOTS = 4` |
| S0 uFTB（`ftb0`） | 64 组 × 4 路 = 256 项，12b 标签，20b 目标压缩（`BR_RET` 例外） | `FTB_S0_SETS = 64`、`FTB_S0_W = 4`、`FTB_S0_TAG_W = 12`、`FTB_S0_TGTB = 20` |
| S1/S2 Main FTB（`ftb1`） | 1024 组 × 4 路 = 4096 项，14b 标签，全宽目标 | `FTB_S1_SETS = 1024`、`FTB_S1_W = 4`、`FTB_S1_TAG_W = 14` |
| S2 Block-TAGE（`s2_tage`） | 4096 项 × 4 槽 ×（2b 基表 + 4 表×(10b tag + 3b cnt + 2b u)）；1 个 `use_alt` 计数器（`ualt=1`）；每 `2^11` 次更新复位一行 useful | `FTB_TAGE_N = 4096`、`FTB_TAGE_IDX_W = 12`、`FTB_TAGE_TAG_W = 10`、`FTB_TAGE_URST = 11` |
| S2 Single Block-ITT（`s2_itt`） | 3 表（历史表 1/2/3）× 256 项，10b 标签，2b conf，1b u，全宽目标 | `FTB_ITT_N = 256`、`FTB_ITT_IDX_W = 8`、`FTB_ITT_TAG_W = 10` |
| 1-Ahead FTB（`aftb`） | 256 组 × 8 路 = 2048 项，由 `key_base` 索引，22b 组合标签 `{key_tag[9:0], cur_tag[11:0]}` | `FTB_AH_SETS = 256`、`FTB_AH_W = 8`、`FTB_AH_TAG_W = 22` |
| 1-Ahead Block-TAGE（`atage`） | 1024 项 × 4 槽 × 4 表（无独立基表，复用 `aftb` 槽 2b 计数器作基表），10b 标签 | `FTB_AH_TAGE_N = 1024`、`FTB_AH_TAGE_IDX_W = 10` |
| 1-Ahead Block-ITT（`aitt`） | 3 表 × 256 项，与 `s2_itt` 同结构 | `FTB_ITT_N = 256` |
| 元数据记录表（`ftb_rec`） | 512 项 1R1W（索引 `blk_id[8:0]`，10b `id` 校验） | `FTB_REC_N = 512`、`FTB_REC_W = 9`、`FTB_BLKID_W = 10` |
| 提交分支队列（`brq`） | 16 项 FIFO，8 写 1 弹，不反压 ROB | `FTB_BRQ_N = 16`、`FTB_BRQ_W = 4` |
| 全局历史 / RAS / PDCKPT | 与旧版完全一致（256b 历史环、12 折叠历史、64 槽投机 RAS、32 项提交 RAS、32 项 PDCKPT 增存 `base`） | `HR_BITS = 256`、`RASQ_N = 64`、`RAS_DEPTH = 32`、`PQ_DEPTH = 32` |

## 3. 接口

`bpu.sv` 顶层端口**与旧版完全保持一致**（零外部端口改动）：
- `out_tage_idxs[i][0]`（10 位）承载单调块号 `blk_id[9:0]` 随块流经 PTAB / F2B / FTQ / B2F，提交时由 `idxs[i][0]` 原样返回；
- `out_tage_tags[i][0]` 承载预测时刻 `ftb_ix.tag[0][7:0]`（仅供一致性观测，训练以 `ftb_rec` 为准）；
- `commit_upd_free`、`commit_tq_free` 恒输出 `4'd15`（与 `FTB_BRQ=2` 一致，不阻塞紧凑 ROB 提交）。

## 4. 结构

```text
  pc_q ─► [S0] ah_pipe_q 选择 (aftb 8路比对 + atage + aitt + RAS) / 未命中回退 uFTB (ftb0) ─► g0
               同时用 (s0_base, s0_fh) 发起下一拍 1-ahead SRAM 读 (aftb/atage/aitt -> ah_pipe_q)
               bpu_cmd + bpu_spec (投机/提交历史与 RAS)
          r0 (base, g0, ck, ftb_ix, ah_hit/v/key) ─► [S1] 读 ftb1 + s2_tage + s2_itt；!ah_hit 时 ftb1 可 S1 覆写
          r1 + r1_raw_q ─► [S2] s2_select (ftb1 + s2_tage + s2_itt + RAS) ─► fin -> PTAB + ftb_rec 写 + S2 覆写
  提交侧：8 通道控制分支 ─► bpu_ftb_brq (16 项 FIFO, 1 弹/拍 + ftb_rec 1R1W) ─► 单分支 RMW 更新全部 7 张表
```

| 文件 | 职责 |
| --- | --- |
| `bpu.sv` | 顶层：S0/S1/S2 阶段寄存器、`ah_pipe_q[0..1]`、1-ahead 读与选路、S1/S2 覆写与 `blk_seq_q` 分配、子模块连线 |
| `bpu_types_pkg.sv` | 块级 FTB / 1-ahead 常量、结构体与纯组合函数（索引哈希、`eval_ent`、`upsert_branch`、`tage_select`、`itt_select`）；命名排在 `bpu_stage_pkg.sv` 之后满足 `rtl_files.sh` 字典序编译 |
| `bpu_ftb_arrays.sv` | 7 张预测阵列容器（`u_ftb0`、`u_ftb1`、`u_s2_tage`、`u_s2_itt`、`u_aftb`、`u_atage`、`u_aitt`） |
| `bpu_ftb_tab.sv` | 参数化组相联 FTB 表（复用实现 `ftb0`、`ftb1`、`aftb`：1 读口 + 1 单分支 RMW 写口 + 可选预译码清槽） |
| `bpu_ftb_tage.sv` | 参数化 4 槽 Block-TAGE（复用实现 `s2_tage` 与 `atage`：1 预测读口 + 可选训练读口 + 1 单槽更新写口 + LFSR / 周期复位 / `use_alt`） |
| `bpu_ftb_itt.sv` | 单块 3 表 Block-ITT（复用实现 `s2_itt` 与 `aitt`：1 读口 + 1 更新写口） |
| `bpu_ftb_brq.sv` | 16 项 1-branch/cycle 提交队列 + 512 项 1R1W `ftb_rec` 元数据表 |
| `bpu_pkg.sv` / `bpu_stage_pkg.sv` | 共享常量与阶段类型（更新 `blk_t`，删除 16-bank `raw_all_t` / `tix_all_t`） |
| `bpu_ctl.sv` / `bpu_cmd.sv` | 优先级控制（`l1_ov` 增 `!r0.ah_hit`）与投机历史/RAS 命令 |
| `bpu_spec.sv` / `bpu_hist_vec.sv` | 投机与提交态历史环、折叠历史与 RAS（完全复用） |
| `bpu_pdq.sv` | PDCKPT 队列（增存 `base` 供 `pd_nb_pc` 假分支清槽） |

## 5. 一拍内的数据流

优先级保持 **refetch > S2 覆写（ovr） > S1 覆写（l1_ov，仅 `!r0.ah_hit`） > S0 发射**：
1. **S0 发射（`s0_go`）**：
   - 若 `refetch`：`ah_pipe_q[0..1].valid` 视作无效，S0 用 `ftb0` 查 `refetch_address`；随后向 `ah_pipe_q[0]` 写入以 `(refetch_address, spec1_fh)` 读出的 1-ahead 原始数据；
   - 非 `refetch` 正常发射：若 `ah_pipe_q[0].valid` 且 `aftb` 8 路标签命中 `s0_base`，则 `g0` 来自 1-ahead（`ah_hit = 1`），否则回退 `ftb0`（`ah_hit = 0`）；同时 `ah_pipe_q[1] <= ah_pipe_q[0]`，`ah_pipe_q[0]` 装载本拍以 `(s0_base, s0_fh)` 读出的 1-ahead 原始数据。
2. **S1（`r0_q`）**：读 `ftb1`、`s2_tage`、`s2_itt` 锁入 `r1_raw_q`；当 `!refetch && !ovr && r0_q.valid && !r0_q.ah_hit && s1_ftb_hit && pred_differs(g1, r0_q.g)` 时触发 `l1_ov`，保留 `ah_pipe_q` 不动（`ah_pipe_q[0]` 正好是 `r0_q` 本身的前驱数据，下一拍 `g1.next` 立即可命中 1-ahead！）。
3. **S2（`r1_q`）**：用 `r1_raw_q` 选出 `fin` 写 PTAB 与 `ftb_rec[blk_seq_q[8:0]]`；若 `ovr`，作废 `r0_q`，并按 `ah_pipe_q[1].key_base == r1_q.base` 恢复 `ah_pipe_q[0] <= ah_pipe_q[1]`（否则清零无效）。
4. **提交训练（并行）**：`brq` 队首 1 条控制分支查 `ftb_rec[blk_id[8:0]]`，若 `rc.valid && rc.id == blk_id` 且 PC 在块内（含 `pc + 2 == rc.base` 的 `carried` 槽 0），则同拍向全部预测表发起单分支 RMW 写（拍末生效）；预译码 `pd_nb_valid` 同拍在训练写之后（或独立组上）清除假分支槽。

## 6. 关键路径与深度

在 `eda-06` 上按 `main` 同口径完成 Yosys 面积与逻辑级数代理综合（`SYNTH_LIGHT=1 SYNTH_MEM=1 SYNTH_LTP=1 SYNTH_NO_MEMPRIO=1 SYNTH_ABC="strash;balance;map"`，64 GB 内存上限）：
- **`bpu`**：**`274,811 cells` / `131 layers`**（对比 `main` 16-bank BPU `549,458 cells` / `134 layers`：单元数 **−50.0%**，深度 **−3 层**，含 115 个 `$mem_v2` 存储块）；
  - 最长拓扑路径为 `u_spec.aras_q[5] → u_spec.spec_d[49]`（131 层，原有 `FE_RFAST` 重定向刷新路径），新增的 1-ahead FTB / Block-TAGE / Block-ITT / BRQ 逻辑均不在关键路径上；
- **`front_top`**：**`898,333 cells` / `153 layers`**。

## 7. 与模型的差异和取舍

- 与 `trace-model` 默认配置（EXP-050 里程碑 A 已合入默认，无需任何环境变量；原实验参数为 `ah1_4k_a2k1k` + `FTB_BRQ=2`）逐拍逐位对齐；
- `ftb_rec` 为 512 项（索引 `blk_id[8:0]`，10 位 `id` 校验），与模型 `FTB_BRQ=2` 一致；在途块数（PTAB 16 + F2B 8 + FTQ 64/128 + BRQ 16 ≤ 168）远小于 512，无覆盖风险；
- `FTB_S1_DIR=0`（删 `S1 mini-TAGE`）、`FTB_OVR_FAST=0`（无同拍组合旁路），与选定的 `ah1_4k_a2k1k` 规格完全一致。

## 8. 验证

全部在 `rtl/ftb-bpu` 分支实测通过（Verilator 5.052，`SOC_XLEN=64 SOC_FM=1`）：
- **静态检查**：`scripts/lint.sh rtl/frontend/bpu`（15 文件）**0 warnings / 0 errors**；`scripts/lint_chip.sh` **0 warnings / 0 errors**；
- **裸机逐条 + 逐周期等价（`scripts/fm_gate.sh`）**：**67/67 PASS，0 FAIL，0 SKIP，0 FM 不一致，0 周期偏差**（`coremark` `275,332 == 275,332`，较 `main` `290,676` **−5.28%**；`dhrystone` `102,229 == 102,229`，较 `main` `108,907` **−6.13%**；`itt-dispatch` `208,168 == 208,168`，**−3.36%**）；
- **逐事件指纹验证（`FPR=1000`）**：`coremark` 上 `PT` 指纹 **276/276 bins 全等**、`UP` 指纹 **276/276 bins 全等**；
- **`rv64gc` + `Sv39` Linux 26 段检查点对齐（`eda-08`/`eda-09`，`s01..s26`，每段 400 万周期，合计 1.04 亿周期）**：
  - 累计验证 **132,473,668 条真实 Linux 指令**，**26/26 段全部 PASS、0 Function-Model 不一致**；
  - **26/26 段全程 400 万周期 `PT`（103,974 / 103,974 bins）与 `UP`（103,144 / 103,144 bins）指纹 0 差异**（同步修复了 `trace-model` `LsuPipeInternal.h::ms_load_value` 未对 `m.atnt=1` 旧物理地址 store 做 STLF 前递的既有建模缺口，消除原 `s10`/`s15` 两处分叉）；
- **Yosys 综合（`eda-06`）**：`bpu` `274,811 cells`（−50.0%）/ `131 layers`，`front_top` `898,333 cells` / `153 layers`。

## 9. 参数与开关速查

全部主参数集中在 `bpu_types_pkg.sv`（`FTB_SLOTS`、`FTB_S0_*`、`FTB_S1_*`、`FTB_S2_TAGE_*`、`FTB_ITT_*`、`FTB_AH_*`、`FTB_REC_*`、`FTB_BRQ_*`）与 `bpu_stage_pkg.sv`（历史/RAS/PDCKPT）。

## 10. 变更记录

- 2026-11-24（`rtl/timing-opt2`，EXP-063 第二轮 28nm DC 时序优化）：
  - **2-Ahead B 与 Block A 真并行**（`bpu_types_pkg` / `bpu_ftb_tab` / `bpu_ftb_arrays` / `bpu_ftb_brq` / `bpu_eval` / `bpu`）：`aftb2` 开启 `STORE_B_BASE=1` 存 `b_base`、`ftb_rec_t` 存 `ah_a_base`，2-Ahead B 改为以 `(key_base, s0_base)` 索引与 Block A 并行评估并在末尾校验 `ah2_b_base == s0_b_base` 与 `b_truncated`，删除串行 `u0_b` 回退，`bpu_eval` 改用并行 `ttg_first_set` 选路与 6-bit 快速 `s0_b_bnd`；DC 28nm `bpu_eval` **0.84 → 1.28 GHz (+52.4%)**（WNS `−0.69 → −0.28 ns`，纯组合 `0.68 ns / 1.47 GHz`，69→49 级，面积 `25,652 → 23,911 um²`）。
  - **`bpu_spec` `M_ARCH` 改为寄存恢复**：重定向回退至架构态时直接读寄存态 `arch_sr_q / arch_fh_q / aras_q`（切断 `commit br_type[0..7] → aras_d → spec_a_ras_top` 关键路径）；DC 28nm `bpu_spec` **0.86 → 1.20 GHz (+39.5%)**（WNS `−0.66 → −0.33 ns`，纯组合 `0.70 ns / 1.43 GHz`，`reg2reg −0.32 ns / 1.22 GHz`，面积 `156k → 142k um²`）。
  - 验证：`lint_chip` 0、`fm_gate` **69/69 PASS（0 周期差）**、rv64gc Linux 26 窗全通、SPEC06 INT 386/386 `−1.20%`。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B 完成）：升级为 2-taken 双块融合 + 1-Ahead A（`2K×8 / 1K×4×4 / 256×3`）+ 2-Ahead B（`1K×8 / 512×4×4 / 256×3`）+ `NT=1` + 4-Bank `ic_pair_ok` + `HistRing 1024b` + 内部 `rec_q[256]`（删除流经 PTAB/F2B/FTQ 的 168 位 `bpu_ck`）+ `BRQ_W=1`；新增 `bpu_eval.sv`。Yosys 综合 `bpu` `504,078 cells` / `272 layers`（较旧 16-bank `549,458` 仍 −8.3%，最长路径 `r1_q[1074] → u_spec.spec_d[99]`，已登记至 TODO）；通过 `lint_chip` 0 警告、`fm_gate` 68/68（0 周期偏差，含 `directed/fe_2taken_fdip.bin`）与 `rv64gc` Linux 27 窗检查点对齐。
- 2026-11-21（`rtl/ftb-bpu`，EXP-050 里程碑 A 完成）：按文档先行完成 7 个块级 1-Ahead FTB SV 模块实现并删除 22 个旧 16-bank 文件；通过 `lint_chip` 0 警告、`fm_gate` 67/67（0 周期偏差）、`rv64gc` Linux 26/26 全量检查点 1.325 亿指令 0 FM 错误且 100% PT/UP 指纹 0 差异与 Yosys 综合（`bpu` 单元数 549,458 → 274,811，−50.0%，深度 134 → 131）。
