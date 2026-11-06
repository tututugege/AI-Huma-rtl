---
module: dcache_pf
area: memsys
rtl: rtl/memsys/dcache
status: green (PF_EN=0 default; PF_EN=1 cycle-equal to trace-model on 66/66 programs)
note: L1D prefetcher h1 (EXP-009), cycle contract taken from trace-model branch exp/prefetch-h1 (0eb258c)
---

# L1D 数据预取器 h1：RTL 实现规格

C++ 规格：trace-model `exp/prefetch-h1`（`MemSubSystem/include/DataPrefetcher.h` + `RealDcache.cpp` / `MSHR.cpp` / `DcacheConfig.cpp` 里的预取改动，`git diff main exp/prefetch-h1 -- MemSubSystem`）。
预取默认关（`PF_ENABLE=0`），关时周期必须与 `scripts/ref_cycles.txt` 逐个相同（门禁 66/66）；开时与 trace-model（`PF_ENABLE=1`）逐程序周期相同。
设计与结果见 `docs/EXPLORATION.md` EXP-009。本文列出 RTL 要做的事和 C++ 里必须逐拍复刻的行为。

## 1. 新模块 `dcache_pf`（对应 `DataPrefetcher`）
状态（约 0.4 KB）：请求 FIFO 8×27 位 + 指针；单表项步长检测器 {valid, last[26], stride[8, 有符号], conf[2]}；
主生成器 {valid, next[26], base[26], stride[8], left[4], pushed}；LLC 下一行生成器 {valid, next[26], base[26], left}；训练输入寄存器 2×{valid, line[26], miss, pf_hit}。
每拍（时序更新，组合只读寄存器）：
1. `head_taken` → FIFO 出队。
2. 主生成器有效：占用 FIFO 写口；候选 = `next`；与 `base` 不在同一 4 KiB 页（`line>>6` 不同）→ 生成器作废（不入队）；否则与 FIFO 中已有行比较（CAM），重复则丢，否则入队 `{line, llc=0}`；`next += stride`（26 位回绕）；`left` 减到 0 作废。
3. 主生成器本拍没有占用写口且 LLC 生成器有效：同样的页检查和 CAM，入队 `{line, llc=1}`，`next += 1`，`left` 减到 0 作废。
4. 训练：用上一拍寄存的 ≤2 个事件，按口序依次（见下）。
5. 选择：本拍 stage 2 的 4 个 load 口事件中，`miss || pf_hit` 的前 2 个（口序）写入输入寄存器，其余丢弃。
训练（每个事件）：`miss` 则 LLC 生成器 := {base=line, next=line+1, left=1}（覆盖）；步长检测器：无效 → 分配 {last=line, stride=0, conf=0} 并返回；
`d = sext(line-last)`；`d==0` 返回；`in_range` = d 在 int8 范围；`d==stride && in_range` → conf<3 时 +1；否则 conf>0 → conf-1，conf 变 0 且 in_range 时 stride:=d；否则 stride := in_range ? d : 0；`last := line`；
`conf>=2 && stride!=0` → 主生成器 := {base=line, next=line+2*stride, stride, left=8}（覆盖）。
注意同一拍两个事件顺序训练（后者看到前者更新后的表项），第二个事件的 `start` 覆盖第一个。
输出：`head_valid`、`head_addr = line<<6`、`head_llc`。

## 2. dcache_s1（stage 1）
- 每个 load 槽新增寄存器位 `pf`（探测槽）、`pf_llc`、`perf_replay`（见 §6 的 LSU 重放位）。
- 探测：在所有需求（填充快照、load0..3、store0..3 的 bank 授权）之后，取**第一个** `!slot.valid` 的 load 槽 i（槽有效 = 真实请求或隐藏重试已占用）；若该行 bank 已被占用（填充、需求、重试）→ 本拍不探测（不出队）；否则该槽 `valid=1, pf=1, pf_llc=head_llc, addr=head_addr, req_id[31]=1（不是 LSU 请求）, replayed=0, perf_replay=1`，出队。该槽读阵列 tag、查 WB 旁路、查 MSHR（`is_prefetch=1`，不触发提升）。
- 只有 `PF_EN` 且 `head_valid` 时才做；此时槽的 `valid` 判断在选择隐藏重试之后。

## 3. dcache_s2_ld / s2_st（stage 2）
- pf 槽不产生 LSU 响应，也不走 load 的分类链；先处理所有需求 load、store，之后才处理探测。
- 空项计数：`free_in` → 需求 load0..3 → store0..3 各占用一个后，探测才用剩余（`free_rem_after_stores`，**含 store 占用**，由 `mshr_free - ld_alloc_cnt - st_alloc_cnt` 得到）。
- 探测判定顺序：WB 旁路命中 → 丢；cache 命中或与本拍填充同行（`s2f` 或 MSHR 当前 fill_req 同行）→ 丢；MSHR 已有同行项 → 丢；`free <= PF_MSHR_RESERVE(=0)` → 丢；否则向 MSHR 申请一项 `{is_prefetch=1, no_fill=pf_llc}`。
- 需求 load 命中且 `!perf_replay && req_id[31]==0`：pf 位置位的路清零，并产生 `pf_hit` 事件（`pf.acc[i]`）；需求 load 的 miss 分支（WB 旁路、命中判定之后、MSHR 查找之前）在同样条件下产生 `miss` 事件。ICache 探针（`probe`）的 CONFLICT 分支先于 miss 事件，不产生事件（对照 C++ 行序）。
- 事件的 `paddr` 为槽地址。

## 4. dcache_mshr
- 项新增 `is_prefetch`、`no_fill`。
- 需求请求（load / store，任何 `find` 或分配合并）遇到 `is_prefetch` 项：清 `is_prefetch`、`no_fill`（"晚到提升"）。探测的 find 不提升。
- AXI 读口发请求：先选"需求项"（`valid && !issued && !is_prefetch` 的最低下标），没有再选预取项。
- `no_fill` 项的 AXI 响应到达（该项 `valid && issued`）：响应当拍就被吸收（`resp_ready` 对应 accepted），**不进保持槽**，项直接释放，并给出 `release_event`（本拍）；保持槽占用时的 `take` 条件按 C++ `comb_inputs_axi` 的顺序（保持槽空才收）。
- `fill_req` 带 `is_prefetch`，经 `s2f` 带到 stage 2 的填充写。释放项清 `is_prefetch/no_fill`。

## 5. 阵列与填充
- 每路新增 `pf` 位（256 组 × 4 路）：填充写时 := `is_prefetch`（目标路 = 已有同 tag 路否则牺牲路）；需求 load 命中且满足 §3 条件时清零。
- `mshr_fill`（给 LSU 的唤醒）= `fill_valid || release_event`；`release_event` 时 `mshr_fill_addr` 为 0（C++ 在无填充时地址为 0）。
- 预取填充与需求填充在 PLRU 上同样处理（`INSERT` 开关已删除，行为 = 普通填充）。

## 6. LSU → DCache 新增信号 `ld_req_replay`（每个 load 口 1 位）
训练要求 `!perf_replay`，`perf_replay = 隐藏重试 ? 1 : lsu_req.replay`，其中 LSU 请求的 `replay = (l.replay_type != HIT)`（`RealLsu.cpp:472`，该 load 上次被 DCache 回过非 HIT 响应后重发）。
这个位目前不在 RTL 的 LSU→DCache 接口上（spec `lsu.io`/`mem_route.io` 明确省略了 `*.replay` 请求标志）。需要从 `lsu_dc_req_ld`（已有 `replay_type`）一路接到 `lsu` → `back_top` → `core_top` → `soc_top` → `mem_top` → `mem_route` → `dcache`；`mem_route` 里 PTW / ICache 复用的口（`LSU_LDU_COUNT-1`）为 0。相应 spec（`lsu.io`、`mem_route.io`、`dcache.io`、`core_top.io`、`back_top.io`）补字段。

## 7. 参数与开关
`dcache` 顶层参数 `PF_EN`（默认 0，由 `mem_top` 参数 → `soc_top` 参数给出；`tb/soc/build.sh` 加 `SOC_PF=1`）。`PF_EN=0` 时所有新状态被综合优化掉、`ld_req_replay` 不被使用；周期不变。

## 8. 验证
1. `PF_EN=0`：`lint.sh`、`lint_chip.sh`、门禁 66/66、周期与 `ref_cycles.txt` 全部相同。
2. `PF_EN=1`：trace-model `PF_ENABLE=1` 与 RTL 在带预取的程序上逐周期相同（dhrystone、coremark、memory-stress-small、matmul；以及强制打开的小程序）；不一致用 `scripts/first_diff.sh`。
3. 重测 `axi_llc` 读响应队列 RQD（现为 8）：预取使 AXI 读请求更密。
4. `scripts/synth_module.sh` 面积代理：`dcache_pf` + MSHR + 阵列 pf 位；`docs/MAIN_RECORDS.md`（性能 + 综合）按 `docs/WORKFLOW.md`。

## 9. 风险
- `perf_replay` 位原来是"只喂 perf"的字段，现在影响行为；LSU 侧 `replay_type` 的产生点必须与 trace-model 同拍。
- 探测占用一个空闲 load 槽的阵列读口与 WB/MSHR 查找口，需确认这些口在 RTL 里按槽复用（`slot_granted`）；pf 槽的 `slot_id[31]=1`，不能被"隐藏重试"逻辑当作 LSU 请求（`retry_issue` 条件含 `!slot_id[31]`，已满足；pf 槽 `replayed=0`，不会进重试）。
- `no_fill` 项在 AXI 响应当拍释放：C++ `comb_inputs_axi` 的顺序与"保持槽空才收"条件需逐拍对齐，否则与 `mshr_fill` 唤醒错一拍。

## 10. 实现与验证结果（2026-11-06）
- RTL：`dcache_pf.sv`（新）；`dcache_s1`（探测槽、`perf_replay`、`s2f_pf`）、`dcache_s2_ld`（pf 槽排除、训练事件、`pf_cand`）、`dcache_s2_st`（`alloc_cnt`）、`dcache_mshr`（`is_prefetch/no_fill`、晚到提升、两遍 AXI 选择、`no_fill` 响应当拍释放 + `release_event`）、`dcache_bank/arr`（pf 位）、`dcache_resp`（`release_event` 唤醒）、`dcache`/`mem_top`/`soc_top`（参数 `PF_EN`）、`ld_req_replay` 由 `lsu_dc_req_ld` 经 lsu/back_top/core_top/mem_top/mem_route 接到 dcache。
- 开关：`soc_top` 参数 `PF_EN`；测试平台 `SOC_VOPT="-GPF_EN=1" SOC_OUT=<dir> SOC_FM=1 bash tb/soc/build.sh`。
- `PF_EN=0`：`lint.sh rtl/memsys/dcache` 通过，门禁 66/66，周期与 `ref_cycles.txt` 全部相同（新增的 `ld_req_replay`/pf 位被综合掉）。
- `PF_EN=1`：`REF_CYCLES=scripts/ref_cycles_pf.txt bash scripts/fm_gate.sh ...` 66/66 通过（逐条对比无不一致），周期与 trace-model `PF_ENABLE=1`（`exp/prefetch-h1` `0eb258c`）逐个相同；其中 25 个程序的周期因预取而变化（dhrystone 162,033 → 161,183，coremark 255,335 → 256,573，memory-stress-small 347,305 → 334,635）。
- 面积代理（yosys 通用门，相对数字）：`dcache_pf` 3,334 个单元、422 个触发器；`dcache_mshr` 95,540（main）→ 95,020（两个标志位的触发器增加，被其他逻辑的差异抵消）；阵列新增 pf 位 256×4 = 1,024 个触发器。工艺库、时序（WNS）：**未做**。
- 调试中发现的两个实现错误（已修）：`dcache_pf` 里 `g_valid_d` 等在两个 `always_comb` 里赋值，后一个覆盖前一个（预取器从不入队）；`slot_pf_llc` 没有和 `slot_pf` 相与，需求项被标成 `no_fill`（表现为 dhrystone 周期差 2）。
- 未做：`axi_llc` 读响应队列 RQD 重测（预取使 AXI 读请求更密）、SPEC 云上全量复跑、`docs/MAIN_RECORDS.md`（未合入 main）。
