> **历史登记（2026-11-04 起不再新增）**：这是旧体系下 RTL 与旧参考模型的差异登记（“任何一拍不同都要登记”）。现在 RTL 只要求与 function-model 逐条提交一致（[06-equivalence-policy.md](06-equivalence-policy.md)），微架构差异不再登记。表里的 S 编号仍被模块笔记引用，所以文件保留在原处。

# 偏差登记（Deviations）

RTL 与参考模型在任何一拍、任何一位上不同，都必须登记在此。**默认不允许有偏差**；每条偏差需要评审人书面批准，批准后才能在 RTL 里出现 `// DEVIATION D-<n>`。

## 已批准偏差

| 编号 | 模块 | 描述 | 原因 | 影响（哪些信号/哪几拍不同） | 批准人/日期 |
| --- | --- | --- | --- | --- | --- |
| （暂无） | | | | | |

## BPU 流水化（exp/bpu-pipe-rtl）的假设

| 编号 | 模块 | 内容 | 处理 |
| --- | --- | --- | --- |
| B-1 | bpu_ub_track | 并行形式假设一拍内的提交车道是程序顺序上连续的有效前缀（只有 0 号车道可以相对上一拍状态不连续）；与模型的逐车道串行版在该前提下逐位等价（随机对拍 300 万拍） | 仿真里有时钟采样断言；违反时需要改回串行形式 |
| B-2 | bpu | 行为与模型逐周期相等，无偏差；结构差别见 docs/analysis/bpu-pipe-rtl.md 第 2 节 | 不登记为偏差 |

## 参考模型疑点（按参考模型行为实现，等待评审决定）

| 编号 | 模块 | C++ 位置 | 现象 | 当前处理 |
| --- | --- | --- | --- | --- |
| S-1 | Idu | Idu.cpp `comb_branch` | `br_id=0` 的误预测使用 `cp[0]=0`，回收全部在飞 tag（包括更老的）；真实程序没出现 | 保持 C++ 行为 |
| S-2 | Idu | `comb_branch` | `clear_mask` 的 bit0（br_id=0 的已解析分支）被广播但状态逻辑忽略 | 保持 |
| S-3 | Ren | Ren.cpp `comb_fire` | mispred 时 `free_tail_1 = free_tail` 丢掉同拍 commit 的前进；C++ 自带 sanity 在该组合下失败，疑为不可达 | 不复刻，按自然行为实现 |
| S-4 | Csr | `comb_csr_write` | 新 `exe2csr.we` 与同拍 `commit && csr_we` 同时出现时新请求的 we 丢失 | 保持 |
| S-5 | Csr | `comb_exception` | mcause 的"中断位"由有无 M 类中断挂起决定而非 `interrupt_resp`；M-ecall 的 cause 判断用了 U-ecall 的委托位 `medeleg[8]`；illegal 的 cause 不看委托位 | 保持 |
| S-6 | Csr | `comb_exception` | mret 把特权级设为 MPP 原值，MPP 可被写成保留值 2，之后行为异常 | 保持；随机生成器避开 |
| S-7 | Csr | 寄存器表 | `mhartid`、`misa` 可被 csrw 改写 | 保持 |
| S-8 | PreIduQueue | `comb_fire` | recover 时跳过 pop，依赖 Rob 在误预测拍不提交（Rob.cpp:218、274），该约束改变会泄漏 FTQ 表项 | 保持；闭环时留意 |
| S-9 | Isu | IssueQueue | DIV/FP 槽倒计时为 0 当拍广播后立即释放，同拍新发射可复用该槽；延迟唤醒广播不受本拍 mispred 影响，错误路径上的乘除也会广播一次 | 保持 |
| S-10 | Isu | 同上 | 槽位不足的 Assert 在无调试编译下为空操作 | RTL 用时钟采样断言代替，真实 trace 未触发 |
| S-11 | Rob | `Rob.cpp:611` | STA 写回带 fault 且 page_fault_store 时清 page_fault_load | 保持 |
| S-12 | TlbMmu | `cancel_pending_walk`/`top_comb` | cancel 拍已回的合法响应仍回填 TLB，出错响应也被消费而 walk 被清空 | 保持 |
| S-13 | TlbMmu | walk 管理 | 出错响应若无同页请求会一直留在 PTW 端口、walk 一直 active，直到同页请求/cancel/fence | 保持 |
| S-14 | TlbMmu | walk 比较 | `walk.satp != satp` 整字比较含 ASID，同页但 ASID 变了被判 OTHER_WALK_ACTIVE | 保持 |
| S-15 | TlbMmu | 查表 | 不 fence 改页表会出现重叠表项（4K 项在超级页内），按最低下标优先 | 保持 |
| S-16 | TlbMmu | `core_comb` | 权限检查用请求口的类型/特权级，仅提前回填用 walk 里保存的，MPRV 变化时二者可不同 | 保持 |
| S-17 | FPU | softfloat | 链接的 softfloat 把 rm=6 当 round-to-odd；RV32F 中 6 是保留编码 | RTL 把 6 当 RTZ，生成器不产生 rm=6 |
| S-18 | exu_int | `Fu.h` ALU | `rol`/`ror` 移位量 0 时 `x >> (32-s)` 为未定义行为；-O0 与 -O3 -march=native 实测一致 | RTL 按正确旋转实现 |
| S-19 | exu_int | MulUnit | 接受新项后流水满且较老项被 flush 杀掉、槽里的指令没被杀，同一条 MUL 可被第二次接受 | 保持；exu_ctrl 集成时留意 |
| S-20 | exu_int | DivUnit | 接受判忙在 consume 之前：完成并被 consume 的同一拍不接新活 | 保持；Exu 侧不要假设同拍可接 |
| S-21 | front_basic | `bpu_icache_read_ready` | 名字有误导：实为"取指地址 FIFO 没满且 bpu_can_run" | 沿用 C++ 含义 |
| S-22 | BPU | `BTB_top.h` `btb_pred_output_comb` | BTB 未命中目标是 `bank_pc + 4`（`bank_pc = pc>>3`），不是 `pc + 4`；会改变取指地址 | 按位复刻 |
| S-23 | BPU | 更新队列 | 同拍同 bank 多条提交只收第一条，其余静默丢弃，而 `update_queue_full` 写死 false | 保持 |
| S-24 | BPU | BHT | `bht_hist_t` 实为 `uint8_t`，BHT 运算按 8 位截断 | 保持 |
| S-25 | BPU | TAGE | 复位后 tag 表全 0，tag=0 与 hash 出的 0 tag 会"命中" | 保持 |
| S-26 | BPU | TAGE useful 清除 | `reset_cnt[23]` 相关模式需约 800 万次/bank 更新才触发，所有验证都没走到，RTL 已实现但**未验证** | 保持；待补专项 |
| S-27 | ROB / CSR | ebreak | 参考模型把每条 ebreak 当作程序结束（冲刷、无异常）。OpenSBI 1.2 探测 semihosting 的 `slli x0,x0,0x1f; ebreak; srai x0,x0,7` 需要一次断点异常，否则 Linux 起不来。RTL 加编译宏 `TTG_EBREAK_TRAP`：打开时 ROB 把 ebreak 作为断点异常提交（cause 3、`mepc` = 该 pc、`mtval` = 该 pc、`medeleg[3]` 仅在非 M 态时委托），CSR 新增输入 `rob_bcast_breakpoint`；**关闭（默认）时与参考模型逐位一致**。是否结束仿真由测试平台判定：夹在标记序列之间的 ebreak 不结束（`SOC_TB_SEMIHOST=1`），其余仍结束。与 function-model（`2191b77`）、trace-model（`42b43db`）规则相同 | 批准（用户决定，2026-11-04）；已用 Linux 镜像对照 trace-model 到 100 万条提交 |

## 申请流程

1. 在上表新增一行，写清楚 C++ 位置、RTL 位置、差异的精确含义；
2. 给出能复现的 trace 片段（周期号 + 字段）；
3. 评审人批准后才能合入；被拒绝的必须改成与参考模型一致。
