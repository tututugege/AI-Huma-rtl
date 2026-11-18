---
module: dcache
area: memsys
rtl: rtl/memsys/dcache（除 dcache_pf.sv，它有自己的文档 dcache_pf.md）
model: trace-model MemSubSystem/RealDcache.cpp、WriteBuffer.cpp、MSHR.cpp、DcacheConfig.cpp 及对应头文件（三个调度单元 `mem_subsystem.dcache_`（类 `RealDcache`，阶段 `comb_stage2`、`comb_stage1`）、`mem_subsystem.wb_`（`WriteBuffer`）、`mem_subsystem.mshr_`（`MSHR`），后两者各有 `comb_axi_to_dcache`、`comb_dcache_to_axi`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 待测（由协调者补）
---

# dcache 设计文档

## 1. 职责

L1 数据缓存，加上它旁边的两个小结构：缺失状态寄存器 MSHR（记录正在向下取的行）和写回缓冲 WB（存放被驱逐的脏行，等写到 AXI）。三者在 RTL 里是同一个目录、一个顶层 `dcache`，在模型里是三个调度单元。

每拍做的事：

1. **接收请求**：4 个 load 口、3 个 store 口（`LSU_LDU_COUNT`、`LSU_STA_COUNT`）。请求来自 `mem_route`（它把 LSU 的请求和 ICache、页表遍历的请求合并到最后一个 load 口上，见 mem_route.md）。每个口一拍一个请求，先进"第一级"寄存器；
2. **第二级**（下一拍）：读 tag 阵列做命中判断，命中则返回数据（load）或写入字（store）；不命中则去 MSHR 分配或合并；写回缓冲里有同一行则直接转发（load）或合并（store）；
3. **行填充**：MSHR 收到 AXI 返回的整行后，选牺牲路，脏牺牲行推进 WB，新行写进阵列；
4. **AXI 请求**：MSHR 发读（整行 64 字节），WB 发写（整行）；
5. **预取**：`dcache_pf` 给出预取候选，借空闲的 load 口做 tag 探测（见 dcache_pf.md）。

模型对应三个调度单元，每拍的相位顺序由 `SimCpu::cycle` 里自动生成的序列给出：`wb_.comb_axi_to_dcache` → `mshr_.comb_axi_to_dcache` → `dcache_.comb_stage2`（……中间是 route、LSU、ISU 等）→ `dcache_.comb_stage1` → `wb_.comb_dcache_to_axi` → `mshr_.comb_dcache_to_axi`（`SimCpu.cpp` 中 `cycle()`）。RTL 是一个纯组合网表加寄存器，没有"相位"，模型里的先后关系体现成数据依赖。

## 2. 配置（`ttg_cfg_pkg` / `dcache_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 组数 / 路数 / 行大小 | 256 组 × 4 路 × 64 字节 = 64 KiB | `DCACHE_SETS_NUM`、`DCACHE_WAYS_NUM`、`DCACHE_LINE_SIZE` |
| 地址划分（32 位物理地址） | 行内偏移 `[5:0]`，组号 `[13:6]`（8 位），tag `[31:14]`（18 位） | `DCACHE_OFFSET_BITS`、`DCACHE_SET_BITS`、`DCACHE_TAG_BITS` |
| bank | 16 个，bank 号 = 组号低 4 位 = 地址 `[9:6]`；每个 bank 16 行（`ROW_W = SET_W - BANK_W = 4`） | `DCACHE_BANK_NUM`、`DCACHE_BANK_BITS`、`dcache_pkg` |
| 数据字 | 与 LSU 交换的字宽 `DW = XLEN_BITS = 64`；行内按 `DWORDS = 512/64 = 8` 个 64 位字；AXI 一侧仍是 16 个 32 位字（`WORDS = DCACHE_WORD_NUM = 16`） | `dcache_pkg` |
| 替换 | 每组 3 位树形 PLRU（4 路），牺牲路 = 第一个无效路，否则按 PLRU | `plru_touch`、`plru_victim`、`dcache_s2_fill.sv` |
| MSHR | 8 项，id 3 位（`DCACHE_MSHR_ENTRIES`、`DCACHE_MSHR_BITS`），空闲计数 4 位（`CNT_W`，0..8） | |
| WB | 8 项，环形队列（`DCACHE_WB_ENTRIES`） | |
| 端口 | 4 个 load 口（`NLD`）、3 个 store 口（`NST`），7 个请求槽（`NSLOT`）；最后一个 load 口（`P3 = NLD - 1`）被 ICache 探测和页表遍历共用 | `LSU_LDU_COUNT`、`LSU_STA_COUNT`、`memcpu_pkg` |
| 合并的第二个 store 字 | 每个 store 口一拍可带第二个字（`st2_t`，strb 为 0 表示没有） | EXP-024，模型 `LSU_PIPE_MERGE` |
| 隐藏重试 | 总是开（分级 LSU 是唯一的 LSU） | `dcache_s1` |
| 预取开关 | 参数 `PF_EN`（默认 1，`soc_top` 传入） | |
| 时钟节拍 | `AXI_SUBSYSTEM_FREQ_DIV = 1`：存储域和 CPU 同频，`cpu_phase0` 恒为 1（见 mem_top.md） | |

## 3. 接口

端口名带 `ld_` / `st_` 的是数组，下标是口号。请求来自 `mem_route`，响应回 `mem_route`（不直接连 LSU）。

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `ld_req_valid/addr/id/replay [NLD]` | load 请求：地址、32 位请求 id（第 31 位是"路由块的请求"标记，见 mem_route.md）、`replay` 为 LSU 重发标志（重发的请求和隐藏重试不参与预取训练，`slot_perf_replay`，见 dcache_pf.md） |
| 入 | `st_req_valid/addr/data/strb/l2/id [NST]` | store 请求：数据、字节使能、第二个字 `st_req_l2`、id |
| 入 | `icache_req [2:0]` | 本拍哪个 load 口上是 ICache 的探测（`NLD` 表示没有） |
| 入 | `mshr_req_accepted/_id`、`mshr_resp_valid/_id/_data[16]` | AXI 读主口：请求被接受、整行返回 |
| 入 | `wb_req_accepted`、`wb_resp_valid` | AXI 写主口：请求被接受、写响应 |
| 出 | `ld_resp_valid/data/id/retry/replay [NLD]`、`st_resp_valid/replay/id [NST]` | 响应。`replay` 四种：HIT（0）、CONFLICT（1）、MSHR_HIT（2）、MSHR_FULL（3） |
| 出 | `ld_retry_busy`、`st_retry_busy` | 该口的隐藏重试寄存器正占着，LSU 这拍不要在该口发新请求 |
| 出 | `mshr_fill`、`mshr_fill_addr` | 有一行填进了缓存（或释放了一个只进 LLC 的预取项），用来唤醒等待的 load / store |
| 出 | `mshr_req_valid/addr/id`、`mshr_resp_ready` | AXI 读请求（地址对齐到行，id = MSHR 项号） |
| 出 | `wb_req_valid/addr/data[16]` | AXI 写请求（整行） |

响应里的 `replay` 用白话说：HIT = 本次访问完成；CONFLICT = 这次没做成（bank 冲突，或 store 遇到正在写出的 WB 头项），请重发；MSHR_HIT = 缺失，该行已经在（或刚刚被）登记到 MSHR，等 `mshr_fill` 后重发；MSHR_FULL = 缺失且 MSHR 没有空项，等有空项时重发。store 在已登记 MSHR 时直接返回 HIT（它的数据合并进了 MSHR 项，见 5.4）。

## 4. 结构

```
 请求（来自 mem_route）
   │
 dcache_s1 ─ 每口选一个请求（真实请求 / 隐藏重试 / 预取探测）、bank 授权、
   │         第一级到第二级的寄存器（7 个槽、探测口号、填充快照 s2f、隐藏重试寄存器）
   │
   ├─► dcache_arr ─ 16 个 dcache_bank：tag / valid / dirty / pf / PLRU / 数据，读（组合）写（时钟沿）
   ├─► dcache_wb  ─ WB 8 项环：load 转发、store 合并、追加驱逐行、AXI 写请求
   ├─► dcache_mshr ─ MSHR 8 项 + AXI 响应暂存：查找、分配 / 合并（dcache_mshr_alloc）、填充请求、AXI 读请求
   │
   ├─► dcache_s2_ld / dcache_s2_st ─ 第二级：load 口 / store 口的命中、WB、MSHR 决策
   ├─► dcache_s2_fill ─ 第二级：填充快照选牺牲路、脏行驱逐、填充写
   ├─► dcache_pf ─ 预取器（独立文档）
   └─► dcache_resp ─ 响应暂存、用填充数据转发、发布
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `dcache.sv` | 339 | 顶层：只做端口适配和连线 |
| `dcache_pkg.sv` | 120 | 常量（端口数、地址域、replay 编码）、字节使能合并函数 `line_merge_n`、PLRU 函数 |
| `dcache_s1.sv` | 304 | 第一级：请求选择、bank 授权、预取探测放行、第一级到第二级寄存器、填充快照、隐藏重试寄存器 |
| `dcache_arr.sv` | 156 | 把请求者映射到 16 个 bank，汇总读结果，仿真时检查"每拍每 bank 只有一个请求者"的断言 |
| `dcache_bank.sv` | 100 | 一个 bank：16 行 × 4 路的 valid/dirty/pf/tag/数据，16 个 PLRU 字 |
| `dcache_s2_ld.sv` | 124 | load 口第二级决策（纯组合） |
| `dcache_s2_st.sv` | 94 | store 口第二级决策（纯组合） |
| `dcache_s2_fill.sv` | 85 | 填充侧：选牺牲路、判断 WB 是否有空间、出驱逐行 |
| `dcache_mshr.sv` | 238 | MSHR |
| `dcache_mshr_alloc.sv` | 51 | MSHR 分配 / 合并：第 k 个要分配的请求拿第 k 个空闲项 |
| `dcache_wb.sv` | 146 | 写回缓冲 |
| `dcache_wb_find.sv` | 33 | 在 WB 环里找某一行的最年轻项 |
| `dcache_resp.sv` | 231 | 响应暂存、用到达的填充行转发、发布 |
| `dcache_cover.sv` | 149 | 仅仿真：29 条 `cover property`，统计各条路径有没有走到；没有硬件 |

（`dcache_pf.sv` 214 行，见 dcache_pf.md。）

几个非平凡文件的说明：

- **dcache_s1**：每个口先选"这拍谁来占用"：真实请求优先；没有真实请求时，用隐藏重试寄存器里的请求，再没有就重发第二级刚判成 bank 冲突的那个请求。然后按 bank 授权：优先级是 填充快照 > load 0..3 > store 0..3（正在重试的口在自己的类内先授权）；同一个 bank 的后来者不被授权，记为"replayed"。被授权的请求下一拍在第二级读阵列。未被授权且是 LSU 来的请求，自己重发（隐藏重试），LSU 看不到冲突；路由块的请求（id 第 31 位为 1）或重试寄存器已占用时则返回 CONFLICT + retry。预取探测取第一个空闲的 load 口，条件是它的 bank 这拍没人用。
- **dcache_arr / dcache_bank**：阵列以 bank 为单位，bank 授权保证每拍每个 bank 只有一个读请求者，所以每个 bank 只有一个读口，读地址是各请求者行号按位或。代码里是普通寄存器阵列（`logic data_q[WAYS][ROWS]`），没有 SRAM 宏。写口：填充 1 个、store 字写 `NST` 个、PLRU 写 `NSLOT + 1` 个。
- **dcache_mshr**：每项存 `valid`、`issued`（读请求已被 AXI 接受）、行地址、已合并的 store 数据 / 字节使能 / dirty、`pf`（预取项）、`nofill`（只进 LLC 的预取项）；另有一个 AXI 响应暂存槽（`hold_*`，只有一个）。每拍先处理 AXI 侧（接受标记、响应入暂存槽），再处理填充确认（释放项）、分配 / 合并，最后从最终状态选下一个要发的读请求（demand 优先于预取，`send_pass`）。
- **dcache_wb**：8 项环（`head`、`count`），`send` 表示有写请求在途；B 响应弹出队头；load 转发取同行的最年轻项（`dcache_wb_find`），store 合并到同行最年轻项（若它是队头且有写在途则报 busy）；被驱逐的脏行追加到队尾；AXI 写请求就是队头（含这拍的合并和追加）。
- **dcache_resp**：每个口保存一个待发布响应（及它所答复的请求，store 还有数据）。TICKS = 1 时这层是纯组合直通（见 7）。当一个等填充的响应（MSHR_HIT / MSHR_FULL）遇到同一行的填充到达，响应当拍变 HIT：load 取填充行里的字，store 合并进填充行并使其变脏（`frf_data`/`frf_dirty` 再交给 s1 做快照）。

状态：阵列（每 bank：valid/dirty/pf 各 4×16 位，tag 4×16×18 位，数据 4×16×512 位，PLRU 16×3 位）；s1 的 7 个槽寄存器、隐藏重试寄存器（每口一份）、填充快照 `s2f_*`（含 512 位数据）；MSHR 8 项（含每项 512 位 store 合并数据和 64 位字节使能）和一个 512 位暂存槽；WB 8 项（行地址 + 512 位数据）、`head`/`count`/`send`；响应暂存。

## 5. 一拍内的数据流

### 5.1 第一级（`dcache_s1`）

1. 每口选请求：`real_v`（`mem_route` 给的）> 隐藏重试寄存器（`use_pend`）> 第二级这拍判为 bank 冲突的那个（`use_new`）；`blocked`（该口上一个响应还没发布）时不发隐藏重试。
2. bank 授权（见上）。填充快照占用它所在的 bank：新行进入第二级（`fill_snap`）时占，同一行已在第二级且这拍写完则不占。
3. 预取探测：第一个没有请求的 load 口，且预取队列头的 bank 这拍没被占，就送出探测（`pf_taken`）。
4. 寄存：`slot_valid/addr/id/...`、`slot_replayed = req_v & ~grant`、填充快照（这拍进入的填充行和同拍 store 合并进快照的数据）。

### 5.2 第二级 load 口（`dcache_s2_ld`，读的是第一级寄存器和阵列）

对每个被授权的 load，优先级：WB 转发（`byp_valid`）> 缓存命中（更新 PLRU、返回数据）> ICache 探测（只查，返回 CONFLICT，不分配）> 已有 MSHR 项（MSHR_HIT）> 无空项（MSHR_FULL）> 分配新项（MSHR_HIT，之后重发时命中）。MSHR 空项数按口顺序记账（`used[]` 链：`free_in > used[i]` 才能分配），store 口分到的是 load 口用剩的（`free_rem = mshr_free - ld_alloc_cnt`），预取探测分到的是再剩的（`pf_free`）。命中预取行的第一次使用清该行的 pf 位，并作为预取训练事件。

### 5.3 第二级 store 口（`dcache_s2_st`）

优先级：(1) 与这拍到达的填充请求同一行：HIT，store 合并进填充快照（`mrg_en`）；(2) 缓存命中：HIT + 写字 + PLRU；(3) 未命中：WB 合并成功 → HIT；WB 合并 busy → CONFLICT；已有 MSHR 项 → HIT（合并）；没有空项 → MSHR_FULL；否则分配 → HIT。

### 5.4 填充（`dcache_s2_fill` + `dcache_mshr`）

MSHR 的暂存槽里有一行（`fr_valid`）→ 与项里已合并的 store 字节覆盖后成为 `fr_data`（`dcache_resp` 可能再合并等待中的 store）→ 第一级把它拍成快照 `s2f` → 第二级选牺牲路（已有同 tag 的路则用它）→ 牺牲行脏且 WB 有空位：写回 WB 并填充；脏但 WB 满：本拍不填充也不确认，快照保持，下一拍重试（`fill_hold`）。填充成功给 MSHR 发 `fill_done`，MSHR 释放该项，同时 `mshr_fill` 通知 LSU / 路由块。

### 5.5 AXI 侧

- MSHR：被接受的读请求标 issued；响应 id 对到项号，非 `nofill` 的进暂存槽，`nofill`（只进 LLC 的预取）的直接丢弃并释放该项（`release_event`）；`ax_resp_ready` 在暂存槽空闲时为 1。
- WB：写请求由队头产生，B 响应弹出队头（写响应 ready 恒为 1，见 mem_top.md 的 `m_wr_resp_ready[0]`）。

### 5.6 响应发布（`dcache_resp`）

第二级的原始响应进暂存，经"填充转发"后发布到 `mem_route`。TICKS = 1 时 `phase0` 恒为 1，响应在第二级的当拍就发布，不再多保留一拍。

## 6. 关键路径与深度

depth: 待测（由协调者补）。从代码读出的，未综合验证，最长的组合链大致有：

- **第二级 load**：第一级寄存器的地址 → bank 号 → 16 选 1（4 路 tag 和数据）→ tag 比较 → `ttg_first_set` 选命中路 → 命中数据 → `dcache_resp` 转发 → `mem_route` 的响应分流 → LSU；
- **MSHR 记账链**：8 项行地址与 7 个口的比较（`find_hit`）→ 各口 `alloc_ok`（沿 load 口、再沿 store 口、再到预取的 `used` 链）→ `mreq_en` → `dcache_mshr_alloc`（第 k 个请求拿第 k 个空闲项）→ 本拍 AXI 读请求（新项当拍就能发出，`dcache_mshr` 注释里写明）；
- **填充 / 驱逐**：快照 → 牺牲路 → `victim_dirty` 与 `wb_free` → `fill_valid`、`evict_valid` → WB 追加 → 队头数据 → AXI 写请求，同时 `fill_done` → MSHR 释放 → 空闲项数 → 同拍后面的 `alloc_ok`；
- **第一级 bank 授权**：7 个槽两两比较 bank 号和优先级键；
- **响应转发**：AXI 响应 → 暂存槽 → `fr_data`（叠加项内 store 字节）→ `dcache_resp` 叠加等待中的 store → 快照；这条在 TICKS = 1 时与第二级的 load 响应都落在同一拍里。

## 7. 与模型的差异和取舍

- **模型不带数据，RTL 带**：模型的 `DcacheArrays` 只有 tag / valid / dirty / pf / PLRU，数据从功能内存取（`MemRouteBlock::comb_response` 里 `tbhook::mem_read`）。RTL 把 512 位行经过阵列、MSHR 项（store 合并数据和字节使能）、暂存槽、填充快照、WB 项传递，load 返回的是真实数据。这部分是 RTL 独有的，不影响周期，由整核逐提交对拍功能模型来验证。
- **bank 冲突检查**：模型有 `check_data_bank_access`（调试用，同拍同 bank 两个访问会中止）；RTL 在 `dcache_arr` 里用仿真断言做同样的事。
- **`dcache_cover`**：RTL 独有的仿真覆盖点，无硬件。
- **响应暂存与节拍**：`dcache_resp` 从 16 倍频的旧结构（一个 CPU 周期 16 个存储域节拍，每口攒一个响应，在节拍 0 发布）保留下来。现在 `AXI_SUBSYSTEM_FREQ_DIV = 1`，`phase0` 恒真，这一层退化为组合直通；模型对应的是 `RealDcache::drive_response`（用同一拍到达的填充把等待中的响应改成 HIT，用上一拍记录的元数据 `resp_meta_cur_` 匹配）。
- **MSHR / WB 的相位合并**：模型在每个调度单元里分 `comb_axi_to_dcache`、`comb_dcache_to_axi` 两段，用原地更新的 `nxt` 状态；RTL 在 `dcache_mshr` / `dcache_wb` 里把它们合并成"A 段（AXI 侧）→ B 段（分配 / 追加）→ AXI 输出"的单个组合块，次态相同（见两个文件开头的注释）。
- **`mshr_count`**：模型有这个计数器，RTL 不存，用 `valid` 位的 popcount 代替（文件头注释）。
- **脏牺牲行 WB 满的处理**：模型和 RTL 一致：本拍不填充、不确认，快照保持；模型代码注释里写"当作干净行覆盖"，但 `dirty_info.valid = false` 并且 `fill_write_.valid = false`，实际行为是不填充，没有数据丢失。
- **ICache 探测的数据**：模型的探测返回走 `MemRouteBlock` 从功能内存取；RTL 返回的是缓存阵列里的 64 位字（由 `mem_route_resp` 选出 32 位），行为在命中时等价。
- **预取器**：模型的 `DataPrefetcher` 是 `RealDcache` 的成员（`pf`），没有单独调度；RTL 拆成 `dcache_pf`（见 dcache_pf.md）。
- **模型里有、RTL 里没有的**：性能统计（`perf_replay`、`PfStats`、`sample_perf`）、`getenv` 调试、功能预热接口 `warm_access`、`llc_warm_set` 等（快速预热用，RTL 没有）。

未核对（继承自旧文档）：无，旧文档的内容没有带入。以下两条标注"RTL 注释称"的说法是 RTL 文件头注释的原话，没有再对照模型逐行核对：`write_dcache_line` 按 tag 重新找路、同拍 store 与填充的 bank 不会冲突（因此填充数据恰好等于快照）。

代码里看起来可疑的地方（未改，仅记录）：
- `dcache_s2_fill.sv`：写入的路 `fill_way_tgt` 在"该 tag 已在某路"时取那一路（RTL 注释称对应模型 `write_dcache_line` 的重新按 tag 找路），但驱逐行 `evict_line` / `evict_data` 和 `victim_dirty` 始终用 `victim` 路；两者不同时（同 tag 已在另一路）驱逐的是 `victim` 的脏行，模型 `stage2` 同样用 `select_way` 判断驱逐，所以行为一致，但这个组合是否会真发生没有验证。
- `dcache.sv` 里 `slot_lsu = !slot_id[31]` 用 id 的最高位区分"LSU 请求"和"路由块 / 预取探测请求"；预取探测用固定 id `32'h8000_0000`（`dcache_s1.sv`），与路由块的 id 同属第 31 位为 1，约定见 mem_route.md。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）。其中与 dcache 直接相关的有 `dcache-conflict-writeback`、`dcache-mshr-pressure`、`pf-stress`、`memory-stress-small`、`memory-boundary`、`directed/memspec_*`。
- **定向程序（需要用 Homebrew LLVM 构建，不在 67 个里）**：`tests/dcache/wb-burst.c`、`wb-flood.c`、`wb-merge.c`，用 `scripts/build_dcache_tests.sh` 构建，覆盖写回缓冲突发、洪泛、store 合并进 WB 项和 load 从 WB 转发。
- **覆盖点**：`dcache_cover.sv` 的 29 条 `cover property`（仅仿真）。
- **断言**（仅仿真）：`dcache_arr` 的"每拍每 bank 只有一个请求者"、`dcache_resp` 的"响应暂存不会被同口新响应覆盖"。
- **Linux 整核门禁**：`scripts/linux_gate.sh`（逐提交对拍 + PMU 序列对比 + 登录提示）。
- **Lint**：`scripts/lint_chip.sh`。
- **没有 dcache 的模块级独立测试**（没有把模型和 RTL 单独对拍的测试台）。**待补**：dcache 模块级随机请求流对拍（含 bank 冲突、MSHR 满、WB 满、填充与同行 store 同拍）。

## 9. 参数与开关速查

`DCACHE_SETS_NUM`、`DCACHE_WAYS_NUM`、`DCACHE_LINE_SIZE`、`DCACHE_WORD_NUM`、`DCACHE_*_BITS`、`DCACHE_BANK_NUM`、`DCACHE_MSHR_ENTRIES`、`DCACHE_WB_ENTRIES`、`LSU_LDU_COUNT`、`LSU_STA_COUNT`、`XLEN_BITS`（`ttg_cfg_pkg`）；`PF_EN`（`dcache` 参数）；`AXI_SUBSYSTEM_FREQ_DIV`（决定 `cpu_phase0`）。`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 10. 变更记录

- 本分支（exp/agu-share）未改动 `rtl/memsys/dcache`（`git log 261bd67..HEAD -- rtl/memsys/dcache` 为空）。
- 更早（来自 `git log`）：`cff4afe` rv64 step 5；`fb05807` rv64 step 2（数据字 XLEN 位、strb 为 XLEN/8+1 位）；`b44ab4c` EXP-024：store 合并改成逐字节并行的 `line_merge_n`；`b1e0335` EXP-024：RTL 的 store 合并（第二个 store 字通路）；`ec493f4` LSU_PIPE（EXP-014）；`5add753` 引入 dcache 域（当时是 16 节拍锁步）。
