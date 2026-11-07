// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_dcache2lsu_ldq_p: L2 decision of PL12, stlf_confirm)
`default_nettype none

// L2 of the staged LSU: per load port, the decision for the load of the L1/L2 register (the LDQ entry still checks
// state PIPE + epoch).  STLF confirm reads the registered STQ entry of the CAM candidate with the full physical
// address.
module lp_l2
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  lp_pl12_t            pl12 [NLD],
  input  lp_stq_t             sq [SQ],
  input  logic [SQ-1:0]       alive_w,
  output lp_l2dec_t           dec [NLD],
  output logic [31:0]         fwd_data [NLD]
);

  for (genvar p = 0; p < NLD; p++) begin : g_port
    logic        s_supp, s_va, s_pa, s_dv, s_hold;
    logic [11:0] s_voff;
    logic [31:0] s_paddr, s_data;
    logic [2:0]  s_f3;
    lp_conf_t    conf;
    logic [1:0]  off;
    logic [31:0] raw;
    assign s_supp = sq[pl12[p].cand].suppress;
    assign s_va = sq[pl12[p].cand].va_v;
    assign s_voff = sq[pl12[p].cand].vaddr[11:0];
    assign s_pa = sq[pl12[p].cand].pa_v;
    assign s_paddr = sq[pl12[p].cand].paddr;
    assign s_f3 = sq[pl12[p].cand].func3;
    assign s_dv = sq[pl12[p].cand].data_v;
    assign s_hold = sq[pl12[p].cand].lrsc && !sq[pl12[p].cand].sc_pass;
    assign s_data = sq[pl12[p].cand].data;
    assign conf = stlf_confirm(pl12[p].voff, pl12[p].paddr, pl12[p].func3, alive_w[pl12[p].cand], s_supp, s_va,
                               s_voff, s_pa, s_paddr, s_f3, s_dv, s_hold);
    assign off = pl12[p].paddr[1:0] - s_paddr[1:0];
    assign raw = s_data;
    assign fwd_data[p] = lsu_pkg::extract_data(raw, off, pl12[p].func3);

    always_comb begin
      dec[p] = '0;
      dec[p].act = L2_NONE;
      if (pl12[p].v) begin
        if (pl12[p].tlb == TLB_PF) begin
          dec[p].act = L2_WBD;
        end else if (pl12[p].tlb == TLB_MISS) begin
          dec[p].act = L2_PARK;
          dec[p].cause = RC_TLB;
        end else if (pl12[p].mmio) begin
          dec[p].act = L2_MMW;
        end else if (!pl12[p].cand_v) begin
          if (pl12[p].dcblk) begin
            dec[p].act = L2_PARK;
            dec[p].cause = RC_DC;
            dec[p].wait_c = replay_wait(RT_CONFLICT);
          end else begin
            dec[p].act = L2_DCW;
          end
        end else begin
          case (conf)
            CF_REPLAY: dec[p].act = L2_RDY;
            CF_NOADDR: begin
              dec[p].act = L2_PARK;
              dec[p].cause = RC_ADDR;
              dec[p].blk = pl12[p].cand;
            end
            CF_HOLD: begin
              dec[p].act = L2_PARK;
              dec[p].cause = RC_HOLD;
              dec[p].blk = pl12[p].cand;
            end
            CF_DATA: begin
              dec[p].act = L2_PARK;
              dec[p].cause = RC_DATA;
              dec[p].blk = pl12[p].cand;
              dec[p].wait_c = RWW'(off);
            end
            default: dec[p].act = L2_WBD;
          endcase
        end
      end
    end
  end

endmodule

`default_nettype wire
