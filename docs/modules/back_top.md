---
module: back_top
area: backend
rtl: rtl/backend/back_top
spec: back_top*
status: green
lockstep: 68/68（整程序）
mutants: 集成层 11/18 杀死，7 待判定
note: 后端整体，含 lsu
---

# back_top 设计笔记（后端集成：back_top）

## 1. 范围与文件
- `back_top`：PreIduQueue、Idu、Ren、Dispatch、Isu、Prf、Exu（`exu_ctrl` + FU + FPU）、Csr、Rob、TlbMmu（DTLB）、`lsu` + 胶水；（早期曾有不含 LSU 的 `back_top_nolsu` 用于分步集成，已删除；`gen_backtop.py --nolsu` 仍可再生成它用于二分。）边界 = 后端 ↔ 前端（SimCpu）+ 访存子系统（DCache、MMIO、PTW）。
- 文件（`rtl/backend/back_top/`）：`back_top.sv`（生成）、`exu.sv`（生成：FU 适配文本 + 端口表）、`back_top_glue.sv`（手写）。
  规格：`spec/back_top.io`、`spec/exu.io`（均生成）。
- 工具：`tools/gen_backtop.py`（`--report` 连线分析、`--write [--full]` 生成、`--asm NAME --inst a,b [--full]` 生成子装配用于二分）、
  `tools/lint_back_top.sh`（`scripts/lint.sh` 只支持单目录顶层，装配体要跨目录，故单独一个脚本）。

## 2. 连线
端口名 = BackTop 线网名 + 字段路径，所以"输出名 == 输入名"自动匹配。`--report` 的结果（nolsu / full）：
实例 11 / 12，端口 712 / 825，线网 428 / 454；有模块驱动的线网 348 / 391，胶水驱动 9 / 10，常量 7，边界输入 64 / 46，边界输出 112 / 69；
位宽/维度不一致 0（除 csr_idx，见下），多驱动 0。自动匹配 = 全部"同名"连线（除下面手工项外的所有）；手工项：
- 重命名 3 条：`pre.idu_br_latch_*` ← `idu.br_latch_*`；`tlb_mmu.ldq/stq_req_*` ↔ `lsu2mmu_*`，`ldq/stq_resp_*` ↔ `mmu2lsu_*`。
- 连接表达式 1 条：`exu.prf2exe_iss_entry_uop_csr_idx` ← `prf2exe_iss_entry_uop_csr_idx[0]`（exu_ctrl 只保留 CSR 槽，硬绑定发射口 0）。
- 常量 7 条、胶水 9(10) 条（第 4 节）。

## 3. 发现的集成问题
| 编号 | 现象（`--report`） | 根因 | 处理 |
| --- | --- | --- | --- |
| I-1 | `dispatch.ren2dis_uop_src1_areg` 无驱动 | Ren 笔记"下游没有读者"只 grep 了 `back-end/*.cpp` 的 `.cpp` 读取；实际经 Dispatch→`dis2rob.src1_areg`→Rob `commit_extra.src1_areg`→`rv_simu_mmu_v2.cpp:1407` 前端 RET 识别（BPU 训练）读取 | **修 Ren**：`ren2dis_uop_src1_areg` 作为输出加回（`ren_pkg/ren_core/ren`，`spec/ren.io` 加一个 `when ren2dis_valid` 字段；Ren 的 trace 需重录） |
| I-2 | `rob.dis2rob_uop_tma_mem_commit_is_store` 无驱动 | Idu 算出 `tma.mem_commit_is_store`，Ren/Dispatch 都没带。按 06 第 8 节它只服务模拟器记账（`commit_sync`），**不进边界 spec，RTL 不要求产生** | 胶水由 `type/func7` 推导（Idu.cpp:539 同式），仅为了不让 Rob 输入悬空；**待清理**：Idu/Ren/Rob 的 tma 边带统一清理时删除此胶水 |
| I-3 | `dispatch.ren2dis_uop_src{1,2}_busy`、`rob.dis2rob_uop_{mispred,br_taken,flush_pipe}`、`rob.exu2rob_entry_uop_{page_fault_inst,flush_pipe}` 无驱动 | 生产者因恒 0 / 被覆盖删字段（06 第 3 节），消费者端口仍在 | 常量 0（见 `CONSTS`，原因逐条写在生成文件里） |
| I-4 | `exu_ctrl.prf2exe_iss_entry_uop_csr_idx` 维度 [] vs [22] | exu_ctrl 只收 CSR 槽 | 连接表达式取口 0 |
| I-5 | `lsu` 需要 `rob_commit_..._amo_op`，Rob 输出 `func7` | 字段形式不同 | 胶水 `amo_op = func7[6:2]` |
| I-6 | 单周期 FU 的 `consume/complete/ready` | exu_ctrl 自己按基类契约推出 complete/ready，FU 只返计算结果 | `exu.sv`：consume 接 0，complete/ready 悬空到具名线；时钟采样断言 `complete == en`；`csr_fu` 不实例化（无数据通路，exu_ctrl 内化握手） |
| I-7 | MC FU 编号 | exu_ctrl 的 mc 序是 {MUL0,DIV3,FPU5,MUL6,DIV8} | `exu.sv` 里 `MC_MUL={0,3}`、`MC_DIV={1,4}`、`MC_FPU=2`；`func3` 截到 2 位、`imm[0]` 给 FPU、`flush/flush_mask/clear_mask` 复制到每个实例 |
其余整程序锁步结果和 RTL 修改见第 6 节。

## 4. 胶水清单（`back_top_glue.sv`）
| 输出 | 内容 | C++ 位置 |
| --- | --- | --- |
| `out_mispred` | `rob_bcast_flush | dec_bcast_mispred` | BackTop.cpp:340-352 |
| `out_stall` | `!pre2front_ready` | BackTop.cpp:346 |
| `out_redirect_pc` | flush ? (mret/sret ? epc : exception ? trap_pc : rob_bcast_pc+4) : `br_latch_redirect_pc`（仅 `out_mispred` 时有意义）| BackTop.cpp:344-362 |
| `out_commit_entry_uop_diag_val[8]` | flush 时 = `out_redirect_pc`，否则 Rob 的 diag_val。**只作用于离开后端的副本**：`rob_commit` 的内部消费者（Ren、PreIduQueue、LSU）都不读 diag_val | BackTop.cpp:364-372 |
| `dis2rob_uop_tma_mem_commit_is_store[8]` | 见 I-2 | Idu.cpp:539 |
| `csr_status_mstatus_{mxr,sum,mprv,mpp}` | `mstatus[19],[18],[17],[12:11]`（LSU 把 csr_status 原样放进 `lsu2mmu_io`，这里 MMU 直接接 CSR）| RealLsu.cpp:326 |
| `rob_commit_..._amo_op` | I-5 | — |

`comb_lsu_mmu` 的模式选择（fence > cancel(flush‖mispred) > translate）在 `tlb_mmu` 内部（直接收 `rob_bcast_fence/flush`、`dec_bcast_mispred`），无需胶水。
`clear_comb_inputs`：只是 SimCpu 每拍重置 `back.in`，在边界之外。

## 5. 边界选择（SimCpu 侧 / 后端侧）
- **边界取在 SimCpu 一侧**：`front2back_hold`（前端停顿时保持上一拍未被 fire 的前端包）和 `peripheral_resp_hold` 是 SimCpu 的寄存器；RTL 看到的 `front2pre_*` 就是 `BackTop::in` 在 `back.comb()` 时的值（含保持值）。`front2back_hold` 需要后端输出 `pre2front_fire`、`out_stall`、`out_mispred`、`rob_bcast_flush`，这些都在边界输出里。
- 边界输出只含环境读取的字段：`back2front_comb`（`ftq_commit_info`、commit 的 type/br_taken/dest_en/dest_areg/diag_val、`commit_extra`）、`commit_sync`（stq_idx/flag、rob_idx/flag、page_fault_*）、difftest 的 exception/mret/sret/`rob_bcast_pc`、`csr_status`、
  （不含 `tma_*`/dbg/perf：有意不含；nolsu 另加 LSU 所读的 dis2lsu/exe2lsu/head_*/dec_bcast/rob_commit amo_op,stq_idx/DTLB 响应；full 里这些成为内部线网，换成 `lsu2dcache`/`peripheral_req`）和 PTW 口。
- **未纳入边界（difftest 观测）**：`prf->reg_file_1`、`rename->arch_RAT_1`、`csr->CSR_RegFile_1`、`commit_entry[].uop.dbg.*`（difftest 用的调试元数据，RTL 不带）。整程序逐拍一致间接保证了它们，但没有直接比较。
- `rob_commit_..._uop_mispred` 没有环境读取点（只有 perf 计数），不在边界；Rob 仍输出，在 back_top 里接到具名悬空线。

## 6. 验证
见报告 / 下面的结果表（整程序锁步，`scripts/lockstep.sh back_top_nolsu|back_top <prog>`；批量 `scripts/lockstep_all.sh`）。

## 7. 已知未验证项
- difftest 直接观测的状态（见第 5 节）。
- 复位只验证了"全零输入 3 拍复位 + 从 init 状态起"（checkpoint 恢复 `restore_from_ref` 不在范围内）。
- 参考模型两个跨拍保持寄存器（`front2back_hold`、`peripheral_resp_hold`）在边界之外，其正确性不属于本集成的验证范围。
- `ptw` 口的 PTW 对端是参考模型的 `MemPtwBlock`，RTL 侧只看到它的输出。
