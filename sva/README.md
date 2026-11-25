# `rtl/sva/` — 非侵入式 SVA 断言与覆盖率框架

本目录通过 SystemVerilog `bind` 将微架构不变量断言与功能覆盖点挂载到 RTL 模块上：
- **零综合污染**：`scripts/rtl_files.sh` 与综合脚本不会拉入本目录。
- **零快速测试拖慢**：默认构建全部关闭，仅在显式传参时启用。

## 可用开关

### 编译期（`tb/soc/build.sh`）
| 开关 | 默认值 | 作用 |
|---|---|---|
| `SOC_ASSERT=1` | `0` | 开启 Verilator `--assert`（激活 RTL 内已有断言） |
| `SOC_SVA=1` | `0` | 挂载 `rtl/sva/*.sv` 并自动开启 `--assert` |
| `SOC_XINIT_UNIQUE=1` | `0` | 将 `--x-assign 0 --x-initial 0` 切换为 `unique`（暴露去复位数组的未初始化依赖） |
| `SOC_COV=1` | `0` | 开启 Verilator line + user（SVA cover）覆盖率（快速）；`SOC_COV=all` 额外加 `--coverage-toggle`（适合集群长跑），退出时写入 `SOC_TB_COV_OUT` |

### 运行期（`soc_tb`）
| 环境变量 | 默认值 | 作用 |
|---|---|---|
| `SOC_TB_FM_STRICT=1` | 关 | 在 `SOC_TB_FM=1` 下额外校验：MMIO/跨字 store 数据 + 每次提交周期边界的 `privilege` 与 18 个架构 CSR（含 `fcsr`） |
| `SOC_TB_COV_OUT=<path>` | `coverage.dat` | `SOC_COV=1` 构建时的覆盖率输出文件路径 |

## 示例命令

```bash
export PATH="$HOME/rv64spec/verilator_src/bin:$PATH"
cd rtl

# 构建全开验证版 soc_tb（不影响默认快速版 build/soc_fm）
SOC_FM=1 SOC_SVA=1 SOC_XINIT_UNIQUE=1 SOC_OUT=$PWD/build/soc_verif bash tb/soc/build.sh

# 跑全量 69 程序门禁（开启严格 CSR/MMIO store 对拍）
SOC_TB_FM_STRICT=1 bash scripts/fm_gate.sh $PWD/build/soc_verif/obj/soc_tb $PWD/build/gate_verif
```
