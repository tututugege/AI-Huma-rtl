#!/usr/bin/env python3
"""rehash: rewrite the spec hash stored in trace headers after the hash definition (or a compare-rule `when`) changed.
Only valid while the field LAYOUT (direction, name, width, dims, order) is unchanged; the in/out byte counts are checked.
usage: rehash.py <spec.io> <trace.trc>...
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'harness', 'tools'))
import iogen  # noqa: E402

spec, traces = sys.argv[1], sys.argv[2:]
mod, fields, ib, ob, h = iogen.parse(spec)
bad = 0
for t in traces:
    with open(t, 'r+b') as f:
        hdr = f.read(24)
        if hdr[:8] != b'TTGTRC01':
            print(f'{t}: bad magic'); bad += 1; continue
        tib, tob = struct.unpack('<II', hdr[8:16])
        if (tib, tob) != (ib, ob):
            print(f'{t}: layout size differs (trace in={tib} out={tob}, spec in={ib} out={ob}) -> re-record'); bad += 1; continue
        f.seek(16)
        f.write(struct.pack('<Q', h))
print(f'rehashed {len(traces) - bad} trace(s) to {h:016x}' + (f', {bad} need re-recording' if bad else ''))
sys.exit(1 if bad else 0)
