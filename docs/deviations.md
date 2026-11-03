# 偏差登记（Deviations）

RTL 与参考模型在任何一拍、任何一位上不同，都必须登记在此。**默认不允许有偏差**；每条偏差需要评审人书面批准，批准后才能在 RTL 里出现 `// DEVIATION D-<n>`。

## 已批准偏差

| 编号 | 模块 | 描述 | 原因 | 影响（哪些信号/哪几拍不同） | 批准人/日期 |
| --- | --- | --- | --- | --- | --- |
| （暂无） | | | | | |

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

## 申请流程

1. 在上表新增一行，写清楚 C++ 位置、RTL 位置、差异的精确含义；
2. 给出能复现的 trace 片段（周期号 + 字段）；
3. 评审人批准后才能合入；被拒绝的必须改成与参考模型一致。
