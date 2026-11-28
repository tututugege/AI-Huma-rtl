---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
model: trace-model-fe-2ahead front-end/BPU/BpuFtb.h、BpuSc.h、BPU_pipe.h、BPU.h、BPU_configs.h（调度单元 `front.core.bpu_pipe`，类 `BpuPipe`，Pure Single-Set Unified 2-Ahead BPU：`uFTB 256` + `1× Main FTB` + `1× 2-Way 2-Ahead ExBlockTage` + `1× 4-Table 2-Ahead ITT` + `RAS` + `self0` A0 复用 + `uFTB FastFill` + `tlat=1`）
status: Pure Single-Set Unified 2-Ahead BPU RTL 实现、77/77 门禁零周期差对齐与 Tier 0-elab/Tier 1 实测完成（`rtl/fe-2ahead`）
depth: Tier 1 TSMC28 LVT + PrimeTime STA：`bpu` `WNS -1.75 ns`（`55` 级，`0.417 GHz` vs `main -1.99 ns / 0.379 GHz`）、`front_top` `WNS -2.59 ns`（`r2r -1.90 ns` vs `main -2.64 ns / r2r -2.13 ns`）
---

# bpu 设计文档（Pure Single-Set Unified 2-Ahead BPU）

> **2026-11-28 Pure Single-Set Unified 2-Ahead BPU（`rtl/fe-2ahead`）**：
> 在保留 `Clean BPU v11` 深宏单口 1RW SRAM、零 `T0` 读 `Meta/WRBypass/PLRU` 提交、`2A`（无同拍 refetch S0 发射）、单一 `ex_fh[3][6]`（`HR_BITS=256`、`ARCH_SR_W=200`）与同页跨 64B 行 2-Fetch 的基础上，采用**彻底单套预测器架构**（无 `u_aftb`、无 `u_s2_tage`、无 `u_s2_itt`、无 `u_atage`、无 `SC`）：
> - **2-Ahead（`A0 → A1 → S0`）**：`A0` 拍以 `(base_t, H_t)` 提前 2 拍启动唯一一套 **2-Way 6 表 2-Ahead ExBlockTage**（`2048 sets × 2 ways = 4096` 项/表，4-Bank `512×128b` 1RW）与 **4 表 2-Ahead ITT**（`512` 项/表，2-Bank `256×52b` 1RW）同步读；`A1` 拍锁存进纯 FF 寄存器 `ah_a1_raw_q`；`S0` 拍用最新历史 `H_{t+2}` 与前一拍块地址 `prev_base_q`（MORSL secondary tag）在 FF 上完成并行选路，与扩展为 `64×4=256` 项（紧凑 `141b/entry`）的 `u_ftb0`（支持 S2 `FastFill` + 提交镜像）组合成 S0 零气泡预测 `g0`。
> - **`self0` 零额外 SRAM 冷块自愈**：当冷启动块或紧接 `ovr`/`refetch` 的块在 S0 未拿到 2-Ahead 读数（`!ah_v`）时，直接在 S1 截取该块自己于 S0 启动并已完成同步读出的 `old_ah_a0` 到 `self0_raw_q`，于 S2 与 `u_ftb1`（`1024×4` 2-Bank 1RW）读出并行完成 0-Ahead 6 表 TAGE + 4 表 ITT 选路，在同套 SRAM 阵列完成训练（tag 加区分 XOR 常量 `0x555`/`0x2aa`），**零额外 SRAM 宏、零额外读口**。
> - **可配 `BPU_FAST_OVR` 与 `tlat=1` 提交流水**：默认 `BPU_FAST_OVR = 1'b1`（S2 `ovr` 仅 2 气泡并立即用 `r1_q.base / r1_q.ck.h.ex_fh` 重启 A0）；`u_brq` 增加 1 拍 `T0 → T1` 寄存流水（`FE_TRAIN_LAT = 1`），切断 `u_rec`（单 Bank `512` 项 `1R1W`）到 `u_ah_ex_tage`/`u_aitt`/`u_ftb1` 的长提交路径。

## 1. 职责、配置与 3 级流水

每拍预测一个至多 32B（16 个 2B 槽）的取指块，仅在 **4KB 页边界**截断（同页跨 64B 缓存行 2-Fetch），外部端口与 `front_pred_path` / Unified FTQ-64 100% 兼容（`pair_valid = 0`、`ptab_is_pair = 0`）：

1. **A0 / A1（2-Ahead 提前 SRAM 读取）**：
   - `s0_go` 时以 `(s0_base, spec_ex_fh)` 发起 `u_ah_ex_tage` 与 `u_aitt` 同步 1RW 读（`ah_key_q` 锁存关键帧，上一拍 `ah_key_q + ah_sram_raw` 推入 `ah_a1_raw_q`）；
   - `d.ovr`（`BPU_FAST_OVR=1`）时 squash `r0_q`/`ah_a1_raw_q`，直接以 `(r1_q.base, r1_q.ck.h.ex_fh)` 重启 `A0`；当 `BPU_FAST_OVR=0` 时退回 1 拍 `ovr_pend_q` 解耦恢复与 A0 重读；
   - `refetch` 时清 `r0_q`/`r1_q`/`ovr_pend_q`/`ah_key_q.valid`/`ah_a1_raw_q.valid`/`prev_base_q`。
2. **S0（0 气泡主力预测，`pc_q` / `spec_q` / `ah_a1_raw_q` / `u_ftb0` 纯寄存驱动）**：
   - 无同拍 `refetch` 发射（`2A`：`issue = !refetch && !ovr_pend_q && !ovr && icache_read_ready`）；
   - 并行查找紧凑 FF `u_ftb0`（`64 × 4 = 256` 项，槽位存储 `20b` 压缩目标；仅对 `tgt_fits` 槽或 `BR_RET` 镜像）并与 `ah_a1_raw_q`（若 `valid`，使用当前 `spec_ex_fh` 与 `prev_base_q` 算 tag）经 2 路 `ah_ex_tage_select_slot` + 4 表 ITT 选路融合得出 `g0`，捕获只读 `ah_pred_meta_t`；
   - 将 `s0_base` 送入 Unified FTQ-64（`pair_valid = 0`），推进 `spec_q` 与投机 RAS，并更新 `prev_base_q <= s0_base`。
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
   - `bpu_ftb_brq` `T0` 弹队首并读出 `u_rec[512]` 与解码偏移后打 1 拍入 `train_t1_*_q`（`FE_TRAIN_LAT = 1`）；
   - `T1` 拍单拍纯写更新 `u_ftb1`、`u_ftb0`（同步 `u_ftb1` 新条目镜像）、`u_ah_ex_tage`（优先写 + 2-Way 8 项 `WRBypass`）与 `u_aitt`。

## 2. 接口清单（外部兼容，100% 与 `main` 一致）

`bpu.sv` 顶层输入/输出端口列表、位宽、名称及 `pair_valid=0` / `ptab_is_pair=0` 协议与 `main`（Clean BPU v11）完全一致，`front_pred_path.sv`、`front_top.sv` 与 `soc_top.sv` 零改动。

## 3. 存储阵列与宏映射布局（TSMC 28nm HS LVT 1RW）

| 阵列 | 逻辑规模 | 物理实现 / 1RW Bank | 真实 28nm 宏映射 |
| --- | --- | --- | --- |
| `u_ftb0` | `64 × 4 = 256` 项 | FF（`bpu_uftb.sv`，`141b/项`） | 标准单元 FF（约 `36.1k` FFs） |
| `u_ftb1` | `1024 × 4 = 4096` 项 | 2-Bank 1RW，`512 × (4×215b=860b)`，`MASK_W=4` | `2 × 12 = 24 × 512×72` |
| `u_ah_ex_tage` | 6 表 × `2048 sets × 2 ways × 4 槽 × 16b` | 6 × 4-Bank 1RW，`512 × 128b`，`MASK_W=128`（无 Base SRAM） | `6 × 4 × 2 = 48 × 512×72` |
| `u_aitt` | 4 表 × `512 × 52b` | 4 × 2-Bank 1RW，`256 × 52b`，`MASK_W=52` | `4 × 2 = 8 × 256×64` |
| `u_brq/u_rec` | `512 × ftb_rec_t` | 单 Bank `1R1W`（真宏封装为 1RW） | `15 × 512×72`（Tier 1 `opt_clean` 裁剪 1 颗未使用切片，合计 `86 × 512×72`） |
| `u_rf_rec` | `256 × bpu_rf_rec_t` | 单 Bank `1R1W`（真宏封装为 1RW） | `6 × 256×72` |
| 历史 / RAS | `HR_BITS=256`，`ARCH_SR_W=200`，`EX_TN=6` | 单一 `ex_fh[3][6]` + `RAS_DEPTH=32` / `RASQ_N=64` | 标准单元 FF |

## 4. 文件清单

| 文件 | 职责 |
| --- | --- |
| `bpu_pkg.sv` | 共享基础常量（分支类型、RAS 深度、块宽） |
| `bpu_stage_pkg.sv` | `BPU_FAST_OVR`、`NITT=4`、`ITT_EX_MAP`、256b 历史环、单一 `ex_fh[3][6]`、`ah_dir_itt_t`、`blk_t` |
| `bpu_types_pkg.sv` | FTB / 2-Way 6 表 2-Ahead ExTAGE / 4 表 ITT 类型、`make_ah_ex_tage_index` / `make_ah_itt_index`、`ah_ex_tage_select_slot`、`ftb_eval_ent`、`ftb_upsert_branch` |
| `bpu_sram_1rw_banked.sv` | 通用单口 Multi-Bank 1RW 同步 SRAM 封装（1 预测读 + 1 提交写 + `HOLD_RD0` + 可选 `clr_rd` / `rst_wr`） |
| `bpu_plru.sv` / `bpu_wrbypass.sv` | 提交期 per-set tree-PLRU 与 8 项 FF WRBypass CAM+Mem |
| `bpu_uftb.sv` | 64×4=256 项紧凑 FF uFTB（0 拍查，单写口：`upd_en` 镜像优先 > `ff_en` FastFill，后级预译码清槽） |
| `bpu_ftb_tab.sv` | 纯 1RW SRAM Main FTB（`u_ftb1`，2-Bank 1RW + 1 项 `FtbWrBuf` + 2 拍 `clr` 状态机 + 导出 `upd_new_ent_o`） |
| `bpu_ftb_ex_tage.sv` | 单套 2-Way 6 表 4-Bank 1RW 2-Ahead ExBlockTage（无 Base SRAM，`(tbl,sl,idx,way)` WRBypass，per-PC `use_alt`，双路并行 `uhi` 复位） |
| `bpu_ftb_itt.sv` | 单套 4 表 512 项 2-Bank 1RW Block-ITT（零 T0 读，无 WrBypass，3-bit `start_k` 防越界） |
| `bpu_ftb_arrays.sv` | 4 阵列容器（`u_ftb0` / `u_ftb1` / `u_ah_ex_tage` / `u_aitt`）与单口 1RW Bank 仲裁 |
| `bpu_ftb_brq.sv` | 16 项提交分支队列 + 单 Bank 512 项 1R1W `u_rec` + `FE_TRAIN_LAT=1` (`T0 → T1`) 流水寄存器 |
| `bpu_hist_vec.sv` / `bpu_spec.sv` | 256b 投机历史环 / 200b 架构移位器与投机/架构 RAS（支持 `BPU_FAST_OVR`） |
| `bpu_eval.sv` | S0（2-Ahead `ah_a1_raw_q` + `u_ftb0`）与 S2（`u_ftb1` + `self0` 并行评估、Cut A2、`fin_diff` 与元数据生成） |
| `bpu_ctl.sv` / `bpu_cmd.sv` | 3 级单块控制与历史/RAS/PC 下一拍命令（支持 `BPU_FAST_OVR=1/0`） |
| `bpu_pdq.sv` | 32 项预译码检查点 FIFO |
| `bpu.sv` | 顶层：`A0 → A1 → S0 → S1 → S2` 流水、`self0` 捕获、`u_rf_rec[256]` 与外部兼容接口 |

（已删除：`bpu_ftb_tage.sv`，以及原 `u_aftb`、`u_s2_tage`、`u_s2_itt`、`u_atage` 四组阵列。）

## 5. 关键路径与一拍内数据流分析

- **A0 → S0**：`ah_a1_raw_q` 保持已在 `A0` 读出并稳定寄存的数据；`S0` 拍用当前 `spec_ex_fh` 与 `prev_base_q` 做 2-Way tag 比较（2 路并行 `hit0/hit1` 选路，无串行循环），`u_ftb0` 64 组 × 4 路并行读出后按 `resolve_ah_dir` 选中 4 槽方向并与 `g0` 求值合并。
- **S2**：`self0_raw_q` 仅使用寄存 FF 数据，与 `u_ftb1` 同步 1RW 宏读（`CLK→Q`）及 tag 比对**并行**完成 0-Ahead 2-Way 6 表 TAGE + 4 表 ITT 选路；若 `BPU_FAST_OVR=1` 触发 `ovr`，当拍同步驱动 `u_spec` 检查点恢复、`ah_rd_en_eff` 重启 A0 并清 `r0_q`/`r1_q`/`ah_a1_raw_q`；若 Tier 1/DC 发现 `ovr → u_spec` 或 `ovr → A0` 成为瓶颈，可将 `bpu_stage_pkg::BPU_FAST_OVR` 一键切回 `1'b0` 验证 `ovr_pend_q` 解耦收益。
- **Train**：`FE_TRAIN_LAT=1` 将 `u_rec` 宏读与 `compute_commit_plan` 彻底切分到 `T0`/`T1` 两拍，避免 `u_rec → WRBypass → u_ftb1/u_ah_ex_tage` 跨宏长路径。

## 6. 面积与综合实测结果

在 `eda` 集群上使用 `main` 合入的 `EXP-071` 四层快速 PPA 工具链（`fast_ppa.sh`，TSMC 28nm HPC+ LVT + 真实 `TEM5N28HPCPLVTA` 1RW SRAM 宏，`clk=0.65 ns`、`unc=0.05 ns`、`io=0.12 ns`）实测，并与 `main`（`6c42731`）基线同口径对比：

### 6.1 Tier 0-elab（`yosys-slang` 仅展开层次）

| 配置 / 模块 | Time(s) | Macros | MacroArea | SRAM_ns | Fallback | 宏构成 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `main` `bpu`（基线） | 4.15 | 180 | 2,019,486.8 | — | 0 | — |
| `rtl/fe-2ahead` `bpu` | 3.93 | **101** | **1,444,148.0** | 0.359 | 0 | `8× 256×64` + `6× 256×72` + `87× 512×72` |
| `main` `front_top`（基线） | 5.39 | 436 | 3,495,845.1 | — | 0 | — |
| `rtl/fe-2ahead` `front_top` | 5.12 | **357** | **2,920,506.3** | 0.359 | 0 | 同上 + `256× 64×64`（ICache） |

### 6.2 Tier 1（`Yosys + buf_high_fanout + PrimeTime` Real STA，`PT_LINK_STATUS=1`、`mem_v2=0`、`fb_bb=0`、`unmapped_std=0`）

| 模块 / 配置 | Macros | Logic+FF Area | Macro Area | Total Area (vs `main`) | `WNS_total` / `WNS_r2r` | `Fmax_T1` (vs `main`) | 关键路径与说明 |
| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| `main` `bpu`（`6c42731`） | 180 | 485,006.9 | 2,019,486.8 | 2,504,493.7 | `−1.99` / `−1.99` | `0.379 GHz` | 61 级，`2.46 ns`，`u_brq.u_rec -> u_ftb1.../A[0]` |
| **`fe-2ahead` `bpu`（`FAST_OVR=1`）** | **100** | 643,098.0 | 1,428,965.0 | **2,072,062.9 (`−17.3%`)** | **`−1.75` / `−1.75`** | **`0.417 GHz` (`+10.0%`)** | 55 级，`2.22 ns`，`FF -> u_ftb1.../A[0]`（`opt_clean` 省 1 颗 `512×72`） |
| `fe-2ahead` `bpu`（`FAST_OVR=0` 对照） | 100 | 644,553.5 | 1,428,965.0 | 2,073,518.5 (`−17.2%`) | `−1.75` / `−1.75` | `0.417 GHz` (`+10.0%`) | 55 级，`2.23 ns`，与 `FAST_OVR=1` 同路径/同 WNS |
| `main` `front_top`（`6c42731`） | 436 | 876,338.6 | 3,495,845.0 | 4,372,183.6 | `−2.64` / `−2.13` | `0.304 GHz` | 92 级，`reg2reg −2.62` 至 `u_icache.u_arr` |
| **`fe-2ahead` `front_top`（`FAST_OVR=1`）** | **356** | 1,050,453.6 | 2,905,323.2 | **3,955,776.8 (`−9.5%`)** | **`−2.59` / `−1.90`** | **`0.309 GHz` (`+1.6%`)** | 92 级，`reg2reg −2.54` 至 `u_icache.u_arr` |

- **结论**：
  1. **面积显著下降**：去掉第二套预测器（`u_aftb` / `u_s2_tage` / `u_s2_itt` / `u_atage`）后，即使 `u_ftb0` 从 `16×4` FF 扩展为 `64×4=256` 紧凑 FF（`Logic+FF` 增加约 `158k`），SRAM 宏从 `180` 颗降至 `100` 颗（`Macro Area` 减少 `590.5k`，`-29.2%`），`bpu` 总面积净降 **`-432.4k`（`-17.3%`）**，`front_top` 总面积净降 **`-416.4k`（`-9.5%`）**。
  2. **时序/主频优于 `main`**：受益于 `FE_TRAIN_LAT=1` 切断 `u_brq.u_rec -> u_ftb1` 跨宏提交长路，`bpu` Tier 1 `WNS` 从 `−1.99 ns` 改善至 `−1.75 ns`（按 `EXP-071` 标定系数 `Fmax_GT/Fmax_T1 = 1.65` 折算约 `0.688 GHz`，按 `main bpu` 比值 `1.75` 折算约 `0.729 GHz`），`front_top` 的全局 `reg->reg WNS` 由 `−2.13 ns` 改善至 `−1.90 ns`，瓶颈仍在 `u_icache.u_arr`（`satp` / data SRAM 地址多路复用），`u_bpu` 未拖慢前端主频。
  3. **`BPU_FAST_OVR=1` 无时序/面积惩罚**：`FAST_OVR=1` 与 `FAST_OVR=0` A/B 对照的 `WNS` 完全一致（均为 `−1.75 ns`、55 级至 `u_ftb1.../A[0]`），可无额外代价保留 0 气泡 fast-override（少 1 拍 `ovr_pend` 气泡）。

## 7. 与模型的差异

- `u_ftb0` 内部按 20-bit 槽压缩目标存储（`141b/项`），仅镜像 `ftb_s0_tgt_fits`（`±1 MB`）或 `BR_RET`；C++ 模型 `FtbTab` 保留全宽 `target` 字段。经 77 程序 `fm_gate.sh` 实测，功能与周期全部 0 差异。
- `BPU_FAST_OVR` 编译期由 `bpu_stage_pkg::BPU_FAST_OVR` 控制（默认 `1'b1`）；与 `trace-model-fe-2ahead` 在 `FE_PRED_ARCH=2 FE_AH_MODE=3 FE_BPU_S3=0 FE_FAST_OVR=1 FE_UFTB_N=256 FE_AH_CUR_TAG=1 FE_AH_SELF0=1 FE_AH_WAYS=2 FE_AH_SEC_TAG=1 FE_UFTB_FAST_FILL=1 FE_ITT_CFG=1 FE_TRAIN_LAT=1` 下 77 程序逐拍完全等价。

## 8. 验证状态

- **静态检查与编码规范**：
  - `python3 harness/tools/svlint.py rtl/frontend/bpu/*.sv`：`0` errors。
  - `bash scripts/lint.sh rtl/frontend/bpu`：`lint ok (19 files, 1 dirs)`。
  - `bash scripts/lint_chip.sh`：`lint_chip: 0 warnings/errors (build/lint_chip.txt)`。
- **架构与逐拍等价门禁（对齐 `trace-model-fe-2ahead`）**：
  - `SOC_FM=1` 编译 `core_tb` 后运行 `REF_CYCLES=/tmp/ref_fe2ah.txt JOBS=12 bash scripts/fm_gate.sh`：**`PASS 77 FAIL 0 SKIP 0`**，`cycles different from ref_cycles.txt: 0`。
- **综合与时序验证（`eda` 集群）**：
  - `Tier 0-elab`（`eda-06`，`mode=real`）：`bpu` `101` macros、`front_top` `357` macros，`Fallback=0`。
  - `Tier 1`（`eda-06`/`eda-07`，`clk=0.65 ns`、`mode=real`）：`t1_bpu_fovr1`、`t1_bpu_fovr0`、`t1_ft` 三组均 `PT_LINK_STATUS=1`、`mem_v2=0`、`fb_bb=0`、`unmapped_std=0`（产物位于 NFS `/nfs_global/S/houruyao/fe2ah_ppa_out/`）。

## 9. 风险与待办

- 后续若需确认精准 DC `compile_ultra` 签核面积与频率（含线负载与多级地址树拆分对 `u_ftb1.../A[0]` `0.97 ns` 末级扇出的收敛效果），可进一步在 `eda` 集群跑 `Tier 2a`/`Tier 3` 综合及 Linux 26 窗 / SPEC06 全量评估。
- `rtl` 根目录 `bpu_sv` 与 `trace-model-fe-2ahead` 暂保留独立分支/worktree，待性能与签核达标后再决定合入策略（当前按规则未执行 `git commit`/`push`）。

## 10. 变更记录

- 2026-11-28（`rtl/fe-2ahead`）：基于 `main`（`6c42731` Clean BPU v11 + EXP-071 快速 PPA 工具链）重构为 **Pure Single-Set Unified 2-Ahead BPU**，修复 `bpu.sv` `u_spec.issue` 在 `BPU_FAST_OVR=1` 下的 override 门控后通过 `lint`/`lint_chip`/77 程序 `fm_gate`（0 周期差），并在 `eda` 集群完成 `Tier 0-elab` 与 `Tier 1` 实测（含 `BPU_FAST_OVR=0` A/B 对照与 `front_top` 整前端综合）。
