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

---

## 补充（第二批起适用，以此为准）

1. **必读 `docs/06-equivalence-policy.md`**。不迁就 C++ 的怪行为：残留值/越界/恒 0 字段/调试字段不复刻；无效时无意义的输出用 `when` 且**删掉对齐 C++ 的强制清零/保持**；没人读的字段从 spec 和 RTL 删除。放宽前必须在参考模型里核对所有读取点（写进设计笔记第 4 节），放宽后变异检查仍须有效。
2. **设计笔记先于 RTL**（`docs/modules/<mod>.md`，含消费者核对、放宽/删除/不复刻清单、变异表）。
3. **标准程序集合**：`bash scripts/record_all.sh <mod>` 现在录 61 个 gate 测试 + `scripts/progs.txt` 里的程序（dhrystone/coremark/coremark10、4 个 vm 测试、float/sha/cjpeg/linear_alg/parser），拍数上限见 progs.txt，gate 默认 30000（`GATE_CYCLES`），`JOBS=2`。端口特别宽的模块先用 `GATE_CYCLES=8000` 控制磁盘（磁盘紧张，已用 >90%）。不再需要的 trace 请删除。
4. **随机 trace 生成器**：真实程序覆盖不到的路径，写一个直接驱动参考模型该类的生成器补充（模板：`/Users/ruyaoh/personal/rtl-wt/{prf,ren,idu,dispatch,rob}` 里的 `tests/<mod>/rand_trace.cpp` 或 `tb/<mod>/gen_rand.cpp`，只读参考）。注意激励必须是参考模型下合法的（可不定义 NDEBUG 让 C++ Assert 全开来自检），并在设计笔记里写明约束依据。
5. **风格范例**（已合并的同类代码，只读参考）：`prf/rtl/backend/prf/prf_write_arb.sv`、`ren/rtl/backend/ren/ren_rat.sv`、`idu/rtl/backend/idu/idu_ctrl_decode.sv`。顶层只做端口适配；逻辑在子模块；用 `ttg_first_set`/`ttg_onehot_mux`/`ttg_popcount`；禁止 break/while/运行计数器。
6. **工具**：package 文件命名 `*_pkg.sv`，工具会自动排在前面；`scripts/lint.sh` 的 `<=` 比较误报已修；断言与 lint 豁免见 `docs/01` 第 1 节与 8.5。需要主仓库新工具时 `git merge main`；不要改 scripts/harness/rtl/common/docs（除你自己的 `docs/modules/<mod>.md`）。
7. **共享 scratchpad 会被其他 agent 覆盖**：临时文件放在 scratchpad 下你自己的子目录（`<scratchpad>/<mod>/`）。提交用 `git -c user.name=ruyaoh -c user.email=ruyaoh@nvidia.com commit`。
8. **报告**：除原有项外，写出 RTL 行数 vs 参考模型 C++ 行数、spec 字段数、放宽/删除字段表、选择不复刻的 C++ 行为清单、只靠随机 trace 才能抓到的变异数量。

9. **debug / perf / TMA 字段与 PMU**：见 `docs/06-equivalence-policy.md` 第 8 节。只服务可观测性（dbg、perf、`tma.*`）的字段不进 RTL 和 spec；按"谁读它"判断，不要按名字（`diag_val` 是功能字段）。

10. **总原则（06 第 0 节，最高优先级）**：只要求边界上每个周期的可观察行为功能等价。C++ 的调用结构、一拍内调用次数、comb/seq 熔合、中间变量、阶段顺序、容器与指针一律不复刻；被覆盖的瞬态不比较。验证强度不降：仍用整程序锁步 + 变异检查证明等价。不需要为这类设计取舍等待协调者评审，在设计笔记里写清合并规则和等价性即可。
11. **文档与进度**：设计笔记头部要填 front-matter（见 `docs/modules/TEMPLATE.md`），进度表由协调者 `make tracker` 生成，不要改 `05-module-tracker.md`。
12. **变异检查要快**：一次构建、运行时选变异体（读 `scripts/mut_backtop_fast.py`）；短程序筛、幸存者只在 ≤12 个短程序×15 万拍复跑。锁步默认 30 万拍上限，别跑 400 万拍。
13. **（用户决定）变异检查不再要求，也不是合入门禁。** 验证 = lint + 冒烟集（8 个短程序×≤5 万拍、1 路并行）+ 针对改动的定向短程序；整程序 68 个锁步由协调者在机器空闲时统一跑。不要自行跑全量锁步或变异；总耗时以几分钟为目标。
