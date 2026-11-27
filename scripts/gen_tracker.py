#!/usr/bin/env python3
"""Generate docs/05-module-tracker.md (the module index) from the front-matter of docs/modules/*.md.

Front-matter fields read: area, rtl, depth.  Measured by this script: the number of RTL files and lines of the module's directories.
The index is generated: change the module doc and rerun `make tracker`; do not edit 05-module-tracker.md by hand.
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AREAS = [('backend', '后端'), ('frontend', '前端'), ('memsys', '访存子系统'), ('core', '整核、PMU 与公共代码'), ('soc', '全片 SoC 与 AXI4 互联'), ('uncore', 'uncore')]


def front_matter(path):
    t = open(path).read()
    m = re.match(r'---\n(.*?)\n---\n', t, re.S)
    if not m:
        return None
    return {k.strip(): v.strip() for k, v in (l.split(':', 1) for l in m.group(1).splitlines() if ':' in l)}


def rtl_stats(rtl):
    """Files and lines of the paths named in the `rtl:` field (directories or .sv files; text in brackets is ignored)."""
    files = set()
    for pat in re.findall(r'rtl/[A-Za-z0-9_./]+', rtl):
        full = os.path.join(ROOT, pat.rstrip('./'))
        if full.endswith('.sv'):
            files.update(glob.glob(full))
        else:
            for dp, _, fs in os.walk(full):
                files.update(os.path.join(dp, f) for f in fs if f.endswith('.sv'))
    return len(files), sum(sum(1 for _ in open(f)) for f in files)


def depth_of(text):
    """The depth in generic-gate levels written at the start of the `depth:` field, or the word that says it was not measured."""
    m = re.match(r'(\d+)\s*层', text)
    return f'{m.group(1)} 层' if m else ('待测' if '待测' in text else text.split('（')[0] or '-')


def main():
    rows = {}
    for p in sorted(glob.glob(os.path.join(ROOT, 'docs/modules/*.md'))):
        fm = front_matter(p)
        if fm and 'area' in fm:
            rows.setdefault(fm['area'], []).append((os.path.basename(p)[:-3], fm))
    out = ['# 05 模块清单', '',
           '> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 每个原子模块一份设计文档 `docs/modules/<模块>.md`，格式见 [modules/TEMPLATE.md](modules/TEMPLATE.md)，开发流程见总仓库 [docs/WORKFLOW.md](../../docs/WORKFLOW.md) 第 7 节（先写文档再改 RTL，提交前核对）。',
           '> 文件数、行数是实测值；深度来自各文档头部的 `depth:`（单模块综合的结构深度，生成门代理，不是时序；`待测` = 还没量过）。待办见总仓库 [docs/TODO.md](../../docs/TODO.md)。', '']
    tot_f = tot_l = 0
    for key, title in AREAS:
        if key not in rows:
            continue
        out += [f'## {title}', '', '| 模块 | RTL（文件/行） | 深度 |', '| --- | --- | --- |']
        for name, fm in rows[key]:
            nf, nl = rtl_stats(fm.get('rtl', ''))
            tot_f += nf
            tot_l += nl
            out.append(f"| [{name}](modules/{name}.md) | {nf}/{nl} | {depth_of(fm.get('depth', '-'))} |")
        out.append('')
    out += [f'合计（各文档的目录有重叠时会重复计数）：{tot_f} 个文件，{tot_l} 行。', '']
    open(os.path.join(ROOT, 'docs/05-module-tracker.md'), 'w').write('\n'.join(out))
    print(f'wrote docs/05-module-tracker.md ({tot_f} files, {tot_l} lines)')


if __name__ == '__main__':
    sys.exit(main())
