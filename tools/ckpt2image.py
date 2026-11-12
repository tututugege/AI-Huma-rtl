#!/usr/bin/env python3
"""Function-model checkpoint -> flat memory image for the SoC testbench (tb/soc): the first <bytes> of DDR (address 0x80000000).
The testbench loads it like a program; the CPU state comes from the restore program of function-model/tools/ckpt2stub.py
(SOC_TB_STUB), so the RTL core starts from reset exactly like the function model does.
usage: ckpt2image.py <checkpoint.gz> <out.bin> [bytes (default 0x10000000)]"""
import gzip, struct, sys

ck, out = sys.argv[1], sys.argv[2]
want = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x10000000
f = gzip.open(ck, 'rb')
magic, ver, priv, ram_size, io_count = struct.unpack('<IHHII', f.read(16))
if ver >= 3: f.read(4)          # sdram_size
# CPU_state size by format version (see function-model/tools/ckpt2stub.py): 2/3 rv32 236, 4 rv64 464, 5 rv64 with F/D 720 + fcsr 4, 6 rv32 with F/D 496 + fcsr 4
f.read({4: 464, 5: 720 + 4, 6: 496 + 4}.get(ver, 236))
f.read(8)                        # interval_inst_count
with open(out, 'wb') as o:
    left = want
    while left:
        b = f.read(min(left, 1 << 24))
        if not b: sys.exit('short checkpoint')
        o.write(b); left -= len(b)
print(f'{out}: {want:#x} bytes of DDR from {ck} (ram_size={ram_size:#x})')
