---
module: dcache_pf
area: memsys
rtl: rtl/memsys/dcache/dcache_pf.sv
model: trace-model MemSubSystem/include/DataPrefetcher.h（类 `DataPrefetcher`，`RealDcache` 的成员 `pf`，没有自己的调度单元；它的 `seq()` 由 `RealDcache::seq()` 调用）
status: 整核周期与模型逐个相等（EXP-062：4 级流水化硬件 Berti，rv64gc Linux 26/26 窗 PT/UP 逐拍全等 + SPEC06 386 点 +0.51%）
depth: 75 层（EXP-062 优化后：Yosys `384→75` 层，拆测 `berti_hist` 33 / `berti_gen` 49 / `berti_tab` 75；**TSMC 28nm HPC+ DC `ssg0p81v125c` `0.50ns`：`WNS -2.23→-0.35 ns`、`0.37→1.18 GHz`、`172→53 lvl`、面积 `184,092→147,594 um²`，见 09-synthesis-report 第 15 节**）
---

# dcache_pf 设计文档

## 1. 职责

L1 数据缓存的预取器，硬件化 **Berti（16 路去重历史表 + 虚拟地址增量 + 复用 LSU 空闲 DTLB 口跨页翻译）**（EXP-048 M3，对应模型 `DataPrefetcher` `PF_KIND=4` `BertiHw`；替代旧 `h1` 全局步长器）。核心结构全部采用有界硬件表与每拍单操作流水：
- **历史表与延迟测量**（`dcache_pf_berti_hist`）：8 组 × 16 路 FIFO 历史表，按 `(pc, vline)` 全组去重保留最早时间戳；16 项在途需求缺失表 `infl`、16 项在途预取发包表 `pf_issue`、64 项预取填充延迟表 `pf_lat`、20 位循环周期计数器 `cyc_q`、4 项搜索队列 `srch_q`。
- **每 PC 增量表**（`dcache_pf_berti_tab`）：16 项全相联 PC 表（4 位精确 LRU），每项 16 个有符号 7 位增量槽（`-63..+63`）；每拍至多执行 1 次搜索（16 槽并行命中累加 + 至多 2 个新增量分配），满 16 次搜索结算状态（`cov >= 11` → L1，`cov >= 6` → LLC，其余清零）。
- **候选生成与跨页翻译队列**（`dcache_pf_berti_gen`）：16→1 锦标赛选择器每拍发射 1 个候选（L1 优先、覆盖率高优先，突发度 `DEG=12`）；同页候选直接拼物理页帧进 8 项请求 FIFO `reqq`，跨页候选进 8 项去重 VA 队列 `xq` 送 LSU 空闲 load DTLB 口翻译，命中结果经 8 项 `xans_q` 回填 `reqq`。

它在模型里不是调度单元：`DataPrefetcher`（`PF_KIND` 默认 4，即 `BertiHw`）的输入由 `RealDcache::stage2` 写入，输出（队头）被 `RealDcache::stage1` 读，状态在 `RealDcache::seq` → `pf.seq()` 里更新。

## 2. 配置（现行默认）

常量都是各文件里的局部参数（`localparam`），不在 `ttg_cfg_pkg` 里；改动要改代码。

| 项 | 值 | 常量（文件） |
| --- | --- | --- |
| 请求 FIFO（`reqq`） | 8 项，去重 | `QD = 8`、`QW = 3`（`dcache_pf.sv`） |
| 训练事件 FIFO（`trnq`） | 4 项；每拍最多压入 2 个 load 事件、弹出 1 个 | `TRNQ_N = 4`（`dcache_pf.sv`） |
| 周期计数器 | 20 位，循环 | `cyc_q`（`dcache_pf.sv`） |
| 历史表 | 8 组 × 16 路，FIFO 替换，组号 = `pc[9:1]` 三段异或 | `HSETS = 8`、`HWAYS = 16`（`dcache_pf_berti_hist.sv`） |
| 在途需求缺失表 / 预取发出表 / 预取延迟表 | 16 / 16 / 64 项 | `INFL_N`、`PFI_N`、`PFL_N`（同上） |
| 搜索队列 | 4 项 | `SRCHQ_N = 4`（同上） |
| 增量范围 | 有符号 7 位，`-63..+63` 行，不为 0 | `srch_d`（同上） |
| PC 增量表 | 16 项全相联 PC × 每项 16 个增量槽，4 位精确 LRU | `DPCS = 16`、`DDELTAS = 16`（`dcache_pf_berti_tab.sv`） |
| 结算 | 每项每 16 次搜索结算一次：覆盖数 `≥ 11` → 进 L1（`st = 1`），`≥ 6` → 只进 LLC（`st = 2`），其余不发（`st = 0`） | `ROUND = 16`、`HI_COV = 11`、`LO_COV = 6`（同上） |
| 突发 | 每次触发最多 12 个候选，每拍 1 个 | `DEG = 12`（`dcache_pf_berti_gen.sv`） |
| 跨页 VA 队列 / 翻译结果队列 | 8 / 8 项 | `XQN = 8`、`XAN = 8`（同上） |
| 行号位数 | 26（物理地址 `[31:6]`） | `LINE_W`（`dcache_pkg`） |
| MSHR 保留 | 0：只要有空项就能分配 | `dcache.sv`：`pf_free = mshr_free - ld_alloc_cnt - st_alloc_cnt`，`pf_ok = pf_cand & (pf_free != 0)` |
| 总开关 | RTL 无（固定开；原参数 `PF_EN` 2026-11-28 删除） | 模型：环境变量 `PF_ENABLE`（0 关闭） |

## 3. 接口

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 出 | `head_valid`、`head_line`、`head_llc` | `reqq` 队头：非空、行号、是否只进 LLC |
| 入 | `head_taken` | `dcache_s1` 这拍把队头送去探测了，下一拍弹出；不是只进 LLC 的那一个同时记入预取发出表（测延迟用） |
| 入 | `fill_valid`、`fill_line`、`fill_is_pf` | `dcache_s2_fill` 本拍的填充：需求填充用来量需求缺失延迟，预取填充用来量预取延迟 |
| 入 | `acc_valid / acc_line / acc_pc / acc_va / acc_miss / acc_pf_hit [NLD]` | 本拍第二级各 load 口的访问事件：物理行号、load 的 PC（32 位）、虚拟地址（39 位）、是否未命中、是否第一次用到预取行 |
| 出 | `pf_xq_v / pf_xq_va [38:0] / pf_xq_llc [NLD]` | 跨页候选：`xq` 队头最多 `NLD` 项的虚拟地址，送 LSU（`lp_l1`）借空闲 load 口的 DTLB 翻译 |
| 入 | `pf_xq_pop [2:0]` | LSU 本拍取走了几项（0..`NLD`） |
| 入 | `pf_xans_v / pf_xans_line / pf_xans_llc [NLD]` | 翻译成功的结果（物理行号），进 `xans` 队列 |

`dcache.sv` 总是实例化本模块。

## 4. 结构

```
 acc_* (≤2/拍) ─► trnq[4] ─(每拍 1 个)─┬─► dcache_pf_berti_hist ─(搜索结果)─► srch_r_q（寄存）─► dcache_pf_berti_tab（更新）
                                        └─► dcache_pf_berti_tab（触发读）─► dcache_pf_berti_gen ─┬─(同页)──────────► reqq[8] ─► head_*
 fill_* / head_taken ─► hist 的延迟测量                                              └─(跨页) xq[8] ─► LSU DTLB ─► xans[8] ─┘
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `dcache_pf.sv` | 185 | 顶层：周期计数器、训练 FIFO `trnq`、请求 FIFO `reqq`（去重）、三个子模块的连接、hist→tab 之间的寄存级 `srch_r_*_q` |
| `dcache_pf_berti_hist.sv` | 277 | 历史表（按组全组去重）、在途需求缺失表 `infl`、预取发出表 `pfi`、预取延迟表 `pfl`、搜索队列 `srchq`；每拍对搜索队列头做一次 16 路"及时增量"搜索 |
| `dcache_pf_berti_tab.sv` | 284 | 每 PC 增量表：两级流水（T1 查 PC、16 槽并行命中计数；T2 选出两个空位插入未命中的新增量、满 16 次结算）；触发读直接读寄存的表 |
| `dcache_pf_berti_gen.sv` | 268 | 突发生成：16 选 1 锦标赛（4 级二叉树），同页候选拼物理页号进 `reqq`，跨页候选进 `xq`（去重）；`xans` 结果优先进 `reqq` |

状态（全部寄存器）：`cyc_q`（20 位）；`trnq_q[4]`（PC、虚拟行号、物理行号、VA 符号位、是否未命中）；`reqq`：`q_line_q[8]`（26 位）、`q_llc_q[8]`、`q_head_q`、`q_cnt_q`；`srch_r_*_q`；hist：`hist_q[8][16]`（PC、行号、20 位时间戳）、`infl_q[16]`、`pfi_*_q[16]`、`pfl_*_q[64]`（12 位延迟）、`srchq_q[4]`；tab：16 项 PC、每项 16 个增量槽（增量、覆盖数、上轮覆盖数、`st`）、`cnt_q[16]`（5 位搜索计数）、LRU；gen：`gen_mask_q`、`gen_left_q`、`gen_vline_q`、`gen_ppn_q`、每槽增量 / `st` / 覆盖数，`xq_*_q[8]`、`xa_*_q[8]`。

## 5. 一拍内的数据流

1. **事件入队**：按 load 口顺序取前 2 个"未命中或首次使用预取行"的访问（`ttg_first_set` 两次），压入 `trnq`（满了丢弃）；`trnq` 非空时每拍弹出队头 1 个，作为本拍的训练 / 触发事件。
2. **历史与延迟**（`dcache_pf_berti_hist`）：需求未命中记入 `infl`（带时间戳）；需求填充命中 `infl` 时得到需求延迟，产生一次搜索；预取填充按 `pfi` 里的发出时间算出预取延迟存进 `pfl`；第一次用到预取行时用 `pfl` 里的延迟产生一次搜索。每个训练事件都按 `(pc, 虚拟行号)` 记进历史表（组内 FIFO 替换），同组已有同一条则不再记（保留最早的时间戳）。
3. **搜索**：搜索队列头与它所在组的 16 路历史逐路比较：同 PC、时间差不小于测得的延迟（"及时"）、行号差非 0 且在 `-63..+63` 内的路有效；16 个增量去重（同值只留最低路）。`srch_stall`（寄存级占用）时本拍不搜索。结果打一拍（`srch_r_*_q`）后送增量表。
4. **增量表更新**（`dcache_pf_berti_tab`）：T1 按 PC 查表（未命中按 LRU 选牺牲项），已有的增量槽并行加覆盖数；T2 插入最多 2 个没命中的新增量，位置先取无效槽，再取 `st == 0` 里覆盖数最低的槽（4 级二叉树选最小两个）；该 PC 满 `ROUND = 16` 次搜索时按覆盖数结算每槽的 `st` 并清计数。
5. **触发**：本拍弹出的训练事件按 PC 读增量表（读寄存的表，不经本拍更新），`st != 0` 的槽组成 `trig_mask`，非空则 `trig_go`。
6. **生成**（`dcache_pf_berti_gen`）：`trig_go` 时装载新突发（`gen_left = DEG = 12`，覆盖旧突发）；否则每拍用锦标赛选出键最大的槽（键 = `{st == 1, 覆盖数}`，即进 L1 的优先、覆盖数高的优先，同键低号赢），目标行 = 触发行 + 增量。同页：直接拼触发时的物理页号，进 `reqq`（`st == 2` 的标为只进 LLC）；跨页：虚拟地址进 `xq`（与队内页号比较去重），之后由 LSU 翻译，结果回 `xans`。`xans` 有结果时优先进 `reqq`，本拍同页候选让路。用掉的槽从 `gen_mask` 清掉。
7. **`reqq` 去重与写入**：`head_taken` 先弹出；候选与弹出后的各项逐项比行号，相同或已满则丢弃，否则写到 `head + cnt`。

## 6. 关键路径与深度

旧的 h1 步长预取器：单模块综合深度 **74 层**（2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。现行 Berti 的数字见文件头 `depth:`（EXP-062：Yosys 75 层，`berti_tab` 最深）；本节没有重新测量。从代码读出的长路径（未综合验证）：

- **增量表**：T2 的"选两个插入位置 + 写表"和触发读之后的 `trig_mask`；EXP-062 已把 PC CAM 与 16×16 匹配切到 T1，与 T2 之间加寄存；
- **生成器**：16 选 1 锦标赛树 → 目标行加法（7 位低位和判断是否跨页，上一页 / 下一页页号与锦标赛并行预先算好）→ `xq` 去重（页号比较也与锦标赛并行）；
- **`reqq` 去重**：`push_line` 与 8 项逐项比较后才决定 `do_push`。

## 7. 与模型的差异和取舍

- 开关：模型是环境变量 `PF_ENABLE`（和 `PF_KIND`，默认 4 = 本设计），RTL 固定开（原参数 `PF_EN` 已删除），没有其他预取器可选；
- 模型的 `PF_BERTI_HWALLOC`（每次搜索最多分配几个新增量）在 RTL 里固定为 2；
- 模型的统计（`PfStats`、`PF_STATS`）是性能统计，RTL 没有；
- 模型 `BertiHw` 的注释写明它是本 RTL 的"每拍一个操作"规格，各表大小与 RTL 局部参数一一对应；
- 事件选择："前 2 个事件"在两边都按 load 口顺序。

模型里看起来不一致的地方：本次没有逐项核对。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh`（77 个程序，周期逐个等于 `scripts/ref_cycles.txt`）。预取行为影响周期，所以周期相等同时验证了预取器；直接的预取程序有 `pf-stress`、`directed/memspec_pf.bin`。
- **关闭预取**：RTL 没有关预取的构建（2026-11-28 删了参数 `PF_EN` 和 `scripts/ref_cycles_nopf.txt`）；模型里关预取的门禁（`PF_ENABLE=0`，`baseline_nopf.csv`）照旧，用于研究。
- **Linux**：`scripts/linux_gate.sh` 的 PMU 序列对比。
- **Lint**：`scripts/lint_chip.sh`。
- **没有模块级独立测试**。**待补**：给 `dcache_pf` 加一个和模型 `BertiHw` 并排的随机事件流测试（输入访问 / 填充 / `head_taken` / 翻译结果序列，比较 `reqq` 队头和 `xq` 序列），改深度时用。

## 9. 参数与开关速查

`dcache_pf` 的 `QD`、`QW`、`TRNQ_N`；`dcache_pf_berti_hist` 的 `HSETS`、`HWAYS`、`INFL_N`、`PFI_N`、`PFL_N`、`SRCHQ_N`；`dcache_pf_berti_tab` 的 `DPCS`、`DDELTAS`、`ROUND`、`HI_COV`、`LO_COV`；`dcache_pf_berti_gen` 的 `DEG`、`XQN`、`XAN`（都是局部参数）；`NLD`、`LINE_W`（`dcache_pkg`）。

## 10. 变更记录

- 2026-11-28 清理：删参数 `PF_EN`（`soc_top` / `chip_top` / `mem_top` / `dcache`，默认 1、没有脚本覆盖）及 `dcache` 的 `g_nopf` 分支，预取器固定实例化（周期不变）。
- 2026-11-28（文档核对，无 RTL 变化）：第 2–7 节按现行 Berti RTL（`dcache_pf` + `dcache_pf_berti_hist / tab / gen`）重写，删掉旧 h1 步长预取器的描述（见 git 历史）；文件表补上三个 Berti 子模块；门禁参考改为 `scripts/ref_cycles.txt`。
- 更早：EXP-062 四级流水化硬件 Berti；EXP-048 M3 硬件 Berti 替换 h1；预取器引入于 EXP-009。见 git 历史。
