---
module: front_top
area: frontend
rtl: rtl/frontend/front_top rtl/core/core_top
spec: front_top core_top
status: green
lockstep: 68/68（front_top、core_top）
mutants: 30 个中 24 杀死，3 等价，3 覆盖缺口
note: 前端顶层 + 前后端联调 core_top
---

# front_top 设计笔记（前端顶层）与 core_top（前后端联调）

覆盖两个装配体：`front_top`（前端整体，spec/front_top.io）和 `core_top`（front_top + back_top + SimCpu 胶合，spec/core_top.io）。
子模块（predecode / predecode_checker / 4 个 FIFO / front_ctrl / BPU / ICache+ITLB）的设计见 `front_basic.md`、`bpu.md`、`icache.md`，
这里只写装配层。总原则见 06 第 0 节：只要求边界上每拍可观察行为功能等价，`front_comb_calc` 的调用结构不复刻。

## 1. 对应的 C++
- `front-end/front_top.cpp` `front_comb_calc`（步骤 S1–S14，见 `analysis/frontend-boundary.md`）；边界 = `FrontTop::in/out`（`front.in/front.out`）加 icache 的存储侧口。
- `rv_simu_mmu_v2.cpp`：`SimCpu::cycle()`、`front_comb_before_back()`（front.out → back.in，`no_taken` 截断，`frontend_can_read`）、`back2front_comb()`、`front2back_hold_comb/seq`。

## 2. 硬件结构
```
 front_top
   front_ctrl (已有)            global_refetch（含延迟一拍的 predecode refetch）、各读写使能、f2b 输出旁路选择
   icache (已有, 含 ITLB)        fetch_addr FIFO 队首 -> 取指组；AXI 读口 / DCache 探针 / PTW walk 口直接引出
   front_fetch_buf (本批)        fetch_addr_fifo、predecode(8 lane)、sequential_next_pc、inst_fifo
   front_pred_path (本批)        BPU、PTAB、predecode_checker、front2back_fifo、front.out 旁路 mux、pc[i]=base+4i
 core_top
   core_front                    front_top + core_back2front + core_front2back
     core_back2front             back2front 寄存器（refetch/地址/itlb_flush/fence_i/stall + 提交槽的 BPU 训练包）
     core_front2back             can_read 选择、no-taken 截断、8->16 lane 展宽、stall 保持寄存器
   back_top (已有)
```
- front_top 顶层 194 行，`front_fetch_buf` 103，`front_pred_path` 287（均 <400）；core_top 340、core_front 242、core_back2front 163、core_front2back ~150。
- front_top 本身**没有新增状态**：状态全部在子模块里（FIFO 指针、BPU、ICache、`predecode_refetch`）。组合路径：FIFO 队首 -> checker -> `do_predecode_flush` -> icache.invalidate；
  不成环（`do_predecode_flush` 只进 `predecode_refetch` 寄存器和 icache 的次态；icache 的前端输出 `read_complete/fetch_group` 不依赖 `invalidate`）。
- SC-L / loop 元数据：BPU 没有这些输出（恒 0），装配层给 PTAB/f2b 的写口接常量 0；读口悬空。条目仍按原宽度存储（PTAB/f2b 里 8×181 位恒 0，见 front_basic §4.5，属 BPU 层决定）。
- 展宽/截断（`no_taken`）和 `front2back_hold` 属于 SimCpu 一侧，**不在 front_top 边界内**，放在 `core_front2back`。

## 3. 一拍内的数据流（对应参考调用顺序，frontend-boundary §1）
寄存后的 back2front（`core_back2front` 的 `_q`）→ 一次组合（front_top）→ back_top 组合 → 时钟沿：BPU/FIFO/ICache 状态、`core_back2front` 寄存器、hold 寄存器。
- `frontend_can_read = !stall_q || refetch_q`；不可读时 `fifo_read_enable=0`（front_top 仍照常求值，BPU/ICache/FIFO 写侧推进），back.in 取 hold 寄存器。可读时 `fifo_read_enable=1`，`refetch` 恒等于 `refetch_q`（C++ 的"不可读则 refetch=false"与"refetch_q 时一定可读"合并后无区别）。
- `back.in.valid[j] = FIFO_valid & inst_valid[j] & 之前没有"valid 且预测跳转"的 lane`（前缀或，不用逐 lane 串行变量）；lane 8..15 恒无效、指令 `INST_NOP`，其余字段 0。
- hold 寄存器每拍无条件写入 back.in：只在"上一拍 stall 且无重定向"后的拍里才被读（此时 C++ 才存非空 hold）；C++ 还会清掉已被后端接受的 lane（`fire`），但后端 all-or-nothing（`PreIduQueue::comb_accept_front`：ready 时 `fire=valid`，不 ready 时全 0），hold 里的组恒为完整的组，所以不需要 `fire`（变异检查里该变异"等价"，故删除了这条依赖）。
- back2front 训练包：提交槽有效时 `actual_dir=(JAL|JALR)?1:br_taken`，`actual_target=(BR|JAL|JALR)?diag_val:ftq_pc+4`，`br_type` 按 CALL/RET/IDIRECT/JAL/DIRECT/NONCTL 分类（`back2front_comb`）。C++ 在槽无效时保留上一值（tage_tag 清 0）；本实现无效槽整体清 0（BPU 的所有消费者——更新队列、历史、类型预测器——都由 `upd_valid` 门控，见 `bpu_uq/bpu_hist/bpu_type`），不建保持寄存器。

## 4. 与 C++ 的差异点、放宽、删除、不复刻

### 4.1 spec/front_top.io 的字段（63 个）与放宽
| 字段 | 处理 | 消费者核对 |
| --- | --- | --- |
| `be_refetch/be_refetch_address/itlb_flush/fence_i/fifo_read_enable`、csr_status 6 个、BPU 训练包 10 组 | 输入，取自 `cpu.front.in.*`、`TTG_IC.csr_*`、`bpu_seq_txn.inp.*`（与 icache.io/bpu.io 同表达式）| — |
| icache 存储侧输入 17 个、输出 12 个 | 同 icache.io（TTG_IC）| 请求字段 `when *_valid` 沿用 icache.io 已核对的放宽 |
| `out_valid`、`out_lane_valid[8]`（= `FIFO_valid & inst_valid[i]`）| 严格比较 | `back.in.valid[j]` 的来源；`out_lane_valid` 同时是 core_front2back 的输入 |
| `out_instructions/page_fault_inst/predict_dir/pc/alt_pred/altpcpn/pcpn/tage_idx/tage_tag`、`out_predict_next_fetch_address` | `when out_valid`（整条 front.out 载荷只在 FIFO_valid 时有意义）| `PreIduQueue.cpp:121-192`：载荷只在 `incoming_valid_num>0`（即某 lane `valid`）分支和按 lane valid 的指令缓冲写里读；`valid` 是 `FIFO_valid & inst_valid & no-taken` 的子集；FIFO_valid=0 时 C++ 输出是全 0/残留，无人读 |
| `out_pc[i]` | 逐 lane 比较（RTL 内 `base + 4i`）| 同时在整程序上验证 base+4i 恒等式（front_basic 用一次性 spec 在 5 个程序验证过，这里变成 68 个程序的常驻检查）|
| **删除**：`front.out.commit_stall`（BPU `update_queue_full` 恒 0；core 里 `front_stall` 接 0）、SC-L/loop 元数据（恒 0）、`front.in.reset`、perf/dbg/tma | | `PreIduQueue` spec 已写明 `front_stall` 无读者；back_top 里该输入只接到 rob（C++ 值恒 0）|

### 4.2 spec/core_top.io（96 个字段）
输入 = icache 存储侧（TTG_IC）+ LSU 的 DCache/MMIO 响应 + DTLB walk 响应 + 中断注入（同 back_top.io 表达式）；输出 = icache 与 LSU 的存储侧请求 + 退休流（`rob_commit_*`、`rob_bcast_*`、`out_mispred/out_redirect_pc`、`out_commit_entry_uop_diag_val`、提交 pc）。后端不再从前端读输入，前端的任何偏差必须通过"取指请求/退休流"变得可见。核边界不含 back_top 内部的 front2pre_*（已由 front_top.io 单独验证）。

### 4.3 选择不复刻
1. `front_comb_calc` 的 S0/S3'/S15（快照、统计、deadlock snapshot）、`front_stats`、8 个 full/empty latch（FIFO 的 size 函数）、四个 FIFO 的"读调用+写调用+accumulate"。
2. inst FIFO 的 `inst_fifo_full_for_write`：结构上不可达，`front_fifo` 内断言（写满）已覆盖；`inst_wr_en = read_complete & !global_refetch`。其中 `!global_refetch` 与 icache 的 `resp_valid = !kill1 && ...` 重复，变异 `inst_wr_en_ignores_refetch` 因此等价（保留作防御）。
3. `FIFO_read_enable=false` 时 `front.in.refetch=false` 的清零（refetch_q 时一定可读，不会触发）。
4. back2front 训练包无效槽的残留值（见 §3）、hold 寄存器的 `fire` 清除（§3）。
5. `frontend_can_read=false` 的拍：C++ 仍调用 `comb_bpu`，RTL 等价（front_top 每拍求值，`fifo_read_enable=0`）。

### 4.4 疑点 / 参考模型观察（无需修改）
- `bpu_icache_read_ready` 名字误导（沿用，见 front_basic §4.1）。
- 恒 0 的 `commit_stall` 若以后 BPU 更新队列会满，`front_stall` 必须接回（core_top 里写死 `1'b0`）。
- ITLB 的 `$error("itlb_flush without refetch")` 断言：在核里由 `itlb_flush_q`（SFENCE.VMA 提交）与 `refetch_q` 同拍成立。

## 5. 验证
- **front_top 整程序实时锁步**（`REFSIM=…/refsim_tap BIG_CYCLES=300000 JOBS=3 bash scripts/lockstep_multi.sh front_top`）：**68/68 PASS**（后端里的各块相同的 68 个程序：61 gate + vm + dhrystone/coremark/float）。
- **core_top 整程序实时锁步**（同命令，模块名 `core_top`）：**68/68 PASS**，共约 149 万拍；coremark（2 次迭代）约 22.7 万拍跑完。
- lint：`rtl/frontend/front_top`、`rtl/core/core_top` 干净（需要 `scripts/lint.sh` 增加两个装配分支，见交付报告）。
- 变异检查（`tests/front_top/mut_front_top.py`：每个 spec 一次构建，运行时 `TTG_MUT=K` 选变异体，先在 9 个短程序上筛，幸存者再在 12 个短 gate 程序 × 15 万拍上复跑）：

| 层 | 变异 | 结果（第一个失配）|
| --- | --- | --- |
| front_top | ctrl 的 `be_fifo_read_enable` 接常 1 | KILLED vm_sum_fetch@2536 `out_valid` |
| | icache `refetch` 只接后端 refetch（漏 predecode refetch）| KILLED smc-div@12 `ptw_walk_flush` |
| | fetch_addr 写地址 ^4 | KILLED smc-div@4 `mem_req_addr` |
| | ctrl `icache_ready` 常 1 | KILLED smc-div@55 `mem_req_addr` |
| | `out_lane_valid` 不看 `out_valid` | KILLED vm_sum_fetch@2537 `out_lane_valid[0]` |
| | inst/PTAB 读使能改成 fa_rd_en | KILLED vm_pagefault@3312 `ptw_walk_flush` |
| | predecode 的 pc 接 0 | KILLED smc-div@71 `out_predict_next_fetch_address` |
| | seq_next_pc 的 valid 接成 page_fault | KILLED smc-div@11 |
| | fetch_addr FIFO 的 clear 去掉 | KILLED smc-div@16 `mem_req_addr` |
| | PTAB 的 base_pc 写成 next_pc | KILLED smc-div@11 `out_pc[0]` |
| | f2b FIFO 用 global_refetch 清 | KILLED dhrystone@3862 `out_valid` |
| | checker 的 seq_next_pc 接 PTAB 预测地址 | KILLED smc-div@11 |
| | f2b 写入未校正方向 | KILLED vm_sum_fetch@2540 `out_predict_dir[4]` |
| | `out_pc` 步长 2 | KILLED smc-div@11 `out_pc[1]` |
| | 旁路时 next_pc 取未校正值 | KILLED smc-div@11 |
| | 旁路 tage_tag 错位 | KILLED smc-div@1693 `out_tage_tag[0][0]` |
| | BPU refetch 地址接 0 | KILLED smc-div@16 `mem_req_addr` |
| | icache `invalidate` 接 0 | **幸存**（覆盖缺口：predecode 冲刷拍与 AXI/DCache 探针请求同拍的情形；下一拍的 refetch 本就杀死请求，只有冲刷拍的存储侧端口会不同，真实程序几乎不触发；icache.md 的随机 trace 变异已覆盖该模块内部）|
| | `inst_wr_en` 去掉 `!global_refetch` | **幸存 = 等价**（icache `resp_valid` 已含 `!kill1`）|
| core_top | `can_read` 忽略 refetch_q | KILLED smc-div@145 `dtlb_walk_flush` |
| | hold 寄存器 pc 取前端值而非 back.in | KILLED vm_pagefault@3367 |
| | no-taken 截断包含 taken lane 自身之后 | KILLED smc-div@59 |
| | stall 寄存器接 0 | KILLED vm_pagefault@3402 `rob_commit_commit_entry_valid[6]` |
| | 训练包 target 对 JALR 用 ftq_pc+4 | KILLED smc-div@236 `mem_req_valid` |
| | refetch 寄存器接 stall | KILLED smc-div@18 `itlb_walk_flush` |
| | 训练包 pcpn 取 altpcpn | KILLED vm_sum_fetch@187 `mem_req_valid` |
| | mstatus.SUM 位接 MXR | **幸存 = 等价**（取指不看 MXR/SUM/MPRV）|
| | CALL 判定去掉 `dest_en` | **幸存 = 等价**（JAL 恒写 rd，`dest_areg==1` 蕴含 `dest_en`）|
| | RET 判定去掉 `imm==0` | **幸存 = 覆盖缺口**（程序里没有带非零偏移的 `jalr x0, imm(ra)`；需要定向测试）|
| | `itlb_flush` 接 `fence_i` | **幸存 = 覆盖缺口**（没有"SFENCE.VMA 之后取指翻译才暴露陈旧 ITLB 项"的程序；需要定向测试）|

  共 30 个变异（front_top 19、core 11）：24 个被抓到，6 个幸存：3 个等价（`inst_wr_en` 重复防御、SUM/MXR、CALL 的 dest_en），3 个是覆盖缺口（icache `invalidate`、RET 的 imm==0、`itlb_flush` 接 fence_i，都需要定向测试）。
- 复现：`REFSIM=…/refsim_tap python3 tests/front_top/mut_front_top.py --jobs 3`；结果 `build/mut_front_top.txt`。

## 6. 复现
```bash
export REFSIM=/Users/ruyaoh/personal/tututugege-rtl/refsim_tap
BIG_CYCLES=300000 JOBS=3 bash scripts/lockstep_multi.sh front_top     # 前端 68/68
BIG_CYCLES=300000 JOBS=3 bash scripts/lockstep_multi.sh core_top      # 核 68/68（构建约 75 秒）
python3 tests/front_top/mut_front_top.py --jobs 3
```
