// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::comb (speculative history / RAS command and next pc)
`default_nettype none

// What the cycle does to the speculative history / RAS and the pc register (bpu_spec command encoding: 0 hold,
// 1 push on the current state, 2 load a checkpoint then push, 3 load the architectural copy then push).
//   refetch, predecode flush with record   checkpoint of the checked block, then the corrected block's symbol / RAS op
//   refetch, back-end mispredict           FTQ checkpoint (history) / committed RAS, then the branch's own outcome
//   refetch, otherwise                     committed history and RAS
//   S2 override, S1 (L1) override          checkpoint of the block, then the new guess / final prediction
//   S0 issue                               push the S0 guess
// With FE_RFAST bit0 / FE_BFAST (FAST) the S0 push is a second step (h2_* / r2_*) on the state the first command
// leaves, and pc1 / the first command are what S0 looks up in the same cycle.
module bpu_cmd import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic        refetch,
  input  logic        pd_restore,
  input  logic        rep_ok,
  input  logic        ovr,
  input  logic        l1_ov,
  input  logic        issue,
  input  logic        s0_go,
  input  logic [31:0] pc,
  input  logic [31:0] refetch_address,
  /* verilator lint_off UNUSEDSIGNAL */   // block / guess structs: only some fields are used here
  input  pred_t       g0,
  input  pred_t       g1,
  input  pred_t       fin,
  input  blk_t        r0,
  input  blk_t        r1,
  /* verilator lint_on UNUSEDSIGNAL */
  input  ck_t         pd_ck,
  input  logic        pd_hv,              // the corrected block pushes a history symbol
  input  logic [HSYM_W-1:0] pd_hbits,
  input  logic [1:0]  pd_ras_op,
  input  logic [31:0] pd_ras_val,
  input  hist_ck_t    rf_ck,
  input  logic [2:0]  rf_type,
  input  logic [31:0] rf_pc,
  output logic [1:0]  h_mode,
  output hist_ck_t    h_ck,
  output logic        h_push_en,
  output logic [HSYM_W-1:0] h_push_bits,
  output logic [1:0]  r_mode,
  output ras_ck_t     r_ck,
  output logic [1:0]  r_op,
  output logic [31:0] r_val,
  output logic [31:0] pc1,                // pc after the first command (what S0 looks up in the FAST configuration)
  output logic        h2_en,              // S0 push after the first command (FAST)
  output logic [HSYM_W-1:0] h2_bits,
  output logic [1:0]  r2_op,
  output logic [31:0] r2_val,
  output logic [31:0] pc_d
);

  localparam bit FAST = (FE_RFAST & 1) != 0 || FE_BFAST != 0;

  localparam logic [1:0] M_HOLD = 2'd0;
  localparam logic [1:0] M_PUSH = 2'd1;
  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  logic rf_taken;

  always_comb begin
    rf_taken = (rf_type == BR_DIRECT) ? (refetch_address != rf_pc + 32'd4) : 1'b1;
  end

  // Ref: comb: history command
  always_comb begin
    h_mode = M_HOLD; h_ck = r1.ck.h; h_push_en = 1'b0; h_push_bits = '0;
    if (refetch) begin
      h_mode = M_ARCH;
      if (pd_restore) begin
        h_mode = M_CK; h_ck = pd_ck.h; h_push_en = pd_hv; h_push_bits = pd_hbits;
      end else if (rep_ok) begin
        h_mode = M_CK; h_ck = rf_ck; h_push_en = rf_taken; h_push_bits = hsym_of(rf_pc, refetch_address);
      end
    end else if (ovr) begin
      h_mode = M_CK; h_ck = r1.ck.h; h_push_en = fin.taken; h_push_bits = fin.hbits;
    end else if (l1_ov) begin
      h_mode = M_CK; h_ck = r0.ck.h; h_push_en = g1.taken; h_push_bits = g1.hbits;
    end else if (issue && !FAST) begin
      h_mode = M_PUSH; h_push_en = g0.taken; h_push_bits = g0.hbits;
    end
  end

  // Ref: comb: RAS command
  always_comb begin
    r_mode = M_HOLD; r_ck = r1.ck.r; r_op = 2'd0; r_val = '0;
    if (refetch) begin
      r_mode = M_ARCH;
      if (pd_restore) begin
        r_mode = M_CK; r_ck = pd_ck.r; r_op = pd_ras_op; r_val = pd_ras_val;
      end else if (rep_ok) begin
        r_op  = (rf_type == BR_CALL || rf_type == BR_ICALL) ? 2'd1 : (rf_type == BR_RET) ? 2'd2 : 2'd0;
        r_val = rf_pc + 32'd4;
      end
    end else if (ovr) begin
      r_mode = M_CK; r_ck = r1.ck.r; r_op = fin.ras_op; r_val = fin.ras_val;
    end else if (l1_ov) begin
      r_mode = M_CK; r_ck = r0.ck.r; r_op = g1.ras_op; r_val = g1.ras_val;
    end else if (issue && !FAST) begin
      r_mode = M_PUSH; r_op = g0.ras_op; r_val = g0.ras_val;
    end
  end

  // Ref: FE_RFAST bit0 / FE_BFAST: S0 push on the state the first command leaves (n.spec after restore, then s0_issue)
  always_comb begin
    h2_en   = FAST && s0_go && g0.taken;
    h2_bits = g0.hbits;
    r2_op   = (FAST && s0_go) ? g0.ras_op : 2'd0;
    r2_val  = g0.ras_val;
  end

  // Ref: comb: pc register
  always_comb begin
    pc1 = pc;
    if (refetch)      pc1 = refetch_address;
    else if (ovr)     pc1 = fin.next;
    else if (l1_ov)   pc1 = g1.next;
    pc_d = pc1;
    if (FAST ? s0_go : issue) pc_d = g0.next;
  end

endmodule

`default_nettype wire
