---
module: front_top
area: frontend
rtl: rtl/frontend/front_top（front_top.sv、front_fetch_buf.sv、front_pred_path.sv）
model: trace-model front-end/front_core.h 的 `FrontCore`（各调度单元 `front.core.*` 的连线 `FrontCore::FrontCore` 和阶段顺序 `FrontCore::comb`）；指令起点扫描对应 front-end/front_top.cpp 的 `InstPort::comb_write`（调度单元 `front.core.inst_port`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles.txt）
depth: 153 层 / 898,333 cells（Yosys 通用门代理 `SYNTH_ABC="strash;balance;map" SYNTH_NO_MEMPRIO=1`，EXP-050 块级 1-Ahead FTB 后首次在 3600s 内完成）
---

# front_top 设计文档

## 1. 职责

前端的装配层：把 BPU、I-Cache（含 ITLB）、四个队列、预译码、检查器接成一个一拍求值一次的组合网络，状态全在子模块里。三个文件各管一块：

- `front_top.sv`：只连线。把 `front_ctrl`、`icache`、`front_fetch_buf`、`front_pred_path` 接起来，对外是"后端来的重定向和训练包、存储侧口、送后端的取指组"；
- `front_fetch_buf.sv`：取指地址队列、I-Cache 回来的取指组的展开（16 位压缩指令还原成 32 位）和预译码、指令起点扫描、顺序下一 pc、指令队列的写；
- `front_pred_path.sv`：BPU、PTAB、携带寄存器（`lh_*`）和 `front_head_fix`、预测检查器、`front_pd_info`、`front2back` 队列、送后端的输出旁路。

模型里没有与 `front_top` 同名的类。模型的前端是 `FrontCore`：它拥有 BPU、四个队列端口、I-Cache、检查器、控制，每个是一个调度单元（`front.core.ctrl / bpu_pipe / fa_port / ptab_port / inst_port / f2b_port / icache / checker`），`FrontCore::FrontCore` 里每个输入接到驱动它的模块输出上，`FrontCore::comb` 里的阶段顺序由 `scripts/comb/gen_top_order.py` 从各单元的 `CONTRACT` 注释生成。RTL 的 `front_top` 就是这张连线图；没有"顺序"，一切是一拍内的组合网络。各块的细节见 [bpu.md](bpu.md)、[icache.md](icache.md)、[front_ctrl.md](front_ctrl.md)、[front_fifos.md](front_fifos.md)、[predecode.md](predecode.md)。

本文不含 `rtl/core/core_top` 里的胶合（`core_back2front`、`core_front2back`、`core_front`）：`front_top` 的后端侧输入就是它们寄存之后的值（`be_*`、`upd_*`、`csr_*` 是寄存后的 back2front）。

## 2. 配置（`ttg_cfg_pkg` / `front_pkg`，现行默认）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 取指组 | 16 个槽（slot），每槽 2 字节，共 32 字节 | `FETCH_WIDTH = 16`、`SLOT_BYTES = 2`、`FETCH_BYTES = 32` |
| 压缩指令 | 开 | `RVC_ENABLE = 1` |
| 提交口（训练包）数 | 8 | `COMMIT_WIDTH = 8`（BPU 里叫 `NCOMMIT`） |
| 取指地址队列 | 16 项 × 64 位 | `FETCH_ADDR_FIFO_SIZE = 16` |
| 指令队列 | 16 项 × 1729 位 | `INSTRUCTION_FIFO_SIZE = 16`，`inst_fifo_entry_t` |
| PTAB | 16 项 × 1526 位 | `PTAB_SIZE = 16`，`ptab_entry_t` |
| front2back 队列 | 8 项 × 2135 位 | `FRONT2BACK_FIFO_SIZE = 8`，`f2b_fifo_entry_t` |
| 随块走的修复记录 | `BCK_W = 166` 位 = 8 位纪元 + 158 位检查点（140 位历史 + 18 位 RAS 指针） | `EPOCH_W`、`HCK_W` |
| 快速路径开关 | `FE_RFAST = 15`（位 0、1、2、3 全开），`FE_BFAST = 0` | `ttg_cfg_pkg` |

条目位宽是手工按 `front_pkg` 里结构体的字段加出来的（`$bits` 没有综合验证过），队列文件头部的位宽注释（"16 x 576b"、"32 x 2424b"等）是旧值，以本表为准。

`FE_RFAST` 的四位（代码里的实际含义）：位 0 = BPU 在重定向那一拍就按新 pc 发射 S0（`bpu_ctl`、`bpu.sv`）；位 1 = PTAB 写读旁路（`front_ctrl_enables`、`ptab`）；位 2 = I-Cache 重定向后不空等一拍（`icache_kill`）；位 3 = 后端 `pre_idu_ibuf` 的旁路（不属前端）。`FE_BFAST` 非 0 的分支（S2 / L1 覆盖时 S0 也立即重发、`WR_AFTER_DROP`）在当前配置里不会被综合进来，模型里也已删除这个开关，见第 7 节。

## 3. 接口

端口按模型 `FrontTopIn / FrontTopOut`（`front_IO.h`）的字段平铺：

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `be_refetch`、`be_refetch_address` | 后端重定向（冲刷 / 误预测 / 异常），已是寄存后的值 |
| 入 | `be_rf_valid / _ck / _epoch / _type / _pc / _is_rvc` | 后端分支误预测带回的修复记录：检查点、纪元、类型、分支 pc、是否 16 位 |
| 入 | `itlb_flush`、`fence_i`、`fifo_read_enable` | SFENCE.VMA、FENCE.I、后端本拍是否读 front2back 队列 |
| 入 | `csr_status_*` | satp、特权级、mxr、sum、mprv、mpp，给 ITLB |
| 入 | `upd_valid / base_pc / actual_dir / upd_is_rvc / br_type / target / pred_dir / alt_pred / pcpn / tags / idxs [NCOMMIT]` | 提交流的 BPU 训练包 |
| 入 | `mem_*`、`dc_*`、`ptw_walk_*` | I-Cache 的存储侧：AXI 读口响应、DCache 探针响应、ITLB 的页表遍历响应 |
| 出 | `out_valid`、`out_lane_valid[16]`、`out_instructions`、`out_pc`、`out_predict_dir`、`out_is_rvc`、`out_page_fault_inst`、`out_alt_pred`、`out_pcpn`、`out_tage_idx / _tag`、`out_predict_next_fetch_address`、`out_bpu_ck`、`out_slot_kind` | 送后端的取指组（后端那一侧的 no-taken 截断不在这里） |
| 出 | `mem_req_*`、`mem_resp_ready`、`dc_req_*`、`ptw_walk_req_*`、`ptw_walk_resp_consumed`、`ptw_walk_flush` | I-Cache 的存储侧请求 |
| 出 | `commit_upd_free`、`commit_tq_free` | BPU 更新队列和 uBTB 训练队列的空闲项数，给紧凑 ROB 做提交信用（EXP-028） |

`out_pc[i]` 是 `基址 + 2*i`（`SLOT_BYTES * i`），只有被携带的槽 0 例外（见 [predecode.md](predecode.md) 第 5 节）；队列里只存基址，不存每槽 pc。`out_lane_valid[i] = out_valid & out_inst_valid[i]`（`front_top.sv`）。

## 4. 结构

```
 front_top（只连线，无状态）
   front_ctrl        : 全局 refetch（含晚一拍的 predecode refetch）、各读写使能、f2b 输出旁路选择        -> front_ctrl.md
   icache            : 取指地址队列队首 -> 取指组（含 ITLB），存储侧口直接引出                          -> icache.md
   front_fetch_buf   : fetch_addr_fifo、rvc_expand x16、predecode x16、指令起点扫描、sequential_next_pc、inst_fifo
   front_pred_path   : bpu、ptab、front_head_fix、predecode_checker、front_slot_kind x16、front_pd_info、
                       front2back_fifo、携带寄存器 lh_*、front.out 旁路 mux
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `front_top.sv` | 222 | 连线；`refetch_pd = global_refetch & !be_refetch`；`out_lane_valid` |
| `front_fetch_buf.sv` | 199 | 取指侧：16 路 `rvc_expand`、`is_rvc`、指令起点扫描（`start_a / start_b`）、`up_ok`、`inst_wr_en = ic_read_complete & !global_refetch` |
| `front_pred_path.sv` | 339 | 预测侧：BPU 的例化（`bpu_bck = {epoch, ck}`）、携带寄存器、检查器、`front2back` 写、输出旁路 |

状态：`front_top` 自己没有；`front_fetch_buf` 没有（队列状态在 `front_fifo` 里）；`front_pred_path` 有携带寄存器 `lh_valid_q`（1 位）、`lh_pc_q`（64 位）、`lh_data_q`（16 位）。其余状态在子模块：`front_refetch_ctrl` 的 `predecode_refetch_q` 和地址、四个队列的指针和计数、BPU、I-Cache、`front_pd_info` 的一拍寄存器。

### 指令起点扫描（`front_fetch_buf.sv`）

压缩指令（RVC）使一个取指组里的 16 个槽不一定都是指令的开头：32 位指令占两个槽。第 i 槽是不是一条指令的开头，取决于它前面一个槽是不是一条 32 位指令的开头：`start[i] = valid[i] & (!start[i-1] | is_rvc[i-1])`。写成逐槽的链很长。现行写法利用"槽 i 是开头，当且仅当它到前面最近一条 16 位指令的距离为偶数"：对每个槽，找它左边最近的一个 `is_rvc` 为 1 的槽及这个槽下标的奇偶，做 4 轮（距离 1、2、4、8）的前缀扫描。输出两份：

- `start_a`：槽 0 是一条指令的开头（普通情形；扫描里"左边没有 16 位指令"当作在槽 -1，奇数位）；
- `start_b`：槽 0 是上一组最后一条 32 位指令的后半（携带情形）；槽 0 当作一条 16 位指令、在偶数位。

两份都写进指令队列，由 `front_head_fix` 按本组是否被携带选用其中一份。`up_ok` 是"本组最后一个有效槽的窗口有真实的高 16 位"（它的下一个半字在同一缓存行内）。

## 5. 一拍内的数据流

下面是各块之间的依赖顺序（同一拍内，从寄存器出发）：

1. 寄存器值：四个队列的计数、`predecode_refetch_q`、携带寄存器、BPU 阶段寄存器、I-Cache 寄存器。`front_ctrl` 算出 `global_refetch = be_refetch | predecode_refetch_q`。
2. 取指地址队列队首（`fa_rd_en` 成立时）作为 `req_valid / fetch_address` 送 I-Cache；I-Cache 的 `read_complete / fetch_pc / fetch_group / inst_valid / page_fault_inst / fetch_upper_ok` 回来。
3. `front_fetch_buf`：16 路展开（`ic_fetch_group[i][1:0] != 2'b11` 的窗口是 16 位指令，展开成 32 位，非法编码展开成 0）、预测译码（只看展开后的字）、起点扫描、`seq_next_pc`；`ic_read_complete & !global_refetch` 时整组写进指令队列。
4. BPU 同拍给出 `icache_read_valid / fetch_address`（S0 块，经 `fa_wr_en` 写取指地址队列）和 `ptab_write_enable`（S2 块，经 `ptab_wr_en` 写 PTAB）。
5. `predecode_can_run`（指令队列非空、PTAB 非空或同拍有旁路写、`front2back` 队列不满、无全局 refetch）时，读指令队列队首和 PTAB 队首；`front_head_fix` 处理携带、丢弃非起点槽、处理末槽跨组；`predecode_checker` 比较预测与预译码；`front_slot_kind` 为每槽译出 BPU 类型。
6. 检查通过或不通过都要写 `front2back` 队列（`f2b_wr_en`）；队列空、后端本拍读时走旁路（`f2b_use_bypass`），本拍写的条目直接当输出。
7. `do_predecode_flush = predecode_can_run & checker_flush_enable`：进 `predecode_refetch_q`（下一拍成为全局 refetch）、进 I-Cache 的 `invalidate`（同拍的第二步）、进 `front_pd_info` 的寄存器（下一拍告诉 BPU）。

没有组合环：`do_predecode_flush` 只进寄存器和 I-Cache 的次态，I-Cache 的取指组输出不依赖 `invalidate`（`icache_ctl` 中 `resp_*` 只看 `kill1`）。

## 6. 关键路径与深度

`depth: 待测（由协调者补）`。已测的单模块数字（通用门级代理，层数）：

| 模块 | 层数 | 说明 |
| --- | --- | --- |
| `front_fetch_buf` | 40 | 指令起点扫描改成前缀扫描之后；改之前链比这深约 40 层 |
| `front_top` 整体 | 132 | **uBTB 查表改写之前**的测量；最长路径在 BPU 里：S1 阶段寄存器 → uBTB 查表 → override / 发射判定 → 投机历史更新 |
| `front_top` 整体（更早） | 528 / 182 / 159 | 整核修复之前，528 是 `bpu_ub_track_ser` 的块跟踪器 |

从代码读出的，未综合验证：前端的组合路径有两条值得注意。一是 BPU 内的 S0 环（见 [bpu.md](bpu.md) 第 6 节）；二是检查链：指令队列队首 → `front_head_fix`（起点链选择、携带组装、末槽判定）→ `predecode_checker`（第一个 taken 槽、目标选择、与 PTAB 预测比较）→ `do_predecode_flush` → `front2back` 写使能和 `predecode_refetch_q`，以及 `front_pd_info` 的第一个 taken 槽选择。这条链不经过 BPU，但队列读口是存储器读，没有再切一拍。

深度相关的改动（均不改变周期）：

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| 指令起点用前缀扫描 | `737e7a5` | `front_fetch_buf` 从 16 槽的链改为 4 轮扫描 |
| 取指地址队列在 push 后一拍才弹出（`head_fresh`） | `4eb8f0e` | 弹出不再依赖同拍 BPU S2 覆盖的决定，见 [front_fifos.md](front_fifos.md) |
| 其余的深度改动都在 BPU 里 | `7551dd0`、`47f4a7d`、`2c76ba2` | 见 [bpu.md](bpu.md) |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- `FE_PAIR`（一拍取两个块，默认关）和 `FE_IPF`（I-Cache 预取，默认关）：RTL 没有，模型默认也是关（`include/env.h`）；
- PMU 前端分类（`FrontControl::finish` 里 `g_pmu_front.feo_*` 的损失原因）：RTL 的前端里没有，RTL 只有一级事件（见 `rtl/pmu`）；
- 模型的 `ReadData` 快照、`front_state` 的 `d` 值、八个 `*_full / *_empty` 锁存：RTL 的 `full / empty` 直接由计数算（`front_fifo`），没有这些寄存器；
- 模型 `pend_*`（FE_PAIR 的第二块）：没有；
- `front.in.reset`（只在模型 `FrontTop::init()` 一拍有效）：RTL 用 `rst_n`，没有"& !reset"项；
- 实例化时 `bpu_can_run` 只用于 `front_ctrl` 内部，顶层接到 `unused_ok`；`override_valid` 在 `front_pred_path` 里不再被用（`override_squash` 仍用于丢取指地址队列的尾项）。

RTL 与模型保持一致的细节：

- 全局 refetch 只清取指地址队列、指令队列、PTAB；`front2back` 队列只被**后端**重定向清（`front2back_fifo.refetch` 接 `be_refetch`），预译码冲刷不清它；
- 携带寄存器在后端重定向或复位时清；预译码冲刷时除非冲刷的那组自己产生了新的携带且续在其后，否则也等于被清（`lh_valid_q <= lh_new_valid`，其中含 `!checker_flush_enable || corrected == lh_new_pc`）。

模型的默认值与参考周期：`include/config.h` 里 `CFG_FE_OVR_REG` 的默认值是 0；RTL 只有"取指地址队列晚一拍弹出"这一种行为，对应 `CFG_FE_OVR_REG = 1`，参考周期表 ev5 就是用 `CFG_FE_OVR_REG=1` 生成的（该表第一行注释）。`FE_RFAST` 在模型里没有对应的开关，是固定行为；RTL 保留的参数用来在没有模型对照的情况下构建变体（`include/config.h` 注释）。

未核对（继承自旧文档）：

- 旧文档写"后端是整组接收（`PreIduQueue::comb_accept_front`：ready 时 `fire = valid`，不 ready 时全 0），hold 里的组恒为完整的组"，这条属于 core_top 胶合，本轮没有核对；
- 旧文档写"指令队列条目数不超过 PTAB 条目数不超过 15，所以指令队列永不满，`front_fetch_buf` 去掉了 full 条件"：只有仿真断言（`front_fifo` 的溢出断言）在保护，没有独立验证；
- 旧文档写"BPU 无效训练槽整体清 0，所有消费者都由 `upd_valid` 门控"：本轮只核对了 `bpu_updq`（`lane_ctl` 含 `upd_valid`），其余消费者没有逐个核对。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，每条提交对比 function-model，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`（模型同配置生成）：67/67 通过，周期逐个相等。其中触及前端的有 `fence-i-self-modify`（FENCE.I 与自修改代码）、`itt-dispatch`（间接跳转表）、各陷入 / 中断程序（后端重定向）、`dhrystone / coremark`（取指带宽和预测）。
- **Linux**：`scripts/linux_gate.sh`（整机从复位启动，每区间 PMU 一级事件与模型相同、逐条检查、控制台到 `login:`）、`scripts/linux_segments_cmp.sh`（检查点窗口，PT / UP 指纹相同）。前端的 PT（PTAB 写）和 UP（预测表更新）指纹由 `scripts/align_check.sh` / `align_check.py` 比较（RTL 侧 `tb/soc/fpr.h`，模型侧 `front-end/BPU/fpr.h`），能指出第一个分歧的区间和事件。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有前端装配层的独立测试**。`scripts/fe_refs/` 里的 `ref_r15_b0.txt`、`ref_r15_b3.txt` 是 `FE_RFAST = 15` 下 `FE_BFAST = 0 / 3` 的旧周期表，数值与现行参考不同（例如 `add-longlong` 1869 对 1441），不是现行门禁的一部分。
- **待补**：前端深度改写（起点扫描）的等价性是用"对每个有效前缀穷举 65536 种压缩模式与链式写法比较"证明的，测试台在草稿目录、不在仓库里；应把它收进 `tb/`。

## 9. 参数与开关速查

`FE_RFAST`、`FE_BFAST`、`RVC_ENABLE`、`FETCH_WIDTH`、`FETCH_BYTES`、`SLOT_BYTES`、`COMMIT_WIDTH`（`ttg_cfg_pkg`）；`FETCH_ADDR_FIFO_SIZE`、`INSTRUCTION_FIFO_SIZE`、`PTAB_SIZE`、`FRONT2BACK_FIFO_SIZE`（`ttg_cfg_pkg`，`front_pkg` 里换名为 `*_DEPTH` 并给出"满"阈值 `*_FULL_AT`）。`ttg_cfg_pkg.sv` 文件头写着"由 gen_cfg_pkg.py 生成，不要手改"，但当前内容与 `make cfg` 的输出是否一致没有核对。

## 10. 变更记录

- 2026-11-17/18（exp/agu-share）：指令起点前缀扫描 `737e7a5`；取指地址队列 push 后一拍才弹出 `4eb8f0e`（模型 `CFG_FE_OVR_REG`，16 个 SPEC 点几何平均 IPC -0.82 %）；BPU 的三处深度改写 `7551dd0`、`47f4a7d`、`2c76ba2`（见 bpu.md）。
- 更早：见 git 历史。
