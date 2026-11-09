`default_nettype none
// Ref: MemSubSystem/MemSubsystem.cpp  capture_dcache_raw_response / forward_pending_response_from_fill /
//      publish_pending_dcache_response / clear_pending_dcache_response
// Response latch of the DCache domain.  Every port keeps ONE pending response (and the request it answers:
// line/word, store data), collected over the 16 ticks of a CPU cycle; the response of tick 0 is the one published
// to the CPU domain, after which the latch is cleared.  While a response waits for an MSHR fill (MSHR_HIT /
// MSHR_FULL) and the MSHR presents the fill of the same line, the response becomes a HIT: a load takes the fill
// word, a store is merged into the fill data (and marks it dirty); the merged fill data is what dcache_s1 then
// snapshots.
module dcache_resp
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 phase0,                  // tick 0 of the CPU cycle
  // raw stage-2 responses of this tick
  input  logic [NLD-1:0]       ld_valid,
  input  logic [31:0]          ld_data    [NLD],
  input  logic [31:0]          ld_id      [NLD],
  input  logic [NLD-1:0]       ld_retry,
  input  logic [1:0]           ld_replay  [NLD],
  input  logic [NST-1:0]       st_valid,
  input  logic [1:0]           st_replay  [NST],
  input  logic [31:0]          st_id      [NST],
  input  logic                 fill_valid,              // stage-2 fill write (mshr_fill wakeup)
  input  logic                 rel_event,               // LLC-only prefetch entry released (wakeup, address 0)
  input  logic [LINE_W-1:0]    fill_line,
  // the request each port is answering (stage-1 slot registers)
  input  logic [31:0]          slot_addr  [NSLOT],
  input  logic [31:0]          slot_data  [NST],
  input  logic [3:0]           slot_strb  [NST],
  input  st2_t                 slot_l2    [NST],
  // fill request of this tick from the MSHR
  input  logic                 fr_valid,
  input  logic [LINE_W-1:0]    fr_line,
  input  logic                 fr_dirty,
  input  logic [LINE_BITS-1:0] fr_data,
  // fill request after merging pending stores (for the snapshot)
  output logic                 frf_dirty,
  output logic [LINE_BITS-1:0] frf_data,
  // a response is waiting at this port
  output logic [NSLOT-1:0]     pend_valid,
  // published response (valid only on tick 0)
  output logic [NLD-1:0]       pub_ld_valid,
  output logic [31:0]          pub_ld_data   [NLD],
  output logic [31:0]          pub_ld_id     [NLD],
  output logic [NLD-1:0]       pub_ld_retry,
  output logic [1:0]           pub_ld_replay [NLD],
  output logic [NST-1:0]       pub_st_valid,
  output logic [1:0]           pub_st_replay [NST],
  output logic [31:0]          pub_st_id     [NST],
  output logic                 pub_fill,
  output logic [LINE_W-1:0]    pub_fill_line
);

  // ---------------------------------------------------------------- state
  logic [NLD-1:0] ldv_q, ldretry_q;
  logic [31:0]    lddata_q [NLD], ldid_q [NLD];
  logic [1:0]     ldrp_q [NLD];
  logic [29:0]    ldaddr_q [NLD];
  logic [NST-1:0] stv_q;
  logic [1:0]     strp_q [NST];
  logic [31:0]    stid_q [NST], stdata_q [NST];
  logic [3:0]     ststrb_q [NST];
  st2_t           stl2_q [NST];
  logic [29:0]    staddr_q [NST];
  logic           fill_q;
  logic [LINE_W-1:0] fillline_q;

  // ---------------------------------------------------------------- capture (a raw response overwrites the slot)
  logic [NLD-1:0] ldv_a, ldretry_a;
  logic [31:0]    lddata_a [NLD], ldid_a [NLD];
  logic [1:0]     ldrp_a [NLD];
  logic [29:0]    ldaddr_a [NLD];
  logic [NST-1:0] stv_a;
  logic [1:0]     strp_a [NST];
  logic [31:0]    stid_a [NST], stdata_a [NST];
  logic [3:0]     ststrb_a [NST];
  st2_t           stl2_a [NST];
  logic [29:0]    staddr_a [NST];
  logic              fill_a;
  logic [LINE_W-1:0] fillline_a;

  always_comb begin
    for (int i = 0; i < NLD; i++) begin
      ldv_a[i]     = ld_valid[i] || ldv_q[i];
      ldretry_a[i] = ld_valid[i] ? ld_retry[i]  : ldretry_q[i];
      lddata_a[i]  = ld_valid[i] ? ld_data[i]   : lddata_q[i];
      ldid_a[i]    = ld_valid[i] ? ld_id[i]     : ldid_q[i];
      ldrp_a[i]    = ld_valid[i] ? ld_replay[i] : ldrp_q[i];
      ldaddr_a[i]  = ld_valid[i] ? slot_addr[i][31:2] : ldaddr_q[i];
    end
    for (int i = 0; i < NST; i++) begin
      stv_a[i]     = st_valid[i] || stv_q[i];
      strp_a[i]    = st_valid[i] ? st_replay[i] : strp_q[i];
      stid_a[i]    = st_valid[i] ? st_id[i]     : stid_q[i];
      stdata_a[i]  = st_valid[i] ? slot_data[i] : stdata_q[i];
      ststrb_a[i]  = st_valid[i] ? slot_strb[i] : ststrb_q[i];
      stl2_a[i]    = st_valid[i] ? slot_l2[i]   : stl2_q[i];
      staddr_a[i]  = st_valid[i] ? slot_addr[NLD+i][31:2] : staddr_q[i];
    end
    fill_a     = fill_valid || rel_event || fill_q;
    fillline_a = fill_valid ? fill_line : (rel_event ? '0 : fillline_q);
  end

`ifndef SYNTHESIS
  // C++ Assert "latch overflow": a raw response must not hit a port whose previous response (same CPU cycle) is
  // still pending
  for (genvar i = 0; i < NLD; i++) begin : g_chk_ld
    assert property (@(posedge clk) disable iff (!rst_n) !(ld_valid[i] && ldv_q[i]));
  end
  for (genvar i = 0; i < NST; i++) begin : g_chk_st
    assert property (@(posedge clk) disable iff (!rst_n) !(st_valid[i] && stv_q[i]));
  end
`endif

  // ---------------------------------------------------------------- forward from the fill request
  logic [31:0]    lddata_f [NLD];
  logic [1:0]     ldrp_f [NLD];
  logic [1:0]     strp_f [NST];
  logic [LINE_BITS-1:0] frd_f;
  logic                 frdirty_f;
  always_comb begin
    frd_f     = fr_data;
    frdirty_f = fr_dirty;
    for (int i = 0; i < NLD; i++) begin
      lddata_f[i] = lddata_a[i];
      ldrp_f[i]   = ldrp_a[i];
      if (ldv_a[i] && fr_valid && ldrp_a[i][1] && ldaddr_a[i][29:OFF_W-2] == fr_line) begin
        // loads see the fill before this tick's store merges
        lddata_f[i] = line_word(fr_data, ldaddr_a[i][WORD_W-1:0]);
        ldrp_f[i]   = RP_HIT;
      end
    end
    for (int i = 0; i < NST; i++) begin
      strp_f[i] = strp_a[i];
      if (stv_a[i] && fr_valid && strp_a[i][1] && staddr_a[i][29:OFF_W-2] == fr_line) begin
        frd_f     = line_merge(frd_f, staddr_a[i][WORD_W-1:0], stdata_a[i], ststrb_a[i]);
        frd_f     = line_merge(frd_f, stl2_a[i].word, stl2_a[i].data, stl2_a[i].strb);
        frdirty_f = 1'b1;
        strp_f[i] = RP_HIT;
      end
    end
  end
`ifndef SYNTHESIS
  // coverage: forwarding paths
  logic fwd_ld, fwd_ld_full, fwd_st, fwd_st_full;
  always_comb begin
    fwd_ld = 1'b0; fwd_ld_full = 1'b0; fwd_st = 1'b0; fwd_st_full = 1'b0;
    for (int i = 0; i < NLD; i++)
      if (ldv_a[i] && fr_valid && ldrp_a[i][1] && ldaddr_a[i][29:OFF_W-2] == fr_line) begin
        fwd_ld = 1'b1;
        if (ldrp_a[i] == RP_MSHR_FULL) fwd_ld_full = 1'b1;
      end
    for (int i = 0; i < NST; i++)
      if (stv_a[i] && fr_valid && strp_a[i][1] && staddr_a[i][29:OFF_W-2] == fr_line) begin
        fwd_st = 1'b1;
        if (strp_a[i] == RP_MSHR_FULL) fwd_st_full = 1'b1;
      end
  end
  cover property (@(posedge clk) disable iff (!rst_n) fwd_ld);
  cover property (@(posedge clk) disable iff (!rst_n) fwd_ld_full);
  cover property (@(posedge clk) disable iff (!rst_n) fwd_st);
  cover property (@(posedge clk) disable iff (!rst_n) fwd_st_full);
`endif

  assign frf_data  = frd_f;
  assign frf_dirty = frdirty_f;

  assign pend_valid = {stv_a, ldv_a};

  // ---------------------------------------------------------------- publish (tick 0) and registers
  always_comb begin
    pub_ld_valid  = ldv_a & {NLD{phase0}};
    pub_ld_retry  = ldretry_a;
    pub_st_valid  = stv_a & {NST{phase0}};
    pub_fill      = fill_a && phase0;
    pub_fill_line = fillline_a;
    for (int i = 0; i < NLD; i++) begin
      pub_ld_data[i]   = lddata_f[i];
      pub_ld_id[i]     = ldid_a[i];
      pub_ld_replay[i] = ldrp_f[i];
    end
    for (int i = 0; i < NST; i++) begin
      pub_st_replay[i] = strp_f[i];
      pub_st_id[i]     = stid_a[i];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ldv_q  <= '0;
      stv_q  <= '0;
      fill_q <= 1'b0;
    end else begin
      ldv_q  <= ldv_a & ~{NLD{phase0}};          // the latch is cleared at the end of tick 0
      stv_q  <= stv_a & ~{NST{phase0}};
      fill_q <= fill_a && !phase0;
    end
  end

  // payload (consumed only while the valid bit is set; the pending response keeps its forwarded replay/data)
  always_ff @(posedge clk) begin
    for (int i = 0; i < NLD; i++) begin
      ldretry_q[i] <= ldretry_a[i];
      lddata_q[i]  <= lddata_f[i];
      ldid_q[i]    <= ldid_a[i];
      ldrp_q[i]    <= ldrp_f[i];
      ldaddr_q[i]  <= ldaddr_a[i];
    end
    for (int i = 0; i < NST; i++) begin
      strp_q[i]   <= strp_f[i];
      stid_q[i]   <= stid_a[i];
      stdata_q[i] <= stdata_a[i];
      ststrb_q[i] <= ststrb_a[i];
      stl2_q[i]   <= stl2_a[i];
      staddr_q[i] <= staddr_a[i];
    end
    fillline_q <= fillline_a;
  end

endmodule
`default_nettype wire
