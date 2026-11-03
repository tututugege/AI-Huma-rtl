// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_mmio_in: response of the MMIO request issued earlier)
`default_nettype none

module lsu_mmio_in
  import lsu_pkg::*;
(
  input  logic             resp_is_mmio,
  input  logic [31:0]      resp_rdata,
  input  logic             unc_valid,             // cur.uncached_unit
  input  logic             unc_is_load,
  input  logic [RIW-1:0]   unc_idx,
  input  logic [RCW-1:0]   fin_count_q,
  input  ld_state_t        ld_st_q     [LQ],
  input  st_state_t        st_st_q     [SQ],
  output logic             unc_valid_o,           // uncached valid after the response
  output ldq_mm_t          ld_mm       [LQ],      // events for the LDQ entries
  output logic [SQ-1:0]    st_mm,                 // events for the STQ entries
  output lsu_rop_t         fin_op                 // finish queue: the load enters it
);
  logic fire, load_room, load_done, load_hit, store_hit;
  assign fire      = resp_is_mmio && unc_valid;
  assign load_room = fin_count_q < RCW'(LQ);               // the load branch needs finish_count < LDQ_SIZE
  assign load_done = fire && unc_is_load && load_room;        // clears uncached.valid whatever the LDQ entry state is
  assign load_hit  = load_done && ld_st_q[unc_idx] == LD_WAIT_MMIO_RESP;
  assign store_hit = fire && !unc_is_load && st_st_q[unc_idx] == ST_WAIT_MMIO_RESP;
  assign unc_valid_o = unc_valid && !(load_done || (fire && !unc_is_load));
  for (genvar e = 0; e < LQ; e++) begin : g_ld
    assign ld_mm[e].go   = load_hit && unc_idx == RIW'(e);
    assign ld_mm[e].data = resp_rdata;
  end
  for (genvar e = 0; e < SQ; e++) begin : g_st
    assign st_mm[e] = store_hit && unc_idx == SQW'(e);
  end
  logic [WIN-1:0]          app_en;
  logic [WIN-1:0][RIW-1:0] app_idx;
  always_comb begin
    app_en  = '0;
    app_idx = '0;
    app_en[0]  = load_hit;
    app_idx[0] = unc_idx;
  end
  assign fin_op = rop_app(app_en, app_idx);
endmodule

`default_nettype wire
