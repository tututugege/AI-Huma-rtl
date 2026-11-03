# dcache 设计笔记（DCache 域：RealDcache + MSHR + WriteBuffer + 响应锁存/转发）

边界与分析见 `docs/analysis/memsys-boundary.md` §2.1、录制点见 `docs/analysis/memsys-record-hook.md`。本文是 RTL 设计笔记（先于 RTL）。

## 1. 对应的 C++
- `MemSubSystem/RealDcache.cpp`（`stage1_comb/stage2_comb/seq`）、`MSHR.cpp`、`WriteBuffer.cpp`、`DcacheConfig.cpp`（`Dcache_Read/Dcache_Write/PLRU/apply_strobe`）、
  `MemSubsystem.cpp`（`dcache_domain_comb_outputs/comb_inputs/seq`、`capture_dcache_raw_response`、`forward_pending_response_from_fill`、`publish/clear_pending_dcache_response`）。
- 每个**快 tick**（16/CPU 周期）执行一次；一个 tick = `comb_outputs 半拍`（WB/MSHR 先吸收 AXI 输入 → WB/MSHR 对上拍 stage1 请求应答 → 阵列读 → stage2 → 阵列写 → 响应捕获/转发/发布）
  + `comb_inputs 半拍`（stage1 → MSHR 释放/分配 → WB 压入 → AXI 输出重算）+ `seq`。
- 边界 = `spec/dcache.io`（输入 8 个请求口 + `icache_req` + MSHR/WB AXI 输入；输出 = tick 0 发布的响应 + `mshr_fill(_addr)` + MSHR/WB AXI 输出），`cpu_phase0` 由顶层相位计数器给出。
- 读写点核对：`resp_pub` 的读者是 `MemRouteBlock::comb_response`（load 口 3 的 `valid/req_id/replay/data/retry`，`mshr_fill`）与 `RealLsu::comb_dcache2lsu_ldq/stq`（`valid/req_id/replay/data`）、`wake_*_on_mshr_fill`（`mshr_fill/mshr_fill_addr`）。

## 2. 硬件结构
```
 LSU 请求 ─► dcache_s1 ──(s1s2 寄存器: 8 槽 + 填充快照 s2f + 隐藏 bank 重试锁存)──► dcache_s2 ──► 响应(raw) ─► dcache_resp ─► resp_pub / mshr_fill
              ▲  bank 授权/重试选择/填充快照                    │ 命中判定、MSHR/WB 请求、填充写、牺牲路选择      ▲ 捕获/转发(填充数据)/tick0 发布+清空
              │                                                 ├─► dcache_arr (16 bank × tag/valid/dirty/PLRU/data)  │
              │                                                 ├─► dcache_mshr (8 项 + AXI 响应保持槽)  ◄──► mshr AXI
              └── 填充请求(经 resp 转发后) ◄────────────────────└─► dcache_wb   (8 项环形写缓冲)        ◄──► wb AXI
```
| 模块 | 职责 |
| --- | --- |
| `dcache`（顶层）| 端口适配 + 连线 |
| `dcache_pkg` | 常量、`apply_strobe`、PLRU 触碰/牺牲函数、`line` 地址切分 |
| `dcache_s1` | stage1：请求口选择（真实/待重试/新重试）、bank 授权、`s1s2` 槽寄存器、填充快照寄存器 `s2f`、重试锁存 |
| `dcache_s2` | stage2（纯组合）：load/store 分类、响应、MSHR 请求、牺牲路/脏行写回、填充写、PLRU/pendingwrite |
| `dcache_arr` / `dcache_bank` | 16 bank 阵列；每 bank 一个读口（9 个请求者按 bank 分流）、同步写、PLRU |
| `dcache_mshr` / `dcache_mshr_alloc` | MSHR 表 8 项、AXI 读口、响应保持槽、填充请求；释放/分配/合并 store |
| `dcache_wb` / `dcache_wb_find` | 写缓冲 8 项环形、旁路/合并查找（最新匹配者优先）、AXI 写口 |
| `dcache_resp` | 响应锁存（每口 1 槽）、从填充转发、tick 0 发布并清空 |

状态：`s1s2`（8 槽 ≈ 8×(1+32+32+1)+4×36 + 3b icache_req）、`s2f`（1+3+1+26b + 512b 数据）、4+4 个隐藏重试锁存、阵列（data 16 bank×4 路×16 行×512b = 64 KiB，tag 256×4×18b，valid/dirty 各 1024b，PLRU 256×3b）、
MSHR（8×{valid, issued, line26, dirty, 512b 合并数据, 64b 合并 strobe} + hold{valid,id,512b}）、WB（8×{line26, 512b} + count/head/send）、响应锁存（8 口响应 + 元数据 + mshr_fill/addr）。

**C++ 数据结构 → 硬件结构**
| C++ | RTL |
| --- | --- |
| `data/tag/valid/dirty_array`、`plru_tree_state` 全局数组 | `dcache_bank`×16（bank=set&15，每 bank 16 行×4 路），读口异步、写口同步（01 §3.1）|
| `Dcache_Read(read_req[8], fillout)` | 地址 = `s1s2` 槽（已授权的槽），每 bank 一个读口；填充快照读 = 第 9 个请求者（地址 = `s2f.set`）|
| `Dcache_Write(pendingwrite[4], lru_updates[8], fill_write)` | 每 bank 的字写口（strobe 展开字节使能）、整行填充写口、PLRU 写口；所有写口在不同 bank（见 §4）|
| `bank_retry_cur/nxt` | `dcache_s1` 的 8 个重试锁存（每口 1 槽）|
| `MSHR_STATE.mshr_count` | 删除：恒等于 `popcount(valid)`（分配/释放同步增减，见 §4）|
| `nxt` 就地多次改写 | 一次组合：AXI（先）→ find/free 读 → 释放 → 分配/压入 → AXI 输出重算（§3）|
| `lsu_origin`、`perf`、`alloc_cycle`… | 删除（只喂 perf）|

## 3. 一拍（tick）内的数据流（合并规则）
设 `X_q` 为 tick 开始状态。

**A 半拍（C++ `dcache_domain_comb_outputs`）**
1. WB：`pop = wb_resp_valid && count>0`；`send_a = wb_resp_valid ? 0 : (wb_req_accepted ? 1 : send_q)`；`count_a=count_q-pop`、`head_a=head_q+pop`。
   （`comb_inputs_axi` 先 accepted 置 send，再 resp 清 send，同拍两者并存时 resp 胜。）
2. MSHR：`accepted_id<8 && valid && !issued` → `issued_a` 置位；保持槽空 && `resp_valid` && `resp_id<8` && `valid&&issued_a[resp_id]` → 接收进保持槽（同拍即可作为填充请求，`resp_ready_this_cycle=1`）。
3. WB 应答：`free = 8 - count_a`；4 个 load 旁路（读 `head_a`/`count_a` 范围内**最后匹配者**，早于本拍 store 合并）；4 个 store 合并（命中 head 且 `send_a` → `busy`，否则 `valid` 并把字按 strobe 写进条目，端口间按序，后者优先）。
   请求来自上一拍 stage1 授权的槽（= `s1s2` 槽里 `valid && !replayed`），所以 RTL 不需要额外的请求寄存器。
4. MSHR 应答：`free = 8-popcount(valid)`；`find_resp[k] = 授权槽 k 的行与某 valid 项相同`（AXI 吸收后、释放/分配前）；`fill_req = hold` 项（地址取自该项，数据 = 保持槽 + 项内合并 store 按 strobe 覆盖，dirty = 项 `merged_dirty`）。
5. 阵列读（异步，上一拍写之后）→ `dcache_s2`：load/store 分类（§3.1）→ 阵列写（pendingwrite、LRU 触碰、填充整行写；读先于写，写后可见于下一拍）。
6. 响应：raw 响应捕获进每口 1 个 pending 槽（`dcache_resp`）；`fill_req` 与 pending 中等待 `MSHR_HIT/MSHR_FULL` 且同行的响应匹配 → load 响应数据换成填充字、`replay=HIT`；store 把自己合并进 `fill_req.data` 并置 `dirty`（**修改后的 fill_req 才是 stage1 看到的**）。
   tick 0：此时的 pending 即发布值（`resp_pub`），tick 末清空 pending。

**B 半拍（C++ `dcache_domain_comb_inputs`）**
7. stage1（`dcache_s1`）：每个 load/store 口选择请求（真实 > 待重试 > 新重试，`blocked`=该口 pending 响应有效时不用重试）；bank 授权顺序 = 填充快照 → load0..3 → store0..3，同 bank 后到者 `replayed`；
   填充快照 `s2f_next = hold ? s2f : (fill_req.valid && !same_line_in_s2 ? fill_req : 空)`，其中 `hold = same_line_in_s2 && !fill_write_valid(s2)`；随后 s2 给出的 store 合并线按口序写进 `s2f_next.data` 并置 `dirty`。
8. MSHR 释放（`fill_resp.done`）→ 分配/合并（8 个请求口按序，同行并入同一项，空项按下标取；`dcache_mshr_alloc` 用“前面口是否已经分配”的链表达）→ WB 压入（`dirty_info`，条目 `(head_a+count_a)%8`）。
9. AXI 输出：MSHR = 第一个 `valid && !issued` 项（含本拍新分配项）；`resp_ready = resp_valid ? accepted_this : !hold_valid_after_B`；WB = `!send_a && count>0` 的 head（数据含本拍合并/压入）。

### 3.1 stage2 分类（`dcache_s2_ld/st/fill`，纯组合）
- 隐藏重试（replayed && bank 冲突 && `req_id[31]==0` && 该口重试锁存空）→ **不产生响应**，下一拍重发（`dcache_s1` 内部消化）；否则 replayed → `CONFLICT`（load 同时 `retry=1`）。
- load：WB 旁路 > cache 命中（更新 LRU）> ICache 探针（只查不分配，`CONFLICT`）> MSHR 命中 → `MSHR_HIT` > 无空项 → `MSHR_FULL` > 分配 + `MSHR_HIT`。
- store：与本拍到达的填充请求同行 → `HIT` 并并入下一拍填充快照（`mrg_*`）> cache 命中（pendingwrite + LRU + `HIT`）> WB 合并成功 `HIT` / busy `CONFLICT` > MSHR 已有项 → 合并请求 `HIT`（不占空项计数）> 无空项 `MSHR_FULL` > 分配 `HIT`。
- 空项计数链：`free_in` 起，load0..3 再 store0..3，每个“占空项”的分配口减 1（同一行两个口各减 1，仍只占一项——复刻）。
- 填充：`s2f.valid` 时选牺牲路（第一个无效路，否则 PLRU）；牺牲行有效且脏：WB 有空 → 写回 + 填充 + `done`，WB 满 → 本拍不填充、不 done（脏行不丢，保持 `s2f`，下拍重试）；否则直接填充 + `done`。填充写的路 = 已持有同 tag 的有效路，否则牺牲路。

## 4. 与 C++ 的差异点、隐含依赖、简化清单
**不复刻（总原则 §0，边界上每 tick 可观察行为等价）**
1. 调用结构：`stage2_comb/stage1_comb/MSHR/WB` 的就地 `nxt` 改写、`comb_outputs`/`comb_inputs` 两个半拍、`dcache_fast_comb` 的空请求替换 → 合并为“每 tick 一次”的单个组合 + 一次时钟沿。
2. `dcachereadreq/bypass_req/merge_req/find_req` 等 stage1→stage2 的请求结构体：由 `s1s2` 槽（valid && !replayed）推出，不建寄存器。
3. `bank_conflict` 字段（槽与响应）：恒等于 `replayed`，响应里的 `bank_conflict` 无读者（全仓库只有 perf 读）→ 删除。`mshr_fill_addr` 低 6 位恒 0，输出 `{line, 6'b0}`。
4. `MSHR_STATE.mshr_count`：每次 valid 置位/清零都同步增减，恒等于 `popcount(valid)` → 删除。`MSHREntry/MSHRFINDResp.hit`、`MSHR_FILLReq.id/way_idx`、`DcacheMSHRIO.find_req.set/tag`（=槽地址）等冗余字段不建。
5. `lsu_origin`、`perf_replay`、alloc/start cycle、COUNT_L1D_*：只喂 perf，删除。`Assert` 溢出检查、`CheckAddr`（被注释）、`dump_debug_state`：不翻译。
6. AXI 常量字段：`req_total_size=63`、WB `req_id=0`、`req_wstrb=全 1`、WB `resp_ready=1`、MSHR/WB `req_ready`（输入，无读者）→ 不在 spec 中，集成时接常量。
7. `store.strb` 8 位 → 4 位：`apply_strobe` 只用低 4 位；MSHR 的 `merged_store_strb` 按字节记录（`|=` 后“非零”只用于决定是否覆盖，覆盖本身按字节 strobe，等价）。`lockstep_ticks` 的诊断（`TTG_TICK_STAT=1`）确认 strb 上 4 位从未置位。
8. 响应 payload 放宽（`when`）：`ld_resp_{data,id,retry,replay}` `when ld_resp_valid`；`st_resp_{replay,id}` `when st_resp_valid`（读者均在 `valid` 保护下，见 §1）；`mshr_fill_addr when mshr_fill`；AXI 地址/数据/id `when req_valid`。
9. **不可达分支（证明后不复刻，原 C++ 有）**：(a) stage2 里“store 与正在 stage2 的填充同行 → 直接并入 `out.fill_write.data`”（`RealDcache.cpp:633-635`）；(b) stage2 里“store 命中的路 == `fill_write.way_idx` 且同组 → `CONFLICT`”（`:657-663`，连同“填充停顿时 `way_idx` 为 0”的怪行为）。
   证明：stage2 在 tick t 处理的填充 `s2f` 是在 tick t-1 的 stage1 里快照（或停顿保持）的，该拍填充**占用其所在 bank**（`fillout_granted`），而 tick t 的 stage2 里的 store 槽是 tick t-1 授权的——授权给与填充同 bank 的请求在 t-1 就被拒（`replayed`），不会以 `!replayed` 到达 stage2。(a) 需要“同行”（同 bank），(b) 需要“同组”（同 bank），都被拒。`dcache_arr` 的 `assert property`（每 tick 每 bank 至多一个请求者，包含填充快照读）在 68 个程序、3 个定向程序和 14.4M tick 的随机激励中始终成立，覆盖点 `st_fm` 恒为 0。
   `store 与填充同行 → HIT 并入下一拍快照`（`fill_req_merge_wires`，即 `mrg_*`）可达（填充请求第一次出现在 tick t，store 在 t-1 授权），已复刻并覆盖（随机激励覆盖点 `st_mrg`>0，真实程序 0）。

**必须复刻的“怪行为”（登记疑点）**
- D2：WB 满且牺牲行脏时 `dirty_info.valid` 被丢弃的注释自相矛盾（`:470-473`），代码行为 = 本拍填充不做、保持 `s2f` 重试，脏行不丢。按代码。
- D3：load 口 `LSU_LDU_COUNT-1` 被路由块用于 PTW/ICache；ICache 探针（`icache_req==i`）miss 回 `CONFLICT` 且 `retry=0`、不分配 MSHR。
- D4：load 的 WB 旁路优先于 cache 命中，且命中不更新 LRU；store 与 MSHR 填充同行判断先于 cache 命中判断；WB 合并在“阵列命中”之前对 WB 本身生效（即便 store 同时命中 cache，WB 里同行副本也被改写，复刻）。
- D5：`free` 计数链对同一行的两个口各减 1（只占一项），可能产生保守的 `MSHR_FULL`。
- D6：MSHR 释放与分配同拍时，被释放项的下标可被同拍分配复用（“按下标最小空项”在释放之后计算）；store 的 `find_resp.valid` 为 A 半拍结果，B 半拍该项若被 `fill_resp.done` 释放，则同一个 store 请求在 B 半拍重新分配一项。
- D7：`s2f` 保持（`hold`）时，stage1 仍占用填充所在 bank（`fillout_granted`）；`same_fill_in_s2 && fill_write.valid` 时不占用也不重新快照。
- D8：同拍内 load 的“从填充转发”读到的是合并 store 之前的填充数据，store 的转发合并按口序累积到同一份填充数据（C++ `forward_pending_response_from_fill` 顺序），再被 stage1 快照。

**隐含依赖（RTL 靠结构保证、已写成断言/注释）**
- 每个 tick 内 8 个 LSU 槽 + 填充快照的**授权在互不相同的 bank**（`try_grant_bank` 构造保证）。因此同拍的 9 个读、4 个 pendingwrite、9 个 LRU 触碰、1 个填充写落在 9 个不同的 bank / 组，不存在同组多写的顺序问题（C++ 的 `Dcache_Write` 顺序无可观察性）；每个 bank 一个读口（`dcache_arr` 内 `assert property`）。
- pending 响应锁存每口每 CPU 周期至多 1 次写入（C++ `Assert`）：重试被 `blocked` 抑制保证；RTL 在 `dcache_resp` 里用时钟采样断言检查。
- `s2f.valid` 时 `Dcache_Read` 的 `fillout.set_idx == s2f.set`（快照读地址 = `s2f.set`，无需单独寄存）。
- 复位：状态全部清零 = C++ `init()`（唯一例外 `s1s2.icache_req` 初值 C++ 在第一拍的 stage1 才置为 4，RTL 复位为 0；复位后第一个周期槽全空，不可观察）。

## 5. 验证
见文末“验证记录”（整程序 16-tick 锁步、变异检查、覆盖）。
