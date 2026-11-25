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
