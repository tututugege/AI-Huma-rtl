#!/usr/bin/env python3
"""Literal array sizes -> configuration parameters, by wire-name prefix (the spec/boundary names come from the reference model).
`param_for(name, n)` returns the parameter that a dimension of size n of signal `name` stands for (None = leave the literal).
The numeric value must equal the literal today; the point is that a configuration change then flows through.
usage: dimmap.py --apply <files...>     rewrite declarations in place"""
import re
import sys

RULES = [
    # (name regex, literal, parameter)
    (r'^(rob_commit|ftq_commit|commit_extra|out_commit|nc_rob_commit)', 8, 'COMMIT_WIDTH'),
    (r'^(dis2rob|ren2dis|dec2ren|dis2lsu|lsu2dis|pre_issue|dis2iss|nc_dis2|idu_consume)', 8, 'DECODE_WIDTH'),
    (r'^(prf2exe_iss|exu2rob_entry|iss2prf_iss|exe2prf_entry|exe2iss_fu)', 22, 'ISSUE_WIDTH'),
    (r'^(exe2lsu_ldu|dcache2lsu_load|lsu2dcache_load|mmu2lsu_ldq|lsu2mmu_ldq|nc_mmu2lsu_ldq)', 4, 'LSU_LDU_COUNT'),
    (r'^(exe2lsu_sta|lsu2exe_sta|lsu2dcache_store|dcache2lsu_store|mmu2lsu_stq|lsu2mmu_stq|nc_mmu2lsu_stq)', 4, 'LSU_STA_COUNT'),
    (r'^exe2lsu_sdu', 4, 'LSU_SDU_COUNT'),
    (r'^(lsu2exe_wb|prf_awake)', 4, 'LSU_LOAD_WB_WIDTH'),
    (r'^(front2pre_|pre2front_fire)', 16, 'BACKEND_FETCH_WIDTH'),
    (r'^exe2prf_bypass', 28, 'TOTAL_FU_COUNT'),
    (r'^iss_awake', 15, 'MAX_WAKEUP_PORTS'),
]
VALUES = {'COMMIT_WIDTH': 8, 'DECODE_WIDTH': 8, 'ISSUE_WIDTH': 22, 'LSU_LDU_COUNT': 4, 'LSU_STA_COUNT': 4, 'LSU_SDU_COUNT': 4,
          'LSU_LOAD_WB_WIDTH': 4, 'BACKEND_FETCH_WIDTH': 16, 'TOTAL_FU_COUNT': 28, 'MAX_WAKEUP_PORTS': 15}
for _, lit, p in RULES:
    assert VALUES[p] == lit, p


def param_for(name, n):
    for rx, lit, p in RULES:
        if n == lit and re.match(rx, name):
            return p
    return None


DECL = re.compile(r'^(?P<head>\s*(?:(?:input|output|inout)\s+)?(?:logic|wire)\s*(?:\[[^\]]+\]\s*)?)(?P<name>\w+)'
                  r'(?P<dims>(?:\s*\[\s*\w+\s*\])+)(?P<tail>\s*[,;)]|\s*//.*$|\s*$)')


def rewrite_line(l):
    m = DECL.match(l)
    if not m:
        return l
    def sub(mm):
        n = int(mm.group(1)) if mm.group(1).isdigit() else None
        p = param_for(m.group('name'), n) if n is not None else None
        return f'[{p}]' if p else mm.group(0)
    dims = re.sub(r'\[\s*(\w+)\s*\]', sub, m.group('dims'))
    return m.group('head') + m.group('name') + dims + m.group('tail') + l[m.end():]


def rewrite(text):
    return '\n'.join(rewrite_line(l) for l in text.split('\n'))


if __name__ == '__main__':
    if sys.argv[1] == '--apply':
        for f in sys.argv[2:]:
            s = open(f).read()
            n = rewrite(s)
            if n != s:
                open(f, 'w').write(n)
                print('rewrote', f)
