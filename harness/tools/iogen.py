#!/usr/bin/env python3
"""iogen: turn a module IO spec (spec/<mod>.io) into the files the harness needs.

Outputs (into <outdir>):
  <mod>_tbwrap.sv   flat-vector wrapper around the real module (in_bits / out_bits)
  <mod>_fields.h    field table (name, width, dims, byte offset, 'when' link) + spec hash

Spec grammar (one item per line, '#' starts a comment):
  module <name>
  in  <name> <width> [dim]...            # module input
  out <name> <width> [dim]... [when <v>] # module output; compared only where <v> (1-bit input or output) is true
  ... @ <c++ expr>                       # optional (all fields or none): how the reference simulator
                                         # reads this signal, see "Recorder" below

Rules
  * The wrapped module must have ports  clk, rst_n  plus exactly the spec signals, declared as
    `logic [W-1:0] name [D0][D1]...` (W == 1 -> `logic name`).
  * Every array element occupies ceil(W/8) whole bytes in the trace record (little endian,
    row-major element order), inputs first as one record part, outputs second.
  * `when <v>`: <v> is a 1-bit input or output of the same dims (element-wise) or a scalar.

Recorder (only if every field has an `@` expression): iogen also writes <mod>_rec.cpp, a plugin for the
instrumented reference simulator (refsim). Inside <expr> the following names exist:
    cpu  (SimCpu&)   bt (BackTop&, == cpu.back)   i0 i1 ... (element indices, one per dimension, in order)
`@ <expr>`   value is converted to uint64_t          (width <= 64)
`@w <expr>`  value is a pointer to little-endian uint32_t words (any width)
Private members are readable (the plugin is compiled with `private` public).
"""
import re
import sys
import os

LINE = re.compile(r'^(in|out)\s+(\w+)\s+(\d+)((?:\s*\[\d+\])*)(?:\s+when\s+(\w+))?$')
ATLINE = re.compile(r'^(.*?)\s@(w?)\s+(.*)$')


class Field:
    def __init__(self, direction, name, width, dims, when, expr=None, wide=False):
        self.expr = expr
        self.wide = wide
        self.dir = direction
        self.name = name
        self.width = width
        self.dims = dims
        self.when = when
        self.nelem = 1
        for d in dims:
            self.nelem *= d
        self.ebytes = (width + 7) // 8
        self.byte_off = 0
        self.index = -1

    def elem_indices(self):
        """All element index tuples in row-major order."""
        if not self.dims:
            return [()]
        out = [()]
        for d in self.dims:
            out = [t + (i,) for t in out for i in range(d)]
        return out


def parse(path):
    mod = None
    fields = []
    seen = set()
    norm = []
    with open(path) as f:
        for ln, raw in enumerate(f, 1):
            line = raw.split('#', 1)[0].strip() if '@' not in raw else raw.rstrip('\n').strip()
            if '@' in line:
                # '#' may legitimately occur inside the C++ expression; only strip a comment before the '@'
                head, _, tail = line.partition('@')
                line = head.split('#', 1)[0].rstrip() + ' @' + tail
            if not line:
                continue
            expr = None
            wide = False
            am = ATLINE.match(line)
            if am:
                line, wide, expr = am.group(1).strip(), bool(am.group(2)), am.group(3).strip()
                if not expr:
                    sys.exit(f'{path}:{ln}: empty @ expression')
            if line.startswith('module '):
                mod = line.split()[1]
                norm.append(line)
                continue
            m = LINE.match(line)
            if not m:
                sys.exit(f'{path}:{ln}: cannot parse: {raw.rstrip()}')
            d, name, w, dims, when = m.groups()
            if name in seen:
                sys.exit(f'{path}:{ln}: duplicate signal {name}')
            if name in ('clk', 'rst_n', 'in_bits', 'out_bits'):
                sys.exit(f'{path}:{ln}: reserved signal name {name}')
            seen.add(name)
            dl = [int(x) for x in re.findall(r'\[(\d+)\]', dims)]
            if int(w) < 1 or any(x < 1 for x in dl):
                sys.exit(f'{path}:{ln}: width and dims must be >= 1')
            if when and d == 'in':
                sys.exit(f'{path}:{ln}: "when" is only valid on outputs')
            fields.append(Field(d, name, int(w), dl, when, expr, wide))
            # the hash covers the trace LAYOUT only: direction, name, width, dims. Neither the recorder expression nor
            # `when` (a compare rule) is part of it, so relaxing/tightening a compare rule never invalidates traces.
            norm.append(f'{d} {name} {w} {"".join(f"[{x}]" for x in dl)}')
    if mod is None:
        sys.exit(f'{path}: missing "module <name>"')
    byname = {f.name: f for f in fields}
    for f in fields:
        if f.when:
            v = byname.get(f.when)
            if v is None or v.width != 1:
                sys.exit(f'{path}: {f.name}: "when {f.when}" must name a 1-bit field (input or output)')
            if v.nelem != 1 and v.dims != f.dims:
                sys.exit(f'{path}: {f.name}: "when {f.when}" must be scalar or have the same dims')
    off = {'in': 0, 'out': 0}
    for i, f in enumerate(fields):
        f.index = i
        f.byte_off = off[f.dir]
        off[f.dir] += f.ebytes * f.nelem
    h = 0xcbf29ce484222325
    for b in '\n'.join(norm).encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return mod, fields, off['in'], off['out'], h


def sv_decl(f):
    w = '' if f.width == 1 else f'[{f.width - 1}:0] '
    dims = ''.join(f'[{d}]' for d in f.dims)
    return f'logic {w}{f.name}{(" " + dims) if dims else ""};'


def elem_ref(f, idx):
    return f.name + ''.join(f'[{i}]' for i in idx)


def gen_wrapper(mod, fields, in_bytes, out_bytes):
    L = []
    L.append('// Generated by harness/tools/iogen.py -- do not edit.')
    L.append('`default_nettype none')
    L.append('/* verilator lint_off UNUSEDSIGNAL */')
    L.append(f'module {mod}_tbwrap (')
    L.append('  input  wire clk,')
    L.append('  input  wire rst_n,')
    L.append(f'  input  wire [{in_bytes * 8 - 1}:0] in_bits,')
    L.append(f'  output wire  [{out_bytes * 8 - 1}:0] out_bits')
    L.append(');')
    for f in fields:
        L.append('  ' + sv_decl(f))
    for f in fields:
        if f.dir != 'in':
            continue
        for k, idx in enumerate(f.elem_indices()):
            lo = (f.byte_off + k * f.ebytes) * 8
            L.append(f'  assign {elem_ref(f, idx)} = in_bits[{lo} +: {f.width}];')
    L.append(f'  {mod} dut (')
    conns = ['    .clk(clk)', '    .rst_n(rst_n)'] + [f'    .{f.name}({f.name})' for f in fields]
    L.append(',\n'.join(conns))
    L.append('  );')
    # one continuous assign per element; the unused high bits of each byte-aligned element are tied to 0
    for f in fields:
        if f.dir != 'out':
            continue
        pad = f.ebytes * 8 - f.width
        for k, idx in enumerate(f.elem_indices()):
            lo = (f.byte_off + k * f.ebytes) * 8
            L.append(f'  assign out_bits[{lo} +: {f.width}] = {elem_ref(f, idx)};')
            if pad:
                L.append(f"  assign out_bits[{lo + f.width} +: {pad}] = {pad}'d0;")
    L.append('endmodule')
    L.append('`default_nettype wire')
    return '\n'.join(L) + '\n'


def gen_fields_h(mod, fields, in_bytes, out_bytes, h):
    byname = {f.name: f for f in fields}
    L = []
    L.append('// Generated by harness/tools/iogen.py -- do not edit.')
    L.append('#pragma once')
    L.append('#include "trace_format.h"')
    L.append(f'namespace ttg_io {{')
    L.append(f'constexpr const char *kModule = "{mod}";')
    L.append(f'constexpr unsigned kInBytes = {in_bytes};')
    L.append(f'constexpr unsigned kOutBytes = {out_bytes};')
    L.append(f'constexpr unsigned long long kSpecHash = 0x{h:016x}ULL;')
    L.append(f'constexpr unsigned kNumFields = {len(fields)};')
    L.append('enum FieldId : int {')
    for f in fields:
        L.append(f'  F_{f.name} = {f.index},')
    L.append('};')
    L.append('constexpr ttg::FieldInfo kFields[] = {')
    for f in fields:
        dims = (f.dims + [0, 0, 0, 0])[:4]
        when = byname[f.when].index if f.when else -1
        L.append(f'  {{"{f.name}", {1 if f.dir == "out" else 0}, {f.width}, {len(f.dims)}, '
                 f'{{{", ".join(map(str, dims))}}}, {f.nelem}, {f.ebytes}, {f.byte_off}, {when}}},')
    L.append('};')
    L.append('}  // namespace ttg_io')
    return '\n'.join(L) + '\n'


def gen_rec(mod, fields, in_bytes, out_bytes):
    """Plugin source for the instrumented reference simulator."""
    L = []
    L.append('// Generated by harness/tools/iogen.py -- do not edit.')
    L.append('#include <algorithm>\n#include <array>\n#include <bitset>\n#include <cstdint>\n#include <cstdio>')
    L.append('#include <cstdlib>\n#include <cstring>\n#include <deque>\n#include <functional>\n#include <list>')
    L.append('#include <map>\n#include <memory>\n#include <queue>\n#include <set>\n#include <string>')
    L.append('#include <unordered_map>\n#include <unordered_set>\n#include <vector>')
    L.append('#define private public')
    L.append('#define protected public')
    L.append('#include "SimCpu.h"')
    L.append('#undef private')
    L.append('#undef protected')
    L.append(f'#include "{mod}_fields.h"')
    L.append('using namespace ttg_io;')
    L.append('namespace {')
    L.append('struct Recorder {')
    L.append('  ttg::TraceWriter<decltype(kFields)> tw;')
    L.append('  uint64_t n, count = 0;')
    L.append('  bool started = false;')
    L.append('  Recorder()')
    L.append('      : tw(std::getenv("TTG_REC_OUT") ? std::getenv("TTG_REC_OUT") : "trace.trc", kModule, kInBytes,')
    L.append('           kOutBytes, kSpecHash, kFields),')
    L.append('        n(std::getenv("TTG_REC_N") ? std::strtoull(std::getenv("TTG_REC_N"), nullptr, 0) : ~0ull) {}')
    L.append('  ~Recorder() { tw.flush(); }')
    L.append('};')
    L.append('}  // namespace')
    L.append('extern "C" void ttg_rec_cycle(SimCpu *cpu_p, uint64_t cycle) {')
    L.append('  static Recorder r;')
    L.append('  if (r.count >= r.n) return;')
    L.append('  if (!r.started) {  // reset records: inputs 0, outputs not compared')
    L.append('    r.started = true;')
    L.append('    for (int k = 0; k < 3; ++k) r.tw.commit(0, ttg::kFlagReset);')
    L.append('  }')
    L.append('  SimCpu &cpu = *cpu_p;')
    L.append('  BackTop &bt = cpu.back;')
    L.append('  (void)cpu; (void)bt;')
    for f in fields:
        ind = '  '
        for d, n in enumerate(f.dims):
            L.append(f'{ind}for (int i{d} = 0; i{d} < {n}; ++i{d}) {{')
            ind += '  '
        flat = '0'
        for d, n in enumerate(f.dims):
            flat = f'({flat}) * {n} + i{d}'
        if f.wide:
            nw = (f.width + 31) // 32
            L.append(f'{ind}r.tw.set_words(F_{f.name}, {flat}, (const uint32_t *)({f.expr}), {nw});')
        else:
            L.append(f'{ind}r.tw.set(F_{f.name}, {flat}, (uint64_t)({f.expr}));')
        for _ in f.dims:
            ind = ind[:-2]
            L.append(f'{ind}}}')
    L.append('  r.tw.commit(cycle);')
    L.append('  if (++r.count >= r.n) {  // window full: the rest of the run is not needed, stop the simulator now')
    L.append('    r.tw.flush();')
    L.append('    std::_Exit(0);')
    L.append('  }')
    L.append('  if ((r.count & 1023) == 0) r.tw.flush();')
    L.append('}')
    return '\n'.join(L) + '\n'


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: iogen.py <spec.io> <outdir>')
    spec, outdir = sys.argv[1:]
    mod, fields, ib, ob, h = parse(spec)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, f'{mod}_tbwrap.sv'), 'w') as f:
        f.write(gen_wrapper(mod, fields, ib, ob))
    with open(os.path.join(outdir, f'{mod}_fields.h'), 'w') as f:
        f.write(gen_fields_h(mod, fields, ib, ob, h))
    have = [f.expr is not None for f in fields]
    if any(have) and not all(have):
        miss = [f.name for f in fields if f.expr is None]
        sys.exit(f'{spec}: every field needs an @ expression for the recorder, missing: {miss}')
    if all(have):
        with open(os.path.join(outdir, f'{mod}_rec.cpp'), 'w') as f:
            f.write(gen_rec(mod, fields, ib, ob))
    print(f'{mod}: {len(fields)} fields, in={ib}B out={ob}B hash={h:016x}')


if __name__ == '__main__':
    main()
