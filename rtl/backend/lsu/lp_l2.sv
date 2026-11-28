// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_dcache2lsu_ldq_p: L2a STQ CAM + L2b registered STLF confirm)
`default_nettype none

// L2 of the staged LSU, split into L2a and L2b:
//   - L2a runs 64-entry STQ CAM on purely registered pl12_q and sq in parallel with the DCache response.
//     Non-STLF loads (~93%) complete in 0 extra cycles (L2_DCW -> same-cycle DCache hit);
//     STLF hits (~7%) latch into pl2b_q for next cycle's confirm (leaving LDQ state LS_PIPE).
//   - L2b runs stlf_confirm + extract_data on registered pl2b_q (zero CAM on stlf_confirm / lp_wk / fwd_data).
module lp_l2
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
  import memcpu_pkg::REPLAY_CONFLICT, memcpu_pkg::replay_wait;
(
  input  logic                clk,
  input  logic                rst_n,
  input  lp_pl12_t            pl12 [NLD],
  input  logic [LQ-1:0]       l2_ok,
  input  lp_stq_t             sq [SQ],
  input  logic [SQW-1:0]      head_q,
  input  logic                head_flag_q,
  input  logic [CNTW-1:0]     count_q,
  input  logic [SQ-1:0]       alive_w,
  output lp_pl2b_t            pl2b_q [NLD],
  output logic [NLD-1:0]      cam_en,
  output logic [NLD-1:0]      cam_unk,
  output lp_l2dec_t           dec_a [NLD],
  output lp_l2dec_t           dec_b [NLD],
  output logic [NLD-1:0]      wbd_l2b,
  output logic [XLEN_BITS-1:0] fwd_data [NLD]
);

  lp_pl2b_t pl2b_d [NLD];

  for (genvar p = 0; p < NLD; p++) begin : g_port
    // ---- L2b: registered STLF confirm (zero CAM on this path) ----
    logic        s_supp, s_va, s_pa, s_dv, s_hold;
    logic [11:0] s_voff;
    logic [31:0] s_paddr;
    logic [XLEN_BITS-1:0] s_data;
    logic [2:0]  s_f3;
    lp_conf_t    conf;
    logic [OW-1:0] off;

    assign s_supp  = sq[pl2b_q[p].cand].suppress;
    assign s_va    = sq[pl2b_q[p].cand].va_v;
    assign s_voff  = sq[pl2b_q[p].cand].vaddr[11:0];
    assign s_pa    = sq[pl2b_q[p].cand].pa_v;
    assign s_paddr = sq[pl2b_q[p].cand].paddr;
    assign s_f3    = sq[pl2b_q[p].cand].func3;
    assign s_dv    = sq[pl2b_q[p].cand].data_v;
    assign s_hold  = sq[pl2b_q[p].cand].lrsc && !sq[pl2b_q[p].cand].sc_pass;
    assign s_data  = sq[pl2b_q[p].cand].data;

    assign conf = stlf_confirm_pre_l(pl2b_q[p].voff, pl2b_q[p].paddr, pl2b_q[p].paddr_p1, pl2b_q[p].paddr_m1,
                                     pl2b_q[p].func3, alive_w[pl2b_q[p].cand], s_supp, s_va, s_voff, s_pa,
                                     s_paddr, s_f3, s_dv, s_hold);
    assign off         = pl2b_q[p].paddr[OW-1:0] - s_paddr[OW-1:0];
    assign fwd_data[p] = extract_data(s_data, off, pl2b_q[p].func3);

    always_comb begin
      dec_b[p]     = '0;
      dec_b[p].act = L2_NONE;
      if (pl2b_q[p].v) begin
        case (conf)
          CF_REPLAY: dec_b[p].act = L2_RDY;
          CF_NOADDR: begin
            dec_b[p].act   = L2_PARK;
            dec_b[p].cause = RC_ADDR;
            dec_b[p].blk   = pl2b_q[p].cand;
          end
          CF_HOLD: begin
            dec_b[p].act   = L2_PARK;
            dec_b[p].cause = RC_HOLD;
            dec_b[p].blk   = pl2b_q[p].cand;
          end
          CF_DATA: begin
            dec_b[p].act    = L2_PARK;
            dec_b[p].cause  = RC_DATA;
            dec_b[p].blk    = pl2b_q[p].cand;
            dec_b[p].wait_c = RWW'(off);
          end
          default: dec_b[p].act = L2_WBD;
        endcase
      end
    end
    assign wbd_l2b[p] = (dec_b[p].act == L2_WBD) && l2_ok[pl2b_q[p].ldq];

    // ---- L2a: STQ CAM + fast-path decision (non-STLF = 0 extra cycles; STLF latches into pl2b_q) ----
    logic           en, cv, cu, cand_v;
    logic [SQW-1:0] ci;

    assign en = pl12[p].v && (pl12[p].tlb == PL12_TLB_HIT) && !pl12[p].mmio;
    lp_cam u_cam (
      .voff(pl12[p].voff), .func3(pl12[p].func3), .paddr(pl12[p].paddr),
      .paddr_p1(pl12[p].paddr_p1), .paddr_m1(pl12[p].paddr_m1),
      .snap_idx(pl12[p].snap_idx), .snap_flag(pl12[p].snap_flag),
      .head(head_q), .head_flag(head_flag_q), .count(count_q), .sq(sq),
      .spec_ok(pl12[p].spec_ok), .cand_v(cv), .cand(ci), .unk(cu)
    );
    assign cam_en[p]  = en;
    assign cam_unk[p] = cu;
    assign cand_v     = en && cv;

    always_comb begin
      dec_a[p]     = '0;
      dec_a[p].act = L2_NONE;
      pl2b_d[p]    = '0;
      if (pl12[p].v) begin
        if (pl12[p].tlb == PL12_TLB_PF) begin
          dec_a[p].act = wbd_l2b[p] ? L2_WBP : L2_WBD;
        end else if (pl12[p].tlb == PL12_TLB_MISS) begin
          dec_a[p].act   = L2_PARK;
          dec_a[p].cause = RC_TLB;
        end else if (pl12[p].mmio) begin
          dec_a[p].act = L2_MMW;
        end else if (!cand_v) begin
          if (pl12[p].dcblk) begin
            dec_a[p].act    = L2_PARK;
            dec_a[p].cause  = RC_DC;
            dec_a[p].wait_c = replay_wait(REPLAY_CONFLICT);
          end else if (pl12[p].bloom) begin
            dec_a[p].act = L2_RDY;
          end else begin
            dec_a[p].act = L2_DCW;
          end
        end else begin
          // STLF candidate: latch into pl2b_q for next cycle's confirm
          pl2b_d[p].v        = l2_ok[pl12[p].ldq];
          pl2b_d[p].ldq      = pl12[p].ldq;
          pl2b_d[p].epoch    = pl12[p].epoch;
          pl2b_d[p].cand     = ci;
          pl2b_d[p].paddr    = pl12[p].paddr;
          pl2b_d[p].paddr_p1 = pl12[p].paddr_p1;
          pl2b_d[p].paddr_m1 = pl12[p].paddr_m1;
          pl2b_d[p].voff     = pl12[p].voff;
          pl2b_d[p].func3    = pl12[p].func3;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int p = 0; p < NLD; p++) begin
      if (!rst_n) pl2b_q[p] <= '0;
      else        pl2b_q[p] <= pl2b_d[p];
    end
  end

endmodule

`default_nettype wire
