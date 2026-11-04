# rtl

乱序 RISC-V 核（tututugege 模拟器的 SystemVerilog 实现），前端、后端、访存子系统和整核都已完成，可以在 Verilator 里整核闭环运行（核 + 访存子系统 + DDR/外设模型）。

- 文档入口：[docs/README.md](docs/README.md)（范围、编码规范、模块设计笔记、风险登记簿）
- RTL 检查：`make lint`
- 整核闭环：`bash tb/soc/build.sh`，`build/soc/obj/soc_tb <程序.bin> <周期上限>`
- **正确性门禁**：逐条提交对比 function-model —— `SOC_FM=1 bash tb/soc/build.sh`，运行时 `SOC_TB_FM=1`（见 [docs/modules/soc_top.md](docs/modules/soc_top.md)）
- 周期数、IPC 是**性能指标**，不再要求与任何参考相等；与 trace-model 的对比用 `scripts/cmp_trace_model.sh`

早期的"逐拍锁步 / trace 回放 / 变异检查"体系随旧参考模型一起退役，代码在标签 `legacy-reference`（本仓库）里。
