# isu 综合深度 / 面积回退分析（lsu-pipe-rtl-main vs main 5829f07）

> **更新（2026-11-12）**：这是 2026-11-09 前后对 `lsu-pipe-rtl-main` 分支的一次性综合深度分析，数字是当时的值，没有随后续改动更新。

范围：只看 `isu` 单模块综合（`scripts/synth_depth.sh`，yosys-slang + ABC 通用门，`ltp -noff` 打印最长路径）。所有实验在临时拷贝里做（`git archive` 解出），分支和工作区没有改动。
基线复现：main 1,166,243 / 182；分支 1,346,857 / 199（与 lsu-pipe.md 第 13 节完全一致，综合是确定性的）。

## 1. 结论

**+17 层、约 +164k 门几乎全部来自 `lsu2iss_cancel_*`（推测唤醒的取消）这一个钩子**，而它在默认配置（`LP_L2 = 1907`，位 3 = 0）下是死逻辑：
LSU 侧 `lp_wake.sv` 里位 3 关闭时 `spec_w = 0`，`cn_q` 恒 0，但 `isu` 单独综合时 `lsu2iss_cancel_valid/preg` 是自由输入，没有常量折叠，于是每个 IQ 表项里的
`cancel_v[src_preg]`（128:1 选择，每表项 2 个，共 240 个表项 = 480 个）全部被综合出来，并且插在 `slot_ready` 之前、选择器（select）之前，成为新的关键路径起点。
用 `generate if ((lp_pkg::LP_L2 & 8) != 0)` 把 cancel 真正编译掉：**1,182,147 / 181**（深度回到基线 -1，门数 -12.2%）。

## 2. 关键路径（signal chain）

| | 路径 |
| --- | --- |
| main（182） | `g_iq[0].u_store.g_slot[0].uop_q[3]`（IQ_INT 表项 op，flop）→ 就绪/op 类译码 → `u_read.sel[0]`（第 7 层）→ 选择器 / 端口选取 → `iss2prf_iss_entry_valid[5]`（第 85 层）→ 空闲槽计数/分配 `enq_slot[465]`（第 100 层）→ `enq_slot[116]`（153）→ `enq_slot[63]`（166）→ `g_slot[63].write`（168）→ `valid_d`（182）→ `valid_q` |
| 分支（199） | **`lsu2iss_cancel_preg[24]`（输入，第 0 层）→ 7→128 译码 → `cancel_v[105]`（第 6 层）→ 每表项 `cancel_v[uop_q.src_preg]` 128:1 选择 + `wait_c` → `slot_ready` → `u_read.sel[0]`（第 25 层，main 是第 7 层，**+18**）→ 同一条选择/分配链 → `iss2prf_iss_entry_valid[5]`（102）→ `enq_slot[467]`（120）→ `enq_slot[116]`（171）→ `enq_slot[63]`（184）→ `write`（185）→ `valid_d`（199）→ `valid_q` |
| 去掉 cancel（181） | 与 main 相同：`uop_q[3]` → `sel[0]`（7）→ `candidate`（43、51）→ `valid`（84）→ `enq_slot`（101、152、165）→ `write`（167）→ `valid_d`（181） |

后半段（选择 → 分配 → write → valid_d，约 160 层）两边是同一条逻辑，只是起点被 cancel 前面多加的约 18 层推迟；末端 +17。

## 3. 归因表（isu 单模块，同一脚本，每行只改一处）

| 版本 | 内容 | 门数 | 层数 | 相对 main |
| --- | --- | --- | --- | --- |
| O  main 5829f07 | 基线 | 1,166,243 | 182 | - |
| A  分支原样 | 全部钩子 | 1,346,857 | 199 | +180,614 / +17 |
| D  推测唤醒通道（前 NLD 路）编译掉，cancel 保留 | | 1,345,818 | 198 | +179,575 / +16 |
| C  cancel 编译掉，8 路 LSU 唤醒（含推测 4 路）保留 | | 1,183,194 | 181 | +16,951 / -1 |
| B  按 `LP_L2` 位 3 整体编译掉（cancel + 推测 4 路），L3 4 路保留 | **修复版** | 1,182,147 | 181 | +15,904 / -1 |
| F  LSU 唤醒与 cancel 全部去掉 | 理论下限 | 1,180,879 | 181 | +14,636 / -1 |

| 原因 | 层数 | 门数 |
| --- | --- | --- |
| `cancel_v` 译码 + 480 个表项内 128:1 选择 + `wait1_c/wait2_c` 进 `slot_ready`（`isu.sv` u_cancel、`isu_iq_store.sv`） | **+17 ~ +18** | **约 +164k（A-B = 164,710）** |
| 推测唤醒前 4 路通道 `wake[0..NLD)` 未折叠（`woken_lsu` 第 2 条总线） | 0 | 约 +1k（B 与 C 之差） |
| L3 唤醒 4 路（`wake[NLD+p]`，位 0/1 开启，真实功能） | 0 | 约 +1.3k（B-F） |
| 其余（见下） | -1 | 约 +14.6k（F-O，1.25%） |

"其余"在 isu 里没有找到对应逻辑改动（F 里 LSU 唤醒与 cancel 都是常量 0，`wait*_c` 折叠回 `wait*_q`，`isu_wake_bus` 参数化后功能不变），判断为 ABC 对网表结构/命名顺序的差异（约 ±1% 量级的噪声），不当作设计原因。
dispatch 里同样有 cancel 钩子（`dispatch_core` 的 `busy_table | cancel_v`、`dispatch_busy_table`），并且 `NUM_WAKE` 多了 `2*LDU` 路，与 dispatch 82,244 / 44 对 72,586 / 46 的 +9.7k 门相符，本次没有单独综合，处理方式相同。

## 4. 回答问题：关闭的推测唤醒逻辑是否被综合进来

是。端口 `lsu2iss_cancel_*` 是 isu 的输入，`LP_L2` 位 3 只在 LSU 内部起作用，isu 里没有任何 `generate if` 依赖它，所以 isu 单独综合时 cancel 路径（以及推测唤醒的 4 路）完整保留。
整核里如果 `lsu_pipe` 和 `isu` 一起展平，`cn_q` 常量 0 会被 yosys 传播掉，不会有这个代价；但分层综合 / 层次保留的流程（`synth_depth.sh` 的方式、也是后端常见做法）看不到这个常量。
所以这 +17 层主要是"死逻辑没有编译掉"，不是 LSU_PIPE 功能本身的代价。

## 5. 修复清单

1. **（必做，预期 -17 层 / -164k 门）** 在 `isu.sv` 用 `LP_L2` 位 3 做 generate-if，关闭时 `cancel_v = '0`，`woken_lsu` 只接后 NLD 路。
   实验补丁（已在 B 版验证，1,182,147 / 181）：
   ```systemverilog
   if ((lp_pkg::LP_L2 & 8) != 0) begin : g_spec
     isu_wake_bus #(.N(2*LSU_LDU_COUNT)) u_wake_lsu (...lsu2iss_wake_*..., .woken(woken_lsu));
     isu_wake_bus #(.N(LSU_LDU_COUNT))   u_cancel   (...lsu2iss_cancel_*..., .woken(cancel_v));
   end else begin : g_nospec
     // L3 wake-up only: lsu2iss_wake_*[NLD +: NLD]
     for (genvar p = 0; p < LSU_LDU_COUNT; p++) begin : g_l3
       assign l3_valid[p] = lsu2iss_wake_valid[LSU_LDU_COUNT + p];
       assign l3_preg[p]  = lsu2iss_wake_preg[LSU_LDU_COUNT + p];
     end
     isu_wake_bus #(.N(LSU_LDU_COUNT)) u_wake_lsu (.wake_valid(l3_valid), .wake_preg(l3_preg), .woken(woken_lsu));
     assign cancel_v = '0;
   end
   ```
   `isu_iq_store` 不用改（`cancel_v` 常量 0 后 `wait*_c` 自动折叠）；想更干净可把 `cancel_v` 端口也放进 generate（省一个常量传播）。
2. **（必做，同理）** `dispatch.sv` / `dispatch_core.sv` / `dispatch_busy_table.sv` 的 `cancel_v` 也按位 3 编译掉；`NUM_WAKE` 的 `2*LSU_LDU_COUNT` 在位 3 关闭时改成 `LSU_LDU_COUNT`（只留 L3 4 路），预期 dispatch 门数再降约几 k（该项未量化）。
3. **（重新打开推测唤醒时用，目前不需要）** 不要用 `cancel_v[src_preg]` 的 128:1 选择：每个表项把自己的两个源号与 4 个 cancel 号做比较（4×7 位比较，约几十门，对比 128:1 选择的约 340 门），并且 `cn_valid/cn_preg` 在 LSU 里本来就是寄存器输出，
   可在 LSU 内把 `cancel_v` 128 位译码结果也寄存，isu 内只剩比较或一次 AND-OR；这样推测唤醒开启时深度增量约为 4~6 层（译码层消失）而不是 17 层。是否值得做要等推测唤醒重新验证（lsu-pipe.md 12.4：1915 未在合并树上验证）后再定。
4. **（可选，面积 -1.3k）** L3 4 路唤醒并入 `isu_wake_src` 的主总线（`N = WAKE_NUM + NLD`），省一次 `woken_main | woken_lsu` 合并；对深度无影响，收益在噪声内，不建议单独做。

## 6. 复现

临时拷贝在 `/private/tmp/claude-501/-Users-ruyaoh-personal-AI-Huma/76c7eb6c-d693-45f6-9fc2-5e97a09d3da1/scratchpad/{old,new,newB,newC,newD,newF}`；
命令 `cd <copy> && JOBS=1 bash scripts/synth_depth.sh <tag> isu`（约 4~5 分钟/次，输出 `build/synth_<tag>/isu.{stat,ltp}`）。main 拷贝里没有 `synth_depth.sh`，是从分支拷过去的。

## 修复已落地（lsu-pipe-rtl-main）

`isu.sv` 的 `u_wake_lsu`/`u_cancel` 与 `dispatch.sv` 的 `cancel_v` 按 `lp_pkg::LP_L2 & 8`（推测唤醒）做 generate：位 3 为 0 时 `cancel_v = '0`，`woken_lsu` 只接 L3 的 4 路，被丢弃的输入用 `unused_*` 收尾（lint 0 警告）。`LP_L2 & 8` 非零时代码与原来相同。

| 模块 | main | 修复前 | 修复后 |
|---|---|---|---|
| isu | 1,166,243 / 182 | 1,346,857 / 199 | **1,182,207 / 181** |
| dispatch | 72,586 / 46 | 82,244 / 44 | 78,791 / 46 |

验证：`lint.sh` 316 文件 0 警告、`lint_chip.sh` 0；`fm_gate.sh`（预取开，`SOC_FM=1` 重新构建）67/67 PASS，周期与 `ref_cycles.txt` 相同（差异 0）。预取关未重跑（本改动只删默认配置下恒为 0 的逻辑）；`LP_L2=1915` 的 generate 分支未单独 lint/仿真（代码与原来相同）。
