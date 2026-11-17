---
module: tlb_mmu
area: backend
rtl: rtl/backend/tlb_mmu
spec: tlb_mmu*
status: green
lockstep: 68/68 (DTLB+ITLB)
mutants: 34/34（20 仅随机）
note: ITLB 经 icache 验证
---

# tlb_mmu 设计笔记（后端 DTLB 实例）

> **更新（2026-11-12，rv64 / 现状）**：**rv64 为 Sv39**（`tlb_mmu_pkg.RV64 = (XLEN_BITS == 64)`）：3 级、每级 9 位 VPN、16 位 ASID（`satp[59:44]`）、叶子 `level` 2 位（0 = 4 KiB、1 = 2 MiB、2 = 1 GiB）；rv32 为 Sv32（2 级、10 位 VPN、9 位 ASID）。`satp_on`、`satp_asid`、`va_canonical`（Sv39 虚拟地址必须从第 38 位符号扩展，否则缺页）、`tag_match`（按叶子级别忽略低位 VPN）都在 `tlb_mmu_pkg`。**物理地址在两种位宽下都是 32 位**，PTE 只有 `ppn[19:0]` 能到达物理地址（下文 `ppn[21:20]` 被丢弃的论述对 rv64 同样成立，rv64 还丢掉更高位）。下文按 rv32 / 2 级描述。

## 1. 对应的 C++
- `back-end/Lsu/TlbMmu.cpp`、`include/TlbMmu.h`、`include/TlbMmuKernel.h`；类 `TlbMmu`（`Kind::DTLB`）。调用点 `BackTop::comb_lsu_mmu()`：
  `rob_bcast.fence → flush()`（return）；`rob_bcast.flush || dec_bcast.mispred → cancel_pending_walk()`（return）；否则 `translate_lsu_ports(lsu2mmu_io, mmu2lsu_io)`；`seq()` 在 `BackTop::seq`。
  三种模式每拍互斥且必有其一（fence > cancel > translate）。
- 实际生效的路径：`translate_lsu_ports → build_top_common_input → top_comb`（8 个 lane 串行调用 `core_comb`，`TlbMmuKernel.h` 是同一逻辑的 bit 级内核，
  `tlb_kernel_*_io_generator` 只是 `top_comb/core_comb` 的打包版本，翻译以 `top_comb/core_comb` 的语义为准）。`translate()` 单口路径、`walk_and_refill*`、本地 `PtwWalker`（`walker.start`）
  在 walk port 已连接时不会走到，不翻译。`last_retry_reason_`、`record_trace`、`trace_*`、`dump_debug`、`DebugState` 只服务调试，不翻译。
- 输入：`lsu2mmu_io`（ldq_req[4]/stq_req[4] 的 valid/vaddr/entry_idx/wait_idx；csr_status 的 satp、privilege、mstatus 的 MXR/SUM/MPRV/MPP）、`rob_bcast.fence/flush`、`dec_bcast.mispred`、
  PTW walk port（`dtlb_walk_port->comb_output()`：req_ready、resp_valid、resp{fault,vaddr,leaf_pte,leaf_level}）。
- 输出：`mmu2lsu_io`（ldq_resp[4]/stq_resp[4]：valid、result、paddr、entry_idx、wait_idx；唯一消费者 `RealLsu::comb_tlb_in_ldq/stq`）、
  对 walk port 的 `send_walk_req`（PTW 只用 `req.vaddr[31:12]` 和 `req.satp[21:0]`，`access_type` 被 PTW 强制为 0，MemPtwBlock.h:563/633）、`consume_resp`、`flush_client`。
- 录制点：`ttg_rec_cycle` 在 `back.comb()` 之后、`mem_subsystem.comb_inputs()` 之前。**PTW 输入的拍内值核对**：walk-port 适配器（`MemSubsystemPtwWalkPortAdapter`）的 `comb_out_`
  在 `consume_resp/send_walk_req/flush_client` 里会被 TlbMmu 自己改写，所以录制点读适配器会看到改写后的值。适配器的 `comb_out_` 由 `sync_ptw_port_outputs()` 从
  `ptw_block.comb_outputs().walk_clients[DTLB]` 复制而来（上一拍 `comb_inputs` 末尾/`seq` 末尾），本拍 `ptw_block` 没有再运行，所以**输入从 `ptw_block.comb_outputs()` 录**
  就是 TlbMmu 第一次读到的值（回放闭合性验证了这一点：输入错了 `ptw_walk_req_valid`/resp 对不上）。
  **PTW 输出**（`send_walk_req`/`consume_resp`/`flush_client`）从适配器的 `comb_in_`/`seq_in_` 读（只有 TlbMmu 在本拍写它们；`reset_cycle_input` 在录制点之后）。
  适配器类定义在 MemSubsystem.cpp 里，插件看不到，spec 里用局部镜像结构体（同布局：vptr + comb_in_ + seq_in_ + comb_out_）读取。

## 2. 硬件结构
```
 lsu req[8]  ─► tlb_mmu_lookup ×8 (并行 64 路比较 + 优先级选) ─┐
 tlb_mmu_store (64 项 + 替换指针 repl_q) ───────────────────────┤
                                                                ▼
 ptw resp ─► tlb_mmu_early ─► 本拍初始状态 ─► tlb_mmu_lane ×8（并行：各口自己的 miss / 同页 / 权限 / 两种回填视图下的结果）
 walk_q ─────────────────────────────────┘                      │
                    A 选择（first_set：第一个在 walk 页上缺失的口）─┤
                    B 选择（first_set ×3：walk 空闲 / A 成功 / A 出错 三种情况预先选好）─┤
                                  ▼                              ▼
          walk_d / refill(写 store) / ptw req,consume,flush     各口结果 = 末级二选一（视图 1 / 退休口 / 视图 0）
```
> **2026-11-17 EXP-042 改为并行**：原来 8 个口是 `chain[0] → lane 0 → … → lane 7 → chain[8]` 的串行链（综合深度代理 rv64 163 级，最长路径
> 查表 → 64 位 first_set（加法器式 `req & -req`）→ 8 个口依次串过去）。现在各口并行计算，口与口之间的依赖用两次 8 选 1 的 first_set 解决，
> 行为与串行版逐拍相同（`tests/tlb_par/`，见第 5 节）。下面第 3 节"lane 链"描述的是**参考行为**（C++ 的顺序语义），RTL 的实现方式见第 3 节末尾。

- 模块：`tlb_mmu_pkg`（类型/权限检查/地址合成函数）、`tlb_mmu_store`（TLB 阵列：valid 向量 + 项，fence 清 valid、refill 写 `repl_q` 槽并 +1）、
  `tlb_mmu_lookup`（一个口的全相联查表，最低下标优先）、`tlb_mmu_early`（walk 响应已回时的提前处理）、`tlb_mmu_lane`（一个端口自己能算的部分：旁路/权限/缺失判断，两种回填视图下的结果，最后按核心的选择出结果）、
  `tlb_mmu_core`（通用 N 口核心：模式选择、A/B 两次选择、walk 寄存器；ITLB 复用时 `FETCH=1, LANES=1`）、`tlb_mmu`（DTLB 顶层，只做端口适配）。
- 为什么口与口之间有依赖：8 个口共享**一个** walk 寄存器、一个 PTW 请求口、一个响应；`top_comb` 里 `shadow_walk/shadow_refill/shadow_req_ready/shadow_resp_valid` 一口传一口，
  先到的口先启动 walk / 先消费响应，后面的口看到更新后的状态。这是显式的优先级（口 0 最高），不是 C++ 的循环残留；但它不需要逐口串行实现，见第 3 节末尾。
- 状态：
  - `entry_valid_q[64]` + `entry_q[64]`（global,asid[9],level,vpn1[10],vpn0[10],ppn[20],perm[8] = 59 位）；`repl_q`（6 位，轮转指针，复位 0）；
  - `walk_q`（active, req_sent, vpn[20], access_type[2], satp[32], eff_priv[2], mxr, sum = 60 位）。
  - 无 `PendingRefill`/`flush_pending_` 状态：它们在 C++ 里是"本拍 comb 写、本拍 seq 提交"的影子，RTL 里就是 `*_d` 组合信号（refill 当拍旁路给各口、时钟沿写阵列）。
- C++ → 硬件：`tlb_entries_[64]`→`entry_q`；`repl_ptr_`→`repl_q`；`walk_regs_`/`walk_comb_`→`walk_q`/`walk_d`；`refill_comb_`→chain 里的 `refill_valid/refill` 与 store 写口；
  `flush_pending_`→`fence`（seq 里清 valid、repl=0、walk 清空，并丢弃同拍 refill）；`consume_completed_walk_refill`→`tlb_mmu_early`；`core_comb`→`tlb_mmu_lane`；`top_comb`→`tlb_mmu_core` 的 lane 链。

## 3. 一拍内的数据流
1. 模式：`fence`（`flush()`）> `cancel`（`flush||mispred`，`cancel_pending_walk()`）> translate。fence/cancel 拍 LSU 响应全 0（`mmu2lsu_io={}`），lane 全部无效。
2. `tlb_mmu_early`（translate 与 cancel 拍都执行，fence 不执行）：`walk_q.active && req_sent && 响应有效 && 响应页 == walk 页`。
   - translate：响应无错且按 **walk 里保存的** type/eff_priv/sum/mxr 权限通过 → 立即回填（refill，槽=repl_q）+ 消费响应 + walk 清空；响应出错或权限不过 → 不消费，留给 lane（正好撞上同页请求时给 FAULT）。
   - cancel：无错且权限通过 → 回填；**无论如何都消费**；walk 被 cancel 清空，但回填保留并在时钟沿写进阵列（`top_comb` cancel 分支只清 walk，`refill_next=in.refill`）。
3. lane 链（translate 拍）：初始状态 = `{walk0=early? 空 : walk_q, refill0=early refill, resp_valid0=ptw_resp_valid && !early消费}`（C++ 的 `shadow_walk_req_ready` 不建：发出请求后该口把 walk 置为 active+req_sent 并把响应对后面隐藏，之后没有口能再启动新请求，所以 PTW 的 `req_ready` 直接给每个口读，见 4 节第 5 条）。
   每个口：无效→透传；裸模式（`eff_priv==3 || satp[31]==0`）→ paddr=vaddr、HIT；
   查表命中（先看 refill 旁路再看阵列）→ 权限检查 HIT/FAULT；未命中→ walk 状态机：
   walk 空则本口启动（req_sent=0）；walk 属于别的页/satp → MISS；`!req_sent`：PTW 未 ready → MISS，ready → 发请求（本拍 ready/resp_valid 对后面的口失效）并 MISS；
   已发请求：响应无效 → MISS；响应页不符 → 消费(丢弃)并 MISS；页符合 → 消费，walk 清空，响应出错或权限不过 → FAULT，否则生成 refill，HIT，paddr 由响应合成。
   一拍最多一次回填（只有"消费响应"能产生回填，响应只能被消费一次）。
4. 提交：`walk_d = (fence||cancel) ? 空 : chain 末态 walk`；回填（非 fence）→ 写 `entry_q[repl_q]`、`repl_q+1`；fence → 清全部 valid、`repl_q=0`；PTW 请求内容 = 链末 walk 的 vpn/satp
   （发请求之后 walk 不会再被后面的口改写：响应已失效、walk 已 active，别页口只返回 MISS）。`ptw_walk_flush = fence||cancel`；
   `ptw_walk_resp_consumed = fence ? 0 : cancel ? early_hit : (early 消费 || 任一口消费)`。
5. 无 stale 读：所有读都是本拍 comb 值或寄存器；`last_retry_reason_` 不影响任何输出。
6. **并行实现（EXP-042）**。上面的链里，一拍内真正改变共享状态的口最多两个：
   - **A**：walk 在拍初 active 时，第一个"缺失且页/satp 与 walk 相同"的口（`a_req = miss0 & walk_same`，first_set）。它要么发请求（`!req_sent && req_ready`），
     要么消费响应（`req_sent && resp_valid`）；响应页与 walk 页相同则 walk 退休：出错/权限不过 → 该口 FAULT，否则该口 HIT 并产生回填 `refill1`。
     A 之前和之后的其余缺失口只能是 MISS（别的页 → OTHER_WALK；同页 → 已发请求、响应已被隐藏）。
   - **B**：walk 在拍初空闲（全部口），或被 A 退休（只有 A 之后的口），第一个缺失的口启动新 walk（`req_sent = req_ready`）。之后的缺失口都是 MISS。
   - 回填只有两种来源：拍初的 `early_refill`（视图 0）或 A 的 `refill1`（视图 1，内容 = 响应 + walk 页 + 当前 ASID，与是哪个口无关），所以每个口对两种视图都先算好
     `miss0/miss1` 和完整结果，A 之后的口在 A 成功时取视图 1。B 的三种情况（空闲 / A 成功 / A 出错）各有一个 first_set，最后按情况选。
   - 结果：`tlb_mmu` 深度代理 rv64 **163 → 67**（`tlb_mmu_lookup` 61 → 33：64 位 first_set 改成对数深度的前缀或），单元数 −5%；见 `docs/09-synthesis-report.md` 第 11 节。

## 4. 与 C++ 的差异点、放宽与消费者核对
**删除的字段（无消费者）**：`MMUResp` 全部字段保留；`PtwWalkReq.access_type`（PTW 强制 0，不读）、`PtwWalkReq.satp[31:22]`（PTW 只取 `satp & 0x3FFFFF`）、`vaddr[11:0]`（只取 `>>12`）；
输入侧 `PtwWalkResp.vaddr[11:0]`、`leaf_pte[9:8]`（RSW）、`leaf_pte` 的 PPN[21:20]（见下）、`leaf_level[7:1]`；mstatus 只取 MXR/SUM/MPRV/MPP 四个位；
`retry_reason/trace_*`（只用于 debug dump）；`TlbEntry.ppn[21:20]`：`compose_paddr` 结果是 32 位，`ppn<<12` 的 ppn[21:20] 被截断，永不影响任何输出，所以阵列只存 `ppn[19:0]`（spec 输入也只录 20 位）。
**放宽（`when`）**：
| 字段 | 限定 | 消费者核对 |
| --- | --- | --- |
| `{ldq,stq}_resp_result/entry_idx/wait_idx` | `*_resp_valid` | `RealLsu.cpp:361/436` 只在 `resp.valid` 内读；`resp.valid=0` 时 C++ 整个 resp 为 0 |
| `{ldq,stq}_resp_paddr` | `*_resp_hit`（= valid && result==HIT，严格比较） | LSU 只在 `result==HIT` 分支读 `resp.paddr`（RealLsu.cpp:372/446）；MISS/FAULT 的 paddr C++ 是 0，RTL 不强制 |
| `ptw_walk_req_{vpn,root_ppn}` | `ptw_walk_req_valid` | PTW 只在 `req_valid` 时读 req（MemSubsystem.cpp:1072 → MemPtwBlock apply_port_inputs） |
`*_resp_hit` 是只为 `when` 存在的限定输出（`when` 必须引用输出），已严格比较。
**不复刻**：`walker`（本地遍历器）路径；`tlb_capacity` 非 2 的幂的取模（`DTLB_ENTRIES=64`，用位宽回绕 + 参数断言）；`TlbEntry` 在 fence 后清零所有字段（RTL 只清 valid，无效项内容不可观察）；
`valid=0` 的口里 `lookup` 内容（C++ 不查表，输出无意义）；`core_comb` 里 `retry_reason`、`trace_source` 的写入；`translate_lsu_ports` 里对 `resp.paddr` 的 `result==OK ? p_addr : 0` 清零。
**疑点（参考模型行为，已按 C++ 实现）**：
1. 缓存响应出错且无人请求该页时，响应一直留在 PTW 端口、walk 一直 active，直到有同页请求（FAULT）或 cancel/fence 清除。
2. cancel 拍：已回的合法响应仍会被回填进 TLB（`cancel_pending_walk` 先 `consume_completed_walk_refill(true)`，top 的 cancel 分支保留 `refill_next`），并且出错/权限不过的响应也被消费。
3. `walk.satp != satp`（整字比较，含 ASID）也会让同页请求被判为 OTHER_WALK_ACTIVE；satp 的 MODE 位在能走到该比较的路径上恒为 1。
4. 8 个口（`LSU_LDU_COUNT` 个 load 口在前，`LSU_STA_COUNT` 个 store 口在后）按口号优先，口 0 最高；C++ 里 ldq 口先于 stq 口。RTL 并行实现，优先级由 first_set 体现（第 3 节第 6 条）。
5. `shadow_walk_req_ready` 在 C++ 里发请求后清零，RTL 不复刻：一拍要发第二个请求，必须有 walk 再次空闲，而空闲只能由"消费响应"造成，响应在发请求时已被隐藏——因此该清零不可观察（变异 `req_ready` 清零不会改变任何输出；见变异表说明）。
**隐含依赖表登记**：无 stale 读（见第 3 节第 5 点）；PTW 端口输入需从 `ptw_block.comb_outputs()` 取而非适配器（录制细节，见第 1 节）。

## 5. 验证
- **并行化（EXP-042，2026-11-17）**：`tests/tlb_par/run.sh [周期]` 把并行核心与旧串行核心（`tests/tlb_par/tlb_mmu_core_ref.sv`、`tlb_mmu_lane_ref.sv`，原样保留）并排，同一组随机输入（小页池、超级页邻居、satp/特权/MPRV 随机、PTW 响应多数对准 walk 页、fence/cancel）逐拍比较全部输出，DTLB（8 口）和 ITLB（`FETCH=1`，1 口）各一份，`ENTRIES=8` 让替换和重叠项常见；同时把 `ttg_first_set` 与 `req & -req` 在 N=1/3/7/8/13/64 上比较。rv64 300 万拍 0 不一致（rv32 配置包在改动时也跑过 500 万拍 0 不一致）；3 个人为变异（A 不查权限、B 不限 A 之后、不用视图 1）均在 10 万拍内被抓到。
  整芯片（基于 main `8abb7ab`）：`lint_chip` 0 警告；fm_gate 67/67、周期与 `ref_cycles.txt` 0 差异；Linux 检查点窗口 s03/s07/s11（各 400 万周期，对 trace-model main `5b95b35`、function-model main `55affa0`）3/3 PASS，rtl.out / rtl.err 与同环境下 rtl main 逐字节相同。
  以下为 2026-11-03 翻译时的验证记录（逐模块 lock-step 系统已于之后退役）。
- spec：`spec/tlb_mmu.io`，41 个字段名（输入 24、输出 17；LSU 侧字段是 4 路数组，总比特数见 trace 头）。PTW 输入取自 `ptw_block.comb_outputs()`（见第 1 节），PTW 输出取自适配器 `comb_in_/seq_in_`（局部镜像结构体）。
- trace：73 个真实程序（61 个 gate 测试 + dhrystone/coremark/coremark10 + 4 个 vm 测试 + float/sha/cjpeg/linear_alg/parser，各 ≤30000 拍，vm 测试跑到结束 ≈2.7–69k 拍）+ 6 条随机（4 条 20 万拍；2 条 10 万拍 `stale`），共 79 条、1.76M 条记录，全部 PASS。
- 真实程序覆盖（全部 73 个程序合计）：DTLB 的页表遍历只有 7 次请求/7 次响应消费、1 次出错响应、9 次 fence，且全部在 M 态 + MPRV 下（vm 测试）或 S/U 态很少的拍；**没有**：TLB 填满/替换、超级页、A/D 位缺失的权限错、cancel 拍已有响应、
  多口同拍共享一次 walk、满 8 口并发、重叠表项。这些只靠随机 trace 覆盖（`tests/tlb_mmu/rand_trace.cpp`，`run_rand.sh`）。
- 随机生成器：直接驱动参考 `TlbMmu`（Kind::DTLB），调用顺序与 `BackTop::comb_lsu_mmu` 相同，PTW 对端是 mock（同 `MemSubsystemPtwWalkPortAdapter` 的端口语义 + `MemPtwBlock` 的 walk 客户端语义：
  一次一个请求、延迟 0–6 拍、响应保持到消费/新请求/flush、出错响应 `{fault,vaddr}`、叶子响应 = 原始 PTE + level）和一个随机 Sv32 页表内存（3 个地址空间、含同 ASID 不同根、非法/!R&W/未对齐超级页/非叶子指针）。
  合法性依据见该文件头注释：LSU 请求、CSR 状态、fence/flush/mispredict 均为任意合法值；页表在运行中被改写而不 fence（对模型合法，是产生 4K/超级页重叠表项的唯一途径）；
  `stale` 两条额外在 PTW 里注入"错页响应"（真实 PTW 靠 `walk_drop_resp_credit` 不会产生，仅覆盖防御分支，单独成文件）。参考模型 Assert 全开（无 NDEBUG）自检。
  随机 trace 统计（每条 20 万拍）：fence 170–350 次、walk 请求 5–6k、回填 800–1000、TLB 满后替换 0–120 次、cancel 拍消费响应 ≈700–1100 次、结果 MISS/HIT/FAULT ≈ 36/27/10 万。
- 变异（`tests/tlb_mmu/run_mutants.py`，34 个，全部被抓；"真实" = 73 个真实程序，"随机" = 4 条主随机 trace，"stale" = 2 条 stale 随机 trace）：
  | 变异 | 首先被谁抓到（trace, 记录号, 字段） |
  | --- | --- |
  | perm_sum（SUM 判断取反） | 随机 rand_a rec 7 `ldq_resp_result` |
  | perm_dirty（store 不查 D） | 随机 rand_a rec 4292 `stq_resp_result` |
  | perm_mxr（MXR 读 X 页） | 随机 rand_a rec 83599 `ptw_walk_req_valid` |
  | perm_user（U 位判断取反） | 随机 rand_a rec 261 `ldq_resp_result` |
  | perm_accessed（store 才查 A） | 随机 rand_a rec 1691 `ldq_resp_result` |
  | paddr_mega（超级页地址合成错位） | 随机 rand_a rec 6042 `ldq_resp_paddr` |
  | match_global（global 项也比 ASID） | 随机 rand_a rec 374 `ldq_resp_result` |
  | match_asid（忽略 ASID） | 真实 vm_asid_test rec 67147 `ldq_resp_result` |
  | match_level（超级页也比 vpn0） | 随机 rand_a rec 6264 `ldq_resp_result` |
  | priv_mprv（MPRV 选 MPP/特权级取反） | 真实 vm_asid_test rec 66906 `stq_resp_result` |
  | repl_stuck（替换指针不前进） | 真实 vm_asid_test rec 67435 `ldq_resp_result` |
  | fence_repl（fence 不清替换指针） | 随机 rand_a rec 80130 `ldq_resp_result` |
  | fence_valid（fence 不清 valid） | 真实 vm_sfence_perm_test rec 36835 `ldq_resp_result` |
  | lookup_prio（多项命中时 OR 而不是最低下标） | 随机 rand_a rec 21108 `stq_resp_paddr` |
  | early_perm（提前回填不查权限） | 随机 rand_a rec 7 `ldq_resp_result` |
  | early_type（提前回填用错访问类型） | 随机 rand_a rec 1734 `ptw_walk_req_valid` |
  | cancel_consume（cancel 只消费可回填的响应） | 随机 rand_a rec 12015 `ptw_walk_resp_consumed` |
  | cancel_walk（cancel 不清 walk） | 随机 rand_a rec 12334 `ptw_walk_req_valid` |
  | cancel_refill（cancel 丢弃提前回填） | 随机 rand_a rec 70964 `ldq_resp_result` |
  | consumed_early（提前回填不报消费） | 真实 vm_asid_test rec 66973 `ptw_walk_resp_consumed` |
  | root_ppn（PTW 请求根页号错位） | 真实 vm_asid_test rec 66968 `ptw_walk_req_root_ppn` |
  | walk_satp（同页判断不比 satp） | 随机 rand_a rec 363 `ldq_resp_result` |
  | walk_page（同页判断少比一位） | 随机 rand_a rec 178 `ptw_walk_resp_consumed` |
  | walk_priv（walk 里存特权级而非有效特权级） | 随机 rand_a rec 4114 `ldq_resp_result` |
  | refill_asid（回填 ASID 清零） | 随机 rand_a rec 3507 `stq_resp_result` |
  | resp_fault（walk 响应不查权限） | 随机 rand_a rec 7 `ldq_resp_result` |
  | bare_mode（satp.MODE=0 不走直通） | 真实 software-interrupt-vectored rec 395 `stq_resp_result` |
  | refill_bypass（同拍回填不旁路） | 真实 vm_asid_test rec 66973 `ldq_resp_result` |
  | lane_order（口 0–3/4–7 的访问类型互换） | 真实 vm_sfence_perm_test rec 36839 `ldq_resp_result` |
  | top_cancel（cancel 只看 flush 不看 mispred） | 真实 vm_asid_test rec 61 `ptw_walk_flush` |
  | top_fence_prio（flush 与 fence 同拍时 fence 失效） | 真实 vm_sfence_perm_test rec 36835 `ldq_resp_result` |
  | ld_idx（load 响应 entry/wait 下标互换） | 真实 vm_asid_test rec 135 `ldq_resp_entry_idx` |
  | resp_hide（发请求后不隐藏响应） | stale rand_stale_a rec 16341 `ptw_walk_resp_consumed` |
  | walk_resp_vpn（响应页比较少一位） | stale rand_stale_a rec 50844 `ldq_resp_result` |
  真实程序能抓 12 个；只有主随机 trace 能抓 20 个；只有 stale 随机 trace 能抓 2 个。
  不可观察（等价）的冗余：C++ 的 `shadow_walk_req_ready` 清零（见第 4 节第 5 条，RTL 已删除，不是变异）。
