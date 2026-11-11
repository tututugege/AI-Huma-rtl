// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (uncached_unit: comb_mmio_in_p / comb_stlf_p / comb_flush_p / comb_lsu2
`default_nettype none

// The uncached unit holds the one outstanding MMIO request.  Value chain of a cycle:
//   MMIO response clears it (valid_post_resp) -> an MMIO load takes it (P9) -> rob flush / mispredict kill (P11)
//   -> the head MMIO store takes it (P13).
module lp_unc
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                resp_fire,         // peripheral response && unit valid
  output logic                valid_q,
  output logic                is_load_q,
  output logic [SQW-1:0]      idx_q,             // LDQ index for a load, STQ index for a store
  output logic                valid_post_resp,   // after the response (value seen by the MMIO load issue)
  input  logic                ld_set,
  input  logic [31:0]         ld_addr,
  input  logic [2:0]          ld_func3,
  input  logic [SQW-1:0]      ld_idx,
  input  logic                flush,
  input  logic                mispred,
  input  logic [LQ-1:0]       ld_empty,          // LDQ entry empty after P11
  input  logic [SQ-1:0]       st_mmw,            // STQ entry on the MMIO bus
  input  logic [SQ-1:0]       alive_flushed,     // inside the window after the rob-flush step
  input  logic [SQ-1:0]       alive_final,       // inside the window after the mispredict step
  input  logic                st_set,
  input  logic [31:0]         st_addr,
  input  logic [XLEN_BITS-1:0]         st_wdata,
  input  logic [2:0]          st_func3,
  input  logic [SQW-1:0]      st_idx,
  output logic                valid_pre_st,      // value seen by the MMIO store issue
  output logic                valid_o,
  output logic                is_load_o,
  output logic [31:0]         addr_o,
  output logic [XLEN_BITS-1:0]         wdata_o,
  output logic [2:0]          func3_o
);

  logic [31:0] addr_q;
  logic [XLEN_BITS-1:0] wdata_q;
  logic [2:0]  func3_q;

  logic        v2, is_load2, v_flush, v_kill;
  logic [31:0] addr2;
  logic [2:0]  func32;
  logic [SQW-1:0] idx2;

  assign valid_post_resp = valid_q && !resp_fire;
  assign v2       = valid_post_resp || ld_set;
  assign is_load2 = ld_set ? 1'b1 : is_load_q;
  assign addr2    = ld_set ? ld_addr : addr_q;
  assign func32   = ld_set ? ld_func3 : func3_q;
  assign idx2     = ld_set ? ld_idx : idx_q;

  // rob flush keeps only a store that is still in the committed window and waits for its MMIO response
  assign v_flush = flush ? (v2 && !is_load2 && alive_flushed[idx2] && st_mmw[idx2]) : v2;
  assign v_kill  = mispred && v_flush && (is_load2 ? ld_empty[idx2] : !alive_final[idx2]);
  assign valid_pre_st = v_flush && !v_kill;

  assign valid_o   = valid_pre_st || st_set;
  assign is_load_o = st_set ? 1'b0 : is_load2;
  assign addr_o    = st_set ? st_addr : addr2;
  assign wdata_o   = st_set ? st_wdata : wdata_q;
  assign func3_o   = st_set ? st_func3 : func32;

  always_ff @(posedge clk) begin
    if (!rst_n) valid_q <= 1'b0;
    else        valid_q <= valid_o;
    if (ld_set || st_set) begin
      is_load_q <= is_load_o;
      addr_q    <= addr_o;
      wdata_q   <= wdata_o;
      func3_q   <= func3_o;
      idx_q     <= st_set ? st_idx : idx2;
    end
  end

endmodule

`default_nettype wire
