---
module: lsu
area: backend
rtl: rtl/backend/lsu
spec: lsu*
status: partial
lockstep: lsu 68/68；随机 12/12；back_top 冒烟 8/8（整程序 68 未重跑）
mutants: 重构后新 127 个变异体已建好（tests/lsu/mut_lsu.py），仅跑了前 14 个（10 杀死、4 筛选集存活待判），其余未跑；原 10 个存活变异体仍未结案
note: 已手写重构（表项模块 + 队列操作链，无生成文件）；变异检查被协调者叫停
---

# lsu 设计笔记

> **更新（2026-11-12，rv64 / 现状）**：1) 默认是分级 LSU（`LSU_PIPE = 1`），本文描述旧 LSU，规格见 `analysis/lsu-pipe.md`；`LSU_PIPE = 1` 时才有 STQ 写缓冲（EXP-024，`lp_wbuf`）和访存推测（`lp_ms`、`lp_mdp`，`LSU_MEMSPEC = 1`）。2) **数据字**：`XW = XLEN_BITS`、`SW = XW/8` 是 `lsu_pkg` 里的数据字宽和 store 选通宽；分级 LSU 的虚拟地址 `vaddr`、数据 `data` 在 `lp_pkg` 里都是 `XLEN` 位（`lp_pkg` 里按访问大小的函数，默认值 rv64 为 8、rv32 为 4）。3) 周期参考（`scripts/ref_cycles.txt`）是 trace-model 设 `LSU_PIPE_NOWD=1` 的结果：RTL 没有 LDQ/STQ 看门狗，模型的 63 周期看门狗不能打开。

> **分级流水 LSU（`ttg_cfg_pkg::LSU_PIPE = 1`）**：`rtl/backend/lsu/lp_*.sv` + `lsu_pipe.sv`，规格和 RTL 行为清单见 [analysis/lsu-pipe.md](../analysis/lsu-pipe.md)
> （对应 trace-model-lsupipe 的 `LSU_PIPE=1`）。下面的内容是**旧 LSU**（`LSU_PIPE = 0`，`lsu_core`）的设计笔记，该路径原样保留用于对比。
> `lsu.sv` 顶层按 `LSU_PIPE` 选择 `lsu_pipe`（新）或 `lsu_core`（旧）；两者端口相同，新增的两个输入 `dcache2lsu_load_retry_busy / store_retry_busy` 旧路径不用。

## 1. 对应的 C++

- `back-end/Lsu/RealLsu.cpp`（1527 行）、`include/RealLsu.h`、`include/MemUtils.h`、`RealLsuBsdConfig.h`；`RealLsuPerf.cpp` 只在
  `!BSD_CONFIG`（refsim 里 BSD_CONFIG 未定义，所以 perf 字段存在）下写 perf 统计，**但 `mark_load_replay/mark_load_hit/mark_store_*`
  会写 `replay_type`，这是功能状态**（`wake_*_replays_on_mshr_fill` 读它），RTL 保留；`retry_load_resp_timeouts` 受
  `CONFIG_LSU_DRESP_TIMEOUT_CYCLES>0` 控制，该宏未定义，=0，死代码，不翻译。
- 模块 = `RealLsu` 类。MMU（`TlbMmu`）不在本模块内（另一个模块）；它在 LSU 的“请求相”（`comb_tlb_out`）和“响应相”（`comb_tlb_in_*`）之间。

### 1.1 BackTop::comb 里一拍内的阶段顺序（LSU 相关）

```
comb_cal → comb_lsu2dis → comb_lsu2rob           (只读 cur 寄存器；输出给 Dispatch / ROB)
rob->comb_commit                                   (产生 rob_commit / rob_bcast)
comb_stq_commit                (B)  ROB 提交的 store：WaitCommit → Committed/Done，stq_commit_count 增
comb_mmio_in                   (C)  上一拍发出的 MMIO 请求的响应
comb_dcache2lsu_ldq            (D)  DCache load 响应 / MSHR fill 唤醒 / finish 入队
comb_dcache2lsu_stq            (E)  DCache store 响应 / MSHR fill 唤醒
comb_lsu2exe                   (F)  写回 EXU：mmu_done(STA/SC) 与 finish(load)；输出 lsu2exe
exu->comb_exec                                     (产生 exe2lsu，读 lsu2exe)
comb_exe2lsu                   (G)  STD / STA / LOAD 请求写入 STQ/LDQ，入 wait_mmu / mmu_done 队列
comb_tlb_out                   (H)  从 wait_mmu 窗口选请求 → lsu2mmu           (只读)
  MMU: translate_lsu_ports(lsu2mmu → mmu2lsu)
comb_tlb_in_ldq / comb_tlb_in_stq (I) MMU 响应落到 LDQ/STQ，窗口处理(STLF 入队 / finish 入队 / retry)
comb_stlf                      (J)  STLF 检查窗口：转发 / 重试 / 发 MMIO load / 入 wait_dcache / 入 finish
comb_dis2lsu                   (K)  Dispatch 的 LDQ/STQ 分配
comb_flush                     (L)  rob flush / mispred / clear_mask
comb_lsu2dcache_ldq / _stq     (M,N) 发 DCache 请求（load 窗口 / store 提交窗口）
comb_mmio_out                  (O)  发 MMIO 请求（只读 nxt.uncached）
comb_check                     (P)  retire：队首 Done 的 store 出队
seq                                  cur = nxt
```

关键事实：**所有 `comb_*` 都在同一个 `nxt` 上顺序修改**（`nxt` 在 `seq` 里被拷到 `cur`，所以每拍开始时 `nxt == cur`），后一阶段读到前一阶段改过的值；
只有少数地方显式读 `cur`（见下）。因此 RTL 不能把各阶段并行化，而是按 C++ 顺序把 `nxt` 的各个数组写成 SSA 链（每个阶段输出新版本），
一拍内是一条纯组合链：`G → H → (MMU) → I → J → M`（load 从 AGU 请求到发 DCache 请求可以在**同一拍**完成，MMU 命中时）。

读 `cur` 的位置（必须用寄存器值而不是链上的值）：
- `comb_cal/comb_lsu2dis`（全部，是“拍首”视图）；
- `comb_lsu2exe` 里 SC 的 `cur.lrsc_unit.reserve_valid/addr`；
- `comb_mmio_in` 里 `cur.uncached_unit`（链上此时与 cur 相同）；
- `comb_lsu2dcache_stq` 里 `cur.stq[..].store_state != WaitDcacheResp`（本拍刚收到 replay 响应的 store 不会在同拍重发）；
- `comb_lsu2dcache_ldq` 里 `cur.req_gen + issued`；
- `comb_flush` 里 clear_mask 分支用 `cur.ldq[i].load_state != Empty`、`cur.stq_head/stq_count`。

### 1.2 外部信号时刻核对（录制点在整个 `back.comb()` 之后）

| 输入 | 来源 | 最后写入 | 读取点 | 结论 |
| --- | --- | --- | --- | --- |
| `rob_commit.commit_entry[i].valid/uop.type/func7/stq_idx` | `Rob::comb_commit` | 之后只有 `BackTop::comb` 末尾覆盖 `uop.diag_val`（LSU 不读） | `comb_stq_commit` | 终值 = 读取值 |
| `rob_bcast.flush/head_*` | `Rob::comb_commit`（Rob.cpp:180-211） | 之后无写（`Rob::comb_flush` 只读） | `comb_stq_commit/stlf/flush` | 终值 = 读取值 |
| `dec_bcast.*` | `Idu::comb_branch`（Idu.cpp:188-200） | 之后无写 | `comb_flush` | 终值 = 读取值 |
| `dis2lsu.*` | `Dispatch::comb_alloc` 清零、`comb_dispatch` 填充（Dispatch.cpp:80-86、487-506） | `comb_fire` 不改 | `comb_dis2lsu` | 终值 = 读取值 |
| `exe2lsu.*` | `Exu::comb_exec`（Exu.cpp:476-482） | 之后 `Exu::comb_pipeline` 不再写 agu/sdu_req | `comb_exe2lsu` | 终值 = 读取值 |
| `mmu2lsu_io` | `BackTop::comb_lsu_mmu` | 之后无写 | `comb_tlb_in_*` | 终值 = 读取值 |
| `in.dcache2lsu` / `in.peripheral_resp` | `MemSubsystem::comb_outputs` / PeripheralAxi（`back.comb` 之前） | `mem_subsystem.comb_inputs` 在录制之后 | `comb_dcache2lsu_*` / `comb_mmio_*` | 终值 = 读取值 |
| `csr_status` | `SimCpu::cycle` 开头 | — | 只用于透传到 `lsu2mmu.csr_status` | 删除（见第 4 节） |

输出：`lsu2dis/lsu2rob/lsu2exe/lsu2mmu/lsu2dcache/peripheral_req` 都由 LSU 单独写，录制到的是 LSU 的最终值（`lsu2dcache`/`peripheral_req` 在 `mem_subsystem.comb_inputs` 里被读，不改写）。
没有 04 第 3.1 节意义上的 stale 读（所有跨拍状态都是 `cur`，链上读取的都是本拍更早阶段的结果）。

## 2. 硬件结构

重构依据见 `docs/analysis/lsu-structure.md`（每个字段的"事件 → 更新"规则表）。

```
 stage logic (组合；每阶段算"事件"和"队列操作")                      state (寄存器)
 B lsu_stq_commit      → cm_go[SQ]                         ┌─ lsu_stq_ent  × SQ : 状态机 + 字段写使能规则
 C lsu_mmio_in         → mm_ev[LQ], mm_go[SQ], finish op   ├─ lsu_ldq_ent  × LQ : 状态机 + 字段写使能规则
 D lsu_dc_resp_ld      → dc_ev[LQ], wait_dcache 槽 set/clr ├─ lsu_ring × 6      : wait_mmu_ldq / wait_mmu_stq / mmu_done /
 E lsu_dc_resp_st      → dc_ev[SQ], wk_go[SQ]              │                     finish / stlf / wait_dcache（每拍最多 6 个有序操作）
 F lsu_wb_stq/_ldq     → wb_ev/wb_go, 写回口, LR/SC 更新    ├─ lsu_stq_ptr       : head/head_flag/count/ccount
 G lsu_exe_in_st/_ld   → ex_ev[SQ], agu_ev[LQ], 入队操作    ├─ lsu_wd_slot       : wait_dcache 槽的 gen/wait, req_gen
 H lsu_tlb_sel         → MMU 请求口                          ├─ lsu_unc / lsu_lrsc: 未缓存单元 / LR-SC 预约
 I lsu_tlb_resp_ld/_st → tr_ev, tw_ev, 入队/出队操作          └─ (顶层 lsu.sv 只做端口适配；lsu_core.sv 只做连线)
 J lsu_stlf(+_chain,_match) → sf_ev[LQ], 队列操作, MMIO load 起占
 K lsu_alloc           → al_ev[LQ], al_ev[SQ]
 L lsu_flush_ring_ld/_st → 队列末操作；表项自己处理 flush/mispred/clear_mask
 M lsu_dc_req_ld / N lsu_dc_req_st → iss_go / is_ev, DCache 请求口 ; O lsu_mmio_out ; P (在 lsu_stq_ptr 内)
```

- **表项**（`lsu_ldq_ent`/`lsu_stq_ent`，每表项一个实例）：寄存器 = 状态机 + 数据字段（packed struct `ldq_fld_t/stq_fld_t`，
  `result`/`wait` 例外，见下）。输入是已限定的"事件"，表项内部按阶段顺序一条链地改状态（`st_rsp/st_agu/st_tlb/st_win/st_fl…`，
  每个视图一行规则，对应分析文档 §1/§2 的阶段表）；每个数据字段只有写使能 + 写数据（单一写阶段，
  `suppress/wait` 等多写者字段按阶段优先级）。同拍后续阶段需要读到本拍写入值的，读 `fld_e`（= 写后值），拍首值读 `fld_q`。
  `result` 与 `wait` 不放进 struct：J / N 阶段既读 struct 又写它们，放进去会形成 Verilator 看到的（变量级）组合环。
- **队列**（`lsu_ring`）：`lsu_ring_t = {valid[64], idx[64], head, count}`；每拍按阶段顺序给出最多 6 个操作
  `lsu_rop_t = {kill_slot, 窗口 kp（窗口内失效 + 弹出队首连续空洞）, append, flush}`，`view[k]` 为第 k 个操作后的队列；
  寄存器里 `idx[s]` 只在被追加的那个槽写入，`valid/head/count` 每拍更新。各队列的操作序列见分析文档 §3。
- 窗口内"顺序扫描 + 计数器 + 限额"全部写成窗口位置上的前缀计数（`lsu_rank`），`break` 写成位置链（`lsu_stlf_chain`）。
- 环形指针/年龄比较/排名保持硬件写法；`lsu_stq_ptr` 持有 STQ 指针和 P 阶段退休扫描。
- 顶层 `lsu.sv`（274 行）是 spec 端口的平铺适配（原来由 `gen_core.py` 生成，现在手工维护，生成脚本降级到 `tests/lsu/history/`）。

### 状态（寄存器）

| 状态 | 位宽×深度 | 含义 / 读写 |
| --- | --- | --- |
| LDQ 表项（×`LDQ_SIZE`） | `st`(4)、`vaddr/paddr/result`(32)、`func3`(3)、`dest`、`rob_idx/flag`、`br_mask`、`snap_idx/flag`、`replay`(2)、`mmio/pf/lrsc` | 写规则见分析文档 §1 |
| STQ 表项（×`STQ_SIZE`） | `st`(4)、`data/vaddr/paddr`(32)、`func3`、`dest`、`rob_idx/flag`、`br_mask`、`replay`、`wait`(3)、`data_valid/paddr_valid/pf/suppress/mmio/lrsc/sc_pass` | 分析文档 §2 |
| STQ 指针 | head 6 / head_flag 1 / count 7 / ccount 7 | `stq_commit = head + ccount` 不建寄存器 |
| 6 个环形队列 | 各 64×(1+6)+6+7 | `idx` 只在追加时写 |
| `wd_slot` | 每槽 `gen`(25)、`wait`(3)；`req_gen`(25) | 槽复用时保留旧值（C++ 可观察） |
| `unc_*` / `lrsc_*` | 未缓存单元 / 预约 | 分析文档 §4 |

### C++ → 硬件对应

| C++ | RTL |
| --- | --- |
| `LsuState cur/nxt` + `seq(){cur=nxt}` | 表项/队列/标量单元各自持有寄存器；一拍内的阶段链 = 表项内的状态视图链 + 队列操作链 |
| `enqueue_*/dequeue_*`（6 个队列） | `lsu_ring` 的 append / kp 操作 |
| `for(i<issue) … break/continue` 窗口扫描 | `lsu_ring_win` + 前缀计数 + `ttg_first_set` / 位置链 |
| `check_stlf` 的 for-j-break 逆序扫描 | 每个窗口位一个 `lsu_stlf_match`：64 个 store 的"决定者"向量，取最年轻的一个 |
| `comb_lsu2dcache_stq` 的 older 冲突 `for j<i` | 窗口内两两 `CheckAddr`，沿窗口位的 `done_after` 链 |
| `StoreTag/LoadTag` | `{idx, flag}` |

## 3. 一拍内的数据流

各阶段语义见第 1.1 节的顺序；下面是每个阶段翻译时的关键判断（逐条核对过 C++）。

- **B stq_commit**：8 个提交口顺序扫描；第 i 口被接受当且仅当它是 store 且 `stq_idx == commit_ptr + 已接受数` 且该项为 WaitCommit。`flush` 时写 Done+suppress；`is_lrsc && !sc_pass` 同；否则 Committed。`ccount` 饱和到 64。
- **C mmio_in**：`fire = peripheral_resp.is_mmio && cur.uncached.valid`。load：要求 `finish.count<64`，满足则（若该 LDQ 项为 WaitMmioResp）写结果、ReadyToWb、入 finish；**不论该项状态**，`uncached.valid` 清零（满足 finish 未满时）；store：项为 WaitMmioResp 则 Done，`valid` 清零。
- **D dcache_resp_ld**：每口按 `req_id` 取 wait_dcache 槽（`[5:0]`）+ 代号（`[30:6]`）核对，`req_id[31]=1` 的忽略；HIT → ReadyToWb+结果（`extract_data`）；否则 ReadyToIssue + `replay` 类型 + `replay_wait = (MSHR_HIT|MSHR_FULL)?4:0`。然后 MSHR fill 唤醒（窗口 20：MSHR_HIT 且同 cache line → wait=0；MSHR_FULL 取前 4 个 → wait=0），然后窗口内 ReadyToWb 的项入 finish（`finish.count + rank < 64`）并从 wait_dcache 中 invalid，再弹队首空项。
- **E dcache_resp_st**：同理按 `stq_idx=req_id`；HIT → Done；否则 Committed+replay；fill 唤醒窗口是 `min(ccount, count)`（最多 64）个 STQ 项，MSHR_FULL 取前 4 个。
- **F lsu2exe**：先处理 mmu_done 窗口（Ready/PageFault 的 STQ 项；SC 走 `wb_req`（上限 4），STA 走 `sta_wb_req`（上限 4），各自“前 4 个候选”）→ 再处理 finish 窗口（load，`n_sc + rank < 4`）。`sc_pass` 用 **cur** 的 lrsc 预约；SC 成功/失败都清预约；LR 写回时（非 page fault）设预约（同拍多个 LR 取窗口位置最大者）。
- **G exe2lsu**：STD（口序）→ STA（口序）→ LOAD（口序）。STD：rob 匹配则写 data；若 `paddr_valid && WaitData` → Ready + 入 mmu_done。STA：写 vaddr、`paddr_valid=0`、WaitTlb、入 wait_mmu_stq、`is_lrsc`。LOAD：写 vaddr 等、WaitTlb、入 wait_mmu_ldq。匹配只看 `rob_idx/rob_flag`，**不看项当前状态**（与 C++ 一致）。
- **H tlb_out**：窗口（20）内 valid 且状态 WaitTlb 的前 4 个 → 4 个 MMU 请求口（`wait_idx` = 队列槽号）。
- **I tlb_in**：4 个响应口按 `{wait_idx, entry_idx}` 核对队列槽；LDQ：状态非 WaitTlb 则作废该槽，HIT → WaitSTLF，PF → WaitFinish，MISS → WaitTlbRetry；STQ：只处理 WaitTlb 项。随后窗口处理：WaitSTLF → CheckStlf 入 stlf（每拍 ≤4 且 `stlf.count<64`）；WaitFinish → PageFault 入 finish；WaitTlbRetry → WaitTlb；STQ：WaitDone → Ready/PageFault 入 mmu_done，WaitData → 退出队列。
- **J stlf**：窗口 20，顺序处理并带 `break`（见第 2 节的链）：资源（wait_dcache 计数、finish 计数、`uncached.valid`）和“遇到不可处理项就停”作为位置链。
- **K dis2lsu**：LDQ 项由 Dispatch 指定 idx；STQ 项依次放在 `head+count+rank`，`count+rank<64` 才接受。
- **L flush**：`flush`（清全部 LDQ、STQ 只保留已提交项、所有队列清空）→ `mispred`（按 br_mask 杀 LDQ；STQ 从第一个命中项起截断；各队列按 LDQ/STQ 状态作废；uncached、lrsc 同）→ `clear_mask`（用 **cur** 的状态/窗口选择要清位的项）。
- **M/N**：load 窗口里“前 4 个可发”的项发 DCache，之前遍历到但未达到发射条件的 replay 项 `wait` 减 1；store 窗口依序判断（older 同地址未完成则阻塞；MMIO 只有窗口位 0 能发；suppress 的直接 Done）。
- **P check**：`min(ccount,count,20)` 个队首中连续的 Done 项退休。

## 4. 与 C++ 的差异点、放宽、删除、不复刻

### 4.1 spec 里删除的字段（消费者核对）

| 字段 | 理由 / 读取点核对 |
| --- | --- |
| `csr_status` → `lsu2mmu.csr_status` | 纯透传；读者只有 `TlbMmu::translate_lsu_ports`，集成时 MMU 直接接 CSR |
| `lsu2rob.tma.miss_mask` | 只有 perf（`LsuRobIO::tma`，TMA 统计）；`LdqEntry.cache_miss` 同 |
| `lsu2dcache.icache_req` | LSU 写的是常量 `LSU_LDU_COUNT`；DCache 读的 `in.lsu2dcache->icache_req` 是 MemRouteBlock 改写后的版本（MemRouteBlock.cpp:124-126） |
| `load_ports[].replay` / `store_ports[].replay` | 只被 `RealDcache` 写入 `slot.perf_replay`（perf） |
| `lsu2dcache.store_ports[].strb` 高 3 位、`req_id[31]` | `get_store_strb` 最大 `0x3<<3=0x18`；load `req_id` 的 bit31 恒 0 |
| `lsu2exe.*.uop.op/flush_pipe` | 每个口恒为 LOAD/STA、0（`to_micro_op` 后 `Exu` 只用 op 区分 ROB 完成类型）；集成时在 Exu 侧常量连接 |
| `lsu2exe.sta_wb_req.uop.{dest_preg,dest_en,page_fault_load}` | STA 写回恒 0 |
| `dis2lsu.func3`、`stq_flag` | `func3` 在 STA 到达时被覆盖（STA 之前无读取点：`stlf` 对 `!paddr_valid` 先重试，`comb_lsu2dcache_stq` 只对 Committed 项读）；`stq_flag` 只在 Assert 里比较 |
| `exe2lsu.*.op/br_mask/dest_en`、STA 口的 `ldq_idx/stq_flag` | `handle_*` 不读；AGU 口 0-3 静态是 LD 口（`OP_MASK_LD` → UOP_LOAD），4-7 是 STA 口（Exu.cpp:60-80），所以不需要 `op` |
| `dcache2lsu.load_resps[].{retry,bank_conflict}`、`store_resps[].bank_conflict` | LSU 不读 |
| `ld_diag_val` | 恒等于 `v_addr`（只在 page fault 时赋值，赋的就是 `v_addr`）；写回时 `result = page_fault ? v_addr : result` |
| `st_vaddr_valid, ld_v_addr_valid, ld_p_addr_valid` | 只写不读 |
| `lrsc.reserve_rob_idx/rob_flag` | 只写不读（BackTop checkpoint 恢复路径之外） |
| `stq.stq_flag`（项内） | 只在 `get_stq_entry`（无调用者）里读 |

### 4.2 放宽（`when`）

- `lsu2dis.ldq_alloc_idx`：读取点 `Dispatch.cpp:110-114` 受 `ldq_alloc_valid` 保护 → `when ldq_alloc_valid`。
- `lsu2exe.wb_req/sta_wb_req` 的 uop 字段：读取点 `Exu.cpp:533-560` 受 `valid` 保护。
- `peripheral_req.mmio_addr/mmio_fun3`：`PeripheralAxi.cpp:179-225` 只在 `is_mmio` 时读；`mmio_wdata` 只在 `wen` 时有意义（load 请求时 C++ 里是上一个 store 的残留，`rdata` 路径不读 wdata）→ `when peripheral_req_wen`。
- `lsu2dcache.load_ports/store_ports` 的 addr/data/strb/req_id：`RealDcache.cpp:250-331` 受 `valid` 保护。
- `lsu2mmu.*_req` 字段：`TlbMmu::translate_lsu_ports` 受 `valid` 保护（C++ 在无效口为 0，RTL 也可直接给 0，但按 06 用 `when`）。

### 4.3 不复刻的 C++ 行为

- `Assert`/`LSU_NON_BSD_ASSERT` 分支：LDQ allocate collision（`alloc_ldq_entry` 对非 Empty 项返回 false）、STQ overflow、`rob/flag mismatch` 的提前 return 之外的断言、`stq snapshot boundary is outside active STQ window`（`break`）、`STLF retry requeue overflow`、store resp 的 `idx>=STQ_SIZE`：不可达，RTL 取最简（LDQ 分配无条件覆盖；`req_id` 高位非 0 的 store 响应忽略，load 响应 `req_id[31]` 忽略，这两条是 C++ 的显式分支，保留）。
- **`stlf` 的 `stq_distance_from_head_to_boundary` 失败**：不可达（older 数 = `(snapshot - head) mod 2N` ≤ count），不复刻 `break`。
- **残留值**：`alloc_ldq_entry/alloc_stq_entry` 的 `entry = {}` 只复位真正会被读到的字段（LDQ：`page_fault`；STQ：data_valid、paddr_valid、page_fault、suppress、is_mmio、is_lrsc、sc_pass、replay、wait、br_mask、rob_idx/flag、state），其余字段在被读取前一定被 STA/LOAD/响应写过（见第 3 节 G/I）。
- **重复响应/重复请求命中同一项**（同拍两个 DCache 响应口或两个 MMU 响应口指向同一项、同拍两个 STD 指向同一 store）：C++ 靠顺序使后者成为空操作或覆盖；这些在 DCache/MMU/Exu 的协议下不可达，RTL 对 DCache 响应保留“前者生效”链（便宜），对 MMU 和 AGU 口不复刻。
- `stq_commit` 指针：C++ 里 `stq_commit == stq_head + stq_commit_count` 在每个修改处都成立（commit：两者同增；check：head 增、count 减；flush/mispred：显式重算），RTL 不建寄存器。
- 无符号回绕：`lsu2dis.ldq_free = LDQ_SIZE - ldq_count - wait_mmu_ldq_count`（uint32，`wait_mmu` 队列计数含空洞，可能使差为负，回绕成巨大正数，然后被 `min(·, ldq_empty)` 截住）。RTL 对“和 > 64”的情况选择第二个操作数，等价（`stq_free` 同）。`stq_free` 与 `ldq_free` 的这种“空洞计数”导致的背压属于参考模型的行为，保持。

### 4.4 参考模型疑点（按参考模型实现）

1. `comb_mmio_in`：load 响应在 `finish_count < LDQ_SIZE` 时**无条件**清 `uncached.valid`，即使该 LDQ 项已不在 WaitMmioResp（比如已被 flush 置 Empty）；而 `comb_flush` 里的 mispred 分支同拍也会清它。保持。
2. `comb_dcache2lsu_ldq` 里 `wake_load_replays_on_mshr_fill` 对 MSHR_FULL 只放行前 `LSU_LDU_COUNT` 个，没有区分“真的是满”。保持。
3. `lsu2exe` 的 STA 写回口和 `comb_tlb_in_stq` 的 `entry.valid=false` 之间没有对 `WaitData` 项重新入队的保护——靠 STD 到达时按 `paddr_valid && WaitData` 入 mmu_done，保持。
4. `comb_lsu2dcache_stq` 的 `cur_entry.store_state != WaitDcacheResp` 用 cur 而不是 nxt，导致 replay 响应的 store 至少隔一拍才重发。保持。
5. `stq_free`/`ldq_free` 的无符号回绕（见 4.3）。

## 5. 验证

### 5.1 重构（2026-11-04，分支 rtl/lsu2）

- RTL：`rtl/backend/lsu/` 33 个文件 3259 行（旧 34 个文件 3245 行，其中 `lsu_core/lsu_state/lsu` 三个生成文件 891 行）。
  最大文件 389 行（`lsu_core.sv`，纯连线），最长 `always_comb` 36 行（旧 40 行）。无生成文件（`gen_core.py` 移到 `tests/lsu/history/`）；
  `lsu.sv` 仍是 spec 端口平铺适配（274 行，现手工维护）。
- 旧版本链：`lsu_core` 里 134 处 `_v1.._v9` 引用、约 70 个整数组状态各带版本；新设计无 `_vN` 数组、无整数组 `_d`：LDQ/STQ 各 64 个表项实例，
  状态阶段视图（≤9 个 4 位状态）收在表项里，数据字段单写阶段 + 写使能。
- 触发器/门数：按协调者要求未做综合（yosys 被禁）。状态位数从代码读出：两版寄存器内容相同（LDQ/STQ 表项字段、6 队列、指针、unc/lrsc、wait_dcache 槽），
  新版去掉的是旧版的**组合**版本拷贝（旧版每个版本都是 64 项整数组的组合线）。未实测量化。
- spec/lsu.io 整程序锁步：`lockstep_multi.sh lsu`，BIG_CYCLES=300000，**68/68 PASS**（重构提交 3be6144 的 RTL）。
- 随机轨迹：`tests/lsu/run_rand.sh` + `scripts/replay.sh lsu`，**12/12 PASS**（rand_1..12）。
- lint：`bash scripts/lint.sh rtl/backend/lsu` 干净。
- back_top：协调者要求只跑冒烟：8 个短程序（smc-div atomic-boundary add-longlong interrupt-vectored timer-mmio stlf-overlap-boundary unalign memory-boundary）×50k 拍，back_top 与 lsu 同时锁步，**16/16 PASS**。重构后 back_top 整程序 68/68 **未重跑**。

- 本次重构**没有复刻**：C++ 一拍内的阶段调用结构与 `nxt` 整体拷贝；AGU 时 `p_addr=0/paddr=0` 复位（无人在 HIT 前读）；PAGE_FAULT 时 `result=v_addr`
  （写回用 `pf ? vaddr : result`）；数据字段/`wd_gen` 的复位（只复位状态位、指针、valid；无复位的存储器读前必写，见分析文档）；
  `LDQ_SIZE == STQ_SIZE` 的共用索引宽度沿用旧 RTL 假设（未加断言，S5 禁 initial）。
- 疑点/限制：`lsu_ring` 固定 6 个操作口（端口为离散信号，因 Verilator 对数组形端口的 UNOPTFLAT 误报）；窗口宽度 `LSU_LOAD_WINDOW_WIDTH` 须不小于各端口数。

### 5.2 变异检查（`tests/lsu/mut_lsu.py`：一次构建、`TTG_MUT=k` 运行时选，127 个变异体，覆盖新结构的优先级/年龄比较/转发/flush 环/replay/MMIO/LR-SC）

协调者在筛选中途叫停，**只跑了前 14 个**（筛选程序 smc-div memory-stress atomic-boundary vm_pagefault_test dhrystone）：

- 杀死（10）：pkg.stlf-cover-off-by-one、stlf-partial-as-disjoint、lb-offset-ignored、mmio-window1、store-strb-half、align-store-byte、
  ring.pop-live-entry、ring.kp-no-kill、ring.append-slot-ignores-rank、ring.flush-keeps-count。
- 筛选集上存活（4，**未判定**，未跑 12 程序复跑）：pkg.lh-lhu-swapped（原 M12 在旧测试里靠随机轨迹才杀死）、pkg.checkaddr-next-word、
  pkg.checkaddr-prev-word（原 M16）、pkg.stq-alive-inclusive。
- **未跑**：其余约 113 个（其中含对原存活变异 M05 M07 M08 M15 M16 M17 M18 M20 M21 M24 的新结构等价物：
  dcresp-ld.wake-full-limit-plus1、curinfo.ldq-free-no-wrap-check、dcreq-st.suppressed-not-unblocking、ptr.retire-window-unlimited、
  pkg.checkaddr-*、mmioin.ignores-finish-room、stlf.two-mmio-loads-same-cycle、tlbresp-ld.stlf-limit-ignored、dcreq-st.reissue-same-cycle）。
- **原 10 个存活变异体仍未结案**：M05 M07 M08 M15 M16 M17 M18 M20 M21 M24（旧 `tests/lsu/mutants.py` 描述；旧缺口分析见本节下文"覆盖缺口"）。
  M16 的新结构等价变异（checkaddr-next/prev-word）本次在筛选集上又存活，说明仍是覆盖缺口（需要跨字对齐的 store 同址冲突的定向程序）。

### 5.3 旧版验证记录（保留）

- spec：`spec/lsu.io`，111 个字段（输入 63、输出 48）。
- 实现：`rtl/backend/lsu/` 34 个文件 3211 行（其中 `lsu_core/lsu_state/lsu` 三个文件由 `tests/lsu/gen_core.py` 生成：一拍内约 20 个 `comb_*` 阶段在同一个 `nxt` 上顺序改写，RTL 把每个状态数组写成 SSA 版本链，阶段模块端口只含它读写的数组）。C++ 对应 RealLsu.cpp 1527 行。
- trace：61 个 gate 程序（8000 拍）+ progs.txt 的 12 个 = 73 个真实程序（669k 条记录）；另 12 个随机 trace `rand_1..12`（`tests/lsu/rand_trace.cpp`，驱动参考 `RealLsu`，不定义 NDEBUG，参考模型的 Assert 自检）。共 85 个全部 PASS。
- 随机生成器的外围模型与合法性约束：Dispatch 按 `lsu2dis` 的 ldq_alloc/stq_free/tail 分配（同 Dispatch.cpp，load 带 STQ 尾快照）；Exu 每个 uop 只发一次 LD/STA/STD（AGU 口 0-3=LD、4-7=STA，被杀的 uop 不发）；ROB 顺序提交，store 在 STA 写回且 STD 已发之后才提交，异常/随机“中断”以单条提交并带 `flush`，不与 mispredict 同拍（Rob.cpp 逻辑）；分支掩码/乱序解析/clear_mask/mispredict 杀；MMU 命中/miss/页错/无响应，flush 与 mispredict 拍静默（BackTop::comb_lsu_mmu）；DCache 延迟与 HIT/CONFLICT/MSHR_HIT/MSHR_FULL replay、mshr_fill、杀后过期响应（过滤会触发代号断言的组合）；外设单请求在途。覆盖：flush 1887 拍、mispred 1697、flush 拍提交 store 459、flush/mispred 拍分配 57、replay 三类各 2.5k、MMU miss 26.8k/页错 3.2k、LR/SC/AMO、MMIO load/store 4k、LDQ 满 2147 拍。
- **随机 trace 发现的真实 bug（已修）**：`alloc_ldq_entry` 的 `entry = {}` 把 `replay_type` 复位为 HIT；该字段被 `wake_load_replays_on_mshr_fill` 读（配合按槽残留的 `replay_wait_cycles`），RTL 原先没复位 → 复位已补（`lsu_alloc`）。真实程序覆盖不到。
- 覆盖缺口（如实报告）：mispredict 与 flush 同拍（ROB 逻辑下不可达，生成器也不产生）；stq_free==0 只有 2 拍；未对齐跨字访问（生成器只产生对齐访问，`CheckAddr` 的相邻字分支无法区分）；finish/wait_dcache/stlf 队列满（count==64）；`ldq_free/stq_free` 无符号回绕分支（需 wait_mmu 队列空洞计数 > 容量）；退休窗口 >20；同拍两个 MMIO load。
- 变异检查（`tests/lsu/mutants.py`，25 个，trace：dhrystone memory-stress atomic-boundary timer-mmio vm_pagefault_test rand_1 rand_2 rand_3 rand_5 rand_6）：**15 个被抓到**，首个失败字段@记录号：

| # | 变异 | 抓到 |
| --- | --- | --- |
| M01 | STLF 把快照边界上的 store 算 older | wb_req_valid @106（dhrystone） |
| M02 | STLF 决定者选择方向错 | 同类 |
| M03 | STQ 分配容量少 1 | lsu2dis_stq_tail @229（dhrystone） |
| M04 | load replay 倒计时晚 1 拍 | lsu2dcache_load_ports_valid @154（dhrystone） |
| M06 | store 提交忽略同拍前面的提交 | lsu2rob_committed_store_pending @91（dhrystone） |
| M09 | mispredict 多保留一个 STQ 项 | lsu2dis_ldq_free @47（rand_1） |
| M10 | load 写回口忽略 SC 占用 | wb_req_uop_result @5（rand_1，**仅随机**） |
| M11 | 可缓存窗口 1 当 MMIO | lsu2dcache_load_ports_valid（vm_pagefault_test） |
| M12 | LH/LHU 扩展互换 | wb_req_uop_result @5（rand_1） |
| M13 | STLF 覆盖判断差 1 | wb_req_valid @106（dhrystone） |
| M14 | CONFLICT replay 也等待 | lsu2dcache_load_ports_valid @8（rand_1，**仅随机**） |
| M19 | 页错不杀 LR/SC 预约 | wb_req_uop_result @12229（rand_1，**仅随机**） |
| M22 | 被取消的 store 参与转发/阻塞 | lsu2dcache_load_ports_valid（atomic-boundary） |
| M23 | clear_mask 不作用于 LDQ | wb_req_uop_br_mask @224（dhrystone） |
| M25 | load 请求匹配取反 rob_flag | lsu2mmu_ldq_req_valid @105（dhrystone） |

  存活 10 个（trace 未覆盖，见缺口）：M05 MSHR_FULL 唤醒上限 +1、M07 ldq_free 回绕、M08 suppress 的老 store 不解除同址阻塞、M15 退休窗口不限、M16 CheckAddr 相邻字、M17 MMIO load 响应忽略 finish 空间、M18 flush 时保留 MMIO store 不看状态、M20 同拍两个 MMIO load 抢 uncached 单元、M21 STLF 入队每拍上限、M24 replay 响应同拍重发 store。
