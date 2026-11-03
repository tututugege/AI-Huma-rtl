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

## 申请流程

1. 在上表新增一行，写清楚 C++ 位置、RTL 位置、差异的精确含义；
2. 给出能复现的 trace 片段（周期号 + 字段）；
3. 评审人批准后才能合入；被拒绝的必须改成与参考模型一致。
