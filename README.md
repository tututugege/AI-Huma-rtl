# rtl

AI-Huma 乱序 RISC-V 核的 SystemVerilog 实现。起点是把 tututugege 模拟器逐模块翻译过来（2026-11-04 完成，前端、后端、访存子系统、整核）；现在随项目自己的优化迭代，核参数来自 trace-model 的 `config.h`（`make cfg`）。可以在 Verilator 里整核闭环运行（核 + 访存子系统 + DDR/外设模型）。

**当前状态（2026-11-12）**：rv32imab（默认）和 rv64imab（EXP-029，2026-11-12 合入 main）两种位宽，由配置包里的 `XLEN_BITS` 选择；F/D、C 扩展和 SPEC 在 rv64 上都**没做**（rv64 下 OP-FP 是非法指令）。Linux 5.15 在 RTL 上从复位启动到登录提示：rv32 约 1.6 亿周期、rv64 约 1.3 亿周期，逐条对比 0 不一致。

- 文档入口：[docs/README.md](docs/README.md)（范围、编码规范、模块设计笔记、风险登记簿）；子系统笔记 `RTL_FE_NOTES.md`、`RTL_MEMSPEC_NOTES.md`、`RTL_WBUF_NOTES.md`、`RTL_INTEG_NOTES.md`
- 目录布局：`rtl/`（全部 RTL，见 [rtl/README.md](rtl/README.md)）、`docs/`、`scripts/`（[索引](scripts/README.md)）、`tb/soc/`（整核测试平台）、`spec/` 与 `tools/`（生成器，见下）、`harness/tools/`（配置包生成器）、`programs/`、`tests/`

## 常用命令（在本目录执行）

```bash
make cfg                                    # 由 trace-model/include/config.h 生成 rtl/common/ttg_cfg_pkg.sv（不要手改；rv32 默认）
bash scripts/lint.sh                        # 编码规范 + verilator -Wall，按目录
bash scripts/lint_chip.sh                   # 整芯片 -Wall（soc_top 为顶），输出 0 warnings 为通过；CFG=<包> 用别的配置包
# 测试平台：rv32
SOC_FM=1 SOC_OUT=$PWD/build/soc_fm bash tb/soc/build.sh
# 测试平台：rv64（用 rtl/ 的副本，XLEN_BITS=64、MUL_MAX_LATENCY=3、DIV_MAX_LATENCY=32；FMLIB 必须是 XLEN=64 构建的 function-model librefcpu.a）
SOC_XLEN=64 SOC_FM=1 FMLIB=<function-model rv64 librefcpu.a> SOC_OUT=$PWD/build/soc64 bash tb/soc/build.sh
# 门禁：ref_cycles.txt 里 69 个程序逐条提交对比 function-model（rv32）
bash scripts/fm_gate.sh $PWD/build/soc_fm/obj/soc_tb $PWD/build/gate
```

- **正确性门禁**：逐条提交对比 function-model（`tb/soc/fm_check.h`），`fm_gate.sh` 在 rv32 上 69/69、周期与 `scripts/ref_cycles.txt` 0 处不同。rv64 没有对应的 `fm_gate.sh` 程序表，rv64 的 53 个 cpu-tests 是手工用同一个测试平台跑的（见总仓库 `docs/MAIN_RECORDS.md` 2026-11-12 行）。
- **周期**是性能指标：`ref_cycles.txt` 是 trace-model 在当前配置下（并设 `LSU_PIPE_NOWD=1`，RTL 没有 LDQ/STQ 看门狗）的周期，合入 main 时 RTL 与它逐个相等。
- **跑 Linux**（数小时）：测试平台要用 `SOC_VOPT="--threads 4 -DTTG_EBREAK_TRAP"` 构建（ebreak 当断点异常，内核需要），运行时设 `SOC_TB_SEMIHOST=1 SOC_TB_FM=1 SOC_TB_LOG=2000000`，例如
  `SOC_TB_LOG=2000000 SOC_TB_SEMIHOST=1 SOC_TB_FM=1 build/soc_fm/obj/soc_tb ~/personal/AI-Huma-data/linux/linux.bin 400000000`（rv64 用 `linux_rv64/linux.bin`，镜像生成见 function-model `linux/README.md`）。分段并行检查见 `scripts/linux_segments.sh`。
- 测试平台调试开关：`SOC_TB_LOG=<n>`（每 n 周期一行进度）、`SOC_TB_STLOG=<物理地址>`（打印提交到该 8 字节字的 store）、`SOC_TB_COMMIT`、`DEBUG=1`（`--public-flat-rw`）。

## 生成文件与 rv64 的已知债务

- `rtl/common/ttg_cfg_pkg.sv`：由 `harness/tools/gen_cfg_pkg.py`（`make cfg`）生成。rv64 构建不改这个文件，只在 `build/.../rtl64` 副本里把 `XLEN_BITS` 等改为 64 的值。
- `rtl/backend/back_top/back_top.sv`、`exu.sv`、`rtl/core/soc_top/soc_top.sv` 是**生成文件**（`tools/gen_backtop.py`、`tools/gen_soc_top.py`，输入 `spec/*.io`）。**为 rv64 手改过位宽，spec/*.io 和生成器没有同步：重新生成会丢掉这些位宽，rv64 就坏了。** 改这三个文件前先把位宽改动回写到 `spec/*.io` 与生成器（待办，见总仓库 `docs/TODO.md`），否则只能手改。
- 数据通路里 `XLEN_BITS` 相关的位宽：PC、寄存器、立即数、ALU/乘除、CSR、LSU/dcache 数据字 `DW = XLEN`；dcache 的行和 AXI 一侧仍是 32 位字；物理地址始终 32 位（rv64 是 Sv39 虚拟地址、32 位物理地址）。

翻译阶段的"逐拍锁步 / trace 回放 / 变异检查"体系完成使命后退役，代码在标签 `legacy-reference`，文档在 [docs/history/](docs/history/)。
