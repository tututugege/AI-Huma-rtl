`default_nettype none
// Ref: MemSubSystem/MSHR.cpp  MSHR::comb_inputs_dcache (allocation / merge loop over the request ports)
// C++ walks the NSLOT request ports in order: a request joins the entry that already holds its line (including one
// allocated earlier in
// the same loop), else takes the lowest free entry (free entries are counted after this tick's fill release).
// Equivalent
// combinational form: a request is a *leader* when no entry holds its line and no earlier request has the same
// line; the k-th leader
// takes the k-th lowest free entry (chain over the free vector); a follower targets its leader's entry.  A leader
// finding no free
// entry gets no target (the request is dropped, as in C++).
module dcache_mshr_alloc
  import dcache_pkg::*;
(
  input  logic [MSHR_N-1:0]   ent_valid,               // valid after this tick's release
  input  logic [LINE_W-1:0]   ent_line  [MSHR_N],
  input  logic [NSLOT-1:0]    req_valid,
  input  logic [LINE_W-1:0]   req_line  [NSLOT],
  output logic [MSHR_N-1:0]   tgt       [NSLOT],       // entry the request ends up in (one-hot, or 0)
  output logic [MSHR_N-1:0]   alloc_en,                // entries newly allocated this tick
  output logic [LINE_W-1:0]   alloc_line [MSHR_N]      // line of the new entry
);

  logic [NSLOT-1:0]  leader;
  logic [MSHR_N-1:0] free_chain [NSLOT+1];
  logic [MSHR_N-1:0] alloc_oh   [NSLOT];

  assign free_chain[0] = ~ent_valid;

  for (genvar j = 0; j < NSLOT; j++) begin : g_req
    logic [MSHR_N-1:0] exist_oh, first_oh, lead_tgt, tgt_r;
    logic              has_exist, no_earlier_same, leader_r;
    // verilator lint_off UNUSEDSIGNAL
    logic              first_any;     // unused: a leader without a free entry just gets no target
    // verilator lint_on UNUSEDSIGNAL
    always_comb begin
      for (int e = 0; e < MSHR_N; e++) exist_oh[e] = ent_valid[e] && ent_line[e] == req_line[j];
      has_exist       = |exist_oh;
      no_earlier_same = 1'b1;
      for (int i = 0; i < j; i++) if (req_valid[i] && req_line[i] == req_line[j]) no_earlier_same = 1'b0;
      leader_r = req_valid[j] && !has_exist && no_earlier_same;
    end
    ttg_first_set #(.N(MSHR_N)) u_free (.req(free_chain[j]), .onehot(first_oh), .any(first_any));
    assign leader[j]        = leader_r;
    assign alloc_oh[j]      = leader_r ? first_oh : '0;
    assign free_chain[j+1]  = free_chain[j] & ~alloc_oh[j];

    // follower of an earlier leader (same line allocated earlier in this tick)
    always_comb begin
      lead_tgt = '0;
      for (int i = 0; i < j; i++) if (leader[i] && req_line[i] == req_line[j]) lead_tgt = lead_tgt | alloc_oh[i];
      if (!req_valid[j])  tgt_r = '0;
      else if (has_exist) tgt_r = exist_oh;
      else if (leader_r)  tgt_r = alloc_oh[j];
      else                tgt_r = lead_tgt;
    end
    assign tgt[j] = tgt_r;
  end

  always_comb begin
    alloc_en = '0;
    for (int j = 0; j < NSLOT; j++) alloc_en = alloc_en | alloc_oh[j];
    for (int e = 0; e < MSHR_N; e++) begin
      alloc_line[e] = '0;
      for (int j = 0; j < NSLOT; j++) if (alloc_oh[j][e]) alloc_line[e] = req_line[j];
    end
  end

endmodule
`default_nettype wire
