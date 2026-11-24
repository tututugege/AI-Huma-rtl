# rtl

AI-Huma 乱序 RISC-V 核的 SystemVerilog 实现。起点是把 tututugege 模拟器逐模块翻译过来（2026-11-04 完成，前端、后端、访存子系统、整核）；现在随项目自己的优化迭代，核参数来自 trace-model 的 `config.h`（`make cfg`）。可以在 Verilator 里整核闭环运行（核 + 访存子系统 + DDR/外设模型）。

**当前状态（2026-11-24，EXP-064）**：
- `main` 仅维护 **`rv64gc` + `Sv39`**（`XLEN_BITS = 64`、`FP = 1`、`RVC_ENABLE = 1`）；`rv32` 已归档至分支 `rv32-legacy`。
- **核心微架构**（与 `trace-model/include/config.h` 默认配置完全对齐）：
  - **前端**：块级 FTB + S2 Block-TAGE / 多表 ITT + 并行 2-Ahead B（2-taken）、4-Bank 1R1W ICache + 2 读口 ITLB、S2 确认 2-slot FDIP；
  - **后端**：2 级流水重命名（`IDU → S1 → S2 → DISPATCH`、`MOVE_ELIM` 组内 1-hop 消除、稀疏 `K=4` 单写口检查点 + 本地 256×25b `ren_log` 8 宽前向 Walk）、`PRF=256 / ROB=256 / MAX_BR=32`、双 INT 发射队列 + 合并 MEM 队列 + 5 个物理 AGU、Radix-4 Booth 乘法 + 1× Radix-16 Early-out 变延迟除法（EXU 动态唤醒）+ 全套自研可综合 RV64FD FPU（默认仿真走 DPI、`SYNTHESIS` / `-DFPU_REAL` 走真 RTL）、Load L2 推测唤醒与取消、访存相关推测（`LSU_MEMSPEC`）与 STQ Write Buffer；
  - **访存与缓存**：16-MSHR L1D + 4 级流水硬件 Berti 预取器、统一 L2 TLB（1024×4 1RW SRAM）+ 8 项大页 CAM + 16 项 Sv39 PWC、4 MiB LLC（SRRIP）+ BOP & Bingo 4KB 空间预取器。
- **验证状态**：`lint_chip.sh` 0 警告/0 错误；`fm_gate.sh` **69/69 PASS（0 FM 不一致、69/69 与 `trace-model` / `ref_cycles.txt` 0 周期差）**；`rv64gc` + `Sv39` Linux 5.15 **26 窗检查点对齐（`s01..s26`，~1.326 亿指令）26/26 PASS、0 FM 不一致、26/26 PT/UP 指纹 100% 逐拍全等**。
- **TSMC 28nm HPC+ DC 综合状态**（`ssg0p81v125c`, 12T SVT+LVT, `CLK=0.50 ns / 2.0 GHz`, `compile_ultra`，详见 [docs/09-synthesis-report.md](docs/09-synthesis-report.md) §15–17）：全核 23/23 核心模块已补齐实测数据，其中 **14/23 ≥ 1.54 GHz**、**20/23 ≥ 1.28 GHz**、**22/23 ≥ 1.20 GHz**，仅剩 `lsu`（`0.97 GHz`）低于 1.20 GHz。
- 每个原子模块的设计文档位于 `docs/modules/`（索引 `docs/05-module-tracker.md`），RTL 开发流程见总仓库 `docs/WORKFLOW.md` 第 7 节。

- 文档入口：[docs/README.md](docs/README.md)（范围、编码规范、模块设计笔记、风险登记簿）；子系统笔记 `RTL_FE_NOTES.md`、`RTL_MEMSPEC_NOTES.md`、`RTL_WBUF_NOTES.md`、`RTL_INTEG_NOTES.md`
- 目录布局：`rtl/`（全部 RTL，见 [rtl/README.md](rtl/README.md)）、`docs/`、`scripts/`（[索引](scripts/README.md)）、`tb/soc/`（整核测试平台）、`spec/` 与 `tools/`（生成器，见下）、`harness/tools/`（配置包生成器）、`programs/`、`tests/`

## 常用命令（在本目录执行）

```bash
make cfg                                    # 由 trace-model/include/config.h 生成 rtl/common/ttg_cfg_pkg.sv（不要手改；默认 -DXLEN=64 -DRVC=1 -DFP=1，额外的 -D 参数追加在后面）
bash scripts/lint.sh                        # 编码规范 + verilator -Wall，按目录
bash scripts/lint_chip.sh                   # 整芯片 -Wall（soc_top 为顶），输出 0 warnings 为通过；CFG=<包> 用别的配置包
# 一次性准备：门禁程序（rv64ima，用 trace-model 的 build_tests.sh，TM_SRC 指向一棵 trace-model 树）
TM_SRC=../trace-model bash scripts/build_progs.sh       # -> build/progs（env.sh 的 TTG_PROGS 默认值）
# 测试平台；function-model 由 scripts/fm_lib.sh 按固定版本 FM_REV（env.sh）以 XLEN=64 FP=1 RVC=1 自动构建，不再需要 FMLIB
SOC_FM=1 SOC_OUT=$PWD/build/soc_fm bash tb/soc/build.sh
# 模型默认配置改了（= RTL 配置改了）之后重新生成参考周期：
bash scripts/regen_refs.sh <trace-model 的 simulator> "说明"
# 门禁：ref_cycles.txt 里 69 个程序逐条提交对比 function-model
bash scripts/fm_gate.sh $PWD/build/soc_fm/obj/soc_tb $PWD/build/gate
```

- **测试平台构建**：`tb/soc/build.sh` 默认用全部核编译 C++（`JOBS` 可改），并按 5000 条语句拆分生成的 C++（`--output-split` / `--output-split-cfuncs`）。测试平台自带 `tb/soc/fpr.h`（对齐指纹，哈希与 trace-model 相同）。
- **正确性门禁**：逐条提交对比 function-model（`tb/soc/fm_check.h`），`fm_gate.sh` 跑 `scripts/ref_cycles.txt` 的 69 个 rv64 程序。
- **周期**是性能指标：`ref_cycles.txt` 是 trace-model 默认配置下的周期（`scripts/regen_refs.sh` 生成），合入 main 时 RTL 与它逐个相等。
- **跑 Linux**（长跑/集群 26 窗对齐）：测试平台建议开启 **8 线程**（`SOC_VOPT="--threads 8"`；`rob_pkg::EBREAK_TRAP` 已默认开启），集群跨机静态链接时需传 `SOC_COPT="-O2 -march=x86-64-v3 -mtune=generic"` 与 `-Wl,--whole-archive -lpthread -Wl,--no-whole-archive -latomic`。运行时设 `SOC_TB_SEMIHOST=1 SOC_TB_FM=1 SOC_TB_LOG=2000000`；分段并行检查见 `scripts/linux_segments.sh`。
- 测试平台调试开关：`SOC_TB_LOG=<n>`（每 n 周期一行进度）、`SOC_TB_STLOG=<物理地址>`（打印提交到该 8 字节字的 store）、`SOC_TB_COMMIT`、`DEBUG=1`（`--public-flat-rw`）。

## 生成文件与 rv64 的已知债务

- `rtl/common/ttg_cfg_pkg.sv`：由 `harness/tools/gen_cfg_pkg.py`（`make cfg`）生成。默认就是 rv64gc 的包（2026-11-16 起），构建时不再生成副本。
- `rtl/backend/back_top/back_top.sv`、`exu.sv`、`rtl/core/soc_top/soc_top.sv` 以前由 `tools/gen_backtop.py`、`tools/gen_soc_top.py`（输入 `spec/*.io`）生成，生成器和 `spec/` 已在 2026-11-16 删除（它们为 rv64 手改过位宽，早已不同步）：**这三个文件现在直接手改**。`spec/` 已整个删除；测试平台探针用的 core_top 边界字段表是入库的快照 `tb/soc/core_top_fields.h`。
- 数据通路里 `XLEN_BITS` 相关的位宽：PC、寄存器、立即数、ALU/乘除、CSR、LSU/dcache 数据字 `DW = XLEN`；dcache 的行和 AXI 一侧仍是 32 位字；物理地址始终 32 位（rv64 是 Sv39 虚拟地址、32 位物理地址）。

翻译阶段的"逐拍锁步 / trace 回放 / 变异检查"体系完成使命后退役，代码在标签 `legacy-reference`，文档在 [docs/history/](docs/history/)。
