---
module: ptw_walk
area: memsys
rtl: rtl/memsys/ptw_walk
spec: ptw_walk
status: green
lockstep: 68/68
mutants: 29 个中 28 杀死，1 等价
note: 只翻默认配置下活着的部分
---

# ptw_walk 设计笔记（MemPtwBlock 活着的部分：两个 walk 客户端共享一个页表遍历器）

分析与边界见 `docs/analysis/memsys-boundary.md` §2.3；录制点 `docs/analysis/memcpu-record-hook.md`。

## 1. 对应的 C++
- `MemSubSystem/include/MemPtwBlock.h`（1236 行，**活着的只有 walk 客户端 + walker 状态机，约 330 行**：`State/WalkClientState`、`apply_port_inputs`、`send_walk_req`、`select_walk_owner`、`project_outputs_from_state`、`apply_grant/events/wakeups`、`on_walk_read_granted`、`on_walk_mem_resp`、`retry_active_walk`、`flush_walk_client_state`）。
- **死代码（核实，不翻）**：`PtwWalker.cpp/.h`（`lldb` 在 4 个会走页表的 vm 程序上对 `PtwWalker::start/tick` 下断点，命中 0 次）、`PtwMemPort` 路径（`MemSubsystemPtwMemPortAdapter::send_read_req` 命中 0 次，68 个程序 `ptw_memclient_req_valid = 0`、`MEM_DTLB/ITLB` 的 grant/event/wakeup 为 0）、`PtwCompactCoreKernel.h`（整个源码树没有调用者）、`on_walk_mem_replay`（路由块 `replay` 恒 0）、事件槽 1..3、`access_type`。
- 调用顺序（`MemSubsystem::comb_inputs/seq`）：`comb_begin(客户端输入)`（latch 请求、选 walk owner、算 `issue_walk_read/addr`）→ 路由块 `comb_request` → `comb_finish(grant, event, wakeup)` → `seq(walk_client_flush)`。边界每 CPU 周期一条记录（`spec/ptw_walk.io`，21 字段）。

## 2. 硬件结构
```
 TLB(2) ─ req/vpn/root_ppn/resp_consumed/flush ─► ptw_walk_client ×2 ──pending/vpn/root──► ptw_walk_engine ──► issue_walk_read, addr ─► mem_route
          ◄─ req_ready/resp_valid/fault/vpn/ppn/perm/level (寄存器直出)   ◄─ sel/publish/pub_*    ▲  grant / event(data,id) / wakeup ◄─ mem_route
                                                                                      ptw_walk_pte (PTE 分类)
```
| 模块 | 职责 |
| --- | --- |
| `ptw_walk`（顶层）| 端口适配 + 两个客户端 + 引擎 |
| `ptw_walk_client` | 一个 TLB 的端口寄存器：请求锁存（忙时忽略）、`pending→inflight→resp_valid`、冲刷（最后生效）；TLB 只看到寄存器 |
| `ptw_walk_engine` | 遍历器 FSM `IDLE→L1_REQ→L1_WAIT→(L2_REQ→L2_WAIT)→IDLE`、轮转选客户端、读地址、grant/event/wakeup/flush 优先级链 |
| `ptw_walk_pte` | PTE 分类（V/R/W/X + 超级页对齐）；`fault/pointer/leaf` + ppn/perm 切片 |

状态：引擎 `state(3) owner(1) rr(1) l1_ppn(20) req_id(4)`，每客户端 `pending inflight resp_valid fault level vpn(20) root_ppn(20) leaf_ppn(20) perm(8)` ≈ 2×(3+2+20+20+20+8)；总共约 170 位（C++ 约 185 位 + `walk_req_id(32)`）。

## 3. 一拍内的数据流（**同拍 select→issue 组合路径**）
1. 客户端（`apply_port_inputs`）：`resp_valid_a = resp_valid & !consumed & !req_valid`（任何 `req_valid`——哪怕客户端忙——都清掉陈旧响应）；`latch = req_valid & !(pending|inflight)`，`pending_a = pending | latch`，`vpn_a/root_a` = latch ? 输入 : 寄存器。
2. 选择（引擎，仅 IDLE）：`rr` 优先，另一个其次；选中者 `pending→inflight`，`state_b=L1_REQ`，`rr<=!owner`。**本拍新锁存的请求可以当拍被选中**。
3. 读请求（组合）：`state_b=L1_REQ` → `{root_ppn[19:0], vpn[19:10], 00}`；`L2_REQ` → `{l1_ppn[19:0], vpn[9:0], 00}`（`(ppn<<12)+(vpn<<2)` 在 32 位里没有进位，ppn[21:20] 被移出）。
4. grant（路由块上一步算出）：`REQ→WAIT`，记 `req_id`。
5. PTE 事件：`event_hit = valid & 在 WAIT & event.id == req_id`（否则是被冲刷的旧 walk 的陈旧响应，忽略）；L1：无效/`!R&W`→fault，`R|X`→叶（`ppn[9:0]≠0` → fault，否则 level=1），否则 pointer（`l1_ppn<=pte.ppn`，→`L2_REQ`）；L2：无效/`!R&W`/`!(R|X)`→fault，否则叶（level=0）。发布到 owner 客户端（`inflight→resp_valid`，fault 时 ppn/perm/level 清 0）。
6. wakeup：对活着的 walk 的 `WAIT→REQ`（重新发读）；发生在事件之后，所以"grant 后同拍 wakeup"也回到 REQ。
7. flush（时钟沿上，叠在最后）：客户端 `pending/inflight/resp_valid` 清零；若该客户端是活着的 walk 的 owner → `IDLE`。
TLB 在下一周期读到的 `req_ready/resp_*` 是步骤 1–7 之后的寄存器值（= C++ `seq` 里 `refresh_outputs` 的投影）。

## 4. 与 C++ 的差异点、放宽、不复刻
### 4.1 删除 / 简化
| 项 | 理由 |
| --- | --- |
| `walk_drop_resp_credit`（无界 uint32）| **写后无人读**：它只在 `on_walk_mem_resp` 里决定返回 `DROPPED` 还是 `IGNORED`，两者对状态没有任何别的影响（`apply_events` 丢弃返回值）。删除；打包版的 2 位饱和计数器与活代码不等价，更没有意义 |
| `walk_active` / `walk_req_id_valid` | 与 `state≠IDLE` / `state∈{L1_WAIT,L2_WAIT}` 恒等（每次置位/清零都成对出现，已逐处核对 `select_walk_owner`、`on_walk_read_granted`、`publish_*`、pointer 分支、`retry_active_walk`、`flush`），由状态派生 |
| `walk_req_id`（size_t）→ 4 位 | 只做相等比较；陈旧事件的 id 是上一拍请求的 id，与现行 id 差 ≤1（`mem_route.md` §4.3）|
| `satp` 高 2 位、PTE 的 ppn[21:20]/RSW | 被 `(ppn<<12)` 移出 32 位地址，不影响任何输出（TLB 只用 `leaf_ppn[19:0]`，`tlb_mmu.io` 同）。输入端口保留 22 位（与 `tlb_mmu.io/icache.io` 一致），`lint_off UNUSEDSIGNAL` 局部豁免并注明 |
| `resp.vaddr[11:0]`、`resp.leaf_pte` 的高位 | TLB/ICache 只读 vpn、`leaf_ppn`、`perm`、`level` |
| `resp.vaddr` 单独存储 | `resp_valid` 为真期间请求寄存器不会变（新请求会同时清 `resp_valid`）→ 直接用请求 vpn |
### 4.2 放宽（`when`）与消费者核对
`client_resp_{fault,vpn,leaf_ppn,leaf_perm,leaf_level}` 限定 `client_resp_valid`：TLB（`TlbMmu.cpp:1307-1322`）与 ICache（`icache_itlb`）都先看 `resp_valid` 再读负载。`walk_read_addr` 限定 `issue_walk_read`（`MemRouteBlock.comb_request` 只在 `ptw_walk_req.valid` 时读 `addr`）。`resp_fault=1` 时 ppn/perm/level 严格为 0（TLB 不 `when fault`，RTL 清零）。
### 4.3 不可达（C++ 行为不复刻，取最简）
`grant` 到达时 walk 不在 `*_REQ`（grant 只在 `issue_walk_read` 为真的同拍产生）；`on_walk_mem_resp` 里 `else publish_fault()`（`active_req` 蕴含 WAIT 状态）。trace 与随机都未出现。
### 4.4 登记的疑点
- `send_walk_req` 在客户端忙时仍执行 `resp_valid=false`（先清响应再检查忙）——TLB 只在 `req_ready` 时发请求，不可达；RTL 复刻（`resp_valid_a` 里 `!req_valid`）。
- `flush` 对"本拍刚发布的结果"也清零 `resp_valid`（冲刷叠在最后）——复刻。
- 陈旧 L1 事件 / wakeup 作用于已被冲刷再重新发起的新 walk（wakeup 不带 id）：新 walk 会被多余的 wakeup 打回 `REQ`、重发读（行为正确但多一次读）——复刻，随机覆盖 `wake_idle`/`wake_wait`。

## 5. 验证
- spec：`spec/ptw_walk.io`（21 字段）。
- 整程序实时锁步：68 个程序 **68/68 PASS**；但只有 4 个 vm 程序会走页表，共 **20 次 walk 授权**（L1 无效 2、L1 指针 9、L2 叶 9、1 次故障）——**真实程序覆盖极薄**（见 `docs/analysis/data/memcpu_coverage_68prog_200kcyc.txt`）。
- 随机生成器（`-DMOD_PTW`，驱动**真实** `MemPtwBlock`，TLB 客户端按 `PtwWalkPortAdapter` 语义行为：只在 `req_ready` 时发请求、只在 `resp_valid` 时消费、冲刷随机；路由反馈按真实时序：授权后下一拍事件，id 与相邻请求交错；PTE 含全部 V/R/W/X 组合、超级页对齐/错位）：6 个 profile × 6 万拍全 PASS。覆盖（profile 0）：授权 23751、事件 19015（其中 walk 空闲 2780、id 不匹配 833）、L1 指针 4987、故障发布 5593、L1 叶 2335、L0 叶 2524、等待中 wakeup 6257、空闲 wakeup 464、冲刷活着的 walk 1362（其中等待中 789）。
  **随机首先抓出的问题是生成器的**（陈旧 id 取了很久以前的授权，4 位 id 恰好与现行 id 相差 16，产生别名）——说明 4 位 id 的前提（陈旧事件只来自上一拍请求）是必要的，已改成真实时序并在 §4.1 与 `mem_route.md` §4.3 写明。
- 变异：见下表（`tests/memcpu/ptw_walk_mutants.py`）。
  **29 个变异体，28 个被杀**（11 个真实程序锁步也杀：地址切片 `vpn[19:10]/[9:0]`、ppn 切片、`l1_ppn` 移位、root 不锁存、指针后状态、grant 后状态、发布到错误客户端、`resp_consumed` 忽略、冲刷保留 `resp_valid`、fault 时保留 level）；17 个只有随机能杀（PTE 各类故障、超级页对齐检查（只有 `rand1` 第 43112 条记录才杀——对齐位 `ppn[10]` 偶发，较弱）、陈旧事件 id、事件在非等待态、wakeup 忽略、冲刷任意客户端、忙时选择、`rr` 不翻转、冲刷保留 pending/inflight、忙时锁存请求）。1 个存活 = `engine_cpu_en_ignored`（锁步里 `cpu_en` 恒 1，等价）。
  **只靠随机才杀的变异：17/29**——真实程序对 PTW 的覆盖不足以证明这些规则（唯一来源是随机生成器，它驱动真实 `MemPtwBlock` C++ 类）。
