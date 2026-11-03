# 03 逐拍对照 Harness

## 1. 架构

```
   参考模型 (C++ 仿真器 + 录制钩子)                         RTL 侧 (Verilator)
 ┌───────────────────────────────┐                  ┌────────────────────────────────┐
 │ 每拍 comb 结束、seq 之前：      │   traces/<mod>/  │ <mod>_tbwrap.sv  (iogen 生成)   │
 │  读取模块所有端口的当前值       │ ───────────────▶ │   in_bits ─▶ <mod> ─▶ out_bits  │
 │  TraceWriter::commit()         │     *.trc        │ replay (通用回放器)             │
 └───────────────────────────────┘                  │  施加输入→eval→逐位比较输出→时钟 │
              ▲                                      └────────────────────────────────┘
              │ 同一份 spec/<mod>.io 生成 ──────────────▲
              └─ <mod>_fields.h（字段表 + spec 哈希）
```

- **开环回放**：RTL 每拍的输入取自参考模型当拍录下的输入，RTL 的输出与参考模型当拍的输出逐位比较。RTL 内部状态（寄存器）因为每拍都被同样的输入驱动，若实现等价则始终与参考模型一致；一旦不等价，会在**第一个出现分歧的周期**被报告。
- 好处：模块之间互相独立，可以并行开发；trace 一次录制反复使用；失败时自动给出周期号、字段名、期望值/实际值、当拍输入和波形。
- 局限：开环只验证"给定参考输入序列时 RTL 的输出等价"。模块集成后再做**闭环**（RTL 输出反馈到参考模型的其余部分），见 02 流程第 9 步。

### 拍的语义（必须与录制点一致）

每条 trace 记录 = 某一拍里模块所有端口在 **comb 求值完毕、时钟沿之前**的稳定值：

```
记录 k:   施加输入 → eval() → 比较输出 → posedge clk
```

- 输出里的"寄存器直接输出"和"组合输出"没有区别，都是这一刻的值。
- 复位拍（`flags & RESET`）：`rst_n=0`，**不比较输出**。参考模型 `init()` 对应的复位拍必须录在 trace 开头（至少 3 拍）。
- 录制点必须放在参考模型 `BackTop::comb()`（或对应顶层）全部完成之后、`seq()` 之前。

## 2. 接口规格 `spec/<module>.io`

```
module toy_fifo
in  push_valid 1                 # 输入，宽度 1
in  push_data  8
in  blob       80                # 宽信号（>64 位）完全支持
out pop_valid  1
out pop_data   8  when pop_valid # 仅当 pop_valid 为 1 才比较（无效时 C++ 侧值无意义）
out slot_valid 1  [4]            # 数组
out slot_data  8  [4] when slot_valid   # 逐元素 when
out lane_sum   4  [2][2]         # 多维数组，行优先
```

- `when <v>`：`<v>` 必须是 1 位输出，且与本字段同维度（逐元素）或是标量。**只有参考模型确实"无效时不关心"的字段才允许用 `when`**，滥用会掩盖错误——评审时逐个核对。
- 信号名不得为 `clk rst_n in_bits out_bits`。
- spec 是接口的**唯一定义**：RTL 端口、trace 布局、录制代码都由它派生。改 spec 会改变哈希，旧 trace 会被回放器拒绝（需重新录制）。

## 3. 工具

| 工具 | 作用 |
| --- | --- |
| `harness/tools/iogen.py spec out/` | 生成 `<mod>_tbwrap.sv`（把平铺位向量接到真实模块端口）和 `<mod>_fields.h`（字段表 + 哈希） |
| `scripts/hbuild.sh spec outdir rtl...` | iogen + Verilator（`-Wall` 错误即失败）+ 编译通用回放器 `outdir/replay` |
| `build/<mod>/replay trace.trc` | 回放；`--vcd f.vcd --vcd-window N`（失败时自动重跑并导出最后 N 拍波形）、`--max-fail N`、`--max-records N` |
| `scripts/replay.sh <mod> [trace...]` | 一条命令完成构建 + 回放（默认 `traces/<mod>/*.trc`） |
| `scripts/lint.sh` | `svlint.py`（规范 S1–S9）+ `verilator --lint-only -Wall` |
| `harness/tools/gen_cfg_pkg.py` / `make cfg` | 从参考模型 `config.h` 生成 `ttg_cfg_pkg.sv` |

回放器输出示例（失败时）：

```
  MISMATCH rec=9 cycle=9 push_ready: ref=0x1 rtl=0x0
FAIL toy_fifo: first mismatch at record 9 (cycle 9), 1 field(s)
  inputs this cycle (non-zero):
    push_valid = 0x1
    ...
  waveform of records 0..9 written to build/toy_fifo/fail_x.vcd
```

## 4. 参考模型侧录制（已自动化）

参考模型的副本 `refsim/` 已经带有只读钩子：每个 CPU 周期在 `BackTop::comb()` 之后、任何时序更新之前，调用 `$TTG_REC` 指定的插件。插件由 spec 自动生成，**不需要手写录制代码，也不需要重新编译模拟器**。

在 spec 的每个字段后加 `@ <表达式>`：

```
in  inst_valid 1  [8] @ bt.dec2ren.inst[i0].valid     # 表达式里可用 cpu(SimCpu&) bt(BackTop&) i0 i1..(各维下标)
out rob_idx    7  [8] @ bt.ren2dis.inst[i0].rob_idx
in  big_meta   96     @w bt.x.meta.words               # @w：返回 uint32_t 小端字指针，任意位宽
```

- 能读私有成员（插件编译时 `private` 当作 public）。
- 要么每个字段都有 `@`，要么都没有（后者只能回放，不能录制）。`@` 表达式不参与接口哈希。

命令：

```bash
bash scripts/record.sh <module> prog.bin...     # 录指定程序，CYCLES 环境变量控制拍数（默认 200000）
bash scripts/record_all.sh <module>             # 录全部标准程序：61 个 gate 测试 + dhrystone/coremark，4 路并行
```

- **只录程序开头的 CYCLES 拍**：RTL 从复位开始，trace 不能从中途开始。录满后插件会直接结束模拟器（否则大程序会被整个跑完，原版很慢）。
- 每个 trace 开头是 3 个复位拍（输入 0，不比较输出），所以 RTL 的复位状态必须等于参考模型 `init()` 之后的状态。
- 共享的 `refsim/` 只读；多个 agent 可同时运行（实测并行录制无冲突）。
- trace 放 `traces/<module>/<程序名>.trc`，不入库。

## 5. Harness 自检（`make selftest`）

`tests/selftest/` 里有玩具模块 `toy_fifo`（标量、数组、二维数组、80 位宽信号、`when`），以及一个黄金 C++ 模型兼录制器。自检断言：

1. 干净 RTL 回放 2 万拍通过；
2. 8 个植入 bug 的变异体（满标志、读错槽、计数、指针回绕、宽信号、二维索引、flush、数据位）**全部被抓到**，且报告的字段名正确，并产出 VCD；
3. 改了 spec 后，旧 trace 被拒绝（哈希保护）；
4. `svlint.py` 对故意写坏的文件（`tests/selftest/lint_bad.sv`）逐条报出 S1/S2/S4–S9，对干净文件不报。

**修改 harness 的任何代码后必须重跑 `make selftest`。** harness 本身出错会让所有模块的"通过"失去意义。

## 6. 已知限制

- 开环回放无法发现"只有在 RTL 输出反馈给参考模型后才暴露"的问题（闭环阶段覆盖）。
- 每个数组元素在 trace 中占整字节（1 位信号占 1 字节），trace 体积较大；大程序请用 `--max-records` 截取或录制窗口。
- `x`/`z` 不存在：Verilator 是两态，所有寄存器必须显式复位（规范第 3 节）。
