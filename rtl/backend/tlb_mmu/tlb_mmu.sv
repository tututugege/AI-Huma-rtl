// Ref: back-end/Lsu/TlbMmu.cpp  class TlbMmu  (reference model commit 2f31e8d; DTLB instance of BackTop::comb_lsu_mmu)
`default_nettype none

// Back-end DTLB with page-table-walk client: one translation port per physical AGU (LSU_AGU_PHYS; with shared AGUs a
// port serves a load or a store address, the type comes with the request). During fence / cancel cycles no request is
// answered (mmu2lsu_io is all zero in the reference model).
module tlb_mmu import ttg_cfg_pkg::*; import tlb_mmu_pkg::*; #(
  parameter int IDX_W = (LDQ_IDX_WIDTH > STQ_IDX_WIDTH) ? LDQ_IDX_WIDTH : STQ_IDX_WIDTH   // LSU_MMU_IDX_WIDTH
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [LSU_AGU_PHYS-1:0] req_valid,
  input  logic [XLEN_BITS-1:0] req_vaddr [LSU_AGU_PHYS],
  input  logic [IDX_W-1:0] req_entry_idx [LSU_AGU_PHYS],
  input  logic [LSU_AGU_PHYS-1:0] req_is_store,
  input  logic [XLEN_BITS-1:0] csr_status_satp,
  input  logic [1:0] csr_status_privilege,
  input  logic csr_status_mstatus_mxr,
  input  logic csr_status_mstatus_sum,
  input  logic csr_status_mstatus_mprv,
  input  logic [1:0] csr_status_mstatus_mpp,
  input  logic rob_bcast_fence,
  input  logic rob_bcast_flush,
  input  logic dec_bcast_mispred,
  input  logic ptw_walk_req_ready,
  input  logic ptw_walk_resp_valid,
  input  logic ptw_walk_resp_fault,
  input  logic [VPN_W-1:0] ptw_walk_resp_vpn,
  input  logic [PPN_W-1:0] ptw_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] ptw_walk_resp_leaf_perm,
  input  logic [LVL_W-1:0] ptw_walk_resp_leaf_level,
  input  logic pf_page_set,
  input  logic [VPN_W-1:0] pf_page_vpn,
  output logic [LSU_AGU_PHYS-1:0] resp_valid,
  output logic [1:0] resp_result [LSU_AGU_PHYS],
  output logic [LSU_AGU_PHYS-1:0] resp_hit,
  output logic [31:0] resp_paddr [LSU_AGU_PHYS],
  output logic [IDX_W-1:0] resp_entry_idx [LSU_AGU_PHYS],
  output logic ptw_walk_req_valid,
  output logic [VPN_W-1:0] ptw_walk_req_vpn,
  output logic [21:0] ptw_walk_req_root_ppn,
  output logic ptw_walk_resp_consumed,
  output logic ptw_walk_flush,
  output logic walk_next_v,
  output logic [VPN_W-1:0] walk_next_vpn
);

  localparam int LANES = LSU_AGU_PHYS;

  logic        lane_req_valid [LANES];
  logic        lane_req_is_store [LANES];
  logic [XLEN_BITS-1:0] lane_req_vaddr [LANES];
  logic        lane_resp_valid [LANES];
  logic [1:0]  lane_resp_result [LANES];
  logic [31:0] lane_resp_paddr [LANES];
  tlb_mmu_ptw_resp_t ptw_resp;

  assign ptw_resp = '{fault: ptw_walk_resp_fault, vpn: ptw_walk_resp_vpn, level: ptw_walk_resp_leaf_level,
                      ppn: ptw_walk_resp_leaf_ppn, perm: ptw_walk_resp_leaf_perm};

  /* verilator lint_off UNUSEDSIGNAL */
  logic        nc_peek_ok    [1];
  logic [31:0] nc_peek_paddr [1];
  /* verilator lint_on UNUSEDSIGNAL */

  tlb_mmu_core #(.LANES(LANES), .FETCH(1'b0), .ENTRIES(DTLB_ENTRIES), .NPEEK(0)) u_core (
    .clk, .rst_n,
    .fence(rob_bcast_fence), .cancel(rob_bcast_flush || dec_bcast_mispred),
    .satp(csr_status_satp), .privilege(csr_status_privilege), .mxr(csr_status_mstatus_mxr),
    .sum(csr_status_mstatus_sum), .mprv(csr_status_mstatus_mprv), .mpp(csr_status_mstatus_mpp),
    .req_valid(lane_req_valid), .req_vaddr(lane_req_vaddr), .req_is_store(lane_req_is_store),
    .ptw_req_ready(ptw_walk_req_ready), .ptw_resp_valid(ptw_walk_resp_valid), .ptw_resp,
    .pf_page_set, .pf_page_vpn,
    .peek_vaddr('{default: '0}), .peek_ok(nc_peek_ok), .peek_paddr(nc_peek_paddr),
    .resp_valid(lane_resp_valid), .resp_result(lane_resp_result), .resp_paddr(lane_resp_paddr),
    .ptw_req_valid(ptw_walk_req_valid), .ptw_req_vpn(ptw_walk_req_vpn), .ptw_req_root_ppn(ptw_walk_req_root_ppn),
    .ptw_resp_consumed(ptw_walk_resp_consumed), .ptw_flush(ptw_walk_flush),
    .walk_next_v, .walk_next_vpn
  );

  for (genvar i = 0; i < LANES; i++) begin : g_port
    assign lane_req_valid[i] = req_valid[i];
    assign lane_req_is_store[i] = req_is_store[i];
    assign lane_req_vaddr[i] = req_vaddr[i];
    assign resp_valid[i] = lane_resp_valid[i];
    assign resp_result[i] = lane_resp_result[i];
    assign resp_hit[i] = lane_resp_valid[i] && lane_resp_result[i] == RES_HIT;
    assign resp_paddr[i] = lane_resp_paddr[i];
    assign resp_entry_idx[i] = req_entry_idx[i];
  end

endmodule

`default_nettype wire
