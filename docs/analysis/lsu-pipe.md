# LSU_PIPE（分级流水 LSU）RTL 行为清单

规格来源：trace-model-lsupipe 的 `docs/LSU_PIPE.md`（第 2 节）和 `back-end/Lsu/RealLsuPipe.cpp`、`include/RealLsuPipe.h`（开关 `LSU_PIPE=1`）。
本文把模型里的每个阶段整理成 RTL 的寄存器、端口、同拍依赖，并列出模型里“不是硬件”的写法和 RTL 的写法，
以及为了让 RTL 能写而对模型做的小改（第 6 节）。RTL 在 `rtl/backend/lsu/lp_*.sv`，开关是 `ttg_cfg_pkg::LSU_PIPE`（0 = 旧 LSU，保留）。

## 1. 寄存器（每拍开头的状态 = 模型的 `pcur`）

| 名字 | 位宽 × 数量 | 说明 |
| --- | --- | --- |
| LDQ 表项 | 64 项 | `st`(4)、`rob_idx`(7)/`rob_flag`、`br_mask`(64)、`dest_preg`(7)、`func3`(3)、`vaddr`(32)、`pa_v`、`paddr`(32)、`mmio`、`pf`、`lrsc`、`result`(32)、`snap_idx`(6)/`snap_flag`、`rcause`(3)、`blk_idx`(6)、`rwait`(3)、`rtype`(2)、`epoch`(4，永不复位) |
| LDQ 状态 | EMPTY ALLOC PIPE DCW RPW RDY WBP MMW MMR | PIPE = 在 L1/L2 或重放寄存器里；RPW = 停车等事件（原因见 `rcause`：TLB ADDR HOLD DATA DC）；RDY = 可进重放口 |
| STQ 表项 | 64 项 | `va_v pa_v data_v pf mmio lrsc sc_pass suppress trp wbp wbd cmt iss mmw done`（各 1）、`vaddr paddr data`(32)、`func3 dest_preg rob_idx/flag br_mask`、`rtype`(2)、`rwait`(3) |
| STQ 指针 | head(6)+flag、count(7)、ccount(7) | `stq_commit = head + ccount`（不建寄存器） |
| L1/L2 寄存器 PL12 | 4 个 | `v ldq(6) epoch(4) tlb(2) mmio cand_v cand(6) dcblk`；RTL 另带 `paddr(32) vaddr[11:0] func3`（L2 不再读 LDQ，等价：表项在 L1→L2 之间只能被杀/重分配，由 st+epoch 检查拦截） |
| 重放寄存器 RP | 2 个 | `v ldq(6)`；`rp_ptr`(6) 轮转指针；STA 重放寄存器 `srp {v, stq(6)}` |
| 未缓存单元 / LR-SC 预约 | 各 1 | 同旧 LSU（`lsu_lrsc` 复用） |

没有的东西：6 个环形队列、wait_dcache 槽、`req_gen`(25 位)、窗口 20/15。看门狗（`wd`）不做（模型里从未触发）。`miss`（TMA）不做。

## 2. 一拍内的阶段顺序（同拍依赖）

模型的 `comb_*` 在同一个 `pnxt` 上顺序改写，RTL 不能并行化的部分就是这条链（每步读前面步骤的结果）：

| # | 阶段 | 读 | 写 / 产生 |
| --- | --- | --- | --- |
| P1 | stq_commit | ROB 提交口(8)、`wbd`、flush | `cmt suppress done`、ccount（按口顺序的 8 级链：第 i 个被接受的 store 必须是 commit+已接受数） |
| P2 | mmio_in | MMIO 响应、未缓存单元 | MMR load → WBP+result；MMIO store `mmw→0, done` |
| P3a | L2（PL12 ×4） | PL12、**寄存器** STQ（STLF 确认读 pcur）、LDQ st/epoch | 每口一个决定：直写回 WBD(pf / forward)、停车(cause,blk,wait)、MMW、DCW、RDY |
| P3b | DCache load 响应(4) | 响应、P3a 之后的 `st==DCW` 和 epoch | HIT → 直写回（若该口已被 L2 占用则 WBP）；其他 → 停车 DC |
| P4 | DCache store 响应(3)、MSHR fill | 响应 | `iss→0 rtype done rwait`；fill 唤醒 `rwait=0`（HIT 同行；FULL 取最老 3 个） |
| P5 | lsu2exe | P3 结果、STQ、`cur.lrsc` | 直写回口 → STA 写回(3，最老优先，SC 走空闲 load 口) → WBP load（最低 LDQ 号优先，用剩下的口）；写回的 load 表项置 EMPTY；LR 设预约、SC 清预约；`ev_sc` |
| P6 | exe2lsu | STD(3)、STA(3)、LOAD(4) | STQ 数据/vaddr/va_v；LDQ 表项置 PIPE；**按口号压缩到连续槽**（s1/l1），`ev_data ev_sta` |
| P7 | tlb_out | RP、`srp`、新到的 l1/s1 | 重放寄存器填入新 load 后剩下的槽；MMU 请求（vaddr 来自 AGU 或 LDQ） |
| MMU | 同拍组合 | — | 响应 |
| P8 | tlb_in | MMU 响应 | LDQ `pa_v paddr mmio pf result`；STQ `pa_v paddr mmio pf wbp trp`；pf 清预约；`ev_sta` |
| P9 | stlf | pcur STQ + 本拍到达的 STA 旁路 | L1 部分地址 CAM：每个 load 口 `cand_v cand`；MMIO load 起占未缓存单元 |
| P10 | dis2lsu | 分配请求 | LDQ 表项复位+`epoch+1`；STQ 追加，count 增 |
| P11 | flush | ROB flush / mispred / clear_mask | LDQ 清空/清位；STQ 截断；未缓存单元、预约、重放寄存器清除 |
| P12 | lsu2dcache_ldq | l1 槽、`load_retry_busy` | DCache 读请求；PL12 写入；启动时 `epoch+1` |
| P13 | lsu2dcache_stq | STQ、`store_retry_busy` | 排空（≤2 口）、MMIO store 起占 |
| P14 | check | 全部事件 | STQ 退休（≤4）`ev_ret`；唤醒一遍；重放寄存器填充（含本拍刚唤醒的项）；srp 填充 |

关键长路径（同拍串联）：`AGU → MMU → paddr → L1 CAM(64×) → cand → PL12`；`ev_sta/ev_data(AGU) → 唤醒 STLF 确认 → RDY → 轮转 find-first → RP 寄存器`；
`L2 比较(STQ 读) → 直写回 → 写回口选择(WBP 最低号) → 写回数据`。综合报告里按这几条看。

## 3. 模型里“不是硬件”的写法，和 RTL 的写法

1. **64 位事件向量 `ev_sta/ev_data/ev_ret/ev_sc`**。位向量本身便宜：由固定个数的端口（STA 槽 ≤3、STD ≤3、SC 写回 ≤4、退休 ≤4）独热译码得到，LDQ 表项用 `blk_idx` 对向量做 64:1 单比特选择。
   麻烦的是**附带的信息**（见 2）。
2. **唤醒时的 STLF 确认**（RC_ADDR 在 `ev_sta|ev_ret` 时读 `pnxt.stq[blk_idx]`）。RTL 不做 64×64:1 读，而是让每个 STA 槽（≤3，含重放槽）广播
   `{stq 号, va_v, vaddr[11:0], func3, pa_v, paddr, data_v, lrsc&&!sc_pass, suppress, data}`（取本拍 P8 之后的最终值：到达写入 + MMU 结果 + 同拍 STD 旁路 + 同拍 SC 判定）；
   RC_ADDR 表项把 `blk_idx` 与三个槽的号比较、取那一槽的信息，每个表项一个 `range_rel`（共 64 个）做确认。`ev_ret` 优先：已退休 → 直接 RDY，不看字段。
   RC_DATA 唤醒（`ev_data`）：转发数据取同拍 STD 口里 `stq_idx==blk_idx` 的口（3 选 1），按 load 的地址偏移/func3 提取，写入 `result`，状态置 WBP。
3. **“找最低位优先 + 轮转指针”**（重放口填充）。RDY 向量（64 位）按 `rp_ptr` 循环右移 → `ttg_first_set`（`req & -req`）→ 第一个；第二个口把第一个清掉再找一次（模型里第二口从 `i0+1` 起找，与“旋转序里的第二个 RDY”相同）；
   指针 = 最后一个被选项 + 1。已被占用（`rp[r].v`）的口不选。
4. **重放寄存器含本拍刚唤醒的项**：RDY 向量由“P13 之后的 st==RDY”得出，包括本拍 P14 唤醒出来的项（parking 的 TLB / dcblk / CONFLICT 等 wait=0 会在同一拍 RPW→RDY→RP）。
   这是一条组合路径（事件 → 唤醒 → RDY 向量 → 旋转 → first_set → RP 寄存器）。**RTL 按模型保留**，综合报告里单独指出。
5. **epoch 过滤**：每个 LDQ 表项 4 位 epoch，分配和每次启动 DCache 请求时 +1；请求 id = `{epoch, ldq}`；L2 和响应处理都只接受 `st==期望状态 && epoch 相等` 的结果，其余丢弃。
   RTL：表项内部比较（响应按 `req_id[5:0]` 译码成 64 位独热，表项自己比较 epoch，向端口回报“被接受”），不需要 64:1 读。
6. **两个隐藏重试位（DCache 两处改动，LSU_PIPE=1 时生效）**：
   - `load_retry_busy[4]` / `store_retry_busy[3]` = DCache `rty_valid_q`（寄存器位，即隐藏重试锁存有效），经 mem_top/core_top/back_top 送到 LSU。
   - LSU 侧：L1 槽 k 若 `hit && !mmio && !cand_v && load_retry_busy[k]` → 不发读请求，`dcblk=1`，L2 按 CONFLICT 停车（wait 0）；store 排空只用 `!store_retry_busy` 的口（口 0、1，按序）。
   - DCache 侧：`dcache_s1` 的 bank 授予顺序改成“本拍要发隐藏重试的口（`use_pend|use_new`）先拿 bank”，load 在前、store 在后，同组内按口号。不用看门狗。
7. **按口号压缩**：模型把到达的 load/STA 压缩到前面连续的槽（`nl/ns` 计数），重放填空槽。RTL 按同样的写法（前缀计数 + 选择），保证周期一致。

## 4. 端口变化

`spec/lsu.io` 新增输入：`dcache2lsu_load_retry_busy [LSU_LDU_COUNT]`、`dcache2lsu_store_retry_busy [LSU_STA_COUNT]`；`spec/dcache.io` 新增对应输出；
mem_top、core_top、back_top 连线同步。旧 LSU 路径（`LSU_PIPE=0`）不使用这两个输入。其余端口形状不变。

## 5. LSU 开关

`ttg_cfg_pkg::LSU_PIPE`（0/1）。`lsu.sv` 顶层 `generate if (LSU_PIPE)` 选 `lp_core`（新）或 `lsu_core`（旧，原样保留）。DCache 的两处改动同样由 `LSU_PIPE` 控制。

## 6. 为 RTL 对模型做的小改（只在 trace-model-lsupipe 工作区，未提交）

| # | 改动 | 原因 | 影响 |
| --- | --- | --- | --- |
| M4 | `comb_lsu2dcache_stq_p` 重写：①窗口内所有可发的 store 每拍倒数 `rwait`（原来只对扫描到的项倒数）；②MMIO store 与口数无关，只看队首和未缓存单元；③候选 = 最老的 `DRAIN_PORTS`(2) 个“就绪且非 MMIO”的 store，第 m 个候选用第 m 个没有隐藏重试的 store 口，若与更老的“已提交未完成”store 字节重叠则本拍作废，端口空闲（原来是继续往后找下一个，扫描随口数耗尽而停）；④删除不可达的 `suppress` 分支（提交时 `suppress` 一定同时置 `done`；模型里加了不可达检查） | 原写法是带 `break` 和运行计数的串行扫描，且重叠检查对窗口内每个候选都要查全部更老项（64×64）；新写法 = 两个固定候选 × 64 项 CAM | 个别程序周期不同于原模型（见第 7 节结果） |
| — | 内存序违例 CAM（`comb_tlb_in_stq_p` 里对 LDQ 的 64 项比较，置 `RDY`）**RTL 不实现**，模型保留。非投机策略下它从不触发（模型计数器 `order_violation` 在 gate 全程为 0，见第 7 节），所以不改变周期 | 检测用，非投机策略下是死逻辑 | 无 |
| — | 看门狗不实现；参考周期用 `LSU_PIPE_NOWD=1` 生成 | 30 个 SPEC 点上从未触发 | 无 |
| — | 模型 `dis2lsu` 里对 `stq_flag`/`count>=64` 的检查（分配被跳过）RTL 不实现：dispatch 以 `lsu2dis` 给出的 tail/free 分配，这两种情况不可达 | 不可达 | 无 |
| — | 调试用事件打印 `LSU_PIPE_EVT=1`（与 tb 的 `SOC_TB_LSUEVT` 同格式），不影响行为 | 对齐定位 | 无 |

## 7. 实现状态与验证结果（2026-11-06/07）

**实现**：`rtl/backend/lsu/` 新增 `lp_pkg lp_ldq_ent lp_ldq lp_stq_ent lp_stq lp_ptr lp_l1 lp_l1b lp_cam lp_l2 lp_wb lp_drain lp_rp lp_unc lp_pickn lp_core lsu_pipe`
（`lsu.sv` 顶层 `LSU_PIPE` 选择；`lsu_lrsc` 复用）。DCache：`dcache_s1` 的 bank 授予顺序（隐藏重试口优先，load 先于 store）和 `rty_valid_q` 输出，
经 `dcache → mem_top → soc_top → core_top → back_top → lsu` 连到 `dcache2lsu_load_retry_busy / store_retry_busy`（spec 同步）。
配置：`ttg_cfg_pkg::LSU_PIPE`（`gen_cfg_pkg.py -DLSU_PIPE=1` 生成，默认 0）。**本分支提交的配置包是 `LSU_PIPE = 1`、`MOVE_ELIM = 0`**：
参考模型 trace-model-lsupipe 分支早于 EXP-012（没有 move elimination），而 rtl main 默认 `MOVE_ELIM = 1`；两者不一致时周期对不上（用 `MOVE_ELIM = 1` 跑 66 个程序只有 56 个与参考相等，
改为 0 后见下）。要和 main 的 `ref_cycles.txt` 比较时请重新 `make cfg`。

**门禁**（`SOC_FM=1 ... tb/soc/build.sh` + `scripts/fm_gate.sh`，输出 `~/personal/AI-Huma-data/rtl-lsupipe/gate2/`）：**66/66 PASS**（逐条提交对 function-model 一致）。
串口输出对比（`~/personal/AI-Huma-data/rtl-lsupipe/serial_cmp.sh`，RTL 日志的每一行都必须出现在 trace-model 的输出里）：66 个程序无差异
（`supervisor-external-interrupt-vectored` 的一行是串口字符 `E` 紧接着 tb 的 `[FM]` 日志行，不是差异）。

**周期对齐**（参考 = trace-model-lsupipe + 第 6 节的 M4 改动，`LSU_PIPE=1 LSU_PIPE_NOWD=1`，`scripts/ref_cycles_lsupipe.txt`）：**65/66 逐个相等**。
不相等的一个：`memory-stress-small` RTL 345,078 对参考 345,079（RTL 少 1 拍；**后来查清是错误路径取指的数据不同，见第 11 节，已知不一致点 K-1**）。`first_diff.sh`：提交流在第 1,081,398 条（cycle 344,987，距程序结束 90 拍）第一次出现 1 拍差；
用两边的逐拍 LSU 边界事件打印（模型 `LSU_PIPE_EVT=1`，tb `SOC_TB_LSUEVT=1`，DEBUG 构建）对比，**到该拍为止 LSU 的所有输入（MMU / DCache 响应、fill、重试位、AGU / STD 到达、分发、flush / mispred / clear_mask）
和所有输出（写回 rob/preg/br_mask、STA 写回、DCache load/store 请求地址和 id、MMU 请求、`stq_free/ldq_free/tail`、`committed_store_pending`、LDQ 分配号）逐拍相同**（只有写回数据值在错误路径上不同，
模型用的是 oracle 值），第一处差异是 ROB 的提交拍（同一条 `add` 在 RTL 早 1 拍提交）。所以该差异不在 LSU 接口上；**后来在第 11 节查清：原因是错误路径取指读到的数据不同（模型读最新值，RTL 读 LLC/DDR 里的初始值），不是 ROB 也不是 LSU，登记为已知不一致点 K-1**。

前期定位记录（排除了 LSU 自身错误的两件事）：① 参考模型没有 move elimination（见上）；② 模型的 store 排空旧写法与 RTL 的两候选写法不同（M4），改模型后 dhrystone、dcache-conflict-writeback 等对齐。
这一轮 RTL 本身没有出现需要改 LSU 逻辑的偏差：第一次构建就 66/66 通过、54/66 周期相等，其余 11 个由上面两件事解释。

**lint**：`scripts/lint.sh rtl/backend/lsu` 干净（`LSU_PIPE=1`），`scripts/lint_chip.sh` 两种配置（`LSU_PIPE=1` / `0`）都是 0 条。全目录 `scripts/lint.sh` 干净（310 个文件、30 个目录）。
旧 LSU 路径：`LSU_PIPE=0` 能构建，`add`（1530）、`dhrystone`（162,033）逐条提交对 function-model 一致，周期与旧模型一致。

## 8. 综合（面积 = 通用门数代理，深度 = 门级拓扑最长路径；没有工艺库，没有 STA）

方法见 `scripts/synth_module.sh`（`SYNTH_LTP=1` 加 yosys `ltp -noff`，`SYNTH_DEPTH=1` 用 `strash;balance;dc2;balance;map`）和 `scripts/synth_depth.sh`。
**深度是通用门（AND/OR/XOR/MUX/NOT）的层数**，没有线延迟和扇出，不是 ns；只能用来比较。粗略换算：1 GHz 在先进工艺大约容许 40～60 层这类通用门。所有数字用同一个 ABC 脚本。

| 模块 | 单元数 | 最长路径（层） | 路径 |
| --- | --- | --- | --- |
| **新 LSU `lp_core`（整体展平）** | 1,254,460（平衡脚本）/ 903,376（轻量脚本，与 09 报告同口径） | **357** | `ccount_q → 提交口链(8 级) → ccount/count 的 flush、mispred 截断、退休 → alive_post → LDQ 唤醒时的 STLF 确认 → st9(RDY) → 重放寄存器的轮转 find-first → rp_ptr_d` |
| `lp_ptr`（STQ 指针） | 13,719 | 234 | `cm_valid → count_flushed → count_d → alive_post` |
| `lp_cam`（一个 load 口的部分地址 CAM） | 72,490 | 119 | `func3/地址 → 64 路 13 位范围比较 → 最年轻候选` |
| `lp_l1b`（4 个 CAM + 请求 + PL12） | 269,526 | 116 | `l1 槽 → CAM → cand` |
| `lp_drain`（排空） | 48,675 | 107 | `sq → 两候选 × 64 项重叠 CAM → 请求` |
| `lp_wb`（写回口分配） | 250,667 | 102 | `sq → 选口 → wb_result` |
| `lp_ldq_ent`（单个 LDQ 表项，含唤醒确认） | 6,507 | 87 | 事件 → 确认 → st9 |
| `lp_rp`（重放寄存器） | 4,299 | 85 | `rdy9 → 轮转 → first_set → rp_new` |
| `lp_l2` | 65,356 | 68 | L2 的 STLF 确认 |
| `lp_l1` / `lp_stq_ent` | 3,058 / 1,605 | 24 / 18 | |
| **旧 LSU**（`lsu_core` 整体综合超 12 GB 被杀，下面是逐子模块） | 合计约 330 万（轻量脚本，用 09 报告里的数字按实例数相加：stlf 1.09M、ring 0.18M×6、wb_ldq/stq 0.25/0.23M…） | — | — |
| 旧 `lsu_ring`（6 个环队列之一） | 201,595 | **427** | 环队列窗口扫描 / 空洞弹出前缀链 |
| 旧 `lsu_stlf`（STLF 窗口） | 1,267,167 | **403** | 20 个 load 的 `break` 链 × 64 个 store 的链 |
| 旧 `lsu_dc_req_ld` | 203,048 | 163 | wait_dcache 窗口 4 选 20 + 重放倒计时 |
| 旧 `lsu_stq_ptr` | 8,037 | 138 | |
| 旧 `lsu_dc_req_st` | 79,932 | 136 | 窗口内两两冲突检查 |
| 旧 `lsu_dc_resp_ld` / `lsu_wb_stq` / `lsu_wb_ldq` | 173,458 / 383,446 / 471,480 | 80 / 67 / 62 | |
| 旧 `lsu_tlb_sel` / `lsu_tlb_resp_ld` / `lsu_exe_in_ld` / `lsu_alloc` | 127,514 / 53,264 / 34,041 / 100,790 | 59 / 55 / 23 / 31 | |

旧 LSU 一拍内的依赖链（第 1.4 节）`exe_in_ld(23) → tlb_sel(59) → [MMU] → tlb_resp_ld(55) → stlf(403) → dc_req_ld(163)` 逐段相加约 **700 层**（不含窗口队列 427 层的 ring，
它们在 stlf 之前、之后各有串联）。新 LSU 整体展平最长 **357 层**，面积约为旧的 **27%**（903k 对约 330 万，同一轻量脚本）。

**结论（诚实版）**：
1. “新 LSU 比旧 LSU 小、快”成立：面积约 1/4～1/3，最长路径约一半（357 对 700+）。
2. “新 LSU 在 1 GHz 可实现”**不成立**：357 层远超 40～60 层的预算。逐阶段看，阶段**内部**的结构是对的（CAM 119、选口 100 左右、表项 87 都在同一量级但仍偏长），
   真正拖长的是**阶段之间的同拍串联**，即模型里的 `pnxt` 顺序改写。最长路径是一条把 5 个阶段串在一起的链：
   **ROB 提交口 → STQ 提交计数 → flush/mispred 截断 → 退休 → 窗口掩码 → LDQ 唤醒确认 → RDY → 重放寄存器选择**。
3. 建议的改法（每一条都改变模型的周期，需要先在模型里改、重跑门禁和 SPEC，再改 RTL；这里只给方案，没有实施）：
   - 提交口链（约 105 层）：ROB 按序提交，一组里的 store 的 `stq_idx` 是连续的，第 i 个被接受的条件可以并行写成 `idx_i == commit + (本组前面的 store 个数)`，用前缀计数代替“已被接受”的串联。语义不变（`wbd` 条件在 ROB 侧已保证）。
   - `alive_post`（230～242 层）：唤醒确认只需要“被等的 store 是否已退休或被截断”。退休已有 `ev_ret`；截断时等它的 load 一定更年轻、同拍被杀。可改成 `alive_q & ~ev_ret`，去掉 count 链。基本不影响周期。
   - mispredict 截断（首个命中项 first_set 加旋转）：改成每个 STQ 表项自己比较 `br_mask`，打一个 kill 位，count 下一拍再收敛（模型里改成同样的“延迟 1 拍收敛”）。
   - 重放寄存器同拍包含刚唤醒的项（约 100 层）：改成只从寄存器里的 RDY 位选，唤醒只置 RDY（慢 1 拍）。LSU_PIPE.md 第 4.2 节的消融：重放寄存器提前 1 拍填充对 dhrystone 值 1.6%。
   - CAM（119）、写回选口（102）、排空 CAM（107）本身仍然偏长：CAM 的 64 路比较可拆成“寄存器里预先算好的 12 位页内偏移比较”和“STA 旁路的 3 路比较”两部分；写回口分配可提前一拍（WBP 队列化）。
4. 这些改法是不是足够，需要再综合一次才知道；本次没有做。

## 9. 关键路径切断（2026-11-07，`lp_pkg::LP_CUT` 位掩码）

目标：阶段之间用寄存器隔开，量化每条的 IPC 代价。**深度仍是通用门层数（yosys `strash;balance;dc2;balance;map`，`scripts/synth_depth.sh`，`lp_core` 整体展平），不是 ns。
本机没有任何 liberty（`find / -name '*.lib*'` 只找到 Windows 导入库），无法标定层数→ps；“1 GHz 对应多少层”未经验证（第 8 节写的 40～60 层只是经验估计，没有验证）。**
基线 357 层复现（1,254,460 单元，路径同第 8 节）。模型侧见 trace-model-lsupipe `docs/LSU_PIPE.md` 第 6 节（`LSU_PIPE_CUT`，只有会改变周期的几条是模型开关）。
默认值现在是 `LP_CUT = 131071`（全部打开）；`LP_CUT = 0` 是第 7、8 节的原设计（lint 干净；**改完后没有重跑 LP_CUT=0 的门禁/周期，只做了 lint**）。

### 9.1 每个位做了什么

| 位 | 名 | 改法 | 周期影响 | 模型开关 |
| --- | --- | --- | --- | --- |
| 1 | B | LDQ 唤醒确认的 `alive_b` 用 `alive_w`（寄存器窗口）`& ~ev_ret`，不用 retire/截断之后的 `alive_post` | 无（实测 14 点 1.0000） | LSU_PIPE_CUT=1 |
| 2 | R | `lp_ptr` 退休只读寄存器：`ccount_q/count_q` 与各表项**寄存器里的** `done`（`done_q_vec`） | -0.4% | 2 |
| 4 | D | 重放寄存器只从寄存器里的 RDY 位选（`rdy9 = st_q==RDY && !kill`），本拍刚唤醒的项晚 1 拍 | -1.4% | 4 |
| 8 | F | 写回口的 WBP 选择只用寄存器里的 WBP 位（`wbp_r`），本拍新变 WBP 的晚 1 拍 | -0.4% | 8 |
| 16 | G | 排空看不到本拍的 MSHR-full 唤醒（`rw5g`）；唤醒写入 `rwait=0` 照旧，下一拍可排 | 0.0% | 16 |
| 32 | E1 | `rp_pipe` 读寄存器状态（`pipe_r`）而不是 `pipe5`（重放寄存器里的项一定是 PIPE，写回链是假路径） | 无（等价） | — |
| 64 | A | ROB 提交口并行：第 i 个 store 必须 `idx == commit_ptr + 本组前面 store 数`，且前面的 store 全被接受（`wbd` 前缀与）| 无（等价，门禁和周期验证） | — |
| 128 | E2 | `dead_r`（只用寄存器字段的 flush/mispred 杀位）代替 `empty8`/`kill`，用于 rdy9 和重放寄存器有效位 | 无（等价） | — |
| 256 | C1 | `committed`/`ccount_fl` 不再经过 mispred 截断：已提交 store 永远不会被 mispred 截断（模型里加了 abort 检查，从未触发） | 无（等价） | — |
| 512 | C2 | fill 唤醒的 `win4`、`fl_cand` 用寄存器的 `ccount_q/cmt/done`（本拍刚提交的 store 没有重放等待） | 无（等价） | — |
| 1024 | E3 | `mmw_ok` 用 `st3==MMW` 代替 `st5`（MMW 项不会在 P5/P6 被写回/重分配） | 无（等价） | — |
| 2048 | E4 | 唤醒条件 `rpw_a = st3==RPW && !dead_r` 代替 `st8==RPW`（st8 之后只剩 1 级选择） | 无（等价） | — |
| 4096 | E5 | srp 用的 `alive_post` = `alive_w & ~ev_ret & ~(mispred&hit_slot) & (flush ? 提交窗口 : 全 1)`，不经过 count 链 | 无（等价，假设 hit 集合向上封闭） | — |
| 8192 | H | 排空只看已在周期开始时提交的 store（`win13` 用 `ccount_q`，`cmt`/`done` 用寄存器） | -0.2% | 32（模型里是 32，RTL 位是 8192） |
| 16384 | E6 | 未缓存单元的 `ld_empty` 用 `dead_r` | 无（等价） | — |
| 32768 | E7 | `alive_fl` 同 E5，不经过 count 链 | 无（等价） | — |
| 65536 | E8 | `epoch_nx` / `l1` 的 `pipe8` 用 `!dead_r`（L1 槽指向的项一定是 PIPE，只有 flush 杀位能改变） | 无（等价） | — |

“等价”的意思是：假设了不变量（寄存器里的状态不会被中间阶段改写、已提交 store 不被截断……），不是形式化证明；证据是 66 个程序周期与模型逐个相等 + 14 点 SPEC 上模型 abort 检查不触发。

### 9.2 深度 vs IPC 取舍表（逐步累加，深度 = `lp_core` 整体最长路径层数）

| 已打开的位 | 最长路径（层） | 瓶颈（该步综合后的最长路径） | 累计 IPC（14 点，对 LP_CUT=0） |
| --- | --- | --- | --- |
| 无（基线） | 357 | ROB 提交口链 → count → 截断 → alive_post → 唤醒确认 → RDY → 重放选择 | 1.0000 |
| A | 353 | pl12 → L2 → st3 → 写回选口 → st5 → mi_pick → kill → st8 → st9 → 重放选择 | 1.0000 |
| A B | 351 | 同上 | 1.0000 |
| A B R | 350 | 同上 | 0.9959 |
| A B R D | 326 | L2 → 写回 → pipe5 → L1 槽数 → rp_cons → CAM → pl12 | 0.9828（B+R+D） |
| B R D F E1 | 339 | 提交口链回来（没有 A） | 0.9782（B+R+D+F） |
| B R D F E1 A | 273 | L2 → rs_ok → 写回口 → wb_go → st5 → mi_pick → kill → rdy9 → 重放旋转 | |
| + E2 | 269 | 提交口 → ccount → committed → win13 → d_blk → 排空候选 → 排空 CAM → 请求 | |
| + C1 | 265 | 提交口 → fl_cand → full_cand → rwait → d_rdy → 排空 | |
| + C2 | 237 | 同上（仍经 cm_go → done4） | |
| + G E3 E4（掩码到 bit11） | 187 | 提交口 → count_d（mispred 截断）→ alive_post → srp first-set | 0.9784（B+R+D+F+G） |
| + E5 | 169 | 提交口 → win13 → d_blk → 排空 → 排空 CAM → issue | |
| + H | 166 | L2 → 写回口 → wb_go → st8 → unc_busy → 未缓存单元 addr | 0.9787 |
| + E6 | 164 | 提交口 → ccount → alive_fl → unc_busy | |
| + E7 | 163 | L2 → 写回口 → wb_go → st8 → epoch_nx → pl12 req id | |
| **+ E8（全部，LP_CUT=131071）** | **156** | L2(68) → rs_ok → 写回口分配 → LR/SC 预约 `rsv`（wb 挑选 → 预约 alive/br_q） | **0.9787（-2.1%）** |

整体：357 → 156 层（-56%），面积 1.254M → 1.272M 单元（+1.4%，通用门代理），IPC（14 点）-2.1%。
IPC 代价全部来自四条：D（-1.4%）、R（-0.4%）、F（-0.4%）、H（-0.2%）（互相有重叠，合计 -2.1%）；其余 B、G 以及所有 RTL-only 的等价切断零代价。
D 是性价比最低的一条，但不做 D 则重放选择（rdy9 → 旋转 + first-set，约 90 层）总叠在 `st9` 之后，最长路径回到 230+ 层。

### 9.3 验证（LP_CUT = 131071，模型 `LSU_PIPE_CUT=63`）

* `fm_gate`：66/66 PASS（逐条提交对 function-model；`~/personal/AI-Huma-data/rtl-lsupipe/gate_cut/`，tb 在 `soc_cut/obj/soc_tb`）。
* 周期：与新参考 `scripts/ref_cycles_lsupipe_cut.txt`（模型 `build_cut`，`LSU_PIPE=1 LSU_PIPE_NOWD=1 LSU_PIPE_CUT=63`）**65/66 逐个相等**；
  唯一的差还是 `memory-stress-small`：RTL 344,807 对模型 344,808（RTL 少 1 拍），与第 7 节同一个程序同一方向（**根因已查清，见第 11 节：错误路径取指的数据不同，登记为已知不一致点 K-1，见 docs/06-equivalence-policy.md**）。
* `scripts/lint.sh rtl/backend/lsu`：LP_CUT=131071 和 0 都干净。全目录 lint、`lint_chip.sh` 在这些改动之后**没有重跑**。
* 没有做：1 拍差的定位（第 5 项，上下文用尽）；`LP_CUT=0` 的重新门禁；SPEC 30 点（只有 14 点）；综合只做了 `lp_core` 整体，各子模块单独的数字没有更新。

### 9.4 剩余最长路径与下一步（未做）

156 层的路径是 `pl12 → L2 决定 → rs_ok → wbd_v（直写回）→ 写回口分配（free/sc_acc/f2）→ ... → rsv.alive`；同一量级的还有
提交口 → win13 → 排空候选（first-set 62）→ 排空 CAM → issue（约 165 → 已被 H 去掉提交口部分，剩约 105 层排空本身）和 CAM（119，pl12 之前）。
这些是**阶段内部**的结构（L2 + 写回口分配 + 回写 LDQ，约 130 层），再切要付出 load-use 延迟（直写回过寄存器 = 所有 load +1 拍），没有量化；
独立的候选：写回口分配提前一拍（WBP 队列化）、CAM 拆成 12 位页内偏移预比较 + STA 旁路 3 路比较（寄存器隔开）、排空两个候选 × 64 项 CAM 拆两段。
结论：已不再被“阶段间同拍串联”主导（最长路径 156 层中有 130 层在 L2 → 写回口 → LDQ 状态这一条本来就是一个阶段链）。

## 10. L2 一拍内的切断（2026-11-07，`lp_pkg::LP_L2` 位掩码，默认 0）

起点：第 9 节之后最长路径 156 层，几乎全在 L2 一拍内：`pl12 → L2 决定（68）→ rs_ok → 直写回 → 写回口分配 → LR/SC 预约 / LDQ 状态`。
模型侧见 trace-model-lsupipe `docs/LSU_PIPE.md` 第 7 节（`LSU_PIPE_L2`，逐拍账、各开关 IPC）。
**层数仍是通用门层数（yosys + ABC `strash;balance;dc2;balance;map`，`SYNTH_LTP=1 SYNTH_DEPTH=1`，`lp_core` 整体展平），不是 ns；本机没有 liberty，
“1 GHz 对应多少层”没有标定，本节只做相对比较。** 综合在仓库副本上跑（`~/personal/AI-Huma-data/rtl-lsupipe/synth_l2.sh`，不碰工作区），每个点单次运行；ABC 的结果有 ±2 层的噪声
（同一份 `LP_L2=0` 现在 155 层、1,262,008 单元，第 9 节当时是 156 层、1,271,741 单元）。

### 10.1 每个位（RTL 位号；0..3、4..7 对应模型 `LSU_PIPE_L2` 同名位，8 以上是只改 RTL 的等价改法）

| 位 | 名 | 改法 | 周期影响 | 模型 `LSU_PIPE_L2` |
| --- | --- | --- | --- | --- |
| 0 (1) | a | **L3 寄存器**（`lp_l3`）：L2 的直写回结果（转发 / 缺页 / DCache 命中）进每口一个寄存器，LDQ 状态 `LS_WB3`；写回口分配、LDQ 释放、LR 预约放到下一拍，只读寄存器。load-to-use +1（5 拍） | -3.0% IPC | 1 |
| 1 (2) | a2 | （需要 a）消费者在 L3 写回请求的同一拍被唤醒（`lp_wake`，`lsu2iss_wake_*` 通道 `[NLD+p]`），不再等一拍后从 PRF 写回寄存器唤醒；非推测。load-to-use 回到 4 拍 | a + a2 = 1.0023（相对 a 单独 0.9699） | 2 |
| 3 (8) | d | **推测唤醒**：L2 拍里按 PL12 的命中预测（TLB 命中、非 MMIO、无 CAM 候选、无 dcblk、表项仍是 PIPE 且 epoch 相同）唤醒消费者（通道 `[p]`）；DCache 该拍没答 HIT 则登记 cancel（`cn_q`），下一拍选择之前 IQ 的等待位、dispatch 的 busy 表恢复（`isu_iq_store` `wait*_c`、`dispatch_busy_table`）。与 a 合用时消费者在 `t+2` 读操作数，load 结果还在 L3 寄存器：PRF 读口多一个旁路源（`prf` `lsu_byp_*`，来自 `lsu2exe_wb_req`）。load-to-use 3 拍 | +2.9% IPC | 8 |
| 4 (16) | F | 本拍刚拿到 MSHR_FULL 响应的 load 不被本拍的 fill 唤醒（等计数器）；只有周期开头已停车的 load 参加 MSHR-FULL 的“前 4 个”挑选。切掉 L2 决定 → 4 级 first-set → LDQ 状态 | F + M + S 合起来：a + a2 = 1.0023 → 1.0018，没有单独量 | 16 |
| 5 (32) | M | 本拍在 L2 变成 MMW 的 MMIO load 晚一拍上总线（`mmw_ok` 只看寄存器里的 MMW） | SPEC 无 MMIO；周期与模型一致 | 32 |
| 6 (64) | S | 每拍最多完成 1 个 SC（`lp_wb` 的 SC 挑选 K=1，原来 K=NLD 个串联 first-set） | 同上 | 64 |
| 8 (256) | W | 本拍在 L2 停车的 load 的唤醒（`lp_wk`）按 L1/L2 寄存器里的停车信息在**端口级**（4 个）算好，不再等 L2 决定之后在每个 LDQ 表项里算（`blk3 = park_a ? l2.blk : f_q.blk` 的选择在确认之前） | 无（等价） | — |
| 9 (512) | P | LSU 里的 find-first-set 改成对数深度的前缀 OR（`lp_ffs`，原 `req & -req` 进位链，ABC 保持约 N 层） | 无（等价） | — |
| 10 (1024) | T | STQ 的 mispredict 截断：先在全部位置上找第一个命中，再与 `count_flushed` 比较（不再把 count 放在 first-set 前面）。等价依据：活表项一定在 `count_al` 以内，活命中总在陈旧命中之前 | 无（等价，14 点 SPEC 上模型 abort 检查不触发，第 9 节同一假设） | — |
| 11 (2048) | R | 唤醒确认的范围比较改成“迟到的 store 地址只进比较器”（`rel12s/rel32s`，阈值由 load 一侧提前算好） | 无（等价）；**不进推荐组合**，见 10.3 | — |

模型里的 `Y`（128，推测唤醒不用于重放寄存器来的 load）是负结果，RTL 没有实现。

接口：LSU 新增输出 `lsu2iss_wake_valid/preg[2*NLD]`、`lsu2iss_cancel_valid/preg[NLD]`，经 `back_top` 接到 `isu`（`woken` 位图 OR 进去；`cancel_v` 位图）和 `dispatch`
（`NUM_WAKE` 加 `2*NLD` 个通道，busy 表的 cancel）；`prf` 新增输入 `lsu_byp_valid/dest_preg/result`（默认全 0，仅 `LP_L2` 同时含 d 和 a 时接 `lsu2exe_wb_req`）。
`MAX_WAKEUP_PORTS`（配置包）不变，`spec/{lsu,isu,dispatch,prf}.io` 同步（`prf.io` 里的旁路信号写 `@ 0`：模型没有数据通路）。
消费者被 a2 / d 早唤醒后，PRF 写回寄存器仍会对同一个 preg 再唤醒一次（模型里用 `Uop.early_woken` 去掉了），RTL 不去：第二次唤醒只作用在已经被唤醒的表项上，周期没有变化（两个组合的 66 个程序周期都逐个相等）。

### 10.2 层数 / 单元数的逐步变化（`lp_core` 整体，`LP_L2` 为十进制和）

| 已打开的位 | `LP_L2` | 最长路径（层） | 单元数 | 该步综合后的瓶颈 |
| --- | --- | --- | --- | --- |
| 无（第 9 节的设计） | 0 | 155 | 1,262,008 | `pl12 → L2 决定 → park → blk3 → 唤醒确认 → st9`（和第 9 节记录的 `… → rsv.alive` 156 层是同一量级的两条） |
| a | 1 | 157 | 1,272,262 | 同上：L2 停车决定后面紧跟每个表项里的唤醒确认（~70 层） |
| a W | 257 | 150 | 1,300,015 | AGU → L1 槽 → CAM → 最年轻候选（first-set 进位链 65 层）→ PL12 |
| a W P | 769 | 145 | 1,279,354 | 提交口 → `ccount` → mispredict 截断 → `count_d` |
| a W P T | 1793 | 142 | 1,278,757 | L2 决定 → `park_b` → MSHR-FULL 挑选（4 级串联）→ st9 |
| a W P T F | 1809 | 136 | 1,281,905 | L2 决定 → `st3` → `mmw_ok` → MMIO 挑选 → 未缓存单元地址 |
| a W P T F M | 1841 | 129 | 1,283,436 | SC 挑选（K=4）→ `sc_go` → STQ 视图 → `sta_info` → 确认 → st9 |
| a W P T F M S | 1905 | 122 | 1,289,772 | STA 翻译（MMU 结果）→ `sta_info` → STLF 确认（~44 层）→ st9 |
| **+ a2 = 推荐组合（非推测）** | **1907** | **124** | **1,298,404** | 同上 |
| **+ a2 + d = 推荐组合（推测）** | **1915** | **121** | **1,312,351** | 同上 |
| 1907 + R | 3955 | 122 | 1,327,222 | CAM：AGU → L1 槽 → 64 路比较 → 最年轻候选（确认那条已被切掉，但 CAM 同量级，单元 +2.2%，所以不用 R） |

子模块（`LP_L2=1907`，输入当作 0 层）：`lp_l1b`（4 个 CAM + 请求 + PL12）82、`lp_drain` 73、`lp_wb` 74、`lp_ldq` 77（其中端口级确认 54）。第 8/9 节时同一批：`lp_l1b` 116、`lp_drain` 107、`lp_wb` 102。
总体：357（第 8 节）→ 156（第 9 节）→ **124 / 121**；单元数相对 `LP_L2=0` +2.9% / +4.0%（W 一度 +28k，P 之后回收）。**cancel 位图进选择（`isu_iq_store` 的 `slot_ready`）和 PRF 的 LSU 旁路没有单独综合**（只综合了 `lp_core`），它们的代价没有量。

### 10.3 取舍表（IPC = 模型 14 点 SPEC，COV=0.12，对 `LSU_PIPE_L2=0` 的几何平均；层数 = 上表；该表的 IPC 列不含只改 RTL 的等价位）

| 组合 | RTL `LP_L2` | 模型 | 最长路径（层） | 单元数 | load-to-use（命中） | IPC 比 |
| --- | --- | --- | --- | --- | --- | --- |
| 第 9 节的设计 | 0 | 0 | 155（156） | 1,262,008 | 4 | 1.0000 |
| a（朴素 L3，慢唤醒） | 1 | 1 | 157 | 1,272,262 | **5** | **0.9699**（最差 0.9266） |
| **a + a2 + F M S（推荐，非推测）** | **1907** | **115** | **124** | **1,298,404** | **4** | **1.0018**（最差 0.9918） |
| **a + a2 + d + F M S（推荐，推测）** | **1915** | **123** | **121** | **1,312,351** | **3** | **1.0290**（最差 1.0022） |
| 上界：a + 推测唤醒，无需取消（oracle） | 不能实现 | 5 | — | — | 3 | 1.0242（模型里 d 的取消是理想的，所以 d = oracle） |
| 没有 L3 的推测唤醒 | — | 8 / 4 | — | — | 3 | 1.0295 / 1.0295 |
| d 只用于第一次进 L1 的 load（Y） | — | 137 | — | — | — | 1.0005（负结果：重放的 load 贡献了大部分收益） |

推荐：**非推测组合 `LP_L2 = 1907`**（a + a2 + F + M + S + W + P + T）作为切断 L2 的默认候选：层数 155 → 124（-20%），IPC 不变（+0.18%，14 点），load-to-use 仍是 4 拍，没有取消逻辑。
**推测组合 `LP_L2 = 1915`** 另有 +2.9% IPC、load-to-use 3 拍，但要付：8 个额外的 IQ 唤醒通道、取消位图进每个 IQ 的选择路径、dispatch 的 busy 表取消、PRF 读口的 LSU 旁路；
命中预测没有任何缓存状态信息，SPEC 14 点合计 **58% 的推测唤醒被取消**（模型里取消是理想的、免费的，所以 IPC 数是上界；dhrystone 11.6%、coremark 14%，访存密集的点高）；这些硬件代价没有量。

### 10.4 验证

`LP_L2 = 0`、`1907`、`1915` 各用仓库副本 Verilate 一份整核测试平台（`SOC_FM=1`，输出在 `~/personal/AI-Huma-data/rtl-lsupipe/soc_{v0,v2,v3}`，脚本 `build_variant.sh`），`fm_gate.sh`：

| 配置 | 逐条对 function-model | 周期对参考 | 参考文件（`scripts/`） |
| --- | --- | --- | --- |
| `LP_L2 = 0`（开关全关） | 66/66 PASS | 65/66 逐个相等，与 `ref_cycles_lsupipe_cut.txt` 对：只有 `memory-stress-small` RTL 344,807 对 344,808（与第 9 节同一个程序、同一方向；**根因已在第 11 节查清：测试环境取指一致性差异，已知不一致点 K-1**） | `ref_cycles_lsupipe_cut.txt` |
| `LP_L2 = 1907` | 66/66 PASS | **66/66 逐个相等**（含 `memory-stress-small` 345,364，上面那个 1 拍差在这个配置里不出现，原因不明） | `ref_cycles_lsupipe_l2_115.txt`（模型 `LSU_PIPE=1 LSU_PIPE_NOWD=1 LSU_PIPE_CUT=63 LSU_PIPE_L2=115`，`build_l2d`） |
| `LP_L2 = 1915` | 66/66 PASS | **66/66 逐个相等**（`memory-stress-small` 343,541） | `ref_cycles_lsupipe_l2_123.txt`（`LSU_PIPE_L2=123`） |

- 调试记录：第一版 `LP_L2=1915` 在 57/66 个程序上逐条对比失败（`x17 rtl=0 fm=1`）：推测唤醒的消费者在 `t+2` 读操作数，此时 load 结果还在 L3 寄存器、既不在 PRF 也不在写回寄存器——模型没有数据通路所以看不到。加了 PRF 读口的 LSU 旁路（`lsu_byp_*`）之后 66/66。
- `scripts/lint.sh`（315 个文件、30 个目录）和 `scripts/lint_chip.sh` 在 `LP_L2 = 0` 和 `1915` 下都是 0 条警告。`LP_L2` 其他取值（单独的 R、F、M、S 等）只 lint + 综合过，没有仿真。
- 全关（`LP_L2 = 0`）时 RTL 内部有重构（`lp_wk` 共用、`lp_rsv`、`lp_l3` 直通），周期与第 9 节一致（上表第一行）。
- 默认值：**工作区里 `LP_L2 = 0`**（开关默认关闭）；`LP_CUT = 131071`；配置包仍是 `LSU_PIPE = 1`、`MOVE_ELIM = 0`。

### 10.5 没做 / 没验证

- 层数→ns 没有标定（没有 liberty）；“1 GHz 对应多少层”未验证。综合是单次运行、通用门，没有线延迟和扇出。
- b（写回口分配提前一拍、WBP 队列化）没有单独做：加 L3 之后写回口分配的输入全是寄存器（`lp_wb` 单独 74 层），它里面真正长的是 SC 挑选，已由 S（K=1）解决。
- c（LR/SC 预约、LDQ 状态晚一拍收敛）没有做：LR 预约路径在 L3 之后不再是最长的；最长的剩余路径是“STA 翻译 → STQ 视图 → 唤醒确认 → LDQ 状态”（124 层）和 CAM（122 层），要同时切才有收益。
  切法有：把所有事件唤醒（ADDR / HOLD / DATA）晚一拍（事件寄存、确认读寄存的 `sta_info`），代价是这些 load 都慢一拍，**没有在模型里量**；CAM 的最年轻候选选择移到 L2（PL12 带 64 位命中向量），会让 L2 变长，**没有做**。
- DCache 响应判定（`l2_dec`，67 层）本身没有动；CAM 119 → 82（`lp_l1b`）只靠 P。
- 推测唤醒的取消位图进选择、dispatch 取消、PRF 旁路没有单独综合，没有时序数字。
- 没跑：30 点 SPEC、`run_gate.sh` 的 62 项周期比较、Linux 启动、`LP_L2` 其他组合的仿真。
- dhrystone 在 1907 上 182,763 → 167,681（-8%）、在 1915 上 176,946，而 coremark 在 1907 上 256,761 → 259,117：个别程序对时序很敏感（14 点 SPEC 上只有 +0.2%），原因没有分析。

## 11. `memory-stress-small` 差 1 拍的根因（2026-11-07）：不是 LSU，是程序末尾“错误路径取指”读到的数据不同

结论：**两边的逻辑都没错**。RTL 和模型在程序最后 `ret`（`80000300` 附近）之后的错误路径上取到**不同的指令字**，这些垃圾指令在整数发射队列里占发射口，
让一条真实指令（最后一个循环的尾部）在模型里晚 2 拍发射；这一拍的差把提交推迟 1 拍，之后一直保持 1 拍差到程序结束。
差异来自**测试平台的取指数据语义**，不是 LSU、不是发射队列选择、也不是 DCache：

- 程序 `memory-stress-small` 的数组 `a[]` 从 `0x800002f8` 起，紧接在代码后面（代码只有 760 字节）；最后一个 `ret` 被预测到 `0x80000300`，前端把 `a[2..]` 当指令取回来（错误路径，之后被冲刷）。
- **模型**：`ICacheTop.cpp` 的数据走 `tbhook::mem_read(paddr)`（`icache_coherent_read`）= 功能内存，**永远是最新值**（store 在派发时就已经由功能核执行）：取到的是 `a[]` 的**终值**
  （`80000300` = `a[2]` 终值 `fadc8f63`，`80000304` = `d29937e4`，……，与 Python 重放程序算出的终值一致）。
- **RTL**：ICache 从 LLC / DDR 取行，I 侧与 D 侧不相干，DDR 里是 `a[]` 的**初值**（`80000300` = `2e5aa51a`，`c8923b6b`，……，48 个字全部等于 `a[k] = (k*2654435761) ^ 0x12345678`）：这是硬件该有的行为，不是 bug。
- 两套垃圾指令的源寄存器号、类型（模型第 1 组里有一条分支 + 7 条 ALU，RTL 是 5 条 ALU）不同 → 派发组不同 → 整数 IQ 里的槽位和同拍可发射数不同（IQ 按槽位序选择，不是按年龄）。

### 11.1 定位过程（每一步的证据，文件在 `~/personal/AI-Huma-data/rtl-lsupipe/ms/`）

1. 复现：`soc_cut`（LP_CUT=131071, LP_L2=0）344,807；模型 `build_ms`（`LSU_PIPE=1 LSU_PIPE_NOWD=1 LSU_PIPE_CUT=63`，代码 = 工作区）344,808。`first_diff.py`：前 1,081,378 条提交逐拍相同，第 1,081,379 条（`80000218` 之后的 `8000021c`，模型周期 344,714）RTL 提早 1 拍（与同一个 `slli` 同拍提交，模型晚 1 拍）。
2. 发射事件（模型 `LSU_PIPE_TL=1` 新增 `DISP/FEIN/FEST` 行；tb `SOC_TB_ISS=1`，DEBUG 构建 `soc_ms`，打印 `[RISS]/[RDIS]/[RFE]/[RFS]`）：到周期 344,707 为止每拍的发射集合一模一样；
   344,708 起 RTL 比模型早 2 拍发射 rob35（循环里最后一批真实指令之一），模型那一拍 6 个 ALU 口全被 rob113..118 占用，RTL 是 rob112..116 + rob35。
3. 派发流：344,706 及以前每拍相同，**344,707 起不同**（模型 8 个 uop、RTL 5 个；同一个 rob 号上的指令不同）。
4. 取指流（`FEIN` vs `RFE`）：344,703 及以前相同（真实代码），`ret` 预测跳到 `80000300` 后两边取回的指令字不同；用 Python 重放程序证明模型取到 `a[]` 终值、RTL 取到初值。
5. 因果验证（临时实验，已撤销）：在模型 `diff/trace_hook.cpp::mem_read` 里让 `0x80000300..0x8000033f` 返回 `a[]` 的初值（RTL 看到的值）：**模型 344,808 → 344,807；整个提交流与 RTL 逐条逐拍完全相同**（`first_diff.py`：identical over 1,081,437 commits）。只改 16 个字就够，说明差异只来自这些垃圾指令。

### 11.2 为什么 `LP_L2 = 1907 / 1915` 66/66 全相等

两个配置下 load 时序不同，最后一批指令发射的相对时间也不同；用同一个“初值/终值”实验检查：模型在 `LSU_PIPE_L2=115`、`123` 上，垃圾指令字用终值或初值，`memory-stress-small` 周期都不变
（345,364、343,541，与参考相同）。也就是这两个配置下这个程序对垃圾指令内容**不敏感**；RTL 与模型本来就相等。（为什么在这两个时序下不敏感，没有再细查：IQ 里真实指令与垃圾指令的竞争没有发生，是 L2 时序的巧合，不是 L2 切断修了什么。）

### 11.3 哪边“对”，怎么处理

- 没有需要修的 RTL 逻辑，也没有需要修的 LSU 模型逻辑。RTL 的行为（I 侧读 DDR 里的旧值）是硬件真实行为；模型的取指是理想相干内存（对正确路径没有影响，因为正确路径上的指令不会被同时改写）。
- 只会影响“错误路径取到数据区”的程序，而且只在取到的指令字改变了垃圾指令流的发射竞争时才表现为周期差。66 个程序里只有这一个、只在 `LP_L2=0` 一个配置出现。
- 没有改模型：要让模型复现 RTL 的取指内容，需要模型里建模 I/D 不相干（LLC / DDR 的写回状态），代价和风险都大，而且只为错误路径；所以**接受 `memory-stress-small` 在 `LP_L2=0` 上 RTL 比参考快 1 拍**，把它记为已解释的例外
  （`ref_cycles_lsupipe_cut.txt` 里该程序仍是 344,808，不改）。要在比较脚本里逐个相等，只需把该程序的 `LP_L2=0` 期望周期当作 344,807。
- 提示：以后凡是“RTL 与模型差 1~2 拍、只在程序最后 100 拍内出现”的情况，先看错误路径取指的内容是不是数据区（`FEIN` / `RFE` 对比），再怀疑 LSU。

### 11.4 本节涉及的未提交改动与没验证的事

- 模型（`trace-model-lsupipe`，仅调试输出，`LSU_PIPE_TL` 关闭时无影响）：`back-end/Isu.cpp`（`DISP` 行）、`back-end/PreIduQueue.cpp`（`FEIN/FEST` 行）。RTL：`tb/soc/soc_tb.cpp` 里 `SOC_TB_ISS`（`#ifdef SOC_TB_DEBUG`，只在 DEBUG 构建里存在）。RTL 源码（`rtl/`）没有改动，所以门禁、lint、周期结果与第 9、10 节相同。
- 没验证：`LP_L2` 其他取值（如 1907、1915 以外）下这个程序是否也有同类 1 拍差；其他程序在别的配置下是否会出现同类（错误路径取数据区）差异；模型端用 `MS_STALE` 式覆盖在 SPEC 上的影响（没做，也没有必要）。
- 不能由本节推出：垃圾指令对 SPEC 点周期的影响量级。

## 12. 合并 main 之后（2026-11-07，分支 exp/lsu-pipe-rtl，合入 main 的第一阶段：分级流水 LSU，**不含推测唤醒**）

范围：`LSU_PIPE = 1`、`LP_CUT = 131071`、`LP_L2 = 1907`（a + a2 + F + M + S + W + P + T，模型 `LSU_PIPE_L2=115`，`LSU_PIPE_CUT=63`）；推测唤醒（d，`LP_L2 = 1915`）代码保留、默认关闭、不进 main 的默认。
合入 main 的内容：移动消除（默认开）、L1D 预取器（`dcache_pf`，pf-stress，`PF_EN` 参数）等。工作区先分 3 次提交（`2c04ec2` RTL、`58fdc8a` 参考周期脚本、`9c85615` 文档），再 `git merge main`（合并提交 `e06d10b`）。
本节对应的模型记录：trace-model-lsupipe `docs/LSU_PIPE.md` 第 9 节。

### 12.1 冲突和处理

* **文本冲突：没有**（git 自动合并成功）。**语义冲突两处**，都在合并后才暴露：
  1. main 给 `lsu` / `back_top` / `core_top` / `mem_top` 加了输出 `lsu2dcache_load_ports_replay`（预取器训练过滤：这次请求是不是“上一次响应不是 HIT 的重发”），旧 LSU 在 `lsu_dc_req_ld` 里用 `ld_fld.replay != 0` 驱动；
     `lsu_pipe` 没有驱动它（lint：`UNDRIVEN`）。处理：`lp_core` 新增输出 `dcl_req_replay[k] = dcl_req_valid[k] && ldq_q[l1[k].ldq].rtype != RT_HIT`（与模型 `ports[k].replay = e.rtype != HIT` 同义），经 `lsu_pipe` 接到 `lsu2dcache_load_ports_replay`。
     验证：PF 开、PF 关两个构建 67/67 周期逐个相等（replay 位错了会改变预取器训练、周期就对不上）。
  2. 配置包：分支里 `MOVE_ELIM = 0`（当时模型没有移动消除），改回 main 的 `1`；`gen_cfg_pkg.py` 的 `LSU_PIPE` 行原先默认 0、`-DLSU_PIPE=1` 才为 1，改为默认 1、`-DLSU_PIPE=0` 选旧 LSU，
     于是 `harness/tools/gen_cfg_pkg.py` 不带 `-D` 生成的文件与 `rtl/common/ttg_cfg_pkg.sv` **逐字节相同**（已核对，用合并后的 trace-model `config.h`）；与 main 的 `ttg_cfg_pkg.sv` 只差 `LSU_PIPE = 1` 这一行。`lp_pkg::LP_L2` 默认 0 → 1907。
* 风格检查（`lint.sh` 的 S3/S10：行宽 ≤120、文件 ≤400 行）：`mem_top.sv` 合并后 401 行（两个 `retry_busy` 输出合并成一行）、`lp_core.sv` 超行数（新增逻辑压缩），已处理。
* 参考周期文件：`scripts/ref_cycles.txt` 换成新默认配置（LSU_PIPE + 预取器开 + 移动消除开）的模型周期，原 main 的（旧 LSU）留作 `ref_cycles_legacy_lsu.txt`；
  `ref_cycles_nopf.txt` 换成预取器关的新周期，原来的留作 `ref_cycles_legacy_lsu_nopf.txt`。旧的 `ref_cycles_lsupipe*.txt`（移动消除关、无预取器的历史数据）不动。
  **注意：trace-model 的 `baseline.csv` 仍是旧 LSU（模型里分级 LSU 还是环境变量开关，默认关）；`ref_cycles.txt` 与它不再交叉相等，要等 trace-model 默认值那一步再统一。**

### 12.2 合并后发现并修掉的 Linux 启动死锁（模型 9.2，RTL 同步）

trace-model 跑 Linux 时分级 LSU 在 ROB 头死锁（共享 DTLB 页表遍历的“所有者”是一条较年轻的 store，STA 重发寄存器 `srp` 永远取最老的 `trp` store，页不同的老 store 每次都得到 RETRY，
所有者拿不到轮次）。修法：`lp_rp.sv` 的 `srp` 选取改为对 STQ 下标的轮转（`srp_ptr_q`，与装载重发的 `rp_ptr` 同样的做法；模型 `srp_ptr`），`lp_rp` 的 `head_d` 输入和 `lp_ptr` 的 `head_d_o` 输出不再需要，已删除。
**RTL 没有跑 Linux**（见 12.4），这个死锁在 RTL 上没有复现过，只是按模型的因果同步了改法；整核 67 个程序的周期不受影响（它们很少同时有两条以上的 `trp` store）。

### 12.3 验证（合并后的提交上；构建目录 `build/soc_mg2`（PF 开）和 `build/soc_mg_nopf2`（`SOC_VOPT="--threads 4 -DTTG_EBREAK_TRAP -GPF_EN=0"`），都是 `SOC_FM=1`，不覆盖已有的 `soc_*`）

| 检查 | 结果 |
| --- | --- |
| `scripts/lint.sh`（LSU_PIPE=1、LP_L2=1907） | 0 警告（316 个文件、30 个目录） |
| `scripts/lint_chip.sh` | 0 警告 |
| `fm_gate.sh`，预取器开（`ref_cycles.txt`，模型 `LSU_PIPE=1 CUT=63 L2=115 NOWD=1`，PF 开） | **67/67 PASS**，对 function-model 逐条一致；**周期与模型 67/67 逐个相等**（dhrystone 166,296、coremark 251,224、memory-stress-small 330,652、pf-stress 623,428） |
| `fm_gate.sh`，预取器关（`ref_cycles_nopf.txt`，`PF_ENABLE=0`，RTL `-GPF_EN=0`） | **67/67 PASS**，周期 67/67 逐个相等（dhrystone 167,681、coremark 254,460、memory-stress-small 345,364、pf-stress 610,886） |
| `memory-stress-small`（已知不一致点 K-1） | 两个配置下都不出现 1 拍差（与第 10.4 节 1907 下的结论一致；K-1 的原因仍是取指数据语义，没有改动） |
| 程序数 | 现在是 **67 个**（66 个 + pf-stress；任务书里的 66 是合并前的数） |

构建和 fm_gate 在本机用 `JOBS=2`（每个测试平台 4 个线程），整套约 40 秒（预取器开 / 关各一遍）。

### 12.4 没做 / 没验证

* **Linux 启动（RTL）没跑**：本机跑太久。命令（全程逐条对比，之前的记录是约 3.6 小时，分级 LSU 下没有量过）：
  `cd rtl-lsupipe && SOC_FM=1 SOC_OUT=$PWD/build/soc_mg2 SOC_VOPT="--threads 4 -DTTG_EBREAK_TRAP" bash tb/soc/build.sh`（已构建）后
  `SOC_TB_FM=1 SOC_TB_SEMIHOST=1 build/soc_mg2/obj/soc_tb ~/personal/AI-Huma-data/linux/linux.bin 400000000`，看到 `rv32 login:` 且没有 `[FM]` 不一致行后手动结束（参数以 `docs/modules/soc_top.md` 为准，这里没有试过）。
* 串口输出与上一版对比、综合对比（`synth_cfg.sh`，含 `lp_rp` 改动和预取器后的 `mem_top`/`dcache`）、30 点 SPEC、`LP_L2` 其他取值与预取器的组合、`LSU_PIPE=0`（旧 LSU）在合并后树上的整核回归（`-DLSU_PIPE=0` 配置包没有再生成和仿真，合并带来的 `lsu_dc_req_ld` 等改动在旧 LSU 路径上只靠 lint）。
* 推测唤醒（`LP_L2 = 1915`）在合并后树上没有重新验证。

## 13. 合入 main（分支 `lsu-pipe-rtl-main`，EXP-014，2026-11-07）

从当前 main（含 PMU，`5829f07`）切出，只含结论：`lp_*.sv`、`lsu_pipe.sv`、唤醒/IQ/Dispatch/Prf 钩子、配置包（`LSU_PIPE = 1`，`lp_pkg`: `LP_CUT = 131071`、`LP_L2 = 1907`）、`srp` 轮转、`lsu2dcache_load_ports_replay`。
不进 main（留在 `exp/lsu-pipe-rtl`）：`SOC_TB_ISS` 调试打印、`ref_cycles_lsupipe*.txt/.sh`（历史实验参考周期，M4/cut/L2 取值各一份）。推测唤醒（`LP_L2` 位 3，`lsu_byp`、`lsu2iss_cancel`）的硬件在代码里，默认关闭（`LP_L2 = 1907` 不含它），和唤醒通道纠缠在一起所以没有拆。
`ttg_cfg_pkg.sv`：`make cfg`（不带 `-D`，用 trace-model `lsu-pipe-main` 的 `config.h`）与提交的文件逐字节相同；与 main 只差 `LSU_PIPE = 1` 一行。`-DLSU_PIPE=0` 生成旧 LSU 的包。
参考周期：`ref_cycles.txt` / `ref_cycles_nopf.txt` 用 trace-model 默认值重新生成（默认带 watchdog，与关 watchdog 的周期 67/67 相同），与 `baseline.csv` / `baseline_nopf.csv` 的 63 个共有程序逐个相等。
验证（提交后的树）：`lint.sh` 0 警告（316 个文件）、`lint_chip.sh` 0；`fm_gate.sh` 预取开 67/67 PASS、周期 67/67 与参考相等；预取关（`-GPF_EN=0`）67/67 PASS、周期 67/67 相等；Linux 见下。
综合（`synth_depth.sh`，通用门数 / 最长路径层数，main → 合并后）：`dispatch` 72,586/46 → 82,244/44；`isu` 1,166,243/182 → 1,346,857/199；`prf` 297,853/36 → 310,639/35；`dcache_s1` 12,953/46 → 12,970/45；新增 `lp_core` 1,300,459/124、`lp_rp` 4,538/53。旧 `lsu` 整体综合超 12 GB 被杀（第 8 节同样），所以没有整体的旧/新对比。
K-1：合入的默认配置下 67/67 周期逐个相等，不出现（见 06-equivalence-policy.md）。
Linux 从复位启动（提交 `ec493f4` 的树，预取开，`SOC_FM=1`、`-DTTG_EBREAK_TRAP`，`SOC_TB_FM=1 SOC_TB_SEMIHOST=1`，400 M 周期上限）：约 47 分钟（本机，4 线程）到 `rv32 login:`，全程逐条对比 0 条 `[FM]` 不一致行（登录后手动结束，所以没有打印“N instructions checked”汇总）。模型同配置也到登录（110 M 周期之前）。日志 `~/personal/AI-Huma-data/linux/lsupipe_main/boot.log`。第 12.2 节的 `srp` 死锁修法因此在 RTL 上也通过了 Linux。

