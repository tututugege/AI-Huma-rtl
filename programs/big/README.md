# 固定的缩短版大程序（2026-11-04 起为标准）

- `dhrystone.bin`：64 次迭代（`build_dhry.sh 64`）。当前周期数以 `scripts/ref_cycles.txt` 为准（写这句时是 101,277 周期，RTL 与 trace-model 相同）。
- `coremark.bin`：2 次迭代（`buildcm.sh`），当前周期数以 `scripts/ref_cycles.txt` 为准（写这句时是 285,752 周期）。
- 两个都是 rv64ima 程序（`--target=riscv64 -march=rv64ima_zicsr_zifencei`，不含 C 扩展）。
- 不再使用 10000 次 dhrystone / 10 次 coremark 的完整版；需要时可用构建脚本重建（改迭代次数参数）。
- 构建脚本需要 Homebrew LLVM（riscv64）、trace-model 的 `baremetal/` 源码，以及本目录的 `libc_min.c` 和 `inc/` 里的桩头文件。
