# AXI 互连 + LLC 录制点（第四个 tap：`TTG_AXI`，每 tick）：设计、补丁、用法、验证

配套：`axi-record-hook.patch`（对**已打 `memsys-record-hook.patch` 的** `refsim_tap` 的 `diff -u`：`axi-interconnect-kit/axi_interconnect/AXI_Interconnect.cpp`、`rv_simu_mmu_v2.cpp`、新文件 `axi_interconnect/include/axi_tap.h`）。设计背景见 `docs/modules/axi_interconnect.md`。

## 1. 它读什么（`TTG_AXI.t[tick]`，tick = `TTG_MS.cur`）
| 字段 | 采集点 | 含义 |
| --- | --- | --- |
| `a_rd/a_wr`、`d_ddr/d_mmio` | `comb_outputs` 入口 | 主口请求的"陈旧"值（C++ 在 comb_outputs 时读到的）；sim_ddr/MMIO 从口信号 |
| `o1_*` | `comb_outputs` 末尾 | 读响应 valid/id/data、`req.accepted(+id)`、写响应、DDR `rready/bready` |
| `b_*` | `comb_inputs` 入口 | 真实每 tick 主口请求（含写数据/strb）与 `resp.ready` |
| `o2_*` | `comb_inputs` 末尾 | `req.ready`、DDR AR/AW/W 通道 |
| `llc_in2/llc_out2/llc_regs` | `comb_inputs` 末尾 | LLC 最终一次 comb 的 `ext_in/ext_out` 与互连直接读的 LLC 寄存器（hazard/id 冲突用）|
| `llc_ext_out1` | 第一次 `llc.comb()` 之后 | 用于核实"两次 comb 的 ext_out 是否相同" |
| `dbg_*` | `comb_inputs` 末尾 | 覆盖诊断：三类 hazard 阻塞是否发生（非 RTL 边界）|

另有可选的每 tick 回调：插件导出 `ttg_axi_tick(SimCpu*, int tick)`，在每个 tick 的 `axi_subsystem_seq` 之后被调用（统计插件用）。`TTG_REC_END` 未设置时所有采集点只是一个 bool 判断；**补丁在第 1 个 CPU 周期之前就打开 tap**（`ttg_ms_end::arm()`；memsys 补丁的 tap 是在第 1 个周期末才打开，CPU 周期 1 没有录到）。

缩小 LLC 的测试旋钮（环境变量，未设置时行为不变）：`TTG_LLC_KB`（总大小 KB）、`TTG_LLC_WAYS`；RTL 侧用宏 `AXI_LLC_SETS/AXI_LLC_WAYS`（`sets = KB*1024/(64*ways)`）。

## 2. 使用
```bash
rsync -a /Users/ruyaoh/personal/AI-Huma/rtl/refsim_tap/ <dir>/refsim_axi/
cd <dir>/refsim_axi && patch -p1 < <repo>/docs/analysis/memsys-record-hook.patch && patch -p1 < <repo>/docs/analysis/axi-record-hook.patch
gmake LDFLAGS="-lz" -j6
REFSIM=<dir>/refsim_axi bash scripts/lockstep_ticks_axi.sh <axi_llc|axi_interconnect|axi_subsys> <prog.bin> [cpu_cycles]
```
统计/覆盖：`docs/analysis/tools/axi_stat.cpp`（`axi_run_stat.sh`、`axi_agg_stat.py`、程序表 `axi_progs68.txt`）、`axi_mkcov.sh`/`axi_runcov.sh`（gcov）。

## 3. 验证：加 tap 前后行为不变
原版 `refsim_tap` vs 打补丁后（钩子关闭 / 开启并加载统计插件，每 tick 读取全部字段），stdout 逐字节一致（含周期数与全部统计）：dcache-mshr-pressure、dcache-conflict-writeback、timer-mmio、vm_pagefault_test、quick-sort、memory-stress-small（`docs/analysis/tools/axi_identity.sh`）。补丁对已打 memsys 补丁的 `refsim_tap` `patch -p1 --dry-run` 无冲突。采集点只做拷贝（`dbg_*` 调用的是 const 成员函数）。
