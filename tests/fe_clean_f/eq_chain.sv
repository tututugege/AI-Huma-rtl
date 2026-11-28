// Cleanup F equivalence (items 1-3): the old fetch chain (ref/: icache_resp x2 -> front_fetch_buf -> inst_fifo with raw
// A + raw B halfwords -> front_head_fix -> front_slot_kind x16, front_pd_info on the instruction words) against the
// new one (icache_resp halfwords -> front_fetch_buf merging A/B before the queue -> front_head_fix with kind_o ->
// front_pd_info on kind), driven by the same random F1 response / queue control / head-fix side inputs every cycle.
// The F1 response follows rtl/frontend/icache/icache.sv (straddle / tail / a_len / b_nwords from the pc, B = Lo half of
// the next line, uncached single word, page fault, refetch).  Every output of front_head_fix, the FTQ slot kind, the
// predecode_checker result and the front_pd_info registers are compared every cycle; prints the first mismatches or PASS.
`default_nettype none
module eq_chain import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import icache_pkg::*; import fe_ref_pkg::*; #(parameter int NCYC = 1000000) ();
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  longint unsigned rs = 64'h2545f4914f6cdd1d;
  function automatic longint unsigned rnd();
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
  endfunction
  function automatic bit pct(input int p);
    return (rnd() % 100) < longint'(p);
  endfunction

  // a halfword biased towards control flow: compressed j/jal/jr/jalr/beqz/bnez, the low half of jal / jalr / branch
  // (rd = ra or x0, rs1 = ra), upper halves 0 / 1 (ret has imm = 0), else random
  function automatic logic [15:0] rnd_half();
    longint unsigned r = rnd();
    logic [15:0] h = 16'(r >> 8);
    case (r % 16)
      0: return {3'b101, h[12:2], 2'b01};                          // c.j
      1: return {3'b100, 1'b0, h[11:7], 5'b0, 2'b10};              // c.jr
      2: return {3'b100, 1'b1, h[11:7], 5'b0, 2'b10};              // c.jalr / c.ebreak
      3: return {2'b11, h[13], h[12:2], 2'b01};                    // c.beqz / c.bnez
      4: return {h[15:12], 5'd1, 7'b1101111};                      // jal ra (low half)
      5: return {h[15:12], 5'd0, 7'b1101111};                      // jal x0
      6: return {1'b1, 3'b000, 5'd0, 7'b1100111};                  // jalr x0, ra (ret low half)
      7: return {h[15:12], h[0] ? 5'd1 : 5'd0, 7'b1100111};        // jalr
      8: return {h[15:12], h[11:7], 7'b1100011};                   // branch
      9: return 16'h0000;
      10: return 16'h0001;
      11: return {h[15:2], 2'b11};                                 // some other 32-bit low half
      default: return h;
    endcase
  endfunction
  function automatic logic [255:0] rnd_256();
    logic [255:0] v;
    for (int k = 0; k < 16; k++) v[16 * k +: 16] = rnd_half();
    return v;
  endfunction

  // ---- shared stimulus ----
  logic                   refetch, f1_valid, rc, pf, single, from_sram, b_hit_q, b_pa_ok;
  logic [XLEN_BITS-1:0]   pc;
  logic [255:0]           lo_rdata, hi_rdata;
  logic [IC_LINE_W-1:0]   byp_line, line_a;
  logic                   same_pg, straddle, tail, b_en;
  logic [3:0]             a_len, b_nwords;
  logic [XLEN_BITS-1:0]   b_addr;
  logic [1:0]             ic_inflight;
  logic                   rd_en, ifu_rd_en;
  logic [XLEN_BITS-1:0]   ftq_ifu_addr;
  logic [XLEN_BITS-1:0]   pd_base_pc, pd_next_pc;
  logic [FETCH_WIDTH-1:0] predict_dir;
  logic                   lh_valid, chk_en;
  logic [XLEN_BITS-1:0]   lh_pc;
  logic [15:0]            lh_data;

  always_comb begin
    same_pg  = (pc[11:6] != 6'h3f);
    straddle = (pc[5:0] > 6'd32) && same_pg;
    tail     = (pc[5:0] == 6'd32) && same_pg;
    a_len    = straddle ? 4'((7'd64 - {1'b0, pc[5:0]}) >> 1) : 4'd0;
    b_nwords = straddle ? (4'd0 - a_len) : (tail ? 4'd1 : 4'd0);
    b_addr   = {pc[XLEN_BITS-1:6] + (XLEN_BITS-6)'(1), 6'd0};
    b_en     = from_sram && (straddle || tail) && b_pa_ok;
    rc       = !refetch && f1_valid;
    line_a   = from_sram ? (pc[5] ? {hi_rdata, 256'd0} : {hi_rdata, lo_rdata}) : byp_line;
  end

  // ---- old chain ----
  logic [XLEN_BITS-1:0]   o_fpc, o_bpc;
  logic [31:0]            o_fg [FETCH_WIDTH], o_bfg [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] o_pf, o_v, o_up, o_bpf, o_bv, o_bup;
  logic                   o_ifu_v, o_room, o_empty;
  logic [XLEN_BITS-1:0]   o_ifu_a;
  fe_ref_inst_fifo_entry_t o_rd;

  icache_resp_ref u_o_resp (.resp_valid(rc), .resp_pc(pc), .resp_page_fault(pf), .resp_single_word(single),
    .resp_line(line_a), .fetch_pc(o_fpc), .fetch_group(o_fg), .page_fault_inst(o_pf), .inst_valid(o_v),
    .upper_ok(o_up));
  icache_resp_ref u_o_resp_b (.resp_valid(rc && b_en && b_hit_q), .resp_pc(b_addr), .resp_page_fault(1'b0),
    .resp_single_word(1'b0), .resp_line({256'd0, lo_rdata}), .fetch_pc(o_bpc), .fetch_group(o_bfg),
    .page_fault_inst(o_bpf), .inst_valid(o_bv), .upper_ok(o_bup));
  front_fetch_buf_ref u_o_fb (.clk, .rst_n, .global_refetch(refetch), .ftq_ifu_addr, .ifu_rd_en,
    .ifu_rd_valid(o_ifu_v), .ifu_rd_address(o_ifu_a), .inst_fifo_room(o_room), .ic_inflight,
    .ic_read_complete(rc), .ic_fetch_pc(o_fpc), .ic_inst_valid(o_v), .ic_page_fault_inst(o_pf),
    .ic_fetch_group(o_fg), .ic_fetch_single_word(single),
    .ic_b_is_straddle(rc && b_en && straddle), .ic_b_is_tail(rc && b_en && tail), .ic_b_a_len(a_len),
    .b_hit(rc && b_en && b_hit_q && (b_nwords != 4'd0)), .b_actual_n({1'b0, b_nwords}), .b_fetch_group(o_bfg),
    .inst_rd_en(rd_en), .inst_empty(o_empty), .inst_rd(o_rd));

  logic [31:0]            o_insts [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] o_valid, o_pfo, o_pfhi, o_rvc;
  logic [1:0]             o_ty [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   o_tgt [FETCH_WIDTH], o_spc [FETCH_WIDTH], o_pdpc [FETCH_WIDTH];
  logic                   o_carry, o_strad;
  logic [15:0]            o_low;
  logic [XLEN_BITS-1:0]   o_end, o_seq;
  logic [KIND_W-1:0]      o_kind [FETCH_WIDTH];
  front_head_fix_ref u_o_hf (.inst_e(o_rd), .pd_base_pc, .predict_dir, .lh_valid, .lh_pc, .lh_data,
    .insts_o(o_insts), .valid_o(o_valid), .pf_o(o_pfo), .pf_hi_o(o_pfhi), .ptype_o(o_ty), .ptarget_o(o_tgt),
    .is_rvc_o(o_rvc), .slot_pc_o(o_spc), .pd_pc_o(o_pdpc), .carry(o_carry), .straddle(o_strad), .carry_low(o_low),
    .group_end_pc(o_end), .seq_next_o(o_seq));
  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_o_kind
    front_slot_kind_ref u_k (.inst(o_insts[i]), .kind(o_kind[i]));
  end
  logic [FETCH_WIDTH-1:0] o_dirc;
  logic [XLEN_BITS-1:0]   o_nextc;
  logic                   o_fl;
  predecode_checker u_o_chk (.predict_dir, .predict_next_fetch_address(pd_next_pc), .predecode_type(o_ty),
    .predecode_target_address(o_tgt), .seq_next_pc(o_seq), .predict_dir_corrected(o_dirc),
    .predict_next_fetch_address_corrected(o_nextc), .predecode_flush_enable(o_fl));
  logic                 o_pv, o_pfl, o_phn, o_nbv;
  logic [HSYM_W-1:0]    o_hb;
  logic [1:0]           o_rop;
  logic [XLEN_BITS-1:0] o_rval, o_nbpc;
  front_pd_info_ref u_o_pd (.clk, .rst_n, .checked(chk_en), .flush(chk_en && o_fl), .slot_pc(o_spc), .is_rvc(o_rvc),
    .insts(o_insts), .inst_valid(o_valid), .ptype(o_ty), .pre_target(o_tgt), .dir_corrected(o_dirc), .predict_dir,
    .pd_next_pc, .pd_valid(o_pv), .pd_flush(o_pfl), .pd_hn(o_phn), .pd_hbits(o_hb), .pd_ras_op(o_rop),
    .pd_ras_val(o_rval), .pd_nb_valid(o_nbv), .pd_nb_pc(o_nbpc));

  // ---- new chain ----
  logic [XLEN_BITS-1:0]   n_fpc;
  logic [15:0]            n_half [FETCH_WIDTH], n_bhalf [FETCH_WIDTH], n_up16;
  logic [FETCH_WIDTH-1:0] n_pf, n_v;
  logic                   n_ifu_v, n_room, n_empty;
  logic [XLEN_BITS-1:0]   n_ifu_a;
  inst_fifo_entry_t       n_rd;

  icache_resp u_n_resp (.resp_valid(rc), .resp_pc(pc), .resp_page_fault(pf), .resp_single_word(single),
    .resp_line(line_a), .fetch_pc(n_fpc), .fetch_half(n_half), .fetch_up16(n_up16), .page_fault_inst(n_pf),
    .inst_valid(n_v));
  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_bh
    assign n_bhalf[i] = lo_rdata[16 * i +: 16];   // icache.sv g_b_half
  end
  front_fetch_buf u_n_fb (.clk, .rst_n, .global_refetch(refetch), .ftq_ifu_addr, .ifu_rd_en,
    .ifu_rd_valid(n_ifu_v), .ifu_rd_address(n_ifu_a), .inst_fifo_room(n_room), .ic_inflight,
    .ic_read_complete(rc), .ic_fetch_pc(n_fpc), .ic_inst_valid(n_v), .ic_page_fault_inst(n_pf),
    .ic_fetch_half(n_half), .ic_fetch_up16(n_up16), .ic_fetch_single_word(single),
    .ic_b_is_straddle(rc && b_en && straddle), .ic_b_is_tail(rc && b_en && tail), .ic_b_a_len(a_len),
    .b_hit(rc && b_en && b_hit_q && (b_nwords != 4'd0)), .b_actual_n(b_nwords), .b_half(n_bhalf),
    .inst_rd_en(rd_en), .inst_empty(n_empty), .inst_rd(n_rd));

  logic [31:0]            n_insts [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] n_valid, n_pfo, n_pfhi, n_rvc;
  logic [1:0]             n_ty [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   n_tgt [FETCH_WIDTH], n_spc [FETCH_WIDTH], n_pdpc [FETCH_WIDTH];
  logic                   n_carry, n_strad;
  logic [15:0]            n_low;
  logic [XLEN_BITS-1:0]   n_end, n_seq;
  logic [KIND_W-1:0]      n_kind [FETCH_WIDTH];
  front_head_fix u_n_hf (.inst_e(n_rd), .pd_base_pc, .predict_dir, .lh_valid, .lh_pc, .lh_data,
    .insts_o(n_insts), .valid_o(n_valid), .pf_o(n_pfo), .pf_hi_o(n_pfhi), .ptype_o(n_ty), .kind_o(n_kind),
    .ptarget_o(n_tgt), .is_rvc_o(n_rvc), .slot_pc_o(n_spc), .pd_pc_o(n_pdpc), .carry(n_carry), .straddle(n_strad),
    .carry_low(n_low), .group_end_pc(n_end), .seq_next_o(n_seq));
  logic [FETCH_WIDTH-1:0] n_dirc;
  logic [XLEN_BITS-1:0]   n_nextc;
  logic                   n_fl;
  predecode_checker u_n_chk (.predict_dir, .predict_next_fetch_address(pd_next_pc), .predecode_type(n_ty),
    .predecode_target_address(n_tgt), .seq_next_pc(n_seq), .predict_dir_corrected(n_dirc),
    .predict_next_fetch_address_corrected(n_nextc), .predecode_flush_enable(n_fl));
  logic                 n_pv, n_pfl, n_phn, n_nbv;
  logic [HSYM_W-1:0]    n_hb;
  logic [1:0]           n_rop;
  logic [XLEN_BITS-1:0] n_rval, n_nbpc;
  front_pd_info u_n_pd (.clk, .rst_n, .checked(chk_en), .flush(chk_en && n_fl), .slot_pc(n_spc), .is_rvc(n_rvc),
    .kind(n_kind), .inst_valid(n_valid), .ptype(n_ty), .pre_target(n_tgt), .dir_corrected(n_dirc), .predict_dir,
    .pd_next_pc, .pd_valid(n_pv), .pd_flush(n_pfl), .pd_hn(n_phn), .pd_hbits(n_hb), .pd_ras_op(n_rop),
    .pd_ras_val(n_rval), .pd_nb_valid(n_nbv), .pd_nb_pc(n_nbpc));

  // ---- drive (negedge) ----
  task automatic drive();
    logic [5:0] off;
    longint unsigned r;
    refetch   = pct(3);
    f1_valid  = pct(85);
    from_sram = pct(80);
    single    = !from_sram && pct(50);
    pf        = pct(4);
    b_pa_ok   = pct(85);
    b_hit_q   = pct(75);
    r   = rnd();
    case (r % 4)
      0: off = 6'd32;
      1: off = 6'd33 + 6'(rnd() % 31);
      default: off = 6'(rnd());
    endcase
    if (!pct(6)) off[0] = 1'b0;   // odd pcs only on (rare) wrong paths
    pc = {rnd()};
    pc[XLEN_BITS-1:39] = '0;
    if (pct(12)) pc[11:6] = 6'h3f;
    pc[5:0] = off;
    lo_rdata = rnd_256();
    hi_rdata = rnd_256();
    byp_line = {rnd_256(), rnd_256()};
    ic_inflight  = 2'(rnd() % 3);
    rd_en        = pct(55);
    ifu_rd_en    = pct(50);
    ftq_ifu_addr = rnd();
    // head-fix side inputs, mostly agreeing with the queue head
    pd_base_pc = o_rd.base_a;
    if (pct(10)) pd_base_pc = o_rd.base_a + XLEN_BITS'(2 * (rnd() % 16));
    if (pct(3))  pd_base_pc = rnd();
    pd_next_pc  = pct(50) ? o_rd.base_a + XLEN_BITS'(2 * (rnd() % 40)) : rnd();
    predict_dir = pct(50) ? FETCH_WIDTH'(rnd() & rnd() & rnd()) : FETCH_WIDTH'(rnd());
    lh_valid    = pct(45);
    lh_pc       = pct(75) ? o_rd.base_a : rnd();
    lh_data     = rnd_half();
    chk_en      = !o_empty && pct(70);
  endtask

  // ---- compare (posedge, before the state moves) ----
  int ncyc = 0, nerr = 0, nhead = 0;
  longint unsigned c_strad = 0, c_tail = 0, c_carry = 0, c_strout = 0, c_comp = 0, c_pf = 0, c_call = 0, c_ret = 0,
                   c_fl = 0, c_odd = 0, c_ret_lane = 0, c_pfcarry = 0, c_push = 0;
  `define CHK(a, b, nm) if ((a) !== (b)) begin nerr++; if (nerr <= 10) $display("cycle %0d: %s old=%h new=%h", ncyc, nm, a, b); end

  always @(posedge clk) if (rst_n) begin
    ncyc++;
    `CHK(o_ifu_v, n_ifu_v, "ifu_rd_valid")
    `CHK(o_ifu_a, n_ifu_a, "ifu_rd_address")
    `CHK(o_room, n_room, "inst_fifo_room")
    `CHK(o_empty, n_empty, "inst_empty")
    `CHK(o_valid, n_valid, "valid_o")
    `CHK(o_pfo, n_pfo, "pf_o")
    `CHK(o_pfhi, n_pfhi, "pf_hi_o")
    `CHK(o_rvc, n_rvc, "is_rvc_o")
    `CHK(o_carry, n_carry, "carry")
    `CHK(o_strad, n_strad, "straddle")
    `CHK(o_low, n_low, "carry_low")
    `CHK(o_end, n_end, "group_end_pc")
    `CHK(o_seq, n_seq, "seq_next_o")
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      `CHK(o_insts[i], n_insts[i], $sformatf("insts_o[%0d]", i))
      `CHK(o_ty[i], n_ty[i], $sformatf("ptype_o[%0d]", i))
      `CHK(o_tgt[i], n_tgt[i], $sformatf("ptarget_o[%0d]", i))
      `CHK(o_spc[i], n_spc[i], $sformatf("slot_pc_o[%0d]", i))
      `CHK(o_pdpc[i], n_pdpc[i], $sformatf("pd_pc_o[%0d]", i))
      `CHK(o_kind[i], n_kind[i], $sformatf("slot_kind[%0d]", i))
    end
    `CHK(o_dirc, n_dirc, "dir_corrected")
    `CHK(o_nextc, n_nextc, "next_corrected")
    `CHK(o_fl, n_fl, "flush_enable")
    `CHK({o_pv, o_pfl, o_phn, o_hb, o_rop, o_rval, o_nbv, o_nbpc},
         {n_pv, n_pfl, n_phn, n_hb, n_rop, n_rval, n_nbv, n_nbpc}, "pd_info regs")
    if (!o_empty) begin
      nhead++;
      c_strad  += o_rd.is_straddle;
      c_tail   += (!o_rd.is_straddle && o_rd.b_ok);
      c_carry  += o_carry;
      c_strout += o_strad;
      c_pf     += o_pfo[0];
      c_pfcarry += o_pfo[0] && o_carry;
      c_fl     += o_fl;
      c_odd    += o_rd.base_a[0];
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        c_call += o_valid[i] && (o_kind[i] == BR_CALL);
        c_ret  += o_valid[i] && (o_kind[i] == BR_RET);
      end
    end
    c_ret_lane += (o_rop == 2'd2);
    c_push     += (o_rop == 2'd1);
    c_comp += (u_o_hf.complete_oh != '0);
  end

  initial begin
    rst_n = 1'b0;
    drive();
    repeat (3) begin #1 clk = 1'b1; #1 clk = 1'b0; end
    rst_n = 1'b1;
    for (int c = 0; c < NCYC; c++) begin
      drive();
      #1 clk = 1'b1;
      #1 clk = 1'b0;
    end
    $display("cycles %0d, head present %0d: straddle entries %0d, tail-with-B %0d, carry %0d, straddler out %0d, complete %0d,",
             ncyc, nhead, c_strad, c_tail, c_carry, c_strout, c_comp);
    $display("  page-fault heads %0d (with carry %0d), odd-pc heads %0d, checker flush %0d, valid call %0d, valid ret %0d, RAS pushes %0d, RAS pops %0d (unreachable: a taken jalr never flushes)",
             c_pf, c_pfcarry, c_odd, c_fl, c_call, c_ret, c_push, c_ret_lane);
    if (nerr == 0) $display("PASS eq_chain: %0d cycles, 0 mismatches", ncyc);
    else           $display("FAIL eq_chain: %0d mismatches", nerr);
    $finish;
  end
endmodule
`default_nettype wire
