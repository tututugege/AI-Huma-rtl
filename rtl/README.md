# rtl/ 目录

```
common/                 配置包 ttg_cfg_pkg（make cfg 生成）与 4 个原语（ttg_*），所有模块共用
backend/<模块>/         后端：prf idu ren dispatch rob csr pre_idu_queue isu tlb_mmu exu_fu fpu exu_ctrl lsu
backend/back_top/       后端顶层（生成的 back_top.sv + exu.sv + 胶水）
frontend/               前端基础块（FIFO、预译码、front_ctrl 等，平铺文件）
frontend/bpu/           分支预测（类型预测/BTB/TAGE/历史+RAS/更新队列）
frontend/icache/        指令缓存（含 ITLB 胶合）
frontend/front_top/     前端顶层
memsys/<模块>/          访存子系统：dcache mem_route ptw_walk peripheral_axi axi_cpu_port_adapter（+ memcpu_pkg）；axi_interconnect、axi_llc 进行中
core/core_top/          前后端联调顶层（边界为存储侧口与退休流）
```
- 一个目录一个模块族；顶层文件名与目录同名，只做端口适配，逻辑在子模块。
- 行数、文件数以及各模块状态见 [docs/05-module-tracker.md](../docs/05-module-tracker.md)。
- DDR、MMIO/UART、PhysMemory、DMA、difftest 不在 rtl/，留在 testbench（范围见 docs/00）。
