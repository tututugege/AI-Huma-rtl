# idu 设计笔记

## 1. 对应的 C++
- `back-end/Idu.cpp`、`include/Idu.h`（参考模型 2f31e8d）。BackTop 调用序：comb_begin → comb_branch → comb_decode → comb_fire → seq。
- 输入：PreIduQueue 发射组(valid/inst/page_fault_inst/ftq_*)、`ren2dec.ready`、`rob_bcast.flush`、`exu2id.*`。pc 只进 dbg，不翻译。
- 输出：`dec2ren`(valid + uop)、`dec_bcast`、`idu_consume.fire`、`br_latch`（BackTop 读 redirect_pc，PreIduQueue 读 mispred/ftq_idx）。
- `uop.tma.mem_commit_is_load/store` 被 Rob 读取，故保留 tma 四个字段；dbg 不翻译。expect_mask/cplt_mask 恒 0。

## 2. 硬件结构
```
 entries[8] -> idu_decoder x8 (idu_ctrl_decode: 类别 one-hot + ROM；idu_imm_gen)
                   |is_branch                 tag_free_q -> idu_br_alloc (8 级 find-first-set 链)
                   v                                            | alloc_oh[8]
               idu_br_group: rank=更老分支数 -> 取第 rank 个空闲 tag；无 tag 则该 lane 及更年轻 lane 丢弃；
                   br_mask = base | 更老分支 tag 前缀 OR           -> lane_valid/br_id/br_mask/tag_oh/cp_mask
               idu_fire_ctl: fire = valid & ready & ~flush & ~latch_mispred；提交 tag
               idu_br_state: tag_free_q(64), now_br_mask_q(64)；优先级 flush > mispred 回收 > 提交
               idu_br_cp:    checkpoint 表 63x64 (tag0 不存在)，8 写口(按 tag 独热)，1 读口(br_id)
               idu_br_latch: EXU 结果打一拍，flush 清零
               idu_bcast:    dec_bcast；redirect_rob_idx 保持寄存器
```
- C++ 数组对应：tag_vec→tag_free_q（bit0 恒 0）；now_br_mask→now_mask_q；br_mask_cp[64]→cp 表；br_latch→idu_br_latch。
- 译码：C++ 的 switch+if 链改为 27 类互斥 one-hot + 常量 ROM（AND-OR mux）；立即数 7 种候选独热选择。

## 3. 一拍内数据流
- 状态(tag_free_q/now_mask_q/latch)和输入 → 译码、tag 分配、br_mask 前缀 OR → dec2ren。
- comb_fire 全用当拍状态：mispred 回收用状态里的 now_br_mask 与 cp[br_id]（非清除后值）；清除后再被 alloc 覆盖（alloc 优先于 clear）。
- 分配的 tag 取自 tag_vec（未含本拍 clear 释放的 tag）。

## 4. 简化（06 等价性原则）：消费者核对 + 放宽 / 删除 / 不复刻
### 4.1 放宽为 `when`（RTL 无效时直通，不清零、不保持）
| 字段 | 限定 | 消费者核对 |
| --- | --- | --- |
| dec2ren_uop_*（全部 uop 字段，含 br_id/br_mask） | dec2ren_valid | 唯一读取点 Ren.cpp:393-394 把 uop 连同 valid 采样到 inst_r，之后 Ren/Dispatch 均以 inst_valid 限定（Ren.cpp:109,121,179 等） |
| dec_bcast_redirect_rob_idx | dec_bcast_mispred | 仅 Rob.cpp:639-659，位于 `if (mispred && !flush)` 内 |
| dec_bcast_br_mask | dec_bcast_mispred | Prf.cpp:8 is_killed 先判 mispred；Isu.cpp:444/473、Exu.cpp:346-349 均 flush_br/mispred 限定 |
| dec_bcast_br_id | dec_bcast_mispred | 仅 Ren.cpp:342-343，mispred 分支内 |
| br_latch_redirect_pc | br_latch_mispred | BackTop.cpp:346 → rv_simu_mmu_v2.cpp:1167/1438 均 `mispred \|\| flush` 才读；flush 时用别的来源 |
| br_latch_ftq_idx | br_latch_mispred | PreIduQueue.cpp:225-227 在 `else if (mispred)` 内 |
严格比较：dec2ren_valid、idu_consume_fire、dec_bcast_mispred、dec_bcast_clear_mask、br_latch_mispred，以及 valid 时的全部 uop 字段。
### 4.2 删除的字段
- dec2ren expect_mask / cplt_mask：Idu 恒 0，Dispatch.cpp:99/217 自行赋值。
- dec2ren tma.is_cache_miss：Idu 恒 0，无读取点；tma.is_ret：只在 types.h:223 拷贝，无读取点。保留 tma.mem_commit_is_load/store（Rob.cpp:26,30）。
- br_latch br_id / redirect_rob_idx / clear_mask 输出：无外部读取点（外部只读 mispred、redirect_pc、ftq_idx）；它们的作用经 dec_bcast 体现。
### 4.3 选择不复刻的 C++ 行为
1. `dec_bcast.redirect_rob_idx` 在非 mispred 时保留旧值：无消费者 → 删除 hold 寄存器。
2. 无效 entry 的 uop 全 0、tag 不足被丢弃 lane 的 br_id/br_mask 清零而其余字段保留：均被 valid 保护 → 直通。
3. br_latch 其余负载在 flush 时清零：只有 mispred 与 clear_mask 影响状态，仅这两个被 flush 清零；负载无条件打拍。
4. flush 时 br_mask_cp 保持不变：flush 后在飞掩码为 0，checkpoint 在 tag 再次分配时才会被读到 → 不特殊处理（clear 每拍照做，写口覆盖）。随机 trace 的 mispred br_id 因此限定为在飞 tag 或 0（空闲 tag 的 br_id 不可达）。
5. mispred 拍 dec2ren.valid 不变（可能带着预分配 tag）：valid 是严格输出，所以仍与 C++ 一致，没有额外硬件。
### 4.4 仍严格复刻（有意义，含疑点）
- 疑点：br_id=0 的 mispred 用 cp[0]=0，回收所有在飞 tag（含更老的）。真实程序未出现，随机 trace 覆盖；按 06 第 5 节保持 C++ 行为，请协调者登记 deviations 疑点栏。
- clear_mask 的 bit0 被状态逻辑忽略但原样广播。
- AMO rd=x0 → dest_areg=32；未知 CSR 译 NOP、time/timeh 置 illegal；SYSTEM 的 src2_is_imm 规则；page-fault entry 译成全 0 NOP（保守复刻，未逐字段核对 Ren 对 NOP 字段的读取）。
- tag 从 tag_vec（未含本拍 clear 的释放）分配；alloc 优先于 clear。

## 5. 验证
- spec：`spec/idu.io`（48 字段；34 个输出中 dec2ren_uop_*、dec_bcast 3 个、br_latch 2 个带 when）。
- trace：`traces/idu/` 64 个真实程序（gate ≤30000 拍，dhrystone/coremark/coremark10 100000 拍）+ 8 个随机 trace，共 981,741 条，全部 PASS。随机 trace：`bash tb/idu/build_gen.sh`；`build/tb/gen_rand out.trc seed 60000 profile(0-7)`，直接驱动参考 Idu 类。
- 真实程序未覆盖（由随机 trace 补）：page-fault entry、tag 不足 stall、AMO rd=x0、CSR 立即数形式、SFENCE_VMA、br_id=0 mispred、mispred 与 flush 同拍、mispred 时 ready=1、发射组空洞。
- 变异（均被严格比较字段抓到）：
  - 分支 rank 含自身（add-longlong，dec2ren_uop_br_id[0]，rec 56）
  - younger_tags 取反（add-longlong，dec2ren_uop_br_mask[0]，rec 130）
  - fire 忽略 latch_mispred（rand0，idu_consume_fire[0]，rec 11）
  - AMO rd=x0 条件错（rand0，dec2ren_uop_dest_areg[7]，rec 4）
  - time CSR 不置 illegal（rand0，illegal_inst[5]，rec 4）
  - page-fault 仍译码（rand0，dest_areg[1]，rec 34）
  - clear bit0 不屏蔽（add-longlong，br_id[3]，rec 112）
  - immB 位序错（add-longlong，imm[2]，rec 199）
  - dec_bcast br_id 位错（add-longlong，dec_bcast_br_mask，rec 61；when 字段在 mispred 时仍被比较）
  - 另有一个 `x & ~(x-1)` 的“变异”实为等价改写，已弃用。
