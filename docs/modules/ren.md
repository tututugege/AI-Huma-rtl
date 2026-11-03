# ren 设计笔记

## 1. 对应的 C++
- 文件/类：`back-end/Ren.cpp`、`back-end/include/Ren.h`，`class Ren`（参考模型 commit 2f31e8d）。BackTop 调用顺序：
  `comb_begin`（状态镜像）→ `comb_alloc`（idu/csr 之后）→ `comb_rename`（dis->comb_wake 之后）→ `comb_fire`（dis->comb_fire 之后）→ `comb_pipeline` → `seq`。
- 输入（spec `in`）：
  - `dec2ren`：`valid[8]` 与 `uop[8]` 中有消费者的字段（22 个，除 src/dest areg 供重命名外都原样穿过 Ren）；
  - `dec_bcast`：`mispred`、`br_id`、`clear_mask`（`br_mask`/`redirect_rob_idx` Ren 不读）；
  - `dis2ren.ready`；`rob_bcast`：`flush`、`interrupt`；
  - `rob_commit.commit_entry[8]`：`valid` 以及 uop 的 `dest_en/dest_areg/dest_preg/old_dest_preg/type/page_fault_{inst,load,store}/illegal_inst`。
- 输出：`ren2dec.ready`；`ren2dis.valid[8]`、`ren2dis.uop[8]` 中有消费者的字段（见第 4 节）。
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
- `ren_inst_pipe`：Rename 级流水寄存器（8 槽 `ren_inst_t` + valid）；valid 按 kill > take_new > hold，payload 只跟 take_new。
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
5. 流水寄存器（简化后）：valid：`kill`→0，`ren2dec.ready`→`dec2ren.valid`，否则 `valid&~fire`；payload：`ren2dec.ready` 时取 `dec2ren.uop`，否则保持；`br_mask` 一律 `&= ~clear_mask`。无效槽的 payload 是无关值，不设计 kill 保持/hold 只清有效槽这类特殊优先级。

## 4. 简化清单：放宽 / 删除 / 不复刻（docs/06 第 6 节）

### 4.1 放宽（`when ren2dis_valid`）及消费者核对
`ren2dis_uop_*`（全部 24 个字段）在 `ren2dis_valid[i]=0` 时不比较。核对（Dispatch.cpp，参考模型 2f31e8d）：
- `ren2dis.valid[i]` 进 `Dispatch::inst_valid_1[i]`（Dispatch.cpp:743），`ren2dis.uop[i]` 进 `inst_r_1[i]`（:744）；
- 之后 `inst_r[i]` 的每个读取点都受 `inst_valid[i]` / `dis2rob->valid[i]`（= `inst_valid`）/ `dis_fire[i]`（= `basic_fire`，含 `dis2rob->valid`）保护：
  :103、:123（`inst_valid && is_load/is_store`）、:205（`!inst_valid` 即 continue）、:306/:324、:386–388（`inst_valid ? type : NOP`）、:413、:444–445（`dis_fire && dest_en`）、:456、:585、:604–626（在 `!dis2rob->valid[i]` 且 `inst_valid` 的统计分支内，且仅用于 perf 统计）。
- 唯一没有显式 `inst_valid` 保护的 `:397 is_CSR(inst_r[i].type)` 只会把 `basic_fire` 置 false，而无效槽的 `basic_fire` 本来就是 false（`dis2rob->valid[i]=inst_valid[i]`），`csr_blocked` 只在 `inst_valid` 分支被使用，所以无效槽的 type 不影响行为。
- `:91 inst_alloc[i] = from_ren_dis_inst(inst_r[i])` 对所有槽拷贝，但 `inst_alloc[i]` 的消费者同样受 valid/dis_fire 保护（:94/:205/:306/:324）。
结论：无效槽的 `ren2dis_uop_*` 无消费者。RTL 因此不再为无效槽保留残留负载：`ren_inst_pipe` 删掉“kill 保持负载只清 valid / hold 只清有效槽 mask”的特殊路径；`dest_preg` 对无效槽也不再特意清 0（它仍是 `alloc_reg`，只是不比较）。
有效槽的 `src1_preg/src2_preg/old_dest_preg/dest_preg` 仍严格比较（不再按 `src_en/dest_en` 细分：Dispatch.cpp:938 的 AMO 路径把 `inst.dest_preg` 当作 STD 的 src1，我没有逐一证明所有路径都受 `dest_en` 保护，所以保守处理）。

### 4.2 删除的字段（spec 与端口）及理由
- `dec2ren_uop_expect_mask/cplt_mask`（in）与 `ren2dis_uop_expect_mask/cplt_mask`（out）：Ren 不读；Dispatch.cpp:99–100、:227–228 把它们覆写为 0/自己算的值，ROB 用的是 Dispatch 的结果，`ren2dis` 里的值无消费者。
- `ren2dis_uop_src1_busy/src2_busy`：Ren 恒为 0（`from_dec_ren_inst` 不设置，memset 0），Dispatch.cpp:162–163 用 `busy_table` 重新计算并覆写，无消费者。
- `ren2dis_uop_src1_areg/src2_areg`：下游没有读者（grep 全后端：只在 `types.h/Rob.h/Dispatch.h` 的结构定义里出现，无 `.cpp` 读取）。`dest_areg` 保留（ROB 提交回送给 Ren 做 arch RAT 更新）。
- 输入侧：`dec2ren` 的 `src1_areg/src2_areg/dest_areg` 保留（重命名要用），`dec_bcast.br_mask/redirect_rob_idx`、`tma/dbg` 本来就没接。
- 记录量：spec 73 → 65 字段；trace 重新录制（gate 30000 拍、dhrystone/coremark/coremark10 各 100000 拍），旧 1.3GB trace 已删。

### 4.3 选择不复刻的 C++ 行为（06 第 4 节）
1. `mispred` 时 `free_tail_1 = free_tail`（丢弃本拍 commit 的 tail 前进，却保留 `head_commit_1` 前进）：若同拍有回收则 C++ 自己的 `ren_freelist_sanity` 会失败 → 不可达。RTL 写最自然的行为：回收总是在 tail 追加。随机 trace 生成器也避开“mispred 与有回收的 commit 同拍”（C++ 会 Assert）。
2. 检查点在 `flush/mispred` 拍也照写：被写的 tag 属于被杀掉的年轻指令，tag 在重新分配前必先被重新写入，不可观察 → RTL 不特意屏蔽（无条件写，最省）。恢复读旧检查点自然成立（读 `_q`，写入在下一拍才生效）。
3. areg>32 的越界读：解码器只产生 0..32（32 = AMO 目的为 x0 时的特殊编号），不可达；RTL 读 0（独热 mux 的自然结果），不复刻。
4. `RAT_checkpoint`、`free_list[95..127]` 的未初始化：RTL 复位为 0，读前必先写，不可观察。
5. 同拍 `x0` 旁路特判：C++ 在 `dest_areg==0` 时不旁路；解码器 `Idu.cpp:548 if (dest_areg==0) dest_en=false`，所以 `dest_en` 为真时 `dest_areg!=0` 恒成立，特判是死代码 → 删除（`ren_dep_check` 少一个比较器）。
6. 异常/interrupt commit 不回收 old_dest、不更新 arch RAT 等**有意义**行为全部保留（`ren_commit_filter`）。
7. 流水寄存器：不复刻“kill 保持 payload”“hold 路径只对 valid 槽清 mask”等只影响无效槽的细节（4.1）。
8. PRF_NUM=128、MAX_BR_NUM=64 为 2 的幂：指针自然回绕。RTL 里没有加仿真参数断言（`$error` 被规范 §1 禁止；如需断言请协调者定方案）。
- 没有任何“有疑点、按 C++ 实现”的条目，`deviations.md` 无需登记。

## 5. 验证
- spec：`spec/ren.io`，65 个字段（输入 39、输出 26）。
- trace：61 gate（≤30000 拍）+ dhrystone/coremark/coremark10（100000 拍）+ 4 个随机 trace（`tests/ren/rand_trace.cpp`，`bash tests/ren/run_rand.sh`；驱动参考模型 `Ren` 类，外围用小 ROB 模型保证激励合法，且**不定义 NDEBUG**，C++ 的 Assert 全开，生成不崩即激励合法）。
- 真实程序覆盖（简化前统计）：`dec2ren.valid` 0..8、`dis2ren.ready` 0/1、flush 619、mispred 23524、interrupt 5、clear_mask≠0 551022、分配失败 10985、同拍多分支 fire、同拍 RAW/WAW 旁路（多个更老写者）、回收 1..8、free list 指针回绕。
- 随机 trace 补上的缺口（4×100000 拍统计）：flush 与 mispred 同拍 24 次；dest_en 且 ECALL 的 commit 2060 次，dest_en 且 page-fault/illegal 的 commit 8570 次；interrupt 与 commit 同拍 2292 次；areg==32 的 fire 93334 次；分配失败 23618 拍；mispred 同拍有无回收 commit 1277 次（只含无回收的）；flush 同拍有回收 8714 次；同拍多分支 fire 116652 拍。
- 仍未覆盖（刻意）：mispred 与有回收的 commit 同拍（C++ 自己不允许）；areg>32；同拍两个分支同 tag。
- 变异检查：见下表（由脚本对全部 68 个 trace 回放）。

| 变异（对 68 个 trace 回放，首个失败） | 结果（均为严格比较字段，且 `ren2dis_valid` 有效时） |
| --- | --- |
| M1 src1 旁路只看紧邻上一槽 | 抓到：zfinx rec=79 `src1_preg[2]`（67 个 trace 失败） |
| M2 可用 preg 数多算一个 | 抓到：rec=174 `ren2dis_valid[6]`（11 个） |
| M3 flush 与 mispred 优先级对调 | 抓到（原先存活）：随机 trace rec=27721 `old_dest_preg[0]`（4 个，仅随机 trace） |
| M4 检查点 head 不含本槽分配 | 抓到：rec=195 `src1_preg[3]`（11 个） |
| M5 ECALL 不算异常 | 抓到（原先存活）：rec=18 `dest_preg[7]`（4 个，仅随机 trace） |
| M6 take_new 路径不清 clear_mask | 抓到：rand_d rec=4 `br_mask[1]`（4 个，仅随机 trace；真实程序里 clear_mask 与新采样同拍的位被 Dispatch 立刻清掉所以不暴露） |
| M7 mispred 读错 br_id | 抓到：rec=75 `src1_preg[3]`（68 个） |
| M9 流水寄存器 kill 不含 mispred | 抓到：wfi-boundary rec=134 `ren2dis_valid[0]`（59 个） |
| M12 flush 时 head 取旧 `head_commit_q` | 抓到：dummy rec=33 `dest_preg[0]`（68 个） |
| M13 异常 commit 仍回收 | 抓到：rec=29 `dest_preg[6]`（4 个，仅随机 trace） |
| M14 interrupt 只在 page_fault_inst 时屏蔽回收 | 抓到：rec=171 `src1_preg[3]`（6 个） |
| M15 areg 32 不更新 RAT | 抓到：rand_d rec=6 `old_dest_preg[4]`（4 个，仅随机 trace） |
12/12 被抓到；上一版存活的 M3/M5（及等价于已删 x0 规则、已删 tail 回滚的变异）要么靠随机 trace 现在被抓到，要么对应已删除的死代码/不可达行为。
