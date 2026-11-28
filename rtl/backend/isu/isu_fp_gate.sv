// Ref: back-end/include/FpStats.h  FpStats::try_reserve; back-end/Isu.cpp  comb_issue (grant_gate)  (EXP-032)
`default_nettype none

// FP register-file write-port limit using a shift-register busy table indexed by (cycles-from-now - 1),
// mirroring EXP-046's isu_wb_gate. Eliminates the 64-entry ring, 6-bit now_q adders, and 64:1 read muxes.
// The gate and the busy-table update are written for FP_WB_PORTS == 2 write ports per cycle (the free1 / free2 tests).
module isu_fp_gate
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int NC = 5                  // candidates: grant ports that can write the FP file (multi-cycle latency)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          flush_all,      // the reference clears every reservation on a global flush
  input  logic [LSU_LDU_COUNT-1:0] cancel_valid,
  input  logic [NC-1:0] cand_valid,     // candidate is granted by its queue (before this gate)
  input  logic [NC-1:0] cand_fpw,       // ... and writes the FP register file (dest_en & dest_fp & an FP-unit op)
  input  logic [LSU_LDU_COUNT-1:0] cand_spec_mask [NC],
  input  logic [WB_NCLS-1:0] cand_cls_1h [NC], // pre-decoded one-hot completion class of the candidate
  input  logic [NC-1:0] cand_f1,        // pre-evaluated per-slot free1 (eff_busy[lat-1] < 2), parallel with u_read
  output logic [6:0]    fp_free1_cls,   // registered per-class (4..10) eff_busy[lat-1] < 2 (ready at layer 1)
  output logic [NC-1:0] gate_ok         // candidate may issue (not an FP write, or a port is free in its cycle)
);

  localparam int DEPTH = FP_FSQRT_D_LAT + 1;
  localparam int CNT_W = $clog2(FP_WB_PORTS + 2);

  // busy_q[d] = number of reserved FP write ports (d + 1) cycles from now (d = 0 .. DEPTH - 1)
  // Packed vector prevents Yosys memory_share from inferring a multi-port memory on busy_q.
  logic [DEPTH-1:0][CNT_W-1:0] busy_q, eff_busy;
  logic [NC-1:0]               req;
  logic [DEPTH-1:0]            lat_1h [NC];
  logic [NC-1:0]               spec_v_q, cancel_k;
  logic [LSU_LDU_COUNT-1:0]    spec_mask_q [NC];
  logic [DEPTH-1:0]            spec_lat_q [NC];
  logic [10:8]                 fp_free2_cls;   // per shared class (8..10): eff_busy[lat-1] == 0

  always_comb begin
    for (int k = 0; k < NC; k++) cancel_k[k] = spec_v_q[k] && (|(spec_mask_q[k] & cancel_valid));
    for (int d = 0; d < DEPTH; d++) begin
      logic [NC-1:0]    hit_d;
      logic [CNT_W-1:0] cn_d;
      cn_d = '0;
      for (int k = 0; k < NC; k++) begin
        hit_d[k] = cancel_k[k] && spec_lat_q[k][d];
        cn_d     = cn_d + CNT_W'(hit_d[k]);
      end
      eff_busy[d] = busy_q[d] - cn_d;
    end
  end

  assign req = cand_valid & cand_fpw;

  // Direct map from pre-decoded one-hot class to latency bitmask lat_1h[k][d] (d = lat - 1)
  for (genvar k = 0; k < NC; k++) begin : g_dec
    for (genvar d = 0; d < DEPTH; d++) begin : g_lat
      always_comb begin
        lat_1h[k][d] = 1'b0;
        for (int c = 0; c < WB_NCLS; c++)
          if (fp_cls_lat(c) == d + 1) lat_1h[k][d] = lat_1h[k][d] | cand_cls_1h[k][c];
      end
    end
  end

  // Per-class (c = 4..10) free1 flags of the registered table, exported so isu_iq can pre-evaluate f1 per slot before
  // u_read; free2 is only needed for the classes that can appear on several ports (8..10)
  for (genvar ci = 0; ci < 7; ci++) begin : g_fcls
    localparam int C = 4 + ci;
    localparam int L = fp_cls_lat(C);
    if (L > 0) begin : g_on
      assign fp_free1_cls[ci] = (eff_busy[L - 1] < CNT_W'(2));
      if (C >= 8) begin : g_f2
        assign fp_free2_cls[C] = (eff_busy[L - 1] == '0);
      end
    end else begin : g_off
      assign fp_free1_cls[ci] = 1'b1;
      if (C >= 8) begin : g_f2
        assign fp_free2_cls[C] = 1'b1;
      end
    end
  end

  // Re-associate gate_ok so per-class (c = 8, 9, 10) prior-port conflict checks depend ONLY on j < k
  // (ready ~8 layers before port k=4 finishes u_read_fpc), leaving only 3 gate levels after cand_cls_1h[k].
  for (genvar k = 0; k < NC; k++) begin : g_gate
    logic [10:8] cls_ok;
    for (genvar c = 8; c <= 10; c++) begin : g_cok
      logic [NC-1:0] hit_c;
      logic          any_c, two_c;
      for (genvar j = 0; j < NC; j++) begin : g_j
        if (j < k) begin : g_lt
          // Match all shared classes c2 with same WB latency as c (e.g. FMISC cls 9 & I2F cls 10 both lat=2)
          always_comb begin
            hit_c[j] = 1'b0;
            for (int c2 = 8; c2 <= 10; c2++)
              if (fp_cls_lat(c) > 0 && fp_cls_lat(c2) == fp_cls_lat(c))
                hit_c[j] = hit_c[j] | (req[j] & cand_cls_1h[j][c2]);
          end
        end else begin : g_ge
          assign hit_c[j] = 1'b0;
        end
      end
      assign any_c = |hit_c;
      always_comb begin
        two_c = 1'b0;
        for (int a = 0; a < k; a++)
          for (int b = a + 1; b < k; b++)
            two_c = two_c | (hit_c[a] & hit_c[b]);
      end
      assign cls_ok[c] = (fp_free1_cls[c - 4] && !any_c) || (fp_free2_cls[c] && !two_c);
    end
    logic is_shared;
    assign is_shared  = |cand_cls_1h[k][10:8];
    assign gate_ok[k] = !req[k] || (|(cand_cls_1h[k][10:8] & cls_ok)) || (!is_shared && cand_f1[k]);
  end

  // Shift down by 1 every cycle, adding reservations targeting (d + 2) cycles from now into next busy_q[d].
  // Because grants are greedy up to 2, next_busy[d] = min(2, eff_busy[d+1] + popcount(req targeting d+2)),
  // completely decoupled from gate_ok[k].
  for (genvar d = 0; d < DEPTH; d++) begin : g_shift
    if (d + 1 < DEPTH) begin : g_mid
      logic [NC-1:0]    lat_req;
      logic             any_req, two_req;
      logic [CNT_W-1:0] next_busy;
      for (genvar k = 0; k < NC; k++) begin : g_lr
        assign lat_req[k] = req[k] & lat_1h[k][d + 1];
      end
      always_comb begin
        any_req = |lat_req;
        two_req = 1'b0;
        for (int a = 0; a < NC; a++)
          for (int b = a + 1; b < NC; b++)
            two_req = two_req | (lat_req[a] & lat_req[b]);
        if (eff_busy[d + 1] == '0)             next_busy = two_req ? CNT_W'(2) : (any_req ? CNT_W'(1) : '0);
        else if (eff_busy[d + 1] == CNT_W'(1)) next_busy = any_req ? CNT_W'(2) : CNT_W'(1);
        else                                   next_busy = eff_busy[d + 1];
      end
      always_ff @(posedge clk) begin
        if (!rst_n || flush_all) busy_q[d] <= '0;
        else                     busy_q[d] <= next_busy;
      end
    end else begin : g_top
      always_ff @(posedge clk) begin
        if (!rst_n || flush_all) busy_q[d] <= '0;
        else                     busy_q[d] <= '0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush_all) begin
      spec_v_q <= '0;
      for (int k = 0; k < NC; k++) begin
        spec_mask_q[k] <= '0;
        spec_lat_q[k]  <= '0;
      end
    end else begin
      for (int k = 0; k < NC; k++) begin
        spec_v_q[k]    <= req[k] && gate_ok[k] && (|cand_spec_mask[k]);
        spec_mask_q[k] <= cand_spec_mask[k];
        spec_lat_q[k]  <= {1'b0, lat_1h[k][DEPTH - 1 : 1]};
      end
    end
  end

endmodule

`default_nettype wire
