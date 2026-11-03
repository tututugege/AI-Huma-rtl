# 翻译任务书（给负责单个模块的 agent）

> **重要（后加）**：先读 `docs/06-equivalence-policy.md`。目标是"有意义的行为一致"，**不要迁就 C++ 的怪行为**（残留值、越界读、恒 0 字段、调试字段），RTL 应当比 C++ 简单得多。下面第 2、6 步里关于 `when`/禁止放宽的字样以 06 为准。

你负责把参考模型里的**一个模块**翻成 SystemVerilog，并与参考模型**逐拍对照通过**。先通读 `docs/01-rtl-coding-standard.md`（尤其第 0 节）、`docs/02-development-flow.md`、`docs/03-harness.md`、`docs/04-cpp-to-rtl-mapping.md`，然后按下面执行。

## 你在哪、有什么

- 你的当前目录是本仓库的一个**独立 git worktree**（你自己的分支）。只改你自己的文件，提交到你的分支。
- 参考模型源码（只读，commit 2f31e8d）：`/Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src`。后端在 `back-end/`，IO 结构体在 `back-end/include/IO.h`，各阶段的调用顺序在 `back-end/BackTop.cpp`（`comb()` 里的 `comb_stage_*`），模块间连线是 `BackTop` 的成员（`dec2ren`、`ren2dis`…）。
- 已装好的、**共享只读**的带钩子参考模型：`/Users/ruyaoh/personal/tututugege-rtl/refsim`（`scripts/record.sh` 默认用它，不要修改它，不要在其中构建）。
- 测试程序：`/Users/ruyaoh/personal/tututugege-trace/build/tests/*/*.bin`（61 个）+ `/tmp/big/{dhrystone,coremark}.bin`。
- 工具链：Verilator 5.x、python3、clang++。**注意本机 shell 是 zsh**：脚本用 `bash scripts/…` 运行；含空格的变量别直接展开。BSD `sed -i` 需要 `-i ''`，复杂替换请用 python。

## 步骤（每一步都必须做）

1. **读 C++**：读该模块的 .cpp/.h 和 `BackTop.cpp` 里调用它的阶段，列出它读的所有外部量（输入）和被别处读的所有量（输出，包括被其他模块直接读它成员的）。输入必须完整。
2. **写 `spec/<mod>.io`**：格式见 `docs/03-harness.md` 第 2、4 节。每个字段写 `@ <C++ 表达式>`（`cpu`/`bt`/`i0`/`i1`… 可用）。端口名取 C++ 字段名，结构体嵌套用 `_`。只有 C++ 确实"无效时无意义"的字段才可用 `when`。不翻译 perf/debug/`dbg.*` 字段。
3. **录制**：`JOBS=2 bash scripts/record_all.sh <mod>`（先 `CYCLES=20000 bash scripts/record.sh <mod> /tmp/big/dhrystone.bin` 快速试通）。必要时用 `GATE_CYCLES` 控制拍数。检查 trace 的覆盖：各 `valid` 类输入是否取过 0 和 1，队列是否满/空/回绕，flush/mispredict 是否出现过。覆盖不到的路径如实报告。
4. **设计笔记**：`docs/modules/<mod>.md`（模板 `docs/modules/TEMPLATE.md`），**先于 RTL 写**。
5. **写 RTL**：`rtl/backend/<mod>/` 目录，顶层 `<mod>.sv`（只做端口适配）+ 按硬件功能拆分的子模块；风格严格按规范第 0 节：硬件结构，不是 C++ 逐行翻译；无 break/while；文件 ≤400 行；always_comb ≤60 行；参数化；`_q/_d` 两段式；复位值 = C++ `init()` 之后。新原语放在你自己的目录并以模块名为前缀，**不要改 `rtl/common/`**。
6. **回放到绿**：`bash scripts/replay.sh <mod>`（默认回放 `traces/<mod>/*.trc` 全部）。有 MISMATCH 就用 VCD 对照 C++ 找原因。**禁止放宽比较、禁止改 `when` 来让它通过。** 若是参考模型的怪异行为（读上一拍残留值、同拍多次覆盖、`init()` 里的非零初值、越界回绕），按 `docs/04` 第 3 节处理，并在设计笔记和最终报告中逐条列出。
7. **lint**：`bash scripts/lint.sh` 必须干净（含 svlint S1–S12 与 verilator -Wall）。
8. **变异检查**：至少 3 个有意义的变异（改比较条件、改回绕、改优先级、改位宽…），每个都必须被回放抓到；抓不到说明 trace 覆盖不足，要补。记录在设计笔记第 5 节。
9. **提交**：提交到你的分支，提交信息 `rtl/backend: <mod> (green: <n> traces, mutants: k/k)`。不要提交 `traces/`、`build/`。

## 禁止事项

- 不要修改：`harness/`、`scripts/`、`rtl/common/`、`refsim/`、`docs/` 里除你自己的 `docs/modules/<mod>.md` 以外的任何文件（包括进度表和 deviations.md，这些由协调者汇总）。发现 harness 或工具的 bug，**停下来在报告里说明**，不要自己绕过。
- 不要修改参考模型源码。
- 不要为了通过而改 spec 的语义；改 spec 的字段集合是允许的（比如补漏掉的输入），但改完必须重新录制全部 trace。
- 机器负载：同时有多个 agent 在录制，请用 `JOBS=2`，不要开额外的后台常驻进程，结束时确保没有遗留进程。

## 最终报告格式（简洁，用中文）

- 状态：绿 / 红（红则写卡在哪）
- 文件清单与行数（rtl、spec、笔记）
- trace：程序数、总记录数、覆盖情况（有哪些路径没覆盖到）
- 变异：做了哪几个，各被哪个字段在第几拍抓到
- 发现的隐含依赖 / 与 C++ 的差异 / 参考模型疑点（逐条，写清 C++ 位置）
- 对 harness、规范、工具的意见或遇到的问题
- 分支名与提交号
