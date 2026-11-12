# 01 RTL 编码规范

本规范是**强制**的。机器能查的由 `harness/tools/svlint.py`（规则 S1–S9）和 `verilator -Wall`（全部警告为错误）检查，`make lint` 必须干净才能提交；机器查不了的由评审人按本文逐条核对。

## 0 设计原则（强制，评审第一项）

> **总原则**（现行规则见 [06-equivalence-policy.md](06-equivalence-policy.md)，2026-11-04 起正确性是整核逐条提交与 function-model 一致，周期与 trace-model 比较）：RTL 不复刻参考模型的调用结构、阶段顺序、comb/seq 是否熔合、中间变量、容器与指针。

**RTL 不是 C++ 的逐行翻译。** 架构行为必须与 function-model 一致，周期与 trace-model 在同一配置下一致，但**结构必须是硬件结构**。（本规范写于翻译阶段：下文提到的 `trace`、`replay.sh`、`deviations.md` 登记、“Ref: 参考模型”头注释，是旧体系的要求；现行有效的是 lint 规则、三层结构、设计笔记和评审清单。）

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
- 断言只允许放在 `` `ifndef SYNTHESIS `` 内，且不得影响仿真结果；用于表达"参数必须是 2 的幂"这类前提，以及"C++ 里不可达的状态"。**运行期断言必须是时钟采样的** `assert property (@(posedge clk) ...)`；`always_comb` 里的立即断言会在 Verilator 求值的中间态误触发（Isu 已踩过，曾让 10 个 trace 误中止）。只有编译期的参数一致性检查可以用 `$error`。

## 2. 文件与命名（S1 S2 S3 S9）

- 每个文件一个模块（或一个 package），文件名 = 模块名 + `.sv`，全小写下划线（`rob.sv`、`issue_queue.sv`）。
- 文件第一行有效代码是 `` `default_nettype none ``，最后一行是 `` `default_nettype wire ``。
- 无 tab、无行尾空白、行宽 ≤ 120。
- 参数/常量：`UPPER_SNAKE_CASE`；信号/变量：`lower_snake_case`；类型：`lower_snake_case_t`；枚举值：`UPPER_SNAKE_CASE`。
- 模块名与 C++ 中对应的类/模块名一致（`Rob` → `rob`，`IssueQueue` → `issue_queue`）。
- 目录：`rtl/common`（package、通用单元）、`rtl/backend`、`rtl/frontend`、`rtl/memsys`（访存子系统与 AXI/LLC）、`rtl/core`（`core_top`、`soc_top`）、`rtl/pmu`。

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


### 3.1 存储阵列的写法（寄存器堆、FIFO 存储、各种表、队列条目）——不要整体算次态

两段式（`_d`/`_q`）适用于**标量寄存器、指针、状态机、少量字段**。**存储阵列不适用**，必须按存储器的写法：

- **不为阵列建 `_d`**，不写 `for (i) mem_d[i] = mem_q[i]` 这类"默认整体保持"，也不写 `for (i) mem_q[i] <= mem_d[i]`。
- 在 `always_ff` 里**按写口更新**：`if (we) mem_q[waddr] <= wdata;`。多个写口各自一条 `if`（写冲突的优先级由语句顺序表达，或在写口前先仲裁）。每个条目有独立使能时（如多车道写同一个寄存器堆），用 generate 为每个条目写一个带使能的 `always_ff`：`if (wr_en[p]) q[p] <= wr_data[p];`。
- **读口异步读**：`assign rdata = mem_q[raddr];`。
- **复位**：存储内容通常不复位（只复位指针、valid 位、计数）。只有当参考模型要求"复位后某条目的值可被观察"时才复位，并写明理由。
- 条目内含多个字段时，用 packed struct 做条目类型，一次整条写入，不要把字段拆成并行的多个数组各自一套 `_d`。
- 理由：这是硬件上的 SRAM / 寄存器堆写法；整体算次态会生成 N 倍的无效逻辑，综合出大量多余的数据通路，而且让仿真慢一到两个数量级（前端 FIFO 的存储、BPU 的预测表是典型）。
- 大阵列（> 数千位）优先使用同步写、异步读的存储原语（参考 BPU 的 `bpu_mem`，位于 `rtl/frontend/bpu/`），在设计笔记里写明端口数与读写时序。

**一拍内多个阶段顺序改写同一个阵列**（C++ 的 `nxt` 习惯）也不是硬件结构：不要为每个阶段生成一份整体拷贝（`st_v1..st_v5`）。把"对同一阵列的所有写"合并成按条目的写使能和写数据（优先级链），由一次 `always_ff` 写入。

## 4. 端口

- 端口全部平铺（不用 interface），顺序：`clk, rst_n`，然后输入，然后输出。
- **端口名与 `spec/<module>.io` 完全一致**，类型按 spec：宽度 1 用 `logic`，否则 `logic [W-1:0]`，数组用非压缩维度 `logic [W-1:0] name [D0][D1]`。
- 端口名取自参考模型对应 IO 结构体的字段名，结构体嵌套用 `_` 连接（`rob_commit.commit_entry[i].valid` → `rob_commit_entry_valid[i]`）。这样 trace 里的字段名和 C++ 源码一一对得上。
- 模块内部可以用 packed struct 组织，但**边界端口不用 struct**。
- **1 位元素的通道数组写成打包向量**：`logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid`，不写 `logic x [8]`（`spec` 里仍是 `1 [8]`，
  验证外壳 `iogen` 会按 RTL 里的声明方式生成连接）。多位元素的通道数组仍用非压缩维度。判据与工具：`tools/pack_bits.py`（按信号名一次性转换，
  名单 `tools/pack_bits_names.txt`；参数化尺寸无法求值的、以及 `*_bank` 这类以模块参数 `N` 定尺寸的端口保持非压缩，`tools/pack_bits_skip.txt`）。
  新代码直接按此写；扫描式链（`alive[p+1] = alive[p] && ...`，同一 always_comb 内逐位依赖）保持非压缩数组，否则 Verilator 报 ALWCOMBORDER。
- **数组尺寸用配置参数，不写字面量**：`[COMMIT_WIDTH]`、`[ISSUE_WIDTH]`、`[LSU_LDU_COUNT]`…；边界信号名到参数的对应表在 `tools/dimmap.py`
  （生成器 `gen_backtop.py` 同样套用）。

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
- 与 C++ 行为的差异：翻译阶段要在 `deviations.md` 登记（已停止新增）；现在行为差异由 function-model / trace-model 的对比体现，改动记在总仓库 `docs/` 的 EXP 记录里。

## 8. 每个模块必须附带

1. `spec/<module>.io`：接口规格（格式见 [03-harness.md](history/03-harness.md) 第 2 节）。
2. （旧体系）参考模型里的录制点——已退役。
3. `make lint`、`scripts/lint_chip.sh` 干净（0 警告），`scripts/fm_gate.sh` 通过（旧体系的 `replay.sh` 已退役）。
4. （旧体系）至少 3 个变异体检查——已不再要求。

## 8.5 lint 豁免（仅限以下三种，其余一律不允许）

1. `*_pkg.sv` 里的 `/* verilator lint_off UNUSEDPARAM */`（包里的常量被别的文件使用，单独 lint 包时会误报）。
2. 端口位宽由 spec/参考模型规定、但高位确实不用时，在该端口附近用**局部** `lint_off UNUSEDSIGNAL` 并写明原因（如 `rob2dis.enq_idx` 的高位）。
3. 通用原语的输出端口未被某个实例使用时：接到一个**具名**哑信号，并在该信号声明处加局部 `/* verilator lint_off UNUSEDSIGNAL */`（写明原因）。空连接 `.any()` 会被 `-Wall` 的 PINCONNECTEMPTY 拒绝，不要用。
每处豁免必须带注释，评审逐个核对。

## 9. 评审清单

- [ ] 有设计笔记；顶层只做端口适配；按硬件功能拆分了子模块
- [ ] 无 C++ 式循环/break/运行计数器；每个文件 ≤400 行、每个 always_comb ≤60 行
- [ ] 文件头有 Ref 注释；每个 `always_comb` 有 Ref 函数名
- [ ] 无手写位宽魔数；常量来自 `ttg_cfg_pkg`
- [ ] 所有寄存器有复位，复位值与 C++ `init()` 一致
- [ ] 无锁存器、无组合环、无 lint 豁免（如需豁免，注释写明理由并经评审）
- [ ] 与 C++ 的每个差异都登记在 `deviations.md`
