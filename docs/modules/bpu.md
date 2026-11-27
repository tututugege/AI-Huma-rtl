---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
model: trace-model front-end/BPU/BpuFtb.h、BpuSc.h、BPU_pipe.h、BPU.h、BPU_configs.h（调度单元 `front.core.bpu_pipe`，类 `BpuPipe`，Clean BPU v11：单块 1-Taken 1-Ahead A + S2 6 表 ExBlockTage + 深宏 Multi-Bank 1RW SRAM + 零 T0 Meta/WRBypass 提交 + 2A/2B 解耦）
status: Plan A（Clean BPU v11）三仓同步重构中
depth: 待实测（TSMC 28nm 真实 SRAM 宏 DC 签核）
---

# bpu 设计文档（Clean BPU v11：单块 1-Taken + 1-Ahead A + S2 6 表 ExBlockTage + 深宏 Multi-Bank 1RW）

> **2026-11-27 Clean BPU v11（Plan A 架构大扫除）**：
> 在保留 `v10.1` 深宏单口 1RW SRAM、零 `T0` 读 `Meta/WRBypass/PLRU` 提交、`2A`（无同拍 refetch S0 发射）与 `2B`（1 拍寄存 `ovr_pend_q` 恢复 + 零 FF 空闲口 Ahead 重读）全部高频/低面积成果的前提下，彻底清理历史上叠加的 2-Taken / 2-Ahead B / StatCorrector / S3 拆拍补丁：
> - **回归干净的 3 级单块流水（`S0 → S1 → S2`，`MAIN_LAT = 2`）**：
>   - 删除全部 **2-Ahead B / Block B**（`u_aftb2` / `u_atage2` / `u_aitt2`、全部 `_b` 流水线与双写 `ftb_rec` / `rf_rec`、双读口 `rd1`/`rd2`），删除 **S3 拆拍**（`r2_q` / `s3_eval_*_q`），外部 `bpu.sv` 端口保持 100% 兼容（`pair_valid = 0`、`ptab_is_pair = 0`）；
>   - 删除全部 **StatCorrector**（`bpu_ftb_sc.sv` 7 张表、`sc_fh[4]`、`imli`、`LHT`、4 个 `WRBypass` CAM、`sc_meta`）；
>   - 删除死字段 `ftb_ent_t.lru`；`u_ftb1` 按 14-bit 标签紧凑存储（**`215b/way ≤ 216b = 3 × 72b`**）并缩为 2-Bank 512 深（单块无 A/B Bank 冲突），宏数由 `64 × 256×72` 降至 **`24 × 512×72`**；
>   - 独立拆分 `bpu_uftb.sv`（16×4 FF 冷启动 uFTB），`bpu_ftb_tab.sv` 专职纯 1RW SRAM FTB（`u_ftb1` 与 `u_aftb`）；
>   - **单一统一折叠历史引擎 `ex_fh[3][6]`**：`EX_TN = 6`（历史长度 `{5, 11, 22, 44, 89, 178}`），全局历史环由 `1024b` 缩至 **`256b`**（`HR_PTR_W = 8`），`arch_sr_q` 由 `720b` 缩至 **`200b`**；1-Ahead 4 表 TAGE 与 3 表 ITT 直接经 `AH_EX_MAP = {0, 1, 3, 5}` 投影复用 `ex_fh`，彻底删除重复维护的 `fh[3][4]` 与 `sc_fh[4]`。

## 1. 职责与 3 级流水

每拍预测一个至多 32B（16 个 2B 槽）的取指块，仅在 **4KB 页边界**截断（**同页跨 64B 缓存行 2-Fetch**：`block_bnd(base)` 不再按 64B 缓存行截断；当 `base[5:0] > 32 && base[11:6] != 6'h3f` 时，ICache Port B 同拍并行读取相邻缓存行 `line + 1`，与 Port A 同页零额外 ITLB 查表且必然落不同 4-Bank 零 Bank 冲突，由 `front_head_fix` 无缝拼接跨 64B 行的 32-bit 指令），外部端口与 `front_pred_path` / Unified FTQ-64 完全兼容：

1. **S0（0 气泡主力预测，`pc_q` / `spec_q` 纯寄存驱动）**：
   - 无同拍 `refetch` 发射（`2A`：`issue = !refetch && !ovr_pend_q && !ovr && icache_read_ready`）；
   - 优先消费上一拍已提前读出并保持在同步 SRAM 输出端的 **1-Ahead A** 数据（`u_aftb 2048×8` + `u_atage 1024×4×4` + `u_aitt 256×3`，由 `ah_key_q` 寄存的前驱 `(key_base, key_ex_fh)` 索引），8 路并行比对 22-bit 组合标签并捕获只读 `ah_pred_meta_t`；未命中或冷启动时回退 **uFTB**（`u_ftb0`，16×4 FF）；
   - 同拍以 `(s0_base, s0_ex_fh)` 发起下一块 1-Ahead A 1RW SRAM 读，并推进投机历史 `ex_fh` 与投机 RAS；将 `s0_base` 送入 Unified FTQ-64（`pair_valid = 0`）。
2. **S1（`r0_q`，主阵列 1RW SRAM 同步读）**：
   - 用寄存的 `(r0_q.base, r0_ix_q, r0_ex_ix_q)` 单块读取 **Main FTB**（`u_ftb1`，2-Bank 1RW）、**S2 6 表 ExBlockTage**（`u_s2_tage`，8-Bank Tagged + 4-Bank Base 1RW）与 **S2 ITT**（`u_s2_itt`，2-Bank 1RW）。
3. **S2（`r1_q`，终判、写 FTQ/元数据、触发 `2B` 寄存覆写）**：
   - 完成 FTB1 4 路比对、6 表 `ex_tage_select`、3 表 ITT 选路与 `ftb_eval_ent`，组装只读 `s2_pred_meta_t` 与 `out_pred_dir/alt_pred/pcpn/blk_id` 写入 Unified FTQ-64、单 Bank `u_rf_rec[256]` 与单 Bank `u_rec[512]`；
   - 若 `pred_differs(fin, r1_q.g)` 触发 `ovr`：当拍仅作废 `r0_q`（`override_squash_n = {1'b0, ovr && r0_q.valid}`），锁存 `pc_d = fin.next` 并置 `ovr_pend_q <= 1`、`ovr_ck_q <= r1_q.ck`、`ovr_out_q <= fin`、`ovr_base_q <= r1_q.base`；
   - 下一拍（`ovr_pend_q == 1`、`!refetch`）：S0 空闲，由纯寄存 `ovr_*_q` 恢复 `u_spec`（彻底切断 S2 `ovr` 到 `u_spec` 与 `u_arrays` 的组合长路径！），并利用空闲预测口直接以 `(ovr_base_q, ovr_ck_q.h.ex_fh)` 重读 1-Ahead A 1RW SRAM（零 FF 备份恢复 Ahead 命中率！）。
4. **修复**：
   - `refetch` 时清 `r0_q/r1_q/ovr_pend_q/ah_key_q.valid`；`pd_restore` 从 `bpu_pdq` 队首检查点修复；后端误预测命中内部单 Bank `u_rf_rec[256]`（`id` + `epoch` 校验）时按检查点修复；否则零门延迟直映寄存态 `arch_sr_q/arch_ex_fh_q/aras_q` 并递增 `epoch_q`。
5. **训练（零 `T0` 读单拍纯写，原生 `1.00 br/cyc`）**：
   - 8 通道提交推进 `arch_sr_q[199:0]` / `arch_ex_fh_q` / `aras_q` 并将控制分支入 16 项 `bpu_ftb_brq`；
   - 每拍弹队首 1 条分支，由单 Bank `u_rec[512]` 还原预测态 `(base, ex_fh, ah_key, s2_meta, ah_meta)`，查 8 项 FF `WRBypass` + `Meta` + 提交期 tree-PLRU，单拍纯写更新全部预测阵列（FTB 表预测优先 + 1 项 `FtbWrBuf`；TAGE/ITT 表跳过饱和写 + 写优先 `not-hit`）。

## 2. 配置与 SRAM 宏布局（TSMC 28nm HS LVT 1RW）

| 阵列 | 逻辑规模 | 物理实现 / 1RW Bank | 真实 28nm 宏映射（估算） |
| --- | --- | --- | --- |
| `u_ftb0` | `16 × 4 = 64` 项 | FF（`bpu_uftb.sv`） | 标准单元 FF（冷启动回退） |
| `u_ftb1` | `1024 × 4 = 4096` 项 | 2-Bank 1RW，`512 × (4×215b=860b)`，`MASK_W=4` | `2 × 12 = 24 × 512×72` |
| `u_s2_tage` Base | `4096 × 4` 槽 × 2b | 4-Bank 1RW，`1024 × 8b`，`MASK_W=4` | `4 × 2 = 8 × 512×8` |
| `u_s2_tage` Tagged | 6 表 × `4096 × 4` 槽 × 16b | 6 × 8-Bank 1RW，`512 × 64b`，`MASK_W=64` | `6 × 8 = 48 × 512×72` |
| `u_s2_itt` | 3 表 × `256 × 52b` | 3 × 2-Bank 1RW，`128 × 52b`，`MASK_W=52` | `3 × 2 = 6 × 128×64` |
| `u_aftb` | `256 × 8 = 2048` 项 | 2-Bank 1RW，`128 × (8×223b=1784b)`，`MASK_W=8` | `2 × 28 = 56 × 128×64` |
| `u_atage` | 4 表 × `1024 × 4` 槽 × 15b | 4 × 2-Bank 1RW，`512 × 60b`，`MASK_W=60` | `4 × 2 = 8 × 512×72` |
| `u_aitt` | 3 表 × `256 × 52b` | 3 × 2-Bank 1RW，`128 × 52b`，`MASK_W=52` | `3 × 2 = 6 × 128×64` |
| 历史 / RAS / 队列 | `HR_BITS=256`，`ARCH_SR_W=200`，`EX_TN=6` | 单一 `ex_fh[3][6]`，单 Bank `u_rec[512]` / `u_rf_rec[256]` | — |

## 3. 文件清单

| 文件 | 职责 |
| --- | --- |
| `bpu_pkg.sv` | 共享基础常量（分支类型、RAS 深度、块宽） |
| `bpu_stage_pkg.sv` | 流水线阶段类型、256b 历史环、单一 `ex_fh[3][6]`、`ck_t`、`blk_t` 与纯函数 |
| `bpu_types_pkg.sv` | FTB / 6 表 ExTAGE / 1-Ahead TAGE / ITT 类型、统一投影索引哈希、`ftb_eval_ent`、`ftb_upsert_branch` |
| `bpu_sram_1rw_banked.sv` | 通用单口 Multi-Bank 1RW 同步 SRAM 封装（1 预测读 + 1 提交写 + 可选 `clr_rd` / `rst_wr`） |
| `bpu_plru.sv` / `bpu_wrbypass.sv` | 提交期 per-set tree-PLRU 与 8 项 FF WRBypass CAM+Mem |
| `bpu_uftb.sv` | 独立 16×4 FF 冷启动 uFTB（0 拍组合查、1 拍提交更新与预译码清槽） |
| `bpu_ftb_tab.sv` | 纯 1RW SRAM FTB 阵列（复用实现 `u_ftb1` 与 `u_aftb`，紧凑 `TAG_W` 存储 + 1 项 `FtbWrBuf` + 零 T0 读） |
| `bpu_ftb_tage.sv` | 1-Ahead A 4 表 2-Bank 1RW Block-TAGE（零 T0 读 + 8 项 WRBypass + 延迟 `uhi` 复位） |
| `bpu_ftb_ex_tage.sv` | S2 6 表 8-Bank 1RW ExBlockTage + 4-Bank Base（零 T0 读 + 8 项 WRBypass + 16 项 per-PC `use_alt`） |
| `bpu_ftb_itt.sv` | 3 表 2-Bank 1RW Block-ITT（复用实现 `u_s2_itt` 与 `u_aitt`，零 T0 读） |
| `bpu_ftb_arrays.sv` | 7 张预测阵列容器与 1RW Bank 仲裁（FTB 预测优先、TAGE/ITT 写优先 `not-hit`） |
| `bpu_ftb_brq.sv` | 16 项 `1.00 br/cyc` 提交分支队列 + 单 Bank 512 项 1R1W `u_rec` |
| `bpu_hist_vec.sv` / `bpu_spec.sv` | 256b 投机历史环 / 200b 线性架构历史移位器（仅维护 `ex_fh[3][6]`）与投机/架构 RAS |
| `bpu_eval.sv` | S0（1-Ahead A + uFTB 回退）与 S2（Main FTB + 6 表 ExTAGE + ITT 终判与元数据生成） |
| `bpu_ctl.sv` / `bpu_cmd.sv` | 3 级单块控制（`refetch > ovr_pend > ovr > issue`）与历史/RAS/PC 下一拍命令 |
| `bpu_pdq.sv` | 32 项预译码检查点 FIFO |
| `bpu.sv` | 顶层：S0→S1→S2 流水、单 Bank `u_rf_rec[256]`、`ovr_pend_q` 恢复与外部兼容接口 |

## 4. 变更记录

- 2026-11-27（`rtl/uftq-subsys`，**Clean BPU v11 + 同页跨行 2-Fetch + A1/A2/B1 拆链**）：
  - 彻底删除 2-Ahead B / Block B、StatCorrector（`bpu_ftb_sc.sv`）、S3 拆拍与重复 `fh[3][4]` / `sc_fh[4]` / `imli`；回归单块 1-Taken 3 级流水（`MAIN_LAT=2`）+ 6 表 S2 `ExBlockTage` + 单一 `ex_fh[3][6]`（`HR_BITS=256`、`ARCH_SR_W=200`）+ 保留 `2A/2B` 寄存覆写恢复与零 FF Ahead 重读；独立拆分 `bpu_uftb.sv`，删除死字段 `lru` 并收紧 `u_ftb1` 至 2-Bank `512×72`（24 宏）；`u_rec` / `u_rf_rec` 回归单 Bank 1R1W；
  - 新增同页跨 64B 缓存行 2-Fetch（`block_bnd` 仅在 4KB 页边界截断；`off6 == 32` 同页补 `up16` 消灭行尾 32-bit Taken 分支 Predecode Flush；删除 ITLB `peek_b_*`）；
  - 关键路径拆链：**A1**（`ah_rd_en_eff = !refetch && (ovr_pend_q || icache_read_ready)` 解除 `!ovr` 对 1-Ahead SRAM 的门控）、**A2**（`ex_tage_select` 并行 `p_oh/a_oh` + `bpu_eval` 4 槽 `pred_k/diff_k` 与 6 表 TAGE 并行预求值，仅 1-bit `fin_diff` 进 `bpu_ctl`）、**B1**（`front_pred_path` 对 BPU S2 → `icache_fdip` 输入打 1 拍寄存）。
- 2026-11-27（`rtl/bpu-sram-opt`，`v10.1`）：深宏 Multi-Bank 1RW + 零 T0 `Meta/WRBypass/PLRU` + 零 FF `d.ovr` Ahead 重读 + S2→S3 拆拍；真实 28nm 宏 DC 总面积 `3.313 mm²`（296 宏 / `2.661 mm²`），`fm_gate` 77/77 PASS。
- 2026-11-25（`rtl/rob-ptr-bpu`）：S2 `ExBlockTage` + `StatCorrector`（现已精简为 6 表 `ExBlockTage` 并移除 SC）。
- 2026-11-21（`rtl/fe-2fetch-2taken` / `rtl/ftb-bpu`）：块级 FTB + 1-Ahead A 里程碑 A 与 2-Taken 里程碑 B。
