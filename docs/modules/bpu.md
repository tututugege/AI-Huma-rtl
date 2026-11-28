---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
model: trace-model-fe-2ahead front-end/BPU/BpuFtb.h、BpuSc.h、BPU_pipe.h、BPU.h、BPU_configs.h（调度单元 `front.core.bpu_pipe`，类 `BpuPipe`，Pure Single-Set Unified 2-Ahead BPU：`uFTB 256` + `1× Main FTB` + `1× 2-Way 2-Ahead ExBlockTage` + `1× 4-Table 2-Ahead ITT` + `RAS` + `self0` A0 复用 + `uFTB FastFill` + `tlat=1`）
status: Pure Single-Set Unified 2-Ahead BPU RTL 实现、77/77 门禁零周期差对齐与 Tier 0-elab/Tier 1 实测完成（`rtl/fe-2ahead`）
depth: Tier 1 TSMC28 LVT + PrimeTime STA：`bpu` `WNS -1.75 ns`（`55` 级，`0.417 GHz` vs `main -1.99 ns / 0.379 GHz`）；`front_top` 现值见 icache.md 6.1（64 KiB 2 级 ICache 后 `WNS -1.82 ns`，2026-11-28）
---

# bpu 设计文档（Pure Single-Set Unified 2-Ahead BPU）

> **2026-11-28 Pure Single-Set Unified 2-Ahead BPU（`rtl/fe-2ahead`）**：
> 在保留 `Clean BPU v11` 深宏单口 1RW SRAM、零 `T0` 读 `Meta/WRBypass/PLRU` 提交、`2A`（无同拍 refetch S0 发射）、单一 `ex_fh[3][6]`（`HR_BITS=256`、`ARCH_SR_W=200`）与同页跨 64B 行 2-Fetch 的基础上，采用**彻底单套预测器架构**（无 `u_aftb`、无 `u_s2_tage`、无 `u_s2_itt`、无 `u_atage`、无 `SC`）：
> - **2-Ahead（`A0 → A1 → S0`）**：`A0` 拍以 `(base_t, H_t)` 提前 2 拍启动唯一一套 **2-Way 6 表 2-Ahead ExBlockTage**（`2048 sets × 2 ways = 4096` 项/表，4-Bank `512×128b` 1RW）与 **4 表 2-Ahead ITT**（`512` 项/表，2-Bank `256×52b` 1RW）同步读；`A1` 拍锁存进纯 FF 寄存器 `ah_a1_raw_q`；`S0` 拍用最新历史 `H_{t+2}` 与前一拍块地址 `prev_base_q`（MORSL secondary tag）在 FF 上完成并行选路，与扩展为 `64×4=256` 项（紧凑 `141b/entry`）的 `u_ftb0`（支持 S2 `FastFill` + 提交镜像）组合成 S0 零气泡预测 `g0`。
> - **`self0` 零额外 SRAM 冷块自愈**：当冷启动块或紧接 `ovr`/`refetch` 的块在 S0 未拿到 2-Ahead 读数（`!ah_v`）时，直接在 S1 截取该块自己于 S0 启动并已完成同步读出的 `old_ah_a0` 到 `self0_raw_q`，于 S2 与 `u_ftb1`（`1024×4` 2-Bank 1RW）读出并行完成 0-Ahead 6 表 TAGE + 4 表 ITT 选路，在同套 SRAM 阵列完成训练（tag 加区分 XOR 常量 `0x555`/`0x2aa`），**零额外 SRAM 宏、零额外读口**。
> - **快速覆盖与 `T0 → T1` 提交流水**：S2 `ovr` 仅 2 气泡并立即用 `r1_q.base / r1_q.ck.h.ex_fh` 重启 A0（原开关 `BPU_FAST_OVR` 只取过 `1'b1`，2026-11-28 固化并删除）；`u_brq` 增加 1 拍 `T0 → T1` 寄存流水，切断 `u_rec`（单 Bank `512` 项 `1R1W`）到 `u_ah_ex_tage`/`u_aitt`/`u_ftb1` 的长提交路径。

## 1. 职责（含 3 级流水概览）

每拍预测一个至多 32B（16 个 2B 槽）的取指块，仅在 **4KB 页边界**截断（同页跨 64B 缓存行 2-Fetch），外部端口与 `front_pred_path` / Unified FTQ-64 100% 兼容（只出单块，EXP-051 的 `pair_*` / `ptab_is_pair` 等双块端口 2026-11-29 已删）：

1. **A0 / A1（2-Ahead 提前 SRAM 读取）**：
   - `s0_go` 时以 `(s0_base, spec_ex_fh)` 发起 `u_ah_ex_tage` 与 `u_aitt` 同步 1RW 读（`ah_key_q` 锁存关键帧，上一拍 `ah_key_q + ah_sram_raw` 推入 `ah_a1_raw_q`）；
   - `d.ovr` 时 squash `r0_q`/`ah_a1_raw_q`，直接以 `(r1_q.base, r1_q.ck.h.ex_fh)` 重启 `A0`；
   - `refetch` 时清 `r0_q`/`r1_q`/`ah_key_q.valid`/`ah_a1_raw_q.valid`/`prev_base_q`。
2. **S0（0 气泡主力预测，`pc_q` / `spec_q` / `ah_a1_raw_q` / `u_ftb0` 纯寄存驱动）**：
   - 无同拍 `refetch` 发射（`2A`：`issue = !refetch && !ovr && icache_read_ready`）；
   - 并行查找紧凑 FF `u_ftb0`（`64 × 4 = 256` 项，槽位存储 `20b` 压缩目标；仅对 `tgt_fits` 槽或 `BR_RET` 镜像）并与 `ah_a1_raw_q`（若 `valid`，使用当前 `spec_ex_fh` 与 `prev_base_q` 算 tag）经 2 路 `ah_ex_tage_select_slot` + 4 表 ITT 选路融合得出 `g0`，捕获只读 `ah_pred_meta_t`；
   - 将 `s0_base` 送入 Unified FTQ-64，推进 `spec_q` 与投机 RAS，并更新 `prev_base_q <= s0_base`。
3. **S1（`r0_q`，Main FTB 1RW 同步读 & `self0` 捕获）**：
   - 单块读取 **Main FTB**（`u_ftb1`，2-Bank 1RW）；
   - 若 `!r0_q.ah_v && ah_key_q.valid && (ah_key_q.key_base == r0_q.base)`，将本拍 SRAM 返回的 `ah_sram_raw` 捕获至 `self0_raw_q` 并置 `self0_v_q <= 1'b1`。
4. **S2（`r1_q`，终判、写 FTQ/元数据、`FastFill`、触发覆写）**：
   - 完成 `u_ftb1` 4 路比对；若 `!r1_q.ah_v && self0_v_q`，并行从 `self0_raw_q` 完成 0-Ahead 2 路 6 表 TAGE + 4 表 ITT 选路（`is_self0=1, prev_base=0`）；
   - 由 `u_ftb1` 的 2-bit `ctr` 充当基表完成 `resolve_ah_dir`、`eval` 与 Cut A2 平行比对，组装 `s2_meta` / `ah_meta` / `prev_base` 写入单 Bank `u_rf_rec[256]` 与单 Bank `u_rec[512]`；
   - 若 `d_valid && s2_ftb_hit && !r1_q.g.hit && fin.taken`，提出 **S2 `uFTB FastFill`** 写请求（当提交空闲 `!upd_en` 时写入 `u_ftb0`，保持严格单写口）。
5. **修复**：
   - `refetch` 时优先级 `pd_restore`（`bpu_pdq`）> 后端 `u_rf_rec[256]` > 架构状态直映 `arch_sr_q/arch_ex_fh_q/aras_q` 并递增 `epoch_q`。
6. **训练（`T0 → T1` 2 拍提交，零 `T0` 读单拍纯写）**：
   - `bpu_ftb_brq` `T0` 弹队首并读出 `u_rec[512]` 与解码偏移后打 1 拍入 `train_t1_*_q`（`T0 → T1`）；
   - `T1` 拍单拍纯写更新 `u_ftb1`、`u_ftb0`（同步 `u_ftb1` 新条目镜像）、`u_ah_ex_tage`（优先写 + 2-Way 8 项 `WRBypass`）与 `u_aitt`。

## 2. 配置（`bpu_pkg` / `bpu_stage_pkg` / `bpu_types_pkg`，现行默认）

存储阵列与宏映射（TSMC 28nm HS LVT 1RW）：

| 阵列 | 逻辑规模 | 物理实现 / 1RW Bank | 真实 28nm 宏映射 |
| --- | --- | --- | --- |
| `u_ftb0` | `64 × 4 = 256` 项 | FF（`bpu_uftb.sv`，`141b/项`） | 标准单元 FF（约 `36.1k` FFs） |
| `u_ftb1` | `1024 × 4 = 4096` 项 | 2-Bank 1RW，`512 × (4×215b=860b)`，`MASK_W=4` | `2 × 12 = 24 × 512×72` |
| `u_ah_ex_tage` | 6 表 × `2048 sets × 2 ways × 4 槽 × 16b` | 6 × 4-Bank 1RW，`512 × 128b`，`MASK_W=128`（无 Base SRAM） | `6 × 4 × 2 = 48 × 512×72` |
| `u_aitt` | 4 表 × `512 × 52b` | 4 × 2-Bank 1RW，`256 × 52b`，`MASK_W=52` | `4 × 2 = 8 × 256×64` |
| `u_brq/u_rec` | `512 × ftb_rec_t` | 单 Bank `1R1W`（真宏封装为 1RW） | `15 × 512×72`（Tier 1 `opt_clean` 裁剪 1 颗未使用切片，合计 `86 × 512×72`） |
| `u_rf_rec` | `256 × bpu_rf_rec_t` | 单 Bank `1R1W`（真宏封装为 1RW） | `6 × 256×72` |
| 历史 / RAS | `HR_BITS=256`，`ARCH_SR_W=200`，`EX_TN=6` | 单一 `ex_fh[3][6]` + `RAS_DEPTH=32` / `RASQ_N=64` | 标准单元 FF |

对应常量：`FTB_S0_SETS = 64`、`FTB_S0_WAYS = 4`、`FTB_S0_TGT_B = 20`（uFTB）；`FTB_S1_SETS = 1024`、`FTB_S1_WAYS = 4`、`BPU_FTB1_BANKS = 2`（Main FTB）；`EX_TAGE_N = 4096`、`EX_TAGE_WAYS = 2`、`EX_TN = 6`、`BPU_AH_TAGE_BANKS = 4`（ExBlockTage）；`FTB_ITT_N = 512`、`NITT = 4`、`BPU_ITT_BANKS = 2`（ITT）；`FTB_BRQ_N = 16`、`FTB_REC_N = 512`、`FTB_RF_REC_N = 256`；`BPU_WRB_N = 8`；`PQ_DEPTH = 32`（`bpu_pdq`）；`HR_BITS = 256`、`ARCH_SR_W = 200`（`bpu_spec.sv`）、`RAS_DEPTH = 32`、`RASQ_N = 64`。`141b/项`、`215b/路` 等位宽是按结构体字段手算的，没有用 `$bits` 核对。

SRAM 复位：`bpu_sram_1rw_banked` 有 `rst_n` 端口，复位期间把阵列扫成 `INIT`（`ttg_sram_1rw` 的 `INIT_SWEEP`），`u_rec` / `u_rf_rec`（`ttg_sram_1r1w`）同样，见 [common.md](common.md) 4.1 节。

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `clk`、`rst_n` | |
| 入 | `refetch`、`refetch_address`、`refetch_pd` | 全局重取指、地址、是否来自预译码冲刷 |
| 入 | `icache_read_ready` | 前端允许 S0 发射（`front_ctrl` 的 `bpu_icache_read_ready`） |
| 入 | `rf_valid`、`rf_blk`、`next_rf_blk`、`rf_type`、`rf_pc`、`rf_is_rvc` | 后端误预测修复：块号（读 `u_rf_rec`）、下一拍要读的块号（同步 SRAM 预读）、分支类别、pc |
| 入 | `pd_valid`、`pd_flush`、`pd_hn`（1 位：是否压 1 个历史符号）、`pd_hbits`（`HSYM_W` = 3 位）、`pd_ras_op / _val`、`pd_nb_valid / _pc` | 预译码检查结果（`front_pd_info`，寄存一拍）；假分支清槽用 `bpu_pdq` 队首的 `pd_base` |
| 入 | `upd_valid`、`base_pc`、`actual_dir`、`upd_is_rvc`、`br_type`、`target`、`pred_dir`、`alt_pred`、`pcpn`、`blk_id`（各 `[NCOMMIT]`） | 提交训练包 |
| 出 | `icache_read_valid`、`fetch_address` | S0 块（写 FTQ 的 `bpu_ptr`） |
| 出 | `override_valid`、`override_squash_n`、`hold_n` | S2 覆盖、要丢的块数、S1 里可能被丢的块数 |
| 出 | `ptab_write_enable`、`ptab_base_pc`、`predict_next_fetch_address`、`out_pred_dir`、`out_alt_pred`、`out_pcpn`、`out_blk_id` | S2 块写 FTQ（端口名里的 `ptab` 是旧名，现写统一 FTQ 的 `s2_ptr`） |
| 出 | `commit_upd_free`、`commit_tq_free` | 训练队列空闲项数，给 ROB 做提交信用 |

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | ---: | --- |
| `bpu_pkg.sv` | 36 | 共享基础常量（分支类型、RAS 深度、块宽） |
| `bpu_stage_pkg.sv` | 199 | `NITT=4`、`ITT_EX_MAP`、256b 历史环、单一 `ex_fh[3][6]`（2-Ahead 键只存索引折叠 `ex_fh0_t = ex_fh[0]`）、`ah_dir_itt_t`、`blk_t` |
| `bpu_types_pkg.sv` | 359 | FTB / 2-Way 6 表 2-Ahead ExTAGE / 4 表 ITT 类型、`make_ah_ex_tage_index` / `make_ah_itt_index`、`ah_ex_tage_select_slot`、`ftb_eval_ent`、`ftb_upsert_branch` |
| `bpu_sram_1rw_banked.sv` | 175 | 通用单口 Multi-Bank 1RW 同步 SRAM 封装（1 预测读 + 1 提交写 + `HOLD_RD0` + 可选 `clr_rd` / `rst_wr`） |
| `bpu_plru.sv` / `bpu_wrbypass.sv` | 84 + 76 | 提交期 per-set tree-PLRU 与 8 项 FF WRBypass CAM+Mem |
| `bpu_uftb.sv` | 197 | 64×4=256 项紧凑 FF uFTB（0 拍查，单写口：`upd_en` 镜像优先 > `ff_en` FastFill，后级预译码清槽） |
| `bpu_ftb_tab.sv` | 307 | 纯 1RW SRAM Main FTB（`u_ftb1`，2-Bank 1RW + 1 项 `FtbWrBuf` + 2 拍 `clr` 状态机 + 导出 `upd_new_ent_o`） |
| `bpu_ftb_ex_tage.sv` | 344 | 单套 2-Way 6 表 4-Bank 1RW 2-Ahead ExBlockTage（无 Base SRAM，`(tbl,sl,idx,way)` WRBypass，per-PC `use_alt`，双路并行 `uhi` 复位） |
| `bpu_ftb_itt.sv` | 148 | 单套 4 表 512 项 2-Bank 1RW Block-ITT（零 T0 读，无 WrBypass，3-bit `start_k` 防越界） |
| `bpu_ftb_arrays.sv` | 165 | 4 阵列容器（`u_ftb0` / `u_ftb1` / `u_ah_ex_tage` / `u_aitt`）与单口 1RW Bank 仲裁 |
| `bpu_ftb_brq.sv` | 196 | 16 项提交分支队列 + 单 Bank 512 项 1R1W `u_rec` + `T0 → T1` 流水寄存器 |
| `bpu_hist_vec.sv` / `bpu_spec.sv` | 160 + 382 | 256b 投机历史环 / 200b 架构移位器与投机/架构 RAS；`bpu_hist_vec` 的综合 / 仿真两种写法只在 `sym_n ≤ MAX_SYM` 时等价（[06 第 4 节](../06-equivalence-policy.md)），`bpu_spec` 的三个实例都是 `MAX_SYM = 1`、`sym_n = {3'd0, en}`，前提由构造保证 |
| `bpu_eval.sv` | 257 | S0（2-Ahead `ah_a1_raw_q` + `u_ftb0`）与 S2（`u_ftb1` + `self0` 并行评估、Cut A2、`fin_diff` 与元数据生成） |
| `bpu_ctl.sv` / `bpu_cmd.sv` | 49 + 94 | 3 级单块控制与历史/RAS/PC 下一拍命令（S2 覆盖当拍恢复） |
| `bpu_pdq.sv` | 65 | 32 项预译码检查点 FIFO |
| `bpu.sv` | 317 | 顶层：`A0 → A1 → S0 → S1 → S2` 流水、`self0` 捕获、`u_rf_rec[256]` 与外部兼容接口 |


## 5. 一拍内的数据流

- **A0 → S0**：`ah_a1_raw_q` 保持已在 `A0` 读出并稳定寄存的数据；`S0` 拍用当前 `spec_ex_fh` 与 `prev_base_q` 做 2-Way tag 比较（2 路并行 `hit0/hit1` 选路，无串行循环），`u_ftb0` 64 组 × 4 路并行读出后按 `resolve_ah_dir` 选中 4 槽方向并与 `g0` 求值合并。
- **S2**：`self0_raw_q` 仅使用寄存 FF 数据，与 `u_ftb1` 同步 1RW 宏读（`CLK→Q`）及 tag 比对**并行**完成 0-Ahead 2-Way 6 表 TAGE + 4 表 ITT 选路；若触发 `ovr`，当拍同步驱动 `u_spec` 检查点恢复、`ah_rd_en_eff` 重启 A0 并清 `r0_q`/`r1_q`/`ah_a1_raw_q`（原 `BPU_FAST_OVR=0` 的 1 拍 `ovr_pend_q` 解耦已于 2026-11-28 删除；若 `ovr → u_spec` / `ovr → A0` 成为瓶颈需重新实现）。
- **Train**：`T0 → T1` 提交流水将 `u_rec` 宏读与 `compute_commit_plan` 彻底切分到 `T0`/`T1` 两拍，避免 `u_rec → WRBypass → u_ftb1/u_ah_ex_tage` 跨宏长路径。

## 6. 关键路径与深度（面积与综合实测）

在 `eda` 集群上使用 `main` 合入的 `EXP-071` 四层快速 PPA 工具链（`fast_ppa.sh`，TSMC 28nm HPC+ LVT + 真实 `TEM5N28HPCPLVTA` 1RW SRAM 宏，`clk=0.65 ns`、`unc=0.05 ns`、`io=0.12 ns`）实测，并与 `main`（`6c42731`）基线同口径对比：

### 6.1 Tier 0-elab（`yosys-slang` 仅展开层次）

| 配置 / 模块 | Time(s) | Macros | MacroArea | SRAM_ns | Fallback | 宏构成 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `main` `bpu`（基线） | 4.15 | 180 | 2,019,486.8 | — | 0 | — |
| `rtl/fe-2ahead` `bpu` | 3.93 | **101** | **1,444,148.0** | 0.359 | 0 | `8× 256×64` + `6× 256×72` + `87× 512×72` |
| `main` `front_top`（基线） | 5.39 | 436 | 3,495,845.1 | — | 0 | — |
| `rtl/fe-2ahead` `front_top`（32 KiB ICache） | 5.12 | **357** | **2,920,506.3** | 0.359 | 0 | 同上 + `256× 64×64`（ICache） |

### 6.2 Tier 1（`Yosys + buf_high_fanout + PrimeTime` Real STA，`PT_LINK_STATUS=1`、`mem_v2=0`、`fb_bb=0`、`unmapped_std=0`）

| 模块 / 配置 | Macros | Logic+FF Area | Macro Area | Total Area (vs `main`) | `WNS_total` / `WNS_r2r` | `Fmax_T1` (vs `main`) | 关键路径与说明 |
| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| `main` `bpu`（`6c42731`） | 180 | 485,006.9 | 2,019,486.8 | 2,504,493.7 | `−1.99` / `−1.99` | `0.379 GHz` | 61 级，`2.46 ns`，`u_brq.u_rec -> u_ftb1.../A[0]` |
| **`fe-2ahead` `bpu`（`FAST_OVR=1`）** | **100** | 643,098.0 | 1,428,965.0 | **2,072,062.9 (`−17.3%`)** | **`−1.75` / `−1.75`** | **`0.417 GHz` (`+10.0%`)** | 55 级，`2.22 ns`，`FF -> u_ftb1.../A[0]`（`opt_clean` 省 1 颗 `512×72`） |
| `fe-2ahead` `bpu`（`FAST_OVR=0` 对照） | 100 | 644,553.5 | 1,428,965.0 | 2,073,518.5 (`−17.2%`) | `−1.75` / `−1.75` | `0.417 GHz` (`+10.0%`) | 55 级，`2.23 ns`，与 `FAST_OVR=1` 同路径/同 WNS |
| `main` `front_top`（`6c42731`，32 KiB ICache） | 436 | 876,338.6 | 3,495,845.0 | 4,372,183.6 | `−2.64` / `−2.13` | `0.304 GHz` | 92 级，`reg2reg −2.62` 至 `u_icache.u_arr` |
| **`fe-2ahead` `front_top`（`FAST_OVR=1`，32 KiB ICache，已被 64 KiB 2 级 ICache 取代，现值见 [icache.md](icache.md) 6.1）** | **356** | 1,050,453.6 | 2,905,323.2 | **3,955,776.8 (`−9.5%`)** | **`−2.59` / `−1.90`** | **`0.309 GHz` (`+1.6%`)** | 92 级，`reg2reg −2.54` 至 `u_icache.u_arr` |

- **结论**：
  1. **面积显著下降**：去掉第二套预测器（`u_aftb` / `u_s2_tage` / `u_s2_itt` / `u_atage`）后，即使 `u_ftb0` 从 `16×4` FF 扩展为 `64×4=256` 紧凑 FF（`Logic+FF` 增加约 `158k`），SRAM 宏从 `180` 颗降至 `100` 颗（`Macro Area` 减少 `590.5k`，`-29.2%`），`bpu` 总面积净降 **`-432.4k`（`-17.3%`）**，`front_top` 总面积净降 **`-416.4k`（`-9.5%`）**。
  2. **时序/主频优于 `main`**：受益于 `T0 → T1` 提交流水切断 `u_brq.u_rec -> u_ftb1` 跨宏提交长路，`bpu` Tier 1 `WNS` 从 `−1.99 ns` 改善至 `−1.75 ns`（按 `EXP-071` 标定系数 `Fmax_GT/Fmax_T1 = 1.65` 折算约 `0.688 GHz`，按 `main bpu` 比值 `1.75` 折算约 `0.729 GHz`），`front_top` 的全局 `reg->reg WNS` 由 `−2.13 ns` 改善至 `−1.90 ns`，瓶颈仍在 `u_icache.u_arr`（`satp` / data SRAM 地址多路复用），`u_bpu` 未拖慢前端主频。
  3. **`BPU_FAST_OVR=1` 无时序/面积惩罚**：`FAST_OVR=1` 与 `FAST_OVR=0` A/B 对照的 `WNS` 完全一致（均为 `−1.75 ns`、55 级至 `u_ftb1.../A[0]`），可无额外代价保留 0 气泡 fast-override（少 1 拍 `ovr_pend` 气泡）。

## 7. 与模型的差异

- `u_ftb0` 内部按 20-bit 槽压缩目标存储（`141b/项`），仅镜像 `ftb_s0_tgt_fits`（`±1 MB`）或 `BR_RET`；C++ 模型 `FtbTab` 保留全宽 `target` 字段。经 77 程序 `fm_gate.sh` 实测，功能与周期全部 0 差异。
- S2 覆盖固定为快速覆盖（原 `BPU_FAST_OVR = 1`；2026-11-28 删开关）。模型只实现这一种配置：2026-11-28 删掉了 fe-2ahead 的 20 个 `FE_*` 运行时开关（`FE_PRED_ARCH`、`FE_AH_MODE`、`FE_TRAIN_LAT`、`FE_ICACHE_PIPE` 等）和它们的死分支（第二套预测器 aftb / atage / S2 ExBlockTage / S2 ITT、1-Ahead、`ovr_pend`、S3 级），77 程序周期与删除前逐个相同；和 RTL 比周期不需要设环境变量，`fm_gate.sh` 77/77 逐拍等价。交接时记录的 "44/77 周期差" 是模型没带当时那组环境变量跑出来的参考表造成的，不是 RTL 回退。

## 8. 验证

- **静态检查与编码规范**：
  - `python3 harness/tools/svlint.py rtl/frontend/bpu/*.sv`：`0` errors。
  - `bash scripts/lint.sh rtl/frontend/bpu`：`lint ok (19 files, 1 dirs)`。
  - `bash scripts/lint_chip.sh`：`lint_chip: 0 warnings/errors (build/lint_chip.txt)`。
- **架构与逐拍等价门禁（对齐 `trace-model-fe-2ahead`）**：
  - `SOC_FM=1` 编译 `core_tb` 后运行 `JOBS=12 bash scripts/fm_gate.sh`：**`PASS 77 FAIL 0 SKIP 0`**，周期对 `scripts/ref_cycles.txt`（模型默认配置 = RTL 配置，a8ceec2 重新生成）0 处不同。
- **综合与时序验证（`eda` 集群）**：
  - `Tier 0-elab`（`eda-06`，`mode=real`）：`bpu` `101` macros、`front_top` `357` macros，`Fallback=0`。
  - `Tier 1`（`eda-06`/`eda-07`，`clk=0.65 ns`、`mode=real`）：`t1_bpu_fovr1`、`t1_bpu_fovr0`、`t1_ft` 三组均 `PT_LINK_STATUS=1`、`mem_v2=0`、`fb_bb=0`、`unmapped_std=0`（产物位于 NFS `/nfs_global/S/houruyao/fe2ah_ppa_out/`）。

- **待补**：后续若需确认精准 DC `compile_ultra` 签核面积与频率（含线负载与多级地址树拆分对 `u_ftb1.../A[0]` `0.97 ns` 末级扇出的收敛效果），可进一步在 `eda` 集群跑 `Tier 2a`/`Tier 3` 综合及 Linux 26 窗 / SPEC06 全量评估。

## 9. 参数与开关速查

- 无开关（`BPU_FAST_OVR` 2026-11-28 删除，固定为 S2 覆盖当拍重启 A0；第 6 节的 `FAST_OVR=0` 综合对照是删除前的历史数据）。
- 尺寸常量见第 2 节。

## 10. 变更记录

- 2026-11-29 清理 C：删 EXP-051 2-taken 双块残留（EXP-070 起不再产生）：`bpu.sv` 的 `pair_valid / pair_addr2 / pair_a_len / pair_b_len`、`ptab_is_pair / ptab_base_b / ptab_a_len` 输出（原恒 0）与 `pd_ras_op2 / pd_ras_val2 / pd_nb_base` 输入，`clr_base_eff` 改为直接用 `pd_base`（`pd_nb_base` 恒 0）；`pd_hn` / `hr_push_n` 由 2 位收为 1 位、`pd_hbits` / `hr_push_bits` 由 6 位收为 `HSYM_W` 位；`bpu_cmd` 删 `rr_op2 / rr_val2`；`bpu_spec` 删第二个 `do_op`（槽 1），`pack_syms` 收为单符号 `pack_sym`，`u_r1_ck` 由 `MAX_SYM = 2` 改为 1，删 `hr_push_n ≤ 2` 的 SVA（单符号时 `bpu_hist_vec` 前提恒成立）（周期不变）。
- 2026-11-28 清理：删 `BPU_FAST_OVR`（只取过 1）及慢覆盖状态 `ovr_pend_q` / `ovr_ck_q` / `ovr_out_q` / `ovr_base_q` / `issue_no_ovr`、`bpu_ctl.ovr_pend`、`bpu_cmd` 的 `ovr_pend / ovr_ck / ovr_out` 口与 `act_*` 选择、`bpu_spec.ovr` 口与恒假三目；2-Ahead 键的折叠历史只存 `k = 0` 片（新类型 `ex_fh0_t`，`ah_key_q` / `ah_a1_raw_q` / `r0_q` / `r1_q` / `ftb_rec_t`（`u_rec` SRAM 宽度 −144 位）/ `train_t1_rc_q` 各少 144 位，原 `[2:1]` 片只写不读）；删 `bpu_ftb_tab.clr_hold_valid_q`（只写不读）、包内死项 `bpu_pkg::PC_W / BANK_W`、`bpu_stage_pkg::LANE_W / hist_push / hist_push_sym / ras_push / ras_pop`，`u_rf_rec` / `u_rec` 不再显式传 `WRITE_FIRST`（`ttg_sram_1r1w` 固定写优先）；删不起作用的 `UNUSED*` 豁免，`bpu.sv` 的 `unused_ok` 汇点去掉其实有读者的项（只留 `upd_pc`、`next_rf_blk` 高位）（周期不变；第 4 节 `u_rec` 宏数未重测）。
- 2026-11-28（`rtl/fe-2ahead`）：基于 `main`（`6c42731` Clean BPU v11 + EXP-071 快速 PPA 工具链）重构为 **Pure Single-Set Unified 2-Ahead BPU**，修复 `bpu.sv` `u_spec.issue` 在 `BPU_FAST_OVR=1` 下的 override 门控后通过 `lint`/`lint_chip`/77 程序 `fm_gate`（0 周期差），并在 `eda` 集群完成 `Tier 0-elab` 与 `Tier 1` 实测（含 `BPU_FAST_OVR=0` A/B 对照与 `front_top` 整前端综合）。
- 2026-11-28（`rtl/fe-2ahead`）：文档按 TEMPLATE 十节重排（新增第 2 节常量表、第 3 节端口表、文件行数），补 SRAM 复位清零说明，门禁改为对 `scripts/ref_cycles.txt`；`front_top` 的 32 KiB ICache 数字标为已被取代。
