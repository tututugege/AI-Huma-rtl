# 访存子系统录制点（第三个 tap：`TTG_MS`，DCache 域每 tick）：设计、补丁、用法、验证

配套：`memsys-record-hook.patch`（对 `refsim_tap` 的 `diff -u`：`MemSubSystem/MemSubsystem.cpp`、`rv_simu_mmu_v2.cpp`、新文件 `MemSubSystem/include/memsys_tap.h`）。背景见 `memsys-boundary.md` §8。
补丁以 `refsim_tap` 为基（其 `rv_simu_mmu_v2.cpp` 首行已有 `#include "ttg_rec_hook.h"`，补丁在其后加一行），不能直接打到裸 baseline。

## 1. 它读什么
一个 CPU 周期 = 16 tick（tick 0 = `cycle()`；tick 1..15 = `run_extra_axi_subsystem_ticks`）。`MemTap.t[tick]`：

| 字段 | 含义 | 采集点 |
| --- | --- | --- |
| `req` | 本 tick 实际送入 DCache 的 `LsuDcacheIO`（路由后；tick 1..15 为空）| `dcache_domain_comb_inputs` 末尾（tick 0 的真实请求在 `comb_request` 之后才有）|
| `mshr_in`、`wb_in` | MSHR/WB 的 AXI 输入 | `dcache_domain_comb_outputs` 入口 |
| `mshr_out`、`wb_out` | MSHR/WB 的 AXI 输出（`comb_inputs_axi` 的 accepted 消去之后）| `dcache_domain_comb_inputs` 末尾 |
| `resp_pub`（仅 `t[0]`）| `dcache_resp_route_`：本 CPU 周期发布给路由块/LSU 的响应 | `comb_outputs` 里 `publish_pending_dcache_response` 之后 |
| `valid/slow` | 槽是否被填充、是否 tick 0 | |

`cycle()` 开头 `cur=0`，extra tick 循环里 `cur=tick`；`cycle()` 末尾（`run_extra_axi_subsystem_ticks` 之后）调用 `TTG_REC_END` 指定插件的 `ttg_rec_cycle_end(SimCpu*, cycle)`，插件一次看到 16 个 tick。`TTG_REC_END` 未设置时 `on=false`，各采集点只是一个 bool 判断。spec 表达式：`TTG_MS.t[TTG_MS.cur].<field>`。

## 2. 使用
```bash
rsync -a $RTL_ROOT/refsim_tap/ <dir>/refsim_ms/
cd <dir>/refsim_ms && patch -p1 < <repo>/docs/analysis/memsys-record-hook.patch
gmake LDFLAGS="-lz" -j6            # 约 1-2 分钟
TTG_REC_END=<plugin.dylib> ./build/simulator <prog.bin>
```
插件编译需要 `-I MemSubSystem/include` 等（同 `scripts/lockstep.sh` 的 INC 列表）。

## 3. 验证：加 tap 前后行为不变
`refsim_tap`（原版）vs 打补丁并设置 `TTG_REC_END`（统计插件，每 tick 读取全部字段）：stdout 逐字节相同（含周期数、IPC、全部统计）。

| 程序 | 周期 | IPC | 结果 |
| --- | --- | --- | --- |
| dcache-mshr-pressure | 193 | 0.471503 | 一致 |
| dcache-conflict-writeback | 896 | 2.126116 | 一致（WB 请求 512 tick、写响应 256）|
| memory-stress | 1,541,195 | 4.837140 | 一致（MSHR 请求 233,178 tick、fill 223,534）|

另外 `patch -p1 --dry-run` 对 `refsim_tap` 无冲突。采集点只做拷贝，不回写任何状态。
