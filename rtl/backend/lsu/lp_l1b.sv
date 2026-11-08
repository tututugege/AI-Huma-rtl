// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_stlf_p partial CAM, comb_lsu2dcache_ldq_p, L1/L2 register)
`default_nettype none

// Second half of L1: partial STLF CAM of every load slot, the DCache read request (qualified by the CAM and by the
// hidden-retry bit of the port) and the L1/L2 register.
module lp_l1b
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  lp_l1in_t            l1 [NLD],
  input  logic                l_hit [NLD],
  input  logic                l_mmio [NLD],
  input  logic [31:0]         l_paddr [NLD],
  input  logic [1:0]          l_tlb [NLD],
  input  logic [NLD-1:0]      ld_retry_busy,
  input  logic [LQ-1:0]       pipe8,
  input  logic [EPW-1:0]      epoch_nx [LQ],
  input  logic [SQW-1:0]      head_q,
  input  logic                head_flag_q,
  input  logic [CNTW-1:0]     count_q,
  input  logic [SQ-1:0]       cv_va,
  input  logic [11:0]         cv_voff [SQ],
  input  logic [2:0]          cv_f3 [SQ],
  input  lp_stq_t             sq [SQ],
  input  logic [NLD-1:0]      spec_ok,         // memory speculation: the load of slot k may pass unknown-address stores
  output logic [NLD-1:0]      cam_en,          // slot k wrote its CAM result: spec flag update
  output logic [NLD-1:0]      cam_unk,
  output logic [NLD-1:0]      l1_launch,
  output logic [NLD-1:0]      dcl_req_valid,
  output logic [31:0]         dcl_req_addr [NLD],
  output logic [30:0]         dcl_req_id_o [NLD],
  output lp_pl12_t            pl12_q [NLD]
);

  logic            cam_v [NLD];
  logic [SQW-1:0]  cam_i [NLD];
  logic [NLD-1:0]  ok8, dcblk;
  for (genvar k = 0; k < NLD; k++) begin : g_cam
    logic en;
    logic cv, cu;
    logic [SQW-1:0] ci;
    assign en = l1[k].v && l_hit[k] && !l_mmio[k];
    lp_cam u_cam (.voff(l1[k].vaddr[11:0]), .func3(l1[k].func3), .paddr(l_paddr[k]), .full(!l1[k].need_tlb),
                  .snap_idx(l1[k].snap_idx), .snap_flag(l1[k].snap_flag), .head(head_q), .head_flag(head_flag_q),
                  .count(count_q), .cv_va(cv_va), .cv_voff(cv_voff), .cv_f3(cv_f3), .sq(sq),
                  .spec_ok(spec_ok[k]), .cand_v(cv), .cand(ci), .unk(cu));
    assign cam_en[k] = en;
    assign cam_unk[k] = cu;
    assign cam_v[k] = en && cv;
    assign cam_i[k] = ci;
  end

  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      ok8[k] = l1[k].v && pipe8[l1[k].ldq];
      dcblk[k] = l_hit[k] && !l_mmio[k] && !cam_v[k] && ld_retry_busy[k];
      l1_launch[k] = l1[k].v && l_hit[k] && !l_mmio[k] && !cam_v[k] && !ld_retry_busy[k];
      dcl_req_valid[k] = ok8[k] && l1_launch[k];
      dcl_req_addr[k] = l_paddr[k];
      dcl_req_id_o[k] = 31'({epoch_nx[l1[k].ldq], l1[k].ldq});
    end
  end

  lp_pl12_t pl12_d [NLD];
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      pl12_d[k] = '0;
      pl12_d[k].v = ok8[k];
      pl12_d[k].ldq = l1[k].ldq;
      pl12_d[k].epoch = epoch_nx[l1[k].ldq];
      pl12_d[k].tlb = l_tlb[k];
      pl12_d[k].mmio = l_mmio[k];
      pl12_d[k].cand_v = cam_v[k];
      pl12_d[k].cand = cam_i[k];
      pl12_d[k].dcblk = dcblk[k];
      pl12_d[k].paddr = l_paddr[k];
      pl12_d[k].voff = l1[k].vaddr[11:0];
      pl12_d[k].func3 = l1[k].func3;
    end
  end

  always_ff @(posedge clk) begin
    for (int k = 0; k < NLD; k++) pl12_q[k] <= pl12_d[k];
  end


endmodule

`default_nettype wire
