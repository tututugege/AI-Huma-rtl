// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_lsu2dcache_stq_p: drain through the write buffer, MMIO)
`default_nettype none

// Committed-store drain of the staged LSU (EXP-024): the committed stores go through the write buffer (lp_wbuf), which
// groups up to two stores of one cache line into one DCache request.  The head store, when it is MMIO, takes the
// uncached unit.
module lp_drain
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  lp_stq_t             sq [SQ],
  input  logic [SQ-1:0]       d_rdy,
  input  logic [SQ-1:0]       d_elig,
  input  logic [SQ-1:0]       wbi_v,
  input  logic [SQW-1:0]      head_q,
  input  logic [NST-1:0]      retry_busy,
  input  logic                unc_busy,
  input  logic [NST-1:0]      dcs_valid,
  input  logic [31:0]         dcs_req_id [NST],
  input  logic [1:0]          dcs_replay [NST],
  output logic [SQ-1:0]       wb_mark,
  output logic [SQ-1:0]       dr_pick,
  output logic [SQ-1:0]       dr_fol,
  output logic [SQW-1:0]      dr_ml [SQ],
  output logic [SQ-1:0]       dr_mmio,
  output logic [NST-1:0]      req_valid,
  output logic [31:0]         req_addr [NST],
  output logic [XLEN_BITS-1:0]         req_data [NST],
  output logic [DST_STRB_W-1:0] req_strb [NST],
  output logic [DST_L2_W-1:0]  req_l2 [NST],
  output logic [SQW-1:0]      req_id [NST],
  output logic                st_set,
  output logic [31:0]         st_addr,
  output logic [XLEN_BITS-1:0]         st_wdata,
  output logic [2:0]          st_func3,
  output logic [SQW-1:0]      st_idx
);

  lp_wbuf u_wb (.*);

  // ---- MMIO store: only the head, uncached unit free ----
  always_comb begin
    dr_mmio = '0;
    st_set = d_elig[head_q] && sq[head_q].mmio && !unc_busy;
    dr_mmio[head_q] = st_set;
    st_addr = sq[head_q].paddr;
    st_wdata = sq[head_q].data;
    st_func3 = sq[head_q].func3;
    st_idx = head_q;
  end

endmodule

`default_nettype wire
