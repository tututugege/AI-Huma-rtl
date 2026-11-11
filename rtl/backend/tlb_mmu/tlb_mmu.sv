// Ref: back-end/Lsu/TlbMmu.cpp  class TlbMmu  (reference model commit 2f31e8d; DTLB instance of BackTop::comb_lsu_mmu)
`default_nettype none

// Back-end DTLB with page-table-walk client. Top level only adapts the flat spec ports to the core (8 ports:
// LSU_LDU_COUNT loads, then
// LSU_STA_COUNT stores). During fence / cancel cycles no request is answered (mmu2lsu_io is all zero in the
// reference model).
module tlb_mmu import ttg_cfg_pkg::*; import tlb_mmu_pkg::*; #(
  parameter int IDX_W = (LDQ_IDX_WIDTH > STQ_IDX_WIDTH) ? LDQ_IDX_WIDTH : STQ_IDX_WIDTH   // LSU_MMU_IDX_WIDTH
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [LSU_LDU_COUNT-1:0] ldq_req_valid,
  input  logic [XLEN_BITS-1:0] ldq_req_vaddr [LSU_LDU_COUNT],
  input  logic [IDX_W-1:0] ldq_req_entry_idx [LSU_LDU_COUNT],
  input  logic [IDX_W-1:0] ldq_req_wait_idx [LSU_LDU_COUNT],
  input  logic [LSU_STA_COUNT-1:0] stq_req_valid,
  input  logic [XLEN_BITS-1:0] stq_req_vaddr [LSU_STA_COUNT],
  input  logic [IDX_W-1:0] stq_req_entry_idx [LSU_STA_COUNT],
  input  logic [IDX_W-1:0] stq_req_wait_idx [LSU_STA_COUNT],
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
  input  logic ptw_walk_resp_leaf_level,
  output logic [LSU_LDU_COUNT-1:0] ldq_resp_valid,
  output logic [1:0] ldq_resp_result [LSU_LDU_COUNT],
  output logic [LSU_LDU_COUNT-1:0] ldq_resp_hit,
  output logic [31:0] ldq_resp_paddr [LSU_LDU_COUNT],
  output logic [IDX_W-1:0] ldq_resp_entry_idx [LSU_LDU_COUNT],
  output logic [IDX_W-1:0] ldq_resp_wait_idx [LSU_LDU_COUNT],
  output logic [LSU_STA_COUNT-1:0] stq_resp_valid,
  output logic [1:0] stq_resp_result [LSU_STA_COUNT],
  output logic [LSU_STA_COUNT-1:0] stq_resp_hit,
  output logic [31:0] stq_resp_paddr [LSU_STA_COUNT],
  output logic [IDX_W-1:0] stq_resp_entry_idx [LSU_STA_COUNT],
  output logic [IDX_W-1:0] stq_resp_wait_idx [LSU_STA_COUNT],
  output logic ptw_walk_req_valid,
  output logic [VPN_W-1:0] ptw_walk_req_vpn,
  output logic [21:0] ptw_walk_req_root_ppn,
  output logic ptw_walk_resp_consumed,
  output logic ptw_walk_flush
);

  localparam int LANES = LSU_LDU_COUNT + LSU_STA_COUNT;

  logic        lane_req_valid [LANES];
  logic [XLEN_BITS-1:0] lane_req_vaddr [LANES];
  logic        lane_resp_valid [LANES];
  logic [1:0]  lane_resp_result [LANES];
  logic [31:0] lane_resp_paddr [LANES];
  tlb_mmu_ptw_resp_t ptw_resp;

  assign ptw_resp = '{fault: ptw_walk_resp_fault, vpn: ptw_walk_resp_vpn, level: ptw_walk_resp_leaf_level,
                      ppn: ptw_walk_resp_leaf_ppn, perm: ptw_walk_resp_leaf_perm};

  tlb_mmu_core #(.LANES(LANES), .LD_LANES(LSU_LDU_COUNT), .FETCH(1'b0), .ENTRIES(DTLB_ENTRIES)) u_core (
    .clk, .rst_n,
    .fence(rob_bcast_fence), .cancel(rob_bcast_flush || dec_bcast_mispred),
    .satp(csr_status_satp), .privilege(csr_status_privilege), .mxr(csr_status_mstatus_mxr),
    .sum(csr_status_mstatus_sum), .mprv(csr_status_mstatus_mprv), .mpp(csr_status_mstatus_mpp),
    .req_valid(lane_req_valid), .req_vaddr(lane_req_vaddr),
    .ptw_req_ready(ptw_walk_req_ready), .ptw_resp_valid(ptw_walk_resp_valid), .ptw_resp,
    .resp_valid(lane_resp_valid), .resp_result(lane_resp_result), .resp_paddr(lane_resp_paddr),
    .ptw_req_valid(ptw_walk_req_valid), .ptw_req_vpn(ptw_walk_req_vpn), .ptw_req_root_ppn(ptw_walk_req_root_ppn),
    .ptw_resp_consumed(ptw_walk_resp_consumed), .ptw_flush(ptw_walk_flush)
  );

  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_ld
    assign lane_req_valid[i] = ldq_req_valid[i];
    assign lane_req_vaddr[i] = ldq_req_vaddr[i];
    assign ldq_resp_valid[i] = lane_resp_valid[i];
    assign ldq_resp_result[i] = lane_resp_result[i];
    assign ldq_resp_hit[i] = lane_resp_valid[i] && lane_resp_result[i] == RES_HIT;
    assign ldq_resp_paddr[i] = lane_resp_paddr[i];
    assign ldq_resp_entry_idx[i] = ldq_req_entry_idx[i];
    assign ldq_resp_wait_idx[i] = ldq_req_wait_idx[i];
  end

  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_st
    assign lane_req_valid[LSU_LDU_COUNT + i] = stq_req_valid[i];
    assign lane_req_vaddr[LSU_LDU_COUNT + i] = stq_req_vaddr[i];
    assign stq_resp_valid[i] = lane_resp_valid[LSU_LDU_COUNT + i];
    assign stq_resp_result[i] = lane_resp_result[LSU_LDU_COUNT + i];
    assign stq_resp_hit[i] = lane_resp_valid[LSU_LDU_COUNT + i]
                          && lane_resp_result[LSU_LDU_COUNT + i] == RES_HIT;
    assign stq_resp_paddr[i] = lane_resp_paddr[LSU_LDU_COUNT + i];
    assign stq_resp_entry_idx[i] = stq_req_entry_idx[i];
    assign stq_resp_wait_idx[i] = stq_req_wait_idx[i];
  end

endmodule

`default_nettype wire
