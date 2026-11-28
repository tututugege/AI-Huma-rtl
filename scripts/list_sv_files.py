#!/usr/bin/env python3
"""Topologically sort SystemVerilog files by package::symbol dependencies.
Python 3.6+ compatible for eda cluster nodes.
Usage: list_sv_files.py <rtl_root>
"""
import glob
import os
import re
import sys


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: list_sv_files.py <rtl_root>\n")
        sys.exit(1)
    root = os.path.abspath(sys.argv[1])
    search_root = os.path.join(root, "rtl")
    if not os.path.isdir(search_root):
        search_root = root

    pkgs = {}
    for f in sorted(glob.glob(os.path.join(search_root, "**", "*_pkg.sv"), recursive=True)):
        with open(f, "r", encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()
        m = re.search(r"\bpackage\s+(\w+)\s*;", txt)
        if not m:
            continue
        name = m.group(1)
        deps = set(re.findall(r"\b(\w+)::", txt)) - {name}
        pkgs[name] = (f, deps)

    order = []
    seen = set()

    def visit(n):
        if n in seen or n not in pkgs:
            return
        seen.add(n)
        for d in sorted(pkgs[n][1]):
            visit(d)
        order.append(pkgs[n][0])

    for n in sorted(pkgs):
        visit(n)

    for p in order:
        print(p)

    pkg_set = set(order)
    for f in sorted(glob.glob(os.path.join(search_root, "**", "*.sv"), recursive=True)):
        if f not in pkg_set:
            print(f)


if __name__ == "__main__":
    main()
