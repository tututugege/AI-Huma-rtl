---
module: ptw_walk
area: memsys
rtl: rtl/memsys/ptw_walk
model: trace-model MemSubSystem/include/MemPtwBlock.h、include/PtwWalkPort.h（调度单元 `mem_subsystem.ptw_block`，类 `MemPtwBlock`，阶段 `comb_request`、`comb_feedback`；类全部写在头文件里）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 47 层（ptw_walk，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# ptw_walk 设计文档

## 1. 职责

页表遍历器（page-table walker）：ITLB 和 DTLB 缺失时，由它按 Sv39 的三级页表从内存里读页表项（PTE，8 字节），找到叶子项后把结果还给发请求的 TLB。两个 TLB 共用这一个遍历器，一次只走一个遍历（round-robin 在两个客户之间选）。

遍历器自己不访问内存：它每拍最多发出一个"读这个地址"的请求，经 `mem_route` 借数据缓存的 P3 口（见 mem_route.md）去读；请求被接受时 `mem_route` 给"授权"（grant），PTE 回来时给"事件"（event），读没成功（冲突或等填充）时给"唤醒"（wakeup）让它重发。

1. **客户侧**（每个 TLB 一份）：锁存请求，维护"挂起 / 在途 / 响应有效"三个状态，把响应（是否缺页、叶子 PPN、权限、叶子级别）寄存后给 TLB；
2. **遍历器状态机**：选客户 → 读第 2 级页表项 → 读第 1 级 → 读第 0 级（遇到叶子提前结束）→ 发布结果；
3. **PTE 判断**：无效、`W` 无 `R`、保留位、未对齐的大页、级别 0 上还是指针，都是缺页；有 `R` 或 `X` 是叶子；其余是指向下一级的指针。

模型对应一个调度单元 `ptw_block`（`MemPtwBlock::comb_request`：TLB 的请求进、读请求出；`comb_feedback`：授权 / 事件 / 唤醒进、更新状态、消耗 TLB 的请求）。

## 2. 配置（`memcpu_pkg`、`ttg_cfg_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 页表 | Sv39：3 级，每级 VPN 9 位，PTE 8 字节 | `PT_LEVELS = 3`、`PT_VPN_PART_W = 9`、`PT_PTE_SHIFT = 3` |
| 客户 | 2：0 = DTLB，1 = ITLB | `PT_NCLIENT` |
| VPN 宽度 | 27 | `PT_VPN_W` |
| 根页号输入 | 22 位（TLB 给的 satp.ppn 低位） | `PT_PPN_IN_W` |
| 能进入 32 位物理地址的页号 | 20 位（`ppn << 12` 超出 32 位的部分被丢弃） | `PT_PPN_W` |
| 权限位 | 8 位（pte[7:0]） | `PT_PERM_W` |
| 叶子级别 | 2 位（0..2） | `PT_LVL_W` |
| 读请求 id | 4 位（与 `mem_route` 的路由 id 同宽） | `PT_ID_W = RT_ID_W` |
| 数据字 | `XLEN_BITS = 64`，PTE 直接用 64 位 | |
| 状态更新时机 | 只在 `cpu_en`（现行配置恒为 1）更新 | |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `client_req_valid/vpn/root_ppn [PT_NCLIENT]` | TLB 的遍历请求（只在 `req_ready` 时发） |
| 入 | `client_resp_consumed`、`client_flush` | TLB 取走了响应；TLB 丢弃自己的遍历（冲刷 / 取消） |
| 入 | `grant_valid/req_id` | 读请求被数据缓存接受，并带路由 id |
| 入 | `event_valid/data/req_id` | PTE 回来了（64 位 + id） |
| 入 | `wakeup_walk` | 读没成功，请重发 |
| 出 | `client_req_ready`、`client_resp_valid/fault/vpn/leaf_ppn/leaf_perm/leaf_level` | 给 TLB，全是寄存器输出（时钟沿后才变，TLB 下一拍看到） |
| 出 | `issue_walk_read`、`walk_read_addr` | 要读的 PTE 地址，组合输出，给 `mem_route` |

## 4. 结构

```
 ptw_walk (顶层：2 个 client 实例 + 1 个 engine)
   ├ ptw_walk_client ×2 : 每个 TLB 一份的请求锁存和响应寄存
   └ ptw_walk_engine    : 共享状态机（选客户、读请求、授权、PTE 事件、唤醒、冲刷）
        └ ptw_walk_pte  : PTE 的判断（缺页 / 指针 / 叶子，PPN、权限）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ptw_walk.sv` | 80 | 顶层：连线 |
| `ptw_walk_client.sv` | 108 | 客户侧 |
| `ptw_walk_engine.sv` | 159 | 状态机 |
| `ptw_walk_pte.sv` | 59 | PTE 判断（纯组合） |

状态：每个客户的 `pending_q`、`inflight_q`、`resp_valid_q`、`vpn_q`（27 位）、`root_q`（20 位）、响应的 `fault_q`/`leaf_ppn_q`/`perm_q`/`level_q`；引擎的 `state_q`（5 个状态）、`owner_q`、`rr_q`（下次优先的客户）、`l1_ppn_q`（上一级指针项的页号 = 下一级页表的基址，20 位）、`req_id_q`（已授权读请求的 id）、`level_q`（后续读的级别）。

引擎的五个状态（`ptw_state_e`）：`IDLE`、`L1_REQ`（要发第一次读）、`L1_WAIT`（第一次读已授权，等 PTE）、`L2_REQ`（要发第二或第三次读）、`L2_WAIT`。注意"L1 / L2"在这里**不是页表的级别**：`L1_*` 是第一次读（Sv39 的最高级，级别 2），`L2_*` 是之后所有的读（先级别 1，再级别 0）；真正的级别在 `level_q`。模型 `WalkState` 的命名也是这样。引擎里的 `go_level0` 其实是"遇到指针、去读下一级"，不一定是 0 级。

## 5. 一拍内的数据流

顺序与模型一致：请求进 → 选客户 → 读请求 →（`mem_route` 处理）→ 授权 → PTE 事件 → 唤醒 → 冲刷。

1. **请求锁存**（客户）：`latch = req_valid && !(pending || inflight)`；锁存后本拍就能被选中（`pending_a`）。任何 `req_valid`（即使没锁存进去）和 `resp_consumed` 都会让旧响应作废。
2. **选客户**（引擎，只在 `IDLE`）：`rr_q` 指向的客户优先，它没有挂起请求再看另一个；选中后状态变 `L1_REQ`，`rr_q` 指向另一个客户，客户的 `pending` 变 `inflight`。
3. **读请求**：`L1_REQ` 时地址 = `{根页号(20), VPN[2](9), 3'b0}`；`L2_REQ` 时地址 = `{l1_ppn_q, VPN[level_q], 3'b0}`。其他状态不发。
4. **授权**：`grant_valid` 则 `*_REQ → *_WAIT`，记下 `req_id`。
5. **PTE 事件**：只有在 `*_WAIT` 状态且 `event_req_id` 等于已授权的 id 才处理（否则是已被冲刷的遍历的陈旧答案，丢弃）。`ptw_walk_pte` 判断：
   - 缺页（`!v`、`!r && w`、`pte[63:54]` 非 0、叶子但大页 PPN 低位非 0、级别 0 上还是指针）→ 给该客户发布"缺页"，回 `IDLE`；
   - 叶子 → 发布 `ppn = pte[29:10]`、`perm = pte[7:0]`、级别 = 本次读的级别，回 `IDLE`；
   - 指针 → `l1_ppn_q <= pte[29:10]`、`level_q <= 本级 - 1`、转 `L2_REQ`。
   发布时，缺页响应的 ppn / perm / level 清零。
6. **唤醒**：`wakeup_walk` 且处于 `*_WAIT`，退回对应的 `*_REQ` 重发同一个读。
7. **冲刷**：当前遍历的所有者客户这拍冲刷，则遍历回 `IDLE`；客户自己的 `pending/inflight/resp_valid` 同拍清零（冲刷优先于所有其他更新）。

## 6. 关键路径与深度

单模块综合深度 **47 层**（ptw_walk；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\g_client[0].u_client.inflight_q` 到 `\u_engine.publish_any`。从代码读出的，未综合验证：

- 最长的是"**PTE 事件 → 判断 → 状态更新 / 发布**"：`event_data`（来自数据缓存第二级的响应，经 `mem_route`）→ `ptw_walk_pte`（保留位、大页对齐检查、叶子 / 指针判断）→ `publish` → 客户寄存器与引擎状态；其中 id 比较 `event_req_id == req_id_c` 要在授权更新之后（`req_id_c`）；
- "**读请求**"：`state_q`、选客户 → 取 VPN 的 9 位段（按 `level_q` 选）→ `walk_read_addr` → `mem_route` → 数据缓存 bank 授权；
- 选客户和请求锁存串在同一拍里（刚锁存的请求本拍就能被选中，并在同一拍发出读请求）。

## 7. 与模型的差异和取舍

- **陈旧响应的处理**：模型有"丢弃额度"`walk_drop_resp_credit`（冲刷时若正在等响应则加一，之后到达的 id 不匹配的响应被丢弃并减一），RTL 没有这个计数，只靠 id 比较（4 位）和状态（不在 `*_WAIT` 就忽略）；
- **回放事件**：模型 `on_walk_mem_replay` 处理 `replay != 0` 的事件，但 `MemRouteBlock` 产生的事件 `replay` 恒为 0（见 mem_route.md），所以 RTL 没有这个分支；
- **PTE 宽度与物理地址**：模型的叶子响应带完整 64 位 `leaf_pte`，物理地址超过 32 位时直接 `exit(2)` 报错；RTL 只带 20 位页号 + 8 位权限，超出 32 位的部分静默丢弃（TLB 侧看到的就是 `PT_PPN_W` 位的页号）；
- **根页号**：模型取 satp 的 44 位页号，RTL 接口只有 22 位（`PT_PPN_IN_W`），内部取低 20 位；
- **访问 / 脏位、Svnapot、Svpbmt**：模型和 RTL 的 PTE 判断里都没有用到 A / D 位，也不实现 Svnapot / Svpbmt（`pte[63:54]` 非 0 即缺页）；
- 模型的 `WalkState`、`Client` 枚举、轮转指针 `walk_rr_next` 与 RTL 的 `ptw_state_e`、客户号、`rr_q` 一一对应；
- 模型的"冲刷在输出之后生效"（TLB 的冲刷从下一拍才能在输出上看到）：RTL 里冲刷在时钟沿清寄存器，输出是寄存器，效果相同。

代码里看起来不一致的地方（未改，仅记录）：`ptw_walk_engine.sv` 里的信号名 `go_level0`、`l1_ppn_q` 暗示"第 0 级 / 第 1 级"，实际含义是"遇到指针、去读下一级"和"最近一个指针项的页号"（见第 4 节）；`memcpu_pkg::ptw_state_e` 的注释写 "level-0 PTE read" 也是同一问题。

未核对（继承自旧文档）：无，旧文档内容未带入。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序（周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`）。这 67 个里哪些开了分页没有逐个核对；遍历器在开启分页的运行（Linux）里一定被使用。
- **Linux 整核门禁**：`scripts/linux_gate.sh`（逐提交对拍功能模型 + PMU 序列对比）。PMU 探针读取 `ptw_walk_engine` 的 `event_data`、`event_hit`、`walk_read_addr`、`issue_walk_read`、`pub_fault`（`tb/soc/pmu_public.vlt`），所以遍历相关事件被逐区间与模型对比。
- **Lint**：`scripts/lint_chip.sh`。
- **没有 ptw_walk 的模块级测试**。**待补**：与模型 `MemPtwBlock` 并排的随机测试（随机请求 / 冲刷 / 授权 / 事件 / 唤醒序列、随机 PTE），重点是冲刷时机、陈旧事件、两个客户的轮转、各种缺页条件。

## 9. 参数与开关速查

`PT_LEVELS`、`PT_VPN_PART_W`、`PT_PTE_SHIFT`、`PT_NCLIENT`、`PT_PPN_IN_W`、`PT_PPN_W`、`PT_PERM_W`、`PT_LVL_W`、`PT_ID_W`（`memcpu_pkg`）；`XLEN_BITS`（`ttg_cfg_pkg`）。

## 10. 变更记录

本分支未改动（`git log 261bd67..HEAD -- rtl/memsys/ptw_walk` 为空），更早：`72f2cd9` rv64 step 3：Sv39 TLB 和页表遍历器；`8abb7ab` RTL 清理（删旧生成器和 spec/、折叠 rv32 分支）；`2d78026` 初次引入。
