# scripts/ 索引

| 类别 | 脚本 | 作用 |
| --- | --- | --- |
| 路径配置 | `env.sh`、`ttg_env.py` | 所有脚本共用的位置（`RTL_ROOT`、`AI_HUMA_ROOT`、`TTG_PROGS`、`TTG_BIG`、`TM`），全部由所在位置推出，可由环境变量覆盖 |
| 构建/检查 | `lint.sh`、`rtl_files.sh`、`gen_cfg.sh`、`gen_tracker.py` | 规范检查（目录级）、RTL 文件序、配置包、进度表生成 |
| 整芯片检查 | `lint_chip.sh` | 以 `soc_top` 为顶的 Verilator `-Wall`（`lint.sh` 只按目录查）；`CFG=<包>` 用别的配置包检查而不安装，改参数前先用它找写死的位宽 |
| 综合对比 | `synth_cfg.sh <标签> <配置包> <模块...>` | 在指定配置包下逐模块综合（`synth_module.sh`，与 docs/09 同设置），结果在 `build/synth_<标签>/`，结束后恢复原配置包 |
| 整核闭环 | `soc_smoke.sh`、`cmp_trace_model.sh` | 整核 RTL 跑程序，周期/指令数与 trace-model 对比（**性能指标，不是门禁**） |
| 程序表 | `progs.txt`、`progs_smoke.txt`、`ref_cycles.txt` | 程序列表；`ref_cycles.txt` 是 trace-model 在当前配置下的周期数（gate 基线 + dhrystone/coremark），RTL 应与之逐个相等；配置改变时随 `make cfg` 一起更新 |
| 正确性门禁 | `fm_gate.sh <soc_tb> <输出目录>`；测试平台用 `SOC_FM=1 SOC_OUT=<绝对路径> bash tb/soc/build.sh` 构建 | `ref_cycles.txt` 里 69 个程序逐条提交对比 function-model（见 `docs/modules/soc_top.md`），输出 `summary.txt`，并报告与 `ref_cycles.txt` 周期不同的个数；**store 数据不在对比范围内，改动访存/外设路径时还要对比串口输出** |

逐模块锁步、trace 录制/回放、变异检查和旧参考模型副本已退役：脚本在标签 `legacy-reference`（rtl 仓库）里。
| 分歧定位 | `first_diff.sh`、`first_diff.py` | 同一程序在 trace-model 和 RTL 上各出一份提交轨迹（周期 + PC），对比找第一处不同 |
