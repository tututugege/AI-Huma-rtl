// Ref: back-end/include/FpStats.h  FpStats::try_reserve; back-end/Isu.cpp  comb_issue (grant_gate)  (EXP-032)
`default_nettype none

// FP register-file write-port limit using a shift-register busy table indexed by (cycles-from-now - 1),
// mirroring EXP-046's isu_wb_gate. Eliminates the 64-entry ring, 6-bit now_q adders, and 64:1 read muxes.
module isu_fp_gate
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int NC = 5,                 // candidates: grant ports that can write the FP file (multi-cycle latency)
  parameter int P  = FP_WB_PORTS        // write ports per cycle (0: no limit)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          flush_all,      // the reference clears every reservation on a global flush
  input  logic [NC-1:0] cand_valid,     // candidate is granted by its queue (before this gate)
  input  logic [NC-1:0] cand_fpw,       // ... and writes the FP register file (dest_en & dest_fp & an FP-unit op)
  input  logic [WB_CLS_W-1:0] cand_cls [NC],   // completion class of the candidate (its write latency is a constant of the class)
  output logic [NC-1:0] gate_ok         // candidate may issue (not an FP write, or a port is free in its cycle)
);

  localparam int DEPTH = FP_EN ? FP_FSQRT_D_LAT : 2;
  localparam int CNT_W = $clog2(P + 2);

  // busy_q[d] = number of reserved FP write ports (d + 1) cycles from now (d = 0 .. DEPTH - 1)
  logic [CNT_W-1:0] busy_q [DEPTH];
  logic [NC-1:0]    req, granted;
  logic [WB_NCLS-1:0] cls_1h [NC];
  logic [CNT_W-1:0] occ0 [NC];
  logic [NC-1:0]    same_slot [NC];

  assign req = cand_valid & cand_fpw;

  // One-hot decode of cand_cls (only FP-writing classes 4..10 are ever active when req[k] = 1)
  for (genvar k = 0; k < NC; k++) begin : g_dec
    for (genvar c = 0; c < WB_NCLS; c++) begin : g_c
      assign cls_1h[k][c] = (cand_cls[k] == WB_CLS_W'(c));
    end
  end

  // Direct constant-index lookup from shift-register busy_q (zero adder / 64:1 mux)
  for (genvar k = 0; k < NC; k++) begin : g_occ
    always_comb begin
      occ0[k] = '0;
      for (int c = 0; c < WB_NCLS; c++) begin
        if (fp_cls_lat(c) > 0 && cls_1h[k][c]) occ0[k] = busy_q[fp_cls_lat(c) - 1];
      end
    end
    for (genvar j = 0; j < NC; j++) begin : g_same
      always_comb begin
        same_slot[k][j] = 1'b0;
        if (j < k) begin
          for (int c1 = 0; c1 < WB_NCLS; c1++)
            for (int c2 = 0; c2 < WB_NCLS; c2++)
              if (fp_cls_lat(c1) > 0 && fp_cls_lat(c1) == fp_cls_lat(c2))
                same_slot[k][j] = same_slot[k][j] | (cls_1h[k][c1] & cls_1h[j][c2]);
        end
      end
    end
  end

  for (genvar k = 0; k < NC; k++) begin : g_gate
    logic [NC-1:0] same;
    logic [CNT_W-1:0] n_same;
    assign same = req & same_slot[k];
    ttg_popcount #(.N(NC), .CW(CNT_W)) u_same (.bits(same), .count(n_same));
    assign gate_ok[k] = !req[k] || (P == 0) || ((occ0[k] + n_same) < CNT_W'(P));
    assign granted[k] = req[k] && gate_ok[k];
  end

  // Shift down by 1 every cycle, adding grants that target (d + 2) cycles from now into next busy_q[d]
  for (genvar d = 0; d < DEPTH; d++) begin : g_shift
    if (d + 1 < DEPTH) begin : g_mid
      logic [NC-1:0]    hit;
      logic [CNT_W-1:0] n_hit;
      for (genvar k = 0; k < NC; k++) begin : g_hit
        always_comb begin
          hit[k] = 1'b0;
          for (int c = 0; c < WB_NCLS; c++)
            if (fp_cls_lat(c) == d + 2) hit[k] = hit[k] | (granted[k] & cls_1h[k][c]);
        end
      end
      ttg_popcount #(.N(NC), .CW(CNT_W)) u_hit (.bits(hit), .count(n_hit));
      always_ff @(posedge clk) begin
        if (!rst_n || flush_all) busy_q[d] <= '0;
        else                     busy_q[d] <= busy_q[d + 1] + n_hit;
      end
    end else begin : g_top
      always_ff @(posedge clk) begin
        if (!rst_n || flush_all) busy_q[d] <= '0;
        else                     busy_q[d] <= '0;
      end
    end
  end

endmodule

`default_nettype wire
