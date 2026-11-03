# 05 模块清单与进度（唯一的进度来源）

状态：`未开始` → `spec` → `trace` → `rtl` → `绿` ；任何时刻出现问题写 `红` 并在备注说明。
"绿"的定义见 [02-development-flow.md](02-development-flow.md)（lint 干净 + 全部 trace 逐拍一致 + ≥3 个变异被抓到 + 评审通过）。

参考模型提交：`2f31e8d`（见 `tututugege-trace/baseline.lock`）。C++ 路径相对于 `baseline-sim/src`。

## 基础设施

| 项目 | 状态 | 备注 |
| --- | --- | --- |
| 实时锁步（RTL 插件挂进参考模拟器，整程序比对；多模块一遍检查）| 绿 | `scripts/lockstep.sh`、`lockstep_multi.sh`；23 个模块×68 程序、back_top×68 程序全通过；可选 `COVERAGE=1` 翻转/行覆盖 |
| 回放 harness（iogen / tbwrap / replay / VCD 窗口） | 绿 | `make selftest`：干净通过，8/8 变异被抓到，旧 trace 被拒 |
| 编码规范检查（svlint S1–S9 + verilator -Wall） | 绿 | `make lint` |
| 配置包生成 `ttg_cfg_pkg`（151 个常量） | 绿 | `make cfg` |
| 参考模型录制钩子（只读，后端） | 绿 | `refsim/`，`scripts/record*.sh`，周期数与原版一致；前端钩子见分析报告 |
| 闭环集成（RTL 接回参考模型） | 未开始 | 02 流程第 9 步 |

## 后端

状态均为**绿**（lint 干净 + 全部 trace 逐拍一致 + 变异被严格字段抓到 + 协调者独立复核）。RTL 行数含顶层端口适配；trace 数含 61 个 gate 测试、vm 测试、dhrystone/coremark 等和随机 trace；"仅随机"指只有随机 trace 才抓到的变异数。

| 模块 | 分支/合并 | RTL 行数（C++ 行数） | trace | 变异 | 备注 |
| --- | --- | --- | --- | --- | --- |
| Prf | 已合并 | 505（269） | 76 | 10/10（6 仅随机）| 去掉写冲突/旁路优先级；一个物理寄存器同拍只有一个生产者的前提需闭环验证 |
| Idu | 已合并 | 823（600） | 81 | 9/9 | 译码为"27 类 one-hot + 常量表" |
| Ren | 已合并 | 963（485） | 77 | 12/12（5 仅随机）| |
| Dispatch | 已合并 | 1268（1122） | 76 | 16/17（1 等价）| 顶层 298 行中 109 行为端口声明 |
| Rob | 已合并 | 1112（921） | 79 | 10/11（1 等价）| exu2rob 核对结果：不是 stale 读 |
| Csr | 已合并 | 681（586） | 77 | 15/15（6 仅随机）| 真实程序对 CSR 覆盖很薄，随机 trace 作用大 |
| PreIduQueue（含 InstructionBuffer、FTQ）| 已合并 | 664（561） | 77 | 18/18（5 仅随机）| 含真实隐含依赖 `flush_prev_q`（见 04）；spec 里有 3 个多余的"限定输出"待清理 |
| Isu（含 IssueQueue）| 已合并 | 944（1119） | 77（已删，需重录） | 16/17（1 等价）| 唤醒矩阵换位图；MUL 管线 kill 逻辑在当前配置下不可验证 |
| TlbMmu（仅 DTLB；核心参数化可复用于 ITLB，未验证）| 已合并 | 633（~400 生效，C++ 共 3400）| 79 | 34/34（20 仅随机，2 仅 stale）| 真实程序仅 7 次 walk、9 次 fence，几乎全靠随机 trace；PTW 输出靠镜像结构体读适配器（布局依赖） |
| Exu 整数 FU：alu/bru/agu/sdu/csr_fu/mul/div | 已合并 | ~1350（C++ 730）| 每组 73+3~4 | 47/47（11 仅随机）| 多出的行数来自真正的迭代除法器与压缩乘法流水；恒定字段由 exu_ctrl 补 |
| FPU（手写）| 已合并 | 1180（C++ 380）| 81 | 35 中 33（2 等价）| 对 softfloat 组合差分 18 类×1200 万向量 0 不一致；网表仅作可选交叉验证（`tests/fpu/netlist_ref/`），未进 rtl |
| exu_ctrl（Exu 仲裁/收集/旁路/清除）| 已合并 | 1171（C++ Exu.cpp 632）| 77 | 11/11（2 仅随机）| FU 边界约定见笔记；乘法槽重复接受的疑点由 exu_ctrl 的优先级规避 |
| RealLsu | 已合并 | 3211（含 3 个脚本生成文件 ~890 行；C++ 1527）| 85 | **15/25，10 个存活（未补激励）** | 3 个生成文件是 C++ 一拍内顺序改写的 SSA 展开，待重写为手写结构；状态数组散开未用结构体 |
| **back_top（后端整体，含 lsu）** | 已合并 | 生成 1485 + exu 521 + glue 94 | 整程序锁步 | 集成层未做变异 | **68/68 程序整程序逐拍一致（协调者独立复核 136 条通过）**；12 实例、825 端口、多驱动 0；发现 8 个集成问题（见 `docs/modules/back_top.md`），其中 1 个修了 Ren（`src1_areg`）|

### 待办（基础设施与遗留）

- **存储阵列写法整改**（01 第 3.1 节）：Prf 寄存器堆、前端 FIFO 存储、Ren 检查点表、Csr 寄存器堆、TlbMmu TLB 阵列、PreIduQueue 的 FTQ 与指令缓冲、乘法流水；RealLsu 的 SSA 版本链（`st_v1..v5`）随 RealLsu 手写重构一起处理。

- **清理 tma 边带**：从 Idu/Ren/Dispatch/Rob 与 back_top 删除 `tma_mem_commit_is_load/store`（只服务于模拟器的提交记账，见 06 第 8 节），各模块重新回放/锁步。
- **PMU 单独设计**：硬件友好的事件计数，独立于逐拍对照（06 第 8 节）。
- `make cfg` 导出前端专有常量（FIFO 深度、TAGE 位宽、`PTAB_SIZE`）、MUL/DIV 实例数（现手写在 `front_pkg`、`exu_fu_pkg`）。
- exu_ctrl 集成需补上各 FU 被删的恒定字段（FPU/MUL/DIV 的 `op`，BRU/CSR 的 `result=0`，`diag_val`/`mispred`/`br_taken`/`page_fault_inst`/`flush_pipe` 恒 0）。
- 参考模型里给 `MemSubsystemPtwWalkPortAdapter` 加只读访问函数，去掉 TlbMmu 录制的镜像结构体布局依赖。
- PreIduQueue：删除 spec 里 3 个多余的"限定输出"（`ftq_commit_info_resp_valid*`），改用 `when` 引用输入；需重录。
- `gen_cfg_pkg.py` 导出 `GLOBAL_IQ_CONFIG`（队列深度）、`GLOBAL_ISSUE_PORT_CONFIG`（端口能力表），Isu 目前手写了这两张表并有一致性检查。
- `mutcheck.sh` 要区分"变异无法构建"与"变异存活"。
- 端口样板自动生成：顶层平铺端口到内部结构体的适配代码由 spec 生成，减少每个顶层几十到上百行声明。
- **整核闭环（后端）已完成**：back_top 整程序锁步 68/68。剩余：前端接入后的整核锁步；集成层变异检查；difftest 直接观测的状态（寄存器堆、RAT、CSR 堆）未在边界里直接比较；复位只测了"全零输入 3 拍"；coremark 只比较前 400 万拍。
- （已部分完成）模块间接口假设（如 Prf 的"单一生产者"、Rob 在误预测拍不提交、`diag_val` 在 BackTop 里的覆盖）只能在闭环时验证。
- 覆盖：RTL 行/分支覆盖率尚无（Verilator coverage 构建太慢）；真实程序仅录开头一段。

## 前端

| 模块 | 分支/合并 | RTL 行数 | trace | 变异 | 备注 |
| --- | --- | --- | --- | --- | --- |
| predecode / predecode_checker / sequential_next_pc | 已合并 | 共 853（front_basic 全部 8 个模块合计）| 73 真实 + 生成 | 34/34（10 仅生成 trace）| 纯函数用 C++ golden + 穷举/随机 |
| 4 个 FIFO（共用 `front_fifo`）+ front_ctrl | 已合并 | 同上 | 同上 | 同上 | 8 个 full/empty latch 不建；`base_pc` 只存 lane 0（集成层展开）；默认配置下 SC-L/loop 元数据恒 0 |
| BPU（TAGE/BTB/SC/loop/类型预测） | 未开始 | | | | 约 6k 行，分析报告对其内部"未核实" |
| ICache（含存储侧端口）| 未开始 | | | | 需第二个录制点；comb/seq 熔合与冲刷拍一拍推进两步需评审 |
| 前端顶层 front_top | 未开始 | | | | 依赖以上全部 |

## 访存子系统

| 模块 | C++ 来源 | 状态 | trace | 变异 | 偏差 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| RealDcache | MemSubSystem/RealDcache.cpp | 未开始 | | | | |
| MSHR / WriteBuffer | MemSubSystem/MSHR.cpp, WriteBuffer.cpp | 未开始 | | | | |
| PtwWalker | MemSubSystem/PtwWalker.cpp | 未开始 | | | | |
| MemRouteBlock / PeripheralAxi / MemSubsystem | MemSubSystem/ | 未开始 | | | | |

## uncore（范围待定）

| 模块 | C++ 来源 | 状态 | 备注 |
| --- | --- | --- | --- |
| AXI_LLC | axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp | 未决 | 需先定 16 倍频方案 |
| AXI_Interconnect | 同上 | 未决 | |
| DDR / MMIO / PhysMemory | | testbench | 不翻译 |
