// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LSU_PIPE_L2 bits 2 and 8: early wake, speculative wake and cancel)
`default_nettype none

// Wake-ups of the load consumers driven by the LSU (channels: [p] L2 speculative, [NLD+p] L3 register) and the cancel
// of a wrong speculative wake-up (registered, applied at the start of the next cycle before the select).
//   LP_L2[1] (a2): a load written back from the L3 register wakes its consumers in the cycle of the write-back
//                  request.
//   LP_L2[3] (d) : the load of the L1/L2 register whose hit was predicted at L1 (TLB hit, no MMIO, no CAM candidate,
//                  no hidden-retry block) wakes its consumers; if the DCache does not answer HIT in this cycle the
//                  wake-up is cancelled in the next one.  A load woken speculatively and completed at L2 does not
//                  wake again at L3.
module lp_wake
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [BRW-1:0]      dec_br_mask,
  input  lp_pl12_t            pl12 [NLD],
  input  logic [LQ-1:0]       l2_ok,                 // entry of the L1/L2 register still PIPE, same epoch
  input  lp_ldq_t             ldq_q [LQ],
  input  logic [NLD-1:0]      wbd_v,                 // direct completions decided at L2 (before L3)
  input  logic [LQW-1:0]      wbd_idx [NLD],
  input  logic [NLD-1:0]      wbw_v,                 // write-back requests of this cycle
  input  logic [LQW-1:0]      wbw_idx [NLD],
  output logic [2*NLD-1:0]    wk_valid,
  output logic [PRFW-1:0]     wk_preg [2*NLD],
  output logic [NLD-1:0]      cn_valid,
  output logic [PRFW-1:0]     cn_preg [NLD]
);

  logic [NLD-1:0] spec_w, l3_sw_q;
  logic [NLD-1:0] cn_q;
  logic [PRFW-1:0] cn_preg_q [NLD];

  always_comb begin
    wk_valid = '0;
    for (int k = 0; k < 2 * NLD; k++) wk_preg[k] = '0;
    spec_w = '0;
    for (int p = 0; p < NLD; p++) begin
      // L2 speculative wake-up (d)
      if ((LP_L2 & 8) != 0) begin
        spec_w[p] = pl12[p].v && l2_ok[pl12[p].ldq] && pl12[p].tlb == TLB_HIT && !pl12[p].mmio &&
                    !pl12[p].cand_v && !pl12[p].dcblk && ldq_q[pl12[p].ldq].dest_preg != '0 && !flush &&
                    !(mispred && (ldq_q[pl12[p].ldq].br_mask & dec_br_mask) != '0);
        wk_valid[p] = spec_w[p];
        wk_preg[p] = ldq_q[pl12[p].ldq].dest_preg;
      end
      // L3 wake-up (a2): not for a load that was woken speculatively
      if ((LP_L2 & 3) == 3) begin
        wk_valid[NLD + p] = wbw_v[p] && !l3_sw_q[p] && !(MS && ldq_q[wbw_idx[p]].second) &&
                            ldq_q[wbw_idx[p]].dest_preg != '0 && !flush &&
                            !(mispred && (ldq_q[wbw_idx[p]].br_mask & dec_br_mask) != '0);
        wk_preg[NLD + p] = ldq_q[wbw_idx[p]].dest_preg;
      end
    end
  end

  // cancel register: predicted-hit load that did not complete directly this cycle; sw flag of the L3 register
  always_ff @(posedge clk) begin
    for (int p = 0; p < NLD; p++) begin
      cn_q[p] <= rst_n && spec_w[p] && !(wbd_v[p] && wbd_idx[p] == pl12[p].ldq);
      cn_preg_q[p] <= ldq_q[pl12[p].ldq].dest_preg;
      l3_sw_q[p] <= rst_n && spec_w[p] && wbd_v[p] && wbd_idx[p] == pl12[p].ldq;
    end
  end
  assign cn_valid = cn_q;
  always_comb begin
    for (int p = 0; p < NLD; p++) cn_preg[p] = cn_preg_q[p];
  end

endmodule

`default_nettype wire
