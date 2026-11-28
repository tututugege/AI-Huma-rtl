#!/usr/bin/env python3
"""Topologically sort SystemVerilog files by package::symbol dependencies.
Python 3.6+ compatible for eda cluster nodes.
Usage: list_sv_files.py <rtl_root>
         every .sv file: packages first (dependency order), then the rest
       list_sv_files.py --pkgs <rtl_root> <file.sv>...
         only the packages the given files need (packages they reference by pkg::sym / import pkg::*, and the
         packages those reference, transitively; comments ignored), in dependency order, paths relative to
         <rtl_root>; used by lint.sh per directory
"""
import glob
import os
import re
import sys


def strip_comments(txt):
    txt = re.sub(r"/\*.*?\*/", " ", txt, flags=re.S)
    return re.sub(r"//[^\n]*", " ", txt)


def refs(txt, nocomments):
    return set(re.findall(r"\b(\w+)::", strip_comments(txt) if nocomments else txt))


def scan_pkgs(search_root, nocomments):
    pkgs = {}
    for f in sorted(glob.glob(os.path.join(search_root, "**", "*_pkg.sv"), recursive=True)):
        with open(f, "r", encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()
        m = re.search(r"\bpackage\s+(\w+)\s*;", txt)
        if not m:
            continue
        name = m.group(1)
        pkgs[name] = (f, refs(txt, nocomments) - {name})
    return pkgs


def topo(pkgs, roots):
    order = []
    seen = set()

    def visit(n):
        if n in seen or n not in pkgs:
            return
        seen.add(n)
        for d in sorted(pkgs[n][1]):
            visit(d)
        order.append(pkgs[n][0])

    for n in sorted(roots):
        visit(n)
    return order


def main():
    args = sys.argv[1:]
    only = False
    if args and args[0] == "--pkgs":
        only = True
        args = args[1:]
    if not args:
        sys.stderr.write(__doc__)
        sys.exit(1)
    root = os.path.abspath(args[0])
    search_root = os.path.join(root, "rtl")
    if not os.path.isdir(search_root):
        search_root = root
    pkgs = scan_pkgs(search_root, only)

    if only:
        need = set()
        for f in args[1:]:
            with open(f, "r", encoding="utf-8", errors="ignore") as fh:
                txt = fh.read()
            need |= refs(txt, True)
            m = re.search(r"\bpackage\s+(\w+)\s*;", txt)   # a package file given directly is needed itself
            if m:
                need.add(m.group(1))
        for p in topo(pkgs, need):
            print(os.path.relpath(p, root))
        return

    order = topo(pkgs, pkgs.keys())
    for p in order:
        print(p)

    pkg_set = set(order)
    for f in sorted(glob.glob(os.path.join(search_root, "**", "*.sv"), recursive=True)):
        if f not in pkg_set:
            print(f)


if __name__ == "__main__":
    main()
