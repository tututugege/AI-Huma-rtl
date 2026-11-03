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
| 参考模型录制钩子（只读） | 未开始 | 需要在录制分支实现；首个试点模块时一并做 |
| 闭环集成（RTL 接回参考模型） | 未开始 | 02 流程第 9 步 |

## 后端

| 模块 | C++ 来源 | 状态 | trace | 变异 | 偏差 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| Prf | back-end/Prf.cpp | 未开始 | | | | |
| PreIduQueue | back-end/PreIduQueue.cpp | 未开始 | | | | |
| Csr | back-end/Exu/Csr.cpp | 未开始 | | | | |
| Ren | back-end/Ren.cpp | 未开始 | | | | RAT/空闲表/checkpoint |
| Idu | back-end/Idu.cpp | 未开始 | | | | 含分支处理 |
| Rob | back-end/Rob.cpp | 未开始 | | | | |
| Dispatch | back-end/Dispatch.cpp | 未开始 | | | | |
| IssueQueue / Isu | back-end/Isu.cpp | 未开始 | | | | |
| Exu / Fu | back-end/Exu/Exu.cpp, Fu.h | 未开始 | | | | |
| FP 网表 fadd/fmul | back-end/Exu/include/fadd.h, fmul.h | 未开始 | | | | 脚本转换 |
| RealLsu | back-end/Lsu/RealLsu.cpp | 未开始 | | | | 最难的后端模块之一 |
| TlbMmu | back-end/Lsu/TlbMmu.cpp | 未开始 | | | | |

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
