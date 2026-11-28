// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::comb (Single-Set 2-Ahead history/RAS/PC command)
`default_nettype none

module bpu_cmd import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                 refetch,
  input  logic                 pd_restore,
  input  logic                 rep_ok,
  input  logic                 ovr,
  input  ck_t                  r1_ck,
  input  logic                 issue,
  input  logic [XLEN_BITS-1:0] pc,
  input  logic [XLEN_BITS-1:0] refetch_address,
  /* verilator lint_off UNUSEDSIGNAL */
  input  pred_t                g0,
  input  pred_t                fin,
  /* verilator lint_on UNUSEDSIGNAL */
  input  ck_t                  pd_ck,
  input  logic                 pd_hn,
  input  logic [HSYM_W-1:0]    pd_hbits,
  input  logic [1:0]           pd_ras_op,
  input  logic [XLEN_BITS-1:0] pd_ras_val,
  input  ck_t                  rf_ck_rec,
  input  logic [2:0]           rf_type,
  input  logic [XLEN_BITS-1:0] rf_pc,
  input  logic                 rf_is_rvc,
  // !refetch && !issue restore command (direct S2 override: r1 checkpoint + the corrected fin prediction)
  output logic [1:0]           h_mode,
  output hist_ck_t             h_ck,
  output logic                 h_push_en,
  output logic [HSYM_W-1:0]    h_push_bits,
  output logic [1:0]           r_mode,
  output ras_ck_t              r_ck,
  output logic [1:0]           r_op,
  output logic [XLEN_BITS-1:0] r_val,
  output logic [XLEN_BITS-1:0] pc_d,
  // refetch-only restore command
  output logic [1:0]           hr_mode,
  output hist_ck_t             hr_ck,
  output logic                 hr_push_n,
  output logic [HSYM_W-1:0]    hr_push_bits,
  output logic [1:0]           rr_mode,
  output ras_ck_t              rr_ck,
  output logic [1:0]           rr_op,
  output logic [XLEN_BITS-1:0] rr_val
);

  localparam logic [1:0] M_HOLD = 2'd0;
  localparam logic [1:0] M_CK   = 2'd2;
  localparam logic [1:0] M_ARCH = 2'd3;

  logic                 rf_taken;
  logic [XLEN_BITS-1:0] rf_pc_next;

  always_comb begin
    rf_pc_next = rf_pc + (rf_is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
    rf_taken   = (rf_type == BR_DIRECT) ? (refetch_address != rf_pc_next) : 1'b1;
  end

  always_comb begin
    h_mode      = ovr ? M_CK : M_HOLD;
    h_ck        = r1_ck.h;
    h_push_en   = ovr && fin.taken;
    h_push_bits = fin.hbits;

    r_mode      = ovr ? M_CK : M_HOLD;
    r_ck        = r1_ck.r;
    r_op        = ovr ? fin.ras_op : 2'd0;
    r_val       = fin.ras_val;
  end

  always_comb begin
    if (refetch)    pc_d = refetch_address;
    else if (ovr)   pc_d = fin.next;
    else if (issue) pc_d = g0.next;
    else            pc_d = pc;
  end

  always_comb begin
    hr_mode = M_ARCH; hr_ck = pd_ck.h; hr_push_n = 1'b0; hr_push_bits = '0;
    rr_mode = M_ARCH; rr_ck = pd_ck.r; rr_op = 2'd0; rr_val = '0;
    if (pd_restore) begin
      hr_mode = M_CK; hr_ck = pd_ck.h; hr_push_n = pd_hn; hr_push_bits = pd_hbits;
      rr_mode = M_CK; rr_ck = pd_ck.r; rr_op = pd_ras_op; rr_val = pd_ras_val;
    end else if (rep_ok) begin
      hr_mode = M_CK; hr_ck = rf_ck_rec.h; hr_push_n = rf_taken;
      hr_push_bits = hsym_of(rf_pc, refetch_address);
      rr_mode = M_CK; rr_ck = rf_ck_rec.r;
      rr_op   = (rf_type == BR_CALL || rf_type == BR_ICALL) ? 2'd1 : (rf_type == BR_RET) ? 2'd2 : 2'd0;
      rr_val  = rf_pc_next;
    end
  end

endmodule
`default_nettype wire
