# 09 综合报告历史归档（早期 Yosys 通用门代理 §1–14）

> 现行权威综合报告（TSMC 28nm HPC+ Synopsys DC）见 [../09-synthesis-report.md](../09-synthesis-report.md)。

# 综合报告（面积代理，2026-11-05）

**这是什么**：对 283 个 RTL 模块逐个做通用门级综合（yosys + yosys-slang），得到每个模块的单元数、触发器数。
它是**相对面积代理**：用来比较"改动前后"和"哪里最大"，不是流片签核数字（没有工艺库、没有时序约束、没有布局）。

早期逐模块表见 git 历史中的 `synth/modules.csv`。**注意**：本报告和 `modules.csv` 是改配置之前（`IQ_INT` 128 等）的数字；2026-11-05 起默认配置是第 3 批，受影响模块的新数字见第 9 节，最新 TSMC 28nm DC 综合数据见第 15–18 节。脚本：[../scripts/synth_module.sh](../scripts/synth_module.sh)。

> **适用范围（2026-11-12 补充）**：第 1–8 节的数字是 2026-11-05 对**当时的 rv32 配置、旧 LSU 之前的树**实测的（283 个模块，`LSU_PIPE=0` 的 `lsu_core`/`lsu_stlf`/`lsu_ring` 等；第 9 节是第 3 批配置的受影响模块）。此后默认配置已改为分级 LSU（`lp_*`，`LSU_PIPE=1`）、紧凑 ROB（`rob_core_cpt`）、store 写缓冲（`lp_wbuf`）、IQ 入队宽度 7/6/4/4/5（EXP-017）、移动消除、L1D 预取、PMU，并新增 rv64（`XLEN_BITS=64`，数据通路约翻倍）；**这些没有整机重做面积推算，rv64 完全没有综合过**。受这些改动影响的模块的 yosys 面积/深度数字记录在对应记录里：`RTL_WBUF_NOTES.md`、`RTL_INTEG_NOTES.md`（均为通用门、无工艺库、无时序约束，`synth_depth.sh` 的深度是逻辑级数代理，不是 WNS）。`docs/synth/modules.csv` 仍是 2026-11-05 的快照。

## 1. 结论

| 项 | 数值 | 说明 |
|---|---|---|
| 模块总数 | 283 | 来自 `rtl_files.sh` 列出的全部 SV 文件 |
| 综合出数 | 265 | 逐模块扁平综合 |
| 纯连线（0 个单元） | 5 | `exu_ctrl_fu_in/out/view`、`exu_ctrl_lsu_req`、`dcache_cover` |
| 没综合出来 | 13 | 见第 4 节，用子模块加总推算 |
| 整机单元数（推算，下限） | **约 952 万个门** | 见第 3 节，不含 13 个失败模块自己的胶水逻辑 |
| 整机触发器（推算） | 约 18.1 万个 | |
| 存储块 | 364 个 `$mem` | 位数这次取不到，见第 5 节 |

最大的几块（推算，单位：门）：

| 区域 | 单元数 | 主要来源 |
|---|---|---|
| 后端 `u_core.u_back` | 约 700 万 | `isu` 212 万、`lsu_stlf` 109 万、`lsu_ring` 105 万 |
| 数据缓存 `u_mem.u_dcache` | 约 134 万 | 16 个 `dcache_bank` 约 114 万 |
| 前端 `u_core.u_front` | 约 66 万 | `icache` 57 万（含存疑的 `icache_arr`） |
| AXI `u_mem.u_axi` | 约 52 万 | `mem_axi` |

## 2. 方法和流程

每个模块单独作为顶层，`read_slang`（保持层次）→ 展平 → 手写的粗粒度优化 → `techmap` → ABC → `stat`。
设置（脚本里用环境变量开关）：

- `SYNTH_LIGHT=1`：轻量 ABC 脚本（`strash; map`），不用 yosys 默认的 ABC 脚本。
- `SYNTH_MEM=1`：存储阵列保留为 `$mem`，不展开成触发器。
- 不跑 `share`（SAT 资源共享）、不跑 `check`（组合环检查）。
- `SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob"`：放宽 slang 的循环展开上限，并把没走到的分支里的下标越界降为警告。
- 看门狗：每个模块最多 12 GB 内存、180 秒；单核顺序执行。

## 3. 整机推算怎么来的

`soc_top` 的整核综合不出来（门级网表太大）。做法：用 yosys 读入并展开整个设计（不综合），得到每个实例的层次路径；
对每个路径下"最外层、已经综合出数的实例"取其单元数相加（共 240 个实例）。

- 这是**下限**：失败模块自己的胶水逻辑（顶层连线、少量判断逻辑）没有算进去。
- 模块是按**默认参数**综合的，而实例的参数可能不同（例如 `isu_iq` 有 128 项和 64 项两种）。已知这会让个别模块的数字偏差，没有逐实例修正。

## 4. 没综合出来的 13 个模块

`soc_top`、`core_top`、`core_front`、`front_top`、`front_pred_path`、`bpu`、`bpu_tage`、`back_top`、`lsu`、`lsu_core`、`dcache`、`dcache_arr`、`mem_top`。

原因都是门级网表太大：`lsu`、`lsu_core`、`soc_top` 超过 12 GB 内存被杀，其余超过 180 秒。
它们都是包含大量子模块的聚合层，子模块各自有数字，第 3 节用的就是子模块的数字。
旧流程（默认 ABC）曾得到 `bpu` 87,815、`front_pred_path` 90,860，与统一流程不同口径，没有混进表里。

## 5. 数字的可信度和局限

- **相对值，不是绝对值**：通用门（`AND`/`NAND`/`MUX`/…）计数，没有工艺库。ABC 用的是轻量脚本，优化得比默认脚本少，所以数字偏大；同一个模块改前改后用同一流程比较才有意义。
- **存储位数取不到**：保留 `$mem` 后 `stat` 不打印存储位数，所以只有存储块个数（364）。存储本身的面积没有算进单元数，应该另外按位数估。
- **`icache_arr` 的 54 万个单元存疑**：其中约 27 万个 `$_MUX_`、26 万个 `$_NOT_` 的量级相当于整块存储的读多路选择器，可能是读口被展开成了逻辑。`icache`（57 万）包含它，所以 `icache` 也要打折看。
- **`isu` 的 212 万已核对，属实**：5 个发射队列（`IQ_INT` 128 项，其余 4 个 64 项，共 384 个槽）加总。每个槽有一个 `DW` 选 1 的 `ttg_onehot_mux` 写入选择，所以绝大多数是 `AND`/`NAND`。按槽数线性放大约 210 万，与实测相差约 4%。这是估算，不是分别综合每个队列的实测。

## 6. 综合过程中发现的问题

**yosys 的弱点（不是 RTL 写错，已在脚本里绕过）**

| 现象 | 例子 | 绕过 |
|---|---|---|
| 默认 ABC 脚本在深组合逻辑上跑不完 | `fpu_div`（7.4k 个门，28 级除法阵列） | 轻量 ABC，1 秒 |
| `share`（SAT）求解不收敛 | `lsu_dc_req_st`（189 万个 SAT 变量） | 不跑 `share`，17 秒 |
| `check` 在超宽向量上不收敛 | `icache_arr`（421 个单元、85 万线位） | 手写流程去掉 `check`，41 秒 |
| slang 对 `case` 里没走到的分支报下标越界 | `exu_ctrl_fu_in` | `-Wno-error=index-oob` |
| slang 对循环展开次数有上限 | `bpu_mem` | `--unroll-limit 100000` |

**RTL 写法问题（按 SV 规范应该改，已改，Verilator 本来放过）**

- [axi_subsys.sv:286](../rtl/memsys/axi_subsys/axi_subsys.sv)：`unused_hz` 把 unpacked 数组整体放进拼接，改成逐元素。
- [mem_top.sv](../rtl/memsys/mem_top/mem_top.sv)：`ax_mshr_*`、`ax_pa_*` 先用后声明，把声明挪到 `u_dcache` 实例之前。
- 验证：Verilator 全警告 lint 通过；改前改后各构建一个整核测试程序，跑 `atomic-boundary`，周期数 736、提交指令数 172，完全一致。只验证了一个程序，不是完整 smoke。

## 7. 面积上值得关注的点

- **发射队列入队选择**：每个槽对每条入队通道都有一套完整的选择（`isu_iq_store`），`isu` 的 170 万个 `AND`/`NAND` 基本来自这里。可考虑让每个槽只接一部分通道。（架构探索项，需要在 trace-model 里评估性能影响。）
- **LSU**：`lsu_stlf`（109 万）和 `lsu_ring`（单个 17.6 万个单元，共多个实例，合计 105 万）是后端第二、第三大。
- **数据缓存**：单个 `dcache_bank` 约 7.15 万个单元，16 个实例合计 114 万。

## 8. 复现

```bash
cd rtl
export SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob" SYNTH_LIGHT=1 SYNTH_MEM=1
bash scripts/synth_module.sh <模块名> 12000 180     # 结果在 build/synth/<模块名>.{log,stat}
```

yosys-slang 插件放在仓库之外：`/Users/ruyaoh/personal/yosys-slang/build/slang.so`（`SLANG` 环境变量可覆盖）。

## 9. 第 3 批面积配置后的受影响模块（2026-11-05）

配置变化（上层 `docs/EXPLORATION.md` EXP-005）：`BACKEND_FETCH_WIDTH` 16→8、`MAX_BR_NUM` 64→32、ibuf 128→64、front2back 32→8、
IQ INT/BR/STD 128/64/64 → 64/32/16（LD、STA 不变）、发射端口 LD/STA/STD/BR 4/4/4/4 → 4/3/3/2。
同一流程（第 2 节设置），`scripts/synth_cfg.sh` 在两种配置包下各综合一遍；“旧”列与 modules.csv 一致。

| 模块 | 旧配置 | 第 3 批 | 变化 |
|---|---|---|---|
| isu | 2,119,233 | 1,029,239 | −51% |
| prf | 376,833 | 282,121 | −25% |
| ren | 345,198 | 206,193 | −40% |
| rob | 235,182 | 201,297 | −14% |
| pre_idu_queue | 188,943 | 49,764 | −74% |
| exu（含 exu_ctrl、各 FU） | 107,137 | 91,509 | −15% |
| dispatch | 104,827 | 86,598 | −17% |
| idu | 97,352 | 30,640 | −69% |
| lsu_dc_req_st | 87,426 | 86,150 | −1% |
| tlb_mmu | 60,793 | 53,454 | −12% |
| 合计（以上 + front2back_fifo） | 3,723,024 | 2,117,024 | 约 −161 万（整机推算约 952 万的 17%） |
| 触发器（同范围） | 123,595 | 73,873 | 约 −5 万（整机约 18.1 万的 27%） |

- 存储阵列（`$mem`）不在单元数里，按位宽算：FTQ 约 −5.8 万位，front2back 约 −2.3 万位，ibuf 约 −2.8 千位。
- `lsu`、`dcache` 等综合不出来的聚合模块没算（端口减少在 DCache 写口、LSU STA 通路上的节省没有数字），所以是下限。
- 第 1 节的整机推算没有按新配置重做。

## 10. rv64 对 rv32 的面积 / 深度代理（2026-11-12，EXP-029）

**方法**：`scripts/synth_depth.sh`（本报告第 2 节设置加 `SYNTH_DEPTH=1`、`SYNTH_LTP=1` 的深度代理），同一棵树分别用 `XLEN_BITS=32`（`MUL_MAX_LATENCY=2`、`DIV_MAX_LATENCY=16`）和 `XLEN_BITS=64`（`MUL_MAX_LATENCY=3`、`DIV_MAX_LATENCY=32`）各综合一遍。24 个受 XLEN 影响的模块，按单元数增量排序。**有包含关系**：`front_top` 含 `bpu`、`icache`，`alu` 含 `alu_decode` / `alu_shift` / `alu_clmul` / `alu_bitcnt`，这些子模块的行是细分，求和时不能重复计。单元数是通用门，深度是展平后门级网表的最长拓扑路径（不含触发器），**无工艺库、无时序、无布局**，只是相对数字。

| 模块 | rv32 单元 | rv64 单元 | 变化 | rv32 深度 | rv64 深度 | 变化 |
|---|---|---|---|---|---|---|
| `prf` | 310,639 | 568,201 | +82.9% | 35 | 35 | +0% |
| `front_top`（含 `bpu`、`icache`） | 1,044,566 | 1,184,680 | +13.4% | 190 | 299 | +57% |
| `bpu` | 242,069 | 373,489 | +54.3% | 142 | 203 | +43% |
| `lp_l2` | 65,388 | 89,886 | +37.5% | 66 | 67 | +2% |
| `lp_wbuf` | 58,921 | 81,379 | +38.1% | 90 | 92 | +2% |
| `tlb_mmu` | 63,910 | 84,088 | +31.6% | 159 | 163 | +3% |
| `mul_core` | 7,565 | 28,411 | +275.6% | 120 | 213 | +78% |
| `alu`（含移位 / 位计数 / clmul） | 5,283 | 14,625 | +176.8% | 73 | 132 | +81% |
| `div_core` | 1,822 | 4,951 | +171.7% | 96 | 215 | +124% |
| `alu_clmul` | 1,985 | 8,065 | +306.3% | 8 | 11 | +38% |
| `icache` | 803,159 | 806,120 | +0.4% | 127 | 131 | +3% |
| `sdu` | 1,105 | 2,323 | +110.2% | 66 | 130 | +97% |
| `csr_regfile` | 1,392 | 2,548 | +83.0% | 11 | 11 | +0% |
| `lp_wk` | 3,417 | 4,468 | +30.8% | 61 | 63 | +3% |
| `bru` | 921 | 1,898 | +106.1% | 68 | 99 | +46% |
| `alu_shift` | 513 | 1,150 | +124.2% | 13 | 15 | +15% |
| `alu_bitcnt` | 564 | 1,127 | +99.8% | 26 | 32 | +23% |
| `agu` | 164 | 359 | +118.9% | 62 | 97 | +56% |
| `mem_route` | 398 | 524 | +31.7% | 10 | 10 | +0% |
| `ptw_walk` | 697 | 815 | +16.9% | 31 | 33 | +6% |
| `lp_ovl` | 133 | 141 | +6.0% | 12 | 13 | +8% |
| `alu_decode` | 177 | 176 | −0.6% | 11 | 12 | +9% |
| `dcache_wb` | 26,704 | 26,540 | −0.6% | 57 | 54 | −5% |
| `dcache_resp` | 17,443 | 15,236 | −12.7% | 22 | 23 | +5% |

**读法和结论**

- **面积**：去掉被包含的子模块后，18 个互不重叠的模块合计 1610468 → 2111073 单元（+31%，其中 `front_top` 就占 104 万 → 118 万）；增量主要来自 **PRF（+25.7 万，数据位宽翻倍）**、**BPU（+13.1 万，PC / 目标地址变宽，`bta`、uBTB 目标、RAS）**、`lp_l2` / `lp_wbuf`（+2.5 万 / +2.2 万，LSU 的 8 字节数据和 store 掩码）、`tlb_mmu`（+2.0 万，Sv39 三级、16 位 ASID）、`mul_core`（+2.1 万，64×64 → 128 位乘积）。单个 FU 的相对涨幅很大（`mul_core` +276%、`alu_clmul` +306%、`div_core` +172%），但绝对量小。
- **几乎不变**：`icache`（行和 AXI 侧仍是 32 位字）、`dcache_wb`、`dcache_resp`、`alu_decode`、`lp_ovl`、`mem_route`，与设计预期相符。
- **深度**：加法 / 比较链随位宽线性变长，因为本流程的 ABC 脚本不做快速加法器（`agu` 62 → 97、`sdu` 66 → 130、`bru` 68 → 99、`front_top` 190 → 299、`bpu` 142 → 203），**这些增量是代理的偏差，高估了真实实现里的深度**（真实综合会用超前进位）。`mul_core` 120 → 213、`div_core` 96 → 215、`alu` 73 → 132 是实打实更深的结构（乘除用了更多级 / 更宽的步进），其中除法每周期的步数在 `DIV_MAX_LATENCY=32` 下保持 2 步，深度翻倍来自 64 位的比较 / 减法链。
- **没有跑出来**：rv64 的 `dcache_bank` 超过 12 GB 内存看门狗被杀（rv32 是 162,674 单元）；`lsu_core`、`isu`、`rob`、`ren` 等大聚合模块没有做，它们的数据位宽依赖较小（rob 里只有 `diag_val` / `result` / PC 相关字段，ren / isu 基本不依赖 XLEN），预计不是主要来源，但没有实测。
- **不能回答**：真实频率、工艺库面积、时序（WNS）。这仍然**没有做**，需要工艺库和综合工具。
- **脚本**：`scripts/synth_depth.sh` 改为不用过长的 `xargs -I` 命令行（macOS 的 BSD xargs 对替换后的命令行有 255 字节限制，原来的写法在本机直接报 "command line cannot be assembled, too long"）。

## 11. TLB 并行化与 first_set 改为对数深度（2026-11-17，EXP-042）

**问题**：第 10 节里 `tlb_mmu` 深度 159（rv32）/ 163（rv64），是本表里除前端外最深的模块。`synth_depth.sh` 的最长路径：
lane 0 查表（64 项比较）→ `ttg_first_set`（`req & -req`，64 位进位链，约 60 级）→ lane 0 → lane 1 → … → lane 6 的 `chain`（8 个口串行，每口一次 refill 比较 + walk 状态选择）→ `ptw_walk_resp_consumed`。

**改动**（行为逐拍不变，见 `docs/modules/tlb_mmu.md` 第 3 节第 6 条、第 5 节）：
1. `tlb_mmu_core` / `tlb_mmu_lane`：8 个口并行计算，口间依赖改为两次 8 位 first_set（A：服务当前 walk 的口；B：启动新 walk 的口，三种情况各预选一个）；每口对两种回填视图预先算好结果，选择信号只控制最后一级二选一。
2. `ttg_first_set`（公共原语，37 个模块在用）：`req & -req` 改为 Kogge-Stone 前缀或（`log2 N` 级），函数相同。

**结果**（rv64 配置包，本报告第 2 节设置 + `SYNTH_DEPTH=1 SYNTH_LTP=1`，`synth_depth.sh`，main `8abb7ab` 对比改动后）：

| 模块 | main 单元 | 改后单元 | main 深度 | 改后深度 |
|---|---|---|---|---|
| `tlb_mmu` | 84,088 | 80,255 | 163 | **67** |
| `tlb_mmu_lookup` | 12,609 | 12,703 | 61 | 33 |
| `icache_itlb`（ITLB，1 口） | 14,058 | 13,967 | 68 | 49 |
| `lsu_stlf_match` | 53,209 | 53,289 | 139 | 97 |
| `bpu_main_sel` | 86,418 | 87,446 | 121 | 113 |
| `isu_alloc_chain` | 2,005 | 3,530 | 72 | 55 |
| `isu_iq_select` | 1,974 | 2,575 | 69 | 46 |
| `dcache_mshr_alloc` | 9,002 | 8,303 | 29 | 32 |
| `axi_llc_mshr` | 55,226 | 55,115 | 23 | 23 |
| `rob_commit_ctrl` / `ren_alloc_sel` / `lp_ffs` | 179 / 710 / 21 | 181 / 707 / 21 | 16 / 16 / 4 | 16 / 17 / 4 |

rv32 配置包（改动时在旧基线 `15af4b4` 上测）：`tlb_mmu` 159 → 63，`tlb_mmu_lookup` 55 → 32，`icache_itlb` 67 → 43。

**读法**：
- TLB 剩下的最长路径：查表（约 33 级）→ A 选择 → `a_ok` → B 选择 → `walk_q` 的 D 端；A→B 是语义本身的依赖（B 要知道 A 有没有让 walk 退休）。再往下要靠改结构（例如查表结果打一拍、或者限制 walk 只由 load 口启动），会改变周期，不在本次范围。
- first_set 的前缀或在宽向量上多用面积（`isu_alloc_chain` +1.5k、`isu_iq_select` +0.6k 单元/实例），换来深度下降。真实综合工具通常也会把 `req & -req` 映射成快速进位，所以这里的深度下降对 first_set 部分是**代理的偏差被修正**，对 TLB 的串行链部分是实打实的结构改进。
- 仍然没有工艺库和时序约束（不是 WNS）。

## 12. 2026-11-20 全模块综合基准（`main` `6e2d188`，含 EXP-048）与 Yosys 参数规范

### 12.1 权威综合参数与避坑记录

- **工具与路径（`eda-04` ~ `eda-10` 集群共享 NFS）**：
  - `yosys`：`/nfs_global/S/houruyao/tools/oss-cad-suite/bin/yosys`（`Yosys 0.71+52`）
  - `slang.so`：`/nfs_global/S/houruyao/tools/oss-cad-suite/share/yosys/plugins/slang.so`
- **正式口径环境变量**：
  ```bash
  export SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob"
  export SYNTH_LIGHT=1 SYNTH_MEM=1 SYNTH_LTP=1
  export SYNTH_ABC="strash;balance;map"
  ```
- **关键避坑（ABC `dc2` 级数虚高）**：
  - `scripts/synth_depth.sh` 默认 `SYNTH_DEPTH=1` 对应的 ABC 脚本为 `strash;balance;dc2;balance;map`，其中 **`dc2` 会把加法器/比较器重写成长串行进位链，将算术路径深度虚高 2~4 倍**。
  - 同日实测对照（`eda-04`）：
    - `bru`：含 `dc2` 为 **98 层**（1,908 单元）→ 去掉 `dc2`（`SYNTH_ABC="strash;balance;map"`）为 **28 层**（1,872 单元）→ 再加 `SYNTH_ADDER=kogge-stone` 为 **25 层**（3,263 单元）。
    - `mul_unit`：含 `dc2` 为 **90 层**（35,142 单元）→ 去掉 `dc2` 为 **31 层**（39,993 单元）。
  - 因此后续全模块深度评估**一律强制传 `SYNTH_ABC="strash;balance;map"`**（与 `WORKFLOW.md` §7.2 和 `scripts/fill_depth.py` 口径一致）；不设 `SYNTH_ADDER` 以保持与既有模块文档直接可比。
- **看门狗与运行隔离**：大模块放宽单进程看门狗至 `MAXMB=48000`、`TMO=3600`；各模块在计算节点本地 `/tmp` 独立工作目录执行，结果回传 NFS（`/nfs_global/S/houruyao/rtl_synth_work/res_20261120/`）。

### 12.2 全模块综合结果（`rtl` `6e2d188`，rv64gc 默认配置）

| 区域 | 模块 | 单元数 (`cells`) | 深度 (`depth`) | 耗时 | 备注 / 关键路径线索 |
|---|---|---:|---:|---:|---|
| 后端 | `csr` | 8,483 | 29 | 4s | 与旧版 29 层一致 |
| 后端 | `dispatch` | 186,536 | 56 | 101s | 与旧版 56 层一致 |
| 后端 | `exu_ctrl` | 20,133 | 17 | 22s | 与旧版 17 层一致 |
| 后端 | `exu` | 219,040 | 73 | 132s | 含 `exu_ctrl` 及全部 FU，与旧版 73 层一致 |
| 后端 | `idu` | 31,665 | 67 | 18s | 与旧版 67 层一致 |
| 后端 | `isu` | 948,982 | 90 | 266s | 100 层内 |
| 后端 | `lsu` | 1,227,891 | **101** | 475s | `pl12_q` → `u_ldq.g_e[30].u_ent.st_d` |
| 后端 | `pre_idu_queue` | 123,508 | 39 | 35s | 与旧版 39 层一致 |
| 后端 | `prf` | 679,466 | 27 | 157s | EXP-046 写口压缩后 36 → 27 层 |
| 后端 | `ren` | 474,613 | **111** | 181s | `inst_q` → `u_fp.u_ckpt.entry_q`（超 100 层） |
| 后端 | `rob` | 466,029 | 64 | 86s | 100 层内 |
| 后端 | `tlb_mmu` | 46,624 | 61 | 12s | 100 层内 |
| 后端 | `back_top` | 3,998,654 | **142** | 2516s | `u_lsu.u_pipe.u_core.u_ldq.g_e[17].u_ent.st_q` → `u_lsu...u_rp.srp_ptr_q` |
| 前端 | `front_ctrl` | 151 | 5 | 1s | 与旧版 5 层一致 |
| 前端 | `fetch_addr_fifo` | 122 | 13 | 1s | 与旧版 13 层一致 |
| 前端 | `icache` | 312,314 | 70 | 66s | EXP-045 SRRIP 后 69 → 70 层 |
| 前端 | `predecode` | 11,780 | 29 | 2s | 与旧版 29 层一致 |
| 前端 | `bpu` | 274,811 | **131** | 514s | **EXP-050 块级 1-Ahead FTB**：较旧 16-bank（549,458 / 134 层 / 3068s）单元数 **−50.0%**，最长路径仍在既有 `u_spec.aras_q[5]` → `u_spec.spec_d[49]` |
| 前端 | `front_top` | 898,333 | **153** | — | **EXP-050 后首次在 3600s 内顺利出数**（原 16-bank BPU 下超时） |
| 访存 | `axi_cpu_port_adapter` | 222 | 9 | 1s | 与旧版 9 层一致 |
| 访存 | `axi_interconnect` | 106,685 | 53 | 15s | EXP-048 MSHR/RQD 8→16 后 37 → 53 层 |
| 访存 | `axi_llc_bop` | 5,608 | **291** | 2s | **EXP-048 新增**：`best_q` → `replace_alu` → `q_line_q` |
| 访存 | `axi_llc` | 601,377 | **350** | 146s | 旧版 238 → 350，最长路径落入 `u_core.u_bop.q_line_q` |
| 访存 | `axi_subsys` | 689,367 | **353** | 184s | 受 `axi_llc`（`u_bop`）拉高（238 → 353） |
| 访存 | `dcache_pf` | 67,431 | **384** | 12s | **EXP-048 硬件 Berti**：`replace_alu` → `trig_go` → `u_gen.gen_left_q` |
| 访存 | `dcache` | **OOM (>64G)** | **OOM** | 421s | 整块触发 64 GB RSS 看门狗；**已按子模块全部拆测完成，见下表 12.2.1**（核心逻辑最深 `dcache_mshr` **123 层**） |
| 访存 | `mem_top` | **OOM (>64G)** | **OOM** | — | 同上（包含 `dcache`，触发 64 GB RSS 看门狗 64.4 GB） |
| 访存 | `mem_route` | 439 | 9 | 1s | 与旧版 9 层一致 |
| 访存 | `peripheral_axi` | 555 | 10 | 1s | 与旧版 10 层一致 |
| 访存 | `ptw_walk` | 807 | 47 | 1s | 与旧版 47 层一致 |
| 整核 | `pmu` | 11,566 | 90 | 4s | 与旧版 90 层一致 |

### 12.2.1 `dcache` 子模块拆测结果（2026-11-20，同口径 + `SYNTH_NO_MEMPRIO=1`）

| 子模块 | 单元数 (`cells`) | 深度 (`depth`) | 耗时 | 备注 / 关键路径 |
|---|---:|---:|---:|---|
| `dcache_mshr` | 91,934 | **123** | 44s | MSHR 8→16 后超 100 层：`ax_req_accepted` → `ax_req_line[25]` |
| `dcache_mshr_alloc` | 15,633 | 44 | 1s | 100 层内 |
| `dcache_wb` | 23,334 | 49 | 23s | 100 层内 |
| `dcache_wb_find` | 1,548 | 22 | 1s | 100 层内 |
| `dcache_s1` | 9,795 | 23 | 2s | 100 层内 |
| `dcache_s2_ld` | 5,074 | 37 | 1s | 100 层内 |
| `dcache_s2_st` | 1,150 | 29 | 1s | 100 层内 |
| `dcache_s2_fill` | 1,930 | 13 | 1s | 100 层内 |
| `dcache_resp` | 7,293 | 19 | 1s | 100 层内 |
| `dcache_pf_berti_hist` | 41,811 | 77 | 4s | 100 层内 |
| `dcache_pf_berti_tab` | 14,236 | **362** | 2s | **`dcache_pf` 384 层主源头**：`srch_pc[26]` → `trig_go` |
| `dcache_pf_berti_gen` | 5,385 | **172** | 1s | **`dcache_pf` 第二源头**：`gen_mask_q[0]` → `gen_mask_q[8]` |

### 12.3 本次全模块综合发现的待修项

1. **SV 规范问题（阻断 `dcache` / `mem_top` 综合）**：`rtl/memsys/dcache/dcache.sv` 第 76、79 行的 `retry_busy` 先用后声明，需将声明挪到使用前。
2. **EXP-048 预取器组合深度过高**：
   - `dcache_pf`（硬件 Berti）达到 **384 层**（路径经 `replace_alu` → `trig_go` → `u_gen.gen_left_q`）；
   - `axi_llc_bop`（LLC BOP）达到 **291 层**（路径经 `best_q` → `replace_alu` → `q_line_q`），直接把 `axi_llc` 和 `axi_subsys` 从 238 层拉升至 **350 / 353 层**。
3. **其余超 100 层模块**：`ren`（111 层，FP checkpoint 路径）、`lsu`（101 层，贴近 100 层红线）。

## 13. EXP-051 里程碑 B（`2-taken` + `2-ahead B` + 4-Bank `icache` / FDIP）受影响模块综合（2026-11-21）

在 `eda-04` / `eda-05` 按同口径（`SYNTH_LIGHT=1 SYNTH_MEM=1 SYNTH_LTP=1 SYNTH_NO_MEMPRIO=1 SYNTH_ABC="strash;balance;map"`，无 `dc2`，通用门代理、无工艺库/WNS）重测全部前端与 FTQ 受影响模块，结果存档于 `/nfs_global/S/houruyao/rtl_synth_work/res_fe2f/`：

| 模块 | EXP-050 `main`（单元 / 深度） | EXP-051 里程碑 B（单元 / 深度） | 变化 | 耗时 / 最长路径线索 |
|---|---:|---:|---:|---|
| `predecode` | 11,780 / 29 | **10,144 / 27** | −13.9% / −2 层 | 2s；`inst_valid[15] → predecode_target_address[63]` |
| `pre_idu_queue` | 123,508 / 39 | **137,578 / 38** | +11.4% / −1 层 | 32s；删 168b `bpu_ck` + 16×64b PC 比较，直接按 `ftq_offset` 索引；`front2pre_valid[1] → u_ibuf` |
| `tlb_mmu` | 46,624 / 61 | **46,624 / 61** | 0.0% / 0 层 | 23s；DTLB `NPEEK=0` 零开销（ITLB `NPEEK=2` 计入 `icache`） |
| `icache` | 312,314 / 70 | **916,659 / 106** | +193% / +36 层 | 139s；4-Bank 1R1W + 2 读口 ITLB peek + 2-slot FDIP；`u_ctl.r_q[136] → mmu_req_vtag[4]` |
| `bpu` | 274,811 / 131（旧 16-bank 549,458 / 134） | **504,078 / 272** | +83.4%（较旧 16-bank **−8.3%**）/ +141 层 | 959s；`r1_q[1074] → u_spec.spec_d[99]`（S2 双块校验→投机历史更新链） |
| `front_top` | 898,333 / 153 | **1,582,763 / 356** | +76.2% / +203 层 | 1123s；`u_pred_path.u_bpu.r1_q[1074] → PTAB 旁路 → u_pd.pd_ras_op2_q[1]` |

> **关键发现与后续降深度方向**：
> 1. `bpu` 在加入 2-taken + 2-Ahead B + 1024b `HistRing` + 内部 `rec_q[256]` 后单元数（504k）仍低于 EXP-050 前旧 16-bank BPU（549k，−8.3%），`predecode` / `pre_idu_queue` 深度均小幅下降（27 / 38 层）；
> 2. `bpu`（272 层）与 `front_top`（356 层）的最长路径均起于 `r1_q[1074]`（S2 双块 `fin` → `fin_b` 串行校验），分别穿入 `u_spec.spec_d` 与 PTAB 旁路→`u_pd.pd_ras_op2_q`；`icache`（106 层）略超 100 层红线。上述三项均已登记至总仓库 `docs/TODO.md` 综合深度优化清单，作为下一阶段前端时序拆拍的精确切入点。

## 14. EXP-053 前端结构清理（Phase 1 零周期重构 + Phase 2 去补丁微架构重构，2026-11-21）

在 `eda-04` / `eda-05` / `eda-06` 按同口径（`SYNTH_LIGHT=1 SYNTH_MEM=1 SYNTH_LTP=1 SYNTH_NO_MEMPRIO=1 SYNTH_ABC="strash;balance;map"`，通用门代理、无工艺库/WNS）对前端与受影响后端/访存模块重测，结果存档于 `/nfs_global/S/houruyao/rtl_synth_work/res_p2/`：

- **Phase 1（零周期改动结构重构）**：真 4-bank 1R1W `icache_arr` + 并行 SRRIP；`bpu_eval` 并行 `ftb_eval_ent`、`bpu_hist_vec` 零取模并行移位、切断 `r1_q → ovr_a → spec_a → g0_b` 假路径、收紧 `MAX_SYM`；`inst_fifo_entry_t` 改存紧凑原始半字 + 单份展开预译码与 4 轮 Kogge-Stone `start_a/b` 前缀扫描挪至 `front_head_fix`；彻底删除死线 `tage_idx` / `tage_tag` / `ftq_commit_info_resp_valid_t`。
- **Phase 2（微架构去补丁）**：
  - **P2-1**：删除跨子系统 `fdip_snoop_dirty` / `fdip_snoop_line` 旁路，改为 FDIP 发射前借既有 `dc_req`/`dc_resp` 通道做 1 拍 DCache/WB/MSHR/fill 一致性探针；删除 `resp_popped_q` 回波补丁，改为在 `axi_cpu_port_chan` 通道 0 参数化 `CLEAR_ON_POP=1` 从根源消除陈旧响应回波；
  - **P2-2**：删除跨页 RVC 第二半字取指缺页经 `inst -> diag_val[1]` 搭便车编码，改为显式 1-bit `pf_inst_hi` 贯穿 `front_head_fix → front2back → core_front2back → pre_idu → idu → ren → dis → rob → rob_trap_ctrl`。

| 模块 | EXP-051 里程碑 B（单元 / 深度） | EXP-053 Phase 1+2（单元 / 深度） | 变化 | 备注 / 最长路径线索 |
|---|---:|---:|---:|---|
| `front_top` | 1,582,763 / 356 | **1,159,189 / 216** | **−26.8% / −39.3%** | `mem_v2=180`；`u_pred_path.u_bpu.r1_q[1106] → u_pred_path.u_pd.ras_val_d[29]` |
| `bpu` | 504,078 / 272 | **410,093 / 197** | **−18.6% / −27.6%** | `mem_v2=169`；`r1_q[1106] → u_spec.spec_d[144]` |
| `icache` | 916,659 / 106 | **389,270 / 114** | **−57.5% / +8 层** | `mem_v2=7`；真 4-bank 1R1W 面积腰斩超半；`u_ctl.r_q[136] → Mux$12092[30]` |
| `pre_idu_queue` | 137,578 / 38 | **131,433 / 38** | **−4.5% / 0 层** | `mem_v2=8`；删死 `tage_idx/tag` + 加 1b `pf_inst_hi`；`front2pre_valid[1] → pre_issue_entries_ftq_is_last[3]` |
| `axi_cpu_port_adapter` | 222 / 9 | **227 / 9** | +2.3% / 0 层 | 通道 0 增加 `CLEAR_ON_POP=1`，仅 +5 单元、深度不变 |
| `dcache_bank` | — | **142,429 / 12** | 删 `fdip_snoop` 读口 | `mem_v2=6`；删除 `fdip_snoop_dirty` / `fdip_snoop_line` 端口 |
| `dcache_s2_ld` | 5,074 / 37 | **5,097 / 37** | +0.5% / 0 层 | 支持 1 拍 `icache` 一致性探针（`ic_probe` 复用既有 load 口） |
| `dcache_wb` | 23,334 / 49 | **23,334 / 49** | 0.0% / 0 层 | 删除 `fdip_snoop` 端口，面积深度零回归 |
| `rob` | 466,029 / 64 | **466,653 / 64** | +0.1% / 0 层 | 槽位显式增加 1-bit `pf_inst_hi`（+624 单元，深度不变） |

