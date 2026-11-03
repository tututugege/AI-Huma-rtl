# prf 设计笔记

## 1. 对应的 C++
- 文件/类：`back-end/Prf.cpp`、`back-end/include/Prf.h`，`class Prf`（参考模型 commit 2f31e8d）。
- BackTop 调用顺序：`comb_begin`(277) → `comb_complete`(空) → `comb_awake`(289) → `comb_write`(290) →
  … → `comb_req_ftq`(323) → `pre->comb_ftq_lookup_prf` → `comb_read`(325) → … → `comb_pipeline`(391) → `seq`。
- 输入（spec 里 `in`；简化后删去 `ftq_prf_pc_resp.resp[].valid`）：
  - `dec_bcast`：mispred、br_mask、clear_mask（br_id/redirect_rob_idx 未被读）
  - `rob_bcast.flush`
  - `iss2prf.iss_entry[22]`：valid + uop 全部字段（除 dbg）
  - `exe2prf.entry[22]`：valid + uop{dest_preg,result,br_mask,dest_en,op}
  - `exe2prf.bypass[28]`：valid + uop{dest_preg,result,dest_en}（br_mask/op 未被读）
  - `ftq_prf_pc_resp.resp[10]`：pc、pred_taken、next_pc
- 输出（`out`）：`ftq_prf_pc_req.req[10]`、`prf_awake.wake[4]`、`prf2exe.iss_entry[22]`。
  其他模块不直接读 Prf 成员（`reg_file` 仅被 BackTop 的 checkpoint 恢复/difftest 路径写入，不属于 RTL 边界）。
- 端口命名：BackTop 线名 + 字段路径，例如 `iss2prf_iss_entry_uop_dest_preg[i]`、`exe2prf_bypass_valid[k]`。
- 位宽：PRF_IDX 7，UOP_TYPE 5（`UOP_LOAD`=3），BR_MASK 64，ISSUE_WIDTH 22，TOTAL_FU 28，FTQ_PRF_PC_PORT 10，LSU_LOAD_WB_WIDTH 4。

## 2. 硬件结构（简化后）
```
 exe2prf.entry ─▶ prf_wb_pipe ─(wb_*_q: wen/is_load/dest_preg/result/br_mask x22)─┬▶ prf_write_arb ─▶ prf_regfile (128x32)
 dec_bcast/flush ┘                                                                  ├▶ prf_awake ─▶ prf_awake_wake_*
 iss2prf src_preg ─▶ prf_regfile 读口(2x22) ─▶ prf_bypass x44 (prf.sv generate) ◀──┘ + exe2prf.bypass
 iss2prf ─▶ prf_pc_port(请求条件) ─▶ ftq_prf_pc_req；ftq_prf_pc_resp 按口直连回发射口
```
- `prf.sv`：端口适配（透传 uop、44 个 bypass 实例的 generate、PC 口接线）。
- `prf_wb_pipe`：22 路写回级寄存器。只保存"写寄存器的结果"：`wen = !flush && valid && dest_en && !被误预测杀`，
  载荷（dest_preg/result/br_mask/is_load）每拍直接采样 Exu 输出，不做无效槽保持。
- `prf_write_arb`：每个物理寄存器：命中的写口 AND-OR（无优先级），`reg_wr_en = |hits`。
- `prf_regfile`：128x32，2x22 异步读口。
- `prf_bypass`：`!src_en||preg==0 → 0；有 FU/WB 命中 → 命中数据（AND-OR）；否则寄存器堆`。
- `prf_pc_port`：只算 4+6 个口的请求条件（ALU 口需 src1_is_pc 且 op∈ALU，BR 口需 op∈BR）。
- `prf_awake`：写回级里未被杀的 load，按口序压缩进 4 个唤醒槽（前缀 popcount + 独热选择）。

## 3. 一拍内的数据流
- 读（`comb_read`/`comb_awake`）用寄存器当前值（`reg_file`、`inst_r`），写进 `*_1`；写回级旁路补上"本拍写入、本拍读不到"的值。
- `prf2exe`、`ftq_prf_pc_req` 只依赖 iss2prf/ftq 响应/exe 旁路/写回级；`prf_awake` 依赖写回级与 dec_bcast。

## 4. 与 C++ 的差异点、放宽、删除、不复刻
差异：无功能差异（有意义输出逐拍一致）。

**放宽（`when`）及消费者核对**
- `prf2exe_iss_entry_uop_*`（全部）`when prf2exe_iss_entry_valid`：消费者 `Exu::comb_exec/Isu 发射口 → Exu` 只处理 `valid` 为真的槽
  （`Exu.cpp:310` 先判 `iss_entry[p_idx].valid` 才转换）。RTL 在 valid=0 时直通（不再清零）。
- `prf_awake_wake_preg when prf_awake_wake_valid`：读取点 `Isu.cpp:364`、`Dispatch.cpp:7` 都先判 `wake[i].valid`。
- `ftq_prf_pc_req_req_ftq_idx/ftq_offset when ftq_prf_pc_req_req_valid`：读取点 `PreIduQueue::comb_ftq_lookup_prf` 先判 `req[i].valid`。
  RTL 无条件直通发射口的 ftq_idx/offset（不再按请求清零）。
- 严格比较的：`prf2exe_*_pc/ftq_pred_taken/ftq_next_pc`（FTQ 对未请求的口返回全 0，RTL 直通该口的响应，天然一致）、
  `src{1,2}_rdata`（`!src_en||p0` 读 0 这类门控保留：消费者 `Fu.h` 的 src_en 逻辑对未使能源是否读值未逐一核对，按规则不放宽）。

**删除的字段（spec 与端口）及理由**
- 输出 `prf2exe_iss_entry_uop_{ftq_resp_valid, ftq_offset, src1_preg, src2_preg, src2_en}`：Exu/Lsu/Rob 无读取点
  （全后端 grep：`ftq_resp_valid`、`src1_preg/src2_preg`、`src2_en` 在 Exu/Lsu 里无引用；`ftq_offset` 只在 Rob 自己的结构里）。
- 输入 `ftq_prf_pc_resp_resp_valid`：恒等于请求 valid（见不复刻第 5 条），冗余。

**选择不复刻的 C++ 行为**
1. 写回级里"无效槽保持旧载荷"（`inst_r_1[i]` 在 !valid 时保留 uop）：载荷无条件采样，只有 `wen` 有意义。
2. 同拍多个写口写同一物理寄存器（C++ 后者胜）：重命名保证单一生产者，真实 trace 中 0 次，RTL 用 AND-OR。
3. FU 旁路与写回级旁路同时命中同一 preg 的优先级、多 FU 命中的 break：同上，真实 trace 0 次。
4. >4 个 load 同拍唤醒时丢弃多余者：LSU 只有 4 个 load 写回口，不可达（真实 trace 0 次）。
5. FTQ 响应缺失：不存在——`fill_ftq_pc_resp`（PreIduQueue.cpp:9）里 `resp.valid` 恒等于 `req.valid`，未请求的口整体为 0。因此 `resp.valid` 输入冗余，已删；`entry_valid` 无人读。
6. 写 p0 的保护（`dest_preg != 0`、`reg_file_1[0]=0`）：p0 的读口恒返回 0，内容不可观测；dest_en 且 dest_preg=0 的写回真实 trace 0 次。
7. `UOP_LOAD` 的 `decode_uop_type` 断言（op<18）：不复刻。

## 5. 验证
- spec：`spec/prf.io`（71 个字段）。
- trace：64 个真实程序（61 gate 与 dhrystone/coremark 等；gate 各 30000 拍，大程序 100000 拍）+ 3 条随机 trace
  （`tests/prf/run_rand.sh`，驱动参考模型真实 `Prf` 类，各 40003 条；约束：同时可见的写回/旁路目的寄存器互不相同、
  FTQ 对请求口必答、未请求口全 0 —— 与重命名/FTQ 的真实保证一致）。共 67 条、621,726 条记录，全部 PASS。
- 真实程序覆盖：flush 616 拍、mispred 2.3 万、clear_mask≠0 27 万、exe 条目被杀 4248、FU 旁路命中 38 万、WB 旁路命中 13 万、
  同拍 load 唤醒 1–4 个、被杀 load 1229 次、ALU 取 PC 7 万次、BR 取 PC 41 万次。随机 trace 补足上述各项的高密度组合与 p0 源。
- 变异（严格比较的字段抓到；dhrystone / rand_a，记录号）：
  - A3 load 编码 3→4：`prf_awake_wake_valid[0]` rec107 / `[2]` rec4
  - A4 clear_mask 用 AND 代替 AND-NOT：`prf_awake_wake_valid[0]` rec612 / `wake_preg[3]` rec35
  - A5 误预测 kill 用 OR 代替 AND：`src1_rdata[10]` rec137 / `wake_valid[0]` rec8
  - A6 ALU 取 PC 条件取反：`ftq_prf_pc_req_req_valid[0]` rec35 / `[2]` rec1
  - A8 唤醒槽 rank 偏 1：`wake_valid[0]` rec107 / `wake_preg[0]` rec4
  - A9 PC 口接线错位：`prf2exe_iss_entry_uop_pc[0]` rec59 / `[1]` rec3
  - B1 FU 旁路数据截成 16 位：`src1_rdata[0]` rec78 / `[2]` rec4
  - B2 mispred 同拍 flush 失效：dhrystone 抓不到（真实程序无同拍），rand_a `wake_valid[0]` rec12
  - B3 写口只对偶数口有效：`src1_rdata[0]` rec81 / `[11]` rec5
  - B4 WB 旁路对奇数 preg 忽略 wen：`src1_rdata[6]` rec385 / `[18]` rec4
  共 10 个变异全部被抓到，均由严格比较的字段（`wake_valid`、`src*_rdata`、`req_valid`、`pc`）报出。
- 简化前后行数（rtl/backend/prf）：9 个文件 785 行 → 7 个文件 505 行（其中 prf.sv 244 行主要是 spec 端口声明）；spec 82 → 76 行。
