# 02 开发流程

每个模块都走同一条流水线。**任何一步未完成，不得进入下一步；模块在 `05-module-tracker.md` 里只有两种终态：绿（全部通过）或红（有未解决问题）。**

## 流程总览

```
1 读 C++ ─▶ 2 写 spec ─▶ 3 录制 trace ─▶ 4 写 RTL ─▶ 5 回放到绿 ─▶ 6 变异检查 ─▶ 7 评审合入 ─▶ 8 更新 tracker ─▶ 9 集成闭环
```

## 1 读 C++，划定模块边界

- 找到该模块在参考模型里的类/函数、它的 `comb_*()` / `seq()`、它读写的所有外部信号（`wires->...`）。
- 边界信号 = 模块读取的所有外部量（输入）+ 其他模块/顶层读取它的所有量（输出）。**输入必须是完整的**：漏掉一个隐含依赖，回放就会出现无法解释的分歧。
- 参考模型的 shadow 钩子（`MOD(phase)`）和差分 harness 已经把后端各模块的边界划清楚了，优先参考。
- 产出：模块笔记（写进 `05-module-tracker.md` 的备注，或 `docs/modules/<mod>.md`）。

## 2 写 `spec/<module>.io`

- 格式见 [03-harness.md](03-harness.md) 第 2 节；信号名取自 C++ 字段名，结构体嵌套用 `_` 连接（规范第 4 节）。
- 评审点：`when` 只用于 C++ 确实"无效时无意义"的字段。
- spec 一旦有 trace 录制，就视为冻结；改动 = 重新录制全部 trace。

## 3 录制 trace

- 参考模型已有只读录制钩子（`refsim/`，由 `scripts/refsim_setup.sh` 生成，周期数已验证与原版一致）。你只需要在 spec 的每个字段后写 `@ <C++ 表达式>`（见 03 第 4 节），然后：
  `bash scripts/record_all.sh <module>` 录制全部标准程序（每个程序只录开头 N 拍，因为 RTL 从复位开始）。
- 最小程序集合（每个模块都要）：
  1. `build/tests` 里的 61 个 gate 测试（覆盖面广、短）；
  2. dhrystone、coremark（热路径、长）；
  3. memory-stress、smc-div、smc-addi（边角：访存冲突、自修改代码）；
  4. 该模块的专项：如 LSU/DCache 用 `dcache-conflict-writeback`，MMU 用 vm 测试，flush/mispredict 用分支压力测试。
- 对每个模块记录"覆盖了什么"：用 trace 统计各输入组合/状态的命中（至少：每个 `valid` 类输入取过 0 和 1、队列满/空/回绕都出现过）。覆盖不到的路径用专项或随机激励补。

## 4 写 RTL

- 严格遵守 [01-rtl-coding-standard.md](01-rtl-coding-standard.md)（尤其第 0 节：硬件结构，不是逐行翻译）；翻译规则见 [04-cpp-to-rtl-mapping.md](04-cpp-to-rtl-mapping.md)。
- **先写设计笔记** `docs/modules/<mod>.md`（模板见 `docs/modules/TEMPLATE.md`），再写 RTL。
- 行为（每拍每位）与 C++ 一致，结构按硬件功能重新组织；等价性由 trace 保证，不靠"代码长得像"。理解了 C++ 的一拍内数据流之后，用并行/优先级结构表达。
- `make lint` 必须干净。

## 5 回放到绿

```bash
bash scripts/replay.sh <module>        # 对 traces/<module>/*.trc 全部回放
```

- 全部 trace 的每一拍每一位都一致才算过（`PASS <mod>: N records`）。
- 出现 MISMATCH：先看第一个失败的周期和字段，用自动导出的 VCD 对照 C++ 源码定位。**不允许改 spec 的 `when` 或放宽比较来"让它过"**——那等于改了验收标准，必须单独评审。
- 若分歧源于参考模型的怪异行为（读 stale 值、同拍多次写同一量等），按 04 第 3 节处理并登记 `deviations.md`/隐含依赖表，不得悄悄绕过。

## 6 变异检查（证明 trace 抓得住 bug）

绿了之后，对 RTL 做至少 **3 个**有意义的变异（改比较条件、改回绕、改优先级、改一个位宽…），每个都必须被回放抓到。抓不到说明 trace 覆盖不足（回到第 3 步补 trace），而不是 RTL 没问题。变异记录写进 `05-module-tracker.md`。

## 7 评审合入

- 评审人按规范第 9 节清单逐项核对，并重新运行 `make lint` 与第 5 步回放。
- 提交信息：`rtl/<area>: <module> (green: <traces>, mutants: n/n)`。
- 不允许合入红模块；不允许合入修改了 harness 却没跑 `make selftest` 的提交。

## 8 更新 `05-module-tracker.md`

状态、参考模型提交号、使用的 trace、变异数、偏差编号。

## 9 集成与闭环

- 若干模块绿了以后，按数据流成组集成（例：Ren+Dispatch+Isu），成组再录一份 trace（组边界）回放。
- 最终：整核闭环——用 RTL 替换参考模型里的模块（Verilator 通过 C++ 接口接入），在 gate 测试和大程序上周期数与参考模型逐一相等。

## 建议的模块顺序

先易后难，先叶子后枢纽，每一步都能独立验收：

1. 基础单元与小模块：`Prf`、`PreIduQueue`、`Csr`、`Ren`、`Idu`
2. 后端核心：`Rob`、`Dispatch`、`Isu`/`IssueQueue`、`Exu`/`Fu`（含 FP 网表）
3. 访存后端：`Lsu`、`TlbMmu`
4. 前端：各 FIFO、`predecode`、BPU（TAGE/BTB/SC/loop）、ICache、前端顶层（需先把 `front_comb_calc` 还原成数据流）
5. 访存子系统：`RealDcache`、`MSHR`、`WriteBuffer`、`PtwWalker`
6. uncore：`AXI_LLC`、`AXI_Interconnect`（范围待定）

## 分支与提交

- 主线只接受绿模块。开发在 `rtl/<module>` 分支上进行。
- 一个提交只做一件事；harness/规范/文档改动与 RTL 改动分开提交。
