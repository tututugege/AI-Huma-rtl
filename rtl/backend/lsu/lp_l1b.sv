// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_lsu2dcache_ldq_p, L1/L2 register; STQ CAM moved to L2)
`default_nettype none

// Second half of L1: unconditional DCache read launch (qualified only by hit, !mmio, !ld_retry_busy)
// and the L1/L2 pipeline register. STQ CAM runs in parallel at L2 on registered pl12_q and sq.
module lp_l1b
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  lp_l1in_t            l1 [NLD],
  input  logic                l_hit [NLD],
  input  logic                l_mmio [NLD],
  input  logic [31:0]         l_paddr [NLD],
  input  logic [28:0]         l_paddr_p1 [NLD],
  input  logic [28:0]         l_paddr_m1 [NLD],
  input  logic [1:0]          l_tlb [NLD],
  input  logic [NLD-1:0]      ld_retry_busy,
  input  logic [255:0]        stq_bloom_q,     // 256-bit registered bloom filter of STQ vaddr[10:3]
  input  logic [LQ-1:0]       pipe8,
  input  logic [NLD-1:0]      spec_ok,         // memory speculation: the load of slot k may pass unknown-address stores
  input  logic [NLD-1:0]      l1_spec_w,       // L1 speculative wakeup fired (from lp_wake)
  output logic [NLD-1:0]      l1_launch,
  output logic [NLD-1:0]      dcl_req_valid,
  output logic [31:0]         dcl_req_addr [NLD],
  output logic [30:0]         dcl_req_id_o [NLD],
  output lp_pl12_t            pl12_q [NLD]
);

  logic [NLD-1:0] ok8, dcblk, bloom_hit;

  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      ok8[k]           = l1[k].v && pipe8[l1[k].ldq];
      bloom_hit[k]     = !l1[k].replay && stq_bloom_q[l1[k].vaddr[10:3]];
      dcblk[k]         = l_hit[k] && !l_mmio[k] && ld_retry_busy[k];
      l1_launch[k]     = l1[k].v && l_hit[k] && !l_mmio[k] && !ld_retry_busy[k] && !bloom_hit[k];
      dcl_req_valid[k] = ok8[k] && l1_launch[k];
      dcl_req_addr[k]  = l_paddr[k];
      dcl_req_id_o[k]  = 31'({l1[k].epoch + EPW'(1), l1[k].ldq});
    end
  end

  lp_pl12_t pl12_d [NLD];
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      pl12_d[k]           = '0;
      pl12_d[k].v         = ok8[k];
      pl12_d[k].ldq       = l1[k].ldq;
      pl12_d[k].epoch     = l1[k].epoch + EPW'(ok8[k] && l1_launch[k]);
      pl12_d[k].tlb       = l_tlb[k];
      pl12_d[k].mmio      = l_mmio[k];
      pl12_d[k].dcblk     = dcblk[k];
      pl12_d[k].bloom     = l_hit[k] && !l_mmio[k] && !ld_retry_busy[k] && bloom_hit[k];
      pl12_d[k].paddr     = l_paddr[k];
      pl12_d[k].paddr_p1  = l_paddr_p1[k];
      pl12_d[k].paddr_m1  = l_paddr_m1[k];
      pl12_d[k].voff      = l1[k].vaddr[11:0];
      pl12_d[k].func3     = l1[k].func3;
      pl12_d[k].snap_idx  = l1[k].snap_idx;
      pl12_d[k].snap_flag = l1[k].snap_flag;
      pl12_d[k].spec_ok   = spec_ok[k];
      pl12_d[k].replay    = l1[k].replay;
      pl12_d[k].spec_w    = ok8[k] && l1_spec_w[k];
      pl12_d[k].spec_preg = l1[k].dest;
      pl12_d[k].pc8       = l1[k].pc8;
    end
  end

  always_ff @(posedge clk) begin
    for (int k = 0; k < NLD; k++) pl12_q[k] <= pl12_d[k];
  end

endmodule

`default_nettype wire
