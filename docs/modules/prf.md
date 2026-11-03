# prf 设计笔记

## 1. 对应的 C++
- 文件/类：`back-end/Prf.cpp`、`back-end/include/Prf.h`，`class Prf`（参考模型 commit 2f31e8d）。
- BackTop 调用顺序：`comb_begin`(277) → `comb_complete`(空) → `comb_awake`(289) → `comb_write`(290) →
  … → `comb_req_ftq`(323) → `pre->comb_ftq_lookup_prf` → `comb_read`(325) → … → `comb_pipeline`(391) → `seq`。
- 输入（spec 里 `in`）：
  - `dec_bcast`：mispred、br_mask、clear_mask（br_id/redirect_rob_idx 未被读）
  - `rob_bcast.flush`
  - `iss2prf.iss_entry[22]`：valid + uop 全部字段（除 dbg）
  - `exe2prf.entry[22]`：valid + uop{dest_preg,result,br_mask,dest_en,op}
  - `exe2prf.bypass[28]`：valid + uop{dest_preg,result,dest_en}（br_mask/op 未被读）
  - `ftq_prf_pc_resp.resp[10]`：valid、pc、pred_taken、next_pc（entry_valid 未被读）
- 输出（`out`）：`ftq_prf_pc_req.req[10]`、`prf_awake.wake[4]`、`prf2exe.iss_entry[22]`。
  其他模块不直接读 Prf 成员（`reg_file` 仅被 BackTop 的 checkpoint 恢复/difftest 路径写入，不属于 RTL 边界）。
- 端口命名：BackTop 线名 + 字段路径，例如 `iss2prf_iss_entry_uop_dest_preg[i]`、`exe2prf_bypass_valid[k]`。
- 位宽：PRF_IDX 7，UOP_TYPE 5（`UOP_LOAD`=3），BR_MASK 64，ISSUE_WIDTH 22，TOTAL_FU 28，FTQ_PRF_PC_PORT 10，LSU_LOAD_WB_WIDTH 4。

## 2. 硬件结构
```
 exe2prf.entry ─▶ prf_wb_pipe ──(wb_*_q: 22 路写回级寄存器)──┬─▶ prf_write_arb ─▶ prf_regfile (128x32)
 dec_bcast/flush ─▶ (prf_kill)                              ├─▶ prf_awake  ─▶ prf_awake_wake_*
                                                            └─▶ prf_read_ports (bypass)
 iss2prf ─▶ prf_pc_port ─▶ ftq_prf_pc_req / 把 ftq_prf_pc_resp 回挂到发射口
 iss2prf src_preg ─▶ prf_regfile 读口(2x22) ─▶ prf_read_ports(prf_bypass x44) ─▶ prf2exe src{1,2}_rdata
```
- `prf.sv`：顶层，只做端口适配（把 src1/src2 数组并成 [2][22]，透传 uop 字段）。
- `prf_kill`：`mispred && (br_mask & bcast_mask) != 0`，逐路。被 wb_pipe 与 awake 共用。
- `prf_wb_pipe`：22 路写回级流水寄存器 `inst_r`（valid + dest_preg/result/br_mask/dest_en/op），含 flush/杀伤/clear_mask。
- `prf_write_arb`：每个物理寄存器的写使能与写数据；多口同写同一寄存器时**编号最大的口胜出**（C++ `comb_write` 顺序覆盖）；p0 不可写。
- `prf_regfile`：128x32 寄存器堆，2x22 个异步读口，写来自 write_arb。复位全 0。
- `prf_bypass`：单个读口：`!src_en || preg==0 → 0`，否则 优先级 exe 旁路（**编号最小**的 FU 胜出，C++ 有 break）> 写回级旁路（**编号最大**的口胜出，C++ 无 break）> 寄存器堆。
- `prf_read_ports`：22x2 个 `prf_bypass` 的 generate。
- `prf_pc_port`：发射口 → FTQ 读口的静态映射：ALU 口 0..5（需 op∈OP_MASK_ALU 且 src1_is_pc）→ 槽 0..5；BR 口 18..21（op∈OP_MASK_BR）→ 槽 6..9。
  输出请求与每路 pc/ftq_resp_valid/pred_taken/next_pc（没有命中响应则全 0）。
- `prf_awake`：从写回级里选 Load 完成事件（dest_en、op==LOAD、未被 kill），按口序压缩到前 4 个（前缀 popcount + 独热选择）。

状态：`reg_file[128]x32`（写口 22，读口 44）；`inst_r[22]`（C++ 里是 reg，RTL 里 `wb_*_q`）。

## 3. 一拍内的数据流
- 读（`comb_read`/`comb_awake`）用的是**寄存器当前值**（`reg_file`、`inst_r`），写（`comb_write`）写入 `*_1`。
  所以同拍的读不看到同拍的写，写回级旁路正是为此：读口看到 `inst_r`（上一拍执行完、本拍写入堆的结果）。
- 输出 `prf2exe` 是组合输出（依赖 iss2prf、ftq 响应、exe 旁路）；`prf_awake` 只依赖寄存器与 dec_bcast（组合）；
  `ftq_prf_pc_req` 只依赖 iss2prf。
- `comb_pipeline`：flush 优先清 valid；否则 exe 有效则装载，被 kill 则 valid=0，否则 valid=1 并清 clear_mask 位。
  exe 无效则 valid=0。载荷（uop）只在 exe valid 时更新（无效时保持，不可见）。
- 无 stale 读/同拍覆盖之外的问题：`comb_write` 的"同拍多口写同一 preg，后者胜"已显式化为优先级（见上）。

## 4. 与 C++ 的差异点和隐含依赖
- 无功能差异。
- 注意：C++ 里 `exe2prf.entry[i].uop`、`bypass[k].uop`、`prf2exe.iss_entry[i].uop`（valid=0 时）和 `prf_awake.wake[i].preg`（valid=0 时）
  是上一拍残留值；spec 中输出这几项用 `when <valid>` 屏蔽（它们本来就是"无效时无意义"），输入则按原样录制。
- `read_operand_with_bypass` 里写回级旁路没有 break（后者胜），exe 旁路有 break（前者胜）——RTL 保持两者不同的优先方向。

## 5. 验证
- spec：`spec/prf.io`
- trace：64 个真实程序（61 gate + dhrystone/coremark 等；gate 各 30000 拍，大程序 300000 拍）共 1,101,717 条记录；
  另 3 条随机激励 trace（`tests/prf/run_rand.sh`，驱动参考模型的真实 `Prf` 类，各 100003 条，种子 1/2/3，寄存器池 6/16/128）。
  全部 PASS（67 条，1,401,726 条记录）。
- 覆盖（真实程序）：flush 616 拍、mispred 23333、clear_mask≠0 27 万、exe 条目被杀 4248、FU 旁路命中 38 万、WB 旁路命中 13 万、
  load 唤醒 1–4 个同拍均出现。**真实程序没有覆盖到**：同 preg 多口写冲突、FU 与 WB 旁路同时命中、同 preg 多 FU 命中、
  load 唤醒 >4 被丢弃、FTQ 响应缺失（resp.valid=0）、dest_preg=0 的写/旁路、"src1_is_pc 但 op 非 ALU" 等。
  这些由随机 trace 补上（均出现 5 万～数十万次）。
- 变异（回放抓到的第一处，rec=记录号；dhrystone / rand_a）：
  - M1 写冲突改"最小口胜"：src1_rdata[18] rec59 / src1_rdata[4] rec8
  - M2 WB 旁路优先于 FU 旁路：dhrystone 抓不到（真实程序无同时命中）；rand_a src1_rdata[8] rec4
  - M3 多个 FU 命中改"最大号胜"：dhrystone 抓不到；rand_a src1_rdata[9] rec3
  - M4 load 编码 3→4：wake_valid[0] rec107 / rec4
  - M5 clear_mask 用 AND 而非 AND-NOT：wake_valid[0] rec612 / wake_preg[2] rec13
  - M6 kill 用 OR 代替 AND：src1_rdata[10] rec137 / wake_valid[0] rec13
  - M7 ALU 取 PC 条件取反：ftq_prf_pc_req_req_valid[0] rec35 / [5] rec4
  - M9 flush 在 mispred 同拍时失效：dhrystone 抓不到；rand_a wake_valid[0] rec230
  - M10 唤醒槽 rank 偏 1：wake_valid[0] rec107 / wake_valid[2] rec4
  - M11/M13 FU/WB 旁路忽略 dest_en（奇数 preg）：dhrystone 抓不到；rand_a src1_rdata[0] rec3 / src1_rdata[16] rec4
  - M12 BR 口 PC 响应错位：prf2exe_iss_entry_uop_pc[18] rec59 / [19] rec8
  - M14 被杀 load 仍唤醒：wake_valid[0] rec612 / wake_preg[2] rec13
  - M15 去掉 p0 读零门：dhrystone 抓不到；rand_a src2_rdata[12] rec3
  共 15 个有效变异，全部被（真实+随机）trace 抓到；其中 6 个只有随机 trace 能抓到。
  等价变异（不可观测，按设计保留）：(a) kill 的 mask 比较改"全位相等"——dec_bcast.br_mask 恒为单比特，等价；
  (b) 允许写 p0——读口对 p0 强制读 0，p0 内容不可观测（C++ 的 `dest_preg != 0` 与 `reg_file_1[0]=0` 是冗余保护，RTL 保留前者）。
- 回放注意：`scripts/replay.sh prf` 因 harness 的 Verilator `--replication-limit`（out_bits 9632 位）构建失败，
  回放是用私有副本（hbuild 加 `--replication-limit 100000`，其余完全相同）完成的，见最终报告。
