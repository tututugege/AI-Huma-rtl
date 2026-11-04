# 综合报告（面积代理，2026-11-05）

**这是什么**：对 283 个 RTL 模块逐个做通用门级综合（yosys + yosys-slang），得到每个模块的单元数、触发器数。
它是**相对面积代理**：用来比较"改动前后"和"哪里最大"，不是流片签核数字（没有工艺库、没有时序约束、没有布局）。

完整逐模块表：[synth/modules.csv](synth/modules.csv)。脚本：[../scripts/synth_module.sh](../scripts/synth_module.sh)。

## 1. 结论

| 项 | 数值 | 说明 |
|---|---|---|
| 模块总数 | 283 | 来自 `rtl_files.sh` 列出的全部 SV 文件 |
| 综合出数 | 265 | 逐模块扁平综合 |
| 纯连线（0 个单元） | 5 | `exu_ctrl_fu_in/out/view`、`exu_ctrl_lsu_req`、`dcache_cover` |
| 没综合出来 | 13 | 见第 4 节，用子模块加总推算 |
| 整机单元数（推算，下限） | **约 952 万个门** | 见第 3 节，不含 13 个失败模块自己的胶水逻辑 |
| 整机触发器（推算） | 约 18.1 万个 | |
| 存储块 | 364 个 `$mem` | 位数这次取不到，见第 5 节 |

最大的几块（推算，单位：门）：

| 区域 | 单元数 | 主要来源 |
|---|---|---|
| 后端 `u_core.u_back` | 约 700 万 | `isu` 212 万、`lsu_stlf` 109 万、`lsu_ring` 105 万 |
| 数据缓存 `u_mem.u_dcache` | 约 134 万 | 16 个 `dcache_bank` 约 114 万 |
| 前端 `u_core.u_front` | 约 66 万 | `icache` 57 万（含存疑的 `icache_arr`） |
| AXI `u_mem.u_axi` | 约 52 万 | `mem_axi` |

## 2. 方法和流程

每个模块单独作为顶层，`read_slang`（保持层次）→ 展平 → 手写的粗粒度优化 → `techmap` → ABC → `stat`。
设置（脚本里用环境变量开关）：

- `SYNTH_LIGHT=1`：轻量 ABC 脚本（`strash; map`），不用 yosys 默认的 ABC 脚本。
- `SYNTH_MEM=1`：存储阵列保留为 `$mem`，不展开成触发器。
- 不跑 `share`（SAT 资源共享）、不跑 `check`（组合环检查）。
- `SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob"`：放宽 slang 的循环展开上限，并把没走到的分支里的下标越界降为警告。
- 看门狗：每个模块最多 12 GB 内存、180 秒；单核顺序执行。

## 3. 整机推算怎么来的

`soc_top` 的整核综合不出来（门级网表太大）。做法：用 yosys 读入并展开整个设计（不综合），得到每个实例的层次路径；
对每个路径下"最外层、已经综合出数的实例"取其单元数相加（共 240 个实例）。

- 这是**下限**：失败模块自己的胶水逻辑（顶层连线、少量判断逻辑）没有算进去。
- 模块是按**默认参数**综合的，而实例的参数可能不同（例如 `isu_iq` 有 128 项和 64 项两种）。已知这会让个别模块的数字偏差，没有逐实例修正。

## 4. 没综合出来的 13 个模块

`soc_top`、`core_top`、`core_front`、`front_top`、`front_pred_path`、`bpu`、`bpu_tage`、`back_top`、`lsu`、`lsu_core`、`dcache`、`dcache_arr`、`mem_top`。

原因都是门级网表太大：`lsu`、`lsu_core`、`soc_top` 超过 12 GB 内存被杀，其余超过 180 秒。
它们都是包含大量子模块的聚合层，子模块各自有数字，第 3 节用的就是子模块的数字。
旧流程（默认 ABC）曾得到 `bpu` 87,815、`front_pred_path` 90,860，与统一流程不同口径，没有混进表里。

## 5. 数字的可信度和局限

- **相对值，不是绝对值**：通用门（`AND`/`NAND`/`MUX`/…）计数，没有工艺库。ABC 用的是轻量脚本，优化得比默认脚本少，所以数字偏大；同一个模块改前改后用同一流程比较才有意义。
- **存储位数取不到**：保留 `$mem` 后 `stat` 不打印存储位数，所以只有存储块个数（364）。存储本身的面积没有算进单元数，应该另外按位数估。
- **`icache_arr` 的 54 万个单元存疑**：其中约 27 万个 `$_MUX_`、26 万个 `$_NOT_` 的量级相当于整块存储的读多路选择器，可能是读口被展开成了逻辑。`icache`（57 万）包含它，所以 `icache` 也要打折看。
- **`isu` 的 212 万已核对，属实**：5 个发射队列（`IQ_INT` 128 项，其余 4 个 64 项，共 384 个槽）加总。每个槽有一个 `DW` 选 1 的 `ttg_onehot_mux` 写入选择，所以绝大多数是 `AND`/`NAND`。按槽数线性放大约 210 万，与实测相差约 4%。这是估算，不是分别综合每个队列的实测。

## 6. 综合过程中发现的问题

**yosys 的弱点（不是 RTL 写错，已在脚本里绕过）**

| 现象 | 例子 | 绕过 |
|---|---|---|
| 默认 ABC 脚本在深组合逻辑上跑不完 | `fpu_div`（7.4k 个门，28 级除法阵列） | 轻量 ABC，1 秒 |
| `share`（SAT）求解不收敛 | `lsu_dc_req_st`（189 万个 SAT 变量） | 不跑 `share`，17 秒 |
| `check` 在超宽向量上不收敛 | `icache_arr`（421 个单元、85 万线位） | 手写流程去掉 `check`，41 秒 |
| slang 对 `case` 里没走到的分支报下标越界 | `exu_ctrl_fu_in` | `-Wno-error=index-oob` |
| slang 对循环展开次数有上限 | `bpu_mem` | `--unroll-limit 100000` |

**RTL 写法问题（按 SV 规范应该改，已改，Verilator 本来放过）**

- [axi_subsys.sv:286](../rtl/memsys/axi_subsys/axi_subsys.sv)：`unused_hz` 把 unpacked 数组整体放进拼接，改成逐元素。
- [mem_top.sv](../rtl/memsys/mem_top/mem_top.sv)：`ax_mshr_*`、`ax_pa_*` 先用后声明，把声明挪到 `u_dcache` 实例之前。
- 验证：Verilator 全警告 lint 通过；改前改后各构建一个整核测试程序，跑 `atomic-boundary`，周期数 736、提交指令数 172，完全一致。只验证了一个程序，不是完整 smoke。

## 7. 面积上值得关注的点

- **发射队列入队选择**：每个槽对每条入队通道都有一套完整的选择（`isu_iq_store`），`isu` 的 170 万个 `AND`/`NAND` 基本来自这里。可考虑让每个槽只接一部分通道。（架构探索项，需要在 trace-model 里评估性能影响。）
- **LSU**：`lsu_stlf`（109 万）和 `lsu_ring`（单个 17.6 万个单元，共多个实例，合计 105 万）是后端第二、第三大。
- **数据缓存**：单个 `dcache_bank` 约 7.15 万个单元，16 个实例合计 114 万。

## 8. 复现

```bash
cd rtl
export SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob" SYNTH_LIGHT=1 SYNTH_MEM=1
bash scripts/synth_module.sh <模块名> 12000 180     # 结果在 build/synth/<模块名>.{log,stat}
```

yosys-slang 插件放在仓库之外：`/Users/ruyaoh/personal/yosys-slang/build/slang.so`（`SLANG` 环境变量可覆盖）。
