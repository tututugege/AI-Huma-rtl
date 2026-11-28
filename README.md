# rtl

AI-Huma 乱序 RISC-V 核的 SystemVerilog 实现。起点是把 tututugege 模拟器逐模块翻译过来（2026-11-04 完成，前端、后端、访存子系统、整核）；现在随项目自己的优化迭代，核参数来自 trace-model 的 `config.h`（`make cfg`）。可以在 Verilator 里整核闭环运行（核 + 访存子系统 + DDR/外设模型）。

**当前状态（2026-11-28，EXP-073 + `rtl/fe-2ahead`）**：
- `main` 仅维护 **`rv64gc` + `Sv39`**（`XLEN_BITS = 64`、`FP = 1`、`RVC_ENABLE = 1`）；`rv32` 已归档至分支 `rv32-legacy`。
- **核心微架构**（与 `trace-model/include/config.h` 默认配置完全对齐）：
  - **前端**：单套 2-Ahead BPU（uFTB 256 + 主 FTB + 2 路 6 表 2-Ahead ExBlockTage + 4 表 2-Ahead ITT + RAS，见 `docs/modules/bpu.md`）、64 KiB（`256×4`）Lo-32B/Hi-32B 两级 VIPT ICache（单口 `1024×32` 宏，64 项 ITLB，见 `docs/modules/icache.md`）、FDIP 预取（1 项回填缓冲）；
  - **后端**：2 级流水重命名（`IDU → S1 → S2 → DISPATCH`、无上限 `CNT_W=6` 组内 1-hop `MOVE_ELIM`、1 拍流水化检查点写与 INT 空闲表回收、稀疏 `K=4` 单写口检查点 + 本地 256×25b `ren_log` 8 宽前向 Walk）、`PRF=256 / ROB=256 / MAX_BR=32`、双 INT 发射队列 + 合并 MEM 队列 + 5 个物理 AGU、Radix-4 Booth 乘法 + 1× Radix-16 Early-out 变延迟除法（EXU 动态唤醒）+ 全套自研可综合 RV64FD FPU（默认仿真走 DPI、`SYNTHESIS` / `-DFPU_REAL` 走真 RTL）、Load L2a 并行 STQ CAM + 256-bit STQ Bloom Filter + L2b STLF 拆拍 + Load L2 推测唤醒与取消、访存相关推测（`LSU_MEMSPEC`）与拍平 STQ Write Buffer；
  - **访存与缓存**：16-MSHR L1D + 4 级流水硬件 Berti 预取器、统一 L2 TLB（1024×4 1RW SRAM）+ 8 项大页 CAM + 16 项 Sv39 PWC、4 MiB LLC（SRRIP）+ BOP & Bingo 4KB 空间预取器。
- **验证状态**：`lint_chip.sh` 0 警告/0 错误；`fm_gate.sh` **77/77 PASS（0 FM 不一致、77/77 与 `trace-model` / `ref_cycles.txt` 0 周期差；随机上电初值 `SOC_TB_RAND_INIT` 下同样 77/77）**；`rv64gc` + `Sv39` Linux 5.15 **26 窗检查点对齐（`s01..s26`，~1.326 亿指令）26/26 PASS、0 FM 不一致、26/26 PT/UP 指纹 100% 逐拍全等**。
- **TSMC 28nm HPC+ DC 综合状态**（`ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`，详见 [docs/09-synthesis-report.md](docs/09-synthesis-report.md) §15–18）：全核 23/23 核心模块全部突破 **1.12 GHz**（`ren` **1.67 GHz**、`lsu` **1.12 GHz** / 纯组合 `1.18 GHz`），其中 **15/23 ≥ 1.54 GHz**、**20/23 ≥ 1.28 GHz**、**22/23 ≥ 1.20 GHz**。这是 EXP-065 时的基线；之后的结果见 09 §19–23。SRAM 复位清扫（`ttg_rst_sweep`，2026-11-28）之后还没有重新综合。
- 每个原子模块的设计文档位于 `docs/modules/`（索引 `docs/05-module-tracker.md`），RTL 开发流程见总仓库 `docs/WORKFLOW.md` 第 7 节。

- 文档入口：[docs/README.md](docs/README.md)（范围、编码规范、模块设计笔记、风险登记簿）；各子系统的说明在 `docs/modules/<模块>.md`
- 目录布局：`rtl/`（全部 RTL，含 `soc/` 流片向全片 SoC 与双层 Full-AXI4 互联，见 [rtl/README.md](rtl/README.md)）、`docs/`、`scripts/`（[索引](scripts/README.md)）、`tb/core/`（核+存储子系统测试台 `core_tb`，平台模型在 `tb/core/platform/`）、`tb/soc/`（真实全片 SoC 测试台 `soc_tb`）、`tb/axi_unit/`（AXI4 互联协议单测）、`sva/`（SVA bind 断言，见 [sva/README.md](sva/README.md)）、`tools/`（[说明](tools/README.md)）、`harness/tools/`、`programs/`、`tests/`

## 双测试台分工约定（`core_tb` vs `soc_tb`）

| 测试台 | 顶层 RTL | 定位与职责 | 常用入口 |
|---|---|---|---|
| **`tb/core/core_tb`** | `soc_top`（`core_top + mem_top`） | **核+Cache 微架构研发台**：与 `trace-model` 逐拍周期对齐、逐条 `function-model` Difftest、支持 SVA/覆盖率/Fuzzer/Linux 26 窗检查点；外设走 C++ `PeripheralModel`，不引入片上 `soc_xbar` | `SOC_FM=1 bash tb/core/build.sh`、`scripts/fm_gate.sh`、`scripts/riscv_tests_gate.sh`、`scripts/linux_segments_cmp.sh` |
| **`tb/soc/soc_tb`** | `chip_top`（核+双层 Full-AXI4+真实片上外设） | **流片/FPGA 全片集成验证台**：仅暴露芯片引脚，含 ARM IHI 0022E 在线 `soc_axi_checker`、BootROM、64 KiB SRAM、CLINT、PLIC、NS16550A UART、SysCtrl 与 CRG | `bash tb/soc/build.sh`、`scripts/soc_gate.sh`（可选 `--linux`）、`tb/axi_unit/build.sh` |

## 常用命令（在本目录执行）

```bash
export PATH="$HOME/rv64spec/verilator_src/bin:$PATH"        # iprc-jump 必须用 Verilator 5.052
make cfg                                                    # 由 trace-model/include/config.h 生成 rtl/common/ttg_cfg_pkg.sv（不要手改）
bash scripts/lint.sh                                        # 编码规范 + verilator -Wall，按目录
bash scripts/lint_chip.sh && bash scripts/lint_soc.sh       # soc_top 与 chip_top 整芯 -Wall，输出 0 warnings 为通过
# 一次性准备：门禁程序（rv64ima，用 trace-model 的 build_tests.sh，TM_SRC 指向一棵 trace-model 树）
TM_SRC=../trace-model bash scripts/build_progs.sh           # -> build/progs（env.sh 的 TTG_PROGS 默认值）
# 1) 核+存储子系统测试台（core_tb）：function-model 由 scripts/fm_lib.sh 按固定版本 FM_REV 自动构建
SOC_FM=1 CORE_OUT=$PWD/build/core_fm bash tb/core/build.sh
bash scripts/fm_gate.sh $PWD/build/core_fm/obj/core_tb $PWD/build/gate   # 77 个程序逐条对拍 + 周期比对
# 2) 真实全片 SoC 一键回归门禁（soc_tb + axi_unit + lint_soc + DDR_DATA_W=64/128，加 --linux 测 Linux 启动）
bash scripts/soc_gate.sh
# 模型默认配置改了（= RTL 配置改了）之后重新生成参考周期：
bash scripts/regen_refs.sh <trace-model 的 simulator> "说明"
```

- **测试平台构建**：`tb/core/build.sh`（输出 `obj/core_tb`）与 `tb/soc/build.sh`（输出 `obj/soc_tb`）默认用全部核编译 C++（`JOBS` 可改），并按 5000 条语句拆分生成的 C++。`core_tb` 自带 `tb/core/fpr.h`（对齐指纹，哈希与 trace-model 相同）。
- **正确性门禁**：核侧逐条提交对比 function-model（`tb/core/fm_check.h`），`fm_gate.sh` 跑 `scripts/ref_cycles.txt` 的 77 个 rv64 程序；全片 SoC 侧由 `scripts/soc_gate.sh` 守住。
- **周期**是性能指标：`ref_cycles.txt` 是 trace-model 默认配置下的周期（`scripts/regen_refs.sh` 生成），合入 main 时 `core_tb` 与它逐个相等。
- **跑 Linux**（长跑/集群 26 窗对齐）：`core_tb` 用 `scripts/build_soc64_linux.sh` 构建，默认 **4 线程**（`THREADS` 可改；`rob_pkg::EBREAK_TRAP` 已默认开启），集群跨机静态链接时需传 `CORE_COPT="-O2 -march=x86-64-v3 -mtune=generic"` 与 `CORE_LDFLAGS="-static -Wl,--whole-archive -lpthread -Wl,--no-whole-archive -latomic"`。运行时设 `SOC_TB_SEMIHOST=1 SOC_TB_FM=1 SOC_TB_LOG=2000000`；分段并行检查见 `scripts/linux_segments_cmp.sh`。
- 测试平台调试开关：`SOC_TB_LOG=<n>`（每 n 周期一行进度）、`SOC_TB_STLOG=<物理地址>`（打印提交到该 8 字节字的 store）、`SOC_TB_COMMIT`、`SOC_TB_RAND_INIT=<种子>`（所有寄存器和存储随机上电值，需 `SOC_XINIT_UNIQUE=1` 构建；0 = 全零，默认）、`DEBUG=1`（`--public-flat-rw`）。
- **复位后的 SRAM 清扫**：`soc_top` 在外部复位之后再保持复位 `SRAM_SWEEP_CYCLES`（4100）拍，让 SRAM 包装把 `INIT_VAL` 写满每个地址，结束时拉高 `init_done`。`core_tb` 从 `init_done` 之后才开始计周期，所以和模型比的周期不变（见 `docs/modules/common.md` 4.1 节）。

## 生成文件与 rv64 的已知债务

- `rtl/common/ttg_cfg_pkg.sv`：由 `harness/tools/gen_cfg_pkg.py`（`make cfg`）生成。默认就是 rv64gc 的包（2026-11-16 起），构建时不再生成副本。
- `rtl/backend/back_top/back_top.sv`、`exu.sv`、`rtl/core/soc_top/soc_top.sv` 以前由 `tools/gen_backtop.py`、`tools/gen_soc_top.py`（输入 `spec/*.io`）生成，生成器和 `spec/` 已在 2026-11-16 删除（它们为 rv64 手改过位宽，早已不同步）：**这三个文件现在直接手改**。`spec/` 已整个删除；测试平台探针用的 core_top 边界字段表是入库的快照 `tb/core/core_top_fields.h`。
- 数据通路里 `XLEN_BITS` 相关的位宽：PC、寄存器、立即数、ALU/乘除、CSR、LSU/dcache 数据字 `DW = XLEN`；dcache 的行和 AXI 一侧仍是 32 位字；物理地址始终 32 位（rv64 是 Sv39 虚拟地址、32 位物理地址）。

翻译阶段的"逐拍锁步 / trace 回放 / 变异检查"体系完成使命后退役，代码和文档都在标签 `legacy-reference` 里。
