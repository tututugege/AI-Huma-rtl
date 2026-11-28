---
module: tlb_mmu
area: backend
rtl: rtl/backend/tlb_mmu
model: trace-model back-end/Lsu/TlbMmu.cpp、back-end/Lsu/include/TlbMmu.h（类 `TlbMmu`，`Kind::DTLB`；LSU 的子模块 `RealLsu::dtlb`，没有单独的调度单元，在 `back.lsu` 的 `comb_translate` 里被调用）
status: 整核周期与模型逐个相等（EXP-070：新增 `paddr_p1`/`paddr_m1` 随页表回填预计算，零周期变化消除 LSU/DTLB 往返 29b 加法器；fm_gate 77/77 + riscv-tests 152/152 零偏差）
depth: TSMC 28nm HPC+ DC `tlb_mmu_bb` WNS `−0.03 ns`（`1.89 GHz`）/ `25` 级 / `57,685 µm²`；Yosys `61` 层 / `46,624` 单元
---

# tlb_mmu 设计文档

> **EXP-070 后端子系统时序优化（0 周期变化）**：
> - 在 `tlb_mmu_pkg` / `tlb_mmu_lane` / `tlb_mmu_core` / `tlb_mmu` 中随翻译结果并行输出 29-bit `resp_paddr_p1` / `resp_paddr_m1`（兼容 Sv39 4K/2M/1G 大页与直通模式），将原 LSU L1 侧 `paddr[31:3] ± 1` 29-bit 加法器移出 EXU/LSU ↔ DTLB 跨模块关键路径。
>
> **EXP-051 里程碑 B 升级**：`tlb_mmu_core` 新增参数 `NPEEK`（DTLB 保持 `NPEEK = 0` 零改动；ITLB 当时设 `NPEEK = 2`，fe-2ahead 单组 3-block ahead 前端起 `icache_itlb.sv` 设 `NPEEK = 1`），提供纯只读组合翻译口（复用 `entry_valid/entry` 与同拍 `refill_end`，先查 `refill_end` 再查表，含直通 / 规范地址 / 权限检查，精确对齐 `TlbMmu::peek_translate`，零额外 PTW walker、不改替换状态）。

## 1. 职责

后端的数据 TLB（DTLB）和它的页表遍历客户端。每个物理 AGU 口有一个翻译口（`LSU_AGU_COUNT = 5` 个），一拍内最多服务 5 个请求；响应同拍组合返回给 LSU（没有输出寄存器）。每拍做这些事：

1. 对每个有效请求：直通（M 态或 satp 的 MODE 不是 Sv39 时地址不翻译）、非规范地址报缺页、查 64 项全相联表加权限检查，命中则给出物理地址，权限不符给缺页；
2. 表里没有时走页表遍历：同一时刻只有**一个**遍历在途（一个 walk 寄存器），遍历请求发给共享的页表遍历器（PTW），响应回来后回填 TLB 并结果给请求它的口；
3. 三种互斥的拍：`fence`（SFENCE.VMA：清表和遍历）、`cancel`（流水线 flush 或误预测：丢掉在途遍历，通知 PTW）、`translate`（正常服务请求）；`fence` 优先于 `cancel`；fence / cancel 的拍所有请求都得不到响应。

模型里 DTLB 是 `RealLsu` 的成员（`TlbMmu dtlb{DTLB_ENTRIES, Kind::DTLB}`），`comb(fence, cancel, req, resp, n)` 在 `RealLsu::tlb()` 里被调用（`comb_translate` 阶段，请求按口序依次服务），`seq()` 在 `RealLsu::seq()` 里调用；它不是调度单元，内部没有阶段。RTL 里 `tlb_mmu`（顶层，只做端口适配）是独立模块，实例在 `back_top`（`u_dtlb`）。I-cache 的 ITLB 复用同一个核心 `tlb_mmu_core`（`rtl/frontend/icache/icache_itlb.sv`，`LANES = 1`、`FETCH = 1`、`ENTRIES = ITLB_ENTRIES` = 64），不属于本模块的顶层，但它的行为由本文第 5 节的核心决定。

## 2. 配置（`ttg_cfg_pkg` / `tlb_mmu_pkg`，现行默认）

| 名字 | 值 | 含义 |
| --- | --- | --- |
| `LSU_AGU_COUNT`（`LANES`） | 5 | 翻译口数 = 物理 AGU 数（口 0、1 只给 load，口 2、3 load 与 STA 共用，口 4 只给 STA，见 lsu.md 第 2 节） |
| `DTLB_ENTRIES`（`ENTRIES`） | 64 | TLB 项数，必须是 2 的幂（`tlb_mmu_store` 里 `$error` 检查） |
| `XLEN_BITS` | 64 | 现行配置是 rv64，`tlb_mmu_pkg.RV64 = 1`：Sv39 |
| `ASID_W` | 16 | `satp[59:44]` |
| `LEVELS` / `VPN_PART_W` / `VPN_W` | 3 / 9 / 27 | 页表级数、每级 VPN 位数、`vaddr[12 +: 27]` |
| `LVL_W` | 2 | 叶子级别：0 = 4 KiB，1 = 2 MiB，2 = 1 GiB |
| `VLOW_W` | 30 | 最高级叶子保留的虚拟地址低位数（`12 + 9 × 2`） |
| `PPN_W` | 20 | 物理地址是 32 位，PTE 里只有 `ppn[19:0]` 进得了物理地址 |
| `PERM_W` | 8 | PTE 低 8 位 `D A G U X W R V` |
| `IDX_W`（顶层参数） | 6 | 请求带的项号位宽：`max(LDQ_IDX_WIDTH, STQ_IDX_WIDTH)`，响应原样带回 |

一个表项（`tlb_mmu_entry_t`）：标签 `global_page(1) + asid(16) + level(2) + vpn(27) = 46` 位，翻译 `level(2) + ppn(20) + perm(8) = 30` 位，共 76 位，另有一个单独的有效位（在 `tlb_mmu_store` 里）。walk 寄存器（`tlb_mmu_walk_t`）：`active(1) + req_sent(1) + vpn(27) + access_type(2) + satp(64) + eff_priv(2) + mxr(1) + sum(1) = 99` 位——walk 要记住发起它的请求的翻译上下文，回填的权限检查用这个上下文，不用后来请求的。

`tlb_mmu_pkg` 里仍保留 `RV64 = 0`（Sv32）的分支（`ASID_W = 9`、`LEVELS = 2` 等），现行配置不用。

## 3. 接口

端口按模型的 `TlbMmu::Req / Resp` 和 PTW 的 walk 端口命名：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `req_valid / req_vaddr / req_entry_idx / req_is_store [LSU_AGU_COUNT]` | 每个物理口一个请求；`req_is_store` 区分 load（访问类型 1）和 store（2），共用口按每个请求的类型走 |
| 入 | `csr_status_satp [XLEN_BITS]`、`csr_status_privilege [1:0]`、`csr_status_mstatus_mxr / _sum / _mprv`、`csr_status_mstatus_mpp [1:0]` | 翻译上下文 |
| 入 | `rob_bcast_fence`、`rob_bcast_flush`、`dec_bcast_mispred` | `fence` 清表；`cancel = rob_bcast_flush \|\| dec_bcast_mispred`。`back_top` 接的是 `rob_fence_q` 和 `rob_flush_q`，即全局 flush 和 fence 晚一拍（docs/FLUSH_REG.md），误预测不晚 |
| 入 | `ptw_walk_req_ready`、`ptw_walk_resp_valid / _fault / _vpn [27] / _leaf_ppn [20] / _leaf_perm [8] / _leaf_level [2]` | PTW 的 walk 端口：能否接受请求、响应（出错，或叶子的 ppn / perm / level） |
| 出 | `resp_valid / resp_result [1:0] / resp_paddr [31:0] / resp_entry_idx [IDX_W]  [LSU_AGU_COUNT]` | 响应：`resp_valid = req_valid && translate`；`resp_result`：0 未命中（还在走遍历，请再试）、1 命中、2 缺页；`resp_entry_idx` 是请求的项号原样带回 |
| 出 | `ptw_walk_req_valid / _req_vpn [27] / _req_root_ppn [21:0]` | 遍历请求：页号和 `satp[21:0]`（根页表） |
| 出 | `ptw_walk_resp_consumed`、`ptw_walk_flush` | 本拍消费了 PTW 的响应；本拍 fence 或 cancel，让 PTW 丢弃在途遍历 |
| 出 | `resp_paddr_p1 / resp_paddr_m1 [28:0] [LSU_AGU_COUNT]` | 物理地址 `paddr[31:3] ± 1`，随翻译结果并行给出（EXP-070），LSU 跨 8 字节访问不再自己做加法 |
| 入 / 出 | `pf_page_set`、`pf_page_vpn`（入）；`walk_next_v`、`walk_next_vpn`（出） | L1D 预取器跨页翻译：LSU 为预取候选发起遍历时记下页号 `pf_page_q`，该遍历以页故障结束时提前丢掉（`early_pf_drop`）；`walk_next_*` 是下一拍的在途遍历页号，给 LSU 判断（见文末"EXP-048 M3 补充"） |

## 4. 结构

```
 req[5] ─► tlb_mmu_lookup ×5（每口 64 项并行比较，最低下标优先，onehot 选翻译）─┐
 tlb_mmu_store（64 项 + valid 位 + 替换指针 repl_q）──────────────────────────────┤
 ptw resp ─► tlb_mmu_early（walk 的响应已回时提前退休）─► 拍首状态（walk0 / refill0）│
 walk_q ──────────────────────────────────────────────────────────────────────────┤
                                                                                   ▼
                  tlb_mmu_lane ×5（并行：各口自己的 miss / 同页 / 权限 / 两种回填视图下的结果）
                                                                                   │
          A 选择（first_set：第一个在 walk 页上缺失的口）  B 选择（first_set ×3，三种情况预先选好）
                                                                                   ▼
          walk_d / refill（写 store）/ PTW 请求、consume、flush        各口结果 = 末级三选一（视图 1 / 退休口 / 视图 0）
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `tlb_mmu_pkg.sv` | 196 | 常量（响应码 `RES_MISS / RES_HIT / RES_FAULT` 是唯一定义，LSU 的 `lp_l1` 按名导入）、类型（`tlb_mmu_tag_t / _xlat_t / _entry_t / _walk_t / _ptw_resp_t`）、权限检查 `perm_ok`、标签匹配 `tag_match`、物理地址合成 `compose_paddr`、`satp_on / satp_asid`、规范地址检查 `va_canonical`、有效特权级 `effective_priv` |
| `tlb_mmu.sv` | 101 | 顶层：端口适配，实例化 `tlb_mmu_core`（`FETCH = 0`、`ENTRIES = DTLB_ENTRIES`），`cancel = flush \|\| mispred` |
| `tlb_mmu_core.sv` | 258 | N 口翻译核心（DTLB 和 ITLB 共用）：模式选择、提前退休、A / B 两次选择、walk 寄存器、回填和 PTW 端口输出 |
| `tlb_mmu_lane.sv` | 146 | 一个口自己能算的部分：直通 / 非规范 / 命中 / 缺失、权限、两种回填视图下的结果；最后按核心的选择出结果 |
| `tlb_mmu_lookup.sv` | 38 | 一个口的查表：64 项并行比较，最低下标优先（`ttg_first_set`），`ttg_onehot_mux` 选翻译 |
| `tlb_mmu_early.sv` | 33 | walk 的响应已到时的提前退休：用 walk 寄存器里保存的上下文判权限，产生本拍回填 |
| `tlb_mmu_store.sv` | 71 | TLB 阵列：valid 向量 + 项 + 轮转替换指针；只由回填写，fence 清 valid 和指针 |

状态：`entry_valid_q [64]`、`entry_q [64]`（项内容不复位，只在 valid 置位时被读）、`repl_q`（6 位轮转指针，复位 0）、`walk_q`（99 位）。没有"挂起的回填"状态：模型里"本拍 comb 写、本拍 seq 提交"的影子在 RTL 里就是组合信号 `refill_end` 和 `walk_d`，回填当拍旁路给各口、时钟沿写阵列。

## 5. 一拍内的数据流

### 5.1 模式

`translate = !fence && !cancel`。fence 的拍：所有口无响应，`store` 清所有 valid 和 `repl_q`，walk 清空，不消费 PTW 响应（`ptw_walk_resp_consumed = 0`），同拍的回填被丢弃（`write_en = refill_valid && !fence`）。cancel 的拍：所有口无响应，walk 清空，PTW 的响应如果对应 walk 的页则被消费（无论是否出错），可用的那个响应仍然回填进表。两种拍都使 `ptw_walk_flush = 1`。

### 5.2 提前退休（`tlb_mmu_early`）

walk 在途（`active && req_sent`）且 PTW 的响应对着 walk 的页（`resp.vpn == walk.vpn`）时，响应在任何口被看之前先"退休"：用 walk 寄存器里保存的 `access_type / eff_priv / sum / mxr` 判权限，响应无错且权限通过才产生本拍回填（`refill_ok`）。translate 拍只消费可用的响应（出错或权限不符的留给请求同页的口去报缺页）；cancel 拍消费所有对应 walk 的响应；fence 拍不消费。ITLB（`FETCH = 1`）在 translate 拍没有提前退休，响应由请求该页的取指口或 cancel 退休。

### 5.3 各口并行

每个口（`tlb_mmu_lane`，`valid = req_valid && translate`）：有效特权级 `effective_priv`（非取指且 `mprv` 时用 `mpp`）；直通（`eff_priv == 3` 或 satp 的 MODE 不是 8）：命中，`paddr = vaddr`（rv64 且 `vaddr[63:32] != 0` 时为 `32'h7fffffff`，落在 RAM 之外）；非规范地址（`vaddr[63:38]` 不是全 0 或全 1）：缺页；否则查表（64 个标签并行比较：`global_page` 或 `asid` 相等，且每一级 VPN 在叶子级别及以上相等），命中和拍首回填 `refill0` 命中都做权限检查（`perm_ok`：取指要 X，load 要 R 或 `mxr && X`，store 要 W，U 态要 U，S 态不能碰 U 页取指、也不能在 `sum = 0` 时碰 U 页，A 必须置位，store 要 D）得到命中或缺页。表里没有则"缺失"（`miss0`）。

### 5.4 共享的 walk：两次选择

模型里 5 个口按口号顺序依次服务，每个口看到前面的口留下的 walk、回填和 PTW 状态（口 0 优先级最高）。真正会改变共享状态的口一拍最多两个，RTL 并行算出来：

- **A**：拍首 walk 在途时，第一个"缺失且页和 satp 与 walk 相同"的口（`a_req = miss0 & walk_same`，`ttg_first_set`）。它要么发请求（`!req_sent && ptw_req_ready`），要么消费响应（`req_sent && resp0_valid`）；响应页与 walk 页相同则 walk 退休（`a_retire`）：响应出错或 A 口权限不过 → 该口缺页；否则该口命中，物理地址由响应合成，并产生回填 `refill1`（`a_ok`）。A 之后的口在 A 成功时看到 `refill1`（视图 1）。
- **B**：walk 拍首空闲（任何缺失口，视图 0），或被 A 退休（A 之后的缺失口：A 成功时用视图 1，A 出错时用视图 0），第一个缺失的口启动新 walk，`req_sent = ptw_req_ready`（PTW 能接就同拍发出）。三种情况各有一个 `ttg_first_set`，最后按情况选。其余缺失的口只能返回未命中。
- 回填只有两个来源：拍首的 `early_refill`（视图 0）或 A 的 `refill1`（内容 = PTW 响应 + walk 页 + 当前 satp 的 ASID，与是哪个口无关），所以每个口对两个视图都预先算好 `miss0 / miss1` 和完整结果，核心的选择只控制最后的三选一：`use_refill1`（视图 1）优先于 `retire`（A 口自己，按 PTW 响应）优先于视图 0。

### 5.5 提交

`walk_d`：fence 或 cancel → 空；否则 B 选中的口启动的新 walk（`walk_b`）；否则 A 退休 → 空；否则 A 发了请求 → `req_sent = 1`；否则拍首 walk 不变（被提前退休消费了则为空）。回填（`a_ok` 或拍首的 `refill0_valid`）在时钟沿写进 `entry_q[repl_q]`，`repl_q` 加 1（绕回）。PTW 请求（`ptw_walk_req_valid = a_issue || (b_any && ptw_req_ready)`）的内容取 `walk_end` 的 `vpn` 和 `satp[21:0]`。`ptw_walk_resp_consumed = early_consume || a_consume`。

## 6. 关键路径与深度

单模块综合（通用门代理）：`tlb_mmu` **67 层**，这是 EXP-042 把 8 个口的串行链改成并行时的测量（163 → 67，其中 `tlb_mmu_lookup` 61 → 33：64 位 `ttg_first_set` 由加法器式的 `req & -req` 改成对数深度的前缀或），提交说明里是 rv64 配置；之后口数改为 5（16de223），没有重测。我没有重新综合。

从代码读出的长链（**未综合验证**）：请求 `req_vaddr` → `tlb_mmu_lookup` 的 64 路标签比较 → `ttg_first_set`（对数深度）→ `ttg_onehot_mux` 选翻译 → `tlb_mmu_lane` 的 `perm_ok` 和 `compose_paddr` → 末级三选一 → `resp_result / resp_paddr`；另一条是 `miss0` → `a_req` → `ttg_first_set` → `a_ok / use_refill1 / after_a` → 各口的 `result`，以及 B 的三个 `ttg_first_set` → `walk_b` → `walk_d / ptw_req_*`。在整核里，DTLB 请求前面还有 EXU 的 AGU 加法和 `lp_l1` 的 vaddr 选择，后面还有 `lp_stq_ent` 更新 STQ 项等（docs/LSU_TIMING.md 第 1、5 节有整核路径的分段数字，是更早的版本）。

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| 各口并行，A / B 两次选择代替口与口之间的串行链；`ttg_first_set` 对数深度 | `1d8688e` | 深度代理 163 → 67（在 261bd67 之前合入） |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- 模型 `TlbMmu` 按口序依次服务请求，用 `walk_next_ / refill_ / port_` 传递一个口留给下一个口的状态；RTL 并行计算，口间依赖用 A、B 两次 first-set 表达（第 5.4 节）。两者的行为在 EXP-042 时用 `tests/tlb_par` 逐拍比较过（该测试已在 64d5dbb 删除，见第 8 节）；
- `peek_translate`（前端 FE_IPF 的无副作用翻译）和 `warm_install`（快速预热回放装载 TLB 状态）：模型的仿真辅助，RTL 没有；
- 表项内容：模型 `TlbEntry` 在 fence 后整项清零，RTL 只清 valid，无效项的内容不可观察；
- 模型 `ppn` 是 44 位，`compose_paddr` 取 32 位；RTL 的表项和 PTW 响应只存 `ppn[19:0]`（`PPN_W = 20`），物理地址相同；
- 权限不符时的 `resp_paddr`：模型给 0；RTL 的 `tlb_mmu_lane.port_result` 在命中表项或回填的分支里先合成 `paddr` 再判权限，所以权限缺页的口的 `resp_paddr` 是合成值而不是 0。LSU 只在 `resp_result == 命中` 时读 `resp_paddr`（`lp_l1` 的 `tl_l / tl_s`），所以不可观察；
- 模型的 `Resp.valid` 对无效请求口为 0，fence / cancel 拍整个响应为 0；RTL 的 `resp_valid = req_valid && translate`，其余字段在 `resp_valid = 0` 时不关心。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- cancel 拍已到的合法响应仍会回填进表，出错或权限不符的响应也被消费；
- 响应出错、且之后没有同页请求时，响应一直留在 PTW 端口，walk 一直 active，直到有同页请求（缺页）或 cancel / fence；
- `walk.satp != satp`（整字比较，含 ASID）会让同页请求被当作"别的页的 walk"，返回未命中；
- 一次只有一个 walk；一拍最多发一个 PTW 请求：A 发请求要求 walk 在途且尚未发出，B 启动新 walk 要求 walk 空闲或已被 A 退休，两者互斥。

在代码里看到的可疑点（只记录，没有改）：

- 文件头的 `Ref:` 注释仍引用旧模型函数名（`TlbMmu::top_comb / translate_lsu_ports / flush / cancel_pending_walk / core_comb / lookup_table_comb / consume_completed_walk_refill`、`BackTop::comb_lsu_mmu`、"reference model commit 2f31e8d"），现行 `TlbMmu.cpp` 里是 `comb / translate_one / take_completed_walk / make_refill / seq`，语义对应但名字已不存在；
- `tlb_mmu_pkg.sv` 里 `RV64 = 0`（Sv32）的各分支现行配置不用；
- 没有模块级测试（`tests/tlb_par` 已删除，第 8 节）。

未核对（继承自旧文档）：旧文档 `docs/modules/tlb_mmu.md` 的验证部分（73 个真实程序的 trace、34 个变异体及其被谁抓到的表）描述的是已退役的 trace 回放体系，没有采用；其中"PTW 只用 `req.vaddr[31:12]` 和 `req.satp[21:0]`"这类 PTW 侧的消费者核对没有在本次重新验证（RTL 里 `ptw_walk_req_vpn` 27 位、`ptw_walk_req_root_ppn` 22 位与此一致，但没有读 PTW 一侧）。

## 8. 验证

- **最新整核门禁（2026-11-28，`rtl/exu-clean`，EXP-072）**：`lint_chip` & `lint_soc` 0 告警；`SOC_FM=1 SOC_SVA=1 SOC_ASSERT=1` `fm_gate` 77/77、`riscv-tests` 152/152、`soc_gate --linux` 12/12 全通；Linux 26/26 窗（含 Sv39 遍历）PT/UP 全等。
- **整核门禁**：`scripts/fm_gate.sh`，77 个程序，逐条提交对功能模型、周期对参考表 `scripts/ref_cycles.txt`。涉及翻译的：`pf-stress`（缺页压力）、`trap-precise-store`、`directed/memspec_pf`（错误路径上缺页的 load），以及所有在 M 态直通下的访存。M 态以外的 Sv39 翻译主要靠 Linux 启动覆盖。最近一次改 DTLB 的提交（16de223）说明写 fm_gate 67/67、周期等于当时的参考表、lint_chip 0；本次没有重跑。
- **Linux**：`scripts/linux_gate.sh`（从复位启动，RTL 对模型）和 `scripts/linux_segments_cmp.sh`（检查点窗口）：Sv39、ASID、fence、页表遍历在这里被真正用到。
- **Lint**：`scripts/lint_chip.sh`；`scripts/lint.sh` 对 `rtl/frontend rtl/backend/tlb_mmu` 和 `rtl/frontend/icache rtl/backend/tlb_mmu` 另有按目录的编译组合（`icache` 用到了这里的核心）。
- **没有模块级测试**：EXP-042 时用过的 `tests/tlb_par/`（并行核心对旧的串行参考核心逐拍比较）在 16de223 改成每请求带 `req_is_store` 之后已不能构建，已在 64d5dbb 删除。**待补**：按现行 5 口、每请求一个访问类型（共用口上 load 与 store 混合）重写一个并排随机测试。
- 旧体系的 trace 回放 + 随机 trace + 变异检查已随 `spec/` 一起退役。

## 9. 参数与开关速查

`DTLB_ENTRIES`、`ITLB_ENTRIES`、`LSU_AGU_COUNT`、`XLEN_BITS`（`ttg_cfg_pkg`）；`RV64`、`ASID_W`、`LEVELS`、`VPN_PART_W`、`VPN_W`、`LVL_W`、`VLOW_W`、`PPN_W`、`PERM_W`（`tlb_mmu_pkg`）；`tlb_mmu_core` 的参数 `LANES`、`FETCH`、`ENTRIES`；`tlb_mmu` 的参数 `IDX_W`。

## 10. 变更记录

- 2026-11-29 清理 D：去重（周期不变，本目录 RTL 不变）。`lp_pkg::MMU_MISS / MMU_HIT / MMU_PF`（与 `RES_MISS / RES_HIT / RES_FAULT` 同值）删除，`lp_l1` 改为导入 `tlb_mmu_pkg::RES_*`。LSU 寄存器 PL12 里的 DTLB 结果另有编码（命中 = 0），改名 `lp_pkg::PL12_TLB_*` 以区分，二者不互相赋值。
- 2026-11-28 清理：删 `tlb_mmu_lane` 只被异或吸收的输入 `ptw_resp_level / ptw_resp_ppn` 及 `tlb_mmu_core` 对它们的驱动、`tlb_mmu_core` 一处无效 waiver；`tlb_mmu_pkg` 的 UNUSEDPARAM waiver 收窄到常量段（周期不变）。另删没有消费者的输出 `resp_hit`。
- 2026-11-28（文档核对，无 RTL 变化）：ITLB 现在 `NPEEK = 1`；`tests/tlb_par` 已在 64d5dbb 删除；接口补 `resp_paddr_p1/m1`、`pf_page_*`、`walk_next_*`；文件表行数；门禁参考改为 `scripts/ref_cycles.txt`（77 个程序）。
- 2026-11-28（`rtl/exu-clean`，EXP-072）：`tlb_mmu.sv` DTLB 口数随 `LSU_AGU_COUNT = 5`（真 5 物理口）统一口径并微调端口注释/参数映射，零逻辑行为变化；通过 `lint` 0、strict+SVA `fm_gate` 77/77、`soc_gate --linux` 12/12 与 Linux 26/26 窗对齐。
- 2026-11-21（`rtl/fe-2fetch-2taken`，EXP-051 里程碑 B）：`tlb_mmu_core` 新增参数化只读 CAM peek 读口 `NPEEK`（DTLB `NPEEK=0` 零改动；ITLB `NPEEK=2` 服务双块 B 与 FDIP，先查同拍 `refill_end` 再查表，零额外 PTW walker）。Yosys 综合 `tlb_mmu` 46,624 单元 / 61 层（不变）；通过 `lint_chip` 0、`fm_gate` 68/68 与 Linux 27 窗对齐。
- 2026-11-17（exp/agu-share）：`16de223` EXP-TLBPORTS 第 3 步：DTLB 每个物理 AGU 一个口（`LSU_AGU_PHYS = 5`），请求自带访问类型（`tlb_mmu / tlb_mmu_core / tlb_mmu_lane`：口类型由参数改为输入 `req_is_store`），响应按口回给 LSU；这是 261bd67 之后对本目录的唯一提交。
- 2026-11-17：`1d8688e` EXP-042：口并行、`ttg_first_set` 对数深度，深度代理 163 → 67（在 261bd67 之前）。
- 2026-11-16：`8abb7ab` RTL 清理（删旧生成器和 spec/，折叠部分 rv32 条件）；2026-11-11：`72f2cd9` rv64 第 3 步：Sv39 TLB 和页表遍历器。
- 更早：见 git 历史。

## EXP-048 M3 补充：预取跨页页表遍历丢弃

DTLB（`FETCH=0`）新增 `pf_page_set` / `pf_page_vpn` 与 `walk_next_v` / `walk_next_vpn`。当 LSU 在空闲 load 口上为预取跨页候选触发新的页表遍历时记录 `pf_page_q`；若该遍历以页故障结束，下拍由 `early_pf_drop` 直接静默回收该遍历状态而不向任何指令报错（对应 `TlbMmu.cpp:287`）。
