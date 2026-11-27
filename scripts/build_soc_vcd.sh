#!/usr/bin/env bash
# build_soc_vcd.sh [输出目录]   带整核波形导出的 rv64 SoC 测试平台（调试用，不是回归用：Verilator --trace 构建慢、仿真慢）。
#   运行：SOC_TB_VCD=<起始周期>:<结束周期>:<文件> soc_tb <镜像> <周期上限>，只在这个周期窗口内导出所有信号（窗口控制在几十个周期，文件不会大）。
#   查询：scripts/vcd_query.py <文件> --list <正则> / <正则>...  （按层次名取信号，逐周期打印变化）
#   与 build_soc64_linux.sh 相同：逐条 function-model 检查、-DTTG_EBREAK_TRAP、默认 4 线程；FMLIB 必填，TM_DIR、THREADS、JOBS 同。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
OUT=${1:-$ROOT/build/core64vcd}; THREADS=${THREADS:-4}
: "${FMLIB:?set FMLIB to the XLEN=64 FP=1 RVC=1 librefcpu.a of the function model}"
cd "$ROOT"
SOC_XLEN=64 SOC_FM=1 SOC_COPT="-O2 -DSOC_TB_TRACE" SOC_VOPT="-DTTG_EBREAK_TRAP --threads $THREADS --trace" FMLIB=$FMLIB CORE_OUT=$OUT TM_DIR=${TM_DIR:-$AI_HUMA_ROOT/trace-model} bash tb/core/build.sh
