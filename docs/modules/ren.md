# ren 设计笔记

## 1. 对应的 C++
- 文件/类：`back-end/Ren.cpp`、`back-end/include/Ren.h`，`class Ren`（参考模型 commit 2f31e8d）。BackTop 调用顺序：
  `comb_begin`（状态镜像）→ `comb_alloc`（idu/csr 之后）→ `comb_rename`（dis->comb_wake 之后）→ `comb_fire`（dis->comb_fire 之后）→ `comb_pipeline` → `seq`。
- 输入（spec `in`）：
  - `dec2ren`：`valid[8]` 与 `uop[8]` 的全部非调试字段（24 个字段，原样穿过 Ren 送往 Dispatch）；
  - `dec_bcast`：`mispred`、`br_id`、`clear_mask`（`br_mask`/`redirect_rob_idx` Ren 不读）；
  - `dis2ren.ready`；`rob_bcast`：`flush`、`interrupt`；
  - `rob_commit.commit_entry[8]`：`valid` 以及 uop 的 `dest_en/dest_areg/dest_preg/old_dest_preg/type/page_fault_{inst,load,store}/illegal_inst`。
- 输出：`ren2dec.ready`；`ren2dis.valid[8]`、`ren2dis.uop[8]` 全部非调试字段（含 `src1_busy/src2_busy`，Ren 恒为 0，由 Dispatch 填）。
- 不翻译：perf 计数、`BE_LOG`、`ctx->run_commit_inst/difftest/ckpt`、`getenv("CT")`、`Assert`/`ren_freelist_sanity`、`tma/dbg` 字段。

## 2. 硬件结构
```
 dec2ren ──► ren_inst_pipe (inst_r/inst_valid) ──► ren_alloc_sel ◄── ren_free_list (window,count)
                 │                                     │
                 │ (inst, valid)               alloc_reg/alloc_valid
                 ▼                                     ▼
          ren_handshake (stall链, fire, ren2dec.ready)   ren_dep_check ◄── ren_rat (读spec_RAT)
                 │ fire                                    │ src1/src2/old_dest
                 ▼                                         ▼
        alloc_fire / br_fire ──► ren_rat (写spec_RAT, snapshot[i]) ──► ren_ckpt (RAT+head 按br_id)
        rob_commit ──► ren_commit_filter ──► ren_free_list(回收) / ren_rat(arch_RAT)
```
- `ren.sv`：只做端口适配（平铺端口 ⇄ `ren_inst_t/ren_commit_t/ren_out_uop_t`），`ren_core.sv`：连线与字段视图。
- `ren_inst_pipe`：Rename 级流水寄存器（8 槽 `ren_inst_t` + valid）及其下一状态（kill > take_new > hold）。
- `ren_free_list`：128×7b 环形空闲表 + `head`（推测分配）/`head_commit`/`tail`。读口：从 head 起连续 8 项（`window`）；写口：commit 回收按 `tail+rank` 写入，同一条目多写用 `ren_last_write`。
- `ren_alloc_sel`：“取前几个空闲寄存器”。`ttg_first_set` 级联：第 k 个请求者（在槽位序中）拿 `window[k]`，且仅当 `k < free_count`；无 for+break+运行计数器。
- `ren_handshake`：stall 链 = 第一个“要 preg 却没分到”的槽位及其后全部阻塞（`ttg_first_set` + `~(x-1)` 求高位掩码）；`fire=valid&dis_ready`；`ren2dec.ready`。
- `ren_dep_check`：组内 RAW/WAW 旁路；对每个槽 i 和三个键（src1/src2/old_dest），在更老且 `valid&dest_en&dest_areg!=0` 的槽里取“最近的”（`ren_last_write`：最高下标命中者优先）。
- `ren_rat`：spec_RAT/arch_RAT（各 33×7b）。读口 24 个（8 槽×{dest,src1,src2}）：areg 独热解码 + 独热 mux（areg>32 读 0）。写：同拍后面槽位覆盖前面（`ren_last_write`）；`snapshot[i]` = 槽 0..i 写完后的 spec_RAT（供分支槽 i 做检查点）。恢复优先级 flush > mispred > 正常。
- `ren_ckpt`：64 个 br_id 各存 `{alloc_checkpoint_head, RAT_checkpoint}`（238b），8 个写口（同 tag 取高槽），1 个读口（读**旧值**，与 C++ 读 `RAT_checkpoint` 而不是 `_1` 一致）。
- `ren_commit_filter`：每个 commit 槽 `reclaim = valid & dest_en & !exception & !interrupt`；`rank`（前面有几个回收）与 `total` 用 `ttg_popcount`。
- `ren_last_write`：“后写者赢”的优先级选择原语（本目录原语，前缀 `ren_`）。
- 状态一览：`spec_RAT/arch_RAT` 33×7b，`free_list` 128×7b，3 个 7b 指针，`checkpoint` 64×(231+7)b，`inst_r` 8×~330b + `inst_valid` 8b。

### C++ → 硬件对应
| C++ | RTL |
| --- | --- |
| `free_list[local_head]`、`local_free_count--` 循环 | `window[k]` + `ren_alloc_sel` 的 first_set 级联 + `free_count>k` |
| `stall` 逐槽传播 | `ren_handshake` 的 `first_fail` 高位掩码 |
| `for j<i` 旁路，后者覆盖前者 | `ren_dep_check` + `ren_last_write` |
| `spec_RAT_1[dest]=…` 逐槽顺序写 | `ren_rat` 每个 areg 一个 `ren_last_write`，`snapshot[i]` 为前缀版本 |
| `LOOP_INC(free_head_1)` 每个 fire 的 dest | `ttg_popcount(alloc_fire)` |
| 提交 `free_list_1[free_tail_1++]` | `write_ptr = tail + rank`，每个条目按地址命中 |
| `RAT_checkpoint_1[br_id][j]=spec_RAT_1[j]` | `ren_ckpt` 写口：snapshot[i]，head = head + popcount(alloc_fire[i:0]) |

## 3. 一拍内的数据流
所有 `ren_*` 输入来自 BackTop 的外部量，Ren 内部没有 stale 读：`comb_alloc`/`comb_rename` 只读寄存器（`inst_r/spec_RAT/free_list/head/tail`）和同拍已定的输入；`comb_fire` 读 `dis2ren.ready`、`rob_commit`、`rob_bcast`、`dec_bcast`（在 BackTop 里全在它之前定型，`rob_bcast.flush` 在 `rob->comb_commit` 内置位，`rob->comb_flush` 在后面只动 ROB 自己，replay 全绿即证实）。
数据流：
1. `window,free_count`（寄存器）→ `alloc_reg/alloc_valid` → `ren2dis.valid`（stall 链）、`fire`。
2. `rd_preg`（RAT 旧值）+ `alloc_reg` → `ren2dis.uop.{src1,src2,old_dest}_preg`。
3. `fire`+`alloc_reg` → spec_RAT 次态、`snapshot[]`、检查点写、`head` 前进；commit → `reclaim/rank/total` → arch_RAT、free_list 回收、`tail/head_commit`。
4. 恢复（`comb_fire` 末尾覆盖前面的结果）：
   - `flush`：`spec_RAT←arch_RAT_1`（含本拍 commit），`head←head_commit_1`；`tail` 仍含本拍回收。
   - `mispred`（且无 flush）：`spec_RAT←RAT_checkpoint[br_id]`（**旧值**），`head←alloc_checkpoint_head[br_id]`（旧值），`tail←tail`（旧值，丢弃本拍回收，见 4）。
5. 流水寄存器：`kill`（flush|mispred）：valid 清零、payload 保持；`ren2dec.ready`：整组采样 `dec2ren`（无条件对 `br_mask &= ~clear_mask`，不看 valid）；否则 `valid&=~fire`，仅对仍 valid 的槽清 `clear_mask`。

## 4. 与 C++ 的差异点和隐含依赖
- **无功能差异**（0 个 DEVIATION）。
- 参考模型怪异行为/需如实复现的点：
  1. 检查点在 `fire` 的同一拍写入，且在 `mispred`/`flush` 拍同样写入（C++ 先写 `RAT_checkpoint_1` 再恢复），RTL 一致；恢复读的是**旧**检查点（`RAT_checkpoint`/`alloc_checkpoint_head`），不是同拍新写入的。
  2. `mispred` 分支 `free_tail_1 = free_tail`：丢掉本拍 commit 的 tail 前进，却保留 `head_commit_1` 前进与 `free_list_1` 写入（Ren.cpp comb_fire 末尾）。若同拍有回收则 `ren_freelist_sanity` 会失败；**trace 中从未出现 mispred 且有回收的拍**（见覆盖），RTL 照 C++ 复现，但此路径无验证。
  3. 分配可在 `flush/mispred` 拍 fire（`ren2dis.valid` 不看 flush），随后被恢复覆盖；RTL 同样不屏蔽。
  4. `old_dest` 旁路对 `dest_en=0` 的槽也会计算（不影响输出，因输出照常比较，已一致）。
  5. `ren2dis.uop[*].dest_preg = alloc_reg`：未分配则为 0；非 valid 槽仍输出 `inst_r`（上一组残留）派生的字段，spec 里**不使用 `when`**，故残留值也逐位比较（`inst_r` 在 `kill` 拍保持，仅 `ren2dec.ready` 拍整体采样 dec2ren）。
  6. 越界：areg 为 6 位而 RAT 只有 33 项，C++ 读 areg>32 是越界（读到相邻成员）。trace 中 dec2ren 的 areg 从未>32，RTL 读 0（未验证）。
  7. `RAT_checkpoint`、`free_list[95..127]` 在 `init()` 中未初始化，RTL 复位为 0；不可观察（读前必先写）。
  8. PRF_NUM=128、MAX_BR_NUM=64=2^BR_TAG_WIDTH，指针在位宽内自然回绕；改配置为非 2 的幂需重写回绕。
- `ren_pkg.sv` 带 `lint_off UNUSEDPARAM`（与生成的 `ttg_cfg_pkg` 相同理由：常量由其他文件使用，单独 lint 包文件会报未使用）。
- `ren_pkg.sv` 放在子目录 `rtl/backend/ren/pkg/` 以保证 `scripts/lint.sh`、`replay.sh` 按排序给文件时先于使用者。

## 5. 验证
- spec：`spec/ren.io`（共 73 个字段：输入 41、输出 32；输出含全部 ren2dis uop 字段，无 `when`）。
- trace：64 个程序（61 gate + dhrystone + coremark + coremark10 等 progs.txt），1,819,218 条记录（扣除每个 trace 的 3 个复位拍后 1,819,026 拍参与统计）。
- 覆盖（脚本统计）：`dec2ren.valid` 取 0..8 全部个数；`dis2ren.ready` 0/1；`flush` 619 次；`mispred` 23524 次；`interrupt` 5 次（均有 commit 同拍）；`clear_mask≠0` 551022 拍；分配失败导致 ren2dec 拉低 10985 拍；分支同拍 fire 多个 141825 拍；`fire` 同拍 flush/mispred 共 184 拍；同拍 RAW/WAW 旁路（src1 358 万、src2 167 万、old_dest 236 万次，多个更老写者 157 万次）；commit 回收 1..8 个均出现；57 个程序累计分配 ≥128（free list 指针回绕）。
- **未覆盖**：①`mispred` 与 commit 回收同拍（0 次）；②`flush` 与 `mispred` 同拍（0 次，C++ 注释称不会同时发生）；③ commit 的 `dest_en` 且异常（page fault/illegal/ECALL）的指令（0 次，只有 10 次无 dest 的异常 commit）；④ dest_areg==0 且 dest_en 的槽（x0 旁路规则，0 次，解码级把 x0 的 dest_en 清掉）；⑤ areg==32/ >32；⑥ 同拍两个分支用相同 br_id。
- 变异检查（每个都对全部 64 个 trace 回放；首个失败 trace 的首个分歧）：
  | 变异 | 结果 |
  | --- | --- |
  | M1 src1 旁路只看紧邻上一槽（不取最近的任意更老槽） | 抓到：zfinx rec=79 `ren2dis_uop_src1_preg[2]`，63 个 trace 失败 |
  | M2 分配可用数多算一个（`free_count+1>k`） | 抓到：rec=174 `ren2dis_valid[7]`/`dest_preg[6]`，9 个 trace |
  | M4 检查点的 head 不含本槽自己的分配 | 抓到：rec=195 `src1_preg[3]`/`old_dest_preg[2]`，7 个 trace |
  | M6 保持路径不清 `clear_mask` | 抓到：test rec=279 `ren2dis_uop_br_mask[0]`，22 个 trace |
  | M7 mispred 读错 br_id（tag^1） | 抓到：rec=75 `src1_preg[3]`，64 个 trace |
  | M9 流水寄存器 kill 不含 mispred | 抓到：rec=134 `ren2dis_valid[0]`/`br_mask[0]`，57 个 trace |
  | M12 flush 时 head 取旧 `head_commit_q`（不含本拍回收） | 抓到：dummy rec=33 `dest_preg[0]`，64 个 trace |
  | M3 flush 与 mispred 优先级对调 | **存活**（trace 无同拍 flush&mispred，C++ 称不会发生） |
  | M5 ECALL 不算异常 | **存活**（ECALL 无 dest，不触发 reclaim 差异；dest_en 的异常 commit 0 次） |
  | M8 mispred 时 tail 不回滚 | **存活**（无 mispred 与回收同拍） |
  | M11 允许 x0 目的旁路 | **存活**（解码已清掉 x0 的 dest_en） |
  另有 5 个变异（free_count `>=`、interrupt 忽略、page-fault 忽略等）因 -Wall 未使用信号告警而无法编译，已丢弃，不计入。存活的 4 个都对应上面“未覆盖”列表。
