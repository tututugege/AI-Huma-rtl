# 05 模块清单与进度（唯一的进度来源）

状态：`未开始` → `spec` → `trace` → `rtl` → `绿` ；任何时刻出现问题写 `红` 并在备注说明。
"绿"的定义见 [02-development-flow.md](02-development-flow.md)（lint 干净 + 全部 trace 逐拍一致 + ≥3 个变异被抓到 + 评审通过）。

参考模型提交：`2f31e8d`（见 `tututugege-trace/baseline.lock`）。C++ 路径相对于 `baseline-sim/src`。

## 基础设施

| 项目 | 状态 | 备注 |
| --- | --- | --- |
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
| Exu / Fu | 未开始 | | | | 分析进行中；FP 网表需脚本转换 |
| FP 网表 fadd/fmul | 未开始 | | | | 脚本转换 + 对照验证 |
| RealLsu | 未开始 | | | | |
| TlbMmu | 未开始 | | | | |

### 待办（基础设施与遗留）

- PreIduQueue：删除 spec 里 3 个多余的"限定输出"（`ftq_commit_info_resp_valid*`），改用 `when` 引用输入；需重录。
- `gen_cfg_pkg.py` 导出 `GLOBAL_IQ_CONFIG`（队列深度）、`GLOBAL_ISSUE_PORT_CONFIG`（端口能力表），Isu 目前手写了这两张表并有一致性检查。
- `mutcheck.sh` 要区分"变异无法构建"与"变异存活"。
- 端口样板自动生成：顶层平铺端口到内部结构体的适配代码由 spec 生成，减少每个顶层几十到上百行声明。
- 整核闭环验证：模块间接口假设（如 Prf 的"单一生产者"、Rob 在误预测拍不提交、`diag_val` 在 BackTop 里的覆盖）只能在闭环时验证。
- 覆盖：RTL 行/分支覆盖率尚无（Verilator coverage 构建太慢）；真实程序仅录开头一段。

## 前端

| 模块 | C++ 来源 | 状态 | trace | 变异 | 偏差 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| fetch_address_FIFO / instruction_FIFO / PTAB / front2back_FIFO | front-end/fifo/*.cpp | 未开始 | | | | |
| predecode / predecode_checker | front-end/predecode*.cpp | 未开始 | | | | |
| BPU（TAGE/BTB/SC/loop/类型预测） | front-end/BPU/ | 未开始 | | | | |
| ICache | front-end/icache/ | 未开始 | | | | |
| 前端顶层 | front-end/front_top.cpp | 未开始 | | | | 需先还原数据流（04 第 3.2 节） |

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
