# 01 RTL 编码规范

本规范是**强制**的。机器能查的由 `harness/tools/svlint.py`（规则 S1–S9）和 `verilator -Wall`（全部警告为错误）检查，`make lint` 必须干净才能提交；机器查不了的由评审人按本文逐条核对。

## 0 设计原则（强制，评审第一项）

**RTL 不是 C++ 的逐行翻译。** 行为必须与参考模型逐拍一致（由 trace 保证），但**结构必须是硬件结构**。

1. **先写设计笔记再写 RTL**：`docs/modules/<mod>.md`（模板见 `docs/modules/TEMPLATE.md`）。写清：框图、每个状态数组的含义和大小、读写端口数、关键组合路径、C++ 数据结构到硬件结构的对应、一拍内的数据流。没有设计笔记不评审。
2. **三层结构**：
   - 顶层 `<mod>.sv`：只做端口适配——把 spec 规定的平铺端口打包/拆包成内部 struct，实例化核心子模块。不放逻辑。
   - 核心子模块：按硬件功能拆分（例：重命名拆成 RAT、空闲表、组内依赖检查、checkpoint 各一个模块），内部可用 packed struct / enum。
   - 通用原语：`rtl/common/ttg_*.sv`（find-first-set、独热 mux、popcount 等）。新原语先放在本模块目录并以模块名为前缀（`ren_xxx.sv`），由协调者统一提升到 common。
3. **用硬件构造表达并行**：优先级选择用 `ttg_first_set`；多路选择用独热 mux；"数前面有几个"用前缀和/popcount；队列用读写指针+满空标志。**禁止**把 C++ 的"for 循环 + break + 运行计数器"搬进 `always_comb`（S11 检查）。
4. **体量上限**：一个文件 ≤ 400 行，一个 `always_comb` ≤ 60 行（S10 检查）。超了说明该拆模块或拆成具名阶段，而不是放宽限制。
5. **命名表达含义**：信号名说明它是什么（`free_preg_onehot`、`rename_group_conflict`），不用 `tmp`、`flag1`、`cnt2`；一个信号一个含义，不复用变量。
6. **全参数化**：车道数、深度、位宽都是参数或来自 `ttg_cfg_pkg`；用 `generate for` 展开车道，不手工复制粘贴 N 份。
7. **状态集中**：每个状态数组一个明确的"写端口"逻辑块；写冲突的优先级写成显式规则并注释对应的 C++ 行为。
8. **不要迁就 C++ 的怪行为**：残留值、越界读、恒为 0 的字段、调试字段都不必复刻；等价性原则见 [06-equivalence-policy.md](06-equivalence-policy.md)。`when` 和删字段是允许的，但必须核对消费者并写入设计笔记，且变异检查仍须有效。


## 1. 语言子集

- SystemVerilog-2017，**必须能被 Verilator 5.x 无警告编译**。
- 只用 `logic`、`always_ff`、`always_comb`、`typedef struct packed`、`typedef enum logic [N-1:0]`、`localparam`、`function automatic`、`generate for/if`、`package`。
- 禁止：`initial`、`#延时`、`force/release`、`$random`、`$display/$finish/$stop`、`always`（裸）、`always @*`、锁存器、三态、`inout`、层次化引用、`wire x = ...` 隐式声明、`interface/modport`（端口一律平铺）、`class`、`program`、动态数组/队列/关联数组/字符串。
- 断言只允许放在 `` `ifndef SYNTHESIS `` 内（`assert property` 或带 `$error` 的即时断言），且不得影响仿真结果；用于表达"参数必须是 2 的幂"这类前提，以及"C++ 里不可达的状态"。

## 2. 文件与命名（S1 S2 S3 S9）

- 每个文件一个模块（或一个 package），文件名 = 模块名 + `.sv`，全小写下划线（`rob.sv`、`issue_queue.sv`）。
- 文件第一行有效代码是 `` `default_nettype none ``，最后一行是 `` `default_nettype wire ``。
- 无 tab、无行尾空白、行宽 ≤ 120。
- 参数/常量：`UPPER_SNAKE_CASE`；信号/变量：`lower_snake_case`；类型：`lower_snake_case_t`；枚举值：`UPPER_SNAKE_CASE`。
- 模块名与 C++ 中对应的类/模块名一致（`Rob` → `rob`，`IssueQueue` → `issue_queue`）。
- 目录：`rtl/common`（package、通用单元）、`rtl/backend`、`rtl/frontend`、`rtl/mem`、`rtl/uncore`。

## 3. 时钟、复位、寄存器

- 单时钟 `clk`，同步复位 `rst_n`（低有效）。每个模块的前两个端口固定为 `clk`、`rst_n`。
- **所有寄存器必须显式复位**，复位值 = 参考模型 `init()` 之后的值。不依赖仿真器初值（harness 用 `--x-initial 0` 只是为了可重复，不是许可）。
- 寄存器后缀 `_q`，次态后缀 `_d`。每个模块采用"两段式"，与 C++ 的 `comb()` / `seq()` 对应：

```systemverilog
always_comb begin          // == C++ comb()：只用阻塞赋值，只写 *_d 和输出
  foo_d = foo_q;           // 默认保持
  if (...) foo_d = ...;
end

always_ff @(posedge clk) begin   // == C++ seq()：只用非阻塞赋值，只写 *_q
  if (!rst_n) foo_q <= '0;
  else        foo_q <= foo_d;
end
```

- `always_ff` 里只做"复位或 `*_q <= *_d`"，**不放逻辑**（S6、S8）。逻辑一律在 `always_comb`（S7）。
- `always_comb` 里每个变量必须在所有路径上先赋默认值（防止推出锁存器）。
- 禁止在 `always_ff` 里使用 `*_d`/`*_q` 以外的名字做目标；禁止对 `*_q` 做 `assign`（S8）。

## 4. 端口

- 端口全部平铺（不用 interface），顺序：`clk, rst_n`，然后输入，然后输出。
- **端口名与 `spec/<module>.io` 完全一致**，类型按 spec：宽度 1 用 `logic`，否则 `logic [W-1:0]`，数组用非压缩维度 `logic [W-1:0] name [D0][D1]`。
- 端口名取自参考模型对应 IO 结构体的字段名，结构体嵌套用 `_` 连接（`rob_commit.commit_entry[i].valid` → `rob_commit_entry_valid[i]`）。这样 trace 里的字段名和 C++ 源码一一对得上。
- 模块内部可以用 packed struct 组织，但**边界端口不用 struct**。

## 5. 位宽与算术

- 所有位宽、深度、索引宽度来自 `ttg_cfg_pkg`（`import ttg_cfg_pkg::*;`），不得出现手写的魔数宽度。
- 赋值两侧位宽必须一致，需要截断/扩展时显式写出（`W'(x)`、`{{N{1'b0}}, x}`），不依赖隐式转换（Verilator `WIDTH` 警告即为错误）。
- 有符号运算必须显式 `$signed/$unsigned`，并在注释里说明理由。
- 循环索引、数组下标越界行为要与 C++ 一致：C++ 里靠 `% N` 回绕的，RTL 里写成显式回绕；不得依赖越界读写。

## 6. 组合逻辑与求值顺序

- **不允许任何组合环**（Verilator `UNOPTFLAT`/`COMBDLY` 是错误）。
- C++ 里"后面的阶段读前面阶段刚算出的值"的结构，在 RTL 里就是普通的组合数据流，没有问题。
- C++ 里**读到上一拍残留值**（stale）或**同一拍被覆盖两次**的写法，必须按 [04-cpp-to-rtl-mapping.md](04-cpp-to-rtl-mapping.md) 第 3 节处理并登记，不得悄悄"修正"。

## 7. 注释与可追溯性

- 每个模块文件头 20 行内必须有一行 `// Ref: back-end/Rob.cpp  class Rob`（S12 检查），可附参考模型提交号。
- 每个 `always_comb` 段落前注明对应的 C++ 函数名（`// Ref: Rob::comb_commit`）。
- 与 C++ 行为的任何差异（哪怕是"明显的 bug"）都要在 `deviations.md` 登记，并在代码处写 `// DEVIATION D-<n>`。**默认不允许有偏差**。

## 8. 每个模块必须附带

1. `spec/<module>.io`：接口规格（格式见 [03-harness.md](03-harness.md) 第 2 节）。
2. 参考模型里的录制点（见 02 流程）。
3. `make lint` 干净、`scripts/replay.sh <module>` 对所有指定 trace 通过。
4. 至少 3 个变异体检查（见 02 流程第 6 步）。

## 8.5 lint 豁免（仅限以下三种，其余一律不允许）

1. `*_pkg.sv` 里的 `/* verilator lint_off UNUSEDPARAM */`（包里的常量被别的文件使用，单独 lint 包时会误报）。
2. 端口位宽由 spec/参考模型规定、但高位确实不用时，在该端口附近用**局部** `lint_off UNUSEDSIGNAL` 并写明原因（如 `rob2dis.enq_idx` 的高位）。
3. 通用原语的输出端口未被某个实例使用时，用具名的空连接 `.any()`，不要用豁免。
每处豁免必须带注释，评审逐个核对。

## 9. 评审清单

- [ ] 有设计笔记；顶层只做端口适配；按硬件功能拆分了子模块
- [ ] 无 C++ 式循环/break/运行计数器；每个文件 ≤400 行、每个 always_comb ≤60 行
- [ ] 文件头有 Ref 注释；每个 `always_comb` 有 Ref 函数名
- [ ] 无手写位宽魔数；常量来自 `ttg_cfg_pkg`
- [ ] 所有寄存器有复位，复位值与 C++ `init()` 一致
- [ ] 无锁存器、无组合环、无 lint 豁免（如需豁免，注释写明理由并经评审）
- [ ] 与 C++ 的每个差异都登记在 `deviations.md`
