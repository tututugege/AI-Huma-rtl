---
module: mem_route
area: memsys
rtl: rtl/memsys/mem_route
spec: mem_route
status: green
lockstep: 68/68（16 tick）
mutants: 31 个中 28 杀死，3 等价
note: 
---

# mem_route 设计笔记（MemRouteBlock：LSU / ICache / PTW → DCache 第 3 号读口的路由）

分析与边界见 `docs/analysis/memsys-boundary.md` §2.2、§4；录制点见 `docs/analysis/memcpu-record-hook.md`。本文是 RTL 设计笔记（先于 RTL 完成接口与规则，最终以实现为准）。

## 1. 对应的 C++
- `MemSubSystem/MemRouteBlock.cpp`（147 行）+ `include/MemRouteBlock.h`（`comb_response` 在 `MemSubsystem::comb_outputs`、早于 `back.comb`；`comb_request` 在 `comb_inputs`、晚于 `back.comb`；`seq` 在 `MemSubsystem::seq`）。
- 一个 CPU 周期（tick 0）一次；tick 1..15 不运行。边界 = 每 CPU 周期一条记录（`spec/mem_route.io`，51 个字段），记录把同一周期的两次调用并成一条：响应侧输入/输出 + 请求侧输入/输出。
- 输入：DCache 发布的响应（4 load + 4 store + `mshr_fill/addr`）、LSU 请求（4 load + 4 store）、ICache 请求（`req_valid/addr`）、PTW walk 读请求（`issue_walk_read/walk_read_addr`）。
- 输出：LSU 看到的响应、DCache 请求（LSU 请求直通，load 口 3 可被抢占）、`icache_resp`、PTW 的 `grant/event/wakeup`。

## 2. 硬件结构
```
 DCache resp ─┬─► mem_route_resp ─► LSU resp (load P3 被改写)         ┌─ state: issued_owner/id, ptw_wait, lsu_replay, next_id
              │        │  └──────► icache_resp / ptw_event / wakeup    │
 LSU req ─────┼─► mem_route_req  ─► DCache req (load P3 被抢占)  ◄──────┘ mem_route_state（cpu_en 使能的寄存器）
 ICache/PTW req ┘        └──────► ptw_grant, 记录被挤掉的 LSU 请求
```
| 模块 | 职责 |
| --- | --- |
| `mem_route`（顶层）| 端口适配；store 响应/请求、`mshr_fill` 是纯直通（C++ 的 memcpy）|
| `mem_route_req` | 仲裁 ICACHE > WALK（同一 owner 不能连续两拍），load 口 3 的 DCache 请求多路，`ptw_grant`，被挤掉的 LSU 请求记录 |
| `mem_route_resp` | 路由响应判别（上拍的 owner、`req_id` 路由位+id 匹配）、LSU 视图改写、`icache_resp`、PTW 事件/唤醒、`ptw_wait` 次态 |
| `mem_route_state` | `issued_owner(2b) issued_id(4b) next_id(4b) ptw_wait lsu_replay_valid lsu_replay_id(31b)`，复位值 = C++ `init()` 后（路由 id 从 0x80000000 起，只留低 4 位）|
| `memcpu_pkg` | 本组 4 个模块共享常量（口数、id 位宽、owner 枚举）|

状态共 ~45 位。C++ `MemRouteBlockState` 的 `issued_tags.req_addr`（只喂 `ptw_events.req_addr`，PTW 不读）、`next_req_id` 高位删除。

## 3. 一拍内的数据流
响应侧（仅依赖寄存器 + DCache 响应，**无** comb 环）：
1. `own_resp = issued_owner≠NONE && load_resp[P3].valid && resp.req_id[31] && resp.req_id[3:0]==issued_id`；`is_hit/is_conf/is_wait` = `own_resp` 且 replay = HIT / CONFLICT / MSHR_HIT|MSHR_FULL。
2. LSU 视图：所有口上路由 id（bit31）的响应被隐藏；`own_resp` 时 P3 被替换为 {valid=`lsu_replay_valid`, req_id=`lsu_replay_id`, data=0, replay=CONFLICT}（回给被挤掉的 LSU load）。
3. `icache_resp`：owner=ICACHE：HIT → valid/data；CONFLICT → valid，`retry`=DCache 的 `retry`，否则 `miss`；MSHR_HIT/FULL → valid+miss。
4. PTW：owner=WALK 且 HIT → `ptw_event{data, id}`；`wakeup_walk` = (owner=WALK 且 (CONFLICT 或 (等待且本拍 `mshr_fill`))) 或 (`mshr_fill` 且 `ptw_wait`)。`ptw_wait_d`：`mshr_fill` → 0；等待响应且无 fill → `owner==WALK`；否则保持。
请求侧：5. `icache_cand = ic_req.valid && issued_owner≠ICACHE`，`walk_cand = walk.valid && issued_owner≠WALK`；owner_d = ICACHE > WALK > NONE。6. 有 owner：DCache load 口 3 = {valid=1, addr, id={1,0..,next_id}}，`icache_probe`=owner==ICACHE，`ptw_grant`=owner==WALK；记录被挤掉的 LSU load P3 的 valid/id；`next_id++`；`issued_owner/issued_id` 更新。无 owner：`issued_owner<=NONE`，LSU 请求直通。
7. 所有寄存器只在 `cpu_en`（tick 0）更新。`ptw_walk.issue_walk_read`→本块 `ptw_walk_req_valid`→`ptw_grant`→`ptw_walk` 次态；本块 `ptw_event/wakeup` 只依赖寄存器与 DCache 响应 → 集成时无组合环。

## 4. 与 C++ 的差异点、放宽、不复刻
### 4.1 消费者核对 / 放宽（`when`）
| 字段 | 限定 | 核对 |
| --- | --- | --- |
| `lsu_resp_load_{req_id,data,replay}` | `lsu_resp_load_valid` | `RealLsu.cpp:725-766`：先判 `valid` 再读 `req_id/replay/data` |
| `lsu_resp_store_{req_id,replay}` | `lsu_resp_store_valid` | `RealLsu.cpp:805-821` |
| `lsu_resp_mshr_fill_line` | `lsu_resp_mshr_fill` | `RealLsu.cpp:22-74`：`wake_*_replays_on_mshr_fill` 先判 `mshr_fill` |
| `dcache_req_load/store_*` 负载 | 各口 `valid` | 路由块原样直通 LSU 的请求，LSU 对无效口的负载无意义（`lsu.io` 同样 `when valid`）|
| `ptw_event_data/req_id`、`ptw_grant_req_id` | `*_valid` | PTW 读事件/授权 id 仅在 valid 时使用（`MemPtwBlock::apply_grant/apply_events`）|

`icache_resp_{retry,miss,data}` **严格比较**（C++ 在 `valid=0` 时恒 0，RTL 同样与门清零，成本可忽略；ICache 模块把它们当无条件输入）。
### 4.2 删除（无消费者 / 死代码）
- **PTW_DTLB / PTW_ITLB 两个 owner、`ptw_dtlb_req/ptw_itlb_req`、`wakeup.dtlb/itlb`、`ptw_wait.dtlb/itlb`**：PTW 的 mem-client 机制不可达——68 个程序上 `route_dtlb/itlb_req_valid`、grant/event/wakeup 的 DTLB/ITLB 项全为 0；`lldb` 对 `MemSubsystemPtwMemPortAdapter::send_read_req`、`PtwWalker::start/tick` 断点命中 0 次（`docs/analysis/memcpu-record-hook.md` §4）。
- `ptw_events.replay`（路由块恒写 0）、`ptw_events.req_addr`（PTW 不读）、`LoadReq/StoreReq.replay`（perf）、`LoadResp.retry`（端口 0..2，LSU 不读）、`bank_conflict`（LSU 不读，`lsu.io` 头注释已确认）、perf 计数、`dump_debug_state`。
- `dcache_req.icache_req`（3 位）→ 1 位 `dcache_req_icache_probe`（C++ 只有 `==LSU_LDU_COUNT-1` 与 `==LSU_LDU_COUNT` 两种取值有意义）。
### 4.3 路由 id 缩位（需评审）
C++ 的 `next_req_id` 是 32 位计数器（0x80000000 起），路由 id 只有两个用途：(1) DCache 把它原样回在响应的 `req_id`，路由块用"最高位=1"识别路由响应、用"等于上一拍 `issued_tags.req_id`"确认；(2) PTW 用它区分"本次 walk 的响应"和"被冲刷的旧 walk 的陈旧响应"。**任意时刻最多一个路由请求在途**（响应在下一个 CPU 周期到达，`DCache` 不会延迟路由 id 的响应，路由 id 不会触发隐藏 bank-retry），因此陈旧事件的 id 与现行 id 至多相差 1，用低 4 位（计数器模 16）比较精确等价。RTL 的 `dcache_req_load_req_id` 因此是 `{1, 27'b0, id[3:0]}`；spec 表达式把 C++ 的 id 屏蔽成同一形式比较。`resp_id_match_always` 变异体因此存活（等价变异，见 §5）。
### 4.4 登记的 C++ 怪行为（已复刻）
1. `nxt.ptw_wait` 在"MSHR_HIT/FULL 响应且无 fill"分支被**整体赋值** `(owner==WALK)`：当响应属于 ICACHE 时会把一个已存在的 `ptw_wait.walk=1` 清成 0（丢一次唤醒）。RTL 同样（`ptw_wait_d = owner_walk`）。真实程序里没有出现 MSHR_HIT/FULL 路由响应（68 个程序 `route_resp3_routeid_replay2/3 = 0`），只有随机覆盖；**疑点，登记**。
2. 被挤掉的 LSU load 在 `lsu_replay_valid=0` 时（P3 没有 LSU 请求）响应的 `valid=0`，`req_id` 无意义（`when`）。
3. 路由 id 位 31 的判别对所有 4 个 load 口生效（C++ 对所有口隐藏）。

## 5. 验证
- spec：`spec/mem_route.io`（51 字段：20 输入数组/标量、31 输出）。
- 整程序实时锁步（补丁副本）：68 个程序 × ≤30 万拍 **68/68 PASS**（`lockstep_multi.sh`，与其它 3 个模块同一次运行 272/272）。真实程序里：ICache 路由请求 6031 次、walk 路由请求 23 次、被挤掉的 LSU load 31 次、ICache 响应 hit 4167 / miss 1813 / retry 51；MSHR_HIT/FULL 与 wakeup 为 0。
- 随机生成器 `tb/memcpu/gen_rand.cpp`（`-DMOD_ROUTE`，驱动**真实** `MemRouteBlock.cpp`）：6 个 profile × 6 万拍 PASS；覆盖（profile 0，6 万拍）：ICache grant 13816、walk grant 11445、被挤掉的 LSU load 12718、walk 响应 HIT 4044 / CONFLICT 2977 / MSHR_HIT 1501 / MSHR_FULL 1489（含带 fill 的变体）、ICache 响应各 replay 类型、wakeup 4934、`ptw_wait` 置位周期 14250。激励约束：路由 id 响应只对上一拍实际发出的路由请求出现（真实 DCache 的行为），其余口出现随机 LSU id 的响应。
- 变异（`tests/memcpu/mem_route_mutants.py`，`scripts/mut_memcpu.py`：一次构建、运行时选变异体）：**31 个，28 个被杀（其中 18 个真实程序锁步也杀）**，3 个存活且为等价变异：
  `resp_id_match_always`（§4.3）、`req_p3_lsu_wins_over_route`（`granted ? 1 : lsu` ≡ `lsu || granted`，我写错的变异）、`state_cpu_en_ignored`（锁步里 `cpu_en` 恒 1）。
  只有随机才杀的 10 个：全部与 MSHR_HIT/FULL、wakeup、`ptw_wait`、各 replay 组合有关（真实程序不出现）。
