# FLUSH_REG：全局 flush 晚一拍生效（EXP-LSUTIM / EXP-FLUSHREG）

模型：trace-model `CFG_FLUSH_REG=1`（`docs/LSU_TIMING.md`）；RTL：`back_top` 的 `rob_flush_q`。

## 做了什么

ROB 在第 t 拍决定一次全局 flush（异常 / xRET / CSR / fence / 访存违例 / 中断），**同一拍清自己**。其余部分晚一拍（t+1）才看到：

| 看到 flush 的模块 | t 拍 | t+1 拍 |
| --- | --- | --- |
| ROB | 清空（覆盖这拍的入队） | 屏蔽陈旧的误预测恢复（`flush_pend`） |
| pre / idu / ren / dispatch / isu / prf / exu / DTLB / LSU | 看不到，照常工作（这拍的结果都是死的） | 清状态（`rob_flush_q`） |
| 前端重定向（`out_mispred`、`out_redirect_pc`） | 被压住（这拍的分支误预测也丢弃，flush 优先） | 用寄存的 pc 重定向 |
| fence / fence_i 广播（TLB、icache 失效） | — | 随重定向一起 |

**不能晚一拍的是"限定同一拍提交"的信号**：`rob_bcast_interrupt`（带中断退休的指令不算提交，rename 不能把它的 rd 映射提交进架构映射）、LSU 的 store 提交抑制（缺页 store 随 flush 提交，不能写出去）用当拍的 flush（`rob_flush_now`），提交 diag_val 里的重定向 pc 也用当拍的。

## 为什么

最长组合路径的头一直是 ROB 提交 → trap → flush（约 29 层），再经 EXU 的 AGU 使能、LSU 的"请求被接受"检查进入 DTLB 请求和后面的 CAM。flush 只清寄存器就够，不该并进数据通路。flush 那一拍出来的都是比 flush 点年轻的指令，全部要死，唤醒、发射、写回都无所谓。

## 模型里踩到的三个坑（RTL 无 trace bridge，但前两个是设计问题）

1. 同一拍提交的限定条件不能晚一拍（`interrupt`、flush 对 store 提交）：否则带异常 / 中断的指令的 rd 映射被提交进架构映射，ROB 死锁。
2. flush 那拍 IDU 可能锁存了陈旧分支的误预测，下一拍 flush 挂起时 ROB 已空，不能再拿它做恢复（`flush_pend`）。
3. （仅 trace 模型）flush 那拍 dispatch 对 bridge 登记 / `on_exec` 打补丁，会污染已经倒回的指令流，Linux 启动 blake2s 自检失败。

## 结果

* 模型：67 个程序周期 +0.05%；16 个访存点 IPC 0.9982（-0.18%）；Linux 启动到 `login:`。
* RTL：`fm_gate` 67/67，周期与 `scripts/ref_cycles_memiq6_nr_int2_ev3.txt`（模型）逐个相等；`lint_chip` 0。
* 还没做：最终 RTL 的 Linux 从复位启动（带指纹），整机综合深度复测。
