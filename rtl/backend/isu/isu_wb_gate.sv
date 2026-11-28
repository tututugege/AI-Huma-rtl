// Ref: back-end/Isu.cpp  comb_issue (grant_gate) and WbBusy (EXP-035)
`default_nettype none

// Completion-cycle reservation of the issue ports. A port completes one uop per cycle (one ROB / write-back
// entry), and the cycle in which a granted uop completes is known at issue (issue cycle + offset), so a grant
// reserves (port, cycle) (like XiangShan's WbFuBusyTable). A port grants at most one uop per cycle, so the picks
// of different ports never share a reservation and each port's check depends on its own table only.
// Table (EXP-046): per port a shift register indexed by "cycles from now": bit k = the cycle now + k is taken. It
// shifts down by one every cycle, a grant of offset k sets bit k - 1 of the next cycle. Only a uop of a longer
// offset issued earlier can take a cycle, so a port needs bits 1 .. port_max_off - 1 and the classes that cannot be
// blocked (isu_pkg cls_blockable: the longest one of the port, every class of a one-class port) are constant free.
// Same behaviour as the reference's 64-entry ring (WbBusy).
module isu_wb_gate
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   flush_all,        // every reservation is cleared on a global flush
  input  logic [LSU_LDU_COUNT-1:0] cancel_valid,
  input  logic [WB_NCLS-1:0]     cls_1h [ISSUE_WIDTH], // one-hot completion class of each port's pick
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: a port whose classes all have offset 1 keeps no table
  input  logic [ISSUE_WIDTH-1:0] reserve,          // the port's pick is granted (after every gate)
  input  logic [LSU_LDU_COUNT-1:0] reserve_spec_mask [ISSUE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [WB_NCLS-1:0]     cls_free [ISSUE_WIDTH]   // per port and class: that class's completion cycle is free (registered only)
);

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam int M = port_max_off(p);       // the table holds offsets 1 .. M - 1
    /* verilator lint_off UNUSEDSIGNAL */   // waiver: bit 0 (and the whole vector on a port without blockable classes) is not read
    logic [M:0] busy;                         // busy[k]: the cycle now + k is taken (bits 0 and M are always 0)
    /* verilator lint_on UNUSEDSIGNAL */
    for (genvar c = 0; c < WB_NCLS; c++) begin : g_cls
      if (cls_wb_blockable(p, c)) begin : g_tab
        assign cls_free[p][c] = !busy[wb_cls_off(c)];   // offset < M: a longer class exists
      end else begin : g_free
        assign cls_free[p][c] = 1'b1;
      end
    end
    assign busy[0] = 1'b0;
    assign busy[M] = 1'b0;
    if (M >= 2) begin : g_q
      logic [M-1:1]             busy_q, eff_busy_q, set_d;
      logic                     spec_v_q, spec_cancel, has_multi_cls;
      logic [LSU_LDU_COUNT-1:0] spec_mask_q;
      logic [M-1:1]             spec_bit_q;
      always_comb begin
        spec_cancel   = spec_v_q && (|(spec_mask_q & cancel_valid));
        eff_busy_q    = spec_cancel ? (busy_q & ~spec_bit_q) : busy_q;
        has_multi_cls = 1'b0;
        for (int c = 1; c < WB_NCLS; c++) begin
          if (port_serves_cls(p, c) && (wb_cls_off(c) >= 2))
            has_multi_cls = has_multi_cls | cls_1h[p][c];
        end
      end
      for (genvar k = 1; k < M; k++) begin : g_set
        always_comb begin
          set_d[k] = 1'b0;
          for (int c = 1; c < WB_NCLS; c++) begin
            if (port_serves_cls(p, c) && (wb_cls_off(c) == k + 1))
              set_d[k] = set_d[k] | (reserve[p] & cls_1h[p][c]);
          end
        end
      end
      always_ff @(posedge clk) begin
        if (!rst_n || flush_all) begin
          busy_q      <= '0;
          spec_v_q    <= 1'b0;
          spec_mask_q <= '0;
          spec_bit_q  <= '0;
        end else begin
          busy_q      <= busy[M:2] | set_d;   // shift down by one, plus this cycle's grant
          spec_v_q    <= reserve[p] && (|reserve_spec_mask[p]) && has_multi_cls;
          spec_mask_q <= reserve_spec_mask[p];
          spec_bit_q  <= set_d;
        end
      end
      assign busy[M-1:1] = eff_busy_q;
    end
  end

endmodule

`default_nettype wire
