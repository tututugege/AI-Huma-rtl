---
module: peripheral_axi
area: memsys
rtl: rtl/memsys/peripheral_axi
spec: peripheral_axi
status: green
lockstep: 68/68
mutants: 26 个中 24 杀死，2 等价
note: 真实程序几乎不走该路径
---

# peripheral_axi 设计笔记（PeripheralAxi：LSU MMIO / uncached 访问单元）

分析与边界见 `docs/analysis/memsys-boundary.md` §2.4；录制点 `docs/analysis/memcpu-record-hook.md`。`PeripheralModel`（UART/CLINT/INTC/SD/boot/DMA/随机中断，805 行）、`PhysMemory` 留在 testbench，不翻。

## 1. 对应的 C++
- `MemSubSystem/PeripheralAxi.cpp`（264 行）+ `include/PeripheralAxi.h`（86 行）；调用：`MemSubsystem::comb_inputs` 里 `comb_outputs(); comb_inputs();`（tick 0），`seq`。LSU 的 `peripheral_req/resp` 与 EXTRA 读/写 AXI 主口（`bypass=1`）。
- 顶层 `peripheral_resp_hold`（`RV:1066/1110/1186`）在 SimCpu 里，不是本模块：边界输出是 `comb_inputs` 之后的 `*peripheral_resp`，hold 寄存器由顶层/core_top 负责一拍延迟。
- 边界：每 CPU 周期一条记录（`spec/peripheral_axi.io`，33 字段）。

## 2. 硬件结构
| 模块 | 职责 |
| --- | --- |
| `peripheral_axi`（顶层）| 端口适配，例化 `fmt` + `ctl` |
| `peripheral_axi_fmt` | 纯组合：按 func3 的访问大小（`size/wstrb/wdata` 打包）与读数据符号/零扩展（LB/LH/LW/LBU/LHU，其余原样）|
| `peripheral_axi_ctl` | 访问 FSM + 寄存器（`busy write accepted resp_valid addr wdata func3 rdata`，~104 位；C++ 的 `req_id`（恒 0）删除）|
```
 idle ──(is_mmio, region≠AXI)──► resp_valid (下一拍答复；env 读/写在接受拍发出)
      └─(is_mmio, region=AXI)──► busy: 发请求(直到 accepted) ─► 等响应 ─► resp_valid
```
**环境接口**（切在 testbench 一侧，不是 C++ 端口）：`env_region`（0=AXI，1=uncached RAM，2=modeled MMIO；uncached 优先于 modeled，= `simulator_is_uncached_memory_addr` / `PeripheralModel::is_modeled_mmio` 的译码）、`env_rd_en/addr/func3` → `env_rdata`（同拍组合返回最终读数据：`read_uncached_ram` / `PeripheralModel::read_load`）、`env_wr_en/addr/data/func3`（`write_uncached_ram`，uncached 写在接受拍发出，**在时钟沿由 testbench 生效**，不是组合副作用）。modeled 写**不**触发环境动作（真正的设备写在提交路径 `on_commit_store`，不属于本模块）。

## 3. 一拍内的数据流
1. 输出只来自寄存器：`resp_ready = !busy && !resp_valid`；`resp_is_mmio = resp_valid`，`resp_rdata = rdata`；busy 且未 accepted → AXI 请求（读/写 + addr + size + wstrb/wdata）；busy 且 accepted → `resp_ready`。
2. 次态（C++ `comb_inputs`，优先级链）：`resp_valid` → 清（本拍不接新请求）；空闲且 `is_mmio` → 本地服务（`resp_valid<=1`，`rdata<=wen?0:env_rdata`）或 AXI（`busy<=1`）；busy 未 accepted 且对应通道 `accepted` → `accepted<=1`；busy 已 accepted 且对应通道 `resp_valid` → `busy<=0,resp_valid<=1,rdata<=写?0:extract(resp_data0,func3)`。请求（addr/wdata/func3/write）在接受拍锁存。
3. C++ 里 `comb_inputs` 的读响应分支又重算 `peripheral_resp->ready = !nxt.busy && !nxt.resp_valid`——该分支里 `cur.busy` 为真，结果恒为 0，与"只由 `cur` 寄存器决定"的公式一致（已核对，随机/真实 `resp_ready` 均与公式吻合）。

## 4. 与 C++ 的差异点、放宽、不复刻
- 删除：`req_id`（恒 0，互连只用它标记事务；RTL 集成时把读/写口 id 接 0）、AXI `req_ready`（C++ 从不读）、`resp_id`（不读）、`resp_data[1..15]`、`wdata[1..15]`（恒 0）、`total_size` 高位（只有 0/1/3）、`nxt.write=false` 的清除（`write` 仅在 busy 时有意义）。
- 放宽（`when`）：`resp_rdata`←`resp_is_mmio`（LSU `RealLsu.cpp:286-304` 先判 `peripheral_resp->ready` / `is_mmio`）；AXI 请求负载←`req_valid`（互连读口只在 `req.valid` 内读）；`env_*` 负载←各自 `en`。
- **环境契约**：`env_rdata` 只在 `env_rd_en` 的拍有意义（写请求时 C++ 把 `rdata` 置 0，RTL 取 `req_wen ? 0 : env_rdata`；testbench 在 `env_rd_en=0` 时返回 0 则该保护与否等价——变异 `ctl_local_write_rdata` 因此存活）。
- 疑点（登记）：C++ 里 modeled 写请求本身没有任何设备动作（设备写在提交钩子里按 store 提交顺序发生），时序上"提交钩子"与"本模块 N+1 周期 resp_valid"相互独立；集成时 testbench 必须保持这一点。
- 真实程序**从不走 AXI 路径**：68 个程序里 `per_req_*_axi = 0`、`rdEX/wrEX_ready_never`（互连对 EXTRA 口从不 ready）——peripheral 的整个 busy 分支只有随机覆盖。

## 5. 验证
- spec：`spec/peripheral_axi.io`（33 字段）。
- 整程序锁步：68/68 PASS（真实流量：uncached 读 49036 / 写 48276、modeled 读 110 / 写 2222；`func3` 0/1/2/4/5 全有；请求到来时 `resp_valid` 为真而被忽略 49822 次）。
- 随机生成器（`-DMOD_PERI`，驱动**真实** `PeripheralAxi.cpp` + 真实 `PeripheralModel`，`pmem_read/write` 打桩）：6 个 profile × 6 万拍全 PASS；覆盖（profile 0）：AXI 读完成 3296、AXI 写完成 3420、uncached 读/写各 ~1100、modeled 读/写各 ~1100、func3 0–7 全部（3/6/7 约 140 次）、忙时请求被忽略 19057 次；握手"杂波"（该状态下应被忽略的 accepted/resp_valid 脉冲）每个通道 2–15%。
- 变异（`tests/memcpu/peripheral_axi_mutants.py`）：**26 个，24 个被杀**。真实程序锁步也杀的 5 个：空闲判定忽略 `resp_valid`、接受非 MMIO 请求、modeled 走 AXI、uncached 写扩到所有区域、本地读使能在写请求时也为真；**只靠随机才杀的 19 个**：全部 `fmt_*`（size/strobe/wdata 打包、LB/LH/LBU/LHU/默认的符号扩展）、AXI 通道互换、响应 ready 提前、写数据不屏蔽、写响应 rdata、func3/write 不锁存、答复持续两拍等——**peripheral 的 AXI 路径与 size/符号扩展在 68 个真实程序里完全没有被覆盖**，这些规则只有随机在证明。存活 2 个：`ctl_cpu_en_ignored`（锁步里 `cpu_en` 恒 1）与 `ctl_local_write_rdata`（环境契约：写请求时 `env_rdata` 恒 0，保护与否等价，见 §4）。
