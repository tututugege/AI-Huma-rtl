# docs/analysis — 边界分析与设计分析

这里是翻译阶段写的分析文档，**设计内容仍可参考**（RTL 代码注释引用了 `lsu-structure.md`、`frontend-boundary.md` 等）；其中“与参考模型逐拍对照”的部分已随旧体系退役（2026-11-04，见 [06-equivalence-policy.md](../06-equivalence-policy.md)）。录制点（`*-record-hook.md/.patch`）已挪到 [../history/analysis/](../history/analysis/)。

| 区域 | 文档 |
| --- | --- |
| 后端 Exu | [exu-boundary.md](exu-boundary.md) |
| 前端 | [frontend-boundary.md](frontend-boundary.md) |
| BPU | [bpu-boundary.md](bpu-boundary.md) |
| ICache | [icache-boundary.md](icache-boundary.md) |
| 访存子系统 | [memsys-boundary.md](memsys-boundary.md) |
| LSU 结构（各阶段的写规则） | [lsu-structure.md](lsu-structure.md) |

- `data/`：覆盖与锁步统计（历史数据，文件名带程序数和拍数）。
- `tools/`：覆盖插件、位宽实测（`widths.cpp`）、验证脚本；`examples/`：早期示例 spec 与 trace 检查脚本。
