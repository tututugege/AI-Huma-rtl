# tututugege-rtl

tututugege OoO RISC-V 核（C++ 参考模型）的 SystemVerilog 翻译，目标是与参考模型**逐拍一致**。

- 文档入口：[docs/README.md](docs/README.md)（范围、编码规范、开发流程、harness、翻译规则、进度）
- 验证 harness 自检：`make selftest`
- RTL 检查：`make lint`

当前阶段：harness 与规范已就绪，尚无核内模块 RTL（见 [docs/05-module-tracker.md](docs/05-module-tracker.md)）。
