`default_nettype none
// Ref: MemSubSystem/include/DataPrefetcher.h  BertiHw (hist[8][16] dedup, infl[16], pfi[16], pfl[64], srchq[4])
// History table, latency measurement CAMs, and 16-way timely-delta search with deduplication for hardware Berti.
module dcache_pf_berti_hist
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [19:0]          cyc_q,
  // prefetch issue timing (reqq head taken & !llc)
  input  logic                 pfi_en,
  input  logic [LINE_W-1:0]    pfi_pline,
  // cache fill timing (dcache_s2_fill)
  input  logic                 fill_valid,
  input  logic [LINE_W-1:0]    fill_pline,
  input  logic                 fill_is_pf,
  // 1 training event per cycle (popped from trn_q)
  input  logic                 trn_v,
  input  logic                 trn_miss,
  input  logic [31:0]          trn_pc,
  input  logic [31:0]          trn_vline,
  input  logic [LINE_W-1:0]    trn_pline,
  // 1 search output per cycle (head of srch_q -> dcache_pf_berti_tab; gated by srch_stall for 2-stage tab)
  input  logic                 srch_stall,
  output logic                 srch_v,
  output logic [31:0]          srch_pc,
  output logic [15:0]          srch_uniq,
  output logic signed [6:0]    srch_d [16]
);
  localparam int HSETS   = 8;
  localparam int HWAYS   = 16;
  localparam int INFL_N  = 16;
  localparam int PFI_N   = 16;
  localparam int PFL_N   = 64;
  localparam int SRCHQ_N = 4;

  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] line;
    logic [19:0] t;
  } hist_e_t;

  typedef struct packed {
    logic [LINE_W-1:0] pline;
    logic [31:0]       vline;
    logic [31:0]       pc;
    logic [19:0]       t;
  } infl_e_t;

  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] line;
    logic [19:0] t_dem;
    logic [11:0] lat;
  } srch_e_t;

  // ---------------- state ----------------
  logic [HWAYS-1:0]  hist_v_q [HSETS];
  hist_e_t           hist_q   [HSETS][HWAYS];
  logic [3:0]        hptr_q   [HSETS];

  logic [INFL_N-1:0] infl_v_q;
  infl_e_t           infl_q   [INFL_N];
  logic [3:0]        infl_ptr_q;

  logic [PFI_N-1:0]  pfi_v_q;
  logic [LINE_W-1:0] pfi_line_q [PFI_N];
  logic [19:0]       pfi_t_q    [PFI_N];
  logic [3:0]        pfi_ptr_q;

  logic [PFL_N-1:0]  pfl_v_q;
  logic [LINE_W-1:0] pfl_line_q [PFL_N];
  logic [11:0]       pfl_lat_q  [PFL_N];
  logic [5:0]        pfl_ptr_q;

  srch_e_t           srchq_q [SRCHQ_N];
  logic [2:0]        srchq_n_q;

  function automatic logic [2:0] hset(input logic [8:0] pc9);
    return pc9[2:0] ^ pc9[5:3] ^ pc9[8:6];
  endfunction

  function automatic logic [11:0] clamp12(input logic [19:0] diff);
    return (diff > 20'd4095) ? 12'd4095 : diff[11:0];
  endfunction

  // ---------------- 1. Combinational 16-way history search on srchq_q[0] ----------------
  logic [2:0]        sset;
  logic [HWAYS-1:0]  w_ok;
  logic signed [6:0] w_d [HWAYS];

  always_comb begin
    srch_v  = !srch_stall && (srchq_n_q != 3'd0);
    srch_pc = srchq_q[0].pc;
    sset    = hset(srchq_q[0].pc[9:1]);
    for (int w = 0; w < HWAYS; w++) begin
      logic [19:0] age;
      logic signed [31:0] d32;
      age = srchq_q[0].t_dem - hist_q[sset][w].t;
      d32 = $signed(srchq_q[0].line - hist_q[sset][w].line);
      w_ok[w] = srch_v && hist_v_q[sset][w] && (hist_q[sset][w].pc == srchq_q[0].pc) &&
                !age[19] && (age >= {8'b0, srchq_q[0].lat}) &&
                (d32 != 32'sd0) && (d32 > -32'sd64) && (d32 < 32'sd64);
      w_d[w]  = d32[6:0];
      srch_d[w] = d32[6:0];
    end
  end

  always_comb begin
    for (int w = 0; w < HWAYS; w++) begin
      logic dup;
      dup = 1'b0;
      for (int j = 0; j < w; j++) begin
        if (w_ok[j] && (w_d[j] == w_d[w])) dup = 1'b1;
      end
      srch_uniq[w] = w_ok[w] && !dup;
    end
  end

  // ---------------- 2. pf_issue + pf_lat + infl CAM lookups (decoupled: no physically impossible same-cycle issue->fill->hit bypass) ----------------
  logic [PFI_N-1:0]  pfi_hit_iss, pfi_hit_iss_oh, pfi_hit_fill, pfi_hit_fill_oh;
  logic              pfi_iss_any, pfi_fill_any;
  logic [3:0]        pfi_iss_idx, pfi_fill_idx;
  logic [19:0]       pfi_t_fill;

  always_comb begin
    for (int i = 0; i < PFI_N; i++) begin
      pfi_hit_iss[i]  = pfi_en && pfi_v_q[i] && (pfi_line_q[i] == pfi_pline);
      pfi_hit_fill[i] = fill_valid && fill_is_pf && pfi_v_q[i] && (pfi_line_q[i] == fill_pline);
    end
  end
  ttg_first_set #(.N(PFI_N)) u_pfi_iss (.req(pfi_hit_iss), .onehot(pfi_hit_iss_oh), .any(pfi_iss_any));
  ttg_onehot_to_idx #(.N(PFI_N), .IDXW(4)) u_pfi_iss_i (.onehot(pfi_hit_iss_oh), .idx(pfi_iss_idx));
  ttg_first_set #(.N(PFI_N)) u_pfi_fl (.req(pfi_hit_fill), .onehot(pfi_hit_fill_oh), .any(pfi_fill_any));
  ttg_onehot_to_idx #(.N(PFI_N), .IDXW(4)) u_pfi_fl_i (.onehot(pfi_hit_fill_oh), .idx(pfi_fill_idx));

  logic [11:0]       pf_fill_lat;
  logic [PFL_N-1:0]  pfl_hit_wr, pfl_hit_wr_oh, pfl_hit_rd, pfl_hit_rd_oh;
  logic              pfl_wr_any, pfl_rd_any;
  logic [5:0]        pfl_wr_idx, pfl_rd_idx;
  logic [11:0]       pfl_rd_lat;

  always_comb begin
    pfi_t_fill  = pfi_t_q[pfi_fill_idx];
    pf_fill_lat = clamp12(cyc_q - pfi_t_fill);
    for (int k = 0; k < PFL_N; k++) begin
      pfl_hit_wr[k] = pfi_fill_any && pfl_v_q[k] && (pfl_line_q[k] == fill_pline);
      pfl_hit_rd[k] = trn_v && !trn_miss && pfl_v_q[k] && (pfl_line_q[k] == trn_pline);
    end
  end
  ttg_first_set #(.N(PFL_N)) u_pfl_wr (.req(pfl_hit_wr), .onehot(pfl_hit_wr_oh), .any(pfl_wr_any));
  ttg_onehot_to_idx #(.N(PFL_N), .IDXW(6)) u_pfl_wr_i (.onehot(pfl_hit_wr_oh), .idx(pfl_wr_idx));
  ttg_first_set #(.N(PFL_N)) u_pfl_rd (.req(pfl_hit_rd), .onehot(pfl_hit_rd_oh), .any(pfl_rd_any));
  ttg_onehot_to_idx #(.N(PFL_N), .IDXW(6)) u_pfl_rd_i (.onehot(pfl_hit_rd_oh), .idx(pfl_rd_idx));

  always_comb begin
    pfl_rd_lat = pfl_lat_q[pfl_rd_idx];
  end

  // ---------------- 3. infl demand fill CAM + miss insert + history dedup ----------------
  logic [INFL_N-1:0] infl_hit_fl, infl_hit_fl_oh, infl_v_post_fl;
  logic              infl_fl_any, infl_have_trn, hist_dup;
  logic [3:0]        infl_fl_idx;
  logic [2:0]        tset;
  srch_e_t           srch_fl, srch_ph;

  always_comb begin
    for (int i = 0; i < INFL_N; i++) begin
      infl_hit_fl[i] = fill_valid && !fill_is_pf && infl_v_q[i] && (infl_q[i].pline == fill_pline);
    end
  end
  ttg_first_set #(.N(INFL_N)) u_infl_fl (.req(infl_hit_fl), .onehot(infl_hit_fl_oh), .any(infl_fl_any));
  ttg_onehot_to_idx #(.N(INFL_N), .IDXW(4)) u_infl_fl_i (.onehot(infl_hit_fl_oh), .idx(infl_fl_idx));

  always_comb begin
    infl_v_post_fl = infl_v_q & ~infl_hit_fl_oh;
    infl_have_trn = 1'b0;
    for (int i = 0; i < INFL_N; i++) begin
      if (infl_v_post_fl[i] && (infl_q[i].pline == trn_pline)) infl_have_trn = 1'b1;
    end
    tset = hset(trn_pc[9:1]);
    hist_dup = 1'b0;
    for (int w = 0; w < HWAYS; w++) begin
      if (hist_v_q[tset][w] && (hist_q[tset][w].pc == trn_pc) && (hist_q[tset][w].line == trn_vline)) hist_dup = 1'b1;
    end
    srch_fl = '{pc: infl_q[infl_fl_idx].pc, line: infl_q[infl_fl_idx].vline,
                t_dem: infl_q[infl_fl_idx].t, lat: clamp12(cyc_q - infl_q[infl_fl_idx].t)};
    srch_ph = '{pc: trn_pc, line: trn_vline, t_dem: cyc_q, lat: pfl_rd_lat};
  end

  // ---------------- 4. srchq next state (pop 1, push fill search, push pf_hit search) ----------------
  srch_e_t    srchq_d [SRCHQ_N];
  logic [2:0] srchq_n_d;

  always_comb begin
    logic [2:0] n;
    for (int i = 0; i < SRCHQ_N; i++) srchq_d[i] = srchq_q[i];
    n = srchq_n_q;
    if (!srch_stall && (n != 3'd0)) begin
      for (int i = 0; i < SRCHQ_N - 1; i++) srchq_d[i] = srchq_q[i + 1];
      n = n - 3'd1;
    end
    if (infl_fl_any && (n < 3'(SRCHQ_N))) begin
      srchq_d[n[1:0]] = srch_fl;
      n = n + 3'd1;
    end
    if (pfl_rd_any && (n < 3'(SRCHQ_N))) begin
      srchq_d[n[1:0]] = srch_ph;
      n = n + 3'd1;
    end
    srchq_n_d = n;
  end

  // ---------------- 5. Registers ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < HSETS; s++) begin
        hist_v_q[s] <= '0;
        hptr_q[s]   <= '0;
      end
      infl_v_q   <= '0;
      infl_ptr_q <= '0;
      pfi_v_q    <= '0;
      pfi_ptr_q  <= '0;
      pfl_v_q    <= '0;
      pfl_ptr_q  <= '0;
      srchq_n_q  <= '0;
    end else begin
      // pfi update
      if (pfi_en) begin
        if (pfi_iss_any) begin
          pfi_t_q[pfi_iss_idx] <= cyc_q;
        end else begin
          pfi_v_q[pfi_ptr_q]    <= 1'b1;
          pfi_line_q[pfi_ptr_q] <= pfi_pline;
          pfi_t_q[pfi_ptr_q]    <= cyc_q;
          pfi_ptr_q             <= pfi_ptr_q + 4'd1;
        end
      end
      if (pfi_fill_any) pfi_v_q[pfi_fill_idx] <= 1'b0;

      // pfl update
      if (pfi_fill_any) begin
        if (pfl_wr_any) begin
          pfl_lat_q[pfl_wr_idx] <= pf_fill_lat;
        end else begin
          pfl_v_q[pfl_ptr_q]    <= 1'b1;
          pfl_line_q[pfl_ptr_q] <= fill_pline;
          pfl_lat_q[pfl_ptr_q]  <= pf_fill_lat;
          pfl_ptr_q             <= pfl_ptr_q + 6'd1;
        end
      end
      if (pfl_rd_any) pfl_v_q[pfl_rd_idx] <= 1'b0;

      // infl update
      if (infl_fl_any) infl_v_q[infl_fl_idx] <= 1'b0;
      if (trn_v && trn_miss && !infl_have_trn) begin
        infl_v_q[infl_ptr_q] <= 1'b1;
        infl_q[infl_ptr_q]   <= '{pline: trn_pline, vline: trn_vline, pc: trn_pc, t: cyc_q};
        infl_ptr_q           <= infl_ptr_q + 4'd1;
      end

      // hist record (set-wide dedup)
      if (trn_v && !hist_dup) begin
        hist_v_q[tset][hptr_q[tset]] <= 1'b1;
        hist_q[tset][hptr_q[tset]]   <= '{pc: trn_pc, line: trn_vline, t: cyc_q};
        hptr_q[tset]                 <= hptr_q[tset] + 4'd1;
      end

      // srchq update
      srchq_n_q <= srchq_n_d;
      for (int i = 0; i < SRCHQ_N; i++) srchq_q[i] <= srchq_d[i];
    end
  end
endmodule

`default_nettype wire
