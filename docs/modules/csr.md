---
module: csr
area: backend
rtl: rtl/backend/csr
model: trace-model Csr.cpp、include/Csr.h（类 `Csr`，全局 `csr_state()`）。它不是调度单元：没有 comb 阶段，只有时钟沿的 `seq`；状态视图、读口和"本拍提交的陷入 / xRET 目标"（`trap_out`）都是寄存器的函数
status: 整核周期与模型逐个相等（fm_gate.sh 77/77，周期对 scripts/ref_cycles.txt）
depth: 29 层（csr，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）
---

# csr 设计文档

## 1. 职责

CSR 文件（控制和状态寄存器）、当前特权级、待处理中断的判断、陷入和 xRET 的状态机。做五件事：

1. **读**：CSR 指令执行时按 CSR 号读出当前值（`csr2exe_rdata`，同拍、组合），由 `exu_ctrl` 当作结果写回；
2. **写**：CSR 指令执行时只把写请求（CSR 号、写数据、命令）暂存起来，等 ROB 提交这条指令时（`rob2csr_commit`）才真正写寄存器；`csrrs` / `csrrc` 的读改写在提交时用当时的旧值做；
3. **陷入和 xRET**：ROB 在提交异常、中断、`ecall`、`mret`、`sret` 的那一拍给出 `rob_bcast_*`，CSR 同拍算出陷入目标 `csr2front_trap_pc` 和返回目标 `csr2front_epc`，并在时钟沿更新 `mepc / mcause / mtval / mstatus`（或 S 级的对应寄存器）和特权级；
4. **中断**：根据 `mip / mie / mideleg / mstatus` 和特权级判断有没有可响应的中断（`csr2rob_interrupt_req`），外部中断线（`interrupt_inject_*`）直接改 `mip` 的对应位；
5. **状态输出**：`csr_status_{mstatus, sstatus, satp, privilege}` 给 DTLB、LSU、前端等；浮点：`csr2exe_frm`（动态舍入模式）、`csr2rob_fs_off`（`mstatus.FS == Off`），并累积 `fflags`、维护 `FS` 的 Dirty。

术语：**M 级陷入 / S 级陷入**指陷入由机器级还是监管级处理（由 `medeleg` / `mideleg` 决定，M 级优先）；**视图**指 `sstatus / sie / sip` 这类并不单独存储、而是 `mstatus / mie / mip` 的一部分。

## 2. 配置（`csr_pkg` / `ttg_cfg_pkg`，现行默认）

- 存储的寄存器 `NREG = 19`（`csr_pkg::R_*`）：`mtvec`、`mepc`、`mcause`、`mie`、`mip`、`mtval`、`mscratch`、`mstatus`、`mideleg`、`medeleg`、`sepc`、`stvec`、`scause`、`sscratch`、`stval`、`satp`、`mhartid`、`misa`、`fcsr`（`{frm[2:0], fflags[4:0]}`，只在有 F/D 时有意义）。`sstatus`、`sie`、`sip` 是视图，不存储。模型 `CSR_NUM = 22`（`ttg_cfg_pkg`）把这三个也存了；
- CSR 号表 `NENT = 24`（`ENT_ADDR`）：18 个整数核寄存器各一项，加 `sstatus`、`sie`、`sip` 三个视图，共 21 项；再加 `fflags`（0x001）、`frm`（0x002）、`fcsr`（0x003）三项（都落在 `fcsr` 寄存器上）。每项有写掩码 `ENT_WMASK`、读掩码 `ENT_RMASK`、在寄存器里的移位 `ENT_SHIFT`（`frm` 在 `fcsr` 的第 5 位起）、是否带派生的 SD 位 `ENT_SD`、是否再按 `mideleg` 屏蔽 `ENT_DELEG`；
- 复位值：`misa = 0x8000000000141103`（`MXL = 2`，A、B、I、M、S、U）加 F、D（`0x28`，F/D 总是有）加 C（`RVC_ENABLE`，`0x4`）；`mstatus = 0xA00000000`（`UXL = SXL = 2`）；特权级 M；其他 0；
- `mstatus` 写掩码 `0x7FF9BB`，`sstatus` 读掩码 `0x3000DE133`、写掩码 `0xDE133`；`mie` / `mip` 写掩码 `0xAAA`，`mideleg` 和 `sie` 视图 `0x222`，`sip` 只能写 `SSIP`（`0x2`）；
- `satp`：只实现 Bare（0）和 Sv39（8），写其他模式无效；
- 中断：三类（软件、定时器、外部），`mip` 中 M 级位 3、7、11，S 级位 1、5、9。

`ttg_cfg_pkg.sv` 目前是手工编辑的，与 `make cfg` 生成的不同步（待统一，见 docs/TODO.md）。

## 3. 接口

| 方向 | 信号组 | 含义 |
| --- | --- | --- |
| 入 | `exe2csr_{we, idx, wdata, wcmd}` | `exu_ctrl` 的 CSR 请求：`we` 要写、`wcmd` 为 `func3[1:0]`（`10` 置位、`11` 清位，其余直接写） |
| 入 | `rob2csr_commit` | 一条 CSR 指令这拍提交 |
| 入 | `rob2csr_interrupt_resp` | ROB 响应一次中断 |
| 入 | `rob2csr_fflags`、`rob2csr_fs_dirty` | 浮点：这拍提交的指令累积的异常标志；有指令使 `FS` 变 Dirty |
| 入 | `rob_bcast_{mret, sret, ecall, breakpoint, page_fault_inst, page_fault_load, page_fault_store, illegal_inst, trap_val, pc}` | ROB 的陷入广播，**不经 FLUSH_REG 推迟**，和 ROB 的决定同一拍 |
| 入 | `interrupt_inject_{software, external, supervisor_external, timer}_irq_pending` 及各自的 `_valid` | 外部设备（CLINT/PLIC）的中断线：`_valid` 为 1 时把对应 `mip` 位（`MSIP`/`MEIP`/`SEIP`/`MTIP`）设为 `pending` 的值 |
| 出 | `csr2exe_rdata` | CSR 读出值 |
| 出 | `csr2rob_interrupt_req` | 有可响应的中断 |
| 出 | `csr2front_trap_pc`、`csr2front_epc` | 陷入目标、xRET 目标 |
| 出 | `csr_status_{mstatus, sstatus, satp, privilege}` | 状态；`back_top_glue` 另从 `mstatus` 切出 `MXR`、`SUM`、`MPRV`、`MPP` 给 DTLB |
| 出 | `csr2exe_frm`、`csr2rob_fs_off` | 浮点 |

模型 `Csr` 没有端口：读口是 `read(idx)`，状态是 `status` 结构。

## 4. 结构

```
 exe2csr ─► csr_read（执行时读口：CSR 号 → 值）──────────────────────────► csr2exe_rdata
 exe2csr ─► csr_wbuf（暂存 we / idx / wdata / wcmd）─ rob2csr_commit ─► commit_fire、commit_idx、commit_wdata ┐
            └ csr_read（第二个读口：暂存的 idx 的旧值，做 csrrs / csrrc 的读改写）                         │
 rob_bcast_* ─► csr_trap（特权级寄存器、陷入分类、cause 选择、目标 pc、mstatus 更新）─ 写请求 ─────────────┤► csr_regfile（19 个寄存器，写合并）
                 ├ csr_trap_class ─ csr_cause_sel × 2     └ csr_trap_target × 2（M 级、S 级）               │
 csr_irq（pending 判断）─► csr2rob_interrupt_req、m_pending / s_pending                                    │
 interrupt_inject_*、rob2csr_fflags、rob2csr_fs_dirty ─────────────────────────────────────────────────────┘
```

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `csr_pkg.sv` | 137 | 寄存器编号、CSR 号表和掩码表、特权级、`mstatus` 位置、中断位位置、`medeleg` 位 |
| `csr.sv` | 106 | 顶层：连线，状态输出，`csr2rob_fs_off`、`csr2exe_frm` |
| `csr_regfile.sv` | 111 | 19 个寄存器和写合并 |
| `csr_read.sv` | 31 | 一个读口：CSR 号 → 经视图掩码的值，表驱动；未知 CSR 号读 0 |
| `csr_wbuf.sv` | 64 | 写请求暂存和提交时的读改写 |
| `csr_irq.sv` | 39 | 待处理中断 |
| `csr_trap.sv` | 131 | 特权级寄存器、陷入 / xRET 状态机、寄存器写请求 |
| `csr_trap_class.sv` | 80 | 陷入属于哪一级、cause 码的优先级条件表 |
| `csr_cause_sel.sv` | 21 | 按优先级选 cause 码（`ttg_first_set` + 独热选择） |
| `csr_trap_target.sv` | 18 | 陷入目标：向量模式下中断为 `基址 + 4 × cause` |

状态：`regs_q[19]`（每个 64 位）；`privilege_q`（2 位，复位为 M）；暂存的写请求 `we_q`、`idx_q`（12 位）、`wdata_q`（64 位）、`wcmd_q`（2 位）。

## 5. 一拍内的数据流

### 5.1 读和暂存写（CSR 指令在槽里的那一拍）

`csr_read`：每项做 12 位地址比较，值 = `(寄存器 >> 移位) & 读掩码`，`sie`、`sip` 再与 `mideleg` 相与，`mstatus` 和 `sstatus` 视图在 `FS == Dirty` 时把第 63 位（SD）置 1（派生，不存储），独热选择输出。同拍 `exu_ctrl` 用它覆盖 CSR 指令的结果。`csr_wbuf`：`exe2csr_we` 为 1 时 `idx`、`wdata`、`wcmd` 覆盖暂存，`we_q` 置位。

### 5.2 提交

`commit_fire = rob2csr_commit && we_q`。提交值：`wcmd == 10` 时 `wdata | 旧值`，`11` 时 `~wdata & 旧值`，否则 `wdata`；旧值来自第二个读口（暂存的 `idx`）。`csr_regfile` 对每个寄存器合并写请求：命中它的 CSR 号项给出写掩码（`sie` / `sip` 再按 `mideleg` 屏蔽）和移位后的值；`satp` 只在模式为 0 或 8 时接受。暂存在提交、或在 `rob_bcast_illegal_inst`（`FS == Off` 时执行了浮点 CSR，非法指令）时清掉。

### 5.3 陷入和 xRET

`csr_trap_class` 判断：`m_trap = (M 级可响应中断 && interrupt_resp) || 各异常按 medeleg 未委托的`；`s_trap` 为委托给 S 级的。同拍 M 优先：`m_trap` > `s_trap`（仅 S）> `mret` > `sret`。结果：`csr2front_trap_pc`（`m_trap` 时用 `mtvec`，否则 `stvec`）和 `csr2front_epc`（`mret` 用 `mepc`，否则 `sepc`）都是当前寄存器的函数，不是下一拍的值；寄存器写请求：`mepc` 或 `sepc` 取 `rob_bcast_pc`，`mcause` 或 `scause` 为 `{是否中断, 0, cause 码}`，`mtval` 或 `stval` 对缺页、非法指令、断点取 `rob_bcast_trap_val`、其余取 0，`mstatus` 按陷入、`mret`、`sret` 各自更新 `MPP / MPIE / MIE`（`SPP / SPIE / SIE`）；特权级陷入时变 M 或 S，`mret` 取 `MPP`，`sret` 取 `SPP`。

### 5.4 中断

`csr_irq`：M 级 = `(mip & mie)` 且不委托且（特权级低于 M 或 `mstatus.MIE`）；S 级 = （`mip & mie` 且委托）或（S 级自己的位 `mip & mie`），且（特权级为 U，或为 S 且 `sstatus.SIE`）。`csr2rob_interrupt_req` 是两者之或。外部中断线在时钟沿改 `mip` 的 `MEIP`、`SEIP`、`MTIP`，优先级最高。

### 5.5 写合并和浮点

每个寄存器的写合并，低到高：保持 < 陷入 / xRET < 提交的 CSR 写 < （仅 `mip`）中断线注入；浮点再叠加：`fcsr` 的低 5 位或上 `rob2csr_fflags`，`rob2csr_fs_dirty` 或对 `fflags / frm / fcsr` 的提交写使 `mstatus.FS = Dirty`（`2'b11`）。

## 6. 关键路径与深度

单模块综合深度 **29 层**（csr；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC="strash;balance;map"`，生成门代理，不是时序）。综合报告给出的最长路径：从 `\exe2csr_idx [7]` 到 `\csr2exe_rdata [1]`。，本模块没有单独综合过。以下是从代码读出的，未综合验证：

| 路径 | 内容 |
| --- | --- |
| 陷入 → 目标 pc | `rob_bcast_*` → `csr_trap_class`（M / S 判定、cause 条件）→ `csr_cause_sel` → `csr_trap_target`（64 位加法，向量模式）→ `trap_pc` 选择 → `csr2front_trap_pc` → `back_top_glue` 的 `flush_redirect_pc` → `redirect_pc_q` 的寄存器和 `out_commit_entry_uop_diag_val`（组合输出到芯片边界）。全局 flush 晚一拍（`FLUSH_REG`）之后这条路径不再进其他模块的数据通路，但 `diag_val` 这一路仍是组合输出 |
| 中断请求 | 寄存器 → `csr_irq` → `csr2rob_interrupt_req` → ROB |
| 读口 | `exe2csr_idx` → 24 路地址比较 → 独热选择 → `csr2exe_rdata` → `exu_ctrl` 写回选择 |

本模块在本分支没有改动。

## 7. 与模型的差异和取舍

模型里有、RTL 里有意没有复刻的，或两边不同的：

- **写的来源**：模型的 CSR 写由 ROB 在提交时给出（`rob2csr.{we, idx, wcmd, wdata}`，写数据取自 trace 的 `csr_wdata` 事实）；RTL 没有 trace，由 CSR 指令在执行时算出写数据，在 `csr_wbuf` 暂存，提交时才写，并在 `illegal_inst` 时丢弃暂存（模型里非法指令优先于 CSR 提交，根本不提交）；
- **存储方式**：模型存 22 个寄存器（`sstatus`、`sie`、`sip` 也存，写时同步更新）；RTL 存 19 个，三个视图读时现算；`mstatus.SD` 模型存储并随 `FS` 更新，RTL 只在 CSR 读口派生。因此 RTL 的 `csr_status_mstatus`、`csr_status_sstatus` 输出没有第 63 位，模型的 `status.mstatus` 有；芯片内部的使用者（`back_top_glue` 只取第 19、18、17、12:11 位，DTLB 取 `satp`、`privilege`）不受影响，芯片边界上的使用者本文没有核对；
- **浮点 CSR**：模型里 `fflags / frm / fcsr` "不含值"（只占一个寄存器，写读照常）；RTL 真实累积 `fflags`、保存 `frm`、维护 `FS`；
- **未知 CSR 号**：模型遇到未知号或 `time / timeh` 直接中止；RTL 读 0、写没有命中项即无效；
- **cause 优先级**：模型 M 级里 `ebreak` 断点在"非法指令"之前，RTL 的 `csr_trap_class` 把非法指令排在断点前面（S 级同样）；同一条指令不会同时带这两个标志，所以实际无差别，本文没有从 ROB 一侧证明不会同时出现；
- **断点异常总是开**：ROB 把 `ebreak` 报成断点异常（cause 3，`mtval = pc`，`rob_trap_ctrl`），没有开关；
- **PMU**：`csr_pkg::ENT_ADDR` 里没有计数器 CSR；`core_top.sv` 的注释说 PMU 计数器还没有接到 CSR。

RTL 与模型保持一致的细节（读模型时容易误判为 bug）：

- `mcause` 的最高位 = "M 级有任何待处理中断"（`m_is_irq`），不看 `interrupt_resp`，与模型 `is_irq = irq.to_m()` 一致；
- 非法指令的 cause 码选择不看 `medeleg`，M 级的 `ecall_m` 在 `medeleg[8] == 0` 时才取 11（模型同）；
- 断点异常：`medeleg[3]` 委托在 M 级时无效（`d_bp = medeleg[3] && privilege != M`）；
- `mret` 之后 `MPP` 清成 U，`MPIE` 置 1；`sret` 之后 `SPP` 清成 U，`SPIE` 置 1。

未核对（继承自旧文档）：

- 旧文档说"`csr_wbuf`：同拍到达的下一条 CSR 写会被提交清掉，这是参考模型的行为"：当前模型没有执行级暂存，无法对照；本文只读了 `csr_wbuf.sv`（`we_d = (commit_fire | drop) ? 0 : (exe_we | we_q)`）；
- 旧文档的变异检查（15/15）和 trace 回放结果：随 `spec/` 退役。

## 8. 验证

- **门禁**：`scripts/fm_gate.sh` 77/77，每条提交对比函数模型，周期对 `scripts/ref_cycles.txt`。名字对得上本模块的有：`csr-alias-boundary`（`sstatus / sie / sip` 视图）、`trap-boundary`、`illegal-instruction-trap`、`interrupt-vectored`、`software-interrupt-vectored`、`supervisor-external-interrupt-vectored`、`supervisor-trap-delegation`、`supervisor-illegal-delegation`、`timer-interrupt-mask`、`timer-mmio`、`wfi-boundary`、`fd-*`（`FS`、`fflags`）；没有逐个核对每个程序实际覆盖了哪些分支。
- **Linux**：`scripts/linux_gate.sh`（Linux 启动到 `login:`，逐条提交检查，且对比模型的 PMU 数字）会走 S 级陷入、`satp`、定时器中断；断点异常总是开。
- **Lint**：`scripts/lint_chip.sh` 0 告警。
- **没有模块级的独立测试**：旧的 trace 回放和变异检查随 `spec/` 退役。**待补**：给 `csr_trap_class` / `csr_cause_sel`（cause 优先级、委托组合）、`csr_regfile` 的写合并（`satp` 非法模式、`sie / sip` 与 `mideleg`、`fcsr` 各视图）补和模型 `Csr::exception`、`Csr::csr_write` 并排的随机测试。

## 9. 参数与开关速查

`XLEN_BITS`、`RVC_ENABLE`、`FPRF_NUM`（`ttg_cfg_pkg`；F/D 总是有）；`NREG`、`NENT`、`ENT_*` 表、`MISA_RESET`、`MSTATUS_RESET`、`MSTATUS_WMASK`、`SSTATUS_MASK`、`SSTATUS_WMASK`（`csr_pkg`）。没有开关。

## 10. 变更记录

- 2026-11-28 清理：删 `FP_EN`（F/D 总是有，`NENT_MAX` 并入 `NENT = 24`）、输出 `csr2exe_rdata_vld` / `csr2front_epc_vld` / `csr2front_trap_pc_vld` 与输入 `exe2csr_re`（`back_top` 无人读）、`csr_trap` 的 `trap_taken` / `xret_taken` 输出口（`trap_taken` 改内部线）、ROB 侧宏 `TTG_NO_EBREAK_TRAP`；删不抑制任何告警的 lint 豁免（`csr_cause_sel.sv` 1 处，以去掉豁免后整树 lint 普通 / `-DSYNTHESIS` 均无新告警为准）（周期不变）。
- 2026-11-28（`rtl/fe-2ahead`，文档核对）：断点异常宏统一为 `TTG_NO_EBREAK_TRAP`（默认开启断点异常）；门禁改为 77/77 对 `scripts/ref_cycles.txt`。
- 2026-11-26（`rtl/soc-env`）：新增 `MIP_MSIP`（bit 3）与 `interrupt_inject_software_irq_pending(_valid)` 端口，接入真实片上 CLINT 软中断；`soc_top` 默认绑 0，对 `fm_gate` 零影响。
- 本分支（exp/agu-share，`261bd67..HEAD`）：本目录没有改动。
- 2026-11-12：rv64（寄存器 `XLEN_BITS` 位、`misa` / `mstatus` 复位值和掩码）；F/D（`fcsr`、`FS`、`csr2exe_frm`、`csr2rob_fs_off`）。
- 更早：见 git 历史。
- 2026-11-29 清理：`csr_pkg` 删包级 `lint_off UNUSEDPARAM` 豁免（`scripts/lint.sh` 改为只编所需的包，包常量是否未用只在整芯片 lint 判定，见 `docs/01-rtl-coding-standard.md` 8.5；整芯片 lint 普通 / `-DSYNTHESIS` 下无死常量）（周期不变）。
