# `rtl/tools/fuzz/` — 轻量微架构感知 RV64GC Fuzzer

针对乱序 RV64GC 核的零依赖随机程序压力生成器 + 并行运行器 + 自动二分缩减器。

## 5 种测试 Profile
- `alu_fp`：ALU/Zba/Zbb、移动消除链、MUL/DIV、F/D 写回口冲突风暴
- `lsu_stlf`：窄地址多宽度 STLF 重叠、WBP 写缓冲背压、AMO/LR-SC、同 set 冲突
- `fe_rvc`：RVC 16b/32b 混排、高密度前向分支、有界短循环、JAL/RET、fence.i
- `priv_trap`：CSR 读写、受控 `ecall` / 非法指令异常、`sfence.vma`
- `mixed`：上述所有组合（`--profile all` 轮询全部 5 种）

## 用法

```bash
cd rtl

# 1. 本机 16 核快速扫 100 个 seed（带 SVA + X-init unique + 严格 CSR/MMIO 对拍）
#    --tb 是核测试平台 core_tb（构建见 sva/README.md：SOC_FM=1 SOC_SVA=1 SOC_XINIT_UNIQUE=1 CORE_OUT=... bash tb/core/build.sh）
python3 tools/fuzz/fuzz_run.py \
  --tb "$PWD/build/core_verif/obj/core_tb" \
  --out "$PWD/build/fuzz_run" \
  --seeds 100 --profile all --strict --jobs 16

# 2. 用同一套随机生成器扫 function-model vs Spike（验证参考模型本身，速度比 RTL 快 100 倍）
#    先用 function-model/scripts/build_spike.sh 编出带 --diff 的 a.out，再跑：
python3 tools/fuzz/fuzz_run.py \
  --spike-fm /path/to/build-spike/a.out \
  --out "$PWD/build/fuzz_fm_spike" \
  --seeds 2000 --profile all --jobs 16

# 3. 若发现失败 seed，自动二分缩减为最小复现 .S
python3 tools/fuzz/minimize.py \
  --tb "$PWD/build/core_verif/obj/core_tb" \
  --src "$PWD/build/fuzz_run/failures/s42_mixed/prog.S" \
  -o "$PWD/build/fuzz_run/failures/s42_mixed/min.S" \
  --strict
```
