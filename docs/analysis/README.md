# docs/analysis — 边界分析与设计分析

这里是翻译阶段写的分析文档，**设计内容仍可参考**（RTL 代码注释引用了 `lsu-structure.md`、`frontend-boundary.md` 等）；其中“与参考模型逐拍对照”的部分已随旧体系退役（2026-11-04，见 [06-equivalence-policy.md](../06-equivalence-policy.md)）。录制点（`*-record-hook.md/.patch`）已挪到 [../history/analysis/](../history/analysis/)。

| 区域 | 文档 |
| --- | --- |
| 后端 Exu | [exu-boundary.md](exu-boundary.md) |
| 前端 | [frontend-boundary.md](frontend-boundary.md) |
| BPU | [bpu-boundary.md](bpu-boundary.md) |
| ICache | [icache-boundary.md](icache-boundary.md) |
| 访存子系统 | [memsys-boundary.md](memsys-boundary.md) |
| LSU 结构（各阶段的写规则，**旧 LSU**） | [lsu-structure.md](lsu-structure.md) |
| 分级 LSU（`LSU_PIPE=1`，默认）的规格与 RTL 行为清单 | [lsu-pipe.md](lsu-pipe.md) |
| BPU 流水化 RTL | [bpu-pipe-rtl.md](bpu-pipe-rtl.md) |
| 发射队列深度分析 | [isu-depth.md](isu-depth.md) |

这些文档写于 rv32、32 位 PC、行式 ROB 时期；位宽（现为 `XLEN_BITS`）、ROB（现默认紧凑）、LSU（新增 store 写缓冲、访存推测）等细节以 `docs/modules/*.md` 的“更新”提示和源码为准。

- `data/`：覆盖与锁步统计（历史数据，文件名带程序数和拍数）。
- `tools/`：覆盖插件、位宽实测（`widths.cpp`）、验证脚本；`examples/`：早期示例 spec 与 trace 检查脚本。
