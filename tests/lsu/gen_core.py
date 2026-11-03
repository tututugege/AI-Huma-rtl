#!/usr/bin/env python3
"""Generates rtl/backend/lsu/{lsu_core,lsu_state,lsu}.sv: the wiring of the LSU stage chain.

Why generated: RealLsu::comb_* mutate one `nxt` state in sequence (about 20 stages, ~70 state arrays).  The RTL gives every stage
module only the arrays it touches and chains them as SSA versions (`x_v1`, `x_v2`, ...; `x_q` is the register, `x_d` the last version).
Port naming convention of the stage modules:  `x_i` / `x_o` = input from / output to the chain version of state variable `x`;
a bare input `x` reads the current version.  Everything else is mapped explicitly in STAGES below.
Run:  python3 tests/lsu/gen_core.py   (writes the three files; they are committed).
"""
import re, sys, os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
RTL = os.path.join(ROOT, 'rtl/backend/lsu')

# ---- state variables: name -> (declaration prefix, dim suffix, reset literal) ----
def arr(t, n):  return (t, f' [{n}]', None)
VARS = {}
for n, t in [('ld_vaddr', 'logic [31:0]'), ('ld_paddr', 'logic [31:0]'), ('ld_func3', 'logic [2:0]'), ('ld_result', 'logic [31:0]'),
             ('ld_dest', 'logic [6:0]'), ('ld_rob_idx', 'logic [6:0]'), ('ld_br_mask', 'logic [BRW-1:0]'),
             ('ld_snap_idx', 'logic [SQW-1:0]'), ('ld_replay', 'logic [1:0]')]:
    VARS[n] = (t, ' [LQ]', "'{default: '0}")
VARS['ld_st'] = ('ld_state_t', ' [LQ]', "'{default: LD_EMPTY}")
for n in ['ld_rob_flag', 'ld_mmio', 'ld_pf', 'ld_lrsc', 'ld_snap_flag']:
    VARS[n] = ('logic [LQ-1:0]', '', "'0")
for n, t in [('st_data', 'logic [31:0]'), ('st_func3', 'logic [2:0]'), ('st_vaddr', 'logic [31:0]'), ('st_paddr', 'logic [31:0]'),
             ('st_dest', 'logic [6:0]'), ('st_replay', 'logic [1:0]'), ('st_wait', 'logic [RWW-1:0]'),
             ('st_br_mask', 'logic [BRW-1:0]'), ('st_rob_idx', 'logic [6:0]')]:
    VARS[n] = (t, ' [SQ]', "'{default: '0}")
VARS['st_st'] = ('st_state_t', ' [SQ]', "'{default: ST_EMPTY}")
for n in ['st_data_valid', 'st_paddr_valid', 'st_pf', 'st_suppress', 'st_mmio', 'st_is_lrsc', 'st_sc_pass', 'st_rob_flag']:
    VARS[n] = ('logic [SQ-1:0]', '', "'0")
VARS['stq_head'] = ('logic [RIW-1:0]', '', "'0")
VARS['stq_head_flag'] = ('logic', '', "1'b0")
VARS['stq_count'] = ('logic [RCW-1:0]', '', "'0")
VARS['stq_ccount'] = ('logic [RCW-1:0]', '', "'0")
for n in ['wmld', 'wmst', 'mdone', 'finish', 'stlf', 'wdc']:
    VARS[n] = ('lsu_ring_t', '', "'0")
VARS['wd_gen'] = ('logic [GENW-1:0]', ' [RN]', "'{default: '0}")
VARS['wd_wait'] = ('logic [RWW-1:0]', ' [RN]', "'{default: '0}")
VARS['req_gen'] = ('logic [GENW-1:0]', '', "'0")
VARS['unc_valid'] = ('logic', '', "1'b0")
VARS['unc_is_load'] = ('logic', '', "1'b0")
VARS['unc_addr'] = ('logic [31:0]', '', "'0")
VARS['unc_wdata'] = ('logic [31:0]', '', "'0")
VARS['unc_func3'] = ('logic [2:0]', '', "'0")
VARS['unc_idx'] = ('logic [RIW-1:0]', '', "'0")
VARS['lrsc_valid'] = ('logic', '', "1'b0")
VARS['lrsc_addr'] = ('logic [31:0]', '', "'0")
VARS['lrsc_br'] = ('logic [BRW-1:0]', '', "'0")

PORT = re.compile(r'^\s*(input|output)\s+(.*?)\s*\b(\w+)\s*((?:\[[^\]]+\]\s*)*),?\s*(?://.*)?$')

def parse_ports(mod):
    txt = open(os.path.join(RTL, mod + '.sv')).read()
    head = txt[txt.index('(', txt.index('module ' + mod)):]
    head = head[:head.index(');')]
    head = re.sub(r'/\*.*?\*/', '', head, flags=re.S)
    ports = []
    for line in head.split('\n'):
        m = PORT.match(line)
        if m:
            d, t, n, dims = m.groups()
            ports.append((d, re.sub(r'\bNP\b', 'NLD', t).strip(), n, re.sub(r'\bNP\b', 'NLD', dims).strip()))
    return ports

# ---- the chain ----
# entry: (module, instance, {port: expr}, {param: value})   expr '$in:name' / '$out:name' = core port, '$new:name' = internal wire
S = []
def stage(mod, inst, m=None, p=None): S.append((mod, inst, m or {}, p or {}))

stage('lsu_cur_info', 'u_cur', {
    'ld_st_q': 'ld_st_q', 'st_st_q': 'st_st_q', 'stq_head_q': 'stq_head_q', 'stq_head_flag_q': 'stq_head_flag_q',
    'stq_count_q': 'stq_count_q', 'stq_ccount_q': 'stq_ccount_q', 'wait_mmu_ldq_count_q': 'wmld_q.count',
    'wait_mmu_stq_count_q': 'wmst_q.count', 'mmu_done_count_q': 'mdone_q.count',
    'lsu2dis_stq_tail': '$out:lsu2dis_stq_tail', 'lsu2dis_stq_tail_flag': '$out:lsu2dis_stq_tail_flag',
    'lsu2dis_stq_free': '$out:lsu2dis_stq_free', 'lsu2dis_ldq_free': '$out:lsu2dis_ldq_free',
    'lsu2dis_ldq_alloc_valid': '$out:lsu2dis_ldq_alloc_valid', 'lsu2dis_ldq_alloc_idx': '$out:lsu2dis_ldq_alloc_idx',
    'lsu2rob_committed_store_pending': '$out:lsu2rob_committed_store_pending'})
stage('lsu_stq_commit', 'u_commit', {
    'cm_valid': '$in:cm_valid', 'cm_type': '$in:cm_type', 'cm_amo_op': '$in:cm_amo_op', 'cm_stq_idx': '$in:cm_stq_idx',
    'flush': '$in:rb_flush'})
stage('lsu_mmio_in', 'u_mmio_in', {
    'resp_is_mmio': '$in:periph_resp_is_mmio', 'resp_rdata': '$in:periph_resp_rdata', 'unc_valid_i': 'unc_valid_q',
    'unc_is_load': 'unc_is_load_q', 'unc_idx': 'unc_idx_q', 'unc_valid_o': '$new:unc_valid_resp'})
stage('lsu_dc_resp_ld', 'u_dc_resp_ld', {
    'rsp_valid': '$in:dcl_valid', 'rsp_req_id': '$in:dcl_req_id', 'rsp_data': '$in:dcl_data', 'rsp_replay': '$in:dcl_replay',
    'fill_valid': '$in:fill_valid', 'fill_line': '$in:fill_line'})
stage('lsu_dc_resp_st', 'u_dc_resp_st', {
    'rsp_valid': '$in:dcs_valid', 'rsp_req_id': '$in:dcs_req_id', 'rsp_replay': '$in:dcs_replay',
    'fill_valid': '$in:fill_valid', 'fill_line': '$in:fill_line'})
stage('lsu_wb_stq', 'u_wb_stq', {
    'lrsc_valid_q': 'lrsc_valid_q', 'lrsc_addr_q': 'lrsc_addr_q', 'sc_clear': '$new:sc_clear', 'n_sc': '$new:n_sc',
    'sc_valid': '$new:sc_valid', 'sc_diag_val': '$new:sc_diag_val', 'sc_result': '$new:sc_result',
    'sc_dest_preg': '$new:sc_dest_preg', 'sc_br_mask': '$new:sc_br_mask', 'sc_rob_idx': '$new:sc_rob_idx',
    'sc_dest_en': '$new:sc_dest_en', 'sc_pf_store': '$new:sc_pf_store',
    'sta_valid': '$out:sta_wb_valid', 'sta_vaddr': '$out:sta_wb_vaddr', 'sta_br_mask': '$out:sta_wb_br_mask',
    'sta_rob_idx': '$out:sta_wb_rob_idx', 'sta_pf_store': '$out:sta_wb_pf_store'})
stage('lsu_wb_ldq', 'u_wb_ldq', {
    'n_sc': 'n_sc', 'sc_valid': 'sc_valid', 'sc_diag_val': 'sc_diag_val', 'sc_result': 'sc_result', 'sc_dest_preg': 'sc_dest_preg',
    'sc_br_mask': 'sc_br_mask', 'sc_rob_idx': 'sc_rob_idx', 'sc_dest_en': 'sc_dest_en', 'sc_pf_store': 'sc_pf_store',
    'lrsc_valid_i': 'lrsc_valid_f1', 'lrsc_addr_i': 'lrsc_addr_q', 'lrsc_br_i': 'lrsc_br_q',
    'lrsc_valid_o': '$new:lrsc_valid_f2', 'lrsc_addr_o': '$new:lrsc_addr_f2', 'lrsc_br_o': '$new:lrsc_br_f2',
    'wb_valid': '$out:wb_valid', 'wb_diag_val': '$out:wb_diag_val', 'wb_result': '$out:wb_result',
    'wb_dest_preg': '$out:wb_dest_preg', 'wb_br_mask': '$out:wb_br_mask', 'wb_rob_idx': '$out:wb_rob_idx',
    'wb_dest_en': '$out:wb_dest_en', 'wb_pf_load': '$out:wb_pf_load', 'wb_pf_store': '$out:wb_pf_store'})
stage('lsu_exe_in_st', 'u_exe_st', {
    'sdu_valid': '$in:sdu_valid', 'sdu_result': '$in:sdu_result', 'sdu_rob_idx': '$in:sdu_rob_idx',
    'sdu_rob_flag': '$in:sdu_rob_flag', 'sdu_stq_idx': '$in:sdu_stq_idx',
    'sta_valid': '$in:sta_valid', 'sta_result': '$in:sta_result', 'sta_dest_preg': '$in:sta_dest_preg', 'sta_func3': '$in:sta_func3',
    'sta_is_atomic': '$in:sta_is_atomic', 'sta_amo_op': '$in:sta_amo_op', 'sta_rob_idx': '$in:sta_rob_idx',
    'sta_rob_flag': '$in:sta_rob_flag', 'sta_stq_idx': '$in:sta_stq_idx'})
stage('lsu_exe_in_ld', 'u_exe_ld', {
    'req_valid': '$in:ldu_valid', 'req_result': '$in:ldu_result', 'req_dest_preg': '$in:ldu_dest_preg', 'req_func3': '$in:ldu_func3',
    'req_is_atomic': '$in:ldu_is_atomic', 'req_amo_op': '$in:ldu_amo_op', 'req_rob_idx': '$in:ldu_rob_idx',
    'req_rob_flag': '$in:ldu_rob_flag', 'req_stq_idx': '$in:ldu_stq_idx', 'req_stq_flag': '$in:ldu_stq_flag',
    'req_ldq_idx': '$in:ldu_ldq_idx'})
stage('lsu_tlb_sel', 'u_tlb_ld', {
    'wait_i': 'wmld_cur', 'wait_tlb': 'ld_wait_tlb', 'vaddr': 'ld_vaddr_cur',
    'req_valid': '$out:mmu_ld_req_valid', 'req_vaddr': '$out:mmu_ld_req_vaddr',
    'req_entry_idx': '$out:mmu_ld_req_entry_idx', 'req_wait_idx': '$out:mmu_ld_req_wait_idx'})
stage('lsu_tlb_sel', 'u_tlb_st', {
    'wait_i': 'wmst_cur', 'wait_tlb': 'st_wait_tlb', 'vaddr': 'st_vaddr_cur',
    'req_valid': '$out:mmu_st_req_valid', 'req_vaddr': '$out:mmu_st_req_vaddr',
    'req_entry_idx': '$out:mmu_st_req_entry_idx', 'req_wait_idx': '$out:mmu_st_req_wait_idx'})
stage('lsu_tlb_resp_ld', 'u_tlb_resp_ld', {
    'rsp_valid': '$in:mmu_ld_valid', 'rsp_paddr': '$in:mmu_ld_paddr', 'rsp_result': '$in:mmu_ld_result',
    'rsp_entry_idx': '$in:mmu_ld_entry_idx', 'rsp_wait_idx': '$in:mmu_ld_wait_idx', 'lrsc_clear': '$new:lrsc_clear_ld'})
stage('lsu_tlb_resp_st', 'u_tlb_resp_st', {
    'rsp_valid': '$in:mmu_st_valid', 'rsp_paddr': '$in:mmu_st_paddr', 'rsp_result': '$in:mmu_st_result',
    'rsp_entry_idx': '$in:mmu_st_entry_idx', 'rsp_wait_idx': '$in:mmu_st_wait_idx', 'lrsc_clear': '$new:lrsc_clear_st'})
stage('lsu_stlf', 'u_stlf', {
    'unc_valid_i': 'unc_valid_resp', 'rb_head_valid': '$in:rb_head_valid', 'rb_head_rob_idx': '$in:rb_head_rob_idx',
    'rb_hi_valid': '$in:rb_hi_valid', 'rb_hi_rob_idx': '$in:rb_hi_rob_idx',
    'unc_set': '$new:unc_set_ld', 'unc_addr': '$new:unc_addr_ld', 'unc_func3': '$new:unc_func3_ld', 'unc_idx': '$new:unc_idx_ld'})
stage('lsu_alloc', 'u_alloc', {
    'ldq_req': '$in:dis_ldq_req', 'ldq_idx': '$in:dis_ldq_idx', 'ldq_br_mask': '$in:dis_ldq_br_mask',
    'ldq_rob_idx': '$in:dis_ldq_rob_idx', 'ldq_rob_flag': '$in:dis_ldq_rob_flag', 'stq_req': '$in:dis_stq_req',
    'stq_br_mask': '$in:dis_stq_br_mask', 'stq_rob_idx': '$in:dis_stq_rob_idx', 'stq_rob_flag': '$in:dis_stq_rob_flag'})
stage('lsu_flush_ld', 'u_flush_ld', {
    'flush': '$in:rb_flush', 'mispred': '$in:dec_mispred', 'dec_br_mask': '$in:dec_br_mask', 'clear_mask': '$in:dec_clear_mask',
    'ld_st_q': 'ld_st_q', 'ld_empty_o': '$new:ld_empty'})
stage('lsu_flush_stq', 'u_flush_stq', {
    'flush': '$in:rb_flush', 'mispred': '$in:dec_mispred', 'dec_br_mask': '$in:dec_br_mask', 'clear_mask': '$in:dec_clear_mask',
    'stq_head_q': 'stq_head_q', 'stq_count_q': 'stq_count_q', 'count_flushed': '$new:count_flushed'})
for r in ['wmld', 'stlf', 'finish', 'wdc']:
    stage('lsu_flush_ring_ld', f'u_fl_{r}', {'flush': '$in:rb_flush', 'mispred': '$in:dec_mispred', 'ring_i': f'{r}_cur',
          'ld_empty': 'ld_empty', 'ring_o': f'$ver:{r}'})
for r in ['wmst', 'mdone']:
    stage('lsu_flush_ring_st', f'u_fl_{r}', {'flush': '$in:rb_flush', 'mispred': '$in:dec_mispred', 'ring_i': f'{r}_cur',
          'stq_head': 'stq_head_cur', 'stq_count': 'stq_count_cur', 'ring_o': f'$ver:{r}'})
stage('lsu_unc', 'u_unc', {
    'valid_post_resp': 'unc_valid_resp', 'is_load_q': 'unc_is_load_q', 'addr_q': 'unc_addr_q', 'wdata_q': 'unc_wdata_q',
    'func3_q': 'unc_func3_q', 'idx_q': 'unc_idx_q', 'ld_set': 'unc_set_ld', 'ld_addr': 'unc_addr_ld', 'ld_func3': 'unc_func3_ld',
    'ld_idx': 'unc_idx_ld', 'flush': '$in:rb_flush', 'mispred': '$in:dec_mispred', 'ld_empty': 'ld_empty',
    'st_st_pre_flush': 'st_st_cur', 'stq_head': 'stq_head_cur', 'count_flushed': 'count_flushed', 'count_final': 'stq_count_cur',
    'st_set': 'unc_set_st', 'st_addr': 'unc_addr_st', 'st_wdata': 'unc_wdata_st', 'st_func3': 'unc_func3_st', 'st_idx': 'unc_idx_st',
    'valid_pre_st': '$new:unc_valid_pre_st', 'valid_o': '$out_state:unc_valid', 'is_load_o': '$out_state:unc_is_load',
    'addr_o': '$out_state:unc_addr', 'wdata_o': '$out_state:unc_wdata', 'func3_o': '$out_state:unc_func3',
    'idx_o': '$out_state:unc_idx'})
stage('lsu_lrsc', 'u_lrsc', {
    'valid_i': 'lrsc_valid_f2', 'addr_i': 'lrsc_addr_f2', 'br_i': 'lrsc_br_f2', 'pf_clear': 'lrsc_pf_clear',
    'mispred': '$in:dec_mispred', 'dec_br_mask': '$in:dec_br_mask', 'clear_mask': '$in:dec_clear_mask',
    'valid_o': '$out_state:lrsc_valid', 'addr_o': '$out_state:lrsc_addr', 'br_o': '$out_state:lrsc_br'})
stage('lsu_dc_req_ld', 'u_dc_req_ld', {
    'req_gen_q': 'req_gen_q', 'req_valid': '$out:dcl_req_valid', 'req_addr': '$out:dcl_req_addr', 'req_id': '$out:dcl_req_id_o'})
stage('lsu_dc_req_st', 'u_dc_req_st', {
    'unc_valid': 'unc_valid_pre_st', 'st_wdr_q': 'st_wdr_start', 'req_valid': '$out:dcs_req_valid', 'req_addr': '$out:dcs_req_addr',
    'req_data': '$out:dcs_req_data', 'req_strb': '$out:dcs_req_strb', 'req_id': '$out:dcs_req_id_o',
    'unc_set': '$new:unc_set_st', 'unc_addr': '$new:unc_addr_st', 'unc_wdata': '$new:unc_wdata_st',
    'unc_func3': '$new:unc_func3_st', 'unc_idx': '$new:unc_idx_st'})
stage('lsu_mmio_out', 'u_mmio_out', {
    'peripheral_ready': '$in:periph_resp_ready', 'unc_valid': 'unc_valid_d', 'unc_is_load': 'unc_is_load_d',
    'unc_addr': 'unc_addr_d', 'unc_wdata': 'unc_wdata_d', 'unc_func3': 'unc_func3_d',
    'req_is_mmio': '$out:periph_req_is_mmio', 'req_wen': '$out:periph_req_wen', 'req_addr': '$out:periph_req_addr',
    'req_wdata': '$out:periph_req_wdata', 'req_fun3': '$out:periph_req_fun3'})
stage('lsu_retire', 'u_retire', {
    'head_i': 'stq_head_cur', 'head_flag_i': 'stq_head_flag_cur', 'count_i': 'stq_count_cur', 'ccount_i': 'stq_ccount_cur',
    'head_o': '$ver:stq_head', 'head_flag_o': '$ver:stq_head_flag', 'count_o': '$ver:stq_count', 'ccount_o': '$ver:stq_ccount'})


# raw SV inserted before the stage with the given instance name; {x_cur} = current version of state variable x
RAW = {
    'u_wb_ldq': """  logic lrsc_valid_f1;
  assign lrsc_valid_f1 = lrsc_valid_q && !sc_clear;   // an SC consumed the reservation""",
    'u_tlb_ld': """  logic [LQ-1:0] ld_wait_tlb;
  logic [SQ-1:0] st_wait_tlb;
  for (genvar e = 0; e < LQ; e++) begin : g_wait_tlb_ld
    assign ld_wait_tlb[e] = {ld_st_cur}[e] == LD_WAIT_TLB;
  end
  for (genvar e = 0; e < SQ; e++) begin : g_wait_tlb_st
    assign st_wait_tlb[e] = {st_st_cur}[e] == ST_WAIT_TLB;
  end""",
    'u_lrsc': """  logic lrsc_pf_clear;
  assign lrsc_pf_clear = lrsc_clear_ld || lrsc_clear_st;""",
    'u_dc_req_st': """  logic [SQ-1:0] st_wdr_start;
  for (genvar e = 0; e < SQ; e++) begin : g_wdr
    assign st_wdr_start[e] = st_st_q[e] == ST_WAIT_DCACHE_RESP;
  end""",
}

def build():
    ver = {v: 0 for v in VARS}
    declared = {}          # internal wire -> decl string
    core_in, core_out = {}, {}   # name -> (type, dims)
    out_state = {}         # var -> d signal declared
    insts, raws = [], []
    decl_order = []

    def cur(v): return f'{v}_q' if ver[v] == 0 else f'{v}_v{ver[v]}'
    def sub(txt): return re.sub(r'\{(\w+)_cur\}', lambda m: cur(m.group(1)), txt)
    def res(e):
        e = re.sub(r'\b(\w+?)_cur\b', lambda m: cur(m.group(1)) if m.group(1) in VARS else m.group(0), e)
        return e

    for mod, inst, mp, par in S:
        ports = parse_ports(mod)
        conns = []
        if inst in RAW: insts.append(('raw', sub(RAW[inst])))
        for d, t, n, dims in ports:
            if n in mp:
                e = mp[n]
                if e.startswith('$in:'):
                    nm = e[4:]
                    core_in.setdefault(nm, (t, dims)); conns.append((n, nm))
                elif e.startswith('$out:'):
                    nm = e[5:]
                    core_out.setdefault(nm, (t, dims)); conns.append((n, nm))
                elif e.startswith('$out_state:'):
                    v = e[11:]
                    out_state[v] = True
                    conns.append((n, v + '_d'))
                elif e.startswith('$new:'):
                    nm = e[5:]
                    declared.setdefault(nm, f'{t} {nm}{" " + dims if dims else ""}')
                    conns.append((n, nm))
                elif e.startswith('$ver:'):
                    v = e[5:]
                    ver[v] += 1
                    conns.append((n, cur(v)))
                else:
                    conns.append((n, res(e)))
                continue
            base = None
            if n.endswith('_i') and n[:-2] in VARS: base, kind = n[:-2], 'i'
            elif n.endswith('_o') and n[:-2] in VARS: base, kind = n[:-2], 'o'
            elif d == 'input' and n in VARS: base, kind = n, 'i'
            if base is None:
                sys.exit(f'unmapped port {mod}.{n}')
            if kind == 'i':
                conns.append((n, cur(base)))
            else:
                ver[base] += 1
                conns.append((n, cur(base)))
        insts.append(('inst', mod, inst, conns))
    return ver, declared, core_in, core_out, out_state, insts


HDR = "// Generated by tests/lsu/gen_core.py -- do not edit.  Ref: back-end/Lsu/RealLsu.cpp  RealLsu (stage chain wiring)\n"

def wrap(items, indent, width=118, sep=', '):
    lines, cur = [], indent
    for it in items:
        add = (it if cur == indent else sep + it)
        if len(cur) + len(add) > width and cur != indent:
            lines.append(cur.rstrip() + sep.rstrip())
            cur = indent + it
        else:
            cur += add
    lines.append(cur)
    return '\n'.join(lines)

def gen_core(ver, declared, core_in, core_out, out_state, insts):
    o = [HDR + "`default_nettype none\n", "module lsu_core", "  import lsu_pkg::*;", "(", "  input  logic clk,", "  input  logic rst_n,"]
    ports = []
    for n, (t, d) in sorted(core_in.items()): ports.append(f"  input  {t} {n}{' ' + d if d else ''}")
    for n, (t, d) in sorted(core_out.items()): ports.append(f"  output {t} {n}{' ' + d if d else ''}")
    o.append(',\n'.join(ports)); o.append(");\n")
    # state wires and chain versions, grouped by (type, dims)
    groups = {}
    for v, (t, d, _) in VARS.items():
        names = [f'{v}_q'] + [f'{v}_v{k}' for k in range(1, ver[v] + 1)]
        if v in out_state: names.append(f'{v}_d')
        groups.setdefault((t, d), []).extend(names)
    for n, dcl in declared.items():
        m = re.match(r'^(.*?)\s+(\w+)(\s+\[\w+\])?$', dcl)
        groups.setdefault((m.group(1), m.group(3) or ''), []).append(m.group(2))
    for (t, d), names in groups.items():
        chunk = []
        for nm in names + [None]:
            if nm is not None:
                chunk.append(nm + d)
                if len(f'  {t} ' + ', '.join(chunk)) < 100: continue
            if chunk:
                o.append(f'  {t} ' + ', '.join(chunk) + ';')
            chunk = [] if nm is None else []
    o.append("")
    # state instance
    conns = []
    for v in VARS:
        last = f'{v}_q' if ver[v] == 0 else f'{v}_v{ver[v]}'
        if v in out_state: last = f'{v}_d'
        conns.append(f'.{v}_d({last})'); conns.append(f'.{v}_q({v}_q)')
    o.append('  lsu_state u_state (.clk(clk), .rst_n(rst_n),')
    o.append(wrap(conns, '    ') + ');\n')
    for it in insts:
        if it[0] == 'raw': o.append(it[1]); continue
        _, mod, inst, c = it
        o.append(f'  {mod} {inst} (')
        o.append(wrap([f'.{a}({b})' for a, b in c], '    ') + ');')
    o.append("\nendmodule\n\n`default_nettype wire")
    return '\n'.join(o) + '\n'

def gen_state(ver, out_state):
    o = [HDR + "`default_nettype none\n", "module lsu_state", "  import lsu_pkg::*;", "(", "  input  logic clk,", "  input  logic rst_n,"]
    ports = []
    for v, (t, d, _) in VARS.items():
        ports.append(f"  input  {t} {v}_d{d}")
        ports.append(f"  output {t} {v}_q{d}")
    o.append(',\n'.join(ports)); o.append(");\n")
    o.append("  // Ref: RealLsu::init (everything zero) / RealLsu::seq (cur = nxt)")
    o.append("  always_ff @(posedge clk) begin")
    o.append("    if (!rst_n) begin")
    for v, (t, d, r) in VARS.items(): o.append(f"      {v}_q <= {r};")
    o.append("    end else begin")
    for v in VARS: o.append(f"      {v}_q <= {v}_d;")
    o.append("    end")
    o.append("  end\n\nendmodule\n\n`default_nettype wire")
    return '\n'.join(o) + '\n'

# spec port -> (core port, kind); kind v = unpacked 1-bit array to packed vector, a = array/scalar passed as is
SPEC_IN = {
 'rob_commit_commit_entry_valid': ('cm_valid', 'v'), 'rob_commit_commit_entry_uop_type': ('cm_type', 'a'),
 'rob_commit_commit_entry_uop_amo_op': ('cm_amo_op', 'a'), 'rob_commit_commit_entry_uop_stq_idx': ('cm_stq_idx', 'a'),
 'rob_bcast_flush': ('rb_flush', 'a'), 'rob_bcast_head_valid': ('rb_head_valid', 'a'), 'rob_bcast_head_rob_idx': ('rb_head_rob_idx', 'a'),
 'rob_bcast_head_incomplete_valid': ('rb_hi_valid', 'a'), 'rob_bcast_head_incomplete_rob_idx': ('rb_hi_rob_idx', 'a'),
 'dec_bcast_mispred': ('dec_mispred', 'a'), 'dec_bcast_br_mask': ('dec_br_mask', 'a'), 'dec_bcast_clear_mask': ('dec_clear_mask', 'a'),
 'dis2lsu_alloc_req': ('dis_stq_req', 'v'), 'dis2lsu_br_mask': ('dis_stq_br_mask', 'a'), 'dis2lsu_rob_idx': ('dis_stq_rob_idx', 'a'),
 'dis2lsu_rob_flag': ('dis_stq_rob_flag', 'a'), 'dis2lsu_ldq_alloc_req': ('dis_ldq_req', 'v'), 'dis2lsu_ldq_idx': ('dis_ldq_idx', 'a'),
 'dis2lsu_ldq_br_mask': ('dis_ldq_br_mask', 'a'), 'dis2lsu_ldq_rob_idx': ('dis_ldq_rob_idx', 'a'),
 'dis2lsu_ldq_rob_flag': ('dis_ldq_rob_flag', 'a'),
 'peripheral_resp_is_mmio': ('periph_resp_is_mmio', 'a'), 'peripheral_resp_ready': ('periph_resp_ready', 'a'),
 'peripheral_resp_mmio_rdata': ('periph_resp_rdata', 'a'),
 'dcache2lsu_load_resps_valid': ('dcl_valid', 'v'), 'dcache2lsu_load_resps_req_id': ('dcl_req_id', 'a'),
 'dcache2lsu_load_resps_data': ('dcl_data', 'a'), 'dcache2lsu_load_resps_replay': ('dcl_replay', 'a'),
 'dcache2lsu_store_resps_valid': ('dcs_valid', 'v'), 'dcache2lsu_store_resps_req_id': ('dcs_req_id', 'a'),
 'dcache2lsu_store_resps_replay': ('dcs_replay', 'a'), 'dcache2lsu_mshr_fill': ('fill_valid', 'a'),
 'dcache2lsu_mshr_fill_line': ('fill_line', 'a'),
}
for t, c in [('sdu', 'sdu'), ('ldu', 'ldu'), ('sta', 'sta')]:
    for f in ['valid', 'uop_result', 'uop_dest_preg', 'uop_func3', 'uop_is_atomic', 'uop_amo_op', 'uop_rob_idx', 'uop_rob_flag',
              'uop_stq_idx', 'uop_stq_flag', 'uop_ldq_idx']:
        core = c + '_' + f.replace('uop_', '')
        kind = 'v' if f in ('valid', 'uop_is_atomic') else 'a'
        SPEC_IN[f'exe2lsu_{t}_req_{f}'] = (core, kind)
for q, c in [('ldq', 'ld'), ('stq', 'st')]:
    for f in ['valid', 'paddr', 'result', 'entry_idx', 'wait_idx']:
        SPEC_IN[f'mmu2lsu_{q}_resp_{f}'] = (f'mmu_{c}_{f}', 'v' if f == 'valid' else 'a')
SPEC_OUT = {
 'lsu2dis_stq_tail': ('lsu2dis_stq_tail', 'a'), 'lsu2dis_stq_tail_flag': ('lsu2dis_stq_tail_flag', 'a'),
 'lsu2dis_stq_free': ('lsu2dis_stq_free', 'a'), 'lsu2dis_ldq_free': ('lsu2dis_ldq_free', 'a'),
 'lsu2dis_ldq_alloc_valid': ('lsu2dis_ldq_alloc_valid', 'v'), 'lsu2dis_ldq_alloc_idx': ('lsu2dis_ldq_alloc_idx', 'a'),
 'lsu2rob_committed_store_pending': ('lsu2rob_committed_store_pending', 'a'),
 'lsu2exe_wb_req_valid': ('wb_valid', 'v'), 'lsu2exe_wb_req_uop_diag_val': ('wb_diag_val', 'a'),
 'lsu2exe_wb_req_uop_result': ('wb_result', 'a'), 'lsu2exe_wb_req_uop_dest_preg': ('wb_dest_preg', 'a'),
 'lsu2exe_wb_req_uop_br_mask': ('wb_br_mask', 'a'), 'lsu2exe_wb_req_uop_rob_idx': ('wb_rob_idx', 'a'),
 'lsu2exe_wb_req_uop_dest_en': ('wb_dest_en', 'v'), 'lsu2exe_wb_req_uop_page_fault_load': ('wb_pf_load', 'v'),
 'lsu2exe_wb_req_uop_page_fault_store': ('wb_pf_store', 'v'),
 'lsu2exe_sta_wb_req_valid': ('sta_wb_valid', 'v'), 'lsu2exe_sta_wb_req_uop_diag_val': ('sta_wb_vaddr', 'a'),
 'lsu2exe_sta_wb_req_uop_result': ('sta_wb_vaddr', 'a'), 'lsu2exe_sta_wb_req_uop_br_mask': ('sta_wb_br_mask', 'a'),
 'lsu2exe_sta_wb_req_uop_rob_idx': ('sta_wb_rob_idx', 'a'), 'lsu2exe_sta_wb_req_uop_page_fault_store': ('sta_wb_pf_store', 'v'),
 'peripheral_req_is_mmio': ('periph_req_is_mmio', 'a'), 'peripheral_req_wen': ('periph_req_wen', 'a'),
 'peripheral_req_mmio_addr': ('periph_req_addr', 'a'), 'peripheral_req_mmio_wdata': ('periph_req_wdata', 'a'),
 'peripheral_req_mmio_fun3': ('periph_req_fun3', 'a'),
 'lsu2dcache_load_ports_valid': ('dcl_req_valid', 'v'), 'lsu2dcache_load_ports_addr': ('dcl_req_addr', 'a'),
 'lsu2dcache_load_ports_req_id': ('dcl_req_id_o', 'a'), 'lsu2dcache_store_ports_valid': ('dcs_req_valid', 'v'),
 'lsu2dcache_store_ports_addr': ('dcs_req_addr', 'a'), 'lsu2dcache_store_ports_data': ('dcs_req_data', 'a'),
 'lsu2dcache_store_ports_strb': ('dcs_req_strb', 'a'), 'lsu2dcache_store_ports_req_id': ('dcs_req_id_o', 'a'),
}
for q, c in [('ldq', 'ld'), ('stq', 'st')]:
    for f in ['valid', 'vaddr', 'entry_idx', 'wait_idx']:
        SPEC_OUT[f'lsu2mmu_{q}_req_{f}'] = (f'mmu_{c}_req_{f}', 'v' if f == 'valid' else 'a')

def gen_top(core_in, core_out):
    spec = [l for l in open(os.path.join(ROOT, 'spec/lsu.io')).read().split('\n') if re.match(r'^(in|out)\s', l)]
    pl, body, wires, conns, used = [], [], [], [], set()
    for l in spec:
        l = l.split('@')[0].split(' when ')[0]
        m = re.match(r'^(in|out)\s+(\w+)\s+(\d+)((?:\s*\[\d+\])*)', l)
        d, n, w, dims = m.group(1), m.group(2), int(m.group(3)), re.findall(r'\[(\d+)\]', m.group(4))
        tbl = SPEC_IN if d == 'in' else SPEC_OUT
        if n not in tbl: sys.exit(f'no core mapping for spec port {n}')
        core, kind = tbl[n]; used.add(core)
        wt = 'logic' if w == 1 else f'logic [{w-1}:0]'
        dd = ''.join(f' [{x}]' for x in dims)
        pl.append(f"  {'input ' if d == 'in' else 'output'} {wt} {n}{dd}")
        if kind == 'v':
            N = dims[0]
            wires.append(f'  logic [{N}-1:0] {core}_vec;')
            if d == 'in':
                body.append(f'  for (genvar i = 0; i < {N}; i++) begin : g_{core}\n    assign {core}_vec[i] = {n}[i];\n  end')
            else:
                body.append(f'  for (genvar i = 0; i < {N}; i++) begin : g_{core}_{n[-8:]}\n    assign {n}[i] = {core}_vec[i];\n  end')
            conns.append(f'.{core}({core}_vec)')
        else:
            if core in used and False: pass
            conns.append(f'.{core}({n})')
    # core ports that are used by two spec ports (sta_wb_vaddr) are connected once
    seen, cc = set(), []
    for c in conns:
        if c.split('(')[0] in seen: continue
        seen.add(c.split('(')[0]); cc.append(c)
    # sta_wb_vaddr drives two spec outputs: connect through a wire
    o = [HDR + "`default_nettype none\n", "module lsu", "  import lsu_pkg::*;", "(", "  input  logic clk,", "  input  logic rst_n,",
         ',\n'.join(pl), ");\n"]
    o += wires
    o.append("  logic [31:0] sta_wb_vaddr_w [NST];")
    o.append("")
    o += body
    o.append("  for (genvar i = 0; i < NST; i++) begin : g_sta_dup\n    assign lsu2exe_sta_wb_req_uop_diag_val[i] = sta_wb_vaddr_w[i];\n    assign lsu2exe_sta_wb_req_uop_result[i] = sta_wb_vaddr_w[i];\n  end\n")
    cc = [c for c in cc if not c.startswith('.sta_wb_vaddr(')] + ['.sta_wb_vaddr(sta_wb_vaddr_w)']
    o.append('  lsu_core u_core (.clk(clk), .rst_n(rst_n),')
    o.append(wrap(cc, '    ') + ');')
    o.append("\nendmodule\n\n`default_nettype wire")
    return '\n'.join(o) + '\n'

if __name__ == '__main__':
    ver, declared, core_in, core_out, out_state, insts = build()
    open(os.path.join(RTL, 'lsu_core.sv'), 'w').write(gen_core(ver, declared, core_in, core_out, out_state, insts))
    open(os.path.join(RTL, 'lsu_state.sv'), 'w').write(gen_state(ver, out_state))
    open(os.path.join(RTL, 'lsu.sv'), 'w').write(gen_top(core_in, core_out))
    miss = [n for n in list(core_in) + list(core_out) if n not in {c for c, k in list(SPEC_IN.values()) + list(SPEC_OUT.values())}]
    print('core ports without spec mapping:', miss)
