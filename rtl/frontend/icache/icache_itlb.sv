// Ref: front-end/icache/ICacheTop.cpp  comb_mmu_view;  back-end/Lsu/TlbMmu.cpp  TlbMmu (Kind::ITLB)
`default_nettype none

// Instruction TLB with page-table-walk client: the shared tlb_mmu_core with one fetch port.  The I-cache asks
// for the page of
// the fetch ({vtag, 12'b0}, access type fetch); the answer is (ppn_valid, ppn) for a hit, (ppn_valid, page_fault) for a
// permission/translation fault, nothing for a miss (the I-cache simply asks again next cycle).
// Modes per cycle (fence > cancel > translate): SFENCE.VMA flush, refetch cancels the walk.  Assumption
// (docs/modules/icache.md):
// itlb_flush always comes together with refetch, as in BackTop (SFENCE.VMA also flushes the pipe).
module icache_itlb import icache_pkg::*; import tlb_mmu_pkg::*; #(
  parameter int ENTRIES = 64
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        itlb_flush,
  input  logic        refetch,
  input  logic        mmu_req_valid,
  input  logic [VPN_W-1:0] mmu_req_vtag,
  input  logic [31:0] csr_satp,
  input  logic [1:0]  csr_privilege,
  input  logic        csr_mxr,
  input  logic        csr_sum,
  input  logic        csr_mprv,
  input  logic [1:0]  csr_mpp,
  input  logic        ptw_req_ready,
  input  logic        ptw_resp_valid,
  input  logic        ptw_resp_fault,
  input  logic [VPN_W-1:0] ptw_resp_vpn,
  input  logic [LVL_W-1:0]        ptw_resp_leaf_level,
  input  logic [PPN_W-1:0] ptw_resp_leaf_ppn,
  input  logic [PERM_W-1:0] ptw_resp_leaf_perm,
  output logic        ppn_valid,
  output logic        page_fault,
  output logic [PPN_W-1:0] ppn,
  output logic        ptw_req_valid,
  output logic [VPN_W-1:0] ptw_req_vpn,
  output logic [21:0] ptw_req_root_ppn,
  output logic        ptw_resp_consumed,
  output logic        ptw_flush
);

  tlb_mmu_ptw_resp_t ptw_resp;
  assign ptw_resp = '{fault: ptw_resp_fault, vpn: ptw_resp_vpn, level: ptw_resp_leaf_level,
                      ppn: ptw_resp_leaf_ppn, perm: ptw_resp_leaf_perm};

  logic        lane_req_valid [1];
  logic [31:0] lane_req_vaddr [1];
  logic        lane_resp_valid [1];
  logic [1:0]  lane_resp_result [1];
  logic [31:0] lane_resp_paddr [1];

  assign lane_req_valid[0] = mmu_req_valid;
  assign lane_req_vaddr[0] = {mmu_req_vtag, 12'b0};

  tlb_mmu_core #(.LANES(1), .LD_LANES(0), .FETCH(1'b1), .ENTRIES(ENTRIES)) u_core (
    .clk, .rst_n, .fence(itlb_flush), .cancel(refetch),
    .satp(csr_satp), .privilege(csr_privilege), .mxr(csr_mxr), .sum(csr_sum), .mprv(csr_mprv), .mpp(csr_mpp),
    .req_valid(lane_req_valid), .req_vaddr(lane_req_vaddr),
    .ptw_req_ready, .ptw_resp_valid, .ptw_resp,
    .resp_valid(lane_resp_valid), .resp_result(lane_resp_result), .resp_paddr(lane_resp_paddr),
    .ptw_req_valid, .ptw_req_vpn, .ptw_req_root_ppn, .ptw_resp_consumed, .ptw_flush
  );

  always_comb begin
    ppn_valid  = lane_resp_valid[0] && (lane_resp_result[0] == RES_HIT || lane_resp_result[0] == RES_FAULT);
    page_fault = lane_resp_valid[0] && lane_resp_result[0] == RES_FAULT;
    ppn        = (ppn_valid && !page_fault) ? lane_resp_paddr[0][31:12] : '0;
  end

  // lane_resp_paddr[11:0] and the page-fault paddr are not consumed
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n) !(itlb_flush && !refetch))
    else $error("icache_itlb: itlb_flush without refetch (assumption of the ITLB mode selection)");
`endif

endmodule

`default_nettype wire
