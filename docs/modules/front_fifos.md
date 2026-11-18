---
module: front_fifos
area: frontend
rtl: rtl/frontend/front_fifo.sv、fetch_addr_fifo.sv、ptab.sv、inst_fifo.sv、front2back_fifo.sv
model: trace-model front-end/fifo/front_fifo.h、front-end/front_fifo_ports.h、front-end/front_top.cpp（调度单元 `front.core.fa_port`、`front.core.ptab_port`、`front.core.inst_port`、`front.core.f2b_port`，类 `FetchAddrPort`、`PtabPort`、`InstPort`、`F2bPort`）
status: 整核周期与模型逐个相等（fm_gate 67/67，参考 scripts/ref_cycles_memiq6_nr_int2_ev5.txt）
depth: 13 层（fetch_addr_fifo；ptab、inst_fifo、front2back_fifo 更浅，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# front_fifos 设计文档

## 1. 职责

前端有四个先进先出队列，把前端分成几段，让各段按自己的节奏走：

| 队列 | 放什么 | 写的一方 | 读的一方 |
| --- | --- | --- | --- |
| 取指地址队列（fetch address FIFO） | BPU 预测出的取指块起始地址 | BPU 的 S0 | I-Cache 请求 |
| 指令队列（instruction FIFO） | I-Cache 回来并预译码过的取指组 | I-Cache 的响应 | 预测检查（和 PTAB 一起读） |
| PTAB（prediction table） | BPU 对这个块的最终预测（S2 之后） | BPU 的 S2 | 预测检查（和指令队列一起读） |
| front2back 队列 | 检查后的取指组，等后端来取 | 预测检查 | 后端 |

模型里这四个是 `FrontFifo<...>` / `FetchAddrFifo` 存储类加四个端口调度单元（`FetchAddrPort`、`PtabPort`、`InstPort`、`F2bPort`）：端口单元决定一拍的读写请求，存储类 `seq` 时应用。`InstPort::comb_read` 里还带着取指组的"头修正"（携带半字、丢非起点槽），那部分在 RTL 里是 `front_head_fix`，放在 [predecode.md](predecode.md)；`InstPort::comb_write` 里的展开、预译码、起点扫描在 `front_fetch_buf`，见 [front_top.md](front_top.md)。本文只讲队列本身。

RTL 只有一个队列实现 `front_fifo`，四个文件是它的端口适配（平铺端口 ↔ 打包结构体的条目）。

## 2. 配置（`ttg_cfg_pkg` / `front_pkg`，现行默认）

| 队列 | 深度 | 条目位宽（按字段手算，未综合验证） | "满"阈值 | 清空（refetch）来源 | 特别 |
| --- | --- | --- | --- | --- | --- |
| 取指地址队列 | 16（`FETCH_ADDR_FIFO_SIZE`） | 64（`XLEN_BITS`） | 15（`FETCH_ADDR_FIFO_FULL_AT`） | 全局 refetch | `drop_tail`、`head_fresh` |
| 指令队列 | 16（`INSTRUCTION_FIFO_SIZE`） | 1729（`inst_fifo_entry_t`） | 16 | 全局 refetch | |
| PTAB | 16（`PTAB_SIZE`） | 1526（`ptab_entry_t`：`BCK_W = 166`） | 15（RTL 不用） | 全局 refetch | 写读旁路（`FE_RFAST` 位 1） |
| front2back 队列 | 8（`FRONT2BACK_FIFO_SIZE`） | 2135（`f2b_fifo_entry_t`） | 8 | **只有后端**重定向 | |

位宽明细（`front_pkg` 结构体）：指令队列 = 全 16 槽的指令字 512 + 预译码类型 32 + 预译码目标 1024 + `inst_valid` 16 + `page_fault_inst` 16 + `is_rvc` 16 + `start_a` 16 + `start_b` 16 + `raw0` 16 + `up_ok` 1 + `seq_next_pc` 64；预测元数据 `pred_meta_t` = TAGE 标签 16×4×8 + 索引 16×4×10 + `pcpn` 16×3 + `alt_pred` 16 + 基址 64 = 1280；PTAB = 元数据 + `bpu_ck` 166 + `predict_dir` 16 + `predict_next_fetch_address` 64；front2back = 修正后下一地址 64 + 元数据 + `bpu_ck` + `slot_kind` 16×3 + 修正后方向 16 + `inst_valid` 16 + `page_fault_inst` 16 + `is_rvc` 16 + `carry` 1 + 指令字 512。各队列文件头注释里的"16 x 576b"、"16 x 2152b"、"32 x 2424b"、"16 x 32b"是旧值，不对。

## 3. 接口

四个队列共用一套端口形状（`front_fifo`）：

| 方向 | 信号 | 含义 |
| --- | --- | --- |
| 入 | `clear` | 清空（接 refetch） |
| 入 | `rd_en` / `wr_en` / `wdata` | 读使能（弹出队首）、写使能、写数据 |
| 入 | `drop_tail` | 丢最年轻的一项（只有取指地址队列接，其余接 0） |
| 出 | `rd_valid` / `rdata` | 读有效（`rd_en & !clear & !empty`，PTAB 加旁路）；队首数据（只在 `rd_valid` 时有意义） |
| 出 | `full` / `empty` / `size` | 拍初状态：`full = (count >= FULL_AT)`，`size` 是拍初占用 |
| 出 | `head_fresh` | 队首是上一拍才 push 的（只有取指地址队列用） |

`rdata` 是读指针指向的槽，读口**不**含"本拍刚写入"的数据（没有写穿），除非 PTAB 开了旁路。

## 4. 结构

```
 front_fifo #(DEPTH, W, FULL_AT, WR_AFTER_DROP, BYPASS)
    mem_q[DEPTH][W] + rd_ptr_q + wr_ptr_q + count_q        （环形缓冲，深度必须是 2 的幂）
    fresh_v_q + fresh_slot_q                                 （head_fresh）
 fetch_addr_fifo / inst_fifo / ptab / front2back_fifo : 端口适配 + 一个 front_fifo 实例
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `front_fifo.sv` | 108 | 通用队列：指针、计数、`head_fresh`、写穿旁路（参数）、溢出断言（仿真） |
| `fetch_addr_fifo.sv` | 34 | 取指地址队列；`WR_AFTER_DROP = (FE_BFAST & 3) != 0` |
| `ptab.sv` | 80 | PTAB；`BYPASS = (FE_RFAST & 2) != 0`；条目只存基址 |
| `inst_fifo.sv` | 89 | 指令队列；不存每槽 pc |
| `front2back_fifo.sv` | 106 | front2back 队列；只存基址和一位 `carry` |

状态：每个队列有三个寄存器（读指针、写指针、计数）加 `DEPTH × W` 的存储；存储不复位（只有读写指针之间的项会被当作有效数据读）；取指地址队列另有 `fresh_v_q`（1 位）和 `fresh_slot_q`（槽号）。

三个队列（PTAB、指令队列、front2back）条目里不存每槽的 pc：槽 i 的 pc 恒为基址 `+ 2*i`（`SLOT_BYTES * i`），只有 front2back 队列里的 `carry = 1`（槽 0 是用携带的半字拼出来的指令）时槽 0 是 `基址 - 2`。这样 PTAB 的 16 个 64 位 pc 缩成一个。

## 5. 一拍内的数据流

`front_fifo` 一拍内按固定顺序：清空 → 丢尾（`drop_tail`）→ 写（`wr_en`）→ 弹出（`rd_valid`）：

- `rd_valid = rd_en & !clear & (!empty | (BYPASS & wr_en))`；
- `drop_eff = drop_tail & !clear & !empty`；
- `count_d = (clear ? 0 : count) - drop_eff + wr_en - rd_valid`；`wr_ptr_d = wr_ptr - drop_eff + wr_en`；`rd_ptr_d = clear ? wr_ptr : rd_ptr + rd_valid`（清空后读写指针相等，随后的 push 落在队首槽）；
- 写落在 `wr_ptr` 槽（`WR_AFTER_DROP` 时落在 `wr_ptr - drop_eff`）。同拍既丢尾又 push 只有 `FE_BFAST != 0` 才会出现（那时 S0 在覆盖当拍重发）；现行配置 S2 覆盖那一拍 BPU 不发射，所以二者不会同拍。

### head_fresh：为什么有、怎么实现

BPU 的 S2 在检查一个块时发现它与 S0 / S1 的猜测不一致，就要"覆盖"：把比它年轻的块（此时在 S1，取指地址已经 push 进了取指地址队列）作废，即丢掉队列里最年轻的一项（`fa_drop_tail = bpu_override_squash`）。如果这个最年轻的项恰好是队首，且这一拍 I-Cache 正在弹它，就得先看这一拍的覆盖决定再决定能不能弹——这条路径从 BPU 的末级一直连到 I-Cache 的请求，是整个前端最长的路径之一。

现行做法（EXP-FEOVR，`4eb8f0e`）：一个地址 push 之后的下一拍不弹。能丢它的覆盖最迟发生在 push 后的下一拍（那时它所在的块在 S1，更老的块在 S2），到再下一拍它已经安全。实现：

- `fresh_v_q` = 上一拍有没有 push（`wr_en` 的寄存值）；`fresh_slot_q` = 上一拍写的槽号（`wr_ptr`，`WR_AFTER_DROP` 时减去丢尾）；
- `head_fresh = fresh_v_q & !empty & (fresh_slot_q == rd_ptr_q)`：队首就是上一拍写的那一项；
- `front_ctrl_enables` 的 `fa_rd_en` 含 `!fa_head_fresh`（见 [front_ctrl.md](front_ctrl.md)）。

队里有更老的项时，队首不是刚写的，不受影响；只有队列空时 push 的那个地址会比以前晚一拍进 I-Cache。模型对应 `CFG_FE_OVR_REG = 1`（模型用队首的 `head_age >= 1`，RTL 用一位）；16 个 SPEC 点几何平均 IPC -0.82 %（提交信息）。

### PTAB 旁路

`FE_RFAST` 位 1：S2 块同拍写 PTAB 时，检查器可以在同一拍读它（队列为空也行）。`ptab.sv` 把 `BYPASS` 传给 `front_fifo`，空时 `rdata = wdata`；`rd_valid` 加上 `BYPASS & wr_en`。其余三个队列不开旁路：取指地址队列和指令队列的读使能要求非空；front2back 队列的同拍旁路是单独的 `f2b_use_bypass`（见 [front_ctrl.md](front_ctrl.md)），不经过队列读口。

## 6. 关键路径与深度

单模块综合深度 **13 层**（fetch_addr_fifo；ptab、inst_fifo、front2back_fifo 更浅；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\u_fifo.count_q [2]` 到 `\u_fifo.count_q [4]`。队列本身是存储器读 + 指针加法，很浅。从代码读出的，未综合验证：值得看的是（1）`rdata = mem_q[rd_ptr_q]`（16 项 × 1729 位的读口选择）后面接着 `front_head_fix` 和检查器，见 [predecode.md](predecode.md)；（2）PTAB 开旁路后读口多了一级 `empty ? wdata : mem_q[...]`，而 `wdata` 来自 BPU 的 S2 选择结果（`bpu_main_sel`），所以 BPU 的 S2 → PTAB 旁路 → 检查器 → 冲刷是一条跨模块的长路径（这是 `FE_RFAST` 位 1 的代价）；（3）取指地址队列的 `head_fresh` 比较是 4 位槽号相等，很浅。

| 改动 | 提交 | 作用 |
| --- | --- | --- |
| 取指地址队列 push 后一拍才弹出 | `4eb8f0e` | `head_fresh`；断开 BPU 覆盖 → 弹出 → I-Cache 请求 |

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的：

- 模型的读口"空队列同拍写则返回写入项"（所有队列）：RTL 只给 PTAB 开（只有 PTAB 的读使能 `predecode_can_run` 允许在队列空时读）；
- 模型取指地址队列项里的 `pair`（`FE_PAIR` 第二块）和 `age`：没有；
- 模型 `drop_tail_n`（丢多项）：RTL 是一位，因为 `squash_n` 只会是 0 或 1（`BpuPipe::decide` 里是 `MAIN_LAT - 1 = 1` 级里有效块的个数）；
- 模型指令队列项存每槽 `pc[16]`、`raw16[16]`、`up16`：RTL 只存 `raw0` 和 `up_ok`，不存 pc（基址 + 2*i 推出），也不存 `up16`（RTL 的取指组窗口本来就带高半字，见 [icache.md](icache.md)）；
- 8 个 `*_full / *_empty` 锁存：RTL 不建，`full / empty` 由拍初计数算出；
- 溢出时模型 `fatal` 退出，RTL 只有仿真断言（`front_fifo`，`ifndef SYNTHESIS`）。

RTL 与模型保持一致的细节：

- 清空来源：前三个队列接全局 refetch（含预译码冲刷），front2back 队列只接后端重定向（模型 `f2b_in.refetch = redirect.valid`）。预译码冲刷后 front2back 里的项还在：触发冲刷的那一组本身在冲刷那一拍就以修正后的方向和下一地址写进了 front2back 队列（`f2b_wr_en = predecode_can_run`），被清的是它后面的取指和 PTAB 项；
- 读口无效（`rd_valid = 0`）时 `rdata` 是读指针所指的槽，没有意义，模型返回 0；下游都用使能门控。

未核对（继承自旧文档）：

- "指令队列条目数不超过 PTAB 条目数，所以不会满"：由 `front_fifo` 的溢出断言在仿真里保护，没有形式证明；
- 旧文档写 8 个锁存"在 73 个程序 126 万拍验证 0 不一致"：是旧分析的结果，本轮没有复现。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 67 个程序，周期对 `scripts/ref_cycles_memiq6_nr_int2_ev5.txt`：67/67 通过，周期逐个相等。队列深度、`full` 阈值、`head_fresh` 都由它间接检验（`head_fresh` 加入时周期表同步从 ev4 换成 ev5）。
- **仿真断言**：`front_fifo` 的溢出断言；深度非 2 的幂的编译期错误。
- **Linux / 指纹**：见 [front_top.md](front_top.md) 第 8 节。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**。**待补**：`front_fifo` 与一个参考队列（含 `drop_tail`、`head_fresh`、PTAB 旁路）的随机对拍，改队列结构时用。

## 9. 参数与开关速查

`FETCH_ADDR_FIFO_SIZE`、`INSTRUCTION_FIFO_SIZE`、`PTAB_SIZE`、`FRONT2BACK_FIFO_SIZE`、`FE_RFAST`（位 1：PTAB 旁路）、`FE_BFAST`（`WR_AFTER_DROP`，当前为 0）；`front_pkg`：`*_DEPTH`、`*_FULL_AT`；`front_fifo` 参数 `DEPTH`、`W`、`FULL_AT`、`WR_AFTER_DROP`、`BYPASS`。

## 10. 变更记录

- 2026-11-18（exp/agu-share）：`front_fifo` 加 `head_fresh`，取指地址队列在 push 后一拍才弹出 `4eb8f0e`。
- 更早：见 git 历史。
