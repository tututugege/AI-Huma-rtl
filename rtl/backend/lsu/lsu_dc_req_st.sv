// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2dcache_stq: committed-store window -> DCache stores / MMIO store)
`default_nettype none

module lsu_dc_req_st
  import lsu_pkg::*;
(
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_ccount,                // window = first min(ccount, WIN) stores from the head
  input  logic             unc_valid,                 // uncached unit as seen after comb_flush
  input  logic [SQ-1:0]    st_wdr_q,                  // cur.stq[].store_state == WaitDcacheResp
  input  st_state_t        st_st_i      [SQ],
  input  logic [RWW-1:0]   st_wait_i    [SQ],
  input  logic [31:0]      st_paddr     [SQ],
  input  logic [2:0]       st_func3     [SQ],
  input  logic [31:0]      st_data      [SQ],
  input  logic [SQ-1:0]    st_suppress,
  input  logic [SQ-1:0]    st_mmio,
  output logic [NST-1:0]   req_valid,
  output logic [31:0]      req_addr     [NST],
  output logic [31:0]      req_data     [NST],
  output logic [4:0]       req_strb     [NST],
  output logic [SQW-1:0]   req_id       [NST],
  output st_state_t        st_st_o      [SQ],
  output logic [RWW-1:0]   st_wait_o    [SQ],
  output logic             unc_set,
  output logic [31:0]      unc_addr,
  output logic [31:0]      unc_wdata,
  output logic [2:0]       unc_func3,
  output logic [RIW-1:0]   unc_idx
);

  // ---- window read: position q = store at head + q ----
  logic [WIN-1:0] in_w, committed_w, supp_w, mmio_w, wdr_w, done_w;
  logic [RIW-1:0] slot_w [WIN];
  logic [RWW-1:0] wait_w [WIN];
  logic [31:0]    paddr_w [WIN];
  logic [4:0]     strb_w [WIN];
  for (genvar q = 0; q < WIN; q++) begin : g_read
    assign slot_w[q]      = stq_head + RIW'(q);
    assign in_w[q]        = stq_ccount > RCW'(q);
    assign committed_w[q] = st_st_i[slot_w[q]] == ST_COMMITTED;
    assign done_w[q]      = st_st_i[slot_w[q]] == ST_DONE;
    assign supp_w[q]      = st_suppress[slot_w[q]];
    assign mmio_w[q]      = st_mmio[slot_w[q]];
    assign wdr_w[q]       = st_wdr_q[slot_w[q]];
    assign wait_w[q]      = st_wait_i[slot_w[q]];
    assign paddr_w[q]     = st_paddr[slot_w[q]];
    assign strb_w[q]      = store_strb(paddr_w[q][1:0], st_func3[slot_w[q]][1:0]);
  end

  // ---- same-address conflicts with older stores of the window ----
  logic [WIN-1:0] conflict [WIN];                     // conflict[i][j]: older store j overlaps store i (j < i)
  for (genvar i = 0; i < WIN; i++) begin : g_row
    for (genvar j = 0; j < WIN; j++) begin : g_col
      if (j < i) begin : g_pair
        assign conflict[i][j] = check_addr(paddr_w[j][31:2], strb_w[j], paddr_w[i][31:2], strb_w[i]);
      end else begin : g_none
        assign conflict[i][j] = 1'b0;
      end
    end
  end

  // ---- ordered decision along the window (position i sees the verdicts of the older positions j < i) ----
  logic           cand [WIN], proceed [WIN], dec [WIN], blocked [WIN], issue [WIN], sup_done [WIN], mm_start [WIN];
  logic           done_after [WIN];
  logic [WIN-1:0] live_conf [WIN];                   // older overlapping store that is not Done (yet)
  logic [RCW-1:0] n_iss [WIN+1];                     // DCache requests issued by positions before i
  assign n_iss[0] = '0;
  for (genvar i = 0; i < WIN; i++) begin : g_dec
    logic visited;
    for (genvar j = 0; j < WIN; j++) begin : g_live
      if (j < i) begin : g_older
        assign live_conf[i][j] = conflict[i][j] && !done_after[j];
      end else begin : g_none
        assign live_conf[i][j] = 1'b0;
      end
    end
    assign cand[i]       = in_w[i] && committed_w[i] && !wdr_w[i];
    assign visited       = n_iss[i] < RCW'(NST);
    assign dec[i]        = cand[i] && visited && wait_w[i] != '0;
    assign proceed[i]    = cand[i] && visited && wait_w[i] < RWW'(2);
    assign blocked[i]    = |live_conf[i];
    assign issue[i]      = proceed[i] && !blocked[i] && !mmio_w[i] && !supp_w[i];
    assign sup_done[i]   = proceed[i] && !blocked[i] && !mmio_w[i] && supp_w[i];
    assign mm_start[i]   = proceed[i] && !blocked[i] && mmio_w[i] && i == 0 && !unc_valid;
    assign done_after[i] = done_w[i] || sup_done[i];
    assign n_iss[i+1]    = n_iss[i] + RCW'(issue[i]);
  end

  always_comb begin
    for (int k = 0; k < NST; k++) begin
      req_valid[k] = 1'b0;
      req_addr[k]  = '0;
      req_data[k]  = '0;
      req_strb[k]  = '0;
      req_id[k]    = '0;
      for (int q = 0; q < WIN; q++) begin
        if (issue[q] && n_iss[q] == RCW'(k)) begin
          req_valid[k] = 1'b1;
          req_addr[k]  = paddr_w[q];
          req_data[k]  = align_store_data(st_data[slot_w[q]], paddr_w[q][1:0], st_func3[slot_w[q]][1:0]);
          req_strb[k]  = strb_w[q];
          req_id[k]    = slot_w[q];
        end
      end
    end
    unc_set   = mm_start[0];
    unc_addr  = paddr_w[0];
    unc_wdata = st_data[slot_w[0]];
    unc_func3 = st_func3[slot_w[0]];
    unc_idx   = slot_w[0];
  end

  for (genvar s = 0; s < SQ; s++) begin : g_entry
    logic [WIN-1:0] by_iss, by_sup, by_mm, by_dec;
    for (genvar q = 0; q < WIN; q++) begin : g_p
      assign by_iss[q] = issue[q]    && slot_w[q] == RIW'(s);
      assign by_sup[q] = sup_done[q] && slot_w[q] == RIW'(s);
      assign by_mm[q]  = mm_start[q] && slot_w[q] == RIW'(s);
      assign by_dec[q] = dec[q]      && slot_w[q] == RIW'(s);
    end
    assign st_st_o[s]   = (|by_iss) ? ST_WAIT_DCACHE_RESP :
                          (|by_sup) ? ST_DONE :
                          (|by_mm)  ? ST_WAIT_MMIO_RESP : st_st_i[s];
    assign st_wait_o[s] = (|by_sup) ? '0 : (|by_dec) ? st_wait_i[s] - RWW'(1) : st_wait_i[s];
  end

endmodule

`default_nettype wire
