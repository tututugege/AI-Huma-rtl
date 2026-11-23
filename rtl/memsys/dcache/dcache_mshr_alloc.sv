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

  // Parallel free-slot picking via ttg_pick_k (replaces NSLOT-deep serial ttg_first_set chain, bit-exact)
  logic [MSHR_N-1:0] exist_oh [NSLOT];
  logic [NSLOT-1:0]  has_exist, need_alloc;
  logic [MSHR_N-1:0] free_pk  [NSLOT];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NSLOT-1:0]  free_pk_v;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [MSHR_N-1:0] alloc_oh [NSLOT];

  for (genvar j = 0; j < NSLOT; j++) begin : g_exist
    always_comb begin
      for (int e = 0; e < MSHR_N; e++) exist_oh[j][e] = ent_valid[e] && (ent_line[e] == req_line[j]);
      has_exist[j]  = |exist_oh[j];
      need_alloc[j] = req_valid[j] && !has_exist[j];
    end
  end

  ttg_pick_k #(.N(MSHR_N), .K(NSLOT)) u_free_pk (.req(~ent_valid), .pick_oh(free_pk), .valid(free_pk_v));

  for (genvar j = 0; j < NSLOT; j++) begin : g_rank
    localparam int RW = $clog2(NSLOT + 1);
    logic [RW-1:0] rank_j;
    if (j == 0) begin : g_r0
      assign rank_j = '0;
    end else begin : g_rn
      logic [$clog2(j + 1)-1:0] cnt_j;
      ttg_popcount #(.N(j)) u_rk (.bits(need_alloc[j-1:0]), .count(cnt_j));
      assign rank_j = RW'(cnt_j);
    end
    always_comb begin
      alloc_oh[j] = '0;
      if (need_alloc[j]) alloc_oh[j] = free_pk[rank_j[$clog2(NSLOT)-1:0]];
      tgt[j] = !req_valid[j] ? '0 : (has_exist[j] ? exist_oh[j] : alloc_oh[j]);
    end
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
