---
module: mem_route
area: memsys
rtl: rtl/memsys/mem_route
model: trace-model MemSubSystem/MemRouteBlock.cpp、include/MemRouteBlock.h（调度单元 `mem_subsystem.mem_route_block`，类 `MemRouteBlock`，阶段 `comb_response`、`comb_request`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 9 层（mem_route，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# mem_route 设计文档

## 1. 职责

数据缓存只有 4 个 load 口，而要访问它的有三方：LSU、ICache（取指缺失时"探测"一下数据缓存里有没有这行，见 icache.md）、页表遍历器。`mem_route` 把后两者的请求塞进数据缓存的**最后一个 load 口**（`P3 = NLD - 1`），并把响应分回各自的主人。

1. **请求侧**（`comb_request`）：本拍如果 ICache 或页表遍历器有请求，就占用 P3，把 LSU 在 P3 上的请求挤掉；ICache 优先于遍历器；同一个主人不能连续两拍赢得 P3（防止饿死 LSU）。被挤掉的 LSU 请求记下来，等响应回来时给 LSU 一个 CONFLICT 重发。路由请求的 id 第 31 位置 1，用来在响应里认出自己；
2. **响应侧**（`comb_response`）：数据缓存的响应里，第 31 位为 1 的是路由块自己的，对 LSU 隐藏；P3 上属于路由请求的响应按主人分发（ICache：命中给数据、冲突给重试或缺失、等填充给缺失；遍历器：命中给 PTE，冲突或等填充则唤醒遍历器重发）；被挤掉的 LSU 请求，在这里补一个 CONFLICT 响应；
3. store 请求、store 响应、`mshr_fill` 通知原样直通。

一次只有一个路由请求在途（响应下一拍回来）。

## 2. 配置

| 项 | 值 | 来源 |
| --- | --- | --- |
| load 口 / store 口数 | 4 / 3 | `LSU_LDU_COUNT`、`LSU_STA_COUNT`（`NLD`、`NST`，`memcpu_pkg`） |
| 共享口 | P3 = 3（最后一个 load 口） | `memcpu_pkg::P3` |
| LSU load id 宽度 | 31 位（第 31 位留给路由标记） | `LD_ID_W` |
| LSU store id 宽度 | 6 位（STQ 项号） | `ST_ID_W` |
| 路由请求 id | 4 位计数器（RT_ID_W），高位补 0、第 31 位置 1 | `RT_ID_W`、`mem_route_req.sv` |
| 数据字 | XLEN = 64（`dcache_resp_load_data`、`ptw_event_data`），给 ICache 的是 32 位 | `XLEN_BITS` |
| store 位宽 | 数据 `XLEN_BITS`、strb `ST_STRB_W = XLEN/8 + 1`、第二字 `DST_L2_W` | `memcpu_pkg`、`ttg_cfg_pkg` |
| 状态更新时机 | 只在 `cpu_en`（= `phase0`，现行配置恒为 1）更新 | |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `dcache_resp_load_*`、`dcache_resp_store_*`、`dcache_resp_load3_retry`、`dcache_resp_mshr_fill(_line)` | 数据缓存这拍的响应（`load3_retry` 是 P3 的 retry 位） |
| 入 | `lsu_req_load_*`、`lsu_req_store_*` | LSU 的请求 |
| 入 | `icache_req_valid/addr` | ICache 探测请求 |
| 入 | `ptw_walk_req_valid/addr` | 页表遍历器读 PTE 的请求 |
| 出 | `lsu_resp_load_*`、`lsu_resp_store_*`、`lsu_resp_mshr_fill(_line)` | 回 LSU 的响应 |
| 出 | `icache_resp_valid/retry/miss/data` | 回 ICache 的探测结果（32 位数据） |
| 出 | `ptw_event_valid/data/req_id`、`ptw_wakeup_walk` | 回遍历器：PTE 到了（带 id）、或"请重发读" |
| 出 | `dcache_req_load_*`、`dcache_req_store_*`、`dcache_req_icache_probe` | 给数据缓存的请求；`icache_probe` 告诉数据缓存 P3 上是 ICache 探测 |
| 出 | `ptw_grant_valid/req_id` | 遍历器的读请求被接受（占到了 P3），id 是分配给它的路由 id |

## 4. 结构

```
 mem_route (顶层：寄存器声明、store / fill 直通，连接下面三块)
   ├ mem_route_req   : 仲裁（ICache > 遍历器，上拍的主人不能连赢）、P3 请求替换、记录被挤掉的 LSU 请求
   ├ mem_route_resp  : 响应分流（LSU / ICache / 遍历器），遍历器等填充的标志 ptw_wait 的次态
   └ mem_route_state : 状态寄存器（cpu_en 时更新）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `mem_route.sv` | 139 | 顶层与直通路径 |
| `mem_route_req.sv` | 68 | 请求侧 |
| `mem_route_resp.sv` | 97 | 响应侧 |
| `mem_route_state.sv` | 62 | 状态寄存器 |

状态（`mem_route_state`）：上一拍路由请求的主人 `issued_owner_q`（2 位）、它的 id `issued_id_q`（4 位）、它的地址第 2 位 `issued_hi_q`（ICache 要 64 位字里的哪个 32 位半）、下一个路由 id `next_id_q`、遍历器在等填充 `ptw_wait_q`、被挤掉的 LSU 请求的有效位和 id `lsu_replay_valid_q`/`lsu_replay_id_q`（31 位）。

## 5. 一拍内的数据流

### 5.1 请求侧

1. `icache_cand = icache_req_valid && issued_owner_q != OWN_ICACHE`，`walk_cand = walk_req_valid && issued_owner_q != OWN_WALK`；有 `icache_cand` 则本拍主人是 ICACHE，否则有 `walk_cand` 则是 WALK，否则无；
2. 有主人时 P3 的请求换成路由请求：valid = 1、地址 = 主人的地址、id = `{1, 0…, next_id_q}`、replay = 0；否则 P3 照常是 LSU 的请求；
3. `dcache_req_icache_probe` = 主人是 ICACHE；`ptw_grant_valid` = 主人是 WALK，`ptw_grant_req_id` = `next_id_q`；
4. 记录 `lsu_replay_valid_d/id_d` = LSU 在 P3 上的请求（不论有没有被挤掉，只有授权时才写入状态寄存器）。

### 5.2 响应侧

1. `own_resp` = 上拍有路由主人 && P3 响应有效 && 响应 id 第 31 位为 1 && id 低 4 位等于 `issued_id_q`；
2. LSU 视角：所有第 31 位为 1 的响应对 LSU 隐藏；`own_resp` 时 P3 对 LSU 的响应换成"被挤掉的请求 + CONFLICT"（`lsu_replay_valid_q` 有效才出）；
3. ICache：主人是 ICACHE 时，HIT → `icache_resp_valid`，数据取响应数据的 32 位半（`issued_hi_q` 选高 / 低）；CONFLICT 且数据缓存给了 retry → `retry`；CONFLICT 且没有 retry、或 MSHR_HIT / MSHR_FULL → `miss`；
4. 遍历器：主人是 WALK 且 HIT → `ptw_event_valid`，数据 = 响应的 64 位字，id = `issued_id_q`；
5. 唤醒遍历器：`ptw_wakeup_walk = (主人是 WALK && (CONFLICT || (等填充 && 同拍 mshr_fill))) || (mshr_fill && ptw_wait_q)`；
6. `ptw_wait_d`：有 `mshr_fill` 则清 0；否则收到等填充响应则 = 该响应是否属于遍历器；否则保持。

### 5.3 状态更新

`cpu_en` 时：`issued_owner_q <= owner_d`；有授权才更新 `issued_id_q`（取 `next_id_q`）、`next_id_q`（加一，4 位回绕）、`issued_hi_q`、`lsu_replay_*`；`ptw_wait_q <= ptw_wait_d`。

## 6. 关键路径与深度

单模块综合深度 **9 层**（mem_route；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\dcache_resp_load_valid [0]` 到 `\ptw_wakeup_walk`。。从代码读出的，未综合验证：

- **请求侧**：`issued_owner_q`（寄存器）和 ICache / 遍历器的请求有效 → 主人 → 地址二选一 → P3 的 `dcache_req_load_*`，然后进入数据缓存的 bank 授权，这是整个路由块进入数据缓存关键路径的入口；
- **响应侧**：数据缓存第二级的响应（组合）→ id 比较、`own_resp` → LSU 的 `lsu_resp_load_*`（P3 要多一层二选一）；同时 → 遍历器的 PTE 事件，进入 `ptw_walk` 的 PTE 解析（见 ptw_walk.md）；
- 两个方向都是几层逻辑（4 位 id 比较、二选一），没有长链，深度主要来自它前后两端的数据缓存和 LSU / 遍历器。

## 7. 与模型的差异和取舍

- **路由 id 宽度**：模型的路由 id 是 32 位（第 31 位 + 递增计数），RTL 只保留低 4 位（`RT_ID_W`），代码注释的理由是同一时刻只有一个路由请求在途，id 在比较窗口内不会混淆；
- **ICache 探测的数据**：模型在命中时用 `tbhook::mem_read` 从功能内存取指令字（模型的 L1D 不存数据），RTL 取数据缓存阵列返回的 64 位字里的那个 32 位半（`issued_hi_q`）；
- **PTE 数据**：模型用功能内存连读两个 32 位字拼成 64 位；RTL 直接用数据缓存返回的 64 位字；
- **模型的 `Owner::LSU`、`PtwEvent.replay`、`PtwEvent.req_addr`、`PtwGrant.owner`** RTL 没有：RTL 的主人只有 NONE / ICACHE / WALK 三个；模型里 `PtwEvent.replay` 在路由块里恒为 0（`comb_response` 只在 HIT 时产生事件并置 `replay = 0`），所以 RTL 的遍历器没有"回放事件"分支（见 ptw_walk.md）；
- **被挤掉的 LSU 响应数据**：模型保留数据缓存响应的数据字段，RTL 清零；两者的 replay 都是 CONFLICT，LSU 不使用数据；
- 在模型里 `MemRouteBlock` 的状态用 `q_` 保存、`seq()` 更新；RTL 状态单独放在 `mem_route_state`，并且只在 `cpu_en` 时更新。

模型与 RTL 一致、读代码时容易误判的地方：

- 遍历器在等填充时不是立刻重发，而是 `ptw_wait_q` 置位，等下一个 `mshr_fill` 才唤醒（可能已经是几拍之后）；
- 一个主人刚占过 P3，下一拍无论有无请求都让位，所以 ICache 取指缺失连续探测时，LSU 与它交替。

代码里看起来不一致的地方（未改，仅记录）：`memcpu_pkg.sv` 里 `NST` 的注释写"4 store ports"，实际值是 `LSU_STA_COUNT = 3`。

未核对（继承自旧文档）：无，旧文档内容未带入。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`；ICache 缺失时由 `rtl/frontend/icache/icache_probe.sv` 发出探测请求（`dc_req_valid`），所以有 ICache 缺失的程序都会走 ICache 探测这条路径（哪些缺失发探测由 ICache 决定，见 icache.md）。页表遍历路径由开分页的程序（Linux）覆盖：`scripts/linux_gate.sh`。
- **Lint**：`scripts/lint_chip.sh`。
- **没有 mem_route 的模块级测试**。**待补**：路由块与模型 `MemRouteBlock` 并排的随机测试（随机的 ICache / 遍历器 / LSU 请求，随机的数据缓存响应），重点是 P3 仲裁、被挤掉请求的重发、`ptw_wait`。

## 9. 参数与开关速查

`LSU_LDU_COUNT`、`LSU_STA_COUNT`、`XLEN_BITS`、`DST_STRB_W`、`DST_L2_W`（`ttg_cfg_pkg`）；`RT_ID_W`、`LD_ID_W`、`ST_ID_W`、`P3`、`FILL_LINE_W = 26`（`memcpu_pkg`）。

## 10. 变更记录

本分支未改动（`git log 261bd67..HEAD -- rtl/memsys/mem_route` 为空），更早：`8abb7ab` RTL 清理；`fb05807` rv64 step 2（数据字 XLEN 位）；`b1e0335` EXP-024（第二个 store 字通路）；`17ffdf7` 预取器引入（探测口、LSU 的 load replay 位）；`2d78026` 初次引入。
