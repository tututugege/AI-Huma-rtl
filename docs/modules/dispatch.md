# dispatch 设计笔记

## 1. 对应的 C++
- `back-end/Dispatch.cpp`、`back-end/include/Dispatch.h`，类 `Dispatch`；BackTop 调用顺序：`comb_begin` → `comb_alloc` → `comb_wake` → `comb_dispatch` →（ROB/LSU/ISU 阶段）→ `comb_fire` → `comb_pipeline` → `seq`。
- 输入：`ren2dis`（valid + 27 个 uop 字段）、`rob2dis`（ready/empty/stall/enq_idx/rob_flag）、`iss2dis.ready_num[5]`、`lsu2dis`（stq_tail/flag/free、ldq_free、ldq_alloc_idx/valid[8]）、`prf_awake`(4)、`iss_awake`(15)、`rob_bcast.flush`、`dec_bcast.{mispred,clear_mask}`。
- 输出：`dis2ren.ready`、`dis2rob`（valid/dis_fire/uop）、`dis2iss.req[5][8]`、`dis2lsu`（STQ 8 口、LDQ 8 口）。
- 不翻译：tma/dbg/perf（`CONFIG_PERF_COUNTER` 块只写统计）。ren2dis 的 `expect_mask/cplt_mask/src2_areg` 在 C++ 里被覆盖或从不读取，故不进 spec。

## 2. 硬件结构
```
ren2dis ─▶ [inst_stage: inst_q/valid_q ×8] ──┬─▶ lsu_alloc (STQ/LDQ 分配, rob_valid)
                                            ├─▶ wake_match + src_busy (busy_table 读, 同拍唤醒, 组内 RAW)
 busy_table[128] ◀─ set(fire) / clear(wake) ├─▶ decompose ×8 (每 IQ 至多 1 个 uop)
                                            ├─▶ iq_alloc (每 IQ 前缀计数, 容量检查, 端口号)
                                            ├─▶ fire_ctl (dis_fire, dis2ren.ready)
                                            └─▶ iq_req / lsu_req (仅 fire 的车道驱动请求口)
```
- `dis_pkg`：常量、`dis_inst_t/dis_iss_uop_t/dis_res_t/dis_class_t`、枚举、分类函数。（文件名取 `dis_pkg` 以保证 replay/lint 按字典序先编译包。）
- `dispatch`：只做端口打包/拆包。`dispatch_core`：连线。
- `dispatch_inst_stage`：8 条 128 位级寄存器（含全部字段）+ valid；flush/mispred 清 valid、ready 时收新组、否则保留未 fire 的并刷新 busy、两路都清 clear_mask。
- `dispatch_lsu_alloc`：用前缀 popcount 得到车道前面有几条 load / store；STQ：rank<stq_free 即授予，位置 = tail + min(rank,stq_free)，flag 带进位；LDQ：端口 0..k 全可用（first_set 求首个不可用口）才授予第 k 个 load。
- `dispatch_wake_match`：16 个源 preg 对 19 个唤醒口的 CAM。`dispatch_src_busy`：busy = src_en & ((table & !woken) | 老车道写同 preg)；LSU 拒绝的车道保留进来时的 busy。
- `dispatch_busy_table`：128 位，`busy_d = set | (busy_q & ~clear)`。
- `dispatch_decompose`：每车道一个，产出“每个 IQ 的 uop + has_iq + expect_mask”（因为每条指令对同一 IQ 至多 1 个 uop，省去 C++ 的 k 下标）。
- `dispatch_iq_alloc`：每 IQ 一个“older lanes 的 uop 数”前缀 popcount 作为端口号；容量 = used < min(width, ready_num)；`brk_before` = 前面有有效但放不下的车道。
- `dispatch_fire_ctl`：见 3。`dispatch_iq_req`/`dispatch_lsu_req`：每个端口 one-hot 选中拥有该端口且 fire 的车道，用 `ttg_onehot_mux` 取数据。

C++ → 硬件：`dispatch_cache/dispatch_success_flags/stq_port_owner/ldq_port_owner/iq_usage` 都变成上述前缀计数与 one-hot；`comb_fire` 的“撤销 IQ 请求”不再存在——只有 fire 的车道才驱动请求（结果等价）。

## 3. 一拍内的数据流
1. `comb_alloc`：rob_idx = {enq_idx[3:0], 车道号}（`make_rob_idx`，enq_idx 实为 4 位行指针）；load/store 分配（见上）。
2. `comb_wake`：busy 计算（见上）。3. `comb_dispatch`：decompose + iq_alloc；dis2rob.uop.expect_mask 仅当该车道被处理且放得下时非 0。
4. `comb_fire`：顺序标志 pre_stall/pre_fire 并行化——“此前没有 stall”意味着此前所有有效车道都已 fire，故 pre_fire = 前面有有效车道。`stop_here[i] = valid & (!fire_ideal | AMO | WFI)`；`dis_fire[i] = fire_ideal[i] & !(older stop)`；`ready = !(|stop_here)`。CSR/AMO 要求 ROB 空且无更老 fire。busy_table 清除唤醒后再置位 fire 车道的 dest_preg。
5. `comb_pipeline`：见 inst_stage。

## 4. 与 C++ 的差异点和隐含依赖
- 无功能差异（无 deviation）。
- 隐含依赖（均按 C++ 行为实现，无需额外寄存器）：
  - (stale) `dispatch_success_flags[i]` 在 comb_dispatch 中途 `break` 之后的车道保留上一拍的值；但这些车道之前已有有效车道 stall，所以不可观察。RTL 用 `fit` 的理想值并由 stall 链屏蔽。
  - (stale) `dis2iss.req[].uop`、`dis2lsu` 的 rob_idx/func3/flag/ldq_* 在 valid/req 为 0 时是上一拍残留（回滚只清 valid），spec 用 `when` 忽略。`dis2lsu.br_mask/ldq_br_mask` 在 req=0 时为 0，全程比较。
  - (3.3 覆盖) AMO 既是 load 又是 store；失败的 AMO load 仍占用 store 计数；load 失败后不再递增 load 计数（RTL：端口 0..k 前缀）。
  - `dis2rob.uop` 的 stq_idx/ldq_idx 在未授予时为 0；load 总是记录 stq 位置（即使 LDQ 没授予）。
  - `rob2dis.enq_idx` 7 位 IO 字段，实为 4 位，高位丢弃；top 对该端口位 6:4 局部 `lint_off UNUSEDSIGNAL`。
  - 唤醒输入在 comb_wake 与 comb_fire 取同一份（trace 验证一致）。
- 参考模型疑点：held 指令的 busy 重新带入“同组老车道写同 preg ⇒ busy”（comb_pipeline 用 inst_alloc.busy）；无害，已照搬。

## 5. 验证
- spec：`spec/dispatch.io`（114 字段，输入 414 B/拍，输出 2017 B/拍）。
- trace：61 个 gate 测试各 8000 拍（短程序提前结束）+ dhrystone/coremark 各 60000 拍 + coremark10 250000 拍（仅本地回放，未提交），共 64 个、约 478k 条记录，全部 PASS。拍数用 `GATE_CYCLES`-等价的方式缩小，原因是每拍 2.4 KB。
- 覆盖：flush 594、mispred 8570、rob stall 约 1.6k、ready=0 约 12 万拍、clear_mask 非 0、STQ 位置/flag 回绕、LDQ 空闲 <8 与 =0、STQ 空闲=0 仅 6 拍、STA/STD/BR/INT 8 口全用到、AMO 全部 11 种、JAL/JALR/CSR/MRET/SRET/WFI/FENCE_I/EBREAK/ECALL 均出现。**未覆盖**：SFENCE_VMA（decompose 的 UOP_SFENCE_VMA 映射未被检验）；IQ_INT/STA/STD/BR 的 ready_num<8（只有 IQ_LD 受限）；STQ 空闲 <8 极少。
- 变异（回放首个失败：trace / 字段 / cycle）：
  - M1 CSR/AMO 不看更老 fire：atomic-boundary，dis2rob_dis_fire[4]，cycle 101
  - M2 STQ 进位仅 tail_flag=0 时生效：coremark，dis2rob_uop_stq_flag[1]，1319
  - M3 忽略组内 RAW(src1)：add-longlong，dis2iss_req_uop_src1_busy[0][1]，74
  - M4 IQ 容量 `<`→`<=`：coremark，dis2rob_uop_expect_mask[5]，17844
  - M5 AMO rmw STD busy 极性：atomic-boundary，dis2iss_req_uop_src1_busy[3][0]，226
  - M6 WFI 不独占：wfi-boundary，dis2ren_ready，88
  - M7 保留指令不清 clear_mask：coremark，dis2rob_uop_br_mask[0]，237
  - M8 busy_table 某唤醒口不释放：matrix-mul，dis2iss_req_uop_src2_busy[0][0]，134
  - M10 SC expect_mask 覆盖删除：atomic-boundary，expect_mask[7]，88
  - M11 JAL/JALR BR uop 保留 dest_en：add-longlong，dest_en[4][0]，74
  - M12 STQ 授予 `<`→`<=`：matmul_fpu，dis2rob_valid[4]，164
  - M13 rob_idx 车道位错：add-longlong，rob_idx[1]，1
  - M14 SC 误判为 load：atomic-boundary，ldq_idx[7]，88
  - M15/M16/M18：imm=4 / 新组不清 br_mask / 最后唤醒口忽略，均被抓。
  - 抓不到的：busy_table 置位与清除同拍冲突（set/clear 同 preg，实际不会发生）、JALR 强制 src1_en（Idu 已置 1）、`ldq_alloc_valid` 单口（与 ldq_free 冗余，等价）。
