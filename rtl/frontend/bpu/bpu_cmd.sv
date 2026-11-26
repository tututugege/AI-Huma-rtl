// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::comb (speculative history / RAS command and next pc, 2-taken)
`default_nettype none

module bpu_cmd import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic        refetch,
  input  logic        pd_restore,
  input  logic        rep_ok,
  input  logic        ovr,
  input  logic        ovr_a,
  input  logic        d_pair,
  input  logic        l1_ov,
  input  logic        issue,
  input  logic        s0_go,
  input  logic        s0_paired,
  input  logic [XLEN_BITS-1:0] pc,
  input  logic [XLEN_BITS-1:0] s0_base,
  input  logic [XLEN_BITS-1:0] s0_b_base,
  input  logic [XLEN_BITS-1:0] refetch_address,
  /* verilator lint_off UNUSEDSIGNAL */
  input  pred_t       g0,
  input  pred_t       g0_b,
  input  pred_t       g1,
  input  pred_t       fin,
  input  pred_t       fin_b,
  input  blk_t        r0,
  input  blk_t        r1,
  /* verilator lint_on UNUSEDSIGNAL */
  input  ck_t         pd_ck,
  input  logic [1:0]  pd_hn,              // 0..2 history symbols of corrected block(s)
  input  logic [5:0]  pd_hbits,           // {sym2, sym1}
  input  logic [1:0]  pd_ras_op,
  input  logic [XLEN_BITS-1:0] pd_ras_val,
  input  logic [1:0]  pd_ras_op2,
  input  logic [XLEN_BITS-1:0] pd_ras_val2,
  input  ck_t         rf_ck_rec,          // checkpoint from internal rec_q[256]
  input  logic [2:0]  rf_type,
  input  logic [XLEN_BITS-1:0] rf_pc,
  input  logic        rf_is_rvc,
  output logic [1:0]  h_mode,
  output hist_ck_t    h_ck,
  output logic [1:0]  h_push_n,
  output logic [5:0]  h_push_bits,
  output logic [1:0]  r_mode,
  output ras_ck_t     r_ck,
  output logic [1:0]  r_op,
  output logic [XLEN_BITS-1:0] r_val,
  output logic [1:0]  r_op2,
  output logic [XLEN_BITS-1:0] r_val2,
  output logic [XLEN_BITS-1:0] pc1,
  // S0 Block A push (used on refetch / BFANY after step 1)
  output logic        h2_en,
  output logic [HSYM_W-1:0] h2_bits,
  output logic [1:0]  r2_op,
  output logic [XLEN_BITS-1:0] r2_val,
  // S0 Block B push (applied after Block A whenever s0_go && s0_paired)
  output logic        h3_en,
  output logic [HSYM_W-1:0] h3_bits,
  output logic [1:0]  r3_op,
  output logic [XLEN_BITS-1:0] r3_val,
  output logic [XLEN_BITS-1:0] pc_d,
  // refetch-only copy of the command (REFONLY)
  output logic [1:0]  hr_mode,
  output hist_ck_t    hr_ck,
  output logic [1:0]  hr_push_n,
  output logic [5:0]  hr_push_bits,
  output logic [1:0]  rr_mode,
  output ras_ck_t     rr_ck,
  output logic [1:0]  rr_op,
  output logic [XLEN_BITS-1:0] rr_val,
  output logic [1:0]  rr_op2,
  output logic [XLEN_BITS-1:0] rr_val2,
  // IMLI 2-bit ops (0=hold, 1=inc_sat, 2=zero) & checkpoint values
  output logic [1:0]  i1_op,
  output logic [7:0]  i_ck,
  output logic [1:0]  i2_op,
  output logic [1:0]  i3_op,
  output logic [1:0]  ir1_op,
  output logic [7:0]  ir_ck,
  output logic [1:0]  g0_i_op
);

  localparam logic [1:0] M_HOLD = 2'd0;
  localparam logic [1:0] M_PUSH = 2'd1;
  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  logic                 rf_taken;
  ck_t                  o_ck;
  /* verilator lint_off UNUSEDSIGNAL */
  pred_t                o_out;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [XLEN_BITS-1:0] s0_next, d_obase;

  always_comb begin
    rf_taken = (rf_type == BR_DIRECT) ? (refetch_address != rf_pc + (rf_is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4))) : 1'b1;
    o_ck     = (ovr_a || !d_pair) ? r1.ck   : r1.ck_b;
    o_out    = (ovr_a || !d_pair) ? fin     : fin_b;
    d_obase  = (ovr_a || !d_pair) ? r1.base : r1.base_b;
  end

  always_comb begin
    s0_next  = s0_paired ? g0_b.next : g0.next;
  end

  // Ref: comb: history command
  always_comb begin
    h_mode = M_HOLD; h_ck = o_ck.h; h_push_n = 2'd0; h_push_bits = '0;
    if (refetch) begin
      h_mode = M_ARCH;
      if (pd_restore) begin
        h_mode = M_CK; h_ck = pd_ck.h; h_push_n = pd_hn; h_push_bits = pd_hbits;
      end else if (rep_ok) begin
        h_mode = M_CK; h_ck = rf_ck_rec.h; h_push_n = rf_taken ? 2'd1 : 2'd0;
        h_push_bits = {3'd0, hsym_of(rf_pc, refetch_address)};
      end
    end else if (ovr) begin
      h_mode = M_CK; h_ck = o_ck.h; h_push_n = o_out.taken ? 2'd1 : 2'd0; h_push_bits = {3'd0, o_out.hbits};
    end else if (l1_ov) begin
      h_mode = M_CK; h_ck = r0.ck.h; h_push_n = g1.taken ? 2'd1 : 2'd0; h_push_bits = {3'd0, g1.hbits};
    end else if (issue) begin
      h_mode = M_PUSH; h_push_n = g0.taken ? 2'd1 : 2'd0; h_push_bits = {3'd0, g0.hbits};
    end
  end

  // Ref: comb: RAS command
  always_comb begin
    r_mode = M_HOLD; r_ck = o_ck.r; r_op = 2'd0; r_val = '0; r_op2 = 2'd0; r_val2 = '0;
    if (refetch) begin
      r_mode = M_ARCH;
      if (pd_restore) begin
        r_mode = M_CK; r_ck = pd_ck.r; r_op = pd_ras_op; r_val = pd_ras_val;
        r_op2 = pd_ras_op2; r_val2 = pd_ras_val2;
      end else if (rep_ok) begin
        r_mode = M_CK; r_ck = rf_ck_rec.r;
        r_op   = (rf_type == BR_CALL || rf_type == BR_ICALL) ? 2'd1 : (rf_type == BR_RET) ? 2'd2 : 2'd0;
        r_val  = rf_pc + (rf_is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
      end
    end else if (ovr) begin
      r_mode = M_CK; r_ck = o_ck.r; r_op = o_out.ras_op; r_val = o_out.ras_val;
    end else if (l1_ov) begin
      r_mode = M_CK; r_ck = r0.ck.r; r_op = g1.ras_op; r_val = g1.ras_val;
    end else if (issue) begin
      r_mode = M_PUSH; r_op = g0.ras_op; r_val = g0.ras_val;
    end
  end

  // S0 Block A push (after refetch command)
  always_comb begin
    h2_en   = refetch && s0_go && g0.taken;
    h2_bits = g0.hbits;
    r2_op   = (refetch && s0_go) ? g0.ras_op : 2'd0;
    r2_val  = g0.ras_val;
  end

  // S0 Block B push (after Block A when paired)
  always_comb begin
    h3_en   = s0_go && s0_paired && g0_b.taken;
    h3_bits = g0_b.hbits;
    r3_op   = (s0_go && s0_paired) ? g0_b.ras_op : 2'd0;
    r3_val  = g0_b.ras_val;
  end

  // Ref: comb: pc1 (before S0 A/B) and pc_d (after S0 A/B)
  always_comb begin
    pc1 = refetch ? refetch_address : pc;
  end

  always_comb begin
    if (refetch)    pc_d = s0_go ? s0_next : refetch_address;
    else if (issue) pc_d = s0_next;
    else if (ovr)   pc_d = o_out.next;
    else if (l1_ov) pc_d = g1.next;
    else            pc_d = pc;
  end

  // refetch-only command (no dependence on S2 / S1 decisions)
  always_comb begin
    hr_mode = M_ARCH; hr_ck = o_ck.h; hr_push_n = 2'd0; hr_push_bits = '0;
    rr_mode = M_ARCH; rr_ck = o_ck.r; rr_op = 2'd0; rr_val = '0; rr_op2 = 2'd0; rr_val2 = '0;
    if (pd_restore) begin
      hr_mode = M_CK; hr_ck = pd_ck.h; hr_push_n = pd_hn; hr_push_bits = pd_hbits;
      rr_mode = M_CK; rr_ck = pd_ck.r; rr_op = pd_ras_op; rr_val = pd_ras_val;
      rr_op2 = pd_ras_op2; rr_val2 = pd_ras_val2;
    end else if (rep_ok) begin
      hr_mode = M_CK; hr_ck = rf_ck_rec.h; hr_push_n = rf_taken ? 2'd1 : 2'd0;
      hr_push_bits = {3'd0, hsym_of(rf_pc, refetch_address)};
      rr_mode = M_CK; rr_ck = rf_ck_rec.r;
      rr_op   = (rf_type == BR_CALL || rf_type == BR_ICALL) ? 2'd1 : (rf_type == BR_RET) ? 2'd2 : 2'd0;
      rr_val  = rf_pc + (rf_is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
    end
  end

  // IMLI commands (matching BPU_pipe.h upd_imli sites)
  always_comb begin
    g0_i_op = imli_op_of(g0.ty, g0.taken, s0_base, g0.next, 1'b0);
    i_ck    = o_ck.imli;
    i1_op   = 2'd0;
    if (refetch) begin
      if (pd_restore) begin
        i_ck  = pd_ck.imli;
        i1_op = 2'd0;
      end else if (rep_ok) begin
        i_ck  = rf_ck_rec.imli;
        i1_op = imli_op_of(rf_type, rf_taken, rf_pc, refetch_address, 1'b1);
      end
    end else if (ovr) begin
      i_ck  = o_ck.imli;
      i1_op = imli_op_of(o_out.ty, o_out.taken, d_obase, o_out.next, 1'b0);
    end else if (l1_ov) begin
      i_ck  = r0.ck.imli;
      i1_op = imli_op_of(g1.ty, g1.taken, r0.base, g1.next, 1'b0);
    end else if (issue) begin
      i1_op = g0_i_op;
    end

    ir_ck  = o_ck.imli;
    ir1_op = 2'd0;
    if (pd_restore) begin
      ir_ck  = pd_ck.imli;
      ir1_op = 2'd0;
    end else if (rep_ok) begin
      ir_ck  = rf_ck_rec.imli;
      ir1_op = imli_op_of(rf_type, rf_taken, rf_pc, refetch_address, 1'b1);
    end

    i2_op = (refetch && s0_go) ? g0_i_op : 2'd0;
    i3_op = (s0_go && s0_paired) ? imli_op_of(g0_b.ty, g0_b.taken, s0_b_base, g0_b.next, 1'b0) : 2'd0;
  end

endmodule

`default_nettype wire
