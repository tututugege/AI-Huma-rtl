#!/usr/bin/env python3
"""Generate docs/05-module-tracker.md from the front-matter of docs/modules/*.md.

Hand-maintained fields (module notes): area, rtl, spec, status, lockstep, mutants, note.
Measured by this script: RTL line count/file count (rtl dirs), spec existence and field count.
Never edit 05-module-tracker.md by hand: change the module note and rerun `make tracker`.
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AREAS = [('backend', '后端'), ('frontend', '前端'), ('memsys', '访存子系统'), ('uncore', 'uncore（AXI 互连 / LLC）')]


def front_matter(path):
    t = open(path).read()
    m = re.match(r'---\n(.*?)\n---\n', t, re.S)
    if not m:
        return None
    return {k.strip(): v.strip() for k, v in (l.split(':', 1) for l in m.group(1).splitlines() if ':' in l)}


def rtl_stats(rtl):
    files = []
    for pat in rtl.split():
        if pat.endswith('.sv'):
            files += glob.glob(os.path.join(ROOT, pat))
        else:
            for dp, _, fs in os.walk(os.path.join(ROOT, pat)):
                files += [os.path.join(dp, f) for f in fs if f.endswith('.sv')]
    n = sum(sum(1 for _ in open(f)) for f in files)
    return len(files), n


def spec_stats(pats):
    fields, cnt = 0, 0
    for p in pats.split():
        for f in glob.glob(os.path.join(ROOT, 'spec', p if p.endswith('.io') else p + '.io')):
            cnt += 1
            fields += sum(1 for l in open(f) if re.match(r'\s*(in|out)\s', l))
    return cnt, fields


def main():
    rows = {}
    for p in sorted(glob.glob(os.path.join(ROOT, 'docs/modules/*.md'))):
        fm = front_matter(p)
        if fm:
            rows.setdefault(fm['area'], []).append((os.path.basename(p)[:-3], fm))
    out = ['# 05 模块清单与进度', '',
           '> **本文件由 `scripts/gen_tracker.py`（`make tracker`）生成，不要手改。** 改对应的 `docs/modules/<模块>.md` 的头部（front-matter），再重新生成。',
           '> RTL 行数、文件数、spec 数/字段数是脚本实测值；状态、锁步、变异是模块笔记里人工填写并经协调者复核的值。',
           '> 状态：`green` = lint 干净 + 整程序锁步全部通过 + 变异被抓到（存活者已判定）+ 独立复核；`partial` = 有已知缺口，见备注。',
           '> 未完成事项与路线图见 [07-roadmap.md](07-roadmap.md)。参考模型提交：`2f31e8d`。', '']
    tot_f = tot_l = 0
    for key, title in AREAS:
        if key not in rows:
            continue
        out += [f'## {title}', '', '| 模块 | 状态 | RTL（文件/行） | spec（个/字段） | 整程序锁步 | 变异 | 备注 |', '| --- | --- | --- | --- | --- | --- | --- |']
        for name, fm in rows[key]:
            nf, nl = rtl_stats(fm['rtl'])
            ns, nfld = spec_stats(fm['spec'])
            tot_f += nf
            tot_l += nl
            out.append(f"| [{name}](modules/{name}.md) | {fm['status']} | {nf}/{nl} | {ns}/{nfld} | {fm['lockstep']} | {fm['mutants']} | {fm['note']} |")
        out.append('')
    out += [f'合计：{tot_f} 个 RTL 文件，{tot_l} 行（不含 `rtl/common` 与 `ttg_cfg_pkg`）。', '']
    open(os.path.join(ROOT, 'docs/05-module-tracker.md'), 'w').write('\n'.join(out))
    print(f'wrote docs/05-module-tracker.md ({tot_f} files, {tot_l} lines)')


if __name__ == '__main__':
    sys.exit(main())
