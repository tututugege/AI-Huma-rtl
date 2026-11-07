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
3. 提交侧架构历史每拍最多压 8 条 × 3 位（24 级链），行为上与模型一致，**时序上不现实**（见第 5 节）。
4. 没有的开关：LOOP、UB_MAIN、UB_HBITS、L1_HBITS、BTB 128 组、年龄规则。

## 3. 验证
| 项 | 结果 |
|---|---|
| `scripts/lint.sh`、`lint_chip.sh` | 0 警告 |
| ICALL 单独（零气泡 RTL vs 模型 `BPU_PIPE=0` + ICALL） | 67/67 周期逐个相等 |
| `fm_gate.sh`（逐条提交对比 function-model） | 67/67 PASS，与 `scripts/ref_cycles_bpupipe.txt`（模型默认配置）周期不同的个数 0 |
| 大程序 | dhrystone 116,054、coremark 295,445、smc-addi 10,244、smc-div 10,802、pf-stress 621,150、memory-stress-small 335,923，全部相等 |
| 逐提交周期轨迹（`first_diff.sh`，300k 周期） | sha-test、cjpeg、parser-125k、linear_alg、coremark、memory-stress：全部提交（约 20 万到 100 万条）周期与 pc 完全一致（恒定偏移 1，是该脚本的约定） |
| 已知例外 | `load-store`（不在门禁）：RTL 与旧 RTL 都在“Misaligned Load”处被 function-model 检查中止，与 BPU 无关 |
没有出现需要登记的周期差异（K-1 型“错误路径取指读数据区”差异没有遇到）。**没有跑 Linux**（按要求留给与 LSU 合并后一起验证）；也没有 SPEC 点。

## 4. 综合（yosys-slang，通用门，`SYNTH_LIGHT=1 SYNTH_MEM=1`，与 09 报告同设置；单元数为相对量，层数 = `ltp -noff` 通用门级）
| 模块 | 新（单元 / 层） | 旧对应模块（单元，来自 docs/synth/modules.csv） |
|---|---|---|
| bpu_ubtb（uBTB+L1+训练，阵列保留为 $mem） | 20,050 / 482 | 无 |
| &nbsp;&nbsp;bpu_ub_look（一次查表） | 1,676 / 73 | |
| &nbsp;&nbsp;bpu_ub_rmw | 1,538 / 43 | |
| &nbsp;&nbsp;bpu_ub_track（8 车道提交块跟踪） | 9,323 / 480 | |
| &nbsp;&nbsp;bpu_ub_tq | 5,790 / 112 | |
| bpu_main_sel（S2 选择） | 17,210 / 53 | bpu_pred 8,076 |
| bpu_updq + sched | 55,905 / 255（sched 4,951 / 191） | bpu_uq 19,682 |
| bpu_spec（投机+提交 历史/RAS） | 99,411 / 73（含 24 级架构链） | bpu_hist 21,565 + bpu_ras 12,015 |
| bpu_ctl / cmd / pdq / stage0 | 339 / 1,468 / 84 / 912（层数 18 / 18 / 16 / 11） | bpu_ctrl 1,937 |
| bpu_btb_bank（BTB+ITT） | 676 / 49 | 1,883（含 BHT/TC） |
| bpu_tage_bank | 698 / 21 | 831 |
| bpu_type | 653 / 12 | 997 |
旧设计的层数没有逐模块重测。顶层 `bpu` 与旧版一样综合不出来（太大），关键路径只能按模块相加估计：
* **L1 比较 -> S0 取消发射**：`bpu_ub_look`（73）+ `pred_differs` 比较（约 15）+ `bpu_ctl`（18）约 105 层，再接取指地址 FIFO 写使能。这是最长的非阵列路径。备选（文档 BPU_PIPE 9.7）：照发射、下一拍 `drop_tail` 取消，气泡相同。
* **历史修复装载路径**：`bpu_cmd`（18）+ `bpu_spec` 的 hist_push_sym（折叠 3 步，约 73 含 arch 链选择）约 90 层。
* S2 比较：阵列读出寄存后 `bpu_main_sel` 53 层，加 `bpu_ctl` 的 override 判定 18 层约 75 层，再接 S0 pc 选择和 FIFO pop 门控。
* `bpu_updq_sched` 191 层、`bpu_ub_track` 480 层是顺序循环的串行展开（8 项扫描、8 车道链），不是真实可综合的时序：真实实现要流水或限宽。`bpu_spec` 的提交侧 24 级压入同理。这三处是**面积/时序上的已知问题**，行为已与模型一致，改写成并行前缀需要同时改模型的丢弃/合并规则或证明等价。
* 存储：uBTB 128x49 + L1 512x49 约 31 kb（原估计 26–30 kb）；FTQ 检查点 64 x (132+8) 位（trim 后 109+8）约 7.5 kb；PTAB 每项 +140 位；PDCKPT 32 x 140+43 位；TC/pre-TC/BHT 删除，ITT 每 bank 256 x 44 位。

## 5. 未完成 / 遗留
1. 合入 main 前：LSU 合并；Linux 整核逐条对比（数小时）；`ref_cycles.txt`、`PROJECT.md`、`baseline.csv` 更新；MAIN_RECORDS。
2. `tools/gen_backtop.py` 与 `spec/*.io` 没有同步新端口（back_top.sv 为手工修改：`exu2id_br_pc`、`front2pre_bpu_ck/slot_kind`、`out_rf_*`）；已删除失效的 `spec/bpu_{hist,btb,tage,uq,type}.io`，`spec/bpu.io`、`front_top.io`、`ptab.io` 等前端 spec 仍是旧接口（旧回放体系已退役）。`docs/modules/bpu.md` 未重写（本文件代替）。
3. 综合：第 4 节三处串行逻辑的并行化；旧设计层数对比；没有做整机面积推算。
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
