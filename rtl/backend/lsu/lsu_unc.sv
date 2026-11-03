// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (uncached_unit: set by comb_stlf / comb_lsu2dcache_stq, killed by comb_flush)
`default_nettype none

// The uncached unit holds the one outstanding MMIO request.  Its value is passed through the stage chain:
//   valid_post_resp (comb_mmio_in) -> load set (comb_stlf) -> flush/mispredict kill (comb_flush)
//   -> store set (comb_lsu2dcache_stq)
module lsu_unc
  import lsu_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  input  logic             valid_post_resp,     // after comb_mmio_in cleared it
  output logic             valid_q,             // registers (cur.uncached_unit)
  output logic             is_load_q,
  output logic [RIW-1:0]   idx_q,
  // comb_stlf: an MMIO load takes the unit
  input  logic             ld_set,
  input  logic [31:0]      ld_addr,
  input  logic [2:0]       ld_func3,
  input  logic [RIW-1:0]   ld_idx,
  // comb_flush
  input  logic             flush,
  input  logic             mispred,
  input  logic [LQ-1:0]    ld_empty,            // LDQ entry Empty after the flush / mispredict step
  input  st_state_t        st_st_pre_flush [SQ],
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   count_flushed,
  input  logic [RCW-1:0]   count_final,
  // comb_lsu2dcache_stq: the head store of the commit window takes the unit
  input  logic             st_set,
  input  logic [31:0]      st_addr,
  input  logic [31:0]      st_wdata,
  input  logic [2:0]       st_func3,
  input  logic [RIW-1:0]   st_idx,
  output logic             valid_pre_st,        // value seen by comb_lsu2dcache_stq
  output logic             valid_o,
  output logic             is_load_o,
  output logic [31:0]      addr_o,
  output logic [31:0]      wdata_o,
  output logic [2:0]       func3_o,
  output logic [RIW-1:0]   idx_o
);
  logic [31:0] addr_q, wdata_q;
  logic [2:0]  func3_q;

  logic        v2, is_load2, v_flush, v_kill;
  logic [31:0] addr2;
  logic [2:0]  func32;
  logic [RIW-1:0] idx2;

  assign v2       = valid_post_resp || ld_set;
  assign is_load2 = ld_set ? 1'b1 : is_load_q;
  assign addr2    = ld_set ? ld_addr : addr_q;
  assign func32   = ld_set ? ld_func3 : func3_q;
  assign idx2     = ld_set ? ld_idx : idx_q;

  // rob flush keeps only a store that is still in the (committed) STQ window and waits for its MMIO response
  assign v_flush = flush ? (v2 && !is_load2 && stq_alive(idx2, stq_head, count_flushed) &&
                            st_st_pre_flush[idx2] == ST_WAIT_MMIO_RESP) : v2;
  assign v_kill  = mispred && v_flush && (is_load2 ? ld_empty[idx2] : !stq_alive(idx2, stq_head, count_final));
  assign valid_pre_st = v_flush && !v_kill;

  assign valid_o   = valid_pre_st || st_set;
  assign is_load_o = st_set ? 1'b0 : is_load2;
  assign addr_o    = st_set ? st_addr : addr2;
  assign wdata_o   = st_set ? st_wdata : wdata_q;
  assign func3_o   = st_set ? st_func3 : func32;
  assign idx_o     = st_set ? st_idx : idx2;

  // the request data is only meaningful while valid: written when a request is taken, kept otherwise
  always_ff @(posedge clk) begin
    if (!rst_n) valid_q <= 1'b0;
    else        valid_q <= valid_o;
    if (ld_set || st_set) begin
      is_load_q <= is_load_o;
      addr_q    <= addr_o;
      wdata_q   <= wdata_o;
      func3_q   <= func3_o;
      idx_q     <= idx_o;
    end
  end

endmodule

`default_nettype wire
