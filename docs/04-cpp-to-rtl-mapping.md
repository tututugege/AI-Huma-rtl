# 04 C++ → SystemVerilog 翻译规则

> **适用范围（2026-11-12）**：本文是翻译阶段（对着 C++ 参考模型）的规则。现在新增逻辑是对着 trace-model 的 `config.h` / 行为写，RTL 不要求与模型结构对应；本文里的“构造对照表”和 stale 读处理对读旧代码、读 `// Ref:` 注释仍有用，`deviations.md` / `trace 回放` 相关条款已退役。位宽一律用 `XLEN_BITS`，不要写死 32。

参考模型是"RTL 风格"的 C++（comb/seq 分离、`wire<N>` 位宽类型），大部分构造可以机械翻译。本文规定怎么译，以及遇到不能机械翻译的情况怎么处理。

## 1. 构造对照表

| C++（参考模型） | SystemVerilog | 备注 |
| --- | --- | --- |
| `class Foo` + `init()` | `module foo` + 复位分支 | 复位值 = `init()` 之后的值 |
| `comb()` / `comb_xxx()` | `always_comb`（每段注明 `// Ref: Foo::comb_xxx`） | 多个 `comb_*` 按调用顺序展开为数据流，不是顺序执行 |
| `seq()` | `always_ff`（只做 `*_q <= *_d`） | |
| 成员寄存器 `x` / 次态 `x_1`（或 `cur`/`next`） | `x_q` / `x_d` | |
| `wire<N>` | `logic [N-1:0]`（N=1 用 `logic`） | |
| IO 结构体 `XxxIO` | 平铺端口，名字 `<struct>_<field>` | 嵌套/数组按 spec 的维度 |
| `constexpr int N = ...`（config.h） | `import ttg_cfg_pkg::*;` 使用同名常量 | 不得手写数字 |
| `for (int i = 0; i < W; i++)` 并行端口循环 | `for` 写在 `always_comb` 内，或 `generate for` | 要求循环体彼此无顺序依赖，否则按第 3 节处理 |
| `% N`、`& (N-1)` 回绕 | 显式回绕表达式 | 非 2 的幂必须写出 |
| 指针/uop 池 (`Uop*`、`uop_alloc`) | 槽位里直接存 payload（packed struct），按槽号引用 | 池只是模拟器的内存管理，不是硬件 |
| `std::deque/vector/queue` | 固定深度环形缓冲 | 深度取参考模型的**实际上界**，必须在 spec/笔记中写明来源；若无上界先和评审确认 |
| 位操作 `>>`/`<<`、`uint32_t` 回绕 | 显式位宽的 `logic [31:0]` | 移位量 ≥ 位宽时 C++ 是未定义行为，RTL 需与实际测得行为一致并登记 |
| `int` 有符号运算 | `$signed` 显式 | 注释说明 |
| FP 网表（`fadd.h`/`fmul.h`） | 由脚本从 `bool nX = ...` 网表逐行转成 `assign` | 单独出生成脚本，不手写 |
| perf 计数器、`BE_LOG`、`Assert`、debug 打印、`dbg.*` 字段 | **不翻译**，也不进 spec | 若 `dbg` 字段被控制逻辑使用，先报告 |
| `tbhook` / oracle / difftest / checkpoint | **不翻译** | 属于 testbench |

## 2. 数据通路规则

- 数据位宽、符号扩展、饱和/截断行为逐位对照 C++ 的实际结果（用 trace 回放验证，不凭阅读判断）。
- C++ 里 `uint64_t` 装 `wire<N>` 的位置，RTL 用精确位宽；高位清零/不清零的差异会表现为 spec 比较的位数差异，必须一致。

## 3. 隐含依赖与求值顺序（最重要，必须逐项登记）

参考模型靠**手排的调用顺序**保证每个阶段读到已算好的值。翻译时有三类情况，**不能机械搬**：

### 3.1 读到上一拍残留值（stale read）

某阶段读取一个由"更晚阶段"在本拍才写、因此读到的是上一拍遗留值的变量（例如参考模型 `BackTop` 注释里提到的"ROB 在 EXU 刷新之前消费 `exu2rob`"）。

- 检测：参考模型有诊断开关 `CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN`，每拍开头清空阶段 IO。打开它后周期数/行为变了，说明存在这类依赖。
- 处理：RTL 里把这个"上一拍值"建成**显式寄存器** `<sig>_hold_q`，在 spec 里不单独暴露，在 `04` 末尾的**隐含依赖表**登记（模块、信号、读取点、写入点）。
- 绝不允许为了避免寄存器而"改成读当拍值"。

### 3.2 同拍多次求值/累加

例如前端 `front_comb_calc` 在一拍内多次调用 FIFO 的 `comb_calc` 并累加请求（`accumulate_*_req`），LLC 的 `comb()` 一拍内被调用两次（输出相/输入相）。

- 处理：先在笔记里把"一拍内的所有步骤"写成数据流图，确认每一步的输入输出，再写成一次组合求值。累加规则 = 明确的优先级/合并逻辑，写成显式 mux。
- 该翻译必须经过评审，因为它改变了代码结构。

### 3.3 顺序覆盖

C++ 里同一变量被后面的语句覆盖（"后写者赢"）。RTL 里在 `always_comb` 内保持同样的语句顺序即可得到同样结果；**不要**重排语句。

### 隐含依赖表（持续维护）

| 模块 | 信号 | 类型（3.1/3.2/3.3） | 读取点 | 写入点 | RTL 处理 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| PreIduQueue | `rob_bcast.flush` | 3.1 | `comb_accept_front` 读到上一拍值 | `Rob::comb_commit`（Rob.cpp:179-182），`rob_bcast` 是 BackTop 跨拍成员 | 显式寄存器 `flush_prev_q`（flush 后第一拍 ready 为 0；flush 当拍 ready 可为 1，fire 随后被清）| 已实现并验证 |
| Rob | `exu2rob` | 核对：非 stale | `Rob::comb_complete` | `Exu::comb_exec` 在其之前写入，之后不再改 | 无需寄存器（BackTop 注释里的 Known issue 只在 `CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN=1` 下出现）| 已核对 |
| Ren | `rob_bcast.flush` | 核对：非 stale | `Ren::comb_fire` | `Rob::comb_commit` 更早 | 无需寄存器 | 已核对 |
| Idu | `dec_bcast.redirect_rob_idx` | 无消费者的残留 | 只在 Rob 误预测分支读 | `Idu::comb_branch` 仅误预测时写 | 不建 hold 寄存器，`when dec_bcast_mispred` | 已简化 |
| 闭环注意 | `commit_entry[i].uop.diag_val` | BackTop 行为 | `BackTop.cpp` flush 时覆盖为 `redirect_pc` | | Rob 边界上是 Rob 自己的值；闭环集成时该覆盖应放在 Rob 之外 | 待集成 | |

## 4. 时钟域

参考模型的 AXI 子系统以 16 倍频运行（`CONFIG_AXI_SUBSYSTEM_FREQ_DIV=16`，每个 CPU 周期里额外跑若干 tick，静默后提前退出）。**多时钟/倍频的处理方案尚未决定**，在 uncore 开工前必须在 `00-scope-and-decisions.md` 里定案，核内模块（范围 A）不受影响。

## 5. 不确定时怎么办

- 无法判断某个 C++ 写法的硬件含义 → 停下，写进模块笔记并向评审提问，不要猜。
- 发现参考模型的明显 bug → 不修；按参考模型行为实现，登记 `deviations.md` 的"参考模型疑点"栏，由评审决定。
