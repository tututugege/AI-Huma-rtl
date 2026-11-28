// Ref: front-end/front_top.cpp  InstPort::comb_read (line-straddle raw A/B merge, single expand+predecode, O(log N) prefix start scan, PTAB PC cut, rvc_head_fix)
`default_nettype none

// Instruction-queue head preparation before predecode_checker:
//   1) Line-straddle raw A/B merge (fused A + next line B when inst_e.is_pair, else intact Block A);
//   2) Single 16-lane RVC expand + predecode + 4-round O(log N) Kogge-Stone start_a/start_b prefix scan;
//   3) Parallel PTAB PC agreement cut (4-round prefix-OR) + log-depth valid count (ttg_first_set);
//   4) RVC=1 C910-style carry assembly, cross-page 2nd-halfword page-fault offset (+2), and straddler handling.
module front_head_fix import ttg_cfg_pkg::*; import front_pkg::*; (
  input  inst_fifo_entry_t        inst_e,
  input  logic [XLEN_BITS-1:0]    ptab_base_pc,
  input  logic [FETCH_WIDTH-1:0]  predict_dir,
  input  logic                    lh_valid,
  input  logic [XLEN_BITS-1:0]    lh_pc,
  input  logic [15:0]             lh_data,
  output logic [31:0]             insts_o      [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  valid_o,
  output logic [FETCH_WIDTH-1:0]  pf_o,
  output logic [FETCH_WIDTH-1:0]  pf_hi_o,
  output logic [1:0]              ptype_o      [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0]    ptarget_o    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  is_rvc_o,
  output logic [XLEN_BITS-1:0]    slot_pc_o    [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0]    ptab_pc_o    [FETCH_WIDTH],
  output logic                    carry,
  output logic                    straddle,
  output logic [15:0]             carry_low,
  output logic [XLEN_BITS-1:0]    group_end_pc,
  output logic [XLEN_BITS-1:0]    seq_next_o
);

  localparam logic [15:0] INST_NOP_LO = 16'h0013;
  localparam int          IC_OFF_W    = $clog2(ICACHE_LINE_SIZE);

  // ---- Step 1: Same-Page Line-Straddle 2-Fetch contiguous halfword assembly ----
  logic                   use_pair;
  logic [FETCH_WIDTH-1:0] s1_v, s1_pf;
  logic [XLEN_BITS-1:0]   s1_pc   [FETCH_WIDTH], ptab_pc [FETCH_WIDTH];
  logic [15:0]            s1_lo   [FETCH_WIDTH], s1_hi   [FETCH_WIDTH];

  assign use_pair = inst_e.is_pair;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      logic [3:0] j;
      j = 4'(i) - inst_e.a_len;
      if (use_pair && (4'(i) >= inst_e.a_len)) begin
        s1_v[i]  = inst_e.b_ok && ({1'b0, j} < inst_e.b_actual_n);
        s1_pf[i] = 1'b0;
        s1_pc[i] = inst_e.base_a + XLEN_BITS'(SLOT_BYTES * i);
        s1_lo[i] = s1_v[i] ? inst_e.raw_b[j] : INST_NOP_LO;
        s1_hi[i] = s1_v[i]
                   ? (({1'b0, j} + 5'd1 < inst_e.b_actual_n) ? inst_e.raw_b[j + 4'd1] : inst_e.up16_b)
                   : 16'h0000;
      end else begin
        s1_v[i]  = inst_e.valid_a[i];
        s1_pf[i] = inst_e.pf_a[i];
        s1_pc[i] = inst_e.base_a + XLEN_BITS'(SLOT_BYTES * i);
        s1_lo[i] = inst_e.raw_a[i];
        if (inst_e.pf_a[i] || !inst_e.valid_a[i]) begin
          s1_hi[i] = 16'h0000;
        end else if (use_pair && inst_e.b_ok && (inst_e.b_actual_n != 5'd0) && (4'(i) == inst_e.a_len - 4'd1)) begin
          // Stitch 32-bit instruction straddling the 64B cache-line boundary directly from Line L+1 slot 0!
          s1_hi[i] = inst_e.raw_b[0];
        end else begin
          s1_hi[i] = ((i + 1 < FETCH_WIDTH) && inst_e.valid_a[i + 1]) ? inst_e.raw_a[i + 1] : inst_e.up16_a;
        end
      end
      ptab_pc[i] = ptab_base_pc + XLEN_BITS'(SLOT_BYTES * i);
    end
  end

  // First invalid slot in s1_v -> s1_last_oh, s1_up16, s1_up_ok, s1_seq (O(log N))
  logic [FETCH_WIDTH-1:0] s1_inv_oh, s1_last_oh;
  logic                   s1_any_inv, s1_has_v, s1_up_ok;
  logic [15:0]            s1_up16;
  logic [XLEN_BITS-1:0]   s1_last_pc, s1_seq_raw, s1_seq;

  ttg_first_set #(.N(FETCH_WIDTH)) u_s1_inv (.req(~s1_v), .onehot(s1_inv_oh), .any(s1_any_inv));
  assign s1_last_oh = s1_any_inv ? {1'b0, s1_inv_oh[FETCH_WIDTH-1:1]} : {1'b1, {(FETCH_WIDTH-1){1'b0}}};
  assign s1_has_v   = s1_v[0];
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16))        u_s1_up16 (.sel(s1_last_oh), .data(s1_hi), .out(s1_up16));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_s1_lpc  (.sel(s1_last_oh), .data(s1_pc), .out(s1_last_pc));
  assign s1_up_ok   = s1_has_v && (!inst_e.single_word_a) &&
                      ((((s1_last_pc + XLEN_BITS'(SLOT_BYTES)) & XLEN_BITS'(ICACHE_LINE_SIZE - 1)) != '0) ||
                       (!use_pair && inst_e.b_ok));
  assign s1_seq_raw = s1_has_v ? (s1_last_pc + XLEN_BITS'(SLOT_BYTES)) : inst_e.base_a;
  assign s1_seq     = (!use_pair && (s1_seq_raw[XLEN_BITS-1:IC_OFF_W] != inst_e.base_a[XLEN_BITS-1:IC_OFF_W]))
                      ? {s1_seq_raw[XLEN_BITS-1:IC_OFF_W], {IC_OFF_W{1'b0}}}
                      : s1_seq_raw;

  // ---- Step 2: Single 16-lane RVC expand + predecode + 4-round O(log N) prefix start scan ----
  logic [31:0]            s1_win  [FETCH_WIDTH], s1_inst [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] s1_rvc, s1_sa, s1_sb;
  logic [1:0]             s1_ty   [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   s1_tgt  [FETCH_WIDTH];

  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_dec
    logic [31:0] ex;
    assign s1_win[i]  = s1_last_oh[i] ? {16'h0000, s1_lo[i]} : {s1_hi[i], s1_lo[i]};
    rvc_expand u_exp (.h(s1_lo[i]), .inst(ex));
    assign s1_rvc[i]  = (RVC_ENABLE != 0) && s1_v[i] && (s1_lo[i][1:0] != 2'b11);
    assign s1_inst[i] = s1_rvc[i] ? ex : s1_win[i];
    predecode_lane u_pd (
      .pc(s1_pc[i]), .inst(s1_inst[i]), .inst_valid(s1_v[i]),
      .predecode_type(s1_ty[i]), .predecode_target_address(s1_tgt[i])
    );
  end

  // 4-round Kogge-Stone prefix scan for start_a (no carry: lane 0 starts) / start_b (carry: lane 1 starts)
  logic [FETCH_WIDTH-1:0] s1_v_pre, ga_gen, gb_gen;
  always_comb begin
    // Leading valid prefix mask: bits strictly before first zero in s1_v
    logic [FETCH_WIDTH-1:0] z_pre;
    z_pre = ~s1_v;
    z_pre = z_pre | (z_pre << 1);
    z_pre = z_pre | (z_pre << 2);
    z_pre = z_pre | (z_pre << 4);
    z_pre = z_pre | (z_pre << 8);
    s1_v_pre = ~z_pre;

    ga_gen[0] = 1'b1;
    gb_gen[0] = 1'b0;
    for (int i = 1; i < FETCH_WIDTH; i++) begin
      ga_gen[i] = s1_rvc[i - 1];
      gb_gen[i] = (i == 1) ? 1'b1 : s1_rvc[i - 1];
    end
  end

  // Helper: nearest-left generator parity (Kogge-Stone parallel tree for synthesis, fast scan for simulation)
  function automatic logic [FETCH_WIDTH-1:0] scan_starts(input logic [FETCH_WIDTH-1:0] gen,
                                                         input logic [FETCH_WIDTH-1:0] vmask);
    logic [FETCH_WIDTH-1:0] out;
`ifdef SYNTHESIS
    logic [FETCH_WIDTH-1:0] h0, p0, h1, p1, h2, p2, h3, p3, h4, p4;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      h0[i] = gen[i];
      p0[i] = 1'(i & 1);
    end
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      h1[i] = (i >= 1) ? (h0[i] || h0[i - 1]) : h0[i];
      p1[i] = (i >= 1) ? (h0[i] ? p0[i] : p0[i - 1]) : p0[i];
    end
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      h2[i] = (i >= 2) ? (h1[i] || h1[i - 2]) : h1[i];
      p2[i] = (i >= 2) ? (h1[i] ? p1[i] : p1[i - 2]) : p1[i];
    end
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      h3[i] = (i >= 4) ? (h2[i] || h2[i - 4]) : h2[i];
      p3[i] = (i >= 4) ? (h2[i] ? p2[i] : p2[i - 4]) : p2[i];
    end
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      h4[i] = (i >= 8) ? (h3[i] || h3[i - 8]) : h3[i];
      p4[i] = (i >= 8) ? (h3[i] ? p3[i] : p3[i - 8]) : p3[i];
      out[i] = vmask[i] && h4[i] && (p4[i] == 1'(i & 1));
    end
`else
    logic cur_has, cur_par;
    cur_has = 1'b0;
    cur_par = 1'b0;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if (gen[i]) begin
        cur_has = 1'b1;
        cur_par = 1'(i & 1);
      end
      out[i] = vmask[i] && cur_has && (cur_par == 1'(i & 1));
    end
`endif
    return out;
  endfunction

  assign s1_sa = (RVC_ENABLE != 0) ? scan_starts(ga_gen, s1_v_pre) : '0;
  assign s1_sb = (RVC_ENABLE != 0) ? scan_starts(gb_gen, s1_v_pre) : '0;

  // ---- Step 3: Parallel PTAB PC agreement cut ----
  logic [FETCH_WIDTH-1:0] mm_raw, cut_mask, s2_v;
  logic [1:0]             s2_ty  [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   s2_tgt [FETCH_WIDTH];
  logic                   dropped;
  logic [FETCH_WIDTH-1:0] s2_inv_oh, s2_last_oh;
  logic                   s2_any_inv, s2_has_v;
  logic [3:0]             s2_inv_idx;
  logic [4:0]             rvc_n;
  logic [15:0]            s2_cut_up16, s2_up16;
  logic                   s2_up_ok;
  logic [XLEN_BITS-1:0]   s2_last_pc, s2_seq;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++)
      mm_raw[i] = s1_v[i] && (s1_pc[i] != ptab_pc[i]);
    cut_mask = mm_raw;
    cut_mask = cut_mask | (cut_mask << 1);
    cut_mask = cut_mask | (cut_mask << 2);
    cut_mask = cut_mask | (cut_mask << 4);
    cut_mask = cut_mask | (cut_mask << 8);
    dropped  = |(s1_v & cut_mask);
    s2_v     = s1_v & ~cut_mask;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      s2_ty[i]  = cut_mask[i] ? PREDECODE_NON_BRANCH : s1_ty[i];
      s2_tgt[i] = cut_mask[i] ? '0                   : s1_tgt[i];
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_s2_inv (.req(~s2_v), .onehot(s2_inv_oh), .any(s2_any_inv));
  ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_s2_inv_idx (.onehot(s2_inv_oh), .idx(s2_inv_idx));
  assign rvc_n      = s2_any_inv ? {1'b0, s2_inv_idx} : 5'(FETCH_WIDTH);
  assign s2_last_oh = s2_any_inv ? {1'b0, s2_inv_oh[FETCH_WIDTH-1:1]} : {1'b1, {(FETCH_WIDTH-1){1'b0}}};
  assign s2_has_v   = s2_v[0];

  logic [15:0] s1_inst_hi [FETCH_WIDTH];
  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_s1_hi
    assign s1_inst_hi[i] = s1_inst[i][31:16];
  end
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16))        u_s2_up16 (.sel(s2_last_oh), .data(s1_inst_hi), .out(s2_cut_up16));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_s2_lpc  (.sel(s2_last_oh), .data(s1_pc),      .out(s2_last_pc));

  assign s2_seq   = (dropped && s2_has_v) ? (s2_last_pc + XLEN_BITS'(SLOT_BYTES)) : s1_seq;
  assign s2_up16  = (dropped && s2_has_v) ? s2_cut_up16 : s1_up16;
  assign s2_up_ok = (dropped && s2_has_v) ? 1'b1        : s1_up_ok;
  assign pf_o     = s1_pf;

  // ---- Step 4: RVC=1 carry assembly + instruction-start filter + straddler ----
  logic [XLEN_BITS-1:0]   asm_pc, comp_pc;
  logic [31:0]            asm_word, comp_word;
  logic [1:0]             asm_type, comp_type;
  logic [XLEN_BITS-1:0]   asm_tgt, comp_tgt;
  logic [FETCH_WIDTH-1:0] chain, straddle_raw_oh, complete_oh, straddle_oh, keep;
  logic [15:0]            raw_low [FETCH_WIDTH];
  logic [15:0]            comp_low;

  assign carry    = (RVC_ENABLE != 0) && lh_valid && (lh_pc == s1_pc[0]) && s2_v[0];
  assign asm_pc   = s1_pc[0] - XLEN_BITS'(SLOT_BYTES);
  assign asm_word = {inst_e.raw_a[0], lh_data};

  predecode_lane u_asm (
    .pc(asm_pc), .inst(asm_word), .inst_valid(1'b1),
    .predecode_type(asm_type), .predecode_target_address(asm_tgt)
  );

  always_comb begin
    chain = carry ? s1_sb : s1_sa;
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      straddle_raw_oh[i] = (RVC_ENABLE != 0) && s2_last_oh[i] && s2_has_v && chain[i] && !s1_rvc[i] && !s1_pf[i];
      complete_oh[i]     = straddle_raw_oh[i] && predict_dir[i] && s2_up_ok;
      straddle_oh[i]     = straddle_raw_oh[i] && !complete_oh[i];
      raw_low[i]         = s1_inst[i][15:0];
      keep[i]            = (RVC_ENABLE != 0) ? (s2_v[i] && (chain[i] || (carry && (i == 0)))) : s2_v[i];
      valid_o[i]         = keep[i] && !straddle_oh[i];
      slot_pc_o[i]       = (i == 0 && carry) ? asm_pc : s1_pc[i];
      ptab_pc_o[i]       = (i == 0 && carry) ? asm_pc : ptab_pc[i];
    end
  end

  // Select straddler candidate directly from s2_last_oh & s1_lo (100% parallel with scan_starts/chain and complete_oh!)
  // Proof: complete_oh[i] => s2_last_oh[i] && !s1_rvc[i] && !(i==0 && carry), so comp_pc === s2_last_pc and comp_low === s1_lo[last].
  assign comp_pc = s2_last_pc;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_comp_low (.sel(s2_last_oh), .data(s1_lo), .out(comp_low));
  assign comp_word = {s2_up16, comp_low};

  predecode_lane u_comp (
    .pc(comp_pc), .inst(comp_word), .inst_valid(1'b1),
    .predecode_type(comp_type), .predecode_target_address(comp_tgt)
  );

  logic [XLEN_BITS-1:0] last_slot_pc;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_end_pc (.sel(s2_last_oh), .data(slot_pc_o), .out(last_slot_pc));

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
      // Explicit 1-bit flag for cross-page 2nd-halfword instruction page-fault (+2 in ROB stval)
      pf_hi_o[i] = s1_pf[i] && (i == 0) && carry;
      if (s1_pf[i]) insts_o[i] = 32'h00000013;
    end
    group_end_pc = (rvc_n != 5'd0) ? (last_slot_pc + XLEN_BITS'(SLOT_BYTES)) : slot_pc_o[0];
  end

  assign straddle   = |straddle_oh;
  assign seq_next_o = (|complete_oh) ? (comp_pc + XLEN_BITS'(4)) : s2_seq;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_carry_low (.sel(straddle_oh), .data(raw_low), .out(carry_low));

  logic unused_hf;
  assign unused_hf = s1_inv_oh[0];

endmodule

`default_nettype wire
