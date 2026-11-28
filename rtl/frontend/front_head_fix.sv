// Ref: front-end/front_top.cpp  InstPort::comb_read (single expand+predecode, O(log N) prefix start scan,
// FTQ PD PC cut, rvc_head_fix)
`default_nettype none

// Instruction-queue head preparation before predecode_checker (the A/B line-straddle merge is done before the queue,
// in front_fetch_buf; the entry is one halfword window with a prefix of valid slots):
//   1) 32-bit window per slot ({next slot, slot}; {0, slot} on the last valid slot), sequential pc;
//   2) Single 16-lane RVC expand + branch decode + 4-round O(log N) Kogge-Stone start_a/start_b prefix scan;
//   3) Parallel FTQ PD PC agreement cut (4-round prefix-OR) + log-depth valid count (ttg_first_set);
//   4) RVC=1 C910-style carry assembly, cross-page 2nd-halfword page-fault offset (+2), and straddler handling.
module front_head_fix import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; (
  input  inst_fifo_entry_t        inst_e,
  input  logic [XLEN_BITS-1:0]    pd_base_pc,
  input  logic [FETCH_WIDTH-1:0]  predict_dir,
  input  logic                    lh_valid,
  input  logic [XLEN_BITS-1:0]    lh_pc,
  input  logic [15:0]             lh_data,
  output logic [31:0]             insts_o      [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  valid_o,
  output logic [FETCH_WIDTH-1:0]  pf_o,
  output logic [FETCH_WIDTH-1:0]  pf_hi_o,
  output logic [1:0]              ptype_o      [FETCH_WIDTH],   // 0 (non-branch) on an invalid slot
  output logic [KIND_W-1:0]       kind_o       [FETCH_WIDTH],   // BR_* of insts_o (every slot; the FTQ slot kind)
  output logic [XLEN_BITS-1:0]    ptarget_o    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  is_rvc_o,
  output logic [XLEN_BITS-1:0]    slot_pc_o    [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0]    pd_pc_o      [FETCH_WIDTH],
  output logic                    carry,
  output logic                    straddle,
  output logic [15:0]             carry_low,
  output logic [XLEN_BITS-1:0]    group_end_pc,
  output logic [XLEN_BITS-1:0]    seq_next_o
);

  localparam int          IC_OFF_W    = $clog2(ICACHE_LINE_SIZE);

  // ---- Step 1: slot windows from the merged halfword window ----
  logic                   use_straddle;
  logic [FETCH_WIDTH-1:0] s1_v, s1_pf;
  logic [XLEN_BITS-1:0]   s1_pc   [FETCH_WIDTH], pd_pc [FETCH_WIDTH];
  logic [15:0]            s1_lo   [FETCH_WIDTH];

  assign use_straddle = inst_e.is_straddle;
  assign s1_v         = inst_e.valid;
  assign s1_pf        = inst_e.pf;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      s1_lo[i] = inst_e.half[i];
      s1_pc[i] = inst_e.base + XLEN_BITS'(SLOT_BYTES * i);
      pd_pc[i] = pd_base_pc + XLEN_BITS'(SLOT_BYTES * i);
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
  assign s1_up16    = inst_e.up16;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_s1_lpc  (.sel(s1_last_oh), .data(s1_pc), .out(s1_last_pc));
  assign s1_up_ok   = s1_has_v && (!inst_e.single_word) &&
                      ((((s1_last_pc + XLEN_BITS'(SLOT_BYTES)) & XLEN_BITS'(ICACHE_LINE_SIZE - 1)) != '0) ||
                       inst_e.tail_ok);
  assign s1_seq_raw = s1_has_v ? (s1_last_pc + XLEN_BITS'(SLOT_BYTES)) : inst_e.base;
  assign s1_seq     = (!use_straddle && (s1_seq_raw[XLEN_BITS-1:IC_OFF_W] != inst_e.base[XLEN_BITS-1:IC_OFF_W]))
                      ? {s1_seq_raw[XLEN_BITS-1:IC_OFF_W], {IC_OFF_W{1'b0}}}
                      : s1_seq_raw;

  // ---- Step 2: Single 16-lane RVC expand + branch decode + 4-round O(log N) prefix start scan ----
  logic [31:0]            s1_win  [FETCH_WIDTH], s1_inst [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] s1_rvc, s1_sa, s1_sb;
  logic [KIND_W-1:0]      s1_kind [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   s1_tgt  [FETCH_WIDTH];

  // the window of slot i takes slot i+1 as its upper half while slot i+1 is valid (valid is a prefix, so this is every
  // valid slot but the last).  A faulting group holds NOP low halves, so its windows decode as non-branch either way.
  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_dec
    logic [31:0] ex;
    if (i + 1 < FETCH_WIDTH) begin : g_mid
      assign s1_win[i] = s1_v[i + 1] ? {s1_lo[i + 1], s1_lo[i]} : {16'h0000, s1_lo[i]};
    end else begin : g_end
      assign s1_win[i] = {16'h0000, s1_lo[i]};
    end
    rvc_expand u_exp (.h(s1_lo[i]), .inst(ex));
    assign s1_rvc[i]  = (RVC_ENABLE != 0) && s1_v[i] && (s1_lo[i][1:0] != 2'b11);
    assign s1_inst[i] = s1_rvc[i] ? ex : s1_win[i];
    predecode_lane u_pd (.pc(s1_pc[i]), .inst(s1_inst[i]), .kind(s1_kind[i]), .target(s1_tgt[i]));
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

  // ---- Step 3: Parallel FTQ PD PC agreement cut ----
  logic [FETCH_WIDTH-1:0] mm_raw, cut_mask, s2_v;
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
      mm_raw[i] = s1_v[i] && (s1_pc[i] != pd_pc[i]);
    cut_mask = mm_raw;
    cut_mask = cut_mask | (cut_mask << 1);
    cut_mask = cut_mask | (cut_mask << 2);
    cut_mask = cut_mask | (cut_mask << 4);
    cut_mask = cut_mask | (cut_mask << 8);
    dropped  = |(s1_v & cut_mask);
    s2_v     = s1_v & ~cut_mask;
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
  logic [KIND_W-1:0]      asm_kind, comp_kind;
  logic [XLEN_BITS-1:0]   asm_tgt, comp_tgt;
  logic [FETCH_WIDTH-1:0] chain, straddle_raw_oh, complete_oh, straddle_oh, keep;
  logic [15:0]            raw_low [FETCH_WIDTH];
  logic [15:0]            comp_low;

  assign carry    = (RVC_ENABLE != 0) && lh_valid && (lh_pc == s1_pc[0]) && s2_v[0];
  assign asm_pc   = s1_pc[0] - XLEN_BITS'(SLOT_BYTES);
  assign asm_word = {s1_lo[0], lh_data};   // carry => slot 0 valid => slot 0 is a Block A slot (a_len >= 1)

  predecode_lane u_asm (.pc(asm_pc), .inst(asm_word), .kind(asm_kind), .target(asm_tgt));

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
      pd_pc_o[i]         = (i == 0 && carry) ? asm_pc : pd_pc[i];
    end
  end

  // Select straddler candidate directly from s2_last_oh & s1_lo (100% parallel with scan_starts/chain and complete_oh!)
  // Proof: complete_oh[i] => s2_last_oh[i] && !s1_rvc[i] && !(i==0 && carry), so comp_pc === s2_last_pc and
  // comp_low === s1_lo[last].
  assign comp_pc = s2_last_pc;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_comp_low (.sel(s2_last_oh), .data(s1_lo), .out(comp_low));
  assign comp_word = {s2_up16, comp_low};

  predecode_lane u_comp (.pc(comp_pc), .inst(comp_word), .kind(comp_kind), .target(comp_tgt));

  logic [XLEN_BITS-1:0] last_slot_pc;
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_end_pc (.sel(s2_last_oh), .data(slot_pc_o), .out(last_slot_pc));

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      logic [KIND_W-1:0]    k;
      logic [XLEN_BITS-1:0] t;
      if (i == 0 && carry) begin
        insts_o[i]  = asm_word;
        is_rvc_o[i] = 1'b0;
        k           = asm_kind;
        t           = asm_tgt;
      end else if (complete_oh[i]) begin
        insts_o[i]  = comp_word;
        is_rvc_o[i] = 1'b0;
        k           = comp_kind;
        t           = comp_tgt;
      end else begin
        insts_o[i]  = s1_inst[i];
        is_rvc_o[i] = (RVC_ENABLE != 0) && s1_rvc[i];
        k           = s1_kind[i];
        t           = s1_tgt[i];
      end
      // the checker sees the decode of the assembled word even on a fault (valid_o => !cut); the FTQ kind is the NOP's
      ptype_o[i]   = valid_o[i] ? ptype_of_kind(k) : PREDECODE_NON_BRANCH;
      ptarget_o[i] = valid_o[i] ? t : '0;
      kind_o[i]    = s1_pf[i] ? BR_NONCTL : k;
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
