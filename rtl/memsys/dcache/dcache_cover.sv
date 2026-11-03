`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp RealDcache (verification aid, no hardware)
// Functional coverage points of the DCache domain (which of the C++ paths listed in docs/modules/dcache.md
// section 5 the lock-step runs reach).  Simulation only (counted by `verilator --coverage-user`); no state.
module dcache_cover
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 phase0,
  input  logic [CNT_W-1:0]     mshr_free,
  input  logic [CNT_W-1:0]     wb_free,
  input  logic [NSLOT-1:0]     slot_valid,
  input  logic [NSLOT-1:0]     slot_replayed,
  input  logic [31:0]          slot_addr [NSLOT],
  input  logic [NSLOT-1:0]     retry_issue,
  input  logic [NSLOT-1:0]     pend_valid,
  input  logic                 s2f_valid,
  input  logic                 same_fill,
  input  logic                 fill_valid,
  input  logic                 evict_valid,
  input  logic [NLD-1:0]       byp_hit,
  input  logic [NST-1:0]       wb_mrg_ok,
  input  logic [NST-1:0]       wb_mrg_busy,
  input  logic [NSLOT-1:0]     mshr_find_hit,
  input  logic [NLD-1:0]       ld_mreq,
  input  logic [NST-1:0]       st_mreq,
  input  logic [NST-1:0]       st_mrg,
  input  logic [NLD-1:0]       s2ld_valid,
  input  logic [1:0]           s2ld_replay [NLD],
  input  logic [NST-1:0]       s2st_valid,
  input  logic [1:0]           s2st_replay [NST],
  input  logic [NLD-1:0]       ld_lu,
  input  logic [NST-1:0]       st_pw,
  input  logic                 mshr_req_valid,
  input  logic                 mshr_resp_valid,
  input  logic                 wb_req_valid,
  input  logic                 wb_resp_valid,
  input  logic                 fr_valid
);

  logic ld_full, st_full, ld_mhit, st_find, st_conf, req_bank_conflict;
  always_comb begin
    ld_full = 1'b0;
    st_full = 1'b0;
    ld_mhit = 1'b0;
    st_find = 1'b0;
    st_conf = 1'b0;
    req_bank_conflict = 1'b0;
    for (int j = 1; j < NSLOT; j++)
      for (int i = 0; i < j; i++)
        if (slot_valid[j] && slot_replayed[j] && slot_valid[i] && !slot_replayed[i] &&
            slot_addr[i][OFF_W +: BANK_W] == slot_addr[j][OFF_W +: BANK_W]) req_bank_conflict = 1'b1;
    for (int i = 0; i < NLD; i++) begin
      if (s2ld_valid[i] && s2ld_replay[i] == RP_MSHR_FULL) ld_full = 1'b1;
      if (s2ld_valid[i] && s2ld_replay[i] == RP_MSHR_HIT && !ld_mreq[i]) ld_mhit = 1'b1;
    end
    for (int i = 0; i < NST; i++) begin
      if (s2st_valid[i] && s2st_replay[i] == RP_MSHR_FULL) st_full = 1'b1;
      if (st_mreq[i] && mshr_find_hit[NLD+i]) st_find = 1'b1;
      if (s2st_valid[i] && s2st_replay[i] == RP_CONFLICT) st_conf = 1'b1;
    end
  end

`ifndef SYNTHESIS
  // MSHR full
  cover property (@(posedge clk) disable iff (!rst_n)
    mshr_free == '0);
  // WriteBuffer full
  cover property (@(posedge clk) disable iff (!rst_n)
    wb_free == '0);
  // fill stalled by a full WB
  cover property (@(posedge clk) disable iff (!rst_n)
    s2f_valid && !fill_valid);
  // dirty victim written back
  cover property (@(posedge clk) disable iff (!rst_n)
    evict_valid);
  // load forwarded from the WB
  cover property (@(posedge clk) disable iff (!rst_n)
    |byp_hit);
  // store merged into a WB entry
  cover property (@(posedge clk) disable iff (!rst_n)
    |wb_mrg_ok);
  // store hits the WB head in flight
  cover property (@(posedge clk) disable iff (!rst_n)
    |wb_mrg_busy);
  // load answered MSHR_FULL
  cover property (@(posedge clk) disable iff (!rst_n)
    ld_full);
  // store answered MSHR_FULL
  cover property (@(posedge clk) disable iff (!rst_n)
    st_full);
  // load joins an existing MSHR entry
  cover property (@(posedge clk) disable iff (!rst_n)
    ld_mhit);
  // store merges into an existing entry
  cover property (@(posedge clk) disable iff (!rst_n)
    st_find);
  // load allocates
  cover property (@(posedge clk) disable iff (!rst_n)
    |ld_mreq);
  // store allocates / merges
  cover property (@(posedge clk) disable iff (!rst_n)
    |st_mreq);
  cover property (@(posedge clk) disable iff (!rst_n)
    (|ld_mreq) && (|st_mreq));
  // bank conflict
  cover property (@(posedge clk) disable iff (!rst_n)
    |(slot_replayed & slot_valid));
  // hidden retry issued
  cover property (@(posedge clk) disable iff (!rst_n)
    |retry_issue);
  cover property (@(posedge clk) disable iff (!rst_n)
    |(slot_replayed & slot_valid & ~retry_issue));
  // retry blocked by a pending response
  cover property (@(posedge clk) disable iff (!rst_n)
    |pend_valid && |retry_issue);
  // store merged into the next snapshot
  cover property (@(posedge clk) disable iff (!rst_n)
    |st_mrg);
  // fill request seen twice (stage 1 + 2)
  cover property (@(posedge clk) disable iff (!rst_n)
    same_fill && fill_valid);
  // stalled fill held
  cover property (@(posedge clk) disable iff (!rst_n)
    same_fill && !fill_valid);
  cover property (@(posedge clk) disable iff (!rst_n)
    |ld_lu);
  cover property (@(posedge clk) disable iff (!rst_n)
    |st_pw);
  cover property (@(posedge clk) disable iff (!rst_n)
    st_conf);
  cover property (@(posedge clk) disable iff (!rst_n)
    mshr_req_valid && mshr_resp_valid);
  cover property (@(posedge clk) disable iff (!rst_n)
    wb_req_valid && wb_resp_valid);
  cover property (@(posedge clk) disable iff (!rst_n)
    fr_valid && phase0);
  // request denied because an earlier request owns its bank
  cover property (@(posedge clk) disable iff (!rst_n)
    req_bank_conflict);
`endif

endmodule
`default_nettype wire
