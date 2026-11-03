// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_mmio_in: response of the MMIO request issued earlier)
`default_nettype none

module lsu_mmio_in
  import lsu_pkg::*;
(
  input  logic             resp_is_mmio,
  input  logic [31:0]      resp_rdata,
  input  logic             unc_valid_i,           // cur.uncached_unit (still equal to nxt here)
  input  logic             unc_is_load,
  input  logic [RIW-1:0]   unc_idx,
  input  lsu_ring_t        finish_i,
  input  ld_state_t        ld_st_i     [LQ],
  input  logic [31:0]      ld_result_i [LQ],
  input  st_state_t        st_st_i     [SQ],
  output logic             unc_valid_o,
  output lsu_ring_t        finish_o,
  output ld_state_t        ld_st_o     [LQ],
  output logic [31:0]      ld_result_o [LQ],
  output st_state_t        st_st_o     [SQ]
);

  logic fire, load_room, load_done, load_hit, store_hit;

  assign fire      = resp_is_mmio && unc_valid_i;
  assign load_room = finish_i.count < RCW'(LQ);               // the load branch needs finish_count < LDQ_SIZE
  assign load_done = fire && unc_is_load && load_room;        // clears uncached.valid whatever the LDQ entry state is
  assign load_hit  = load_done && ld_st_i[unc_idx] == LD_WAIT_MMIO_RESP;
  assign store_hit = fire && !unc_is_load && st_st_i[unc_idx] == ST_WAIT_MMIO_RESP;
  assign unc_valid_o = unc_valid_i && !(load_done || (fire && !unc_is_load));

  for (genvar e = 0; e < LQ; e++) begin : g_ld
    assign ld_st_o[e]     = (load_hit && unc_idx == RIW'(e)) ? LD_READY_TO_WB : ld_st_i[e];
    assign ld_result_o[e] = (load_hit && unc_idx == RIW'(e)) ? resp_rdata : ld_result_i[e];
  end
  for (genvar e = 0; e < SQ; e++) begin : g_st
    assign st_st_o[e] = (store_hit && unc_idx == SQW'(e)) ? ST_DONE : st_st_i[e];
  end

  lsu_ring_app #(.NA(1)) u_fin (.ring_i(finish_i), .app_en(load_hit), .app_idx('{unc_idx}), .ring_o(finish_o));

endmodule

`default_nettype wire
