`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp  RealDcache::stage1_comb / seq (S1S2Reg, bank_retry_cur/nxt, fill snapshot)
// Stage 1: picks one request per LSU port (real request, else the pending hidden bank-conflict retry, else a new
// one), grants banks (fill snapshot first, then load 0..3, store 0..3; a later request to a taken bank is
// `replayed`) and owns the stage-1 -> stage-2 registers: 8 slots, the icache probe port, the fill snapshot `s2f`
// and the hidden retry latches.  The payload of an invalid slot is don't-care, so it is rewritten every tick.
module dcache_s1
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // routed LSU request of this tick (all empty on ticks 1..15)
  input  logic [NLD-1:0]       ld_req_valid,
  input  logic [31:0]          ld_req_addr  [NLD],
  input  logic [31:0]          ld_req_id    [NLD],
  input  logic                 ld_req_replay [NLD],
  input  logic [NST-1:0]       st_req_valid,
  input  logic [31:0]          st_req_addr  [NST],
  input  logic [31:0]          st_req_data  [NST],
  input  logic [3:0]           st_req_strb  [NST],
  input  logic [31:0]          st_req_id    [NST],
  input  logic [2:0]           icache_req,
  // prefetch tag-probe candidate (FIFO head of dcache_pf); taken when it rides an idle load port
  input  logic                 pf_head_valid,
  input  logic [LINE_W-1:0]    pf_head_line,
  input  logic                 pf_head_llc,
  output logic                 pf_taken,
  // a response of this port is still waiting in the latch (dcache_resp): hidden retry must not be issued
  input  logic [NSLOT-1:0]     blocked,
  // fill request seen this tick (after the response forwarding merged pending stores into it)
  input  logic                 fr_valid,
  input  logic [LINE_W-1:0]    fr_line,
  input  logic [MSHR_IDW-1:0]  fr_id,
  input  logic                 fr_dirty,
  input  logic                 fr_pf,
  input  logic [LINE_BITS-1:0] fr_data,
  // stage-2 results of this tick
  input  logic                 s2_fill_valid,             // out.fill_write.valid
  // stores merged into the incoming fill (applied to the snapshot)
  input  logic [NST-1:0]       mrg_en,
  input  logic [31:0]          mrg_data     [NST],
  input  logic [3:0]           mrg_strb     [NST],
  input  logic [WORD_W-1:0]    mrg_word     [NST],
  // ---- stage-1 registers seen by stage 2 / the arrays / the WB+MSHR lookups ----
  output logic [NSLOT-1:0]     slot_valid,
  output logic [NSLOT-1:0]     slot_replayed,             // bank not granted
  output logic [31:0]          slot_addr    [NSLOT],
  output logic [31:0]          slot_id      [NSLOT],
  output logic [31:0]          slot_data    [NST],
  output logic [3:0]           slot_strb    [NST],
  output logic [2:0]           icache_req_s2,
  output logic [NLD-1:0]       slot_pf,                   // slot is a prefetch tag probe
  output logic [NLD-1:0]       slot_pf_llc,               // ... whose line only goes to the LLC
  output logic [NLD-1:0]       slot_perf_replay,          // LSU re-issue or hidden retry (not trained on)
  // replayed bank-conflict LSU request whose retry latch is free: no response
  output logic [NSLOT-1:0]     retry_issue,
  output logic                 s2f_valid,
  output logic [MSHR_IDW-1:0]  s2f_id,
  output logic                 s2f_dirty,
  output logic                 s2f_pf,
  output logic [LINE_W-1:0]    s2f_line,
  output logic [LINE_BITS-1:0] s2f_data,
  output logic                 same_fill                  // fill request is the line already in stage 2
);

  // ------------------------------------------------------------------ state
  logic [NSLOT-1:0] slot_valid_q, slot_replayed_q;
  logic [31:0]      slot_addr_q [NSLOT];
  logic [31:0]      slot_id_q   [NSLOT];
  logic [31:0]      slot_data_q [NST];
  logic [3:0]       slot_strb_q [NST];
  logic [2:0]       icache_req_r_q;
  logic             s2f_valid_q, s2f_dirty_q, s2f_pf_q;
  logic [NLD-1:0]   slot_pf_q, slot_pfllc_q, slot_prep_q;
  logic [MSHR_IDW-1:0]  s2f_id_q;
  logic [LINE_W-1:0]    s2f_line_q;
  logic [LINE_BITS-1:0] s2f_data_q;
  // hidden retry latches (one per port): addr/id/data/strb are always the slot payload that was replayed
  logic [NSLOT-1:0] rty_valid_q;
  logic [31:0]      rty_addr_q [NSLOT];
  logic [31:0]      rty_id_q   [NSLOT];
  logic [31:0]      rty_data_q [NST];
  logic [3:0]       rty_strb_q [NST];

  assign slot_valid    = slot_valid_q;
  assign slot_replayed = slot_replayed_q;
  assign slot_addr     = slot_addr_q;
  assign slot_id       = slot_id_q;
  assign slot_data     = slot_data_q;
  assign slot_strb     = slot_strb_q;
  assign icache_req_s2  = icache_req_r_q;
  assign s2f_valid     = s2f_valid_q;
  assign s2f_id        = s2f_id_q;
  assign s2f_dirty     = s2f_dirty_q;
  assign s2f_pf        = s2f_pf_q;
  assign slot_pf          = slot_pf_q;
  assign slot_pf_llc      = slot_pfllc_q;
  assign slot_perf_replay = slot_prep_q;
  assign s2f_line      = s2f_line_q;
  assign s2f_data      = s2f_data_q;

  // ------------------------------------------------------------------ request selection per port
  logic [NSLOT-1:0] use_pend, use_new, req_v;
  logic [NLD-1:0]   pf_sel, perf_rep_d;
  logic [31:0]      req_addr [NSLOT];
  logic [31:0]      req_id   [NSLOT];
  logic [31:0]      req_data [NST];
  logic [3:0]       req_strb [NST];

  always_comb begin
    for (int i = 0; i < NSLOT; i++)
      retry_issue[i] = slot_valid_q[i] && slot_replayed_q[i] && !slot_id_q[i][31] && !rty_valid_q[i];
  end

  for (genvar i = 0; i < NSLOT; i++) begin : g_sel
    logic real_v;
    logic [31:0] real_addr, real_id;
    if (i < NLD) begin : g_ld
      assign real_v    = ld_req_valid[i];
      assign real_addr = ld_req_addr[i];
      assign real_id   = ld_req_id[i];
    end else begin : g_st
      assign real_v    = st_req_valid[i-NLD];
      assign real_addr = st_req_addr[i-NLD];
      assign real_id   = st_req_id[i-NLD];
    end
    // hidden retry: pending latch first, else the retry issued from the slot this very tick (fed back through the slot
    // regs)
    assign use_pend[i] = !real_v && !blocked[i] && rty_valid_q[i];
    assign use_new[i]  = !real_v && !blocked[i] && !use_pend[i] && retry_issue[i];
    assign req_v[i]    = real_v || use_pend[i] || use_new[i];
    assign req_addr[i] = real_v ? real_addr : (use_pend[i] ? rty_addr_q[i] : slot_addr_q[i]);
    assign req_id[i]   = real_v ? real_id   : (use_pend[i] ? rty_id_q[i]   : slot_id_q[i]);
  end
  for (genvar i = 0; i < NST; i++) begin : g_stp
    assign req_data[i] = st_req_valid[i] ? st_req_data[i] : (use_pend[NLD+i] ? rty_data_q[i] : slot_data_q[i]);
    assign req_strb[i] = st_req_valid[i] ? st_req_strb[i] : (use_pend[NLD+i] ? rty_strb_q[i] : slot_strb_q[i]);
  end

  // ------------------------------------------------------------------ fill snapshot control
  logic fill_hold, fill_occupies_bank, fill_snap;
  logic [BANK_W-1:0] fill_bank;
  assign same_fill          = s2f_valid_q && fr_valid && s2f_line_q == fr_line;
  assign fill_hold          = same_fill && !s2_fill_valid;          // fill stalled in stage 2 (WB full): keep it
  assign fill_occupies_bank = fr_valid && !(same_fill && s2_fill_valid);
  assign fill_snap          = fr_valid && !same_fill;               // new line enters stage 2
  assign fill_bank          = fr_line[BANK_W-1:0];

  // ------------------------------------------------------------------ bank grant
  logic [NSLOT-1:0] grant;
  logic [BANK_W-1:0] req_bank [NSLOT];
  for (genvar i = 0; i < NSLOT; i++) begin : g_bank
    assign req_bank[i] = req_addr[i][OFF_W +: BANK_W];
  end
  for (genvar i = 0; i < NSLOT; i++) begin : g_grant
    logic no_earlier_same_bank;
    always_comb begin
      no_earlier_same_bank = 1'b1;
      for (int j = 0; j < i; j++) if (req_v[j] && req_bank[j] == req_bank[i]) no_earlier_same_bank = 1'b0;
      grant[i] = req_v[i] && !(fill_occupies_bank && fill_bank == req_bank[i]) && no_earlier_same_bank;
    end
  end

  // ------------------------------------------------------------------ prefetch tag probe (lowest priority)
  // The first load port without a request (real or hidden retry) carries the FIFO head if the bank of its line is free.
  logic [BANK_W-1:0] pf_bank;
  logic              pf_bank_busy, pf_go;
  logic [NLD-1:0]    idle_first;
  assign pf_bank = pf_head_line[BANK_W-1:0];
  always_comb begin
    pf_bank_busy = fill_occupies_bank && fill_bank == pf_bank;
    for (int j = 0; j < NSLOT; j++) if (grant[j] && req_bank[j] == pf_bank) pf_bank_busy = 1'b1;
    idle_first = '0;
    for (int i = NLD - 1; i >= 0; i--) if (!req_v[i]) begin
      idle_first = '0;
      idle_first[i] = 1'b1;
    end
    pf_go  = pf_head_valid && (|idle_first) && !pf_bank_busy;
    pf_sel = pf_go ? idle_first : '0;
  end
  assign pf_taken = pf_go;
  for (genvar i = 0; i < NLD; i++) begin : g_prep
    // hidden retries count as replays; real requests carry the LSU's replay flag
    assign perf_rep_d[i] = ld_req_valid[i] ? ld_req_replay[i] : 1'b1;
  end

  // ------------------------------------------------------------------ next state
  logic [NSLOT-1:0] rty_set;          // a replayed request that could not be re-issued is parked in the latch
  assign rty_set = retry_issue & ~use_new;

  logic                 s2f_valid_d, s2f_dirty_d, s2f_pf_d;
  logic [MSHR_IDW-1:0]  s2f_id_d;
  logic [LINE_W-1:0]    s2f_line_d;
  logic [LINE_BITS-1:0] s2f_data_d;
  always_comb begin
    if (fill_hold) begin
      s2f_valid_d = 1'b1;
      s2f_id_d    = s2f_id_q;
      s2f_line_d  = s2f_line_q;
      s2f_dirty_d = s2f_dirty_q;
      s2f_pf_d    = s2f_pf_q;
      s2f_data_d  = s2f_data_q;
    end else begin
      s2f_valid_d = fill_snap;
      s2f_id_d    = fill_snap ? fr_id : '0;
      s2f_line_d  = fill_snap ? fr_line : '0;
      s2f_dirty_d = fill_snap && fr_dirty;
      s2f_pf_d    = fill_snap && fr_pf;
      s2f_data_d  = fill_snap ? fr_data : '0;
    end
    // stores of this tick that hit the line being filled are merged into the snapshot (port order, later wins)
    if (s2f_valid_d) begin
      for (int p = 0; p < NST; p++) if (mrg_en[p]) begin
        s2f_data_d  = line_merge(s2f_data_d, mrg_word[p], mrg_data[p], mrg_strb[p]);
        s2f_dirty_d = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      slot_valid_q    <= '0;
      slot_replayed_q <= '0;
      rty_valid_q     <= '0;
      icache_req_r_q  <= '0;
      s2f_valid_q     <= 1'b0;
    end else begin
      slot_valid_q    <= req_v | {{NST{1'b0}}, pf_sel};
      slot_pf_q       <= pf_sel;
      slot_replayed_q <= req_v & ~grant;
      for (int i = 0; i < NSLOT; i++) begin
        if (use_pend[i]) rty_valid_q[i] <= 1'b0;
        else if (rty_set[i]) rty_valid_q[i] <= 1'b1;
      end
      icache_req_r_q  <= icache_req;
      s2f_valid_q     <= s2f_valid_d;
    end
  end

  // payload registers: no reset needed (payload is only consumed while the matching valid bit is set)
  always_ff @(posedge clk) begin
    for (int i = 0; i < NSLOT; i++) begin
      slot_addr_q[i] <= req_addr[i];
      slot_id_q[i]   <= req_id[i];
      if (i < NLD) begin
        if (pf_sel[i < NLD ? i : 0]) begin
          slot_addr_q[i] <= {pf_head_line, {OFF_W{1'b0}}};
          slot_id_q[i]   <= 32'h8000_0000;
        end
        slot_pfllc_q[i < NLD ? i : 0] <= pf_head_llc;
        slot_prep_q[i < NLD ? i : 0]  <= pf_sel[i < NLD ? i : 0] ? 1'b1 : perf_rep_d[i < NLD ? i : 0];
      end
      if (rty_set[i]) begin
        rty_addr_q[i] <= slot_addr_q[i];
        rty_id_q[i]   <= slot_id_q[i];
      end
    end
    for (int p = 0; p < NST; p++) begin
      slot_data_q[p] <= req_data[p];
      slot_strb_q[p] <= req_strb[p];
      if (rty_set[NLD+p]) begin
        rty_data_q[p] <= slot_data_q[p];
        rty_strb_q[p] <= slot_strb_q[p];
      end
    end
    s2f_id_q   <= s2f_id_d;
    s2f_dirty_q <= s2f_dirty_d;
    s2f_pf_q    <= s2f_pf_d;
    s2f_line_q <= s2f_line_d;
    s2f_data_q <= s2f_data_d;
  end

endmodule
`default_nettype wire
