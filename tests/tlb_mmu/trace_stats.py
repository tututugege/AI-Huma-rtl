#!/usr/bin/env python3
"""Coverage statistics of a tlb_mmu trace (.trc).  usage: trace_stats.py trace.trc [--dump N]
Reads the field layout from spec/tlb_mmu.io (same rules as harness/tools/iogen.py)."""
import re, struct, sys, os, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')

def layout():
    fields = []
    for raw in open(os.path.join(ROOT, 'spec', 'tlb_mmu.io')):
        line = raw.split('@')[0].split('#')[0].strip()
        m = re.match(r'^(in|out)\s+(\w+)\s+(\d+)((?:\s*\[\d+\])*)', line)
        if not m:
            continue
        dims = [int(x) for x in re.findall(r'\[(\d+)\]', m.group(4))]
        n = 1
        for d in dims:
            n *= d
        fields.append((m.group(1), m.group(2), int(m.group(3)), n))
    return fields

def read(path):
    f = open(path, 'rb').read()
    assert f[:8] == b'TTGTRC01'
    ib, ob, h, nl = struct.unpack_from('<IIQH', f, 8)
    off = 8 + 18 + nl
    fields = layout()
    recs = []
    rs = 9 + ib + ob
    while off + rs <= len(f):
        cyc, flags = struct.unpack_from('<QB', f, off)
        p = off + 9
        d = {}
        for dr, name, w, n in fields:
            eb = (w + 7) // 8
            vals = [int.from_bytes(f[p + i * eb:p + (i + 1) * eb], 'little') for i in range(n)]
            p += n * eb
            d[name] = vals if n > 1 else vals[0]
        recs.append((cyc, flags, d))
        off += rs
    return recs

if __name__ == '__main__':
    recs = read(sys.argv[1])
    dump = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == '--dump' else 0
    c = collections.Counter()
    for cyc, flags, d in recs:
        if flags & 1:
            continue
        c['cycles'] += 1
        satp_on = d['csr_status_satp'] >> 31
        if d['rob_bcast_fence']: c['fence'] += 1
        elif d['rob_bcast_flush'] or d['dec_bcast_mispred']:
            c['cancel'] += 1
            if d['ptw_walk_resp_valid']: c['cancel_with_resp'] += 1
            if d['ptw_walk_resp_valid'] and d['ptw_walk_resp_fault']: c['cancel_with_fault_resp'] += 1
            if d['ptw_walk_resp_valid'] and d['ptw_walk_resp_leaf_ppn'] is not None and not d['ptw_walk_resp_fault']: c['cancel_with_ok_resp'] += 1
        for q in ('ldq', 'stq'):
            for i in range(4):
                if d[q + '_req_valid'][i]:
                    c['req_' + q] += 1
                    c['req_satp_on' if satp_on else 'req_bare'] += 1
                    if d[q + '_resp_valid'][i]:
                        c['resp_%s_res%d' % (q, d[q + '_resp_result'][i])] += 1
        if d['ptw_walk_req_valid']: c['walk_req'] += 1
        if d['ptw_walk_resp_consumed']: c['resp_consumed'] += 1
        if d['ptw_walk_resp_valid']: c['resp_valid_seen'] += 1
        if d['ptw_walk_flush']: c['walk_flush'] += 1
        if satp_on: c['satp_on_cycles'] += 1
        c['priv%d' % d['csr_status_privilege']] += 1
        if d['csr_status_mstatus_mprv']: c['mprv'] += 1
        if d['csr_status_mstatus_sum']: c['sum'] += 1
        if d['csr_status_mstatus_mxr']: c['mxr'] += 1
        if dump and (d['ptw_walk_req_valid'] or d['ptw_walk_resp_consumed'] or d['ptw_walk_flush']) and dump > 0:
            print(cyc, {k: v for k, v in d.items() if v not in (0, [0, 0, 0, 0])})
            dump -= 1
    for k in sorted(c): print('%-28s %d' % (k, c[k]))
