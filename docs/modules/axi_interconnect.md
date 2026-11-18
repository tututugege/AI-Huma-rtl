---
module: axi_interconnect
area: memsys
rtl: rtl/memsys/axi_interconnect
model: trace-model axi-interconnect-kit/axi_interconnect/AXI_Interconnect.cpp、include/AXI_Interconnect.h、include/AXI_Interconnect_IO.h（调度单元 `axi`，类 `AxiSubsystem` 的成员 `interconnect`；见 axi_subsys.md）
status: 整核周期与模型逐个相等（最近一次提交 60ed422 的提交信息记 fm_gate 67/67、周期等于 scripts/ref_cycles_memiq6_nr_int2_ev5.txt；本次写文档没有重跑）
depth: 37 层（axi_interconnect，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# axi_interconnect 设计文档

## 1. 职责

AXI 互连：夹在"访存子系统的 4 个读主口、2 个写主口"和"LLC（最后一级缓存，见 axi_llc.md）、DDR"之间。**LLC 不在本模块内**：LLC 的输出是本模块的输入（`lo_*`、`hz_*`），本模块送给 LLC 的请求是输出（`li_*`）；`axi_subsys` 把两者连起来。每个时钟沿（一个 tick）做五件事：

1. 读主口收请求：每个主口 1 项"捕获槽"，用"ready 先抬、下一次请求还在才接收"的握手（下称 ready-first，见 5.1）；
2. 写主口收请求：只处理第一个有请求、且同一 64 字节行没有读在途的写主口（5.2）；
3. 把捕获槽里的请求按轮询（round-robin）送进唯一的一个"台"（stage，同一时刻只有一项读或写在送给 LLC），LLC 不收时读可被写抢占（5.3）；
4. LLC 的内存侧请求变成 DDR 的 AXI 通道：读走 AR / R，写走 AW / W / B，并做读写同行冲突检查（5.4、5.5）；
5. LLC 给主口的响应先进本模块的响应寄存器，主口的 `resp.ready` 把它取走（5.6）。

主口：读 0 = ICache（取指，可 bypass），读 1 = DCache 的 MSHR（整行填充），读 2 = UNCORE_LSU（`mem_axi.sv` 里接常量 0，没用），读 3 = 外设；写 0 = DCache 写缓冲，写 1 = 外设（`mem_axi.sv` 的 `m_rd_*` / `m_wr_*` 连接）。bypass（不缓存）请求指外设 MMIO 和 ICache 的非缓存取指，LLC 对它们不分配行。

模型对应：`AXI_Interconnect` 类在 LLC 打开（`CONFIG_AXI_LLC_ENABLE = 1`）时的路径，它在调度单元 `axi`（`AxiSubsystem`）里被当作子模块扫描。RTL 只实现这条活路径，其余见第 7 节。

## 2. 配置（`axi_ic_pkg`，现行默认）

| 量 | 值 | 来源 |
| --- | --- | --- |
| 读主口数 `NR` / 写主口数 `NW` | 4 / 2 | `axi_ic_pkg.sv`；模型 `NUM_READ_MASTERS` / `NUM_WRITE_MASTERS`（`AXI_Interconnect_IO.h`） |
| 在途 DDR 读槽数 `NM` | 8 = LLC 的 MSHR 数 | 宏 `AXI_LLC_MSHR`（默认 8，`axi_ic_pkg.sv`、`axi_llc_pkg.sv` 各有一份默认）；模型 `CONFIG_AXI_LLC_MSHR_NUM = 8`（`config.h`） |
| 行大小 | 64 字节 | `line64()` 取地址 `[31:6]` |
| DDR 数据拍宽 | 256 位（32 字节） | `d_rdata` / `d_wdata` 位宽；模型 `CONFIG_AXI_KIT_SIM_DDR_BEAT_BYTES = 32` |
| AXI id 位宽 | 6（端口）；分配时只用低 4 位（0..15） | `d_arid` 位宽；`axi_ic_ar` 的 `used[15:0]`；模型 `CONFIG_AXI_KIT_AXI_ID_WIDTH = 6` |
| 请求 `size` 字段 | 字节数减 1（整行 = 63） | `axi_ic_pkg` 的 `issue_len` 注释、`mem_axi.sv` 里 `m_rd_size[1] = 8'd63` |
| 小请求 | `size < 32`（≤ 32 字节）按 32 字节对齐发 1 拍，响应时按地址低 5 位右移取出 | `issue_small` / `issue_addr` |
| 每 CPU 周期的 tick 数 | 1 | `AXI_SUBSYSTEM_FREQ_DIV = 1`（`ttg_cfg_pkg`，模型 `config.h` 同值）；此时 `mem_top` 的 `phase0` 恒为 1 |

响应寄存器和延迟线：读响应 1 项 / 主口；写响应延迟线 2 项 / 写主口（`axi_ic_resp`）；`axi_ic_stage` 的捕获槽每主口 1 项。这些深度比模型的 32 项（`CONFIG_AXI_KIT_MAX_OUTSTANDING`）小得多，依据和风险见第 7 节。

## 3. 接口

端口名沿用旧体系的"边界规格"命名；数组端口是 `[4]`（读）、`[2]`（写）：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `m_rd_valid / addr / size / id / bypass / resp_ready [4]`、`m_wr_valid / addr / data(512) / strb(64) / size / id / bypass / resp_ready [2]` | 主口请求与响应 ready；`phase0` 是 CPU 周期的第 0 个 tick |
| 入 | `d_arready / d_rvalid / d_rid / d_rdata`、`d_awready / d_wready / d_bvalid / d_bid / d_bresp` | DDR 从口输出 |
| 入 | `lo_rd_req_ready / lo_rd_resp_* [4]`、`lo_wr_req_ready / lo_wr_resp_* [2]` | LLC 对主口的 ready 和响应 |
| 入 | `lo_mem_rd_req_*`、`lo_mem_wr_req_*` | LLC 的内存侧读 / 写请求（写带 512 位数据和 64 位字节使能） |
| 入 | `hz_lookup_*`、`hz_rresp_fresh / valid / id [4]`、`hz_mshr_* [8]` | LLC 里"在途"的状态寄存器，只给冲突检查读 |
| 出 | `m_rd_resp_valid / id / data [4]`、`m_wr_resp_valid / id / resp [2]` | 响应寄存器给主口 |
| 出 | `m_rd_accepted / _id [4]`、`m_wr_accepted [2]` | "已接收"标志（口径见 5.7）；另有 `m_rd_acc_new / _id`、`m_wr_acc_new`：本 tick 刚接收的 |
| 出 | `m_rd0_req_ready`、`m_rd3_req_ready`、`m_wr1_req_ready` | 只导出被 CPU 侧读的三个口的 `req.ready`（ICache 读、外设读、外设写） |
| 出 | `d_ar*`、`d_aw*`、`d_w*`、`d_rready`（恒 1）、`d_bready` | DDR 主口 |
| 出 | `li_rd_valid / addr / size / id / bypass / resp_ready [4]`、`li_wr_* [2]`、`li_mem_*` | 送给 LLC 的请求（"台"里的那一项）、LLC 内存侧的 ready 和 DDR 响应 |

## 4. 结构

```
 m_rd[4] ─► axi_ic_rd ─┐ acc / cap_*                    ┌─ axi_ic_ar ─► DDR AR / R ─► li_mem_rd_resp
 m_wr[2] ─► axi_ic_wr ─┤ (axi_ic_haz 给出写的同行读冲突)  │     r_pend[NM]、AR latch
                       ▼                                 │
                 axi_ic_stage（捕获槽 + 台 + 6 口轮询 + 读被写抢占）──► li_rd_* / li_wr_*（到 LLC）
 LLC lo_* ─► axi_ic_resp（读响应寄存器、写响应延迟线）──► m_rd_resp_* / m_wr_resp_*
 LLC lo_mem_wr ─► axi_ic_aw ─► DDR AW / W / B ─► li_mem_wr_resp
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `axi_ic_pkg.sv` | 45 | 常量（`NR`、`NW`、`NM`）、`line64`、小请求的发射形态函数 |
| `axi_interconnect.sv` | 293 | 顶层：端口适配、子块连线、边界输出 |
| `axi_ic_rd.sv` | 86 | 读捕获（ready-first、id 冲突检查） |
| `axi_ic_wr.sv` | 53 | 写捕获（固定优先级 0 → 1） |
| `axi_ic_haz.sv` | 53 | 写的同行读冲突检查 |
| `axi_ic_stage.sv` | 258 | 捕获槽、台、轮询派发、读被写抢占、accepted 标志 |
| `axi_ic_ar.sv` | 188 | DDR 读侧：AR latch、在途表 `r_pend`、R 拍收集、小读右移 |
| `axi_ic_aw.sv` | 145 | DDR 写侧：AW latch、W 拍、B 响应 |
| `axi_ic_resp.sv` | 106 | 响应寄存器和写响应延迟线 |

状态：`axi_ic_rd` / `axi_ic_wr` 各口一个 ready-first 寄存器；`axi_ic_stage` 的 `up_rd_q[4]`、`up_wr_q[2]`（含 512 位数据）、`stg_q`（台）、`rr_q`（0..5 的轮询指针）、accepted 标志的"本 tick"和"粘滞"两组寄存器；`axi_ic_ar` 的 `latch_q`、`pend_q[NM]`（每项含 512 位数据）、`seen_*`（见 5.4）；`axi_ic_aw` 的 `awl_q`、`w_q`（含 512 位数据和 64 位使能）、`rsp_v_q`；`axi_ic_resp` 每个读主口的 1 项（512 位数据）和每个写主口的 2 项延迟线。

## 5. 一拍内的数据流

### 5.1 读捕获（`axi_ic_rd`，每个主口互相独立）

`cand = 请求 valid & 捕获槽空 & 台里没有这个主口的读 & 没有 id 冲突`；`acc = cand & (主口是 DCache 读口 | ready 寄存器已置位)`；`ready_o2 = cand`；`ready_r' = cand & !acc`。即除 DCache 读口外，第一次看到请求只抬 ready，下一次请求还在才接收。ready 寄存器：DCache 读口每 tick 更新，其他口只在 `phase0` 更新（`FREQ_DIV = 1` 时没有区别）。

id 冲突（`conflict`）：同一主口的同 id 请求已在台、捕获槽、本地响应寄存器、LLC 的读响应寄存器（`hz_rresp_*`）、LLC 的查表寄存器、任一 MSHR 里；另外**只有主口 0** 还会与在途 DDR 读表 `r_pend` 里"槽号等于该 id"的项冲突（`rp_conf`）。这是模型的行为：LLC 发的内存读在模型里 `master_id` 恒为 0、`orig_id` 是 MSHR 槽号（`AXI_Interconnect.cpp:1174-1175`），所以 ICache 的 id 0..7 会被同号的在途 DDR 读卡住，RTL 复刻它。

### 5.2 写捕获（`axi_ic_wr`、`axi_ic_haz`）

`axi_ic_haz` 对每个写主口比较它的 64 字节行与：4 个读主口当前请求、4 个读捕获槽、台里的读、LLC 查表里的读、LLC 内存读请求、8 个 MSHR 里的读、`r_pend` 未完成项和 AR latch。有一个相等就是 `hazard`。`axi_ic_wr` 取 `valid & !hazard` 的第一个主口（固定优先级 0 → 1，`ttg_first_set`），它的 ready-first 寄存器已置位就接收，否则只抬起。

### 5.3 台与派发（`axi_ic_stage`）

每拍按顺序算：

1. **弹出**：台里的项被 LLC 接收（`lo_rd_ready[master]` 或 `lo_wr_ready[master]`）就清空；
2. **抢占**：弹出后台里还是一个没被 LLC 收的读、它主口的捕获槽已空、且有写捕获槽的行与它不同，则读退回自己的捕获槽，写进台；两个写都可选时按 `rr_q[0]` 决定先试哪个；
3. **派发**：台空时，从 `rr_q` 起按 读 0..3、写 0..1 的顺序（6 口）取第一个有请求的口进台，`rr_q = 口号 + 1 (mod 6)`；
4. **捕获**：派发后仍空的捕获槽收本拍接收的请求。

### 5.4 DDR 读侧（`axi_ic_ar`）

LLC 的内存读请求 `lo_*` 在以下条件下发出 AR（`fresh`）：没有 AR latch、不是"刚发过同一 (id, 地址, size) 的请求"（`seen_*`）、没有同行的写在途（AW latch 或活动 W，`wp_*`）。`arready` 为低时请求存进 `latch_q`，之后优先从 latch 发。AXI id 取 `r_pend` 和 latch 没用的最小 id（`ttg_first_set`）；`arlen = 0`（≤ 32 字节）或 1（整行 2 拍）。在途读按 LLC 内存 id（= MSHR 槽号）存在 `pend_q[NM]`，R 拍按 AXI id 匹配后填进 256 位半边；两拍（或一拍）收齐就是完成项，被 LLC 取走即释放（`read_resp_ready` 恒 1）。小读完成时数据按地址低 5 位右移。`d_rready` 恒为 1。

### 5.5 DDR 写侧（`axi_ic_aw`）

只服务 LLC 的内存写（受害行写回和 bypass 写）。`fresh = 没有 B 脉冲 & LLC 请求有效 & 同行没有读在途（`pr_v` 的 9 项加本拍刚发的 AR）& 没有活动 W & 没有 AW latch`。AW 直接由 LLC 请求驱动，`awready` 为低时存进 `awl_q`；AW 完成后下一拍起逐拍发 W（`wlast` 在最后一拍），B 的 id 与当前写匹配且没有未取走的 B 脉冲时 `bready`；B 完成后给 LLC 一个 1 tick 的 `write_resp` 脉冲。≤ 32 字节的写把数据和使能按地址低 5 位左移到 32 字节拍内的字节位置。

### 5.6 响应寄存器（`axi_ic_resp`）

读：每个主口 1 项。LLC 的响应在寄存器空且该响应不是"刚出现"（`hz_rresp_fresh`，LLC 的读响应寄存器出现后的第一个 tick 不可被取）时进入；主口 `resp.ready` 为高时清空。写：LLC 响应先进 2 项延迟线（每项过 1 个 tick 才可弹出），再进写响应寄存器，主口 `resp.ready` 清空；延迟线满或寄存器占着时对 LLC 的 ready 为低。

### 5.7 accepted 标志（`axi_ic_stage`）

`m_rd_acc_new`：本 tick 在捕获槽空时接收了请求（读）或接收了请求（写）。`m_rd_accepted`：DCache 口取"上一 tick 的 acc_new"；其他口在 `phase0` 取"整个 CPU 周期粘滞"值（`stk_*`，`phase0` 时先清零再累积，id 取最后一次接收的）。`FREQ_DIV = 1`（`phase0` 恒 1）时粘滞值就是上一 tick 的 `acc_new`，两种口径一致。粘滞逻辑是原 16 tick 方案留下的。

## 6. 关键路径与深度

单模块综合深度 **37 层**（axi_interconnect；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_rd.rp_v [0]` 到 `\u_ar.pend_d [2557]`。下面是从代码读出的、未综合验证的长组合链：

- **台的弹出 / 抢占 / 派发 / 捕获环**：`lo_rd_ready` 来自 LLC 的 `axi_llc_rdacc`（它对四个读口各做 3 组行 CAM 比较，再轮询选择，见 axi_llc.md），之后在 `axi_ic_stage` 里依次经过弹出、抢占判断、两次 `ttg_first_set`（派发）、捕获槽选择，最后写 512 位数据槽的次态。这是跨 LLC 和互连的一条链。
- **写捕获**：`axi_ic_haz` 对每个写主口约 28 个 26 位相等比较再 OR → `axi_ic_wr` 的 `ttg_first_set` → 接收 → 捕获槽。
- **读捕获**：id 比较（含 8 个 MSHR）→ `cand` → `acc` → 捕获槽。
- **DDR 读**：`lo_addr` 与 `wp_line` / `seen` 比较 → `fresh` → `o_arvalid` → `ar_fire`（含 `d_arready`）→ `pend_p` 入表 → 同拍 R 拍的 id 匹配 → 数据半边写入。
- **`li_resp_data`**：`comp_idx` 选出完成项 → 512 位数据按 `off` 右移。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- **MMIO 口和路由**：模型的 `AxiSubsystem` 里有 MMIO 总线和 UART，互连按地址分流到 DDR 或 MMIO；RTL 的互连只有 DDR 口，没有 MMIO 从口（`mem_axi.sv` 把外设读写接成互连的读 3 / 写 1，`bypass` 接 `phase0`，即当 bypass 请求送进 LLC 路径）。模型默认 DDR 基址为 0（`AXI_Interconnect.cpp:44`，`CONFIG_AXI_KIT_DDR_BASE` 可改）。
- 非 LLC 路径、运行期模式切换、预取、`invalidate_*` 维护、`read_req_hold`、`w_pending`、`llc_upstream_write_q`、`w_resp_queue` 等：RTL 没有，对应的"不会发生"用时钟断言守着（`axi_ic_stage` 的写槽占用断言、`axi_ic_ar` 的"同一 LLC 内存 id 二次在途"和"无空闲 AXI id"断言，`ifndef SYNTHESIS`）。
- 队列深度：模型是 32 项（`MAX_OUTSTANDING`），RTL 是 `r_pend` 8 项、读响应 1 项、写响应延迟线 2 项。依据是 LLC 的内存读在途数受 MSHR 数（8）限制；写响应延迟线深度来自旧文档里"实测最大 1"的记录，在第 8 节"未核对"里。
- 每 tick 的求值：模型 `AxiSubsystem` 对每个 tick 调 `comb_outputs` / `comb_inputs` / `seq`；RTL 把它们合成每个 `clk` 沿的一次次态函数。两次组合求值结果相同这一点没有在本次核对。
- `tick` 数：RTL 的 `phase0` 在 `FREQ_DIV = 1` 时恒为 1，粘滞 accepted、"只在 tick 0 更新"的 ready 寄存器都退化为每拍更新。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- ICache 读 id 与 MSHR 槽号冲突（5.1）；
- ready-first 握手，第一拍只抬 ready；
- 写口固定优先级 0 → 1，且只处理第一个无冲突的写主口（模型 `w_arb_rr_idx` 在活路径上恒 0，见第 8 节"未核对"）；
- 台上读被写抢占；
- LLC 读响应"刚出现一个 tick 内不可取"；
- 写响应经 1 tick 延迟再进寄存器。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比函数模型，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）。
- **Lint**：`scripts/lint_chip.sh`。
- **Linux 启动门禁**：`scripts/build_soc64_linux.sh`、`scripts/linux_gate.sh`、`scripts/linux_segments_cmp.sh`（Linux 启动会长时间用到 LLC 和 DDR 通路）。
- **没有模块级的独立测试**：`tests/` 和 `tb/` 下没有针对互连的测试（`tb/soc` 只是整核测试平台，带参考的 DDR 模型）。旧体系的锁步 spec（`axi_interconnect.io` 等）已随 `spec/` 退役。**待补**：互连的随机并排测试（把 `axi_subsys` 的主口随机驱动，与模型的 `AXI_Interconnect` 逐 tick 比较）；外设口（读 3 / 写 1）、bypass 写、写响应延迟线满、`r_pend` 满等路径在整核程序里很少或没有被走到，应有定向用例。
- **未核对（继承自旧文档）**：
  - 两次组合求值（`comb_outputs` 里的第一次与 `comb_inputs` 的最终一次）的输出逐字段相同（旧文档的实测，4 种 LLC 几何）；
  - 模型里 hazard 判断（读被挂起写阻塞、写被未完成读阻塞、写捕获被同行读阻塞）在 68 个程序里一次都没生效，因此这些逻辑没有程序验证过；
  - 外设口在 68 个程序里零触发；
  - 各队列的实测最大深度（r_pending 8、写响应延迟 1、读响应队列 1 等）；
  - 模型 `w_arb_rr_idx` 活路径恒 0、MMIO 口活动 0、`classify_downstream_port` 恒为 DDR；
  - 小读 / 小写的单拍发射形态对应模型的 `axi_bridge_downstream_*_issue_shape`（`force_ddr_aligned = 0`，32 字节拍）；
  - 旧文档里的"变异存活表"。

## 9. 参数与开关速查

`AXI_LLC_MSHR`（宏，默认 8，`axi_ic_pkg` 与 `axi_llc_pkg` 各有一份默认，两处必须一致）；`AXI_SUBSYSTEM_FREQ_DIV`（`ttg_cfg_pkg`，由 `mem_top` 的 `TICKS` 使用，当前 1）；模型侧 `CONFIG_AXI_LLC_ENABLE`、`CONFIG_AXI_LLC_MSHR_NUM`、`CONFIG_AXI_KIT_MAX_OUTSTANDING`、`CONFIG_AXI_KIT_AXI_ID_WIDTH`、`CONFIG_AXI_KIT_SIM_DDR_BEAT_BYTES`。

## 10. 变更记录

- 本分支（`261bd67..HEAD`）未改动本目录；更早：见 git 历史。
