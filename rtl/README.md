# rtl/ 目录

```
common/                 配置包 ttg_cfg_pkg（make cfg 生成，rv64gc）、fp_pkg 与 5 个原语（ttg_first_set / onehot_mux / onehot_to_idx / pick_k / popcount），所有模块共用
common/sram/            SRAM 包装 ttg_sram_1rw / ttg_sram_1r1w（复位期间把 INIT_VAL 写满每个地址）、复位延长 ttg_rst_sweep、ttg_sram_pkg（SRAM_SWEEP_CYCLES = 4100）
backend/<模块>/         后端：prf idu ren dispatch rob（rob_core，紧凑 ROB）csr ftq_ibuf isu tlb_mmu exu_fu（含 FPU：fp_*）exu_ctrl lsu（顶层 lsu / lsu_pipe + lp_* 分级 LSU）
backend/back_top/       后端顶层：back_top.sv、exu.sv（原为生成文件，生成器已删除，现在手改）、back_top_glue.sv、back_br_redirect.sv、iss_rr_reg.sv
frontend/               前端基础块（FIFO、预译码、front_ctrl 等，平铺文件）
frontend/bpu/           分支预测（类型预测/BTB/TAGE/历史+RAS/更新队列）
frontend/icache/        指令缓存（含 ITLB 胶合）
frontend/front_top/     前端顶层
memsys/<模块>/          访存子系统：dcache（含驱逐脏行的缓冲 dcache_wb 和预取 dcache_pf；EXP-024 的 store 写缓冲在 lsu 里：lp_wbuf）mem_route ptw_walk peripheral_axi axi_cpu_port_adapter（+ memcpu_pkg）axi_interconnect axi_llc axi_subsys mem_top
core/core_top/          前后端联调顶层（边界为存储侧口与退休流）
core/soc_top/           整核顶层 soc_top = core_top + mem_top（手改，原生成器已删除）
pmu/                    性能计数器块与事件总线（tier 1，CSR 未接）
soc/<模块>/             全片 SoC：chip_top（核 + 双层 Full-AXI4 + 片上外设）soc_axi soc_xbar soc_bootrom soc_sram soc_clint soc_plic soc_uart soc_sysctrl soc_crg soc_pkg（见 docs/modules/chip_top.md）
```
- 一个目录一个模块族；顶层文件名与目录同名，只做端口适配，逻辑在子模块。
- 行数、文件数以及各模块状态见 [docs/05-module-tracker.md](../docs/05-module-tracker.md)（自动生成，只列有笔记的模块）。
- DDR、MMIO/UART、PhysMemory、DMA、difftest 不在 rtl/，留在 testbench（范围见 docs/00）。
