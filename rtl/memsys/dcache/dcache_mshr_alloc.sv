`default_nettype none
// Ref: MemSubSystem/MSHR.cpp  MSHR::comb_inputs_dcache (allocation / merge loop over the request ports)
// C++ walks the NSLOT request ports in order: a request joins the entry that already holds its line, else takes the
// lowest free entry (free entries counted after this tick's fill release).  The granted requests of one tick are in
// distinct banks, hence on distinct lines, so a request can only match an entry that existed before this tick (the
// C++ "line allocated earlier in the same loop" case is unreachable); the k-th allocating request takes the k-th lowest
// free entry (chain over the free vector).  A request that finds no free entry gets no target (dropped, as in C++).
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

  logic [MSHR_N-1:0] free_chain [NSLOT+1];
  logic [MSHR_N-1:0] alloc_oh   [NSLOT];

  assign free_chain[0] = ~ent_valid;

  for (genvar j = 0; j < NSLOT; j++) begin : g_req
    logic [MSHR_N-1:0] exist_oh, first_oh;
    logic              has_exist;
    // verilator lint_off UNUSEDSIGNAL
    logic              first_any;     // unused: a request that finds no free entry just gets no target
    // verilator lint_on UNUSEDSIGNAL
    always_comb begin
      for (int e = 0; e < MSHR_N; e++) exist_oh[e] = ent_valid[e] && ent_line[e] == req_line[j];
      has_exist = |exist_oh;
    end
    ttg_first_set #(.N(MSHR_N)) u_free (.req(free_chain[j]), .onehot(first_oh), .any(first_any));
    assign alloc_oh[j]     = (req_valid[j] && !has_exist) ? first_oh : '0;
    assign free_chain[j+1] = free_chain[j] & ~alloc_oh[j];
    assign tgt[j]          = !req_valid[j] ? '0 : (has_exist ? exist_oh : alloc_oh[j]);
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
