// Ref: front-end/BPU/dir_predictor/TAGE_top.h  TAGE_TOP::tage_update_comb (+ lsfr_update_comb)
`default_nettype none

// Update decision of one TAGE bank (one update per cycle, from the update queue).  The caller has read the
// START-of-cycle counters / useful bits at the indices recorded with the prediction (idx_in); returns write requests.
// sc_used/loop_used are constant 0 in this configuration, so the provider is always "used" (provider_used == 1).
module bpu_tage_upd import bpu_pkg::*; (
  input  logic [T_IDX_W-1:0]  idx_in      [TN],
  input  logic                real_dir,
  input  logic                pred_in,
  input  logic                alt_pred_in,
  input  logic [PCPN_W-1:0]   pcpn_in,
  input  logic [1:0]          base_cnt,
  input  logic [2:0]          rd_cnt      [TN],
  input  logic [1:0]          rd_useful   [TN],
  input  logic [1:0]          reset_row_useful [TN],    // useful[i][reset row] (START of cycle)
  input  logic [3:0]          lsfr,                     // {LSFR[3..0]}
  input  logic [23:0]         reset_cnt,
  input  logic [3:0]          use_alt_ctr,
  // write requests
  output logic                base_we,
  output logic [1:0]          base_wdata,
  output logic                cnt_we      [TN],
  output logic [2:0]          cnt_wdata   [TN],
  output logic                useful_we   [TN],
  output logic [1:0]          useful_wdata [TN],
  output logic                tag_we      [TN],
  output logic                reset_we    [TN],         // useful row-clear write of table i
  output logic [T_IDX_W-1:0]  reset_row,
  output logic [1:0]          reset_wdata [TN],
  output logic                use_alt_we,
  output logic [3:0]          use_alt_wdata,
  output logic [3:0]          lsfr_next,
  output logic [23:0]         reset_cnt_next
);

  logic              has_prov;
  logic [2:0]        prov_cnt;
  logic [1:0]        prov_useful;
  logic              prov_pred_raw;
  logic              alt_used;
  logic              prov_weak;
  logic              prov_correct;
  logic              alt_correct;
  // allocation
  logic              alloc;
  logic [TN-1:0]     free_tbl;
  logic [TN-1:0]     j_onehot;
  logic [TN-1:0]     k_onehot;
  logic [TN-1:0]     rest;                           // free tables after removing j
  logic              found_j;
  logic              found_k;
  logic [1:0]        lsfr_rand;
  logic              pick_k;
  logic [TN-1:0]     target_onehot;
  logic [PCPN_W-1:0] start_search;
  logic [TN-1:0]     in_range;                       // tables searched for allocation (index >= start_search)

  function automatic logic [1:0] dec2(input logic [1:0] v);
    return (v == 2'd0) ? 2'd0 : v - 2'd1;
  endfunction
  function automatic logic [1:0] inc2(input logic [1:0] v);
    return (v == 2'd3) ? 2'd3 : v + 2'd1;
  endfunction

  // Ref: tage_update_comb, 1. update provider / base
  always_comb begin
    has_prov      = (pcpn_in < PCPN_W'(TN));
    prov_cnt      = rd_cnt[pcpn_in[1:0]];
    prov_useful   = rd_useful[pcpn_in[1:0]];
    prov_pred_raw = (prov_cnt >= 3'd4);
    alt_used      = (pred_in == alt_pred_in);
    prov_weak     = (prov_cnt == 3'd3);
    prov_correct  = (prov_pred_raw == real_dir);
    alt_correct   = (alt_pred_in == real_dir);
    base_we       = !has_prov;
    base_wdata    = real_dir ? inc2(base_cnt) : dec2(base_cnt);
    use_alt_we    = has_prov && prov_weak && (prov_useful == 2'd0) && (prov_pred_raw != alt_pred_in) &&
                    (prov_correct ^ alt_correct);
    use_alt_wdata = alt_correct ? ((use_alt_ctr == 4'd0) ? 4'd0 : use_alt_ctr - 4'd1) :
                                  ((use_alt_ctr == 4'd15) ? 4'd15 : use_alt_ctr + 4'd1);
  end

  // Ref: tage_update_comb, 2. allocation: free (useful == 0) tables from start_search, first = j, second = k
  always_comb begin
    start_search = (pcpn_in == PCPN_W'(TN)) ? PCPN_W'(0) : pcpn_in + PCPN_W'(1);
    for (int i = 0; i < TN; i++) in_range[i] = (PCPN_W'(i) >= start_search);
  end

  always_comb begin
    for (int i = 0; i < TN; i++) free_tbl[i] = in_range[i] && (rd_useful[i] == 2'd0);
  end

  always_comb begin
    alloc    = (pred_in != real_dir) && ((pcpn_in <= PCPN_W'(TN - 2)) || (pcpn_in == PCPN_W'(TN)));
    j_onehot = free_tbl & (~free_tbl + TN'(1));
    rest     = free_tbl & ~j_onehot;
    k_onehot = rest & (~rest + TN'(1));
    found_j  = |free_tbl;
    found_k  = |rest;
    lsfr_next = {lsfr[2:0], lsfr[0] ^ lsfr[3]};
    lsfr_rand = {lsfr_next[0], lsfr_next[1]};
    pick_k    = found_k && (lsfr_rand == 2'd0 || lsfr_rand == 2'd3);          // lsfr_rand % 3 == 0
    target_onehot = pick_k ? k_onehot : j_onehot;
  end

  // write requests: provider update, allocation (or useful decay), reset
  always_comb begin
    for (int i = 0; i < TN; i++) begin
      cnt_we[i]       = 1'b0;
      cnt_wdata[i]    = '0;
      useful_we[i]    = 1'b0;
      useful_wdata[i] = '0;
      tag_we[i]       = 1'b0;
      if (has_prov && pcpn_in[1:0] == 2'(i)) begin
        cnt_we[i]    = 1'b1;
        cnt_wdata[i] = real_dir ? ((rd_cnt[i] == 3'd7) ? 3'd7 : rd_cnt[i] + 3'd1)
                                : ((rd_cnt[i] == 3'd0) ? 3'd0 : rd_cnt[i] - 3'd1);
        if (!alt_used) begin
          useful_we[i]    = 1'b1;
          useful_wdata[i] = (pred_in == real_dir) ? inc2(rd_useful[i]) : dec2(rd_useful[i]);
        end else if (!prov_correct && alt_correct) begin
          useful_we[i]    = 1'b1;
          useful_wdata[i] = dec2(rd_useful[i]);
        end
      end
      if (alloc && !found_j && in_range[i]) begin
        useful_we[i]    = 1'b1;
        useful_wdata[i] = dec2(rd_useful[i]);
      end
      if (alloc && found_j && target_onehot[i]) begin
        tag_we[i]       = 1'b1;
        cnt_we[i]       = 1'b1;
        cnt_wdata[i]    = real_dir ? 3'd4 : 3'd3;
        useful_we[i]    = 1'b1;
        useful_wdata[i] = 2'd0;
      end
    end
  end

  // Ref: tage_update_comb, 3. periodic clearing of one useful row (every 2048 updates)
  always_comb begin
    reset_cnt_next = reset_cnt + 24'd1;
    reset_row      = reset_cnt[11 +: T_IDX_W];
  end

  always_comb begin
    for (int i = 0; i < TN; i++) begin
      reset_we[i]    = (reset_cnt[10:0] == 11'd0) && !(useful_we[i] && (idx_in[i] == reset_row));
      reset_wdata[i] = reset_cnt[23] ? {1'b0, reset_row_useful[i][0]} : {reset_row_useful[i][1], 1'b0};
    end
  end

endmodule

`default_nettype wire
