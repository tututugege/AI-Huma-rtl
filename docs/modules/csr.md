---
module: csr
area: backend
rtl: rtl/backend/csr
spec: csr*
status: green
lockstep: 68/68
mutants: 15/15（6 仅随机）
note: 
---

# csr 设计笔记

> **更新（2026-11-12，rv64 / 现状）**：CSR 寄存器是 `XLEN_BITS` 位（`regs[NREG]`，`NREG = 18`），下文“32 位”均指 rv32。rv64 差异集中在 `csr_pkg`：`MISA_RESET`（MXL=2）、`MSTATUS_RESET`（SXL/UXL = 2）、`MSTATUS_WMASK` / `SSTATUS_MASK` / `SSTATUS_WMASK`（rv64 上 UXL 只读）；`satp` 的 Sv39 解码在 `tlb_mmu_pkg`（`satp_on` / `satp_asid`）。`rob_bcast_pc`、`trap_val`、`csr2front_epc/trap_pc` 都是 `XLEN` 位。`csr.sv` 的 `TTG_EBREAK_TRAP`（ROB 侧）打开后 ebreak 走断点异常，Linux 需要。PMU 计数器块（`rtl/pmu`）**没有**接到 CSR。

## 1. 对应的 C++
- `back-end/Exu/Csr.cpp`、`back-end/Exu/include/Csr.h`，类 `Csr`；调用点 `BackTop::comb()`：
  `comb_begin → comb_interrupt → (exu comb_to_csr) → comb_csr_read → comb_exception → comb_csr_write → … → comb_interrupt_inject`，`seq`；
  `comb_csr_status` 在 `SimCpu::cycle()` 开头调用（只读当前寄存器，录制点在 comb 之后、seq 之前，状态未变，因此 csr_status 是寄存器的纯函数）。
- 输入：`exe2csr{we,re,idx,wdata,wcmd}`（Exu 每拍 comb_begin 清零，故无残留）、`rob_bcast{mret,sret,ecall,page_fault_*,illegal_inst,trap_val,pc}`、
  `rob2csr{commit,interrupt_resp}`、`csr_interrupt_inject_io` 6 位（外设模型写，末尾 comb_interrupt_inject 读）。
- 输出及消费者：
  - `csr2exe.rdata`：仅 `Exu.cpp:460 if (u.op==UOP_CSR && exe2csr->re) u.result = rdata`。
  - `csr2rob.interrupt_req`：ROB。
  - `csr2front.epc`：`BackTop.cpp:350`（flush && (mret||sret)）、`rv_simu_mmu_v2.cpp:871`（同条件）。
  - `csr2front.trap_pc`：`BackTop.cpp:352`（flush && exception && !mret/sret）、`rv_simu_mmu_v2.cpp:873/892`（异常/中断提交时）。
  - `csr_status{sstatus,mstatus,satp,privilege}`：LSU/MMU/前端/br_oracle。

## 2. 硬件结构
```
 exe2csr ─► csr_wbuf (we/idx/wdata/wcmd 暂存，S/C 读改写) ──commit_fire,idx,wdata──┐
 rob2csr.commit ──────────────────────────────────────────────────────────────────┤
 rob_bcast ─► csr_trap (特权级寄存器, trap/xRET 状态机, cause 优先级, trap_pc/epc) ─┤► csr_regfile (18 个 32 位 CSR 寄存器,
 csr_irq (pending/委托/使能) ──────────────────────────────────────────────────────┘   写合并: inject > commit 写 > trap)
 csr_read ×2 (地址表驱动读口：exe2csr.idx → rdata；暂存 idx → S/C 的旧值)
```
- 子模块：`csr_pkg`（地址表/掩码表/位位置）、`csr_irq`（6 类中断 pending + interrupt_req）、`csr_trap`（见上）、`csr_cause_sel`（优先级选 cause 码）、
  `csr_trap_target`（direct/vectored 目标 PC）、`csr_wbuf`、`csr_read`、`csr_regfile`、顶层 `csr`（只做端口适配）。
- 状态：18 个 32 位寄存器 = C++ 21 个减去 3 个影子寄存器；`privilege_q`(2)；暂存写 `we_q,idx_q(12),wdata_q(32),wcmd_q(2)`。
- C++ → 硬件对应：
  - `CSR_RegFile[csr_sstatus/csr_sie/csr_sip]` 在 C++ 里恒等于 `mstatus & 0x800DE133` / `mie & 0x333` / `mip & 0x333`
    （复位全 0；每个写路径——csr 写、trap、xRET、inject——都同步更新影子寄存器，核对 Csr.cpp 全部 `_1[csr_s*]` 赋值），所以 RTL 不保存，
    读/写走"视图"：表项 `{地址, 目标寄存器, 写掩码, 读掩码}`，`sstatus→mstatus(0x800DE133)`、`sie→mie(0x333)`、`sip→mip(0x333)`。
  - 一长串 if-else 的 CSR 写 → 表驱动：命中向量 `hit[e]` → 目标寄存器写使能 + 写掩码，`new=(old&~mask)|(wdata&mask)`；
    C++ 里 mie/mip/mstatus 的 M 视图写（`wdata & mask`、`(old&~mask)|(w&mask)`）在 mie/mip 只含 mask 内位（复位 0，所有写入都带掩码）的前提下与统一公式相同。
  - `cvt_number_to_csr` 的 abort（未知/time/timeh 地址）：不复刻，读 0。
  - `comb_csr_write` 里对 `csr_wdata`（寄存器）的原地修改：seq 时被 `csr_wdata_1` 覆盖，无效果，不复刻。
  - `debug_ptw_trace::record_satp_write`：调试，不翻译。

## 3. 一拍内的数据流（谁覆盖谁）
所有读都读寄存器当前值（`CSR_RegFile`，不是 `_1`），所以只有"写合并"有顺序：
1. `_1 = 当前值`；
2. `comb_exception`：m_trap（mepc/mcause/mtval/mstatus/priv=M）> s_trap（sepc/scause/stval/mstatus/priv=S）> mret > sret（else-if 链）；
3. `comb_csr_write`：commit && we_q 时按**旧值**重算目标寄存器整字，覆盖 2 的同一寄存器写；并 `csr_we_1=0`；
4. `comb_interrupt_inject`：在 3 的结果上对 mip[11/9/7] 做 RMW，最后赢。
= RTL 的 per-register 写合并：inject > commit 写 > trap > 保持。
- 暂存写：`exe2csr.we` 更新 idx/wdata/wcmd 并置 we；若同拍 `commit && we_q`，C++ 先置 1 后清 0，**新请求的 we 丢失**（idx/wdata/wcmd 仍被覆盖）。
  RTL 复刻为 `we_d = (commit&&we_q) ? 0 : exe_we ? 1 : we_q`（见第 4 节，登记疑点；先看 trace 是否出现）。
- cause 选择里的怪处（均按 C++ 复刻）：
  - bit31（中断标志）由"有 m 类中断 pending"决定，而不是由 `interrupt_resp` 决定；
  - M 态 ecall 的 cause=11 条件带 `!medeleg[8]`（U-ecall 的委托位），medeleg[8]=1 时 M-ecall 的 cause 落到 0/2；
  - `illegal_inst` 的 cause 分支不看委托位；
  - S trap 的 cause 优先级里 ecall-S 与 s_ext 并列且先于 s_timer。

## 4. 与 C++ 的差异点、放宽与消费者核对
**放宽（`when`）**——`when` 只能引用输出，所以加了三个限定输出（`*_vld`），RTL 里是常量表达式/直通：
| 字段 | 限定 | C++ 为什么无意义 | 消费者核对 |
| --- | --- | --- | --- |
| `csr2exe_rdata` | `csr2exe_rdata_vld` = 输入 `exe2csr_re`（直通；`@ bt.exe2csr.re`） | C++ 仅 `re` 时写 rdata，其余拍保持上拍值（`BackTop` 的清零开关 `CONFIG_BE_IO_CLEAR_AT_COMB_BEGIN=0`） | 只有 Exu.cpp:460，受 `re` 保护 |
| `csr2front_epc` | `csr2front_epc_vld` = RTL 的"mret/sret 实际生效"（`@ rob_bcast.mret\|\|sret`，**严格比较**，不是直通） | 仅 mret/sret 分支写 epc | BackTop.cpp:350、rv_simu_mmu_v2.cpp:871，均受 `mret\|\|sret` 保护 |
| `csr2front_trap_pc` | `csr2front_trap_pc_vld` = RTL 的"m_trap\|\|s_trap"（`@ rob_bcast.exception`，严格比较） | 仅 trap 分支写 trap_pc | BackTop.cpp:352、rv_simu_mmu_v2.cpp:873/892，受 `exception` 保护 |
后两个 vld 是 RTL 自己算的，因此同时交叉验证了"ROB 的 exception/mret/sret 标志 与 Csr 自己判定的 trap/xRET 一致"。

**删除**：输入侧未读的 `rob_bcast.{flush,exception,fence,fence_i,interrupt,head_*}` 不接（`exception` 只作为 `*_vld` 的 C++ 表达式，不是端口）；`exe2csr.wcmd` 宽度由 32 收为 2（Exu 恒为 `func3&3`，C++ 里也被 `reg<2>` 截断）；影子寄存器 `sstatus/sie/sip` 不建（见第 2 节）。

**不复刻**：未知 CSR 地址 abort；`csr_wdata` 原地修改（无效果）；`debug_ptw_trace`；`restore_from_ref`/checkpoint 恢复路径（不在录制范围，复位后即从 init 状态起）。

**登记/疑点（按 C++ 复刻，无偏差）**：
1. 同拍 `commit&&we_q` 与新 `exe2csr.we`：新写请求丢失（Csr.cpp `comb_csr_write` 先置后清 `csr_we_1`）。
2. cause 里 M-ecall 的 11 带 `!medeleg[8]`；中断位由 pending 而非 resp 决定（见第 3 节）。
3. `mhartid`/`misa` 可被 csrw 改写（真实硬件只读/WARL）；RTL 保持可写以与 C++ 一致（同一张表，零额外成本）。
4. mret 把 `privilege_1` 设为 `MPP` 原值（可能是保留值 2）。

## 5. 验证
- spec：`spec/csr.io`，输入 22 个、输出 11 个（含 3 个限定输出）。C++ 22 个 IO 字段中输入侧删去 `rob_bcast` 的 flush/exception/fence/fence_i/interrupt/head_*（共 8 个）与 `csr_status` 之外无其他。
- trace：61 个 gate 测试 + dhrystone/coremark/coremark10/4 个 vm/float/sha/cjpeg/linear_alg/parser，共 73 个真实程序（约 76.3 万拍），
  + 4 个随机 trace `rand0..3`（各 6 万拍，`tests/csr/rand_trace.cpp` + `tests/csr/run_rand.sh`，直接驱动参考模型 `Csr` 类，不加 `-DNDEBUG`）。全部 PASS。
- 真实程序覆盖（统计自 trace）：ecall 8 次（U 1/S 4/M 3）、page fault 各 1、illegal 2、mret 18、sret 5、interrupt_resp 5（S 2/M 3）、
  csr 写 127 次（wcmd W/S/C 都有）、CSR 写过的地址 14 个、读过的 15 个、特权级 U/S/M 都出现、satp 开启 11710 拍、
  inject 的 timer/supervisor-external 取过 0/1（`external_irq_pending` 全程 0）。
  **覆盖不到的（只靠随机 trace）**：M 态/U 态 ecall 与各委托位的组合、vectored 目标在多种 cause 下、`illegal` 与委托、mepc/sepc/mcause/scause 的大多数组合、
  sie/sip/sstatus 别名写、mip 软件写、外部中断注入为 1、`wcmd=S/C` 在大多数 CSR 上、同拍 `commit && 新 exe_we`、trap 与 CSR commit 同拍。
- 随机生成器约束（依据 Rob.cpp comb_commit 436-470）：每拍至多一个事件（interrupt_resp 仅在 `csr2rob.interrupt_req` 时、ecall、mret、sret、3 种 page fault、illegal），
  `rob_bcast.exception = ecall|pf|illegal|resp`，resp 时其他事件位为 0；CSR commit 只在无事件的拍（profile 3 例外：与事件/新写请求同拍，用来钉住参考模型的合并优先级，
  真实 ROB/EXU 不会产生）；`mret` 在 `MPP==2`（保留特权级）时不发（该状态下 C++ 的 `trap_pc` 对 ecall 是残留值，且 ROB 的 exception 标志与 Csr 判定不一致）；
  CSR 地址只用 21 个合法地址（未知地址 C++ abort）。
- 变异（共 15 个非等价，全部被抓；"只有随机抓到"=真实 73 个程序都过）：
  | # | 变异 | 真实程序抓到 | 随机抓到 |
  | --- | --- | --- | --- |
  | m1 | 去掉 M-ecall cause=11 的 `~medeleg[8]` | 无 | rand0 rec 10717 `csr2exe_rdata`(mcause) |
  | m2 | S 中断使能去掉 `sstatus.SIE` | software-interrupt-vectored rec 382 `csr2rob_interrupt_req` | rand0 rec 1912 同 |
  | m3 | sret 的新特权级恒为 S | supervisor-trap-delegation rec 340 `csr_status_privilege` | rand0 rec 104 同 |
  | m4 | 同拍 commit 不清除新 exe 的 we（去掉丢弃行为） | 无 | rand3 rec 178 `csr2front_trap_pc` |
  | m5 | 写合并优先级 trap 高于 commit 写 | 无 | rand3 rec 140 `csr_status_sstatus` |
  | m6 | vectored 偏移 4*code → 2*code | interrupt-vectored rec 2198 `csr2front_trap_pc` | rand0 rec 2220 同 |
  | m7 | `SSTATUS_MASK` 末位改 | 无 | rand0 rec 127 `csr_status_sstatus` |
  | m8 | S 中断 cause 优先级 timer/external 互换 | supervisor-external-interrupt-vectored rec 236 `csr2front_trap_pc` | rand0 rec 2208 mcause 读 |
  | m9 | mret 后 MPP 置 M 而不是 U | illegal-instruction-trap rec 213 `csr_status_mstatus` | rand0 rec 148 同 |
  | m10 | illegal 不写 mtval | illegal-instruction-trap rec 171 `csr2exe_rdata` | rand0 rec 2725 同 |
  | m11 | 定时器 inject 取反 | interrupt-vectored rec 187 `csr2rob_interrupt_req` | rand0 rec 106 |
  | m12 | M 中断不看 `~mideleg` | 无 | rand0 rec 1911 `csr2front_trap_pc` |
  | m14 | csrrc 的 `~w & old` 改成 `w & ~old` | csr-alias-boundary rec 285 `csr2exe_rdata` | rand0 rec 99 |
  | m15 | `SIE_MASK` 0x333 → 0x233 | 无 | rand0 rec 225 `csr2exe_rdata` |
  | m16 | S trap 不看 `interrupt_resp` | software-interrupt-vectored rec 374 `csr2front_trap_pc_vld` | rand0 rec 173 同 |
  等价变异（不计）：mret/sret 同拍优先级（m13，需 mret 与 sret 同时为 1，ROB 不会）、`trap_pc` 在无 trap 时的选择（m17，该值不被比较）。
  只靠随机 trace 才能抓到：6 个（m1 m4 m5 m7 m12 m15）。

## 中断 CSR 的规范语义（2026-11-04）

与 function-model、trace-model 一致：`mie`/`mip` 写掩码 0xAAA（无用户级位），`mideleg` 写掩码 0x222，`sie`/`sip` 读写都按 `mideleg` 屏蔽（`csr_pkg::ENT_DELEG`），
`sip` 只能写 SSIP。`csr_regfile` 把 `regs_q[R_MIDELEG]` 并进这两个别名条目的写掩码，`csr_read` 并进读掩码。
