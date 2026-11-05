# ICache 录制点（第二个 tap：`TTG_IC`）：设计、补丁、用法、验证

配套：`icache-record-hook.patch`（对共享 `refsim_tap` 的 `diff -u`，`front-end/` 下 5 个文件）、`tools/icov.cpp`（覆盖插件）、`data/icache_coverage_68prog_200kcyc.txt`。
背景见 `icache-boundary.md` §6。

## 1. 它读什么

`icache_comb_calc`（`front-end/icache/icache.cpp`）每个周期被调用 1 次，谓词预译码冲刷拍 2 次，每次调用都推进 ICache 状态。tap 在调用内部拷贝：

| 字段（`TTG_IC.*`）| 来源与时刻 |
| --- | --- |
| `in_refetch/in_itlb_flush/in_fence_i/in_req_valid/in_fetch_address/csr_*` | 第一次调用（`calls==1`）的 `icache_in` |
| `mem_req_ready/accepted/accepted_id/resp_valid/resp_id/resp_data[16]` | 第一次调用里 `ExternalReadPortAdapter::comb_view()`，ITLB 动作之前 |
| `dc_resp_valid/retry/miss/data` | 同上，DCache 探针响应视图 |
| `ptw_req_ready/resp_*` | 第一次调用里 ITLB 动作**之前**从 `PtwWalkPort::comb_output()` 拷出（flush 同拍时 ITLB 会改适配器）|
| `ptw_req_valid/req_vaddr/req_satp/resp_consumed/flush` | 第一次调用里 ITLB 动作之后，从适配器 `comb_in_/seq_in_`（镜像结构体）拷出 |
| `itlb_translate_invoked/itlb_result` | 第一次调用的 `comb_mmu_view` 结果 |
| `mem_req_valid/addr/total_size/bypass/id`、`mem_resp_ready`、`dc_req_valid/addr` | 每次调用的 `comb_accept`/`drive_dcache_probe_req_port` 之前，**后一次覆盖前一次**：最终值 = 最后一次调用（冲刷拍是第二步）|
| `calls`、`step[0..1]`（`FrontIcStep`）| 每次调用一份：`regs_before/regs_next`、模块输入输出、内核折叠后的 meta、表读/写口 |
| `regs_end` | 最后一次 `seq()` 之后的 FSM 寄存器 |

`TTG_FT.icache_ready`（peek）与 `TTG_FT.icache_out`（主调用结果）、`TTG_FT.do_predecode_flush` 仍由第一个 tap 提供。`icache_comb_calc` 以外**没有**新增副作用；只在 `TTG_REC` 设置时（`g_ttg_front_tap_on`）拷贝。

## 2. 使用

```bash
# 共享 refsim_tap 由协调者合入；自己试验：复制一份，在副本根目录打补丁并增量重建
rsync -a $RTL_ROOT/refsim_tap/ <dir>/refsim_ic/
cd <dir>/refsim_ic && patch -p1 < <repo>/docs/analysis/icache-record-hook.patch
gmake LDFLAGS="-lz" -j8                               # 只重编相关文件（含 front_top.cpp 等，约 1 分钟）
REFSIM=<dir>/refsim_ic bash scripts/lockstep.sh icache <prog.bin> [拍数]
```
spec 里直接写 `TTG_IC.xxx`（`front_tap.h` 已声明，`iogen` 的生成文件在 `front_tap.h` 存在时自动包含）。

## 3. 验证：加 tap 前后周期数不变

| 程序 | 原版 refsim_tap（无插件）| 打补丁版 + tap 开启（`tools/chk.cpp -DUSE_TAP`）| `front.out` 逐拍哈希 |
| --- | --- | --- | --- |
| smc-div（跑完）| 8996 拍 / 1471 提交 | 8996 拍 | `4122dbd3cecb5f3d` 两边一致 |
| dhrystone（跑完）| 3,911,612 拍 | 3,911,612 拍 | `26b33f00552d6bd3` 两边一致 |

复现：`REFSIM=<副本> ORIGSIM=<refsim_tap> PLUGDIR=<含 chk_orig.dylib chk_tap.dylib> bash docs/analysis/tools/verify.sh <prog.bin> <N>`（`build_plugin.sh` 见 `frontend-record-hook.md`）。
补丁自身用 `patch -p1 --dry-run` 对 `refsim_tap` 校验可无冲突应用。
