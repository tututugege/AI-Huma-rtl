---
module: bpu
area: frontend
rtl: rtl/frontend/bpu
spec: (旧的 bpu*.io 已随旧体系退役并删除)
status: 流水化 S+R 版，整核周期与 trace-model 逐个相等（fm_gate 67/67）；未合入 main
note: S0 uBTB / S1 L1 + 阵列读 / S2 比较，taken 历史，PDCKPT，FTQ 检查点修复，ITT
---

# bpu 设计笔记（流水化分支预测单元）

完整设计、与模型的差别、验证和综合数字见 [../analysis/bpu-pipe-rtl.md](../analysis/bpu-pipe-rtl.md)；模型侧见 trace-model `docs/BPU_PIPE.md`、`BPU_OPT.md`、`BPU_ACC.md`、`BPU_RTL.md`。本文只列模块和接口。

## 模块（rtl/frontend/bpu）
| 模块 | 作用 |
|---|---|
| `bpu` | 顶层：阶段寄存器（pc、S1/S2 块、纪元）和各子模块连线 |
| `bpu_stage_pkg` | 类型（历史环、RAS、检查点、uBTB 项、猜测）和历史/RAS 推进函数 |
| `bpu_ubtb`（`bpu_ub_tab/look/rmw/track/tq`） | S0 uBTB 128x4、S1 L1 512x2、提交侧块跟踪与训练队列 |
| `bpu_banks`（`bpu_type`、`bpu_tage_bank/pred/upd`、`bpu_btb_bank/upd/sel`） | 主预测器阵列：S1 读、S2 选择、更新写口 |
| `bpu_main_sel`、`bpu_main_lane` | S2 比较选择、第一条 taken、历史位 / RAS 操作 |
| `bpu_updq`、`bpu_updq_sched` | 更新队列（8 项）与写调度（2 个领头写，4 个 block bank，同窗口合并） |
| `bpu_spec`、`bpu_hist_vec` | 投机/提交历史与 RAS；提交侧一次压入至多 24 位 |
| `bpu_pdq` | PDCKPT：PTAB 内每块的检查点队列 |
| `bpu_ctl`、`bpu_cmd`、`bpu_stage0` | override / L1 覆盖 / 发射判定，投机状态命令与 pc，S0 TAGE 索引 |

## 接口（bpu）
输入：`refetch`、`refetch_address`、`refetch_pd`、`icache_read_ready`、`ptab_size`；后端误预测的修复信息 `rf_valid/rf_ck/rf_epoch/rf_type/rf_pc`；predecode 检查结果 `pd_*`（一拍延迟）；提交流 `upd_*`（每个车道：valid、pc、类型、方向、目标、预测方向、TAGE 元数据）。
输出：S0 的 `icache_read_valid`、`fetch_address`；S2 的 `ptab_write_enable`、`ptab_base_pc`、`predict_next_fetch_address`、每槽预测元数据、块检查点 `out_ck/out_epoch`；`override_valid/override_squash`（前端据此丢弃取指地址队列的最年轻项）。
