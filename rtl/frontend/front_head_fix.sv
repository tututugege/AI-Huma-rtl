// Ref: front-end/front_top.cpp  InstPort::comb_read (S2-confirmed A/B mux, PTAB PC agreement cut, rvc_head_fix)
`default_nettype none

// Instruction-queue head preparation before predecode_checker:
//   1) S2-confirmed A/B mux: if has_alt_a && !ptab_is_pair, restore intact Block A;
//   2) PTAB PC agreement cut: drop any suffix whose PC disagrees with the PTAB entry, updating up16/up_ok/seq_next_pc;
//   3) RVC=1 C910-style carry assembly, instruction-start filtering, and last-slot straddler completion/carry.
module front_head_fix import ttg_cfg_pkg::*; import front_pkg::*; (
  input  inst_fifo_entry_t        inst_e,
  input  logic [XLEN_BITS-1:0]    ptab_base_pc,
  input  logic                    ptab_is_pair,
  input  logic [XLEN_BITS-1:0]    ptab_base_b,
  input  logic [3:0]              ptab_a_len,
  input  logic [FETCH_WIDTH-1:0]  predict_dir,
  input  logic                    lh_valid,
  input  logic [XLEN_BITS-1:0]    lh_pc,
  input  logic [15:0]             lh_data,
  output logic [31:0]             insts_o      [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  valid_o,
  output logic [FETCH_WIDTH-1:0]  pf_o,
  output logic [1:0]              ptype_o      [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0]    ptarget_o    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  is_rvc_o,
  output logic [XLEN_BITS-1:0]    slot_pc_o    [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0]    ptab_pc_o    [FETCH_WIDTH],
  output logic                    multi_o,
  output logic [FETCH_WIDTH-1:0]  in_range_o,
  output logic [FETCH_WIDTH-1:0]  seg_first_o,
  output logic                    carry,
  output logic                    straddle,
  output logic [15:0]             carry_low,
  output logic [XLEN_BITS-1:0]    group_end_pc,
  output logic [XLEN_BITS-1:0]    seq_next_o
);

  // ---- Step 1: S2-confirmed A/B mux ----
  logic                   use_alt;
  logic [31:0]            s1_inst  [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   s1_pc    [FETCH_WIDTH], ptab_pc [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] s1_v, s1_pf, s1_rvc, s1_sa, s1_sb;
  logic [1:0]             s1_ty    [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   s1_tgt   [FETCH_WIDTH];
  logic [15:0]            s1_up16;
  logic                   s1_up_ok;
  logic [XLEN_BITS-1:0]   s1_seq;

  always_comb begin
    use_alt  = inst_e.has_alt_a && !ptab_is_pair;
    s1_v     = use_alt ? inst_e.alt_inst_valid      : inst_e.inst_valid;
    s1_pf    = use_alt ? inst_e.alt_page_fault_inst : inst_e.page_fault_inst;
    s1_rvc   = use_alt ? inst_e.alt_is_rvc          : inst_e.is_rvc;
    s1_sa    = use_alt ? inst_e.alt_start_a         : inst_e.start_a;
    s1_sb    = use_alt ? inst_e.alt_start_b         : inst_e.start_b;
    s1_up16  = use_alt ? inst_e.alt_up16            : inst_e.up16;
    s1_up_ok = use_alt ? inst_e.alt_up_ok           : inst_e.up_ok;
    s1_seq   = use_alt ? inst_e.alt_seq_next_pc     : inst_e.seq_next_pc;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      s1_inst[i] = use_alt ? inst_e.alt_instructions[i]             : inst_e.instructions[i];
      s1_ty[i]   = use_alt ? inst_e.alt_predecode_type[i]           : inst_e.predecode_type[i];
      s1_tgt[i]  = use_alt ? inst_e.alt_predecode_target_address[i] : inst_e.predecode_target_address[i];
      s1_pc[i]   = use_alt ? (inst_e.base_a + XLEN_BITS'(SLOT_BYTES * i))
                           : pair_slot_pc(inst_e.base_a, inst_e.is_pair, inst_e.a_len, inst_e.base_b, i);
      ptab_pc[i] = pair_slot_pc(ptab_base_pc, ptab_is_pair, ptab_a_len, ptab_base_b, i);
    end
  end

  // ---- Step 2: PTAB PC agreement cut & segment descriptors ----
  logic [FETCH_WIDTH-1:0] s2_v;
  logic [1:0]             s2_ty  [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   s2_tgt [FETCH_WIDTH];
  logic [15:0]            s2_up16;
  logic                   s2_up_ok;
  logic [XLEN_BITS-1:0]   s2_seq;

  always_comb begin
    logic cut, dropped;
    int last_v;
    cut     = 1'b0;
    dropped = 1'b0;
    last_v  = -1;
    multi_o = 1'b0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if (!cut && s1_v[i] && (s1_pc[i] != ptab_pc[i])) cut = 1'b1;
      if (cut) begin
        if (s1_v[i]) dropped = 1'b1;
        s2_v[i]   = 1'b0;
        s2_ty[i]  = PREDECODE_NON_BRANCH;
        s2_tgt[i] = '0;
      end else begin
        s2_v[i]   = s1_v[i];
        s2_ty[i]  = s1_ty[i];
        s2_tgt[i] = s1_tgt[i];
      end
      if (s2_v[i]) last_v = i;
    end
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      in_range_o[i]  = s2_v[i];
      seg_first_o[i] = (i > 0) && s2_v[i] && s2_v[i - 1] && (s1_pc[i] != s1_pc[i - 1] + XLEN_BITS'(SLOT_BYTES));
      if (seg_first_o[i]) multi_o = 1'b1;
    end
    s2_seq   = s1_seq;
    s2_up16  = s1_up16;
    s2_up_ok = s1_up_ok;
    if (dropped && (last_v >= 0)) begin
      s2_seq   = s1_pc[last_v] + XLEN_BITS'(SLOT_BYTES);
      s2_up16  = s1_inst[last_v][31:16];
      s2_up_ok = 1'b1;
    end
  end

  assign pf_o = s1_pf;

  // ---- Step 3: RVC=1 carry assembly + instruction-start filter + straddler ----
  logic [XLEN_BITS-1:0] asm_pc, comp_pc;
  logic [31:0]          asm_word, comp_word;
  logic [1:0]           asm_type, comp_type;
  logic [XLEN_BITS-1:0] asm_tgt, comp_tgt;
  logic [FETCH_WIDTH-1:0] chain, last_oh, straddle_raw_oh, complete_oh, straddle_oh, keep;
  logic [15:0]          raw_low [FETCH_WIDTH];
  logic [15:0]          comp_low;
  logic [4:0]           rvc_n;

  assign carry    = (RVC_ENABLE != 0) && lh_valid && (lh_pc == s1_pc[0]) && s2_v[0];
  assign asm_pc   = s1_pc[0] - XLEN_BITS'(SLOT_BYTES);
  assign asm_word = {inst_e.raw0, lh_data};

  predecode_lane u_asm (
    .pc(asm_pc), .inst(asm_word), .inst_valid(1'b1),
    .predecode_type(asm_type), .predecode_target_address(asm_tgt)
  );

  always_comb begin
    int n;
    n     = 0;
    chain = carry ? s1_sb : s1_sa;
    for (int i = 0; i < FETCH_WIDTH; i++) if ((n == i) && s2_v[i]) n = i + 1;
    rvc_n = 5'(n);
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      last_oh[i]         = (n > 0) && (i == (n - 1));
      straddle_raw_oh[i] = (RVC_ENABLE != 0) && last_oh[i] && chain[i] && !s1_rvc[i] && !s1_pf[i];
      complete_oh[i]     = straddle_raw_oh[i] && predict_dir[i] && s2_up_ok;
      straddle_oh[i]     = straddle_raw_oh[i] && !complete_oh[i];
      raw_low[i]         = s1_inst[i][15:0];
      keep[i]            = (RVC_ENABLE != 0) ? (s2_v[i] && (chain[i] || (carry && (i == 0)))) : s2_v[i];
      valid_o[i]         = keep[i] && !straddle_oh[i];
      slot_pc_o[i]       = (i == 0 && carry) ? asm_pc : s1_pc[i];
      ptab_pc_o[i]       = (i == 0 && carry) ? asm_pc : ptab_pc[i];
    end
  end

  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_comp_pc  (.sel(complete_oh), .data(slot_pc_o), .out(comp_pc));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16))        u_comp_low (.sel(complete_oh), .data(raw_low),   .out(comp_low));
  assign comp_word = {s2_up16, comp_low};

  predecode_lane u_comp (
    .pc(comp_pc), .inst(comp_word), .inst_valid(1'b1),
    .predecode_type(comp_type), .predecode_target_address(comp_tgt)
  );

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if (i == 0 && carry) begin
        insts_o[i]   = asm_word;
        is_rvc_o[i]  = 1'b0;
        ptype_o[i]   = valid_o[i] ? asm_type : PREDECODE_NON_BRANCH;
        ptarget_o[i] = valid_o[i] ? asm_tgt  : '0;
      end else if (complete_oh[i]) begin
        insts_o[i]   = comp_word;
        is_rvc_o[i]  = 1'b0;
        ptype_o[i]   = valid_o[i] ? comp_type : PREDECODE_NON_BRANCH;
        ptarget_o[i] = valid_o[i] ? comp_tgt  : '0;
      end else begin
        insts_o[i]   = s1_inst[i];
        is_rvc_o[i]  = (RVC_ENABLE != 0) && s1_rvc[i];
        ptype_o[i]   = valid_o[i] ? s2_ty[i]  : PREDECODE_NON_BRANCH;
        ptarget_o[i] = valid_o[i] ? s2_tgt[i] : '0;
      end
      // Carry cross-page 2nd-halfword instruction page-fault offset (+2) in inst->diag_val for ROB stval
      if (s1_pf[i]) insts_o[i] = (i == 0 && carry) ? 32'd2 : 32'd0;
    end
    group_end_pc = (rvc_n != 5'd0) ? (slot_pc_o[rvc_n[3:0] - 4'd1] + XLEN_BITS'(SLOT_BYTES)) : slot_pc_o[0];
  end

  assign straddle   = |straddle_oh;
  assign seq_next_o = (|complete_oh) ? (comp_pc + XLEN_BITS'(4)) : s2_seq;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_carry_low (.sel(straddle_oh), .data(raw_low), .out(carry_low));

endmodule

`default_nettype wire
