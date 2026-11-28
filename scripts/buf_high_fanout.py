#!/usr/bin/env python3
"""Insert balanced TSMC28 BUFFD8 buffer trees on post-ABC high-fanout 1-bit nets.

Targets nets (such as shared SRAM BWEB/CEB/WEB/addr bits or unbuffered FF Qs)
that exceed MAX_FANOUT across standard cells, SRAM macros, or assign RHS.
Skips clock and reset nets. Python 3.6+ compatible.

Usage: buf_high_fanout.py <in.v> <out.v> [max_fanout=16]
"""
import re
import sys

BUF_CELL = "BUFFD8BWP12T40P140LVT"
SKIP_SIGNALS = {"clk", "rst_n", "rst", "reset", "reset_n"}
SKIP_PORTS = {"CLK", "CP", "CPN"}
OUTPUT_PORTS = {"Q", "QN", "Z", "ZN", "S", "CO", "Y", "O"}

# Match Verilog constants first (so group 1 is None), then scalar/bit-select identifiers.
TOK_RE = re.compile(
    r"\d+'[bdhoBDHO][0-9a-fA-FxXzZ_]+|"
    r"(\\\S+(?:\s*\[\d+\])?|[A-Za-z_][A-Za-z0-9_$]*(?:\[\d+\])?)"
)


def insert_buffers(txt, max_fanout=16):
    lines = txt.splitlines()
    refs = {}
    inst_header_re = re.compile(r"^\s*(\S+)\s+(\S+)\s*\(\s*$")
    port_conn_re = re.compile(r"^(\s*\.([A-Za-z0-9_]+)\()(.*)(\),?\s*)$")
    assign_re = re.compile(r"^(\s*assign\s+[^=]+=\s*)(.+)(;\s*)$")

    # Track vector widths of declared wires/inputs/outputs so we never split a multi-bit bus expression as 1-bit
    vec_names = set()
    decl_vec_re = re.compile(r"^\s*(?:wire|input|output|inout)\s+\[\d+:\d+\]\s+([^;]+);")
    for ln in lines:
        m = decl_vec_re.match(ln)
        if m:
            for nm in m.group(1).split(","):
                nm = nm.strip()
                if nm:
                    vec_names.add(nm)

    in_inst = False
    endmodule_idx = -1

    for idx, ln in enumerate(lines):
        if ln.strip() == "endmodule":
            endmodule_idx = idx
            break

        if not in_inst:
            m = inst_header_re.match(ln)
            if m and m.group(1) not in ("module", "endmodule"):
                in_inst = True
                continue
            ma = assign_re.match(ln)
            if ma:
                rhs = ma.group(2)
                rhs_off = len(ma.group(1))
                for sm in TOK_RE.finditer(rhs):
                    raw = sm.group(1)
                    if not raw:
                        continue
                    key = raw.strip()
                    base = key.split("[")[0]
                    if "[" not in key and base in vec_names:
                        continue
                    if key in SKIP_SIGNALS:
                        continue
                    refs.setdefault(key, []).append((idx, rhs_off + sm.start(1), rhs_off + sm.end(1)))
            continue

        # Inside instance
        if ln.strip() == ");":
            in_inst = False
            continue
        mp = port_conn_re.match(ln)
        if not mp:
            continue
        port_name = mp.group(2)
        expr = mp.group(3)
        expr_off = len(mp.group(1))
        if port_name in SKIP_PORTS or port_name in OUTPUT_PORTS:
            continue
        for sm in TOK_RE.finditer(expr):
            raw = sm.group(1)
            if not raw:
                continue
            key = raw.strip()
            base = key.split("[")[0]
            if "[" not in key and base in vec_names:
                continue
            if key in SKIP_SIGNALS:
                continue
            refs.setdefault(key, []).append((idx, expr_off + sm.start(1), expr_off + sm.end(1)))

    if endmodule_idx == -1:
        raise RuntimeError("Missing endmodule in netlist")

    # Build balanced N-ary buffer trees for signals exceeding max_fanout
    new_decls = []
    new_insts = []
    replacements = {}  # line_idx -> list of (start, end, new_wire)
    buf_id = 0
    buffered_nets = 0

    for sig, occs in refs.items():
        if len(occs) <= max_fanout:
            continue
        buffered_nets += 1
        n_leaves = (len(occs) + max_fanout - 1) // max_fanout
        sizes = [n_leaves]
        while sizes[-1] > 1:
            sizes.append((sizes[-1] + max_fanout - 1) // max_fanout)
        sizes.reverse()

        cur = [sig]
        for count in sizes[1:]:
            nxt = []
            for i in range(count):
                parent = cur[(i * len(cur)) // count]
                wname = "_hbuf_w_%d_" % buf_id
                iname = "_hbuf_i_%d_" % buf_id
                buf_id += 1
                new_decls.append("  wire %s;" % wname)
                new_insts.append("  %s %s (\n    .I(%s ),\n    .Z(%s)\n  );" % (BUF_CELL, iname, parent, wname))
                nxt.append(wname)
            cur = nxt

        for k, (lidx, s, e) in enumerate(occs):
            lw = cur[(k * n_leaves) // len(occs)]
            replacements.setdefault(lidx, []).append((s, e, lw))

    if buffered_nets == 0:
        return txt, 0, 0

    # Apply per-line replacements right-to-left
    out_lines = list(lines)
    for lidx, reps in replacements.items():
        ln = out_lines[lidx]
        for s, e, lw in sorted(reps, key=lambda x: x[0], reverse=True):
            trailing_space = " " if ln[s:e].endswith(" ") else ""
            ln = ln[:s] + lw + trailing_space + ln[e:]
        out_lines[lidx] = ln

    # Insert new wire declarations before first instance/assign or before endmodule,
    # and insert buffer instances right before endmodule.
    first_wire_insert = endmodule_idx
    for idx, ln in enumerate(out_lines):
        if ln.strip().startswith("wire "):
            first_wire_insert = idx
            break

    final_lines = (
        out_lines[:first_wire_insert]
        + new_decls
        + out_lines[first_wire_insert:endmodule_idx]
        + new_insts
        + out_lines[endmodule_idx:]
    )
    return "\n".join(final_lines) + "\n", buffered_nets, buf_id


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("Usage: buf_high_fanout.py <in.v> <out.v> [max_fanout=16]\n")
        sys.exit(1)
    in_v, out_v = sys.argv[1], sys.argv[2]
    max_fo = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    with open(in_v, "r") as fh:
        txt = fh.read()
    out_txt, nets, bufs = insert_buffers(txt, max_fo)
    with open(out_v, "w") as fh:
        fh.write(out_txt)
    print("buf_high_fanout: buffered_nets=%d inserted_buffers=%d max_fo=%d" % (nets, bufs, max_fo))


if __name__ == "__main__":
    main()
