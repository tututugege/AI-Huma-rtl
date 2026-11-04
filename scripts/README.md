# scripts/ 索引

| 类别 | 脚本 | 作用 |
| --- | --- | --- |
| 路径配置 | `env.sh`、`ttg_env.py` | 所有脚本共用的位置（`RTL_ROOT`、`AI_HUMA_ROOT`、`TTG_PROGS`、`TTG_BIG`、`TM`），全部由所在位置推出，可由环境变量覆盖 |
| 构建/检查 | `lint.sh`、`rtl_files.sh`、`gen_cfg.sh`、`gen_tracker.py` | 规范检查（目录级）、RTL 文件序、配置包、进度表生成 |
| 整核闭环 | `soc_smoke.sh`、`cmp_trace_model.sh` | 整核 RTL 跑程序，周期/指令数与 trace-model 对比（**性能指标，不是门禁**） |
| 程序表 | `progs.txt`、`progs_smoke.txt`、`ref_cycles.txt` | 程序列表；`ref_cycles.txt` 是 trace-model gate 基线的周期数，只作性能回退的参照 |
| 正确性门禁 | 在 `tb/soc/`：`SOC_FM=1 bash tb/soc/build.sh`，运行 `SOC_TB_FM=1` | 逐条提交对比 function-model（见 `docs/modules/soc_top.md`） |

逐模块锁步、trace 录制/回放、变异检查和旧参考模型副本已退役：脚本在标签 `legacy-reference`（rtl 仓库）里。
