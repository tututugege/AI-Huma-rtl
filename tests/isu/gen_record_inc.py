#!/usr/bin/env python3
"""Emit the record block (S("name", elem, value) lines) for tests/isu/rand_trace.cpp from the @ expressions of spec/isu.io.
usage: gen_record_inc.py spec/isu.io out.inc     ('bt.' is dropped: the generator keeps the IO structs as locals)"""
import re, sys
out = []
for line in open(sys.argv[1]):
    line = line.split('#')[0].strip()
    if not line or line.startswith('module'):
        continue
    head, expr = line.split('@', 1)
    t = head.split()
    name = t[1]
    dims = [int(m) for m in re.findall(r'\[(\d+)\]', head)]
    expr = expr.strip().replace('bt.', '')
    body = f'S("{name}", ' + ' + '.join(['0'] if not dims else
        [f'i{k}*{int(__import__("math").prod(dims[k+1:]))}' for k in range(len(dims))]) + f', (uint64_t)({expr}));'
    pre = ''.join(f'for (int i{k}=0;i{k}<{d};i{k}++) ' for k, d in enumerate(dims))
    out.append(pre + body)
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
