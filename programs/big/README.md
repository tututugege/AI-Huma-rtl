# 固定的缩短版大程序（2026-11-04 起为标准）

- `dhrystone.bin`：64 次迭代（`build_dhry.sh 64`），当前默认配置下 RTL 与 trace-model 都是 116,774 周期（`scripts/ref_cycles.txt`；2026-11-04 的 150,838 周期是旧配置）。
- `coremark.bin`：2 次迭代（`buildcm.sh`），当前默认配置 284,902 周期（`scripts/ref_cycles.txt`）。这两个都是 rv32 程序，rv64 没有对应的缩短版。
- 不再使用 10000 次 dhrystone / 10 次 coremark 的完整版；`*.bak` 是当时的备份，仅留档，需要时可用构建脚本重建（改迭代次数参数）。
- 构建脚本需要 Homebrew LLVM（riscv32）和 `libc_min.c`、`inc/` 里的桩头文件，均在本目录。
