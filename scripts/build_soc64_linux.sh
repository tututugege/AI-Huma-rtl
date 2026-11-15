#!/usr/bin/env bash
# build_soc64_linux.sh [输出目录]   rv64 SoC 测试平台，给「全程 Linux 回归」（linux_gate.sh）用。
#   - 逐条对 function-model 检查（SOC_FM=1，要求 FMLIB 是 XLEN=64、FP=1、RVC=1 的 librefcpu.a）
#   - -DTTG_EBREAK_TRAP：OpenSBI 用 ebreak 探测半主机，按断点异常处理（从复位启动必需；运行时再设 SOC_TB_SEMIHOST=1）
#   - 默认 4 个仿真线程（--threads 4）：全程 Linux 约 1.4 亿周期，单线程要多出 2~3 倍时间。THREADS=<n> 可改。
# 环境变量：FMLIB（必填）、TM_DIR（默认 $AI_HUMA_ROOT/trace-model，DRAMsim3 静态库在那里）、THREADS（默认 4）、JOBS（Verilator 编译并行度，默认 6）
# 注意：不带 --threads 构建出的仿真是单线程；只做几百万周期以内的检查点复现时可以用单线程（构建更快），但整段 Linux 回归一律用本脚本。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
OUT=${1:-$ROOT/build/soc64lin}; THREADS=${THREADS:-4}
: "${FMLIB:?set FMLIB to the XLEN=64 FP=1 RVC=1 librefcpu.a of the function model}"
cd "$ROOT"
SOC_XLEN=64 SOC_FM=1 SOC_VOPT="-DTTG_EBREAK_TRAP --threads $THREADS" FMLIB=$FMLIB SOC_OUT=$OUT TM_DIR=${TM_DIR:-$AI_HUMA_ROOT/trace-model} JOBS=${JOBS:-6} bash tb/soc/build.sh
