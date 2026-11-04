# scripts/ 索引

| 类别 | 脚本 | 作用 |
| --- | --- | --- |
| 构建/检查 | `lint.sh`、`rtl_files.sh`、`gen_cfg.sh`、`gen_tracker.py` | 规范检查（目录级）、RTL 文件序、配置包、进度表生成 |
| 锁步（主路径） | `lockstep.sh`、`lockstep_multi.sh`、`lockstep_ticks.sh`、`lockstep_ticks_all.sh`、`lockstep_all.sh`、`lockstep_batch.sh` | 整程序实时锁步；`_ticks` 是 16 倍频访存域 |
| trace 回放（辅助） | `record*.sh`、`replay.sh`、`hbuild.sh`、`rehash.py`、`progs.txt` | 录制/回放/随机激励 |
| 变异 | `mut_backtop_fast.py`（模板）、`mut_backtop.py`、`mut_memcpu.py`、`mut_dcache.py`、`mutcheck.sh` | 一次构建、`TTG_MUT=k` 运行时选变异体 |
| 复核 | `review.sh`、`merge_modules.sh` | 协调者独立复核与合并辅助 |
| 参考模型 | `refsim_setup.sh` | 生成带钩子的参考模型副本 |

只有协调者修改已有脚本；agent 需要新工具时新增文件。
