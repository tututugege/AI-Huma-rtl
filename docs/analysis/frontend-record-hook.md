# 前端录制抓手（front tap）：设计、补丁、用法、验证

> 配套文件（均在 `docs/analysis/` 下）：
> - `frontend-record-hook.patch` — 给协调者合入的补丁（`git apply`，仓库根目录执行）
> - `examples/*.io` — 5 个可直接录制的 spec：`ptab.io`、`fetch_addr_fifo.io`、`inst_fifo.io`、`front2back_fifo.io`、`predecode_checker.io`；`examples/alu_bank.io`（Exu 的，**不需要补丁**，见 exu-boundary.md）
> - `examples/check_fifo_trace.py` — 不依赖 RTL 的 trace 自洽检查（Python FIFO 模型）
> - `tools/` — 验证/覆盖统计用的插件源码（`chk.cpp` 周期一致性、`cov.cpp` 前端覆盖+边界一致性检查、`exu_cov.cpp`…）
> - `data/` — 覆盖统计原始汇总

## 1. 要解决的问题

现有钩子 `ttg_rec::cycle(this, ctx.perf.cycle)` 放在 `back.comb()` 之后（`rv_simu_mmu_v2.cpp:1103` 之后），插件通过 `SimCpu&` 读取成员。
前端的求值发生在 `back.comb()` **之前**（`front_comb_before_back`，1080 行），而 `front_comb_calc` 里 icache 输出、BPU 输出、FIFO 读结果、checker 输入输出、各使能/旁路都是**局部变量**，函数返回即消失。

### 1.1 不加补丁已经能读到的（tier-0）

`FrontTop` 的成员 `read_data_`、`update_req_` 是 `private` 的 `unique_ptr`，但插件是用 `#define private public` 编译的，所以可以直接读：

| 表达式（spec 的 `@` 里，`cpu` 是 `SimCpu&`）| 内容 |
| --- | --- |
| `cpu.front.in.*` / `cpu.front.out.*` | `front_top_in/out`，每拍恰好一次 comb 之后的最终值（`front_comb_before_back` 里两个分支都会调用 `comb_bpu()`）|
| `cpu.front.read_data_->{fetch_addr_fifo_rd_snapshot,fifo_rd_snapshot,ptab_rd_snapshot,front2back_fifo_rd_snapshot}` | 4 个 FIFO 的**起拍**状态（`size/head_valid/head_entry`）|
| `cpu.front.read_data_->{*_full_latch_snapshot,*_empty_latch_snapshot,predecode_refetch_snapshot,predecode_refetch_address_snapshot}` | 起拍的 8 个 latch + `predecode_refetch` 寄存器 |
| `cpu.front.update_req_->{fetch_addr_fifo_req,fifo_req,ptab_req,front2back_fifo_req}` | 4 个 FIFO 本拍**最终**请求：`clear_*`、`push_en/push_data(entry)`、`pop_en`（`FrontUpdateRequest`，`train_IO.h:246-254`）|
| `cpu.front.update_req_->bpu_seq_txn.inp` | BPU 的 `InputPayload`（BPU 输入）|
| `cpu.front.update_req_->front_state.next_*` | 8 个 latch 次态、`next_predecode_refetch(_address)` |

这些**足够**录制四个 FIFO 的 push/pop/clear 与入队数据，但读不到出队数据（只有 `head_entry` 起拍快照，可以用，但 `rd_valid` 之类要自己推）、也读不到 icache/BPU 输出/checker/各使能。

### 1.2 补丁新增的（tap）

`front-end/front_tap.h`（新文件）+ `front_top.cpp` 里 8 处 `TTG_TAP(...)` 复制。tap 在**环境变量 `TTG_REC` 非空**时才工作（`g_ttg_front_tap_on`，静态初始化时读一次）；没有插件时每处只是一次被预测为假的 `if`。

## 2. 补丁内容

`frontend-record-hook.patch` 修改/新增 4 个文件（相对仓库根）：

| 文件 | 改动 |
| --- | --- |
| `refhook/front_tap.h`（新）| `struct FrontTap`（见 §3）、`extern bool g_ttg_front_tap_on; extern FrontTap g_ttg_front_tap;`、宏 `TTG_FT`（= `g_ttg_front_tap`，spec 里用）和 `TTG_TAP(...)` |
| `refhook/front_top_tap.patch`（新）| 对参考模型 `front-end/front_top.cpp` 的补丁（在 `refsim_setup.sh` 里自动应用）。改动只有：2 个 include/全局定义，1 个 BPU 输出拷贝 helper，8 个 `TTG_TAP(...)` 只读拷贝点 |
| `scripts/refsim_setup.sh` | 拷贝 `front_tap.h` 到 `refsim/front-end/`，若 `front_top.cpp` 尚未含 `front_tap.h` 则 `patch -p1`；之后照常 `gmake`（只重编 `front_top.cpp` 及依赖者）|
| `harness/tools/iogen.py` | 生成的插件在 `#include "SimCpu.h"` 之后加 `#if __has_include("front_tap.h") #include "front_tap.h" #endif`（没有 tap 的 refsim 不受影响）|

`front_top.cpp` 里 8 个拷贝点（原版行号）：

| # | 位置 | 拷贝内容 |
| --- | --- | --- |
| 1 | 序言（`front_state_req.valid=false` 之后，~1054 行）| `g_ttg_front_tap = FrontTap{}`（清零，防止上拍残留），`count++` |
| 2 | `icache_comb_calc(&icache_in,&icache_out)` 之后（1504）| `icache_in`、`icache_out`（**主调用**的值；predecode 冲刷拍里第二次 invalidate 调用会覆盖局部 `icache_out`，所以要在这里拷）|
| 3 | `can_bypass_fetch_to_icache` 计算之后（~1421）| `normal_write_enable` |
| 4 | `can_bypass_icache_to_predecode` 计算之后（~1563）| 该标志 |
| 5 | `front_checker_input_comb` 之后（~1747）| `checker_in` |
| 6 | `predecode_checker_comb` 之后（1752）| `checker_out` |
| 7 | F2B 块末尾（~1838）| `ptab_can_write`、`front2back_can_write`、`can_bypass_front2back_to_output`、`do_predecode_flush`、`predecode_flush_address` |
| 8 | 函数末尾 `req.out_regs = out` 之后（~2010）| 其余全部（全局控制、读使能、FIFO 读出的 `saved_*`、BPU 输出、旁路标志、4 份累加请求、起拍 FIFO 状态与 latch、next latch）|

**只读**：所有拷贝点都是 `g_tap.x = local_x`；没有任何值从 tap 回流到模型。

## 3. `FrontTap` 字段（一拍里前端的完整"边界视图"）

| 字段 | 含义 | 对应 `front_comb_calc` 步骤（见 frontend-boundary.md §3.2）|
| --- | --- | --- |
| `count` | 本次进程里 `front_comb_calc` 的调用序号（含 init 里的复位调用，故 = 钩子拍数+1）| — |
| `global_reset/global_refetch/refetch_address` | 全局控制 | S1 |
| `icache_ready` | `icache_peek_ready()` 的输出 | S2 |
| `fetch_addr_fifo_read_enable_slot0/inst_fifo_read_enable/ptab_read_enable/front2back_read_enable` | 4 个读使能 | S2 |
| `fa_out0` | fetch_addr FIFO 读结果（`read_valid`、`fetch_address`、`full/empty`=读后值）| S3 |
| `bpu_stall/bpu_can_run`、`bpu_out`（`FrontTapBpuOut`，`BPU_TOP::OutputPayload` 的扁平拷贝）| BPU 控制与输出 | S4 |
| `normal_write_enable/can_bypass_fetch_to_icache`、`fa_out_final` | fetch_addr 写侧 | S5 |
| `icache_in/icache_out`、`icache_slot0_data_valid` | icache 主调用 | S6/S7 |
| `can_bypass_icache_to_predecode/use_icache_to_predecode_bypass/predecode_source_valid/predecode_can_run` | predecode 级 | S8 |
| `saved_fifo_out/saved_ptab_out` | 送给 checker 与 f2b 写的 inst FIFO / PTAB **队首**（读结果）| S3/S8 |
| `ptab_can_write`、`checker_in/checker_out`、`do_predecode_flush/predecode_flush_address` | PTAB 写、checker、冲刷 | S9/S10/S12 |
| `front2back_can_write/can_bypass_front2back_to_output/use_front2back_output_bypass`、`saved_front2back_fifo_out`、`bypass_front2back_fifo_out` | f2b 写与输出旁路 | S11/S14 |
| `fetch_addr_req/inst_req/ptab_req/front2back_req` | 4 个 FIFO 本拍最终 `clear/push/pop` 请求与入队条目 | 累加后 |
| `fa_rd/inst_rd/ptab_rd/f2b_rd`、`predecode_refetch_q/_address_q`、`full_q[4]/empty_q[4]`、`next_full[4]/next_empty[4]` | 起拍 FIFO 状态、锁存与次态（下标：0 fetch_addr、1 instruction、2 PTAB、3 front2back）| S0/S13 |

使用注意：
- `saved_*_out`、`fa_out0` 等在**该拍没有读**时为全 0（tap 每拍清零）；spec 里要配 `when rd_valid`。
- `checker_in/out` 仅 `predecode_can_run` 为 1 的拍非零；全 0 输入对应全 0 输出（纯函数自洽），所以 `predecode_checker.io` 不用 `when`。
- `ptab_req.push_write_entry` 是**屏蔽（`& mask`）之后**写入队列的条目；若 PTAB 模块输入是屏蔽前的值，需验证屏蔽为空操作——当前位宽 `pcpn=3`、`tage_idx=10`、`tage_tag=8` 与 BPU 输出类型位宽一致，实测录制/回放自洽。
- `icache_in.csr_status` 是指针，不要写进 spec。
- tap 里的 `bpu_out.*` 是 BPU 输出；BPU 输入请直接读 `cpu.front.update_req_->bpu_seq_txn.inp`（见 §1.1）。

## 4. 使用说明

```bash
# 0. 在仓库根目录合入补丁
git apply docs/analysis/frontend-record-hook.patch        # 新增 refhook/front_tap.h、refhook/front_top_tap.patch，修改 scripts/refsim_setup.sh、harness/tools/iogen.py
# 1. 重新生成 refsim（会自动拷 front_tap.h 并给 front_top.cpp 打补丁，只重编相关文件，~几秒）
bash scripts/refsim_setup.sh                              # 输出里应有 "front tap inserted"
# 2. 把 spec 拷到 spec/ 下（module 名必须与 RTL 模块一致），然后照常录制
cp docs/analysis/examples/ptab.io spec/
CYCLES=30000 bash scripts/record.sh ptab /tmp/big/dhrystone.bin       # → traces/ptab/dhrystone.trc
# 3. 无 RTL 时的自洽检查
python3 docs/analysis/examples/check_fifo_trace.py spec/ptab.io traces/ptab/dhrystone.trc --cap 16 --full-at 15
```

写新 spec 时，表达式里直接用 `TTG_FT.<字段>`（如 `@ TTG_FT.ptab_req.push_write_entry.sc_idx[i0][i1]`），`cpu`/`bt`/`i0..` 照旧可用。
本补丁**不改变** `ttg_rec_hook.h`、`record.sh`、`replay`、trace 格式。

### 4.1 FIFO spec 的命名约定

`ptab.io` 等 4 个 FIFO spec 使用同一命名：输入 `reset refetch rd_en wr_en wr_*`，输出 `rd_valid rd_*(when rd_valid) full empty`；所以 `check_fifo_trace.py` 通用。它实现的就是 frontend-boundary.md §3.1 的单步语义：

```
clear = reset | refetch ;  rd_valid = rd_en & ~clear & (size>0) ; rdata = head(起拍)
下一状态: clear → push(wr_en) → pop(rd_valid) ;  full/empty = 起拍 size 的函数（full 阈值按 FIFO 给 --full-at）
```

| spec | 深度 | `--cap/--full-at` | 条目位宽（spec 字段合计）| 单拍记录大小 |
| --- | --- | --- | --- | --- |
| `fetch_addr_fifo.io` | 16 | 16 / 15 | 32 | 24 B |
| `inst_fifo.io` | 16 | 16 / 16 | 576（不含 debug pc；含 pc 为 832）| 200 B |
| `ptab.io` | 16 | 16 / 15 | 2376（+2 个恒 0 的 `need_mini_flush/dummy_entry` 不进 spec）| 776 B |
| `front2back_fifo.io` | 32 | 32 / 32 | ~2650（含 `predict_next_fetch_address_corrected`）| ~870 B |
| `predecode_checker.io` | 纯组合 | — | 输入 ~330 / 输出 ~41 位 | 78 B |

注意单拍 PTAB 776 B：10 万拍 ≈ 78 MB，f2b 约 90 MB。`record_all.sh` 默认 3 万拍/程序（gate 测试）较合适；dhrystone/coremark 请用 `CYCLES=30000`。

## 5. 验证（是否改变了模型行为？）

### 5.1 周期数与提交数完全一致

| 配置 | smc-div（跑完）| dhrystone（跑完，3.9M 拍）|
| --- | --- | --- |
| 原版 refsim（`/Users/ruyaoh/personal/tututugege-rtl/refsim`，无插件）| 8996 拍 / 1471 提交 | 3,911,612 拍 / 3,305,227 提交 |
| 打补丁版，**无插件**（tap 关闭）| 8996 / 1471 | 3,911,612 / 3,305,227 |
| 打补丁版，**带插件**（tap 开启，每拍拷贝，`tools/chk.cpp`）| 8996 / 1471 | 3,911,612 / 3,305,227 |

### 5.2 逐拍 `front.out` 哈希一致（原版 vs 打补丁+tap 开启）

`tools/chk.cpp` 每拍把 `cycle`、`front.out`（`FIFO_valid/commit_stall/predict_next_fetch_address` 及 16 lane 的 `pc/instructions/inst_valid/predict_dir`）和累计提交数做 FNV 哈希，对同一程序同样的拍数在两个模拟器上各跑一次：

| 程序 | 拍数 | 原版哈希 | 打补丁版哈希 | 结论 |
| --- | --- | --- | --- | --- |
| smc-div | 8996（跑完）| `4122dbd3cecb5f3d` | `4122dbd3cecb5f3d` | 一致 |
| dhrystone | 前 200000 | `9b0365a27e44ec44` | `9b0365a27e44ec44` | 一致 |
| coremark | 前 200000 | `627eea771b27ef2a` | `627eea771b27ef2a` | 一致 |

复现：`tools/verify.sh <prog.bin> 200000`（需 `REFSIM/ORIGSIM/PLUGDIR`，见脚本头注释）。

另外：用**补丁文件**重新生成的 refsim（`git apply` + `refsim_setup.sh`，在临时目录里验证）与手工修改的版本**源码逐字相同**，并用它完成了 PTAB spec 的录制与检查（§5.3）。

### 5.3 spec → 录制 → 自洽检查

对 4 个 FIFO spec 用补丁后的 refsim 录制，再用 `check_fifo_trace.py`（独立的 Python FIFO，只吃 trace 里的输入，核对输出/full/empty）：

| 程序（拍数）| fetch_addr | instruction | PTAB | front2back | 说明 |
| --- | --- | --- | --- | --- |
| smc-div（8996）| PASS（4190 入/2625 出，max 14）| PASS（2616/2319，max 1）| PASS（4190/2319，**max 15，4501 拍 full**）| PASS（0/0：该程序 f2b 全走输出旁路）| 无不一致 |
| dhrystone（30000）| PASS（14250/13527）| PASS（13467/11315）| PASS（200000 拍：84608/69000，max 15，11.5 万拍 full）| PASS（7410/5141，**max 32，17008 拍 full**）| 无不一致 |

PTAB trace 的检查对故意损坏的 trace（改 1 位 `rd_pcpn`）能报 `MISMATCH rec=3005 ... rd_pcpn differs`，说明检查是有效的。
`predecode_checker.io`、`alu_bank.io`（后者另用 `check_alu_trace.py` 对 9008 个 ALU 运算核对，0 不一致）也已录制成功。

### 5.4 边界一致性（tap 之外的额外验证）

`tools/cov.cpp` 在 73 个程序 ×≤10 万拍（126.5 万拍）里，对 4 个 FIFO 分别用**提议的模块边界信号**驱动一个标准 FIFO 模型，核对读有效/队首标签/次态 full/empty/`pop_en`，另检查 9 条结构不变量与"latch == f(size)"，**全部 0 不一致**（详见 frontend-boundary.md §8）。

## 6. 已知局限 / 待办

1. **icache 存储侧端口**（`ReadMasterPort_t`、DCache 探针口、PTW/ITLB 口）未抓：它们在 icache 求值那一刻的值与 hook 时刻不同（`axi_subsystem_comb_outputs` 在前端之后才更新）。要做 icache 模块的 spec，需要在 `icache_comb_calc`（icache.cpp:314 之前）再加一个 tap（建议同样 `TTG_TAP` 形式，拷贝 `icache_hw.io.in/out/regs` 以及 `ExternalReadPortAdapter::comb_view()`）。
2. `predecode` 的逐 lane 结果只能从 `saved_fifo_out.predecode_*`（FIFO 队首）和 `inst_req.push_entry.predecode_*`（写入时）读到；若要给 `predecode` 做 spec，输入 = `icache_out.fetch_group/fetch_pc/inst_valid`（tap 已有 `icache_out`），输出 = `inst_req.push_entry.predecode_type/target`（有 `inst_valid` 时）。
3. tap 每拍清零并整体拷贝（~15 KB/拍）。录制 10 万拍额外开销可忽略；若将来要在很长的运行里开 tap，可只拷需要的字段（**未测量性能**）。
4. `g_ttg_front_tap_on` 在静态初始化时读 `TTG_REC`，若插件在第一个钩子拍才被 `dlopen`（`ttg_rec_hook.h` 的现有做法），**`TTG_REC` 必须在进程启动前设置**（`record.sh` 已是这样）；`init()` 里的复位调用因此也会被拷到 tap（`count=1`）。
5. 前端的 `in.reset` 在录制窗口里恒为 0（复位只在 `FrontTop::init()`）；tap/spec 里的 `reset` 输入因此恒 0，复位路径靠 harness 的 3 个复位拍 + 随机/定向测试覆盖。
