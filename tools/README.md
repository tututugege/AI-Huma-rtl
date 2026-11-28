# tools/

测试平台构建用的生成器、检查点转换和几个快速 lint 小工具。门禁、对比、综合脚本在 `scripts/`（[索引](../scripts/README.md)）。

| 文件 | 用途 | 用法 |
| --- | --- | --- |
| `gen_soc_probe.py` | 生成 `tb/core/core_probe.inc`：从 Verilator 的 `soc_top` 里读出 `core_top` 边界的全部字段，按 `tb/core/core_top_fields.h`（入库快照）的布局拼成 trace 记录，供 `SOC_TB_TRACE` 逐字段对比 | `tb/core/build.sh` 每次构建自动调用，不用手跑 |
| `gen_skipmask.py` | 从 Verilator 生成的类布局里找出空转比较时要跳过的字节段（`__Vdfg*` / `__Vtemp*` / `__Vdly*` 临时量、`--threads` 的调度状态、≥ 1 MiB 的数组），写成 `skipmask.txt`，`core_tb` 的空转快进比较时读它 | `tb/core/build.sh` 自动调用：`gen_skipmask.py obj/layout.txt <输出目录>/skipmask.txt` |
| `ckpt2image.py` | function-model 检查点 → DDR 平坦内存镜像（从 `0x80000000` 起，默认 `0x10000000` 字节）；CPU 状态由 function-model 的 `tools/ckpt2stub.py` 生成的恢复程序（`SOC_TB_STUB`）给出 | `ckpt2image.py <checkpoint.gz> <out.bin> [字节数]`；`scripts/linux_segments.sh`、`linux_segments_cmp.sh` 自动调用 |
| `toplint.sh` | 整核 Verilator 只看展开错误（`%Error`），结构性改动后快速检查，不是规范检查 | `bash tools/toplint.sh [顶层=soc_top] [最多行数=40]` |
| `lint_back_top.sh` | `back_top` 装配体的 svlint + Verilator `-Wall`。`scripts/lint.sh` 现在已按装配体 lint `back_top`，这个脚本只在单查 `back_top`（或另给顶层）时用 | `bash tools/lint_back_top.sh [顶层=back_top]` |
| `fuzz/` | RV64GC 随机程序 Fuzzer：生成器、并行运行器（对拍 RTL 或 Spike）、失败用例缩减器 | 见 [fuzz/README.md](fuzz/README.md) |

正式的规范检查用 `scripts/lint.sh`、`scripts/lint_chip.sh`、`scripts/lint_soc.sh`（0 警告为通过）。
