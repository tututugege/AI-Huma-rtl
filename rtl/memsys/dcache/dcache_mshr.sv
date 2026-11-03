`default_nettype none
// Ref: MemSubSystem/MSHR.cpp  class MSHR (comb_inputs_axi, comb_outputs_dcache, comb_inputs_dcache, ...)
// Miss status holding registers: 8 entries {valid, issued, line, merged-store dirty/data/strobe} + one AXI response
// hold slot.  Tick order (merged from the C++ in-place `nxt` updates):
//   A: an AXI accept marks the entry issued; an R response is taken into the hold slot when it is free and matches
//      an issued entry; find/free/fill_req are read from this state.
//   B: the fill acknowledge releases the hold slot's entry; requests allocate / merge (dcache_mshr_alloc); the AXI
//      request and ready outputs come from the final state (an entry allocated this tick can already be sent).
// mshr_count of the C++ equals popcount(valid) and is not kept.
module dcache_mshr
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // AXI read master inputs
  input  logic                 ax_req_accepted,
  input  logic [7:0]           ax_req_accepted_id,
  input  logic                 ax_resp_valid,
  input  logic [7:0]           ax_resp_id,
  input  logic [LINE_BITS-1:0] ax_resp_data,
  // from stage 2 / the slot registers
  input  logic [NSLOT-1:0]     find_en,                 // granted slots (lookup of the line)
  input  logic [LINE_W-1:0]    find_line  [NSLOT],
  input  logic [NSLOT-1:0]     req_valid,               // allocate / merge request
  input  logic [LINE_W-1:0]    req_line   [NSLOT],
  // store requests (ports NLD..) merge their word; load requests only allocate
  input  logic [WORD_W-1:0]    req_word   [NST],
  input  logic [31:0]          req_data   [NST],
  input  logic [3:0]           req_strb   [NST],
  input  logic                 fill_done,
  input  logic [MSHR_IDW-1:0]  fill_id,
  // to stage 1/2
  output logic [CNT_W-1:0]     free,
  output logic [NSLOT-1:0]     find_hit,
  output logic                 fr_valid,
  output logic [MSHR_IDW-1:0]  fr_id,
  output logic [LINE_W-1:0]    fr_line,
  output logic                 fr_dirty,
  output logic [LINE_BITS-1:0] fr_data,
  // AXI read master outputs (after the whole tick)
  output logic                 ax_req_valid,
  output logic [LINE_W-1:0]    ax_req_line,
  output logic [MSHR_IDW-1:0]  ax_req_id,
  output logic                 ax_resp_ready
);

  // ---------------------------------------------------------------- state
  logic [MSHR_N-1:0]    valid_q, issued_q, mdirty_q;
  logic [LINE_W-1:0]    line_q  [MSHR_N];
  logic [LINE_BITS-1:0] mdata_q [MSHR_N];
  logic [LINE_BITS/8-1:0] mstrb_q [MSHR_N];            // per byte
  logic                 hold_valid_q;
  logic [MSHR_IDW-1:0]  hold_id_q;
  logic [LINE_BITS-1:0] hold_data_q;

  // ---------------------------------------------------------------- A: AXI accept / response
  logic [MSHR_N-1:0] issued_a, rsel;
  logic              take, hold_valid_a;
  logic [MSHR_IDW-1:0]  hold_id_a;
  logic [LINE_BITS-1:0] hold_data_a;
  always_comb begin
    for (int e = 0; e < MSHR_N; e++) begin
      issued_a[e] = issued_q[e] || (ax_req_accepted && ax_req_accepted_id == 8'(e) && valid_q[e]);
      rsel[e]     = ax_resp_id == 8'(e);
    end
    take         = !hold_valid_q && ax_resp_valid && |(rsel & valid_q & issued_a);
    hold_valid_a = hold_valid_q || take;
    hold_id_a    = take ? ax_resp_id[MSHR_IDW-1:0] : hold_id_q;
    hold_data_a  = take ? ax_resp_data : hold_data_q;
  end

  // free count, find, fill request
  logic [MSHR_IDW:0] n_valid;
  ttg_popcount #(.N(MSHR_N)) u_cnt (.bits(valid_q), .count(n_valid));
  assign free = CNT_W'(MSHR_N) - CNT_W'(n_valid);

  always_comb begin
    for (int k = 0; k < NSLOT; k++) begin
      find_hit[k] = 1'b0;
      for (int e = 0; e < MSHR_N; e++) if (find_en[k] && valid_q[e] && line_q[e] == find_line[k]) find_hit[k] = 1'b1;
    end
    fr_valid = hold_valid_a;
    fr_id    = hold_id_a;
    fr_line  = line_q[hold_id_a];
    fr_dirty = mdirty_q[hold_id_a];
    fr_data  = hold_data_a;
    // merged store bytes of the entry overwrite the returned line
    for (int b = 0; b < LINE_BITS / 8; b++) if (mstrb_q[hold_id_a][b]) fr_data[8*b +: 8] = mdata_q[hold_id_a][8*b +: 8];
  end

  // ---------------------------------------------------------------- B: release, allocate / merge
  logic [MSHR_N-1:0] rel, valid_af, alloc_en;
  logic [MSHR_N-1:0] tgt [NSLOT];
  logic [LINE_W-1:0] alloc_line [MSHR_N];
  logic              done_ok;
  always_comb begin
    done_ok = fill_done && hold_valid_a && hold_id_a == fill_id && valid_q[fill_id] && issued_a[fill_id];
    for (int e = 0; e < MSHR_N; e++) rel[e] = done_ok && fill_id == MSHR_IDW'(e);
    valid_af = valid_q & ~rel;
  end
  dcache_mshr_alloc u_alloc (
    .ent_valid(valid_af), .ent_line(line_q), .req_valid(req_valid), .req_line(req_line),
    .tgt(tgt), .alloc_en(alloc_en), .alloc_line(alloc_line)
  );

  // merged store data of every entry after this tick's store requests (store ports are request ports NLD..NSLOT-1)
  logic [MSHR_N-1:0]    mdirty_d;
  logic [LINE_BITS-1:0] mdata_d [MSHR_N];
  logic [LINE_BITS/8-1:0] mstrb_d [MSHR_N];
  logic [MSHR_N-1:0]    mupd;
  always_comb begin
    for (int e = 0; e < MSHR_N; e++) begin
      mdirty_d[e] = alloc_en[e] ? 1'b0 : mdirty_q[e];
      mdata_d[e]  = alloc_en[e] ? '0 : mdata_q[e];
      mstrb_d[e]  = alloc_en[e] ? '0 : mstrb_q[e];
      mupd[e]     = alloc_en[e];
      for (int p = 0; p < NST; p++) if (tgt[NLD+p][e]) begin
        mdata_d[e]  = line_merge(mdata_d[e], req_word[p], req_data[p], req_strb[p]);
        for (int b = 0; b < 4; b++) if (req_strb[p][b]) mstrb_d[e][4 * int'(req_word[p]) + b] = 1'b1;
        mdirty_d[e] = 1'b1;
        mupd[e]     = 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- AXI outputs from the final state
  logic [MSHR_N-1:0] valid_d, issued_d, send_in, send_oh;
  logic              send_any, hold_valid_b;
  logic [LINE_W-1:0] line_d [MSHR_N];
  always_comb begin
    for (int e = 0; e < MSHR_N; e++) begin
      valid_d[e]  = valid_af[e] || alloc_en[e];
      issued_d[e] = (issued_a[e] && !rel[e]) && !alloc_en[e];
      line_d[e]   = alloc_en[e] ? alloc_line[e] : line_q[e];
    end
    send_in      = valid_d & ~issued_d;
    hold_valid_b = hold_valid_a && !done_ok;
  end
  ttg_first_set #(.N(MSHR_N)) u_send (.req(send_in), .onehot(send_oh), .any(send_any));
  always_comb begin
    ax_req_valid = send_any;
    ax_req_line  = '0;
    ax_req_id    = '0;
    for (int e = 0; e < MSHR_N; e++) if (send_oh[e]) begin
      ax_req_line = line_d[e];
      ax_req_id   = MSHR_IDW'(e);
    end
    ax_resp_ready = ax_resp_valid ? take : !hold_valid_b;
  end

  // ---------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q      <= '0;
      issued_q     <= '0;
      hold_valid_q <= 1'b0;
    end else begin
      valid_q      <= valid_d;
      issued_q     <= issued_d;
      hold_valid_q <= hold_valid_b;
    end
  end

  // entry payload (written on allocation / merge; the line address and hold data/id are only read while valid)
  always_ff @(posedge clk) begin
    for (int e = 0; e < MSHR_N; e++) begin
      if (alloc_en[e]) line_q[e] <= alloc_line[e];
      if (mupd[e]) begin
        mdirty_q[e] <= mdirty_d[e];
        mdata_q[e]  <= mdata_d[e];
        mstrb_q[e]  <= mstrb_d[e];
      end
    end
    if (take) begin
      hold_id_q   <= hold_id_a;
      hold_data_q <= hold_data_a;
    end
  end

endmodule
`default_nettype wire
