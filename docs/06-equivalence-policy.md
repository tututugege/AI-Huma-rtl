# 06 正确性原则（2026-11-04 起）

早期版本的目标是和 C++ 参考模型"逐拍一致"，验证手段是逐模块锁步、trace 回放和变异检查。RTL 现在要自己迭代（改流水线、队列、预测器、缓存），逐拍一致不再成立，那套体系已退役（代码在标签 `legacy-reference`）。

## 现在的规则

1. **正确性 = 架构行为与 function-model 一致。** 整核测试平台（`tb/soc`，`SOC_FM=1` 构建、`SOC_TB_FM=1` 运行）让 function-model 每提交一条指令就执行一条，比较提交 PC 和目的寄存器的值；设备/计数器读值取 RTL 的；中断按 RTL 的 `mcause`/特权级强制注入。与微架构、时序无关，RTL 怎么改都有效。
2. **周期数、IPC 是性能指标**，不是门禁。`scripts/cmp_trace_model.sh` 给出与 trace-model 的差距，用来发现性能回退，不要求相等。
3. **整机门禁**：gate + vm 程序（64 个）逐条提交一致；Linux 启动到 `rv32 login:`；dhrystone / coremark 输出正确。
4. **尚未覆盖（要补）**：store 的地址/数据、CSR 写值、内存内容的对比；综合；形式检查。登记在 [08-risk-register.md](08-risk-register.md)。
5. **模块级测试**：以后每个模块对着一个简单的功能模型做随机自检（不再对着周期精确的旧模型）；`tests/fpu`（对 softfloat 和门级网表）、`tests/common`（原语穷举）保留。

## 历史（仅供查阅）

"有意义的行为逐拍一致"、"被覆盖的瞬态不复刻"、边界信号逐拍比较等原则只在旧体系下有意义，见标签 `legacy-reference` 下的本文件。
