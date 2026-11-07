# 流水化 BPU（S + R）的 RTL 实现与验证（分支 exp/bpu-pipe-rtl）

对应模型：`trace-model-bpuopt` 分支 `exp/bpu-opt`（默认配置即本设计，见该仓库 `docs/BPU_RTL.md`）。**未合入 main**：按 WORKFLOW 第 6 节，合入要等 LSU 合并和负责人确认，且合入时 `ref_cycles.txt`、`PROJECT.md` 标准周期一并更新。

## 1. 设计

配置 = `BPU_PIPE=3 BPO_HIST=1 BPO_HSYM=3 BPO_BANKBLK=4 BPO_PDCKPT=1 BPO_L1_ENTRIES=512` + R（ICALL、历史修复 `BPA_REPAIR=3`、ITT 256 项替换 TC）。

```
S0  pc 寄存器 -> uBTB(128x4路) 查表 -> 下一 pc / 历史位 / RAS 操作；投机历史、RAS 推进；各 bank 的 TAGE 索引；块地址进取指地址队列
S1  各 bank 读 类型表 / TAGE / BTB / ITT；L1(512x2路) 查表，与 S0 猜测不同则覆盖（1 拍气泡，S0 本拍不发射）
S2  比较选择：类型、TAGE provider/alt、BTB/ITT 目标、第一条 taken；写 PTAB；与猜测不同则 override（2 拍气泡，压掉 S1 块）
```
* 历史：256 位环 + 8 位头指针 + 12 组折叠历史；检查点 = 头指针 + 折叠历史（RTL 里每个折叠域按 11 位存，高位恒 0，综合后是 101 位，加头指针 109 位）。每块检查点 + 8 位纪元随块经 PTAB、front2back 队列进后端 FTQ（`pre_idu_ftq_bpu`，64 项），后端误预测时随重定向取回，纪元不符则退回提交态。
* 误预测返回：FTQ 号（读口地址）、误预测分支 pc（经 `exu_ctrl_br_arb` -> `idu_br_latch`）、槽号 = pc 相对块基址、类型 = 前端从指令字译出的每槽类型（`front_slot_kind`，规则同提交侧分类），方向由重定向地址与 pc+4 比较得到。模型选模式 3（只修历史，RAS 用提交态再加该分支自己的 push/pop）：RTL 不存 RAS 检查点，最简单。
* PDCKPT：BPU 内 `bpu_pdq` 队列（32 项，实际占用不超过 PTAB 16 + 在途 2），predecode 检查结果 `front_pd_info` 登记一拍后到 BPU。
* 更新路径：`bpu_updq` 8 项队列 + `bpu_updq_sched`（每拍最多 2 个领头写，按 32 B 窗口分 4 个 block bank，S1 正在读的 bank 不能写，同窗口同 TAGE 索引的项合并）；写口是每个 slot bank 一个。
* ITT：每 bank 256 项，用 TAGE 第 1 张表的索引低 8 位和标签；BHT / TC / pre-TC 阵列删除（NOTC 下没有读者）。
* ICALL：`BR_ICALL=6`，`core_back2front` 分类，类型表 / BTB / ITT / RAS 路径都按“间接 + call”。
* 前端接口：取指地址队列加 `drop_tail`（override 时丢掉最年轻项，且该项为队首时不弹出）；PTAB 不再用 full 锁存，改为 BPU 的信用（`ptab_size + 在途块 >= PTAB_SIZE-1` 则 S0 不发射）。D=2 时模型的“项年龄”规则恒成立，RTL 无年龄字段。

### 模块表（rtl/frontend/bpu）
`bpu`（顶层）、`bpu_stage_pkg`（类型和历史/RAS 函数）、`bpu_ctl`（override/L1/发射判定）、`bpu_cmd`（投机状态命令与 pc）、`bpu_spec`（投机/提交历史与 RAS）、`bpu_pdq`、`bpu_stage0`（S0 索引）、`bpu_ubtb`（含 `bpu_ub_tab/look/rmw/track/tq`）、`bpu_banks`（`bpu_type`、`bpu_tage_bank/pred/upd`、`bpu_btb_bank/upd/sel`）、`bpu_main_sel/lane`（S2 选择）、`bpu_updq/sched`。前端新增 `front_pd_info`、`front_slot_kind`；后端新增 `pre_idu_ftq_bpu`。删除：旧的 `bpu_ctrl/hist/ras/uq/pred/tage/btb` 等。

## 2. 与模型的差别（都不改变周期）
1. uBTB/L1 项去掉 `nd_t`、`nd_nt`、`taken`（taken 历史下无影响）：49 位/项。
2. 模型 `rec_[256]`（按块序号）→ FTQ 每项存检查点；两者在块在途期间等价（模型的 id/pc 校验在 RTL 里按构造恒成立）。
3. 提交侧架构历史一拍压入至多 8 条 x 3 位，用并行的移位/异或网络实现（`bpu_hist_vec`），与逐位压入的函数等价（随机对拍）。
4. 没有的开关：LOOP、UB_MAIN、UB_HBITS、L1_HBITS、BTB 128 组、年龄规则。

## 3. 验证
| 项 | 结果 |
|---|---|
| `scripts/lint.sh`、`lint_chip.sh` | 0 警告 |
| ICALL 单独（零气泡 RTL vs 模型 `BPU_PIPE=0` + ICALL） | 67/67 周期逐个相等 |
| `fm_gate.sh`（逐条提交对比 function-model） | 67/67 PASS，与 `scripts/ref_cycles_bpupipe.txt`（模型默认配置）周期不同的个数 0（串行结构改并行之后重跑，同样 0） |
| 大程序 | dhrystone 116,054、coremark 295,445、smc-addi 10,244、smc-div 10,802、pf-stress 621,150、memory-stress-small 335,923，全部相等 |
| 逐提交周期轨迹（`first_diff.sh`，300k 周期） | sha-test、cjpeg、parser-125k、linear_alg、coremark、memory-stress：全部提交（约 20 万到 100 万条）周期与 pc 完全一致（恒定偏移 1，是该脚本的约定） |
| 已知例外 | `load-store`（不在门禁）：RTL 与旧 RTL 都在“Misaligned Load”处被 function-model 检查中止，与 BPU 无关 |
没有出现需要登记的周期差异（K-1 型“错误路径取指读数据区”差异没有遇到）。**没有跑 Linux**（按要求留给与 LSU 合并后一起验证）；也没有 SPEC 点。

## 4. 综合（yosys-slang，通用门，`SYNTH_LIGHT=1 SYNTH_MEM=1`，与 09 报告同设置；单元数为相对量，层数 = `ltp -noff` 通用门级；阵列保留为 $mem 不计入单元）
同一脚本、同一设置测了新旧：旧 BPU 来自 main 的 `5829f07`（单独工作树 `rtl-bpuold`），新的是串行结构改并行之后的版本。

| 部件 | 新（单元 / 层） | 旧（单元 / 层） |
|---|---|---|
| uBTB + L1 + 训练（`bpu_ubtb`） | 32,604 / 154 | 无 |
| &nbsp;&nbsp;提交侧块跟踪 `bpu_ub_track` | 21,829 / 152（改前 9,323 / 480） | |
| &nbsp;&nbsp;`bpu_ub_look` / `bpu_ub_rmw` / `bpu_ub_tq` | 1,676 / 73；1,538 / 43；5,790 / 112 | |
| S2 选择 `bpu_main_sel` | 17,210 / 53 | `bpu_pred` 8,076 / 15 |
| 更新队列 `bpu_updq`（含调度） | 55,433 / 141（调度 4,277 / 65，改前 4,951 / 191；整体改前 55,905 / 255） | `bpu_uq` 19,682 / 12 |
| 投机+提交 历史/RAS `bpu_spec` | 69,833 / 75（改前 99,411 / 73；其中 `bpu_hist_vec` 10,766 / 51） | `bpu_hist`（含 RAS）21,565 / 56 |
| `bpu_ctl` / `bpu_cmd` / `bpu_pdq` / `bpu_stage0` | 339 / 1,468 / 84 / 912（层 18 / 18 / 16 / 11） | `bpu_ctrl` 1,937 / 26 |
| `bpu_type` | 653 / 12 | 997 / 12 |
| 每 bank：TAGE / BTB+ITT | 698 / 21；676 / 49 | 831 / 21；1,883 / 49 |
| **合计（8 个 bank 的 TAGE+BTB 都算）** | **约 189,500** | **约 74,000** |

* 新设计逻辑量约为旧的 2.6 倍，主要是三块：更新队列 8 项 x 约 170 位触发器与写口选择（55k）、提交侧历史（含 24 位/拍的并行压入）与两份 32 项 RAS（70k）、提交侧块跟踪的并行形式（22k，层数 480 -> 152 的代价）。这些是“零气泡 → 流水线 + 精确修复”买来的状态，不含阵列；阵列新增 uBTB/L1 约 31 kb、FTQ/PTAB 检查点、ITT（BHT/TC 删除抵消一部分）。
* 串行结构改写（行为不变，67/67 周期相等，另用 300 万随机向量对拍旧串行模块）：更新队列调度 191 -> 65 层（两阶段：第一领头 + 同窗口合并、第二领头 + 合并，`UQ_PORTS=2` 固定）；块跟踪 480 -> 152 层（候选块起点并行比较、逐车道 1 位解析；车道有效掩码不要求是前缀，跳转用与前一有效车道下一 pc 的局部比较）；提交侧历史 24 级链改为一次压入 n 位（折叠历史按旋转/异或网络，环缓冲按移位写入），`bpu_spec` 99k -> 70k 单元，层数持平。提交侧 RAS 仍是 8 次顺序 push/pop（未改）。
* **L1 比较 -> S0 取消发射**（`bpu_ub_look(L1)` + `pred_differs` + `bpu_ctl` + `bpu_cmd` 的 pc 选择，探针模块综合）：79 层，1,692 单元（之前按模块相加估 105）。历史修复装载路径（`bpu_ctl` + `bpu_cmd` + `bpu_spec`）：75 层。S2 比较 `bpu_main_sel` 53 层 + override 判定 18 层。旧设计最长路径（顶层不能综合）按模块估：`bpu_ctrl` 26 + 阵列读/选 + `bpu_pred` 15 + `bpu_hist` 56 是同量级。
* 仍然偏长：`bpu_updq` 141 层（压缩和写口选择）、`bpu_ub_tq` 112 层（4 项移位 + 8 车道追加）、`bpu_ubtb` 154 层（跟踪器）。这些不在 S0/S1/S2 的取指周期路径上（提交侧，可加流水），但没有流水化。

## 5. 未完成 / 遗留
1. 合入 main 前：LSU 合并；Linux 整核逐条对比（数小时）；`ref_cycles.txt`、`PROJECT.md`、`baseline.csv` 更新；MAIN_RECORDS。
2. `gen_backtop.py` 与后端 spec 已同步（脚本重新生成 back_top.sv / exu.sv，lint 0 警告，抽查周期相等）；失效的 `spec/bpu_{hist,btb,tage,uq,type}.io` 已删除，`spec/bpu.io`、`front_top.io`、`ptab.io` 等前端 spec 仍是旧接口（旧回放体系已退役）。`docs/modules/bpu.md` 已重写。
3. 综合：第 4 节末尾列出的提交侧长路径没有流水化；整机面积没推算。
4. 没有 SPEC 点上的 IPC 复核（模型文档的 -3.3% 数字未在 RTL 侧复现，RTL 与模型周期相等所以结论等同于模型）。
5. 检查点宽度 `HCK_W` 按 11 位域存，仿真里是 140 位。

## 6. 复现
```
cd rtl-bpupipe
SOC_FM=1 SOC_OUT=$PWD/build/soc_bp JOBS=3 bash tb/soc/build.sh
JOBS=3 REF_CYCLES=$PWD/scripts/ref_cycles_bpupipe.txt bash scripts/fm_gate.sh $PWD/build/soc_bp/obj/soc_tb $PWD/build/gate_bp
# 模型参考周期：JOBS=3 bash scripts/tm_cycles.sh ../trace-model-bpuopt/build_rtl/simulator out.txt
TM=../trace-model-bpuopt/build_rtl/simulator SOC_TB=$PWD/build/soc_bp/obj/soc_tb bash scripts/first_diff.sh programs/extra/sha-test.bin 100000
bash scripts/lint.sh; bash scripts/lint_chip.sh
SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob" SYNTH_LIGHT=1 SYNTH_MEM=1 bash scripts/synth_module.sh <模块> 12000 300
```

## 7. 日志
* 模型：提交未提交的工作 -> 合并 main -> 默认值改为 S+R（`2b497a0`）-> baseline.csv 与 BPU_RTL.md。
* RTL：ICALL（`41eb3eb`，零气泡 67/67）-> 流水化 BPU 全部（`9515c29`，67/67）-> 额外程序逐提交对比 -> 综合 -> 本文。

## 8. coremark 比零气泡慢 16–18% 是否合理（跟进任务 1）
同一模型（`trace-model-bpuopt` 默认 S+R）与零气泡 + ICALL（`BPU_PIPE=0`，旧开关组合）对比，PMU=1：

| 项 | 零气泡 + ICALL | S+R（默认） |
|---|---|---|
| coremark 周期 | 250,900 | 295,445（+17.8%） |
| 提交条件分支误预测 / 返回 / jalr | 4,149 / 85 / 14 | 4,156 / 44 / 9 |
| 分支误预测重定向（含错误路径） | 4,620 | 4,529 |
| `SLOT_FE_OTHER`（取指带宽：短块、taken 气泡） | 388,129 | 669,973（+282k 槽，约 +35k 周期） |
| `SLOT_FE_RECOV_MISPRED` | 271,304 | 308,061（重取多 2 拍气泡） |
| S0 命中块 / 全部块 | - | 162,330 / 217,188（75%） |
| override 次数（S2 与 S0 猜测不同）/ 其中 next pc 不同 | - | 10,732 / 10,305（S0 taken 而主预测器不 taken 3,387；反之 3,777；目标不同 3,113） |
| L1 覆盖次数（1 拍气泡） | - | 11,136 |
| 信用停顿（PTAB 满） | - | 51,532 拍 |

结论：**不是预测精度问题**（误预测数持平，历史修复让返回误预测还少了），是纯取指气泡：coremark 每块约 2.5 条指令、108,910 条条件分支/538k 指令，块数 217k，1.36 拍一个块，uBTB 只在提交的 taken 事件上训练、hist 模式下不为顺序块建项，每次 S0 猜错要 2 拍（L1 覆盖 1 拍），共约 10.7k×2 + 11.1k ≈ 32.5k 拍加重取多 2 拍，与 +44.5k 周期同量级。
同一组 67 个程序里，周期 > 20,000 的 9 个按零气泡对比几何平均 +3.2%，与 BPU_OPT/ACC 文档的 SPEC 数字（S+R 约 -2.6% 到 -3.3%）一致；个别小循环、taken 密集的程序（dhrystone +11.8%、coremark +17.8%）远高于平均，其余为 -0.7% 到 +1.2%。这类程序和 SPEC 30 点里最差的 sjeng（-9%）、gcc 同类，不是配置错误。
模型配置与 SPEC 评估一致：`BPU_PIPE=3 BPO_HIST=1 BPO_HSYM=3 BPO_BANKBLK=4 BPO_PDCKPT=1 BPO_L1_ENTRIES=512 BPA_ITTH=1 BPA_ITTN=256 BPA_NOTC=1`，唯一差别是 `BPA_REPAIR=3`（评估里用 1），两者误预测数在噪声内。RTL 与模型周期逐个相等，所以 RTL 侧没有额外损失。

## 9. 30 点精确预热 SPEC（模型，合并 main 后的默认 S+R 对旧设计）
本机运行（`ba_eval.sh`，`FW=0 COV=0.25`，8 个程序 30 个点，10M 详细预热 + 10M；二进制 `trace-model-bpuopt/build_rtl`，结果 `tim_ba_m_p0`、`tim_ba_m_def`）。旧设计 = 零气泡 + ICALL（`BPU_PIPE=0 BPO_HIST=0 BPO_HSYM=2 BPA_REPAIR=0 BPA_NOTC=0 BPA_ITTH= BPO_PDCKPT=0 BPO_L1_ENTRIES=0 BPO_BANKBLK=0`），新 = 默认值（S+R，`BPA_REPAIR=3`）。

| 配置 | IPC 几何平均 | perl | gcc | mcf | gobmk | hmmer | sjeng | h264 | astar | MPKI（事件口径） |
|---|---|---|---|---|---|---|---|---|---|---|
| 新默认相对旧设计 | **+1.90%** | +11.7 | -7.7 | +0.8 | +6.6 | +0.1 | +7.2 | -0.4 | -0.4 | 8.65 |

新设计比不带 R 的零气泡还快 1.9%，与 BPU_ACC 的结论一致（R 的历史修复、ITT 在流水线里的收益 > 气泡损失；相对“同样加了 R 的零气泡”仍差约 1.8pp）。gcc 是最差项（-7.7%），coremark/dhrystone 这类小循环程序不在 SPEC 里（第 8 节）。因为运行已经在本机进行到一半，这一次没有搬到服务器；之后的 SPEC 按规则走 `fleet.sh`。
