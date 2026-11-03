# docs/analysis — 分析报告、录制点、覆盖数据

按区域命名：`<区域>-boundary.md`（边界与翻译方案，标注"已验证/读码得出/未核实"）、`<区域>-record-hook.md/.patch`（只读录制点：用法与补丁，补丁按依赖顺序合入共享 `refsim_tap`）。

| 区域 | 边界分析 | 录制点 |
| --- | --- | --- |
| 后端 Exu | exu-boundary.md | （后端钩子在 `refsim/`） |
| 前端 | frontend-boundary.md | frontend-record-hook |
| BPU | bpu-boundary.md | — |
| ICache | icache-boundary.md | icache-record-hook |
| 访存子系统 | memsys-boundary.md | memsys-record-hook → memcpu-record-hook（须按此顺序） |

- `data/`：覆盖与锁步统计（文件名带程序数和拍数）。
- `tools/`：覆盖插件、位宽实测、验证脚本；`examples/`：早期示例 spec 与 trace 检查脚本。
