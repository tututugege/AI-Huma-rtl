# 访存 CPU 域录制点（第四个 tap：`TTG_MC`）：设计、补丁、用法、验证

配套：`memcpu-record-hook.patch`（**打在 `memsys-record-hook.patch` 之上**；改 `MemSubSystem/MemSubsystem.cpp`、`MemSubSystem/include/MemSubsystem.h`、`rv_simu_mmu_v2.cpp`，新文件 `MemSubSystem/include/memcpu_tap.h`）、
`tools/memcpu_cov.cpp`（覆盖插件）、`data/memcpu_coverage_68prog_200kcyc.txt`。背景见 `memsys-boundary.md` §2.2–2.4、§2.5 CPU 侧视图、§4。

## 1. 它读什么（全部是**只读拷贝**，`$TTG_REC` 设置时才开）

一个 CPU 周期里各捕获点把值拷进 `g_ttg_mc.cur`（`McCycle`）；周期末（`SimCpu::cycle()` 末尾，`ttg_ms_end::call` 之后）`cur → pub`，`cur` 清零重来。
**普通的 `$TTG_REC` 周期中钩子（`back.comb()` 之后）在下一个周期读 `pub` = 上一周期的完整最终记录**（"滞后一拍"重放：第 k 条记录在第 k+1 周期的钩子里比较，第一次调用看到空闲的初始记录；
`McCycle` 的构造函数把 PTW `req_ready`、外设 `resp.ready` 置 1，等于复位后 RTL 在零输入下的输出）。这样 **不需要改 `scripts/lockstep.sh` / `lockstep_multi.sh`、不需要 `TTG_REC_END`**，多插件并行照常工作。

| 字段（`TTG_MC.pub.*`）| 来源与时刻 |
| --- | --- |
| `r_resp_in` `r_lsu_resp` `r_icache_resp` `r_events` `r_wakeup` | `MemSubsystem::comb_outputs()` 末尾（`mem_route_block.comb_response()` 之后）：路由块的响应侧输入（`dcache_resp_route_`）和输出（`*dcache2lsu`、`*icache_resp`、`ptw_events`、`wakeup`）|
| `r_lsu_req` `r_icache_req` `r_walk_req` `r_dtlb_req` `r_itlb_req` `r_dcache_req` `r_grant` | `comb_inputs()` 里 `mem_route_block.comb_request()` 之后（`dcache_domain_comb_inputs` 之前）|
| `p_view` | `comb_inputs()` 入口：`ptw_block.comb_outputs()`（上一次 `seq` 之后的寄存器投影 = TLB 在本周期开头读到的 `req_ready/resp_*`）|
| `p_in` `p_issue` `p_addr` | `ptw_block.comb_begin()` 的输入、之后的 `issue_walk_read/walk_read_addr`（同拍选中→同拍发读的组合路径）|
| `p_fb` | `comb_finish()` 的 `FeedbackIn`（grant/event/wakeup）|
| `p_flush[2]` | `MemSubsystem::seq()` 里 `ptw_seq_in.walk_client_flush` |
| `q_req` `q_cur` `q_in` `q_is_uncached` `q_is_modeled` | `peripheral_axi_.comb_outputs()` 之前：LSU 请求、PeripheralAxi 当前状态、AXI 输入、地址译码（`simulator_is_uncached_memory_addr` / `PeripheralModel::is_modeled_mmio`）|
| `q_out` `q_resp` `q_env_rdata` | `comb_inputs()` 之后：AXI 输出、最终 `*peripheral_resp`（顶层 hold 寄存器锁存的值）、`nxt.rdata`（本地服务的读数据）|
| `ax[t].ch[k]`（t=0..15）| `run_extra_axi_subsystem_ticks` 里**与 `capture/accumulate_axi_cpu_boundary_state` 完全相同的位置和来源**：`ready`=口 `req.ready`，`accepted/accepted_id`=互连 `read_req_accepted[_id]`（写：`write_req_accepted`、口 `req.id`）状态，`resp_*`=口 `resp.valid/id`，`resp_ready`=主设备 `resp.ready`。通道 0=读 ICACHE、1=读 EXTRA（外设）、2=写 EXTRA |
| `view`、`exp_view` | `restore_axi_cpu_boundary_state` 之后各口的值（CPU 视图）；`exp_view` = **上一周期**末的 `view`（RTL 的寄存器化视图在下个周期 tick 0 才可见，且整个周期保持不变）|
| `t` | 16-tick 锁步外壳（`tb/memcpu/axi_shell.cpp`）当前重放的 tick 下标 |

`McTap::on` 只在 `$TTG_REC` 非空时为真（`MemSubsystem.cpp` 里静态初始化读一次环境变量）；之外所有捕获点是一次 bool 判断。**没有任何回写。**

## 2. 使用

```bash
SP=<scratch>; rsync -a $RTL_ROOT/refsim_tap/ $SP/refsim_mc/
cd $SP/refsim_mc && patch -p1 < <repo>/docs/analysis/memsys-record-hook.patch && patch -p1 < <repo>/docs/analysis/memcpu-record-hook.patch
gmake LDFLAGS="-lz" -j6
REFSIM=$SP/refsim_mc bash scripts/lockstep.sh mem_route <prog.bin> 100000            # 单模块
```
**`axi_cpu_port_adapter` 需要 16-tick 外壳**（一个 CPU 周期 = 16 条记录）。外壳 `tb/memcpu/axi_shell.cpp` 是模块无关的（只有构建 adapter 时才 16 次，其它模块 1 次），所以一个共享的 `EXTRA_CPP`（`lockstep.sh` 已支持，追加到 clang 命令行）即可让 `lockstep_multi.sh` 一次构建并跑四个模块：
```bash
EXTRA_CPP="-Dttg_rec_cycle=ttg_rec_cycle_gen $PWD/tb/memcpu/axi_shell.cpp" REFSIM=$SP/refsim_mc BIG_CYCLES=300000 \
  bash scripts/lockstep_multi.sh mem_route ptw_walk peripheral_axi axi_cpu_port_adapter
```
`-D` 把生成的单条比较入口改名，外壳导出真正被参考模型 `dlsym` 的 `ttg_rec_cycle`，每个 CPU 周期设 `TTG_MC.t = 0..15` 调生成入口 16 次（`lockstep.sh` 单模块运行时 `TTG_REC_N` 数的是记录数，adapter 是周期数×16）。

## 3. 验证：加 tap 前后行为不变
`refsim_tap`（原版）、补丁版不设 `TTG_REC`、补丁版设 `TTG_REC=<覆盖插件>`，三者 stdout（去掉含 time/MIPS/host 的行）**逐字节相同**（含周期数、IPC、全部统计）：

| 程序 | 结果 |
| --- | --- |
| dcache-conflict-writeback | 三者一致 |
| vm_pagefault_test | 三者一致 |
| vm_sfence_perm_test | 三者一致 |
| memory-stress（1,541,195 拍，IPC 4.837140）| 三者一致 |

补丁自身：对"`refsim_tap` + `memsys-record-hook.patch`"用 `patch -p1` 干净应用（逐文件与开发副本一致，已 `cmp`）；**对未打 memsys 补丁的 `refsim_tap` 会有 2 个 `MemSubsystem.cpp` 块失败**（同一批位置）。

## 4. 覆盖与死代码结论（`tools/memcpu_cov.cpp`，68 个程序 × ≤20 万拍，`data/memcpu_coverage_68prog_200kcyc.txt`）
- **PTW mem-client 路径死**：`ptw_memclient_req_valid`、`route_dtlb_req_valid`、`route_itlb_req_valid`、event/grant owner = MEM_DTLB/ITLB、`wakeup_dtlb/itlb`、`event.replay≠0` 全部 0；`lldb` 在 4 个会走页表的 vm 程序上对 `PtwWalker::start`、`PtwWalker::tick`、`MemSubsystemPtwMemPortAdapter::send_read_req` 下断点，命中 **0** 次（`MemPtwBlock::on_walk_mem_resp` 命中 3/4/6/7 次）。`PtwCompactCoreKernel.h` 的入口（`compact_core_io_generator` 等）在整个源码树里没有调用者。
- **只有 4 个程序（vm 测试）会走页表**，共 20 次 walk 发射：PTW 的 L1 叶（超级页）、各类 PTE 故障（只有 L1 无效 2 次、L2 叶 9、L1 指针 9）、wakeup、陈旧事件、冲刷等待中的 walk、双客户端竞争基本**没有**真实程序覆盖 → 靠随机生成器（`tb/memcpu/gen_rand.cpp`）。
- **外设 AXI 路径（第三类地址）68 个程序一次都没走**：`per_req_*_axi = 0`，`rdEX/wrEX_ready_never`（互连对 EXTRA 口从不报 `ready`）；外设请求全部是 uncached RAM 读写（dhrystone/coremark 的 printf）和 modeled 设备（UART/CLINT 写）→ 靠随机。
- 适配器：ICache 通道 `accepted` 总是在 tick 0 的 seq 里出现（`rdIC_accepted_t0 = rdIC_accepted_cycle`），`resp_matches_new_accept`（同 id 响应抑制）1238 次，`ready` 混合（有的 tick 为 1、有的为 0）5169 次；**peripheral 两个通道从不 ready/accepted** → 靠随机。
