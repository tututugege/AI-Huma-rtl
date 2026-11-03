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

## 4. 与 C++ 的差异点和隐含依赖
- 无行为差异。需登记的参考模型怪异行为：
  1. (3.1 stale) `dec_bcast.redirect_rob_idx` 仅在 latch.mispred 时写，否则保留上拍值（从不清零）→ `idu_bcast` 里 `redirect_rob_idx_hold_q`。
  2. 丢弃（tag 不足）的 lane：uop 字段仍是译码结果，只有 valid/br_id/br_mask 被清零；非法/无效 entry 的 uop 全 0。
  3. flush 时 br_mask_cp 不清除也不更新（保持原值）；mispred 时仍做 clear_mask 对 cp 的清除。
  4. mispred 周期 dec2ren.valid 不被修改（可能已分配 tag），但 fire 全 0、tag 不提交。
  5. clear_mask 的 bit0（JAL 等 br_id=0 的已解析分支）被状态逻辑忽略，但原样广播；br_id=0 的 mispred 会用 cp[0]=0 回收全部在飞 tag（C++ 同，随机 trace 覆盖，真实程序未出现）。
  6. AMO(非 LR/SC)且 rd=x0 → dest_areg=32，dest_en 保持 1；LR/SC rd=x0 → dest_en=0。
  7. 系统指令：src2_is_imm=csr 立即数形式(funct3[2]&(f3[0]|f3[1]))对所有 SYSTEM 指令生效；未知 CSR 译成 NOP，访问 time/timeh 置 illegal。
  8. MAX_BR_PER_CYCLE=DECODE_WIDTH=8，上限不会额外生效；alloc 参数化保留。

## 5. 验证
- spec：`spec/idu.io`（55 字段，无 `when`）。
- trace：`traces/idu/` 64 个真实程序（61 gate + dhrystone/coremark/coremark10；gate 每个最多 100000 拍，大程序 300000 拍）共 1,323,970 条；
  另 8 条受约束随机 trace `rand0-7`（`tb/idu/gen_rand.cpp` 直接驱动参考模型 Idu 类，`bash tb/idu/build_gen.sh`，`build/tb/gen_rand out.trc seed 60000 profile`），共 480,000 条。
- 真实程序覆盖到：valid 0/1、ready 0/1、flush、EXU mispred(23445 次)、clear_mask(含 bit0)、一组最多 6 个分支、在飞分支最多 54、各 InstType（缺 SFENCE_VMA）、AMO LR/SC/其它、CSR 寄存器形式、is_ret、dec_bcast 保持。
  真实程序**未覆盖**：page-fault entry、tag 不足 stall、AMO rd=x0、CSR 立即数形式、SFENCE_VMA、br_id=0 的 mispred、mispred 与 flush 同拍、mispred 时 ready=1、issue 组内空洞。这些全部由随机 trace 覆盖（stall 72320 拍，page fault 63147 个，最多 63 个在飞）。
- 变异（均已被抓到，括号为首个抓到的 trace/字段/记录号）：
  - M1 rank 含自身（add-longlong, dec2ren_uop_br_id[0], rec 56）
  - M2 younger_tags 取反（add-longlong, dec2ren_uop_br_mask[0], rec 126）
  - M3 fire 忽略 latch_mispred（rand0, idu_consume_fire[0], rec 5）—— 仅随机 trace 能抓到
  - M4 去掉 redirect_rob_idx 保持（add-longlong, dec_bcast_redirect_rob_idx, rec 62）
  - M5 AMO rd=x0 改名条件错（rand0, dec2ren_uop_dest_areg[7], rec 4）—— 仅随机
  - M6 cp 清除失效（add-longlong, dec2ren_uop_br_mask[0], rec 259）
  - M7 time CSR 不置 illegal（rand0, illegal_inst[5], rec 4）—— 仅随机
  - M8 page fault 仍译码（rand0, dest_areg[0], rec 12）—— 仅随机
  - M9 clear bit0 不屏蔽（add-longlong, br_id[3], rec 112）
  - M10 immB 位序错（add-longlong, imm[2], rec 199）
  - M11 丢弃 lane 的 br_mask 不清零（rand1, br_mask[3], rec 294）—— 仅随机
  - M12 CSR 立即数形式不屏蔽 src2_en（rand0, src2_en[6], rec 12）—— 仅随机
