---
module: soc_top
area: core
rtl: rtl/core/soc_top rtl/memsys/mem_top
spec: core_top
status: green
lockstep: 闭环（RTL 整核）周期数与参考一致：65 个程序（≤23 万周期）全部相等
mutants: 未跑
note: core_top + mem_top；测试平台 tb/soc（Verilator）+ 参考的 SimDDR/PhysMemory/PeripheralModel
---

# soc_top / mem_top 设计笔记（整核闭环）

## 1. 结构
- `mem_top`：访存子系统顶层，端口名与 `core_top` 的存储侧端口同名、方向相反。内部：`mem_route`、`ptw_walk`（客户端 0=DTLB、1=ITLB）、`dcache`、`peripheral_axi`、`mem_axi`（四个 AXI 主口胶水 + `axi_subsys` + `axi_cpu_port_adapter`）。
- `soc_top`：由 `tools/gen_soc_top.py` 生成，`core_top`（时钟 `clk_cpu`）加 `mem_top`（快时钟 `clk`）按端口名连接。
- 时钟：快时钟每 tick 一个沿；`clk_cpu` 在 tick 0 结束的那个快时钟沿同时给一个沿（测试平台生成）。`mem_top` 里的相位计数器 `phase_q` 由复位清零，`phase0` 即 tick 0。

## 2. 集成时的非显然规则（均来自参考模型的求值顺序，已被闭环对照验证）
1. DCache 的 LSU 请求只在 tick 0 进入，其余 tick 是空请求（`dcache_fast_comb(false)`），在 `mem_top` 门控；探针编码 `icache_req = probe ? NLD-1 : NLD`。
2. ICache 在周期开头（早于 `MemSubsystem::comb_outputs`）读探针响应，所以拿到的是路由块**上一周期**的响应：`mem_top` 对 `icache_resp_*` 加一级 `cpu_en` 寄存器。后端的 DCache 响应在 `comb_outputs` 之后读，是同周期的，不加寄存。
3. 外设响应有一个顶层保持寄存器（`peripheral_resp_hold`），核下一个周期才看到。
4. 非 DCache 主口（ICache、外设）只在 tick 0 驱动：`valid/地址/大小/id/bypass/resp_ready` 在 tick 1..15 清零。
5. `axi_cpu_port_adapter` 的 `raw_accepted` 是"该 tick seq 之后的 accepted 状态"，即该 tick 的"本 tick 接受"值；互连因此多导出 `m_rd_acc_new / m_rd_acc_new_id / m_wr_acc_new`（`axi_ic_stage` 的 `rd_new / wr_acc`）。互连输出的 `m_rd_accepted` 是另一个量（tick 0 上是整周期的粘滞值）。
6. 读口 1（MSHR）、写口 0（写缓冲）直连，常量：读大小 63、写大小 63、写 strb 全 1、写响应 ready 恒 1、bypass 0。

## 3. 测试平台 `tb/soc`
- `soc_tb.cpp`：每个 CPU 周期 16 个 tick：DDR 从口输出 → RTL → RTL 主口输出 → DDR 输入 → DDR seq → 时钟沿。程序结束 = 提交 `type == 10`（`ITYPE_EBREAK`）。
- 平台模型直接用参考的源码：`SimDDR`（时序由 config.h 决定）、`PhysMemory`、`PeripheralModel`（UART/中断控制器/定时器；`tick()` 每周期一次，驱动中断注入输入）。
- 设备写（modeled MMIO）在 store **提交**时生效（参考的 `commit_sync` → `on_commit_store`）：测试平台在提交周期从 LSU 的 `st_fld_q[stq_idx]` 读 paddr/data/func3（`public_flat_rw`，依赖 LSU 内部布局）。
- `SOC_TB_TRACE=<core_top trace>`：逐周期与参考录制的 `core_top` 边界比较，首个不一致的周期与字段立即报出（`scripts/record.sh core_top <prog>` 录制；对核不消费的输入字段按"配对 valid"放宽）。
- 构建：`bash tb/soc/build.sh`（`DEBUG=1` 打开内部信号调试打印）；运行：`bash scripts/soc_smoke.sh [最大参考周期]`，参考周期表 `scripts/ref_cycles.txt`。速度约 350 周期/秒。

## 4. 验证结果
- 65 个程序（gate 61 个、vm 4 个、dhrystone（64 次迭代）、coremark（2 次迭代）、memory-stress-small）周期数与参考逐一相等；提交条数与 trace 逐周期比较一致。
- 未覆盖：`memory-stress`（约 154 万周期，仿真约 70 分钟）、`float_test`、`load-store`（参考周期数我这边 200 秒内没测出来）。

## 5. 已知问题 / 待办
- LLC 的 bypass 写与部分行写 miss 未实现（断言会触发）；本批程序和默认配置不出现。
- `axi_subsys` 内互连↔LLC 经结构体有一个粒度上的 UNOPTFLAT，装配顶 lint 对其放宽。
- 外设 AXI 路径（`env_region=0` 且 MMIO）仍只被随机验证；测试平台没有 SD 卡/DMA 模型。
- 12 位以内的外设 `resp.ready` 在 tick 0 的"陈旧值"细节（适配器通道 1、2 的写回）没有在 `mem_axi` 复刻，外设 AXI 路径不被触发所以不可观察。

## Linux 启动（RTL 闭环）

```bash
SOC_OUT=$PWD/build/soc_linux SOC_VOPT=-DTTG_EBREAK_TRAP bash tb/soc/build.sh          # 打开 ebreak 断点异常的构建（默认构建不变）
MEM=0x10000000 bash ../function-model/linux/mkimage.sh <linux_rv32 目录> /tmp/linux.bin    # 平铺镜像
SOC_TB_SEMIHOST=1 build/soc_linux/obj/soc_tb /tmp/linux.bin <周期数>
```

镜像按程序加载（测试平台自带地址 0 的启动桩，`a1` = 设备树）。**与 trace-model（运行模式、同一镜像）逐周期对照**（2026-11-04）：

| trace-model 提交数 | 周期 | RTL 在该周期的提交数 |
| --- | --- | --- |
| 205,443（旧行为：在 OpenSBI 的 semihosting 探测处退出） | 62,061 | 205,443 |
| 400,002（打开断点异常后继续） | 107,585 | 400,002 |
| 1,000,007 | 247,399 | 1,000,007 |

限制：RTL 约每秒 4–5 千周期，完整启动（约 1.2 亿条指令）要 7 小时以上，所以只对照了前 100 万条；更远的部分要走检查点恢复（见 08-risk-register）。

## 空闲 tick 跳过（测试平台加速）

16 倍频访存域里大多数 fast tick 无事发生。`tb/soc/soc_tb.cpp` 在每个 CPU 周期的 tick 1 之后给 Verilated 状态做快照，tick 2 之后若
(a) 状态逐字节相同（忽略 Verilator 临时变量 `__Vdfg*/__Vtemp*/__Vdly*`、≥1 MiB 的 RAM 数组即 LLC 数据，以及 `phase_q`）且
(b) SimDDR 空闲（队列空、各 cooldown 为 0），则 tick 3–14 不可能改变任何东西，在 tick 3 的沿前把 `phase_q` 写为 14，使该沿装载 15，再跑 tick 15。
`SOC_TB_NOSKIP=1` 关闭。掩码由 `tools/gen_skipmask.py` 在 `tb/soc/build.sh` 中从 clang 布局生成。

多线程：`SOC_VOPT="--threads 4" SOC_OUT=build/soc_mt4 bash tb/soc/build.sh` 构建 4 线程版本（Verilator 调度器状态 `__Vm_mtaskstate_*` 已进掩码，空闲跳过照常生效）。dhrystone 20000 周期：单线程+跳过 5.8 s，4 线程+跳过 2.9 s（周期、指令数不变，跳过 17032 周期）。
结果：dhrystone 前 2 万周期 59 s → 23 s（约 2.5×，85% 的周期被跳过）；65 个程序周期数仍全部与参考相等。
注意：LLC 数据数组不参与比较，假设它只在控制状态变化时写入；若将来 LLC 出现读改写类的原地更新需重新评估。

### 每 tick 的 eval 次数（profile，SOC_TB_PROF=1）

`eval()` 占仿真时间 92%，测试平台自身可忽略。原来每 tick 4 次 eval：无时钟沿的 3 次各约 27 µs，时钟沿那次约 67 µs；
空闲 tick（147 µs）与 tick 0（212 µs）相差不大，说明核的时钟沿只贡献约 65 µs，大头是访存域每次 eval 的固定开销。
因此“核只跑一个 tick”本来就基本成立，拆成两个模型收益很小。已做的改动：tick 末尾的 eval 与下一 tick 的第一次合并（下降沿与新输入一起求值）、
外设环境输入未变时不再多 eval 一次。dhrystone 前 2 万周期（不跳 tick）59 s → 31 s；开启空闲跳过后 19 s。65 个程序周期数仍全部相等。

### 根因：`public_flat_rw` 让每次 eval 都重算（重要）

对一个 `public_flat_rw` 信号，Verilator 假定外部随时会写它，于是**每次 `eval()` 都重算所有依赖它的逻辑**。`mem_top.phase_q` 曾被标成 rw
（为了让测试平台直接写），而 `phase0` 门控几乎整个访存域，结果输入完全不变的 `eval()` 也要约 27 µs（采样显示时间全在 `ico_sequent`）。
改成 `public_flat_rd` 后，无变化的 eval 降到 0.2 µs。
**规则：不要用 `public_flat_rw`；测试平台只读的信号用 `public_flat_rd`。把相位做成每 tick 都变的顶层输入口也不行（每 tick 的输入变化都会触发全部输入相关逻辑重算，实测慢回 2 倍）。**
RTL 里不带任何 Verilator 公开属性：测试平台可见的信号由 `tb/soc/soc_public.vlt`（`tools/gen_soc_top.py` 生成）声明；
跳 tick 时测试平台在 tick 3 的时钟沿之前把 `phase_q` 写成 14（只读公开变量，C++ 仍可写），该沿即装载 15。
空闲跳过的比较点同时改为“每个 tick 输入施加、eval 之后、时钟沿之前”的 tick 2 与 tick 3 状态，两次状态相等且 SimDDR 空闲时，tick 3 的边沿装载 phase 15。
结果：dhrystone 前 2 万周期 59 s → 7.4 s（不跳 tick 14 s）；15 个长程序 6:52 → 1:56（4 并行）；65 个程序周期数仍全部相等。
