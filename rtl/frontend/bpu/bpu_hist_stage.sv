// Ref: front-end/BPU/BPU.h  BPU_TOP::bpu_hist_comb (one lane of a history chain)
`default_nettype none

// One lane of a history chain: apply the history step when `en`, otherwise pass the state through.
module bpu_hist_stage import bpu_pkg::*; (
  input  logic               en,
  input  logic               new_hist,
  input  logic [GHR_W-1:0]   ghr_in,
  input  logic [FH_FLAT-1:0] fh_in,
  output logic [GHR_W-1:0]   ghr_out,
  output logic [FH_FLAT-1:0] fh_out
);

  logic [GHR_W-1:0]   step_ghr;
  logic [FH_FLAT-1:0] step_fh;

  bpu_hist_step u_step (.ghr_in(ghr_in), .fh_in(fh_in), .new_hist(new_hist), .ghr_out(step_ghr), .fh_out(step_fh));

  assign ghr_out = en ? step_ghr : ghr_in;
  assign fh_out  = en ? step_fh : fh_in;

endmodule

`default_nettype wire
