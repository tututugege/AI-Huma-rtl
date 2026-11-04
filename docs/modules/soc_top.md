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

## 空闲 tick 跳过（测试平台加速）

16 倍频访存域里大多数 fast tick 无事发生。`tb/soc/soc_tb.cpp` 在每个 CPU 周期的 tick 1 之后给 Verilated 状态做快照，tick 2 之后若
(a) 状态逐字节相同（忽略 Verilator 临时变量 `__Vdfg*/__Vtemp*/__Vdly*`、≥1 MiB 的 RAM 数组即 LLC 数据，以及 `phase_q`）且
(b) SimDDR 空闲（队列空、各 cooldown 为 0），则 tick 3–14 不可能改变任何东西，直接把 `phase_q` 置 15 再跑 tick 15。
`SOC_TB_NOSKIP=1` 关闭。掩码由 `tools/gen_skipmask.py` 在 `tb/soc/build.sh` 中从 clang 布局生成。
结果：dhrystone 前 2 万周期 59 s → 23 s（约 2.5×，85% 的周期被跳过）；65 个程序周期数仍全部与参考相等。
注意：LLC 数据数组不参与比较，假设它只在控制状态变化时写入；若将来 LLC 出现读改写类的原地更新需重新评估。

### 每 tick 的 eval 次数（profile，SOC_TB_PROF=1）

`eval()` 占仿真时间 92%，测试平台自身可忽略。原来每 tick 4 次 eval：无时钟沿的 3 次各约 27 µs，时钟沿那次约 67 µs；
空闲 tick（147 µs）与 tick 0（212 µs）相差不大，说明核的时钟沿只贡献约 65 µs，大头是访存域每次 eval 的固定开销。
因此“核只跑一个 tick”本来就基本成立，拆成两个模型收益很小。已做的改动：tick 末尾的 eval 与下一 tick 的第一次合并（下降沿与新输入一起求值）、
外设环境输入未变时不再多 eval 一次。dhrystone 前 2 万周期（不跳 tick）59 s → 31 s；开启空闲跳过后 19 s。65 个程序周期数仍全部相等。
