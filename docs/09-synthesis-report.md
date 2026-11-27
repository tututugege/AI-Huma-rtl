# 09 综合报告（TSMC 28nm HPC+ Synopsys DC 权威签核 + Yosys 快速代理）

> 早期 Yosys 通用门历史记录（§1–14，2026-11-05 ~ 11-21）已归档至 [archive/09-synthesis-report-yosys-history.md](archive/09-synthesis-report-yosys-history.md)。
> - **权威工艺签核**：Synopsys DC `W-2024.09-SP2` + TSMC 28nm HPC+（`ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50ns / 2.0GHz`, `compile_ultra`）。
> - **分钟级快速代理**：`eda-04`~`10` 上 Yosys + `yosys-slang`（`SYNTH_ABC="strash;balance;map"`，大存储加 `SYNTH_NO_MEMPRIO=1`，脚本见 [../scripts/synth_depth.sh](../scripts/synth_depth.sh)）。

## 15. TSMC 28nm HPC+ Synopsys DC 时序基线与第一轮优化（EXP-062，2026-11-24）

### 15.1 工艺库与约束口径（权威签核标准）

从本阶段起，以 **Synopsys Design Compiler (`W-2024.09-SP2`) + TSMC 28nm HPC+ 标准单元库** 作为权威时序签核口径，Yosys（`SYNTH_ABC="strash;balance;map"`）仅作分钟级快速迭代代理：
- **工艺角与标准单元库**：`tcbn28hpcplusbwp12t40p140ssg0p81v125c.db`（12T SVT, worst-case `0.81V / 125°C`）+ `tcbn28hpcplusbwp12t40p140lvtssg0p81v125c.db`（12T LVT）
- **时序约束**：`CLK = 0.50 ns`（目标 `2.0 GHz`），`clock_uncertainty = 0.03 ns`，`input_delay = output_delay = 0.05 ns`，`compile_ultra`
- **脚本存档**：`/nfs_global/S/houruyao/dc28_check/{run_dc.sh, list_files.py}`（`list_files.py` 按 `::` 引用做包拓扑排序，解决 DC 按字母顺序读包失败）；同步修复 `div_core.sv` 与 `bpu_spec.sv` 两处 DC Presto 函数返回值直接切片语法。

### 15.2 全核主要模块 TSMC 28nm DC 时序基线（优化前，22 模块）

| 模块 | WNS (ns) | 估算 Fmax (GHz) | 逻辑级数 (lvl) | Cell Area (um²) | 关键路径 / 状态 |
|---|---:|---:|---:|---:|---|
| **`dcache_pf`** | **−2.23** | **0.37** | **172** | 184,092 | **#1 瓶颈**：`berti_tab` 串行 16 项 `pick_slot` + 同拍 `srch → trig` 旁路 + `berti_hist` 三级 CAM 旁路 |
| **`bpu_spec`** | **−0.87** | **0.73** | **69** | 154,490 | **#2 瓶颈**：8 宽串行 `ras_push/pop` + `arch_q` 1024b 环形桶形移位 + `aras_q → st_q` 拷贝 |
| **`lsu`** | **−0.71** | **0.83** | **55** | 829,493 | **#3 瓶颈（第二轮）**：`u_rp/rp_ldq_q → u_l1b/pl12_q[cand]`、`sta_info_q → u_ldq/f_q[rwait]` |
| **`bpu_eval`** | **−0.69** | **0.84** | **69** | 25,652 | **#4 瓶颈（第二轮）**：S2 双块校验与选择链 |
| **`ren`** | **−0.45** | **1.05** | **49** | 144,202 | **#5 瓶颈**：`ren_log` 32:1+8:1 mux → commit freelist；第二轮考虑两级流水冲 1.5+ GHz |
| **`axi_llc_bop`** | **−0.45** | **1.05** | **51** | 45,272 | **#5 瓶颈**：26 项串行最大分数链 + `rr_tag_q` (256:1 mux) 串行候选/去重检查 |
| **`dcache_mshr`** | **−0.37** | **1.15** | **54** | 99,463 | 8 级串行 `ttg_first_set` 分配链（Yosys 123 层） |
| `isu` | −0.23 | 1.37 | 28 | 608,221 | 健康（单周期整数选择-唤醒环） |
| `dcache_wb` | −0.17 | 1.49 | 34 | 80,778 | 健康 |
| `idu` | −0.15 | 1.54 | 35 | 18,196 | 健康 |
| `rob` | −0.11 | 1.64 | 35 | 521,086 | 健康 |
| `div_unit` | −0.10 | 1.67 | 37 | 11,016 | 健康（Radix-16 双 Radix-4） |
| `pre_idu_queue` | −0.05 | 1.82 | 20 | 1,684,992 | 健康（面积含寄存器化 ibuf，后续可换 SRAM） |
| `mul_unit` | −0.04 | 1.85 | 21 | 40,926 | 健康（Radix-4 Booth） |
| `dispatch` | −0.03 | 1.89 | 25 | 77,718 | 健康 |
| `tlb_mmu` | −0.03 | 1.89 | 25 | 57,685 | 健康 |
| `dcache_s1` | 0.00 | ≥2.00 | 17 | 14,592 | 满 2.0 GHz |
| `dcache_s2_ld` | 0.00 | ≥2.00 | 21 | 1,720 | 满 2.0 GHz |
| `dcache_s2_st` | 0.00 | ≥2.00 | 21 | 398 | 满 2.0 GHz |
| `icache_ctl` | 0.00 | ≥2.00 | 12 | 7,452 | 满 2.0 GHz |
| `icache_itlb` | 0.00 | ≥2.00 | 20 | 46,683 | 满 2.0 GHz |
| `bpu_ctl` | +0.10 | ≥2.50 | 13 | 595 | 满 2.0 GHz |

> 注：`exu_ctrl` 触发 DC 内部断言 `(VER-37)`（`exu_ctrl_pkg.sv:205`），待第二轮单独定位。

### 15.3 第一轮时序优化结果（EXP-062，5 模块优化前后 DC 28nm & Yosys 对比）

| 模块 | DC WNS (ns) 改前 → 改后 | DC Fmax (GHz) 改前 → 改后 | DC 逻辑级数 | DC Area (um²) | Yosys 深度代理 | 关键改动 |
|---|---|---|---:|---:|---:|---|
| **`dcache_pf`** | **−2.23 → −0.35** | **0.37 → 1.18 (+3.19×)** | **172 → 53** | **184,092 → 147,594 (−19.8%)** | **384 → 75 (−80.5%)** | 4 级流水化（`hist → srch_r_q → tab_s1 → t1_q → tab_s2 → gen`）+ 4 级并行 Top-2 锦标赛树 + 去 `srch→trig` 与 `pfi_en→fill→pf_hit` 同拍旁路；`trace-model` 同步，**SPEC06 INT 386 点反涨 `+0.51%`** |
| **`axi_llc_bop`** | **−0.45 → −0.18** | **1.05 → 1.47 (+1.40×)** | **51 → 42** | 45,272 → 46,209 | **291 → 75 (−74.2%)** | 5 级二进制最大分数树 + 3 路候选地址/去重与 `rr_tag_q` (256:1 mux) 并行预计算（0 周期变化） |
| **`bpu_spec`** | **−0.87 → −0.66** | **0.73 → 0.86 (+1.18×)** | **69 → 41** | 154,490 → 156,084 | — | 3 级 Kogge-Stone 钳位前缀并行 RAS + 128-bit 线性移位寄存器 `arch_sr_q` 替代 1024b 环形 `arch_q` 消除 `M_ARCH` 桶形移位器（0 周期变化；余下路径为 `aras_q[cnt] → st_q`） |
| **`ren`** | **−0.45 → −0.36** | **1.05 → 1.16 (+1.10×)** | **49 → 48** | 144,202 → 144,365 | 91 | `ren_ckpt_ctl` 提前输出 `rd_base_next`，`ren_log` 在 `T-1` 拍预寄存 8 项读窗 `rd_slot_q[0..7]` 移出提交→空闲表关键路径（0 周期变化） |
| **`dcache_mshr`** | −0.37 → −0.37（reg2reg −0.35） | 1.15 → 1.15（reg2reg 1.18） | 54 | 99,463 | **123 → 99 (<100)** | `dcache_mshr_alloc` 8 级串行 `ttg_first_set` 改 `ttg_pick_k(16,8)` + 并行 `ttg_popcount`（0 周期变化，跌破 Yosys 100 层红线） |

## 16. 第二轮 TSMC 28nm HPC+ DC 时序优化（EXP-063，2026-11-24）

同口径 Synopsys DC (`W-2024.09-SP2`, TSMC 28nm HPC+ `ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`) 攻克 `bpu_eval`、`bpu_spec`、`lsu` 并修复 `exu_ctrl` DC `(VER-37)` 补齐全部 23/23 核心模块实测数据：

| 模块 | DC WNS (ns) 改前 → 改后 | DC Fmax (GHz) 改前 → 改后 | 纯组合延迟 / reg2reg | DC 逻辑级数 | DC Area (um²) | 关键改动 |
|---|---|---|---|---:|---:|---|
| **`exu_ctrl`** | `(VER-37)` → **0.00** | **MET ≥2.00 GHz** | — | **13** | 31,761 | 修复 `exu_ctrl_pkg.sv` `xc_is_fp_kind` 返回 `int` 消除 DC Presto `(VER-37)` 断言，全核 23/23 模块数据补齐 |
| **`bpu_eval`** | **−0.69 → −0.28** | **0.84 → 1.28 (+52.4%)** | **0.68 ns (1.47 GHz)** | **69 → 49** | **25,652 → 23,911 (−6.8%)** | 2-Ahead B 改为以 `(key_base, s0_base)` 索引与 Block A 完全并行评估（`bpu_ftb_tab` 增 `STORE_B_BASE=1` 存 `b_base`、去掉串行 `u0_b` 回退、`bpu_eval` 并行 `ttg_first_set` 选路与 6-bit 快速 `s0_b_bnd`）；同步 `trace-model`（SPEC06 INT 386 点 `−1.20%`） |
| **`bpu_spec`** | **−0.66 → −0.33** | **0.86 → 1.20 (+39.5%)** | **0.70 ns (1.43 GHz)** / reg2reg **−0.32 ns (1.22 GHz)** | 52 | **156,084 → 142,200 (−8.9%)** | `M_ARCH` 重定向改为直接从寄存态 `arch_sr_q / arch_fh_q / aras_q` 恢复，彻底切断 `commit br_type[0..7] → aras_d → spec_a_ras_top` 关键路径；同步 `trace-model`（`~0.00%` IPC） |
| **`lsu`** | **−0.71 → −0.64** | **0.83 → 0.88 (+6.0%)** | 1.06 ns / reg2reg −0.64 ns | 56 | **927,154 → 918,551 (−0.9%)** | 0 周期变化：`lp_cam` 用代数恒等式 `mask_unrot & rotr64(raw, head)` 与常量比较 `i < older` 消除 2 个 64-bit 桶形移位器；`lp_wk` 3 路 `stlf_confirm` 与 `sta_info[k].stq == blk` 并行预计算（余下关键路径 `rp_ldq_q → lp_cam → req_id` 与 `lp_ldq_ent` P1..P14 链留待第三轮流水切分） |

### 16.1 第二轮后全核 23 模块 TSMC 28nm DC 时序分布总览

- **≥ 1.50 GHz（11 模块）**：`bpu_ctl` (≥2.50)、`exu_ctrl` / `dcache_s1` / `dcache_s2_ld` / `dcache_s2_st` / `icache_ctl` / `icache_itlb` (≥2.00)、`dispatch` / `tlb_mmu` (1.89)、`mul_unit` (1.85)、`pre_idu_queue` (1.82)、`div_unit` (1.67)、`rob` (1.64)、`idu` (1.54)（实际 14 模块 ≥ 1.54 GHz）。
- **1.15 ~ 1.49 GHz（7 模块，接近 1.5 GHz 门槛）**：`dcache_wb` (1.49)、`axi_llc_bop` (1.47)、`isu` (1.37)、**`bpu_eval` (1.28，纯组合 1.47)**、**`bpu_spec` (1.20，纯组合 1.43)**、`dcache_pf` (1.18)、`ren` (1.16)、`dcache_mshr` (1.15 / reg2reg 1.18)（8 模块）。
- **< 1.00 GHz（仅剩 1 模块）**：`lsu` (0.88 GHz) —— 第三轮聚焦 `lsu` 流水切分与 `ren` 两级重命名向全核 1.5 GHz 冲刺。

## 17. 第三轮 TSMC 28nm HPC+ DC 时序优化（EXP-064，2026-11-24）

同口径 Synopsys DC (`W-2024.09-SP2`, TSMC 28nm HPC+ `ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`) 推进 `dcache_pf`、`dcache_mshr`、`lsu`（Wave 1+2，均 0 周期变化）与 `ren` 2-stage 流水化：

| 模块 | DC WNS (ns) 改前 → 改后 | DC Fmax (GHz) 改前 → 改后 | 纯组合延迟 / reg2reg | DC 逻辑级数 | DC Area (um²) | 关键改动 |
|---|---|---|---|---:|---:|---|
| **`dcache_pf`** | **−0.35 → −0.24** | **1.18 → 1.35 (+14.4%)** | **0.70 ns (1.43 GHz)** | **53 → 43** | 151,660 | 0 周期变化：`dcache_pf_berti_gen` 16→1 锦标赛树 `gen_cand_t` 随路携带 `d`(7b)+`st`(2b)，并行预计算 `gen_vline_q[31:6] ± 1` 与 `xq_va_q` 27b 页标签比较，7b 有符号加法+6b 去重替代 32b 加法器 |
| **`dcache_mshr`** | **−0.37 → −0.28** | **1.15 → 1.28 (+11.3%)** | **0.65 ns (1.54 GHz)** / reg2reg **−0.27 ns (1.30 GHz)** | **54 → 41** | **99,463 → 85,657 (−13.9%)** | 0 周期变化：并行一次性预展开 3 路 store 512b 行数据与 64b 字节选通（替代 16× `line_merge_n`）；`ax_req_*` 改并行 demand/all `ttg_first_set` + `ttg_onehot_mux` |
| **`ren` (`ren_2s`)** | **−0.36 → −0.32** | **1.16 → 1.22 (+5.2%)** | 0.79 ns / reg2reg −0.32 ns（TNS −5,375） | **46 → 40** | 144,365 → 157,570 | 2 级流水化（`IDU → S1 → S2 → DISPATCH`，S1 预译码 RAT one-hot 地址与同组 RAW/WAW 矩阵）+ `ren_ckpt_ctl` 静态槽位预计算 + `ren_log` 8:1 旋转后移至 `bank_rd_q` 之后 + `ren_alloc_sel` 直接前缀 `ttg_popcount`；同步 `trace-model`（SPEC06 INT 386 点 `−1.07%`）；新顶路径仍在 S2（`ckpt_count_q → u_ckpt` 0.79 ns 与 `rd_oh_q → ren_elim_sel → u_rat` 0.78 ns），第四轮重平衡 S1/S2 切点 |
| **`lsu` (Wave 1+2)** | **−0.64 → −0.53** | **0.88 → 0.97 (+10.2%)** | 0.98 ns (1.02 GHz) / TNS **−15.7k → −10.6k (−32.6%)** | 56 → 59 | **918,551 → 873,552 (−4.9%)** | 0 周期变化：`lp_pickn` 全切 `ttg_pick_k`；`lp_cam` 未旋转 `hi/lo` 拆分消 2× `rotr64` 与 `+ head`；`lp_rp` 预寄存 `rp_f_q[0..3]` 消 64:1 LDQ mux 并切断 `epoch_nx → dcl_req_id`；`lp_pkg` `rel12/rel32` 8B 块拆分；`lp_wb` `alive_unrot(count_q) & rotr64` 消 `sta_*` 瓶颈；新顶路径为 `ldq/st_q → lp_l1 → lp_cam → ldq/f_q[spec]`（0.98 ns），第四轮通过 `L0/L1` 流水拆拍攻克 |

### 17.1 第三轮后全核 23 模块 TSMC 28nm DC 时序分布总览

- **≥ 1.50 GHz（14 模块）**：`bpu_ctl` (≥2.50)、`exu_ctrl` / `dcache_s1` / `dcache_s2_ld` / `dcache_s2_st` / `icache_ctl` / `icache_itlb` (≥2.00)、`dispatch` / `tlb_mmu` (1.89)、`mul_unit` (1.85)、`pre_idu_queue` (1.82)、`div_unit` (1.67)、`rob` (1.64)、`idu` (1.54)。
- **1.20 ~ 1.49 GHz（8 模块）**：`dcache_wb` (1.49)、`axi_llc_bop` (1.47)、`isu` (1.37)、**`dcache_pf` (1.35，纯组合 1.43)**、**`dcache_mshr` (1.28，reg2reg 1.30，纯组合 1.54)**、`bpu_eval` (1.28，纯组合 1.47)、**`ren` (1.22)**、`bpu_spec` (1.20，纯组合 1.43)。
- **< 1.20 GHz（仅剩 1 模块）**：**`lsu` (0.97 GHz)** —— 22/23 模块已全部 ≥ 1.20 GHz（20/23 ≥ 1.28 GHz），第四轮聚焦 `lsu` `L0/L1` 流水拆拍与 `ren` S1/S2 切点重平衡。

## 18. 第四轮 TSMC 28nm HPC+ DC 时序优化（EXP-065，2026-11-25）

同口径 Synopsys DC (`W-2024.09-SP2`, TSMC 28nm HPC+ `ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`) 主攻 `ren` S1/S2 重平衡与 `lsu` 并行 CAM + Bloom Filter + L2a/L2b 拆拍 + 零 29-bit 加法器 + `lp_wbuf` 拍平：

| 模块 | DC WNS (ns) 改前 → 改后 | DC Fmax (GHz) 改前 → 改后 | 纯组合延迟 / TNS | DC 逻辑级数 | DC Area (um²) | 关键改动 |
|---|---|---|---|---:|---:|---|
| **`ren`** | **−0.32 → −0.10** | **1.22 → 1.67 (+36.9%)** | TNS **−5,375 → −1,330 (−75.3%)** | **40 → 26 (−35%)** | **157,570 → 156,632 (−0.6%)** | 取消 `MOVE_ELIM_MAX_REFS=7` 上限（`CNT_W=6` 永不溢出），删 `ren_elim_sel` 264×8b 比较器与 8×33b popcount 改复用 S1 `raw_hit_src1_q` + 3 级 Kogge-Stone 指针跳跃；`ren_rat`/`ren_core`/`ren_fp` 检查点写流水化 1 拍（0 周期变化）；`ren_arch_cnt` 简化归零判定 + 1 拍寄存 INT 空闲表回收（同步 `trace-model`） |
| **`lsu`** | **−0.53 → −0.39** | **0.97 → 1.12 (+15.5%)**（较 R1 0.83 GHz **+34.9%**） | **0.85 ns (1.18 GHz)** / TNS **−10,579 → −8,988 (−15.2%)** | **56 → 49 (−12.5%)** | **873,552 → 840,182 (−3.8%)**（较 R1 −9.4%） | `lp_unc` 寄存 `mmio_out`；`stq_cam` 后移至 L2a 与 D-Cache 响应并行 + 256-bit 寄存 `stq_bloom_q`（`vaddr[10:3]`）防 `456.hmmer` STQ 排空饥饿；L2 拆 **L2a**（快路径+CAM）与 **L2b**（仅 ~7% STLF 命中打 1 拍 `PL2B`）；切断 `rs_busy→res_v→lp_wb` 假路径；FF 前一次性预计算 `paddr[31:3] ± 1` 消除 ~700 份 29-bit 加法器；`lp_wbuf` 零周期变化拍平取代 4 级串行 `lp_wbstep`（SPEC06 INT 386/386 合计 `−0.802%`） |

### 18.1 第四轮后全核 23 模块 TSMC 28nm DC 时序分布总览

- **≥ 1.50 GHz（15 模块）**：`bpu_ctl` (≥2.50)、`exu_ctrl` / `dcache_s1` / `dcache_s2_ld` / `dcache_s2_st` / `icache_ctl` / `icache_itlb` (≥2.00)、`dispatch` / `tlb_mmu` (1.89)、`mul_unit` (1.85)、`pre_idu_queue` (1.82)、**`ren` (1.67)**、`div_unit` (1.67)、`rob` (1.64)、`idu` (1.54)。
- **1.20 ~ 1.49 GHz（7 模块）**：`dcache_wb` (1.49)、`axi_llc_bop` (1.47)、`isu` (1.37)、`dcache_pf` (1.35，纯组合 1.43)、`dcache_mshr` (1.28，reg2reg 1.30，纯组合 1.54)、`bpu_eval` (1.28，纯组合 1.47)、`bpu_spec` (1.20，纯组合 1.43)。
- **1.12 ~ 1.19 GHz（仅剩 1 模块）**：**`lsu` (1.12 GHz，纯组合 1.18 GHz)** —— 全核 23/23 模块全部站上 **≥ 1.12 GHz**（22/23 ≥ 1.20 GHz，15/23 ≥ 1.54 GHz），`lsu` 残余 Top 10 齐平在 `−0.39 ns`（`u_ldq/f_q[blk] → f_q[result]` STLF 数据合并与 `dec_bcast_br_mask → u_rp/u_ldq`）。

## 19. 方案 C（9-bit `rob_ptr` 循环年龄冲刷 + `IQ_BR=64`）TSMC 28nm HPC+ DC 综合结果（EXP-068，2026-11-25）

同口径 Synopsys DC (`W-2024.09-SP2`, TSMC 28nm HPC+ `ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`) 评估全后端删除 32-bit `br_mask`/`clear_mask`/`br_id` 改用 9-bit `{rob_flag, rob_idx}` 循环年龄冲刷并将 `IQ_BR_SIZE` 由 32 扩至 64 后的受影响核心后端模块：

| 模块 | DC WNS (ns) 改前 → 改后 | DC Fmax (GHz) 改前 → 改后 | 纯组合延迟 / TNS | DC 逻辑级数 | DC Area (um²) | 关键变化 |
|---|---|---|---|---:|---:|---|
| **`idu`** | **−0.15 → 0.00 (MET)** | **1.54 → 2.70 (+75.3%)** | **0.37 ns** / TNS **0** | **35 → 14 (−60.0%)** | **18,196 → 1,994 (−89.0%)** | 删除 5 个分支标签子模块（`idu_br_alloc/group/state/cp`、`idu_fire_ctl`），面积缩小 **9.1×**、完全 MET（Yosys `66 → 19` 层、`31,607 → 6,595` cells） |
| **`isu`** | **−0.23 → −0.23** | **1.37 → 1.37 (持平)** | **0.64 ns** / TNS `−5,096` | 41 | **608,221 → 598,408 (−1.6%)** | 尽管 `IQ_BR_SIZE` 翻倍（32 → 64），全 6 个发射队列删除 32-bit `br_mask` 后面积仍净降 **9.8k um²**、频率零回退 |
| **`lsu`** | **−0.39 → −0.39** | **1.12 → 1.12 (持平)** | **0.84 ns (1.19 GHz)** / TNS **−8,988 → −7,496 (−16.6%)** | **49 → 43 (−12.2%)** | **840,182 → 758,236 (−9.8%)** | 消除 `dec_bcast_br_mask → u_rp/u_ldq` 广播与 LDQ/STQ/LR-SC 全部 `br_mask` 位，面积净省 **81.9k um²**、TNS 降 **16.6%**、频率零回退 |

- **三模块合计后端面积净省 `107,960 um²`**，全核 23 模块中 **≥ 2.00 GHz 模块由 7 个增至 8 个**（新增 `idu` 2.70 GHz），全核短板频率维持 `1.12 GHz` 零回退。

## 20. `rtl/area-opt` 代码精简 + 全显式严格同步 SRAM 化（`SRAM_BLACKBOX`）TSMC 28nm HPC+ DC 综合结果（2026-11-26）

同口径 Synopsys DC（`W-2024.09-SP2`, TSMC 28nm HPC+ `ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`），对全核存储阵列完成 **100% 严格同步 1R1W/1RW SRAM 化**（彻底删除组合读 `ttg_sram_rf.sv` 与 `bpu_mem.sv`，全部挂接 `ttg_sram_1r1w` / `ttg_sram_1rw` 并支持 `-DSRAM_BLACKBOX`）及 5 项代码/结构体/开关精简后，对全部核心模块与首次可综合的大型存储子系统进行实测签核：

> **口径说明**：带 `_bb` 后缀的模块启用 `-DSRAM_BLACKBOX`，每个 `ttg_sram_1r1w` / `ttg_sram_1rw` 实例综合为单字输出寄存 stub（`rdata_bb_reg`）以反映外围逻辑 + 寄存器面积（不含实际 SRAM 宏单元面积）；其余模块（`isu` / `lsu` / `bpu_spec`）为 100% 完整标准单元综合。

| 模块 | DC WNS (ns) 改前 → 改后 | DC Fmax (GHz) 改前 → 改后 | reg2reg / 级数 / TNS | DC Area (um²) 改前 → 改后 | 关键改动与分析 |
|---|---|---|---|---:|---|
| **`rob` (`rob_bb`)** | −0.11 → **−0.15** | 1.64 → **1.54** | reg2reg −0.15 / 42 lvl / TNS −452 | **521,086 → 121,413 (−76.7%)** | 删除冗余字段，指令字改 8×`32×32b`（1 KiB）严格同步 `ttg_sram_1r1w`（`ROB_INST_WORD`）；29 级串行 `oldest_trap` 改 3 级并行锦标赛树将 WNS 由 −0.95 ns 拉回 −0.15 ns，净省 **399.7k um²** |
| **`ftq_ibuf` (`ftq_ibuf_bb`)** | −0.05 → **−0.13** | 1.82 → **1.59（reg2reg 1.72）** | reg2reg **−0.08** / 24 lvl / TNS −2,486 | **1,684,992 → 243,191 (−85.6%)** | 替代原 `pre_idu_queue`；精简指令缓冲与 FTQ 元数据结构，面积缩小 **6.9×**、净省 **1,441.8k um²** |
| **`isu`** | −0.23 → **−0.23（持平）** | 1.37 → **1.37（持平）** | reg2reg **−0.23** / **41 → 28 lvl** / TNS **−5,096 → −3,852 (−24.4%)** | **598,408 → 467,899 (−21.8%)** | 删除固化开关与无用字段 + 统一 `IQ_*` 枚举，较 EXP-068 再省 **130.5k um²**（较初始基线 −23.1%），级数降 13 级、时序零回退 |
| **`lsu`** | −0.39 → **−0.39（持平）** | 1.12 → **1.12（持平）** | reg2reg −0.39 / 44 lvl / TNS −7,525 | 758,236 → 767,221 (+1.2%) | 删 5 根死线，时序与 EXP-068 零回退（较 R1 面积 −17.3%） |
| **`tlb_mmu` (`tlb_mmu_bb`)** | −0.03 → **−0.03（持平）** | 1.89 → **1.89（持平）** | reg2reg −0.03 / 25 lvl / TNS −104 | 57,685 → **57,685 (0.0%)** | 64 项全相联 L1 TLB，面积与时序完全零回退 |
| **`ptw_walk_l2tlb` (`_bb`)** | 首次签核 | **MET ≥ 2.00（2.70）** | reg2reg **0.00 (MET)** / 19 lvl / TNS **0** | **23,485** | 1024 项 4 路 L2 STLB 改为显式 `ttg_sram_1rw`（`L2TLB_4K`），外围逻辑仅 23.5k um²、满 2.0 GHz MET |
| **`icache` (`icache_bb_v2`)** | 首次整模块签核 | 0.69（`u_fdip` 顶路径） | reg2reg −0.94 / 86 lvl / TNS −28,216 | **248,709** | 32 KiB 数据体（4×8×`16×512b`）改为严格同步 1R1W SRAM（`ICACHE_DATA`），`icache_ctl` 仅 7,480 um²（3.0%）；顶路径位于 `u_ctl → u_fdip/q_va_q` |
| **`dcache` (`dcache_bb`)** | 首次整模块签核 | 0.94（`u_pf/u_tab`） | reg2reg −0.55 / 62 lvl / TNS −33,792 | **866,611** | 64 KiB Tag/Data 改为严格同步 1R1W SRAM（`DCACHE_TAG`/`DCACHE_DATA`），整模块含 `mshr` + Berti `pf` + `wb` + `s1/s2` 首次全综合 |
| **`axi_llc` (`axi_llc_bb`)** | 首次整模块签核 | 0.75（`victim → bingo`） | reg2reg −0.84 / 82 lvl / TNS −45,246 | **644,526** | 4 MiB LLC 数据/标签/状态/替换（6 组 `ttg_sram_1r1w`）+ Bingo PHTL/S（`ttg_sram_1rw`）全部黑盒化，4 MiB LLC 首次在 DC 内可完整签核 |
| **`bpu_spec`** | −0.33 → **−0.34** | 1.20 → **1.20（reg2reg）** | reg2reg **−0.33** / **52 → 48 lvl** / TNS −2,485 | 142,200 → 191,790 | 保持 1.20 GHz reg2reg 时序零回退 |
| **`bpu` (`bpu_bb_p`)** | 首次整模块签核 | 0.53（S2 TAGE → `u_spec`） | reg2reg −1.40 / 119 lvl / TNS −154,380 | **941,477** | ~590 KiB 全部预测表（`u_ftb1`/`aftb`/`aftb2`/`atage`/`atage2`/`s2_tage`/`s2_sc`/`s2_itt`/`aitt`/`aitt2`/`u_rec`/`u_rf_rec`）100% 改为严格同步 `ttg_sram_1r1w`；仅保留 S0 小表 `u_ftb0`（64×4 FF）占 **418,532 um²（44.5%）**，其余全部 BPU 控制/评估/训练逻辑合计仅 `522.9k um²` |

- **可比后端核心模块面积净省**：仅 `rob`（−399.7k）+ `ftq_ibuf`（−1,441.8k）+ `isu`（−130.5k）三模块合计净省 **`1,972,000 um²`（~1.97 mm²）**，且 `lsu` / `isu` / `tlb_mmu` / `bpu_spec` 频率全部零回退。
- **全核大型存储模块首次全部具备 DC 28nm 签核能力**：`icache`（32 KiB）、`dcache`（64 KiB）、`axi_llc`（4 MiB）、`ptw_walk_l2tlb`（1024 项 STLB）、`bpu`（~590 KiB）及 `rob`（1 KiB 指令字）100% 显式接入 `ttg_sram_1r1w` / `ttg_sram_1rw`，零组合读 RAM 残留。
- **综合暴露的后续优化抓手**：① `bpu` 内 `u_ftb0`（64×4 FF）占全 BPU 面积 44.5% 且 S2 TAGE → `u_spec` 组合链达 `1.85 ns`；② `icache` 顶路径在 `u_fdip`；③ 后续结合 `front_top` 去 `ptab_bypass`（SPEC386 仅 −0.03%）与 `back_top` DTLB/LSU 解耦（0 周期变化）可进一步大幅拉升整核频率。

## 21. EXP-070（Unified FTQ-64 + LSU/DTLB 切链 + Clean BPU v11 零黑盒真实 TSMC 28nm SRAM）DC 综合结果（2026-11-27）

同工艺库 Synopsys DC（`W-2024.09-SP2`, TSMC 28nm HPC+ `ssg0p81v125c`, 12T SVT+LVT, `compile_ultra -no_autoungroup`），**前端 `bpu` / `front_top` 全面禁用 `SRAM_BLACKBOX`，改为 `-define {SYNTHESIS SYNTH_TSMC28_SRAM}` 映射真实 TSMC 28nm SRAM 宏（`tem5n28hpcplvta*`）综合出真实时序与面积**；后端子系统沿用 `0.50 ns` 黑盒对照验证切链收益：

| 模块 / 版本 | SRAM 口径 / 时钟 | DC WNS (ns) | 估算 Fmax | 逻辑级数 / TNS | 总面积 (µm²)（逻辑+FF / 真实 SRAM 宏） | 关键路径与结论 |
|---|---|---:|---|---|---:|---|
| **`bpu` (`bpu_v11_065ns`)** | 真实 TSMC28 宏 / `0.65 ns` | `−0.58` | `813 MHz` | `58 lvl` / `−27,002` | `2,076,194`（`386.0k` / `1,690.2k` · **156 宏**） | Clean BPU v11（1RW 8-bank、去 SC 与旧 2-Ahead B），顶路径 `u_s2_tage → u_atage`（`arrival 1.11 ns`） |
| **`bpu` (`bpu_v11_a1a2_065ns`)** | 真实 TSMC28 宏 / `0.65 ns` | **`−0.49`** | **`877 MHz`**（**+83%** vs `v10.1` `478 MHz`） | **`47 lvl` / `−21,929` (−18.8%)** | **`2,075,545`**（`254.5k` 组合 + `130.9k` 非组合 = **`385.4k` −59.1%** / `1,690.2k` · **156 宏**，`50,913` FFs） | 叠加 A1/A2 切断 `s2_tage → atage`，新顶路径 `u_ftb1` 真实宏 → `u_spec/st_q`（`arrival 1.09 ns`） |
| **`front_top` (`front_top_v11_opt_065ns`)** | 真实 TSMC28 宏 / `0.65 ns` | `−0.87`（收尾中） | `~658 MHz`（vs 改前 `−1.57 ns`） | 持续收敛 | `~4,230,674`（含 BPU + ICache 全量真实 SRAM 宏） | 叠加 Unified FTQ 删 `ptab_bypass` + Clean BPU v11 + 同页双取 + A1/A2/B1，零黑盒全前端综合；待 `eda-06` `qor.rpt` 落盘后更新终值 |
| **`back_top_bb`** | `SRAM_BLACKBOX` / `0.50 ns` | `−0.70` | `833 MHz`（`arrival 1.16 ns`） | `62 lvl` / `−71,543` | `2,572,725`（`2,154.2k` 组合 + `418.6k` 非组合，`159,559` FFs） | 彻底消除 EXU/LSU ↔ DTLB `1.24 ns (780 MHz)` 同拍往返链；新顶路径为 `u_lsu/u_ldq → u_isu/g_iq[5]`（`1.16 ns`） |
| **`ftq_ibuf_bb`** | `SRAM_BLACKBOX` / `0.50 ns` | `−0.15` | `1.54 GHz`（reg2reg `1.56 GHz`） | `32 lvl` / `−749` | `239,315`（`23,025` FFs） | Unified FTQ-64（`PTAB+FA+FTQ` 合一 + 同步 1R1W `ftq_meta`），面积与 EXP-069 基本持平 |
| **`tlb_mmu_bb`** | `SRAM_BLACKBOX` / `0.50 ns` | **`−0.03`** | **`1.89 GHz`（持平）** | `23 lvl` / `−110` | `94,793`（`7,490` FFs） | 回填预存 `ppn_p1/m1`（兼容 Sv39 大页与 bare），L1 TLB 时序零回退 |

- **零黑盒综合揭示的下一阶段核心抓手**：
  1. **前端实宏面积/布线优化**：`icache_arr` `4×8×16×512b` 映射到 64-depth 真宏存在约 4× 深度填充浪费，BPU 8-bank 切分带来 156 颗宏（`1.69 mm²`）及 `u_ftb1 → u_spec` 扇出；后续拟将 `icache_arr` 重构为 64-depth 友好形状、BPU 合并为 2~4 bank、`axi_llc` 数据/标签评估 1R1W→1RW。
  2. **后端子系统提频**：DTLB/LSU 长链已解开，下一瓶颈为 `u_lsu/u_ldq → u_isu/g_iq[5]`（`1.16 ns`）及 `Issue / RegRead` 紧耦合，下轮将推进 `Issue/RegRead` 拆拍并全面转入无黑盒真实 SRAM 综合签核。
