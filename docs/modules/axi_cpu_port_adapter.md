# axi_cpu_port_adapter 设计笔记（非 DCache AXI 主口的 CPU 边界适配）

分析见 `docs/analysis/memsys-boundary.md` §2.5“CPU 侧视图”；录制点 `docs/analysis/memcpu-record-hook.md`。

## 1. 对应的 C++
`rv_simu_mmu_v2.cpp`（约 495–646）：`AxiCpuBoundaryState`、`capture_axi_cpu_boundary_state`（tick 0 的 seq 之后）、`accumulate_axi_cpu_boundary_state`（tick 1..15 每 tick 的 seq 之后）、`restore_axi_cpu_boundary_state`（tick 15 之后）、`mask_axi_cpu_boundary_for_internal_tick`（tick 1..15 把非 DCache 主口的请求/`resp.ready` 清零）。
**CPU 只在 tick 0 驱动主口，互连每 tick 前进**，适配器把 16 个 tick 的接口值折叠成 CPU 在**下一个周期**看到的视图：ICache 在 `front_comb_before_back`（周期开头，早于互连 tick-0 的 `comb_outputs`）直接读口字段（`ExternalReadPortAdapter::comb_view`）；互连的 `read_req_accepted[_id]`/`write_req_accepted` **状态数组也被写回**，所以外设在 tick-0 的 `comb_outputs` 之后读到的 `accepted` 也是粘滞值；`resp.ready` 被写回口字段并在下一周期 tick-0 的互连 `comb_outputs` 里被消费（`clear_axi_master_inputs` 刻意不清它）。

## 2. 硬件结构
快时钟域（每 tick 一个沿），3 个通道（0 = ICache 读、1 = 外设读、2 = 外设写；NUM_*_MASTERS 里的 DCache 口和未用的 UNCORE_LSU_R 不经适配器）。`axi_cpu_port_chan` 一个通道，`axi_cpu_port_adapter` 例化 3 份。
| 状态 | 含义 |
| --- | --- |
| `ready_acc, acc, acc_id` | 本周期各 tick 的 `ready`(OR) / `accepted`(粘滞) / 最近一次 accepted 的 id（tick 0 无条件取 id）|
| `resp0_valid, resp0_id, resp0_ready` | tick 0 的响应有效/id、主设备 `resp.ready` |
| `view_*`（6 个寄存器）| 周期末（`phase_last`）装载的 CPU 视图，整个下一周期保持 |
`phase0`/`phase_last`（tick 0 / tick 15）由 SoC 顶层相位计数器给出。装载公式（tick 15 的组合值）：`ready = ready_acc|raw_ready`；`accepted = acc|raw_accepted`，`id` 同；`hide = accepted & raw_resp_valid & (raw_resp_id == id)`（同 id 的响应在 accepted 首次出现的那个周期被抑制）；`resp_valid = raw_resp_valid & !hide`；`resp_id = raw_resp_id`；`resp_ready = resp0_ready & !(resp_is_new | hide)`，`resp_is_new = raw_resp_valid & !(resp0_valid & resp0_id==raw_resp_id)`（响应是在额外 tick 里才出现的）。

## 3. 与 C++ 的差异点、放宽、不复刻
- 通道 2（写）的 `accepted_id` 取口的 `req.id`（额外 tick 被掩成 0）——C++ 只在适配器内部用（`matches_new_accept`），**从不写回**，所以不导出（RTL 通道 2 输出 0，tap 记 0）。**登记疑点**：写通道在 tick≥1 被接受时 `accepted_id` 是 0 而不是真实 id，与读通道不对称；外设写 id 恒 0，无影响。
- 放宽：`cpu_resp_id` 限定 `cpu_resp_valid`（ICache `icache_txn` 只在 `mem_resp_valid` 时用 `mem_resp_id`）；`cpu_accepted_id` 限定 `cpu_accepted`。
- 删除：`state.*` 的中间拷贝、`restore` 里对 DCache 口的跳过（DCache 口根本不进适配器）、`from_extra_tick` 之外的临时变量。
- 响应数据 `resp.data[16]` 不经适配器（C++ 不改写，取最后一个 tick 的值）：直通。
- **8 位 id → 4 位**：口 id 是 `wire<4>`，C++ 的 `uint8_t` 拷贝没有额外位。

## 4. 验证
- spec：`spec/axi_cpu_port_adapter.io`（14 字段，数组 [3]），**每 tick 一条记录**（16/周期）。16-tick 外壳 `tb/memcpu/axi_shell.cpp`（`-Dttg_rec_cycle=ttg_rec_cycle_gen` 改名 + 导出真入口）使其用已有的 `lockstep.sh/lockstep_multi.sh` 在整程序里实时锁步。
- 整程序：68/68 PASS（真实流量：ICache accepted 总在 tick 0 的 seq 里；同 id 抑制 1238 次，`ready` 混合 5169 次；外设两个通道从不 ready/accepted）。
- 随机：`gen_rand`（`-DMOD_AXI`）直接调用**从 `rv_simu_mmu_v2.cpp` 逐字抽出**的 `capture/accumulate/restore_axi_cpu_boundary_state` 与 `mask_axi_cpu_boundary_for_internal_tick`（`build_gen.sh` 用 python 切片），在假的互连口结构上驱动每 tick 的 ready/accepted/id/resp：6 个 profile × 8000 周期（12.8 万 tick 记录）全 PASS。覆盖（profile 0，8000 周期）：通道 0/1/2 各 ~1550 次 accepted（tick 0 仅 ~90，其余晚到）、`resp` 被隐藏 213/200/107 次、`resp.ready` 被扣留 ~680 次、额外 tick 才出现的响应 ~1100 次、accepted id 非零。
