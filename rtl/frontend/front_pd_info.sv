// Ref: front-end/front_top.cpp  FrontComb::write_ptab_and_check (BPO_PDCKPT: PdInfo), BPU_pipe.h PdInfo
`default_nettype none

// Result of the predecode check, registered for the BPU (one cycle later): whether the checker looked at a block at
// all (the BPU then drops the oldest PDCKPT record) and, when it asks for a flush, the history symbol / RAS operation
// of the corrected block: the first taken control instruction of the corrected directions pushes its symbol, a JAL
// with rd=ra pushes pc+4, a return pops.
module front_pd_info import ttg_cfg_pkg::*; import front_pkg::*; import bpu_stage_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    checked,              // the checker compared a PTAB head with the instruction head
  input  logic                    flush,                // ... and found a wrong prediction
  input  logic [XLEN_BITS-1:0]             base_pc,
  input  logic [31:0]             insts      [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  inst_valid,
  input  logic [1:0]              ptype      [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]             pre_target [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  dir_corrected,
  input  logic [XLEN_BITS-1:0]             ptab_next,
  output logic                    pd_valid,
  output logic                    pd_flush,
  output logic                    pd_hv,
  output logic [HSYM_W-1:0]       pd_hbits,
  output logic [1:0]              pd_ras_op,
  output logic [XLEN_BITS-1:0]             pd_ras_val
);

  logic [FETCH_WIDTH-1:0] lane_taken;
  logic [FETCH_WIDTH-1:0] first;
  logic                   any;
  logic [XLEN_BITS-1:0]            first_pc;
  logic [21:0]            first_fld;            // {imm12, rs1, rd} of the first taken instruction
  logic [XLEN_BITS-1:0]            first_tgt;
  logic [1:0]             first_type;
  logic [XLEN_BITS-1:0]            lane_pc  [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]            lane_tgt [FETCH_WIDTH];
  logic [1:0]             lane_ty  [FETCH_WIDTH];
  logic [21:0]            lane_fld [FETCH_WIDTH];

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      lane_pc[i]    = base_pc + XLEN_BITS'(4 * i);
      lane_ty[i]    = ptype[i];
      lane_fld[i]   = {insts[i][31:20], insts[i][19:15], insts[i][11:7]};
      lane_tgt[i]   = (ptype[i] == PREDECODE_JALR) ? ptab_next : pre_target[i];
      lane_taken[i] = inst_valid[i] && ptype[i] != PREDECODE_NON_BRANCH && dir_corrected[i];
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_first (.req(lane_taken), .onehot(first), .any(any));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_pc (.sel(first), .data(lane_pc), .out(first_pc));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(22)) u_fld (.sel(first), .data(lane_fld), .out(first_fld));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_tgt (.sel(first), .data(lane_tgt), .out(first_tgt));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(2)) u_ty (.sel(first), .data(lane_ty), .out(first_type));

  logic                 hv_d;
  logic [HSYM_W-1:0]    hbits_d;
  logic [1:0]           ras_op_d;
  logic [XLEN_BITS-1:0]         ras_val_d;

  // Ref: write_ptab_and_check: PdInfo
  always_comb begin
    hv_d      = flush && any;
    hbits_d   = hv_d ? hsym_of(first_pc, first_tgt) : '0;
    ras_op_d  = 2'd0;
    ras_val_d = '0;
    if (hv_d && first_type == PREDECODE_JAL && first_fld[4:0] == 5'd1) begin
      ras_op_d  = 2'd1;
      ras_val_d = first_pc + XLEN_BITS'(4);
    end else if (hv_d && first_type == PREDECODE_JALR && first_fld[4:0] == 5'd0 && first_fld[9:5] == 5'd1 &&
                 first_fld[21:10] == 12'd0) begin
      ras_op_d = 2'd2;
    end
  end

  logic                 pd_valid_q, pd_flush_q, pd_hv_q;
  logic [HSYM_W-1:0]    pd_hbits_q;
  logic [1:0]           pd_ras_op_q;
  logic [XLEN_BITS-1:0]          pd_ras_val_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pd_valid_q   <= 1'b0;
      pd_flush_q   <= 1'b0;
      pd_hv_q      <= 1'b0;
      pd_hbits_q   <= '0;
      pd_ras_op_q  <= '0;
      pd_ras_val_q <= '0;
    end else begin
      pd_valid_q   <= checked;
      pd_flush_q   <= flush;
      pd_hv_q      <= hv_d;
      pd_hbits_q   <= hbits_d;
      pd_ras_op_q  <= ras_op_d;
      pd_ras_val_q <= ras_val_d;
    end
  end

  assign pd_valid   = pd_valid_q;
  assign pd_flush   = pd_flush_q;
  assign pd_hv      = pd_hv_q;
  assign pd_hbits   = pd_hbits_q;
  assign pd_ras_op  = pd_ras_op_q;
  assign pd_ras_val = pd_ras_val_q;

endmodule

`default_nettype wire
