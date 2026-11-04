# 固定的缩短版大程序（2026-11-04 起为标准）

- `dhrystone.bin`：64 次迭代（`build_dhry.sh 64`），RTL 闭环 150,838 周期、291,923 条指令，与参考、trace-model 一致。
- `coremark.bin`：2 次迭代（`buildcm.sh`），226,991 周期。
- 不再使用 10000 次 dhrystone / 10 次 coremark 的完整版；`*.bak` 是当时的备份，仅留档，需要时可用构建脚本重建（改迭代次数参数）。
- 构建脚本需要 Homebrew LLVM（riscv32）和 `libc_min.c`、`inc/` 里的桩头文件，均在本目录。
