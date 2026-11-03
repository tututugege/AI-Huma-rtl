#!/usr/bin/env python3
"""svlint: mechanical checks for docs/01-rtl-coding-standard.md that Verilator -Wall does not cover.

usage: svlint.py <file.sv>...        exit code 1 if any rule is violated

Rules (ids match the standard):
  S1  file starts (after comments) with `default_nettype none and ends with `default_nettype wire
  S2  one module per file and the file is named <module>.sv
  S3  no tabs, no trailing whitespace, lines <= 120 columns
  S4  no plain `always`; use always_ff / always_comb
  S5  no initial blocks, #delays, $random, force/release, $display/$finish/$stop in rtl
  S6  always_ff: every non-blocking assignment target ends in _q, only `<=` is used
  S7  always_comb: only blocking `=` is used and no target ends in _q
  S8  no `wire x = ...` / `assign` to a *_q name; _d names are never assigned in always_ff
  S9  parameters / localparams are UPPER_SNAKE_CASE
"""
import re
import sys

SRC_KEYWORDS_BEGIN = re.compile(r'\b(begin|case|casez|casex|fork)\b')
SRC_KEYWORDS_END = re.compile(r'\b(end|endcase|join)\b')


def strip_comments(text):
    """Remove // and /* */ comments but keep line structure."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            out.append('"' + ' ' * (j - i - 1) + '"')
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def blocks(code, kw):
    """Yield (start_line, body) for each `kw` block: always_ff/always_comb ... statement or begin..end."""
    for m in re.finditer(r'\b' + kw + r'\b', code):
        i = m.end()
        # skip sensitivity list
        while i < len(code) and code[i].isspace():
            i += 1
        if code.startswith('@', i):
            i = code.index('(', i)
            depth = 0
            while True:
                if code[i] == '(':
                    depth += 1
                elif code[i] == ')':
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
        start = i
        # body: the statement that follows
        depth = 0
        j = i
        tokens = re.compile(r'\b(begin|end|case|casez|casex|endcase|if|else|;)\b|;')
        seen_begin = False
        while j < len(code):
            t = tokens.search(code, j)
            if not t:
                j = len(code)
                break
            w = t.group(0)
            j = t.end()
            if w in ('begin', 'case', 'casez', 'casex'):
                depth += 1
                seen_begin = True
            elif w in ('end', 'endcase'):
                depth -= 1
                if depth == 0:
                    break
            elif w == ';' and depth == 0 and not seen_begin:
                break
        yield code.count('\n', 0, m.start()) + 1, code[start:j]


# assignment statements inside a block body:  <lhs> (<=|=) ...
ASSIGN = re.compile(r'(?m)(?:^|[;\s])((?:[A-Za-z_]\w*)(?:\s*\[[^\]]*\]|\s*\.\s*\w+)*)\s*(<=|=)(?!=)')
NON_TARGET = {'if', 'else', 'for', 'while', 'case', 'begin', 'end', 'int', 'logic', 'integer', 'bit', 'return'}


def targets(body):
    for m in ASSIGN.finditer(body):
        lhs = m.group(1)
        base = re.match(r'[A-Za-z_]\w*', lhs).group(0)
        if base in NON_TARGET:
            continue
        # skip `for (int i = 0; ...` loop headers and declarations with initialisers
        pre = body[max(0, m.start() - 12):m.start() + 1]
        if re.search(r'\b(int|integer|logic|bit)\s*(\[[^\]]*\])?\s*$', body[:m.start(1) + len(base)][-30:]):
            continue
        if re.search(r'for\s*\(\s*(int\s+)?$', body[:m.start(1)][-20:]):
            continue
        yield base, m.group(2), body.count('\n', 0, m.start(1))


def check(path):
    errs = []
    raw = open(path).read()
    name = path.rsplit('/', 1)[-1]
    code = strip_comments(raw)

    def err(rule, line, msg):
        errs.append(f'{path}:{line}: {rule} {msg}')

    # S1
    stripped = code.strip()
    if not stripped.startswith('`default_nettype none'):
        err('S1', 1, 'file must start with `default_nettype none')
    if not stripped.endswith('`default_nettype wire'):
        err('S1', code.count('\n') + 1, 'file must end with `default_nettype wire')
    # S2
    mods = re.findall(r'(?m)^\s*(?:module|package)\s+(\w+)', code)
    if len(mods) != 1:
        err('S2', 1, f'expected exactly one module/package, found {len(mods)}')
    elif name != mods[0] + '.sv' and not name.endswith('_tb.sv'):
        err('S2', 1, f'file name must be {mods[0]}.sv')
    # S3
    for i, line in enumerate(raw.split('\n'), 1):
        if '\t' in line:
            err('S3', i, 'tab character')
        if line != line.rstrip():
            err('S3', i, 'trailing whitespace')
        if len(line) > 120:
            err('S3', i, f'line too long ({len(line)} > 120)')
    # S4 / S5
    for m in re.finditer(r'\balways\b(?!_)', code):
        err('S4', code.count('\n', 0, m.start()) + 1, 'plain `always` is not allowed')
    for pat, what in ((r'\binitial\b', 'initial block'), (r'#\s*\d', '#delay'), (r'\$random|\$urandom', 'random'),
                      (r'\b(force|release)\b', 'force/release'), (r'\$(display|write|finish|stop|fatal)\b', 'system task')):
        for m in re.finditer(pat, code):
            err('S5', code.count('\n', 0, m.start()) + 1, f'{what} is not allowed in rtl')
    # S6
    for line, body in blocks(code, 'always_ff'):
        for base, op, off in targets(body):
            if op != '<=':
                err('S6', line + off, f'always_ff must use <=, found = on {base}')
            elif not base.endswith('_q'):
                err('S6', line + off, f'register {base} must be named *_q')
    # S7
    for line, body in blocks(code, 'always_comb'):
        for base, op, off in targets(body):
            if op != '=':
                err('S7', line + off, f'always_comb must use =, found <= on {base}')
            elif base.endswith('_q'):
                err('S7', line + off, f'{base} is a register (*_q) and cannot be driven in always_comb')
    # S8
    for m in re.finditer(r'\bassign\s+(\w+)', code):
        if m.group(1).endswith('_q'):
            err('S8', code.count('\n', 0, m.start()) + 1, f'{m.group(1)}: *_q names are registers; do not assign them')
    for line, body in blocks(code, 'always_ff'):
        for base, op, off in targets(body):
            if base.endswith('_d'):
                err('S8', line + off, f'{base}: *_d names are next-state wires; drive them in always_comb')
    # S9
    for m in re.finditer(r'\b(?:localparam|parameter)\b(?:\s+(?:int|integer|logic|bit)\b)?(?:\s*\[[^\]]*\])?\s+(\w+)\s*=', code):
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', m.group(1)):
            err('S9', code.count('\n', 0, m.start()) + 1, f'parameter {m.group(1)} must be UPPER_SNAKE_CASE')
    return errs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    errs = []
    for p in sys.argv[1:]:
        errs += check(p)
    for e in errs:
        print(e)
    sys.exit(1 if errs else 0)


if __name__ == '__main__':
    main()
