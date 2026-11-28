# 08 风险登记簿（现行有效风险）

> 本文件只记录当前 `main`（`rv64gc` + `Sv39`）**仍未关闭**的验证缺口、设计限制与技术债。已关闭项和历史变更（rv32、旧锁步/变异体系等）保留在 git 历史中；要执行的动作记在 [../../docs/TODO.md](../../docs/TODO.md)。

## 1. 验证与覆盖风险

| # | 内容 | 等级 | 状态 / 缓解 |
|---|---|---|---|
| V-1 | **RTL vs `trace-model` 在高分支误预测 SPEC06 点上存在少量对称周期微差异**：全量 386/386 SPEC06 INT（10M warmup + 10M ROI，~77.2 亿条指令）RTL 逐条 FM 比对已 **0 fail / 0 FM diff 全通**，12 项基准 geomean **`+0.00%`**，其中 **266/386（68.9%）实现 0-cycle 完全对齐**（`hmmer`/`libquantum`/`h264ref`/`astar` 100% 0-cycle）；但剩余 120 点（集中于 `458.sjeng` 0/27、`471.omnetpp` 1/25、`483.xalancbmk` 25/34 等高分支误预测/间接跳转负载）存在对称 `±` 周期微差（最大单点 `2.65%`） | 低 | 架构正确性已全量闭环；剩余周期微差登记在 TODO，待抽 1 个 `458.sjeng` 点定位首个分歧周期 |
| V-2 | **AMO 写回数据未进 `fm_check.h` store 对比**：`SOC_TB_FM_STRICT=1` 已覆盖 RAM/MMIO store 与 18 架构 CSR，但 `0x2f` AMO 写回结果仍依赖后续 load 间接校验 | 中 | 登记在 TODO |
| V-3 | **中断与页错为被动跟随**：`fm_check.h` 按 RTL 触发的 `mcause`/`force_pf` 同步 FM，RTL 若漏报中断/页错可能逃逸 | 中 | 由定向测试（`irq_flush_race`、`sv39_edge`、`sv39_priv_itlb`）与 Fuzzer 覆盖 |
| V-4 | **LR/SC 遇异步中断的保留位分歧（原 R-7）**：`lp_rsv.sv` 在 `sc` 推测执行时即清 `rsv_valid_q`，若随后异步中断冲刷未提交 `sc`，`mret` 重执 RTL 返回 1，而 `function-model` 中断未清 `reserve_valid` 返回 0 | 中 | 根因已于 2026-11-25 查明并登记 TODO |
| V-5 | **长程与极罕见覆盖死角**：① BPU TAGE `reset_cnt[23]` 需数百万次更新（短测试未触发）；② `dcache_resp.sv` `fwd_st`/`fwd_st_full`/`fwd_ld_full` 与 `lp_ldq_ent.sv` `L2_WBP` 仍为 0 命中；③ 尚未在集群跑全量 `--coverage-toggle`（`SOC_COV=all`）与 26 窗 Linux 下 `SOC_SVA=1` | 中 | 已建 `rtl/sva/` 与 `tools/fuzz/`，待上集群长跑与补洞 |
| V-6 | **形式化验证（CEC / FPV）尚未接入**：EXP-062~065 大量组合逻辑改写缺少 Yosys `equiv_*` / Formality 形式等价（此前 `isu_fp_gate` 跨类写回 Bug 即由手改重结合引入） | **高** | 登记在 TODO：优先为组合降深度模块建立 Yosys CEC |
| V-7 | **门级后仿（GLS）与 RTL-vs-Gate LEC 未做**：已跑 TSMC 28nm DC 综合，但尚未对综合网表做门级仿真与形式等价 | 中 | 待整核 DC 综合收敛后补齐 |

## 2. 架构功能与硬件限制

| # | 内容 | 等级 | 说明 |
|---|---|---|---|
| A-1 | **不支持非对齐访存**：普通 load/store 非对齐未按 RISC-V 规范上报 cause 4/6 异常，也未硬件支持 `Zicclsm`（`riscv_tests_gate.sh` 默认跳过 `rv64ui-ma_data`） | 中 | 待决定走异常上报或队头慢路径硬件支持 |
| A-2 | **物理地址截断在 32 位（4 GiB）**：`ptw_walk` 静默截断高 PPN，不支持标准 Sv39 56-bit PA | 低 | 当前平台内存 ≤ 2 GiB，暂不影响 |
| A-3 | **CSR 与特权级精简**：仅实现 24 个 CSR 表项，缺 `mcycle`/`minstret`/PMU CSR 接入、PMP、Access Fault（cause 1/5/7）、Debug Module；`csr_trap_class.sv` 保留少量历史异常优先级简化 | 低 | 跑通当前 OpenSBI + Linux 5.15，流片前需补齐 |
| A-4 | **LLC 局部路径未充分压力覆盖**：旁路写/部分行写 miss 及 `stall_lookup_on_table_busy` 主要靠断言守护 | 低 | 登记在 TODO |

## 3. 代码卫生与基础设施债

| # | 内容 | 等级 |
|---|---|---|
| D-2 | `tests/pmu/pmu_tb.cpp` 落后于 PMU 事件表（`NUM_EV = 52`，`rtl/pmu/pmu_ev_pkg.sv` 的 `PMU_NUM_EV = 66`） | 低 |
| D-3 | 缺少自动化 CI 流水线（门禁全靠手工触发） | 低 |

## 4. 最近审计记录

- **2026-11-25**：清理历史 rv32/旧锁步过期条目；闭环原 V-6（`SOC_XINIT_UNIQUE=1` + `SOC_SVA=1` 69/69 PASS）、大幅收敛原 V-12（`SOC_TB_FM_STRICT=1` 覆盖 MMIO store 与 18 架构 CSR）、查明原 R-7 根因（LR/SC 推测 `sc_clr` + 异步中断）、接入 152 官方 `riscv-tests`（检出并修复 `isu_fp_gate` 跨类写回 Bug）+ 8 定向短测试（行覆盖 `96.44%`，DDR 写回 AW/W/B 0→92）+ RV64GC Fuzzer（RTL 100/100 + Spike 500/500 PASS）。
- **2026-11-26**：完成全量 **386/386 SPEC06 INT（10M+10M + 逐条 FM 比对，~77.2 亿条指令）** 8 线程 RTL 验证（**0 fail、0 FM diff、12 项基准 geomean `+0.00%`、266/386 点 0-cycle 精确一致**）；全量验证期间实测检出并修复 4 项真实缺陷：① LSU `lp_core.sv`/`lp_ldq.sv` 补齐 per-port `epoch` 过滤防陈旧 DCache 响应搭便车；② ISU `Isu.cpp`/`isu_pkg.sv`/`isu_fp_gate.sv` 修复 `FDIV`/`FSQRT` FPWB 预留提前 1 拍溢出；③ `fp_dpi.cpp` 加 `std::mutex` 消除 `--threads 8` SoftFloat 舍入竞态；④ `trace-model` `PerfCount::perf_reset()` 补齐 `cycle_base = 0`（修复 `--restore-stub` 重复扣减 ~25k 周期导致的 +0.78% 虚高）。原 V-1 降级为低风险（仅剩高分支负载 120 点对称 `±` 周期微差）。
- **2026-11-28**（`rtl/fe-2ahead`）：① 查出并修复 SRAM 上电值依赖（73761fa）：原来 SRAM 包装在仿真里靠 `initial` 给 `INIT_VAL`，综合后上电是随机值（如 LLC 的 valid / dirty / 替换表会假命中、写回垃圾）；现在 `ttg_sram_1rw` / `ttg_sram_1r1w` 复位期间逐地址写 `INIT_VAL`，`ttg_rst_sweep` 把整核复位延长 `SRAM_SWEEP_CYCLES`（4100）拍，`SOC_TB_RAND_INIT` 随机上电下 `fm_gate.sh` 77/77、0 周期差。② 整核 Verilator `UNOPTFLAT` 清零，`scripts/` 里的 `-Wno-UNOPTFLAT` 全部删除（5e5d40f），原 D-1（`axi_subsys` 跳过 Verilator lint）关闭，`lint.sh` 现在照常 lint `axi_subsys`。③ `make cfg` 重新生成的 `ttg_cfg_pkg.sv` 与入库文件逐字节相同，原 D-2 的配置同步部分关闭。
