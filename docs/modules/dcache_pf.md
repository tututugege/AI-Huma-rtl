---
module: dcache_pf
area: memsys
rtl: rtl/memsys/dcache/dcache_pf.sv
model: trace-model MemSubSystem/include/DataPrefetcher.h（类 `DataPrefetcher`，`RealDcache` 的成员 `pf`，没有自己的调度单元；它的 `seq()` 由 `RealDcache::seq()` 调用）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 74 层（dcache_pf，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# dcache_pf 设计文档

## 1. 职责

L1 数据缓存的预取器，冻结设计 "h1"（EXP-009，模型头文件注释称它是 RTL 的规格）。它做三件事：

1. **训练**：看 load 口第二级的访问事件，每拍最多取 2 个，事件是"L1D 未命中"或"第一次用到被预取进来的行"。用一个全局的（不分 PC、只有一条）步长表项检测步长；
2. **生成候选**：步长置信度够了就发一串步长预取（"步长突发"，8 个候选，从触发行之后 2 个步长处开始，不跨 4 KiB 页）；另有一个"下一行"引擎，每次 load 未命中后给下一行发一个候选，这一行只进 LLC，不填进 L1D；
3. **请求队列**：候选进一个 8 项 FIFO（同一行去重，满了丢弃），队头交给 `dcache_s1` 借一个空闲的 load 口做 tag 探测；探测不命中、MSHR 有空项时，由 `dcache` 顶层在 MSHR 里分配一个预取项（见 dcache.md）。

它在模型里不是调度单元：`DataPrefetcher` 的输入由 `RealDcache::stage2` 写入（`acc[]`），输出（队头）被 `RealDcache::stage1` 读，状态在 `RealDcache::seq` → `pf.seq()` 里更新。

## 2. 配置（现行默认）

| 项 | 值 | 来源（模型常量 / RTL 常量） |
| --- | --- | --- |
| 请求 FIFO 深度 | 8 | `PF_QUEUE` / `QD`，指针 `QW = 3` |
| 每拍训练事件数 | 2 | `PF_TRAIN_PORTS` / `NTR` |
| 突发候选数 | 8 | `PF_DEGREE` / `DEGREE`，剩余计数 4 位 |
| 起始距离 | 2 个步长 | `PF_DIST`；RTL 里写死成左移一位（`{sx(stride)[LINE_W-2:0], 1'b0}`） |
| 置信度阈值 | 2 | `PF_CONF_THR`；RTL 里写死成 `st_conf_d >= 2'd2`，置信度 2 位，上限 3 |
| 步长位数 | 8 位有符号（单位：行） | `PF_STRIDE_BITS` / `SB` |
| 下一行引擎行数 | 1 | `PF_LLC_LINES`；RTL 里 `g2` 没有计数器，隐含为 1 |
| 行号位数 | 26（`addr[31:6]`） | `PF_LINE_BITS` / `LINE_W`（`dcache_pkg`） |
| MSHR 保留 | 0：只要有空项探测就能分配 | `PF_MSHR_RESERVE`；RTL 里 `pf_free = mshr_free - ld_alloc_cnt - st_alloc_cnt`，`pf_ok = pf_cand & (pf_free != 0)`（`dcache.sv`） |
| 总开关 | 参数 `PF_EN`（默认 1；`soc_top` 传入） | 模型：环境变量 `PF_ENABLE`（0 关闭，`DataPrefetcher::enabled_`） |

没有准确率节流、没有来自 LSU 的 PC（模型头文件注释说明这是有意的）。

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 出 | `head_valid`、`head_line`、`head_llc` | FIFO 队头：非空、行号、是否只进 LLC |
| 入 | `head_taken` | `dcache_s1` 这拍把队头送去探测了，下一拍弹出 |
| 入 | `acc_valid/acc_line/acc_miss/acc_pf_hit [NLD]` | 本拍第二级各 load 口的访问事件：未命中（含合并进在途 MSHR 项的）、或第一次使用预取行。重发的请求和隐藏重试不产生事件（`dcache_s2_ld` 里 `dem` 要求 `!slot_perf_replay`、来自 LSU、不是探测） |

`PF_EN = 0` 时 `dcache.sv` 不实例化本模块，`pf_head_valid` 等恒为 0（`g_nopf`）。

## 4. 结构

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `dcache_pf.sv` | 214 | 全部：FIFO、步长表项、两个生成器、训练输入寄存器 |

状态（全部寄存器）：

- FIFO：`q_line_q[8]`（26 位）、`q_llc_q[8]`、`q_head_q`、`q_cnt_q`；
- 步长表项：`st_valid_q`、`st_last_q`（上次的行号）、`st_stride_q`（8 位）、`st_conf_q`（2 位）；
- 步长突发生成器 `g_*`：有效、下一行 `g_next_q`、基准行 `g_base_q`（页检查用）、步长、剩余次数；
- 下一行生成器 `g2_*`：有效、下一行、基准行（页检查用）；
- 训练输入寄存器：`in_valid_q/in_miss_q/in_line_q [2]`（上一拍选出的事件，这一拍才用来训练，使训练不在第二级的路径上）。

## 5. 一拍内的数据流

顺序与模型 `DataPrefetcher::seq` 一致（RTL 里是同一个组合块的几段，随后统一打入寄存器）：

1. **弹出**：`head_taken` 为真则队头出队（`cnt_a`、`head_a`）；
2. **步长生成器**：有效则占用 FIFO 的写口；下一行与基准行不在同一页（行号 `[25:6]` 不同）则作废，否则推入候选 `g_next_q`（`llc = 0`），`g_next` 加一个步长，剩余次数减一，到 0 作废；
3. **下一行生成器**：写口没被步长生成器占用时才工作；同页则推入候选 `g2_next_q`（`llc = 1`），然后作废；
4. **去重与写入**：候选与弹出后的 FIFO 项逐项比较行号，相同则丢弃；FIFO 满则丢弃；否则写到 `head_a + cnt_a`。生成器的 `g_next`、`g_left` 不管候选是否被丢弃都照常推进（与模型 `push_candidate` 一致）；
5. **训练**（对上一拍寄存的 2 个事件按顺序依次处理）：
   - 未命中事件：启动下一行生成器（基准行 = 本行，下一行 = 本行 + 1）；
   - 步长表项无效则以本行建立（步长 0、置信度 0）；否则 `d = 本行 - st_last`：`d == 0` 不更新；`d` 在 8 位有符号范围内且等于已存步长则置信度加一（上限 3）；否则置信度大于 0 就减一，减到 0 且 `d` 在范围内则采用 `d` 作为新步长；置信度已是 0 则直接以 `d`（不在范围内则为 0）为步长；更新 `st_last`；置信度 ≥ 2 且步长非 0 则启动步长突发（基准行 = 本行，起点 = 本行 + 2 个步长，剩余 8 次）；
6. **选择新事件**：按 load 口顺序取前 2 个"未命中或首次使用预取行"的访问，寄存起来供下一拍训练，多余的丢弃。

## 6. 关键路径与深度

单模块综合深度 **74 层**（dcache_pf；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\st_last_q [1]` 到 `\g_next_q [24]`。。从代码读出的，未综合验证：

- **FIFO 去重**：写入候选 `push_line`（由生成器状态直接给出）与 8 项逐项比较后，才决定 `do_push`；
- **训练**：两个事件在同一个组合块里依次串行更新步长表项（第二个事件看第一个的结果），行号减法、范围判断、置信度更新、突发启动串起来，是组合链最长的部分；
- 预取器的输入全部走寄存器（`in_*_q`），第二级的 load 路径不经过它；它只把 `head_*` 给 `dcache_s1`，`head_line` 是 8 选 1 的读出。

## 7. 与模型的差异和取舍

- 开关：模型是环境变量 `PF_ENABLE`，RTL 是参数 `PF_EN`；
- 配置常量里 `PF_DIST`、`PF_CONF_THR`、`PF_LLC_LINES` 在 RTL 中是写死的结构（见第 2 节），改这些常量要改代码；
- 模型的 `PfStats`（issued、useful、late 等）是性能统计，RTL 没有；PMU 的预取事件在 RTL 里另有来源（本次没有核对）；
- 模型的 `pf::Table` / `pf::Fifo` 有"每拍固定端口数、违反则中止"的建模规则检查，RTL 由结构本身保证；
- 事件选择："第一个 `PF_TRAIN_PORTS` 个事件"在两边都按 load 口顺序。

模型里看起来不一致的地方：无。

未核对（继承自旧文档）：旧文档中的预取收益数字（IPC 提升）未带入；PMU 预取事件的来源未核对。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh`（67 个程序，周期逐个等于 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`）。预取行为影响周期，所以周期相等同时验证了预取器；直接的预取程序有 `pf-stress`、`directed/memspec_pf.bin`。
- **关闭预取的参考**：`scripts/ref_cycles_nopf.txt`（模型 `PF_ENABLE=0`，RTL `SOC_VOPT="-GPF_EN=0"`；文件头日期 2026-11-16，不在当前门禁里，本次没有运行）。
- **Linux**：`scripts/linux_gate.sh` 的 PMU 序列对比。
- **Lint**：`scripts/lint_chip.sh`。
- **没有模块级独立测试**。**待补**：给 `dcache_pf` 加一个和模型 `DataPrefetcher` 并排的随机事件流测试（只需事件序列和 `head_taken` 序列，输出队头序列对比），改训练逻辑深度时用。

## 9. 参数与开关速查

`PF_EN`（`dcache`、`mem_top`、`soc_top` 参数）；`dcache_pf` 内部局部参数 `QD`、`QW`、`SB`、`DEGREE`、`NTR`；`NLD`、`LINE_W`（`dcache_pkg`）。

## 10. 变更记录

本分支未改动，更早：见 git 历史（预取器引入于 EXP-009）。
