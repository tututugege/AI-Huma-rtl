---
module: ptw_walk
area: memsys
rtl: rtl/memsys/ptw_walk
model: trace-model MemSubSystem/include/MemPtwBlock.h、include/PtwWalkPort.h（调度单元 `mem_subsystem.ptw_block`，类 `MemPtwBlock`，阶段 `comb_request`、`comb_feedback`；类全部写在头文件里）
status: 整核周期与模型逐个相等（fm_gate 68/68 + 定向 l2tlb_pwc.S 9041/9041 + memspec_pf.S 3295/3295，0 FM 差异）
depth: 44 层（ptw_walk，单模块综合 5446 cells / 21 $mem_v2，2026-11-22，`SYNTH_ABC="strash;balance;map" SYNTH_NO_MEMPRIO=1`，生成门代理，见第 6 节）
---

# ptw_walk 设计文档

## 1. 职责

页表遍历器（page-table walker）：ITLB 和 DTLB 缺失时，由它按 Sv39 的三级页表从内存里读页表项（PTE，8 字节），找到叶子项后把结果还给发请求的 TLB。两个 TLB 共用这一个遍历器，一次只走一个遍历（round-robin 在两个客户之间选）。

遍历器自己不访问内存：它每拍最多发出一个"读这个地址"的请求，经 `mem_route` 借数据缓存的 P3 口（见 mem_route.md）去读；请求被接受时 `mem_route` 给"授权"（grant），PTE 回来时给"事件"（event），读没成功（冲突或等填充）时给"唤醒"（wakeup）让它重发。

1. **客户侧**（每个 TLB 一份）：锁存请求，维护"挂起 / 在途 / 响应有效"三个状态，把响应（是否缺页、叶子 PPN、权限、叶子级别）寄存后给 TLB；
2. **统一 L2 TLB + Sv39 PWC**（`ptw_walk_l2tlb`）：1024 项 4 路组相联 4KB 页 STLB（256 组 × 4 路，3-bit 树 PLRU）+ 8 项大页 CAM（2MB/1GB，轮转替换）+ 16 项 Sv39 非叶页表项缓存 PWC（L2/L1 指针，轮转替换）；在 `sfence_flush`（`rob_bcast_fence`）时全清有效位；
3. **遍历器状态机**：选客户 → 1 拍 `PW_STLB_LK` 查 STLB/SP/PWC（命中 STLB/SP 直接发布叶子、总延迟 2 拍；命中 PWC L1 跳至 0 级单次读、命中 PWC L2 跳至 1 级两次读；全缺失则从 2 级开始）→ 读页表项 → 发布结果并回填 STLB/PWC；
4. **PTE 判断**：无效、`W` 无 `R`、保留位、未对齐的大页、级别 0 上还是指针，都是缺页；有 `R` 或 `X` 是叶子；其余是指向下一级的指针。

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
| L2 TLB（4KB STLB） | 1024 项（256 组 × 4 路，3-bit 树 PLRU，索引 `vpn0[7:0] ^ vpn1[7:0]`） | `L2TLB_ENTRIES` / `L2TLB_WAYS`（`ttg_cfg_pkg`） |
| L2 TLB 大页 CAM | 8 项（2MB / 1GB，轮转替换） | `L2TLB_SP_ENTRIES`（`ttg_cfg_pkg`） |
| Sv39 PWC | 16 项（L2/L1 非叶 PTE，轮转替换） | `L2TLB_PWC_ENTRIES`（`ttg_cfg_pkg`） |
| 数据字 | `XLEN_BITS = 64`，PTE 直接用 64 位 | |
| 状态更新时机 | 只在 `cpu_en`（现行配置恒为 1）更新 | |

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `client_req_valid/vpn/root_ppn [PT_NCLIENT]` | TLB 的遍历请求（只在 `req_ready` 时发） |
| 入 | `client_resp_consumed`、`client_flush` | TLB 取走了响应；TLB 丢弃自己的遍历（冲刷 / 取消） |
| 入 | `sfence_flush` | 来自 `rob_bcast_fence`（`sfence.vma` 提交），清空 L2 TLB、大页 CAM 与 PWC 有效位（分支误预测 `client_flush` 不清 L2 TLB/PWC） |
| 入 | `grant_valid/req_id` | 读请求被数据缓存接受，并带路由 id |
| 入 | `event_valid/data/req_id` | PTE 回来了（64 位 + id） |
| 入 | `wakeup_walk` | 读没成功，请重发 |
| 出 | `client_req_ready`、`client_resp_valid/fault/vpn/leaf_ppn/leaf_perm/leaf_level` | 给 TLB，全是寄存器输出（时钟沿后才变，TLB 下一拍看到） |
| 出 | `issue_walk_read`、`walk_read_addr` | 要读的 PTE 地址，组合输出，给 `mem_route` |

## 4. 结构

```
 ptw_walk (顶层：2 个 client 实例 + 1 个 engine)
   ├ ptw_walk_client ×2 : 每个 TLB 一份的请求锁存和响应寄存
   └ ptw_walk_engine    : 共享状态机（选客户、L2 TLB/PWC 查询、读请求、授权、PTE 事件、唤醒、冲刷）
        ├ ptw_walk_l2tlb: 统一 L2 TLB（256×4 SRAM + 8 项大页 CAM）+ 16 项 PWC
        └ ptw_walk_pte  : PTE 的判断（缺页 / 指针 / 叶子，PPN、权限）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ptw_walk.sv` | 82 | 顶层：连线（含 `sfence_flush`） |
| `ptw_walk_client.sv` | 108 | 客户侧 |
| `ptw_walk_engine.sv` | 208 | 状态机（含 `PW_STLB_LK` 查表拍与回填） |
| `ptw_walk_l2tlb.sv` | 317 | 统一 L2 TLB（4 路 256×76b 1RW SRAM + 3-bit PLRU（`ttg_util_pkg::ttg_plru4_touch / ttg_plru4_victim`）+ 8 项大页 CAM）+ 16 项 PWC |
| `ptw_walk_pte.sv` | 57 | PTE 判断（纯组合） |

状态：每个客户的 `pending_q`、`inflight_q`、`resp_valid_q`、`vpn_q`（27 位）、`root_q`（20 位）、响应的 `fault_q`/`leaf_ppn_q`/`perm_q`/`level_q`；引擎的 `state_q`（6 个状态）、`owner_q`、`rr_q`（下次优先的客户）、`l1_ppn_q`（上一级指针项的页号 = 下一级页表的基址，20 位）、`req_id_q`（已授权读请求的 id）、`level_q`（后续读的级别）；`ptw_walk_l2tlb` 内的 4 路 256×76b 1RW STLB SRAM（`mem_q`）、`stlb_rd_q`、`stlb_valid_q`、`stlb_plru_q`、8 项大页 CAM + `sp_rr_q`、16 项 PWC + `pwc_rr_q`。

引擎的六个状态（`ptw_state_e`）：`PW_IDLE`、`PW_STLB_LK`（1 拍 L2 TLB / 大页 CAM / PWC 查表）、`PW_L1_REQ`（要发第一次读，级别 2）、`PW_L1_WAIT`（第一次读已授权，等 PTE）、`PW_L2_REQ`（要发 PWC 跳转或下一级读）、`PW_L2_WAIT`。注意"L1 / L2"在这里**不是页表的级别**：`L1_*` 是顶层读（Sv39 级别 2），`L2_*` 是之后所有的读（级别 1 或级别 0，真正的级别在 `level_q`）。模型 `WalkState` 的命名也是这样。

## 5. 一拍内的数据流

顺序与模型一致：请求进 → 选客户（发射 STLB 1RW SRAM 读）→ 下一拍 `PW_STLB_LK` 查 STLB / SP CAM / PWC →（若缺失）读请求 →（`mem_route` 处理）→ 授权 → PTE 事件（回填 STLB / SP CAM / PWC）→ 唤醒 → 冲刷 → `sfence_flush`。

1. **请求锁存**（客户）：`latch = req_valid && !(pending || inflight)`；锁存后本拍就能被选中（`pending_a`）。任何 `req_valid`（即使没锁存进去）和 `resp_consumed` 都会让旧响应作废。
2. **选客户**（引擎，只在 `PW_IDLE`）：`rr_q` 指向的客户优先，它没有挂起请求再看另一个；选中后状态变 `PW_STLB_LK`，`rr_q` 指向另一个客户，客户的 `pending` 变 `inflight`，并同步发起 4 路 1RW STLB SRAM 读（`lk_rd_idx = vpn[7:0] ^ vpn[16:9]`）。
3. **L2 TLB / SP CAM / PWC 查表**（`PW_STLB_LK`，第 T+1 拍）：用已寄存的 `stlb_rd_q` + `stlb_valid_q`、大页 CAM 和 PWC 匹配 `(cur_vpn, cur_root)`：
   - 命中 4KB STLB → 更新该组 3-bit 树 PLRU，发布叶子（总延迟 2 拍），回 `PW_IDLE`；
   - 命中大页 CAM（2MB/1GB）→ 发布叶子，回 `PW_IDLE`；
   - 命中 PWC（L1 优先于 L2）→ `l1_ppn_q <= pwc_ppn`、`level_q <= 0(L1) 或 1(L2)`、转 `PW_L2_REQ`；
   - 全缺失 → `level_q <= 2`、转 `PW_L1_REQ`。
4. **读请求**（仅当 `state_q == PW_L1_REQ / PW_L2_REQ`，与 `select_any` 完全解耦）：`PW_L1_REQ` 时地址 = `{cur_root(20), VPN[2](9), 3'b0}`；`PW_L2_REQ` 时地址 = `{l1_ppn_q, VPN[level_q], 3'b0}`。
5. **授权**：`grant_valid` 则 `*_REQ → *_WAIT`，记下 `req_id`。
6. **PTE 事件**：只有在 `*_WAIT` 状态且 `event_req_id` 等于已授权的 id 才处理。`ptw_walk_pte` 判断：
   - 缺页 → 给该客户发布"缺页"，回 `PW_IDLE`（不写 L2 TLB / PWC）；
   - 叶子 → 回填 STLB（`level == 0`，1RW 写第一无效路或 3-bit PLRU 淘汰路并更新 PLRU）或大页 CAM（`level > 0`，覆盖同项/第一无效/轮转 `sp_rr_q`），发布叶子，回 `PW_IDLE`；
   - 指针 → 回填 PWC（覆盖同项/第一无效/轮转 `pwc_rr_q`），`l1_ppn_q <= pte[29:10]`、`level_q <= 本级 - 1`、转 `PW_L2_REQ`。
7. **唤醒**：`wakeup_walk` 且处于 `*_WAIT`，退回对应的 `*_REQ` 重发同一个读。
8. **冲刷**：`client_flush[owner_b]` 使遍历回 `PW_IDLE` 并清客户状态（不影响 L2 TLB / PWC）；`sfence_flush`（`rob_bcast_fence`）在时钟沿清空 STLB `valid/plru`、SP CAM `valid/rr` 与 PWC `valid/rr`。

## 6. 关键路径与深度

单模块综合深度 **44 层**，面积 **5,446 cells**（含 `21 $mem_v2`、206 FFs；`ptw_walk`；2026-11-22；`scripts/synth_depth.sh l2tlb2 ptw_walk`，`SYNTH_ABC="strash;balance;map" SYNTH_NO_MEMPRIO=1`）。综合报告最长路径：`\g_client[0].u_client.inflight_q` → `vpn_a` → `u_l2tlb.pwc_l1_hit` → `stlb_pwc_go` → `u_engine.state_q`（44 层，较加入 L2 TLB 前的 47 层更浅，因 `PW_L1_REQ/PW_L2_REQ` 的 grant 与 PTE 判别已从 `select_any -> state_b` 路径解耦）。

- 4 路 256×76b STLB 是 4 个 `ttg_sram_1rw`（`TAG = "L2TLB_STLB"`，`DEPTH = PT_STLB_SETS = 256`，`WIDTH = STLB_ENTRY_W`）；内容由 `rst_n` 期间的 SRAM 清扫写 `INIT_VAL`（common.md 4.1），有效位 `stlb_valid_q` 和 PLRU 仍在触发器里、同步复位；写操作与读操作按 FSM 状态严格互斥（`PW_IDLE` 读、`*_WAIT` 写），无读写转发冲突；
- L1 ITLB / DTLB 关键路径完全不受 L2 TLB 影响。

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

- **定向测试**：`programs/directed/l2tlb_pwc.S`（覆盖 4KB STLB 命中、3-bit tree-PLRU 淘汰、2MB SP CAM、PWC L2/L1、以及 `sfence.vma` 重映射刷新；RTL 与模型均 `9041` cycles，`0` FM 差异）与 `programs/directed/memspec_pf.S`（`3295` cycles，`0` FM 差异）。
- **门禁**：`scripts/fm_gate.sh` 68 个程序全过（`68/68 PASS`，`0` FM 差异，`0` cycle 差异）。
- **Linux 整核门禁**：27 窗口 `linux_segments_cmp.sh`（逐提交对拍功能模型 + PT/UP 指纹逐窗口比对）。
- **Lint**：`scripts/lint.sh rtl/memsys/ptw_walk rtl/memsys/memcpu_pkg` 与 `scripts/lint_chip.sh` 均 0 warnings/errors。

## 9. 参数与开关速查

`PT_LEVELS`、`PT_VPN_PART_W`、`PT_PTE_SHIFT`、`PT_NCLIENT`、`PT_PPN_IN_W`、`PT_PPN_W`、`PT_PERM_W`、`PT_LVL_W`、`PT_ID_W`、`PT_STLB_WAYS`、`PT_STLB_SETS`、`PT_SP_N`、`PT_PWC_N`（`memcpu_pkg`）；`XLEN_BITS`、`L2TLB_ENTRIES`、`L2TLB_WAYS`、`L2TLB_SP_ENTRIES`、`L2TLB_PWC_ENTRIES`（`ttg_cfg_pkg`）。

## 10. 变更记录

- 2026-11-29 清理 D：去重（周期不变）。`ptw_walk_l2tlb` 删除本地 `plru_update / plru_victim`（与 `ttg_util_pkg::ttg_plru4_touch / ttg_plru4_victim` 逐字相同），改为按名导入后者。
- 2026-11-28 清理：`ptw_walk.sv` 文件头去掉已删除的 `spec/ptw_walk.io` 引用；删 `ptw_walk_pte.sv` 一处无效 waiver（周期不变）。
- 2026-11-28（rtl 73761fa，SRAM 复位清扫）：`ptw_walk_l2tlb` 的 4 个 STLB `ttg_sram_1rw` 实例接上 `rst_n`；复位期间 SRAM 外壳逐地址写 `INIT_VAL`，`ttg_rst_sweep` 把复位拉长 `SRAM_SWEEP_CYCLES = 4100` 拍，不再依赖上电值（common.md 4.1）；0 周期变化，`fm_gate` 77/77。
- **2026-11-22 (`rtl/l2tlb`)**：新增 `ptw_walk_l2tlb.sv`（1024 项 4 路 1RW SRAM STLB + 3-bit PLRU、8 项大页 CAM、16 项 Sv39 PWC）与 `PW_STLB_LK` 查表拍，经 `mem_top.rob_bcast_fence` 接入 `sfence_flush`；解耦 `PW_L1_REQ/PW_L2_REQ` 与 `select_any` 路径（综合 `5446 cells / depth=44`）。
- 更早：`72f2cd9` rv64 step 3：Sv39 TLB 和页表遍历器；`8abb7ab` RTL 清理；`2d78026` 初次引入。
